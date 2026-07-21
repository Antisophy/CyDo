module cydo.workflow.sessions.task_runner;

import core.time : seconds;

import std.file : mkdirRecurse;
import std.exception : enforce;
import std.path : buildPath, dirName;
import std.logger : infof, tracef, warningf;

import ae.utils.json : JSONPartial, jsonParse, toJson;
import ae.utils.promise : Promise, reject, resolve;

import cydo.agent.contract : Agent, SessionConfig;
import cydo.agent.session : AgentSession;
import cydo.mcp.tool_descriptions : RenderedCydoToolsOptions,
	ToolDescriptionViolation, checkRenderedCydoToolDescriptionViolations;
import cydo.protocol : ItemDeltaEvent, ItemStartedEvent, ProcessExitEvent,
	ProcessStderrEvent, TranslatedEvent;
import cydo.runtime.config : AgentDriver, PathMode, SandboxConfig;
import cydo.runtime.launch.types : AgentSandboxConfig, ProcessLaunch;
import launchSandbox = cydo.runtime.launch.sandbox;
import cydo.domain.tasks.model : ProcessState, TaskData, TaskStatus,
	WaitingTaskDependencyState;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.domain.task_types.catalog : TaskTypeCatalog;
import cydo.domain.task_types.definition : TaskTypeDef,
	formatCompactCreatableTaskTypeToolSummary, formatCompactHandoffToolSummary,
	isInteractive, formatCompactSwitchModeToolSummary, loadTaskTypeSystemPrompt, byName;

version (unittest) import std.exception : assertThrown;
version (unittest) import std.process : execute;
version (unittest) import std.string : strip;
version (unittest) import cydo.agent.drivers.claude : ClaudeCodeAgent;

package(cydo):

private bool isAssistantTurnWork(TranslatedEvent ev)
{
	@JSONPartial struct EventType
	{
		string type;
	}

	auto eventType = jsonParse!EventType(ev.translated).type;
	if (eventType == "item/started")
	{
		auto started = jsonParse!ItemStartedEvent(ev.translated);
		if (started.is_replay || started.is_synthetic || started.is_meta)
			return false;
		return started.item_type == "text"
			|| started.item_type == "thinking"
			|| started.item_type == "tool_use";
	}
	if (eventType == "item/delta")
	{
		auto delta = jsonParse!ItemDeltaEvent(ev.translated);
		return delta.delta_type == "text_delta"
			|| delta.delta_type == "thinking_delta"
			|| delta.delta_type == "input_json_delta";
	}
	return false;
}

unittest
{
	foreach (eventJson; [
		`{"type":"item/started","item_id":"text","item_type":"text"}`,
		`{"type":"item/started","item_id":"thinking","item_type":"thinking"}`,
		`{"type":"item/started","item_id":"tool","item_type":"tool_use"}`,
		`{"type":"item/delta","item_id":"text","delta_type":"text_delta","content":"work"}`,
		`{"type":"item/delta","item_id":"thinking","delta_type":"thinking_delta","content":"work"}`,
		`{"type":"item/delta","item_id":"tool","delta_type":"input_json_delta","content":"{}"}`,
	])
		assert(isAssistantTurnWork(TranslatedEvent(eventJson, null)), eventJson);
}

unittest
{
	foreach (eventJson; [
		`{"type":"session/init","session_id":"session"}`,
		`{"type":"session/status","status":"idle"}`,
		`{"type":"session/compacted"}`,
		`{"type":"item/started","item_id":"user","item_type":"user_message"}`,
		`{"type":"item/started","item_id":"replay","item_type":"text","is_replay":true}`,
		`{"type":"item/started","item_id":"synthetic","item_type":"thinking","is_synthetic":true}`,
		`{"type":"item/started","item_id":"meta","item_type":"tool","is_meta":true}`,
		`{"type":"item/delta","item_id":"background","delta_type":"output_delta","content":"late output"}`,
		`{"type":"item/completed","item_id":"text","text":"done"}`,
		`{"type":"item/result","item_id":"tool","content":"done"}`,
		`{"type":"turn/result","subtype":"success"}`,
		`{"type":"process/stderr","text":"warning"}`,
		`{"type":"process/exit","code":0}`,
		`{"type":"task/notification","message":"waiting"}`,
	])
		assert(!isAssistantTurnWork(TranslatedEvent(eventJson, null)), eventJson);
}

unittest
{
	assertThrown!Exception(isAssistantTurnWork(
		TranslatedEvent(`{"type":"item/started"`, null)));
}

struct TaskSessionLaunch
{
	ProcessLaunch processLaunch;
	SessionConfig sessionConfig;
}

struct TaskSessionRunnerHost
{
	TaskData* delegate(int tid) getTask;
	string delegate(const TaskData* td) taskDir;
	string delegate(const TaskData* td) outputPath;
	string delegate(const TaskData* td) effectiveCwd;
	string delegate(const TaskData* td) worktreePath;
	SandboxConfig delegate() globalSandbox;
	SandboxConfig delegate(string workspaceName) findWorkspaceSandbox;
	string delegate(string workspaceName) findWorkspaceRoot;
	string delegate(string workspaceName) findWorkspacePermissionPolicy;
	SandboxConfig delegate(string agentName) findAgentSandbox;
	void delegate(string projectPath, string taskType,
		ToolDescriptionViolation[] violations) reportMcpToolDescriptionLimit;
	string delegate(int tid) resolveSharedTmpPath;
	string delegate() mcpSocketPath;
	Agent delegate(int tid) agentForTask;
	Agent delegate(int tid) tryAgentForTask;
	void delegate(int tid) clearLastActive;
	void delegate(int tid, TranslatedEvent ev) broadcastTask;
	string delegate(int tid, string subject, string body) appendTaskDiagnostic;
	void delegate(int tid, string translated) broadcastAppendedTaskEvent;
	void delegate(int tid, string nonce) sendAgentAck;
	void delegate(int tid) publishTaskSnapshot;
	void delegate(int tid) onTaskTurnCompletedAlive;
	bool delegate(int tid) drainIdleCallbacksForTurnResult;
	void delegate(int tid) drainIdleCallbacksOnExit;
	bool delegate(int tid) hasPendingSubTask;
	bool delegate(int tid) hasTaskDependency;
	bool delegate(int tid) hasPendingChildQuestion;
	void delegate(int tid) sendPendingChildAnswerReminder;
	string delegate(int tid) checkDeclaredOutputs;
	bool delegate(int tid, bool eagerDepCleanup) finalizeCompletedSubTask;
	bool delegate(int tid) deliverFailedPendingSubTaskResult;
	void delegate(int tid) deliverWaitingParentResultsIfReady;
	void delegate(int parentTid) deliverBatchResults;
	void delegate(int tid) failPendingAskUserQuestionOnExit;
	void delegate(int tid) failPendingPermissionPromptOnExit;
	void delegate(int tid) failPendingAskRouteOnExit;
	void delegate(int tid) cancelExitBackgroundWork;
	void delegate(int tid) resetHistoryWatermarkOnly;
	void delegate(int tid) resetHistoryWatermarkAfterExit;
	void delegate(int tid) unsubscribeTaskHistorySubscribers;
	void delegate(int tid) touchAndPersistLastActive;
	int delegate(int tid) findAliveAncestor;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	void delegate(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTaskFrom;
	void delegate(int tid, string resultText) persistResultText;
	void delegate(int tid, string missingOutputs) requestMissingOutputs;
	void delegate(int tid) spawnContinuation;
	void delegate(int tid) spawnOnYieldContinuation;
	void delegate(int tid) emitTaskReload;
	void delegate(int tid) startJsonlWatch;
	void delegate(int tid) ensureHistoryLoaded;
	void delegate(int tid) finalReconcileJsonlIfPresent;
	void delegate(int tid) stopJsonlWatch;
	void delegate(int tid) broadcastHistoryOperations;
	void delegate(int tid) sendSystemRestartNudge;
	void delegate() loadPersistedTaskDeps;
	int[] delegate() snapshotTaskIds;
	WaitingTaskDependencyState delegate(int parentTid) waitingTaskDependencyState;
	bool delegate() shuttingDown;
	TaskTypeCatalog taskTypeCatalog;
}

class TaskSessionRunner
{
	private TaskSessionRunnerHost host_;
	private AgentSession[int] sessions_;

	this(TaskSessionRunnerHost host)
	{
		host_ = host;
	}

	AgentSession sessionForTask(int tid)
	{
		if (auto session = tid in sessions_)
			return *session;
		return null;
	}

	bool taskAlive(int tid)
	{
		auto session = sessionForTask(tid);
		return session !is null && session.alive;
	}

	bool taskCanStop(int tid, bool stdinClosed)
	{
		auto session = sessionForTask(tid);
		return session !is null
			&& session.alive
			&& (!stdinClosed || session.canStopAfterCloseStdin);
	}

	void shutdownSessions()
	{
		AgentSession[] snapshot;
		foreach (session; sessions_)
			snapshot ~= session;
		foreach (session; snapshot)
		{
			if (session.alive)
				session.stop();
			session.killAfterTimeout(0.seconds);
		}
	}

	void interruptTask(int tid)
	{
		if (auto session = sessionForTask(tid))
			session.interrupt();
	}

	void sigintTask(int tid)
	{
		if (auto session = sessionForTask(tid))
			session.sigint();
	}

	void closeTaskStdin(int tid)
	{
		if (auto session = sessionForTask(tid))
			session.closeStdin();
	}

	void stopTask(int tid)
	{
		if (auto session = sessionForTask(tid))
			session.stop();
	}

	TaskSessionLaunch prepareTaskSessionLaunch(int tid, Agent taskAgent,
		TaskTypeDef* typeDef)
	{
		auto td = requireTask(tid,
			"Task must exist before preparing session launch");

		SessionConfig sessionConfig;
		auto taskTypes = host_.taskTypeCatalog.getTaskTypesForProject(td.projectPath);
		auto entryPoints = host_.taskTypeCatalog.getEntryPointsForProject(td.projectPath);
		sessionConfig.creatableTaskTypes = formatCompactCreatableTaskTypeToolSummary(taskTypes,
			td.taskType);
		sessionConfig.switchModes = formatCompactSwitchModeToolSummary(taskTypes, td.taskType);
		sessionConfig.handoffs = formatCompactHandoffToolSummary(taskTypes, td.taskType);
		if (typeDef !is null)
		{
			sessionConfig.model = taskAgent.resolveModelAlias(typeDef.model_class);
			if (taskAgent.supportsDeveloperPrompt)
				sessionConfig.appendSystemPrompt = loadTaskTypeSystemPrompt(*typeDef, taskTypes,
					td.taskType,
					host_.taskTypeCatalog.promptSearchPath(td.projectPath),
					host_.outputPath(td));
		}
		sessionConfig.mcpSocketPath = host_.mcpSocketPath();

		auto workDir = td.repoPath.length > 0 ? td.repoPath : null;

		auto tdDir = host_.taskDir(td);
		mkdirRecurse(tdDir);

		auto taskCwd = host_.effectiveCwd(td);
		auto chdir = taskCwd.length > 0 ? taskCwd : workDir;

		auto wsSandbox = host_.findWorkspaceSandbox(td.workspace);
		auto wsRoot = host_.findWorkspaceRoot(td.workspace);
		auto agentTypeSandbox = host_.findAgentSandbox(td.agentType);
		bool readOnly = typeDef !is null && typeDef.read_only;
		AgentSandboxConfig agentSandbox;
		agentSandbox.configureSandbox = (ref PathMode[string] paths, ref string[string] env) {
			taskAgent.configureSandbox(paths, env);
		};
		agentSandbox.gitName = taskAgent.gitName;
		agentSandbox.gitEmail = taskAgent.gitEmail;
		auto sandbox = launchSandbox.resolveSandbox(host_.globalSandbox(), agentTypeSandbox, wsSandbox,
			agentSandbox, workDir, wsRoot, readOnly);

		if (td.hasWorktree && workDir.length > 0)
			sandbox.paths[workDir] = PathMode.ro;

		if (workDir.length > 0 && (td.isGitCheckout || td.hasWorktree))
		{
			auto workDirMode = workDir in sandbox.paths;
			enforce(workDirMode !is null, "Sandbox must expose the task checkout: " ~ workDir);
			final switch (*workDirMode)
			{
			case PathMode.ro:
			case PathMode.rw:
			case PathMode.always_rw:
				launchSandbox.grantGitMetadata(sandbox.paths, workDir, *workDirMode);
				break;
			case PathMode.tmpfs:
			case PathMode.empty_dir:
			case PathMode.empty_file:
				break;
			}
		}

		sandbox.paths[tdDir] = PathMode.rw;

		// Other tasks' outputs are part of the workflow contract (sub-task
		// results are delivered to the parent as paths into the sub-tasks'
		// directories), and the tasks container is not necessarily reachable
		// through the workspace-root mount (it may live on another volume) —
		// mount it read-only, unless configuration says otherwise.
		auto tasksRoot = dirName(tdDir);
		if (tasksRoot !in sandbox.paths)
			sandbox.paths[tasksRoot] = PathMode.ro;

		if (td.hasWorktree && workDir.length > 0)
		{
			// Read-only tasks need the worktree mounted too: the task
			// directory tree is not necessarily reachable through the
			// workspace-root mount (it may live on another volume).
			auto wtPath = host_.worktreePath(td);
			enforce(wtPath.length > 0, "Worktree path must not be empty for worktree task");
			auto wtMode = readOnly ? PathMode.ro : PathMode.rw;
			sandbox.paths[wtPath] = wtMode;
			launchSandbox.grantGitMetadata(sandbox.paths, wtPath, wtMode);
		}

		auto reachesWorktree = host_.taskTypeCatalog.reachesWorktreeFor(td.projectPath);
		if (workDir.length > 0 && (td.isGitCheckout || td.hasWorktree)
			&& td.taskType in reachesWorktree && reachesWorktree[td.taskType])
			launchSandbox.grantGitMetadata(sandbox.paths, workDir, PathMode.always_rw);

		auto mcpSocketPath = host_.mcpSocketPath();
		if (mcpSocketPath.length > 0)
			sandbox.paths[mcpSocketPath] = PathMode.ro;

		if (workDir.length > 0)
		{
			auto memoryDir = buildPath(workDir, ".cydo", "memory");
			mkdirRecurse(memoryDir);
			sandbox.paths[memoryDir] = PathMode.always_rw;
		}

		sandbox.sharedTmpPath = host_.resolveSharedTmpPath(tid);
		td.launch = launchSandbox.prepareProcessLaunch(sandbox, chdir,
			taskAgent.executableName(sandbox.env));

		sessionConfig.workspace = td.workspace;
		sessionConfig.workDir = chdir !is null ? chdir : "";
		if (taskAgent.needsBash())
			sessionConfig.includeTools ~= "Bash";
		if (sessionConfig.creatableTaskTypes.length > 0)
			sessionConfig.includeTools ~= "Task";
		if (sessionConfig.switchModes.length > 0)
			sessionConfig.includeTools ~= "SwitchMode";
		if (sessionConfig.handoffs.length > 0)
			sessionConfig.includeTools ~= "Handoff";
		if (taskTypes.isInteractive(host_.taskTypeCatalog.getEntryPointsForProject(td.projectPath),
			td.taskType))
			sessionConfig.includeTools ~= "AskUserQuestion";
		sessionConfig.includeTools ~= "Ask";
		sessionConfig.includeTools ~= "Answer";
		if (typeDef !is null && typeDef.allow_native_subagents)
			sessionConfig.allowNativeSubagents = true;

		sessionConfig.permissionPolicy = host_.findWorkspacePermissionPolicy(td.workspace);
		if (sessionConfig.permissionPolicy.length > 0)
			sessionConfig.includeTools ~= "PermissionPrompt";

		RenderedCydoToolsOptions renderedToolOptions;
		renderedToolOptions.includeBash = taskAgent.needsBash();
		renderedToolOptions.includePermissionPrompt =
			sessionConfig.permissionPolicy.length > 0;
		host_.reportMcpToolDescriptionLimit(td.projectPath, td.taskType,
			checkRenderedCydoToolDescriptionViolations(taskTypes, entryPoints,
				td.taskType, options: renderedToolOptions));
		sessionConfig.agentName = td.agentType;

		return TaskSessionLaunch(td.launch, sessionConfig);
	}

	void spawnTaskSession(int tid)
	{
		auto td = requireTask(tid, "Task must exist before spawning session");
		assert(td.taskType.length > 0,
			"Task must have a task_type before spawning session");
		td.wasKilledByUser = false;
		td.hadTurnResult = false;
		td.stdinClosed = false;
		td.clearLastSessionStatus();
		td.compactionReminderInFlight = false;

		auto taskAgent = host_.agentForTask(tid);
		auto typeDef = currentTaskTypeDef(td);
		auto launch = prepareTaskSessionLaunch(tid, taskAgent, typeDef);
		td = requireTask(tid, "Task disappeared before session creation");
		auto session = taskAgent.createSession(tid, td.agentSessionId,
			launch.processLaunch, launch.sessionConfig);
		sessions_[tid] = session;
		host_.clearLastActive(tid);

		if (taskAgent.lastMcpConfigPath.length > 0)
			td.launch.sandbox.tempFiles ~= taskAgent.lastMcpConfigPath;

		if (td.agentSessionId.length > 0)
			host_.startJsonlWatch(tid);

		session.onOutput = (TranslatedEvent ev) {
			host_.broadcastTask(tid, ev);

			auto current = host_.getTask(tid);
			if (current is null)
				return;

			if (isAssistantTurnWork(ev))
			{
				bool processingChanged = !current.isProcessing;
				if (processingChanged)
					current.isProcessing = true;
				if (current.status == TaskStatus.waiting)
					host_.transitionTask(tid, TaskStatus.waiting, TaskStatus.active,
						TaskNotificationChange.preserve);
				else if (processingChanged)
					host_.publishTaskSnapshot(tid);
			}

			if (!taskAgent.isTurnResult(ev.translated))
				return;

			current = host_.getTask(tid);
			if (current is null)
				return;

			current.isProcessing = false;
			current.hadTurnResult = true;
			current.compactionReminderInFlight = false;

			if (!host_.shuttingDown())
				host_.startJsonlWatch(tid);
			if (!host_.shuttingDown())
				host_.broadcastHistoryOperations(tid);

			current = host_.getTask(tid);
			if (current is null)
				return;

			current.resultText = taskAgent.extractResultText(ev.translated);

			bool hasOnYield = taskHasOnYield(current);
			if (host_.hasPendingSubTask(tid) || current.pendingContinuation !is null
				|| host_.hasTaskDependency(tid) || hasOnYield
				|| current.onIdleCallbacks.length > 0)
			{
				if (current.onIdleCallbacks.length > 0)
				{
					if (host_.drainIdleCallbacksForTurnResult(tid))
					{
						host_.publishTaskSnapshot(tid);
						return;
					}
				}
				else if (host_.hasPendingSubTask(tid))
				{
					if (current.pendingContinuation is null && !hasOnYield)
					{
						auto missingOutputs = host_.checkDeclaredOutputs(tid);
						if (missingOutputs is null)
							host_.finalizeCompletedSubTask(tid, true);
						else
							tracef("onOutput: tid=%d deferring sub-task finalization; %s",
								tid, missingOutputs);
					}
				}

				current = host_.getTask(tid);
				if (current is null)
					return;

				bool hasPendingChildQuestion =
					current.pendingContinuation is null
					&& host_.hasPendingChildQuestion(tid);

				if (hasPendingChildQuestion)
				{
					host_.sendPendingChildAnswerReminder(tid);
				}
				else
				{
					current.processQueue.setGoal(ProcessState.Dead).ignoreResult();
					session.closeStdin();
					session.killAfterTimeout(5.seconds);
				}
			}
			else
			{
				if (current.onIdleCallbacks.length > 0)
					host_.drainIdleCallbacksOnExit(tid);
				else
				{
					host_.onTaskTurnCompletedAlive(tid);
					return;
				}
			}

			host_.publishTaskSnapshot(tid);
		};

		session.onAgentAck = (string nonce) {
			if (nonce.length == 0)
				return;
			host_.sendAgentAck(tid, nonce);
		};

		string lastStderr;

		session.onStderr = (string line) {
			ProcessStderrEvent ev;
			ev.text = line;
			host_.broadcastTask(tid, TranslatedEvent(toJson(ev), null));
			lastStderr = line;
		};

		session.onExit = (int exitCode) {
			auto stored = tid in sessions_;
			if (stored is null || *stored !is session)
				return;
			sessions_.remove(tid);
			if (host_.shuttingDown())
				return;

			host_.touchAndPersistLastActive(tid);

			tracef("onExit: tid=%d exitCode=%d status=%s",
				tid, exitCode, currentStatusForLog(tid));

			auto current = host_.getTask(tid);
			if (current is null)
				return;

			ProcessExitEvent ev;
			ev.code = exitCode;

			auto onYieldDef = currentOnYieldDef(current);
			bool hasOnYield = onYieldDef !is null;
			auto cleanExit = (exitCode == 0 || current.pendingContinuation !is null || hasOnYield)
				&& !current.wasKilledByUser;
			if (cleanExit && (current.pendingContinuation !is null || hasOnYield))
				ev.is_continuation = true;
			if (!ev.is_continuation && host_.hasPendingChildQuestion(tid))
				ev.is_continuation = true;

			host_.broadcastTask(tid, TranslatedEvent(toJson(ev), null));

			current = host_.getTask(tid);
			if (current is null)
				return;

			current.isProcessing = false;
			current.stdinClosed = false;
			if (exitCode != 0 && current.status != TaskStatus.completed)
				current.error = lastStderr;
			cleanupTaskLaunch(current);
			host_.ensureHistoryLoaded(tid);
			host_.finalReconcileJsonlIfPresent(tid);
			host_.stopJsonlWatch(tid);

			host_.failPendingAskUserQuestionOnExit(tid);
			host_.failPendingPermissionPromptOnExit(tid);
			host_.failPendingAskRouteOnExit(tid);
			host_.drainIdleCallbacksOnExit(tid);
			host_.cancelExitBackgroundWork(tid);

			bool missingExecutableLaunchFailure = exitCode != 0
				&& !current.hadTurnResult
				&& isMissingExecutableMessage(current.error);
			if (missingExecutableLaunchFailure)
			{
				host_.resetHistoryWatermarkOnly(tid);
				auto translated = host_.appendTaskDiagnostic(
					tid, "Failed to resume session",
					buildLaunchFailureBody(tid, current.error));
				host_.broadcastAppendedTaskEvent(tid, translated);
				host_.unsubscribeTaskHistorySubscribers(tid);
			}
			else if (current.undoStopInProgress)
				host_.resetHistoryWatermarkOnly(tid);
			else
				host_.resetHistoryWatermarkAfterExit(tid);

			current = host_.getTask(tid);
			if (current is null)
				return;

			current.recentNonces = null;

			auto ta = host_.tryAgentForTask(tid);
			bool intentionalExit = !missingExecutableLaunchFailure
				&& (current.processQueue.goalState != ProcessState.Alive
					|| (ta !is null && ta.driver == AgentDriver.codex && exitCode == 143));

			if (current.killPromise !is null)
			{
				auto promise = current.killPromise;
				current.killPromise = null;
				promise.fulfill(ProcessState.Dead);
			}
			else
			{
				if (!intentionalExit)
					current.processQueue.setGoal(ProcessState.Dead).ignoreResult();
				current.processQueue.setCurrentState(ProcessState.Dead);
			}

			if (current.undoStopInProgress)
			{
				current.undoStopInProgress = false;
				return;
			}

			if (!intentionalExit && current.status != TaskStatus.completed)
			{
				if (current.error.length == 0)
					current.error = "Process exited unexpectedly";
				current.resultText = current.error;
				host_.persistResultText(tid, current.resultText);
				host_.transitionTaskFrom(tid,
					[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
						TaskStatus.waiting], TaskStatus.failed,
					TaskNotificationChange.preserve);
				if (current.relationType != "fork")
				{
					auto ancestor = host_.findAliveAncestor(tid);
					if (ancestor >= 0)
						host_.broadcastFocusHint(tid, ancestor);
				}
				if (!host_.deliverFailedPendingSubTaskResult(tid))
					host_.deliverWaitingParentResultsIfReady(tid);
				return;
			}

			if (cleanExit && current.pendingContinuation !is null)
			{
				host_.spawnContinuation(tid);
				return;
			}

			if (hasOnYield && cleanExit)
			{
				infof("on_yield: tid=%d type=%s → %s",
					tid, current.taskType, onYieldDef.on_yield.task_type);
				host_.spawnOnYieldContinuation(tid);
				return;
			}

			bool consumerWaiting = host_.hasPendingSubTask(tid) || host_.hasTaskDependency(tid);
			if (cleanExit && consumerWaiting)
			{
				auto missing = host_.checkDeclaredOutputs(tid);
				if (missing !is null && !current.outputEnforcementAttempted)
				{
					current.outputEnforcementAttempted = true;
					infof("Output enforcement: tid=%d missing outputs, resuming: %s",
						tid, missing);
					host_.requestMissingOutputs(tid, missing);
					return;
				}
				if (missing !is null)
					warningf("Output enforcement: tid=%d still missing outputs after retry: %s",
						tid, missing);
			}

			bool deliveredPendingSubTask = false;
			bool statusWasAlreadyTarget;
			if (current.status == TaskStatus.completed)
				statusWasAlreadyTarget = true;
			else if (exitCode == 0 && host_.hasPendingSubTask(tid))
				deliveredPendingSubTask = host_.finalizeCompletedSubTask(tid, false);
			else
			{
				auto targetStatus = exitCode == 0
					? TaskStatus.completed : TaskStatus.failed;
				host_.persistResultText(tid, current.resultText);
				if (current.status != targetStatus)
				{
					host_.transitionTaskFrom(tid,
						targetStatus == TaskStatus.completed
							? [TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
								TaskStatus.waiting, TaskStatus.failed]
							: [TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
								TaskStatus.waiting, TaskStatus.completed],
						targetStatus, TaskNotificationChange.preserve);
				}
				else
					statusWasAlreadyTarget = true;
				if (current.status != TaskStatus.completed)
					deliveredPendingSubTask = host_.deliverFailedPendingSubTaskResult(tid);
			}

			if (!deliveredPendingSubTask)
				host_.deliverWaitingParentResultsIfReady(tid);

			host_.emitTaskReload(tid);

			current = host_.getTask(tid);
			if (current is null)
				return;

			if (current.relationType != "fork")
			{
				auto ancestor = host_.findAliveAncestor(tid);
				if (ancestor >= 0)
					host_.broadcastFocusHint(tid, ancestor);
			}
			if (!deliveredPendingSubTask && statusWasAlreadyTarget)
				host_.publishTaskSnapshot(tid);
		};

		td.error = null;
		if (td.status == TaskStatus.pending)
			host_.transitionTask(tid, TaskStatus.pending, TaskStatus.active,
				TaskNotificationChange.preserve);
		else
			host_.publishTaskSnapshot(tid);
	}

	Promise!ProcessState delegate(ProcessState) makeProcessQueueSF(int tid)
	{
		return (ProcessState goal) => processTransition(tid, goal);
	}

	Promise!ProcessState processTransition(int tid, ProcessState goal)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return reject!ProcessState(new Exception("Task not found"));

		if (goal == ProcessState.Alive)
		{
			if (host_.shuttingDown())
				return reject!ProcessState(new Exception("Shutting down"));
			try
				spawnTaskSession(tid);
			catch (Exception e)
			{
				td = requireTask(tid, "Task must exist when spawn fails");
				td.error = e.msg;
				td.resultText = e.msg;
				host_.persistResultText(tid, td.resultText);
				host_.transitionTaskFrom(tid,
					[TaskStatus.pending, TaskStatus.active, TaskStatus.alive,
						TaskStatus.waiting, TaskStatus.completed], TaskStatus.failed,
					TaskNotificationChange.preserve);
				auto translated = host_.appendTaskDiagnostic(
					tid, "Failed to resume session", buildLaunchFailureBody(tid, e));
				host_.broadcastAppendedTaskEvent(tid, translated);
				if (!host_.deliverFailedPendingSubTaskResult(tid))
					host_.deliverWaitingParentResultsIfReady(tid);
				return reject!ProcessState(e);
			}
			return resolve(ProcessState.Alive);
		}

		if (!taskAlive(tid))
			return resolve(ProcessState.Dead);

		td.killPromise = new Promise!ProcessState;
		return td.killPromise;
	}

	void resumeInFlightTasks()
	{
		host_.loadPersistedTaskDeps();

		int[] toResume;
		foreach (tid; host_.snapshotTaskIds())
		{
			auto td = host_.getTask(tid);
			if (td is null)
				continue;
			if (td.status == "alive" || td.status == "active" || td.status == "waiting")
				toResume ~= tid;
		}

		if (toResume.length == 0)
			return;

		infof("Resuming %d in-flight task(s) after restart", toResume.length);

		foreach (i, tid; toResume)
		{
			auto td = host_.getTask(tid);
			if (td is null)
				continue;

			auto status = td.status;
			infof("Resuming session %d/%d (tid=%d, agent=%s, status=%s)",
				i + 1, toResume.length, tid, td.agentType, status);

			if (status == "waiting")
			{
				final switch (host_.waitingTaskDependencyState(tid))
				{
				case WaitingTaskDependencyState.noChildren:
					tracef("resumeInFlightTasks: tid=%d waiting, no children — resuming with restart nudge",
						tid);
					resumeActiveTask(tid);
					break;
				case WaitingTaskDependencyState.allChildrenTerminal:
					tracef("resumeInFlightTasks: tid=%d waiting, all children terminal — resuming with batch delivery",
						tid);
					resumeAndDeliverResults(tid);
					break;
				case WaitingTaskDependencyState.hasNonTerminalChildren:
					tracef("resumeInFlightTasks: tid=%d waiting, nonterminal children — resuming without message",
						tid);
					resumeWaitingTask(tid);
					break;
				}
			}
			else if (status == "active")
			{
				resumeActiveTask(tid);
			}
			else if (status == "alive")
			{
				resumeTask(tid).ignoreResult();
			}
		}
	}

	Promise!void resumeTask(int tid)
	{
		auto td = host_.getTask(tid);
		if (td is null)
			return resolve();

		return td.processQueue.setGoal(ProcessState.Alive).then(() {
			auto current = host_.getTask(tid);
			if (current is null)
				return;
		});
	}

	void resumeAndDeliverResults(int tid)
	{
		resumeTask(tid).then(() {
			host_.deliverBatchResults(tid);
		}).ignoreResult();
	}

	void resumeWaitingTask(int tid)
	{
		resumeTask(tid).ignoreResult();
	}

	void resumeActiveTask(int tid)
	{
		resumeTask(tid).then(() {
			host_.sendSystemRestartNudge(tid);
		}).ignoreResult();
	}

private:
	TaskData* requireTask(int tid, string message)
	{
		auto td = host_.getTask(tid);
		assert(td !is null, message);
		return td;
	}

	TaskTypeDef* currentTaskTypeDef(const TaskData* td)
	{
		return host_.taskTypeCatalog.getTaskTypesForProject(td.projectPath)
			.byName(td.taskType);
	}

	TaskTypeDef* currentOnYieldDef(const TaskData* td)
	{
		if (td.pendingContinuation !is null)
			return null;
		auto typeDef = currentTaskTypeDef(td);
		if (typeDef is null || typeDef.on_yield.task_type.length == 0)
			return null;
		return typeDef;
	}

	bool taskHasOnYield(const TaskData* td)
	{
		return currentOnYieldDef(td) !is null;
	}

	void cleanupTaskLaunch(TaskData* td)
	{
		import cydo.runtime.launch.sandbox : cleanup;

		cleanup(td.launch.sandbox);
	}

	string currentStatusForLog(int tid)
	{
		auto td = host_.getTask(tid);
		return td is null ? "(gone)" : td.status;
	}

	bool isMissingExecutableMessage(string message)
	{
		import std.algorithm : canFind;

		return message.canFind("No such file") || message.canFind("not found");
	}

	string buildLaunchFailureBody(int tid, string message)
	{
		import std.conv : to;
		import std.string : toUpper;

		auto td = requireTask(tid, "Task must exist while rendering launch failure");
		if (isMissingExecutableMessage(message))
		{
			auto ta = host_.tryAgentForTask(tid);
			string binEnvVar;
			string installHint;
			if (ta is null)
			{
				binEnvVar = "CYDO_" ~ td.agentType.toUpper ~ "_BIN";
				installHint = "the appropriate package for your agent";
			}
			else
			{
				binEnvVar = "CYDO_" ~ to!string(ta.driver).toUpper ~ "_BIN";
				final switch (ta.driver)
				{
				case AgentDriver.claude:
					installHint = "`npm install -g @anthropic-ai/claude-code`";
					break;
				case AgentDriver.codex:
					installHint = "`npm install -g @openai/codex`";
					break;
				case AgentDriver.copilot:
					installHint = "the appropriate package for your agent";
					break;
				}
			}
			return "The **`" ~ td.agentType ~ "`** CLI was not found on `PATH`.\n\n"
				~ "Install it (e.g. via " ~ installHint ~ ") or set the `"
				~ binEnvVar ~ "` environment variable to its absolute path, "
				~ "then click **Resume** again.";
		}

		return "Failed to resume session.\n\n```\n"
			~ message ~ "\n```";
	}

	string buildLaunchFailureBody(int tid, Exception e)
	{
		return buildLaunchFailureBody(tid,
			e.classinfo.name ~ ": " ~ e.msg);
	}
}

version (unittest) private final class LinkedWorktreeSandboxTestAgent : ClaudeCodeAgent
{
	override string executableName(string[string] env)
	{
		return "/bin/true";
	}
}

version (unittest) private void assertLinkedWorktreeGitMetadataMode(
	string fixtureName, string taskTypeName, PathMode expectedMode,
	bool projectIsMasked = false)
{
	withGitMetadataLaunchFixture(fixtureName,
		(GitMetadataLaunchFixture fixture) {
			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  writable:\n"
				~ "    model_class: large\n"
				~ "  readonly:\n"
				~ "    model_class: large\n"
				~ "    read_only: true\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto reachesWorktree = catalog.reachesWorktreeFor(fixture.linkedCheckout);
			assert(reachesWorktree !is null);
			assert(!reachesWorktree["writable"]);
			assert(!reachesWorktree["readonly"]);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = taskTypeName;
			tasks[1].agentType = "claude";
			assert(!tasks[1].hasWorktree);

			auto workspaceSandbox = unrestrictedLaunchTestSandbox();
			if (projectIsMasked)
				workspaceSandbox.paths[fixture.linkedCheckout] = expectedMode;

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				workspaceSandbox, "", fixture.linkedCheckout);
			auto typeDef = taskTypes.byName(taskTypeName);
			assert(typeDef !is null);
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			auto projectMode = fixture.linkedCheckout in launch.processLaunch.sandbox.paths;
			auto gitDirMode = fixture.linkedGitDir in launch.processLaunch.sandbox.paths;
			auto gitCommonDirMode = fixture.commonGitDir in launch.processLaunch.sandbox.paths;
			assert(projectMode !is null, "linked worktree checkout is not mounted");
			assert(*projectMode == expectedMode);
			if (projectIsMasked)
			{
				assert(gitDirMode is null, "masked checkout granted its git dir");
				assert(gitCommonDirMode is null, "masked checkout granted its common git dir");
			}
			else
			{
				assert(gitDirMode !is null, "linked worktree git dir is not mounted");
				assert(gitCommonDirMode !is null, "linked worktree common git dir is not mounted");
				assert(*gitDirMode == *projectMode);
				assert(*gitCommonDirMode == *projectMode);
			}
		});
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-writable", "writable", PathMode.rw);
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-readonly", "readonly", PathMode.ro);
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-tmpfs", "writable", PathMode.tmpfs, true);
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-empty-dir", "writable", PathMode.empty_dir, true);
}

unittest
{
	assertLinkedWorktreeGitMetadataMode(
		"cydo-task-runner-linked-worktree-empty-file", "writable", PathMode.empty_file, true);
}

version (unittest) private struct GitMetadataLaunchFixture
{
	string root;
	string workspaceRoot;
	string primaryRepo;
	string linkedCheckout;
	string linkedGitDir;
	string commonGitDir;
}

version (unittest) private void withGitMetadataLaunchFixture(string fixtureName,
	void delegate(GitMetadataLaunchFixture fixture) test)
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, write;
	import std.process : environment;

	auto root = buildPath("/tmp", fixtureName);
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto oldHome = environment.get("HOME", "");
	auto hadHome = "HOME" in environment;
	scope (exit)
	{
		if (hadHome)
			environment["HOME"] = oldHome;
		else
			environment.remove("HOME");
	}
	environment["HOME"] = buildPath(root, "home");

	auto workspaceRoot = buildPath(root, "workspace");
	auto primaryRepo = buildPath(workspaceRoot, "primary");
	auto linkedCheckout = buildPath(workspaceRoot, "linked");
	mkdirRecurse(primaryRepo);
	assert(execute(["git", "-C", primaryRepo, "init", "-q"]).status == 0);
	assert(execute(["git", "-C", primaryRepo, "config", "user.email", "test@example.com"])
		.status == 0);
	assert(execute(["git", "-C", primaryRepo, "config", "user.name", "CyDo Test"])
		.status == 0);
	write(buildPath(primaryRepo, "README.md"), "linked worktree fixture\n");
	assert(execute(["git", "-C", primaryRepo, "add", "README.md"]).status == 0);
	assert(execute(["git", "-C", primaryRepo, "commit", "-qm", "initial fixture"])
		.status == 0);
	assert(execute(["git", "-C", primaryRepo, "worktree", "add", "--detach", linkedCheckout])
		.status == 0);

	string gitPath(string checkoutPath, string flag)
	{
		auto result = execute(["git", "-C", checkoutPath, "rev-parse",
			"--path-format=absolute", flag]);
		assert(result.status == 0, result.output);
		return result.output.strip;
	}

	GitMetadataLaunchFixture fixture;
	fixture.root = root;
	fixture.workspaceRoot = workspaceRoot;
	fixture.primaryRepo = primaryRepo;
	fixture.linkedCheckout = linkedCheckout;
	fixture.linkedGitDir = gitPath(linkedCheckout, "--git-dir");
	fixture.commonGitDir = gitPath(linkedCheckout, "--git-common-dir");
	assert(fixture.linkedGitDir != fixture.commonGitDir);
	assert(fixture.commonGitDir == buildPath(primaryRepo, ".git"));
	test(fixture);
}

version (unittest) private TaskTypeCatalog gitMetadataTaskCatalog(
	GitMetadataLaunchFixture fixture, string yaml)
{
	import std.file : mkdirRecurse, write;

	auto defsDir = buildPath(fixture.root, "defs");
	mkdirRecurse(buildPath(defsDir, "prompts"));
	write(buildPath(defsDir, "prompts", "blank.md"), "Blank prompt\n");
	write(buildPath(defsDir, "task-types.yaml"), yaml);
	return new TaskTypeCatalog(defsDir, buildPath(defsDir, "task-types.yaml"),
		(string name) => name == "claude");
}

version (unittest) private SandboxConfig unrestrictedLaunchTestSandbox()
{
	import configy.attributes : SetInfo;

	return SandboxConfig(
		isolate_filesystem: SetInfo!bool(false),
		isolate_processes: SetInfo!bool(false),
		isolate_environment: SetInfo!bool(false),
	);
}

version (unittest) private TaskSessionRunner gitMetadataTestRunner(
	TaskData[int]* tasks, TaskTypeCatalog catalog, GitMetadataLaunchFixture fixture,
	SandboxConfig workspaceSandbox, string worktreePath, string taskCwd)
{
	return new TaskSessionRunner(TaskSessionRunnerHost(
		getTask: (int tid) {
			auto task = tid in *tasks;
			return task is null ? null : &(*tasks)[tid];
		},
		taskDir: (const TaskData* td) => buildPath(fixture.root, "tasks", "task"),
		outputPath: (const TaskData* td) => buildPath(fixture.root, "tasks", "task", "output.md"),
		effectiveCwd: (const TaskData* td) => taskCwd,
		worktreePath: (const TaskData* td) => worktreePath,
		globalSandbox: () => unrestrictedLaunchTestSandbox(),
		findWorkspaceSandbox: (string workspaceName) => workspaceSandbox,
		findWorkspaceRoot: (string workspaceName) => fixture.workspaceRoot,
		findWorkspacePermissionPolicy: (string workspaceName) => "",
		findAgentSandbox: (string agentName) => unrestrictedLaunchTestSandbox(),
		reportMcpToolDescriptionLimit: (string projectPath, string taskType,
			ToolDescriptionViolation[] violations) {},
		resolveSharedTmpPath: (int tid) => "",
		mcpSocketPath: () => "",
		taskTypeCatalog: catalog,
	));
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-managed-linked-worktree",
		(GitMetadataLaunchFixture fixture) {
			auto managedCheckout = buildPath(fixture.workspaceRoot, "managed");
			assert(execute(["git", "-C", fixture.primaryRepo, "worktree", "add", "--detach",
				managedCheckout]).status == 0);
			auto managedGitDir = execute(["git", "-C", managedCheckout, "rev-parse",
				"--path-format=absolute", "--git-dir"]);
			assert(managedGitDir.status == 0, managedGitDir.output);

			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  managed:\n"
				~ "    model_class: large\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto typeDef = taskTypes.byName("managed");
			assert(typeDef !is null);
			auto reachesWorktree = catalog.reachesWorktreeFor(fixture.linkedCheckout);
			assert(reachesWorktree !is null && !reachesWorktree["managed"]);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "managed";
			tasks[1].agentType = "claude";
			tasks[1].worktreeTid = 1;

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), managedCheckout, managedCheckout);
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			auto workDirMode = fixture.linkedCheckout in launch.processLaunch.sandbox.paths;
			auto baseGitMode = fixture.linkedGitDir in launch.processLaunch.sandbox.paths;
			auto worktreeMode = managedCheckout in launch.processLaunch.sandbox.paths;
			auto managedGitMode = managedGitDir.output.strip in launch.processLaunch.sandbox.paths;
			auto commonGitMode = fixture.commonGitDir in launch.processLaunch.sandbox.paths;
			assert(workDirMode !is null);
			assert(baseGitMode !is null);
			assert(worktreeMode !is null);
			assert(managedGitMode !is null);
			assert(commonGitMode !is null);
			assert(*workDirMode == PathMode.ro);
			assert(*baseGitMode == PathMode.ro);
			assert(*worktreeMode == PathMode.rw);
			assert(*managedGitMode == PathMode.rw);
			assert(*commonGitMode == PathMode.rw);
		});
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-reaches-worktree-git-metadata",
		(GitMetadataLaunchFixture fixture) {
			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  parent:\n"
				~ "    model_class: large\n"
				~ "    read_only: true\n"
				~ "    creatable_tasks:\n"
				~ "      child:\n"
				~ "        task_type: child\n"
				~ "        worktree: require\n"
				~ "        prompt_template: prompts/blank.md\n"
				~ "  child:\n"
				~ "    model_class: large\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto typeDef = taskTypes.byName("parent");
			assert(typeDef !is null);
			auto reachesWorktree = catalog.reachesWorktreeFor(fixture.linkedCheckout);
			assert(reachesWorktree !is null && reachesWorktree["parent"]);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "parent";
			tasks[1].agentType = "claude";

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), "", fixture.linkedCheckout);
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			auto workDirMode = fixture.linkedCheckout in launch.processLaunch.sandbox.paths;
			auto gitDirMode = fixture.linkedGitDir in launch.processLaunch.sandbox.paths;
			auto commonGitMode = fixture.commonGitDir in launch.processLaunch.sandbox.paths;
			assert(workDirMode !is null);
			assert(gitDirMode !is null);
			assert(commonGitMode !is null);
			assert(*workDirMode == PathMode.ro);
			assert(*gitDirMode == PathMode.always_rw);
			assert(*commonGitMode == PathMode.always_rw);
		});
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-non-git-managed-worktree",
		(GitMetadataLaunchFixture fixture) {
			import std.algorithm : canFind;
			import std.file : mkdirRecurse;

			auto worktreePath = buildPath(fixture.root, "plain-worktree");
			mkdirRecurse(worktreePath);

			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  managed:\n"
				~ "    model_class: large\n");
			auto taskTypes = catalog.getTaskTypesForProject(fixture.linkedCheckout);
			auto typeDef = taskTypes.byName("managed");
			assert(typeDef !is null);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", fixture.linkedCheckout);
			tasks[1].taskType = "managed";
			tasks[1].agentType = "claude";
			tasks[1].worktreeTid = 1;

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), worktreePath, worktreePath);
			bool threw;
			try
				runner.prepareTaskSessionLaunch(1, new LinkedWorktreeSandboxTestAgent(), typeDef);
			catch (Exception e)
			{
				threw = true;
				assert(e.msg.canFind(worktreePath));
				assert(e.msg.canFind("--git-dir"));
			}
			assert(threw);
		});
}

unittest
{
	withGitMetadataLaunchFixture("cydo-task-runner-non-git-reaches-worktree",
		(GitMetadataLaunchFixture fixture) {
			import std.file : mkdirRecurse;

			auto projectPath = buildPath(fixture.workspaceRoot, "plain-project");
			mkdirRecurse(projectPath);

			auto catalog = gitMetadataTaskCatalog(fixture,
				"task_types:\n"
				~ "  parent:\n"
				~ "    model_class: large\n"
				~ "    creatable_tasks:\n"
				~ "      child:\n"
				~ "        task_type: child\n"
				~ "        worktree: require\n"
				~ "        prompt_template: prompts/blank.md\n"
				~ "  child:\n"
				~ "    model_class: large\n");
			auto taskTypes = catalog.getTaskTypesForProject(projectPath);
			auto typeDef = taskTypes.byName("parent");
			assert(typeDef !is null);
			auto reachesWorktree = catalog.reachesWorktreeFor(projectPath);
			assert(reachesWorktree !is null && reachesWorktree["parent"]);

			TaskData[int] tasks;
			tasks[1] = TaskData(1, "local", projectPath);
			tasks[1].taskType = "parent";
			tasks[1].agentType = "claude";
			assert(!tasks[1].isGitCheckout);

			auto runner = gitMetadataTestRunner(&tasks, catalog, fixture,
				unrestrictedLaunchTestSandbox(), "", projectPath);
			// A non-Git project may launch a worktree-reaching parent; only an
			// actually requested worktree child can fail. No metadata is granted.
			auto launch = runner.prepareTaskSessionLaunch(1,
				new LinkedWorktreeSandboxTestAgent(), typeDef);
			auto projectMode = projectPath in launch.processLaunch.sandbox.paths;
			assert(projectMode !is null);
			assert(*projectMode == PathMode.rw);
			assert(fixture.commonGitDir !in launch.processLaunch.sandbox.paths);
		});
}
