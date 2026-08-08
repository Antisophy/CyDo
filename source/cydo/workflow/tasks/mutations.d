module cydo.workflow.tasks.mutations;

import core.lifetime : move;

import std.exception : enforce;
import std.file : exists, readText;
import std.logger : warningf;
import std.string : representation;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.utils.json : jsonParse, toJson;
import ae.utils.promise : Promise;
import ae.utils.statequeue : StateQueue;

import cydo.agent.contract : Agent, PersistedHistoryBoundaryKind;
import cydo.agent.drivers.codex : CodexActiveUserTurnsAfterStatus, CodexAgent,
	CodexSession, ThreadForkOutcome, ThreadRollbackOutcome,
	countActiveFallbackRecordsFromBoundary, countActiveUserTurnsAfterForkId;
import cydo.agent.session : AgentSession;
import cydo.domain.storage.persistence : Persistence, createForkTask;
import cydo.domain.task_types.definition : TaskTypeDef;
import cydo.domain.tasks.model : ArchiveState, ErrorMessage, ProcessState,
	TaskCreatedMessage, TaskData, TaskStatus, UndoPreviewMessage, UndoResultMessage,
	Watermark, WsMessage, watermarkFromPath;
import cydo.domain.tasks.lifecycle : TaskNotificationChange;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
import cydo.workflow.history.jsonl_edit : replaceUserMessageContent;
import cydo.workflow.history.operations : CodexForkSourceState, HistoryOperation,
	HistoryOperationMechanism, allowsFileRevert, allowsOperation,
	selectHistoryOperations;
import cydo.workflow.history.jsonl_store : countLinesAfterForkId,
	editJsonlMessage, forkTask, HistoryForkDestination, spliceJsonlByLine,
	truncateJsonl, writeJsonlPrefix;
import cydo.workflow.history.native_history : HistoryAccess,
	TaskHistoryResolution, TaskHistoryResolutionKind;
import cydo.workflow.sessions.task_runner : CodexForkSourceOperation,
	TaskSessionLaunch;
import cydo.runtime.launch.types : ProcessLaunch;
import cydo.runtime.launch.sandbox : cleanup;
import cydo.runtime.config : AgentDriver;

package(cydo):

alias MutationReply = void delegate(Data);

private struct MutationReplySocket
{
	MutationReply reply;
	void send(Data data) { reply(data); }
}


struct TaskMutationServiceHost
{
	TaskData* delegate(int tid) getTask;
	void delegate(int tid, TaskData td) putTask;
	void delegate(int tid) removeTask;

	Agent delegate(int tid) agentForTask;
	AgentSession delegate(int tid) sessionForTask;
	bool delegate(int tid) taskAlive;
	void delegate(int tid) stopTask;

	TaskSessionLaunch delegate(int tid, Agent taskAgent,
		TaskTypeDef* typeDef) prepareTaskSessionLaunch;
	TaskSessionLaunch delegate(int tid, Agent taskAgent,
		TaskTypeDef* typeDef) prepareOperationSessionLaunch;
	TaskTypeDef* delegate(string projectPath, string taskTypeName) taskTypeForProject;
	Promise!ProcessState delegate(ProcessState) delegate(int tid) makeProcessQueueSF;
	Promise!ArchiveState delegate(ArchiveState) delegate(int tid) makeArchiveQueueSF;

	Persistence* delegate() persistence;
	void delegate(int tid) deleteTask;
	void delegate(int tid, string agentSessionId) setAgentSessionId;
	void delegate(int tid, string relationType) setRelationType;
	void delegate(int tid, string title) setTitle;
	void delegate(int tid, TaskStatus expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTask;
	void delegate(int tid, TaskStatus[] expectedFrom, TaskStatus to,
		TaskNotificationChange notification) transitionTaskFrom;

	void delegate(int tid) ensureHistoryLoaded;
	TaskHistoryResolution delegate(int tid) resolveTaskHistory;
	void delegate(int tid, const ref TaskHistoryResolution resolution)
		reportUnavailableHistory;
	ProcessLaunch delegate(int tid, const ref HistoryAccess access)
		requireLiveHistoryLaunch;
	CodexForkSourceOperation delegate(int tid, const ref HistoryAccess access)
		openCodexForkSourceOperation;
	CodexForkSourceState delegate(int tid) codexForkSourceState;
	bool delegate(int tid, const ref HistoryAccess access,
		string requestedAnchor, out HistoryBoundary boundary)
		resolveFreshPersistedBoundary;
	HistoryForkDestination delegate(int sourceTid) prepareHistoryForkDestination;
	string delegate(int tid) getUndoJsonl;
	void delegate(int tid) clearUndoJsonl;
	void delegate(int tid) invalidateJsonlLineage;
	void delegate(int tid) startJsonlWatch;
	void delegate(int tid) stopJsonlWatch;

	void delegate(int tid) generateSuggestions;
	void delegate(int tid) unsubscribeTaskHistorySubscribers;
	void delegate(int tid, string reason) emitTaskReload;
	void delegate(TaskCreatedMessage message) broadcastTaskCreated;
	void delegate(int tid) broadcastTaskUpdate;
	void delegate(int fromTid, int toTid) broadcastFocusHint;
}

class TaskMutationService
{
private:
	TaskMutationServiceHost host_;

public:
	this(TaskMutationServiceHost host)
	{
		host_ = host;
	}

	void handleForkTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		if (td.agentSessionId.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
			return;
		}

		HistoryAccess source;
		if (!requireHistoryAccess(MutationReplySocket((Data data) => ws.send(data)), tid,
			"Fork failed: task history file not found", source))
			return;
		auto ta = source.agent;
		HistoryBoundary boundary;
		if (!host_.resolveFreshPersistedBoundary(tid, source, json.after_uuid, boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}
		auto codexSession = cast(CodexSession) host_.sessionForTask(tid);
		auto operations = selectHistoryOperations(ta.driver,
			host_.codexForkSourceState(tid));
		if (!allowsOperation(boundary, operations, HistoryOperation.fork))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}
		auto mechanism = boundary.kind == HistoryBoundaryKind.user
			? operations.fork.user : operations.fork.agent_turn;
		if (mechanism == HistoryOperationMechanism.codex_native)
		{
			auto ca = cast(CodexAgent) ta;
			assert(ca !is null, "Codex-native fork requires Codex agent");
			if (codexSession !is null)
			{
				beginCodexNativeFork(ws, tid, source, boundary, ca, codexSession, null);
				return;
			}
			CodexForkSourceOperation operation;
			try
				operation = host_.openCodexForkSourceOperation(tid, source);
			catch (Exception e)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: " ~ e.msg, tid)).representation));
				return;
			}
			operation.routeReady.then((CodexSession owner) {
				beginCodexNativeFork(ws, tid, source, boundary, ca, owner, operation);
			}, (Exception e) {
				operation.closeStdin();
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: " ~ e.msg, tid)).representation));
			}).ignoreResult();
			return;
		}

		enforce(ta.driver != AgentDriver.codex,
			"Codex history forks must use the native source-owner path");
		auto destination = host_.prepareHistoryForkDestination(tid);
		auto result = forkTask(*host_.persistence(), tid, source, boundary.anchor,
			td.projectPath, td.workspace, td.title, destination,
			&ta.rewriteSessionId, &ta.forkIdMatchesLine, td.description, td.taskType,
			td.agentName);
		if (result.tid < 0)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}

		import std.datetime : Clock;

		if (td.worktreeTid > 0)
			host_.persistence().setWorktreeTid(result.tid, td.worktreeTid);
		auto newTd = TaskData(result.tid, td.workspace, td.projectPath);
		newTd.title = td.title.length > 0 ? td.title ~ " (fork)" : "(fork)";
		newTd.agentSessionId = result.agentSessionId;
		newTd.parentTid = tid;
		newTd.relationType = "fork";
		newTd.status = TaskStatus.completed;
		newTd.agentName = td.agentName;
		newTd.description = td.description;
		newTd.taskType = td.taskType;
		newTd.worktreeTid = td.worktreeTid;
		newTd.createdAt = Clock.currStdTime;
		newTd.lastActive = newTd.createdAt;
		host_.putTask(result.tid, move(newTd));
		auto child = host_.getTask(result.tid);
		assert(child !is null, "Fork child task must exist after insertion");
		child.processQueue = new StateQueue!ProcessState(
			host_.makeProcessQueueSF(result.tid),
			ProcessState.Dead,
		);
		child.archiveQueue = new StateQueue!ArchiveState(
			host_.makeArchiveQueueSF(result.tid),
			ArchiveState.Unarchived,
		);
		child.history.reset(watermarkFromPath(result.destinationPath));

		host_.broadcastTaskCreated(TaskCreatedMessage("task_created", result.tid,
			td.workspace, td.projectPath, tid, "fork"));
		host_.broadcastTaskUpdate(result.tid);
		host_.broadcastFocusHint(tid, result.tid);
	}

	void handleUndoTaskMsg(WebSocketAdapter ws, WsMessage json)
	{
		handleUndoTaskMsg((Data data) => ws.send(data), json);
	}

	void handleUndoTaskMsg(MutationReply reply, WsMessage json)
	{
		auto ws = MutationReplySocket(reply);
		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		if (td.agentSessionId.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
			return;
		}

		HistoryAccess access;
		if (!requireHistoryAccess(ws, tid, "UUID not found in task history", access))
			return;
		auto ta = access.agent;
		HistoryBoundary boundary;
		if (!host_.resolveFreshPersistedBoundary(tid, access, json.after_uuid, boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
			return;
		}
		auto codexSourceState = host_.codexForkSourceState(tid);
		auto operations = selectHistoryOperations(ta.driver, codexSourceState);
		if (!allowsOperation(boundary, operations, HistoryOperation.undo))
		{
			ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
			return;
		}
		auto mechanism = boundary.kind == HistoryBoundaryKind.user
			? operations.undo.user : operations.undo.agent_turn;
		if (json.revert_files && !allowsFileRevert(boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error", "File revert is unavailable for this history boundary", tid)).representation));
			return;
		}
		if (json.dry_run)
		{
			if (mechanism == HistoryOperationMechanism.codex_native)
			{
				import std.file : exists, readText;

				auto jsonlPath = access.path;

				auto result = countActiveUserTurnsAfterForkId(readText(jsonlPath),
					boundary.anchor);
				final switch (result.status)
				{
					case CodexActiveUserTurnsAfterStatus.targetMissing:
						ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
						return;
					case CodexActiveUserTurnsAfterStatus.targetNotUser:
						ws.send(Data(toJson(ErrorMessage("error", "Undo target is not a user message", tid)).representation));
						return;
					case CodexActiveUserTurnsAfterStatus.ok:
						break;
				}
				ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid,
					result.count + 1)).representation));
				return;
			}
			if (cast(CodexAgent) ta !is null)
			{
				import std.file : exists, readText;

				auto jsonlPath = access.path;
				auto count = countActiveFallbackRecordsFromBoundary(readText(jsonlPath), boundary.anchor);
				if (count < 0)
				{
					ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
					return;
				}
				ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid, count)).representation));
				return;
			}

			auto count = countLinesAfterForkId(
				access.path,
				boundary.anchor,
				&ta.forkIdMatchesLine,
				&ta.isForkableLine);
			if (count < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
				return;
			}
			ws.send(Data(toJson(UndoPreviewMessage("undo_preview", tid,
				count + 1)).representation));
			return;
		}

		if (mechanism == HistoryOperationMechanism.codex_native)
		{
			auto ca = cast(CodexAgent) ta;
			assert(ca !is null, "Codex-native undo requires Codex agent");
			{
				import std.file : exists, readText;

				auto jsonlPath = access.path;

				auto result = countActiveUserTurnsAfterForkId(readText(jsonlPath),
					boundary.anchor);
				final switch (result.status)
				{
					case CodexActiveUserTurnsAfterStatus.targetMissing:
						ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
						return;
					case CodexActiveUserTurnsAfterStatus.targetNotUser:
						assert(false, "Codex-native undo policy permits only user boundaries");
					case CodexActiveUserTurnsAfterStatus.ok:
						break;
				}

				auto numTurns = cast(uint)(result.count + 1);
				host_.invalidateJsonlLineage(tid);

				auto rollbackLaunch = host_.requireLiveHistoryLaunch(tid, access);
				ca.rollbackThread(access.sessionId, numTurns, access.path, rollbackLaunch,
					td.workspace)
					.then((ThreadRollbackOutcome r) {
						if (!r.ok)
						{
							ws.send(Data(toJson(ErrorMessage("error",
								"Thread rollback failed: " ~ r.error, tid)).representation));
							return;
						}
						host_.clearUndoJsonl(tid);
						auto td2 = host_.getTask(tid);
						assert(td2 !is null,
							"Undo target task must exist after rollback");
						td2.history.reset(watermarkFromPath(access.path));
						host_.unsubscribeTaskHistorySubscribers(tid);

						if (td2.pendingSteeringTexts.length > 0)
						{
							import std.file : exists, readText;

							auto histPath = access.path;
						if (histPath.exists)
						{
							auto boundaries = ta.extractPersistedHistoryBoundaries(
								readText(histPath));
								int remaining = 0;
								foreach (ref f; boundaries)
									if (f.kind == PersistedHistoryBoundaryKind.user)
										remaining++;
								if (remaining < cast(int) td2.pendingSteeringTexts.length)
									td2.pendingSteeringTexts =
										td2.pendingSteeringTexts[0 .. remaining].dup;
							}
						}

						ws.send(Data(toJson(UndoResultMessage("undo_result", tid, "")).representation));
						if (auto session = host_.sessionForTask(tid))
							session.invalidatePendingSubmittedMessages();
						host_.emitTaskReload(tid, "");
						host_.startJsonlWatch(tid);
						host_.broadcastTaskUpdate(tid);
					}).ignoreResult();
				return;
			}

		}

		if (host_.taskAlive(tid))
		{
			auto liveLaunch = host_.requireLiveHistoryLaunch(tid, access);
			fallbackUndoKillAndTruncate(ws, tid, json, boundary, mechanism, access,
				liveLaunch);
			return;
		}

		if (auto session = host_.sessionForTask(tid))
			session.invalidatePendingSubmittedMessages();
		performUndoExecution(ws, tid, json, boundary, mechanism, access,
			ProcessLaunch.init, ta.driver == AgentDriver.codex
			&& codexSourceState == CodexForkSourceState.dead);
	}

	void handleEditMessage(WebSocketAdapter ws, WsMessage json)
	{
		import std.algorithm : startsWith;

		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		if (td.agentSessionId.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
			return;
		}
		if (host_.taskAlive(tid))
		{
			ws.send(Data(toJson(ErrorMessage("error", "Stop the session before editing messages", tid)).representation));
			return;
		}

		HistoryAccess access;
		if (!requireHistoryAccess(MutationReplySocket((Data data) => ws.send(data)), tid,
			"Message UUID not found in history", access))
			return;
		auto ta = access.agent;
		auto jsonlPath = access.path;
		auto newContent = json.content.json !is null ? jsonParse!string(json.content.json) : "";
		auto targetUuid = json.after_uuid;
		string fallbackUuid;
		if (targetUuid.startsWith("enqueue-"))
		{
			host_.ensureHistoryLoaded(tid);
			fallbackUuid = td.checkpointUuidForAnchor(targetUuid);
		}
		if (targetUuid.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Message UUID not found in history", tid)).representation));
			return;
		}

		auto edited = editJsonlMessage(jsonlPath, targetUuid,
			&ta.forkIdMatchesLine,
			(string line) => replaceUserMessageContent(line, newContent));
		if (!edited && fallbackUuid.length > 0)
		{
			edited = editJsonlMessage(jsonlPath, fallbackUuid,
				&ta.forkIdMatchesLine,
				(string line) => replaceUserMessageContent(line, newContent));
		}
		if (!edited)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Message UUID not found in history", tid)).representation));
			return;
		}

		host_.invalidateJsonlLineage(tid);
		td.history.reset(watermarkFromPath(jsonlPath));
		host_.unsubscribeTaskHistorySubscribers(tid);
		host_.emitTaskReload(tid, "edit");
		host_.broadcastTaskUpdate(tid);
	}

	void handleEditRawEvent(WebSocketAdapter ws, WsMessage json)
	{
		auto tid = json.tid;
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		if (td.agentSessionId.length == 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Task has no agent session ID", tid)).representation));
			return;
		}
		if (host_.taskAlive(tid))
		{
			ws.send(Data(toJson(ErrorMessage("error", "Stop the session before editing events", tid)).representation));
			return;
		}

		auto seq = json.seq;
		if (seq < 0)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Invalid seq number", tid)).representation));
			return;
		}

		host_.ensureHistoryLoaded(tid);
		if (seq >= td.history.length || td.history.rawAt(seq) is null)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Seq out of range or no raw source", tid)).representation));
			return;
		}

		auto sourceLine = td.history.sourceLineAt(seq);
		HistoryAccess access;
		if (!requireHistoryAccess(MutationReplySocket((Data data) => ws.send(data)), tid,
			"Raw event not found in JSONL file", access))
			return;
		auto ta = access.agent;
		auto jsonlPath = access.path;
		auto newContent = json.content.json !is null ? jsonParse!string(json.content.json) : "";

		string[] compactLines;
		try
		{
			compactLines = compactRawEventObjectSequence(newContent);
		}
		catch (Exception e)
		{
			ws.send(Data(toJson(ErrorMessage("error", e.msg, tid)).representation));
			return;
		}

		auto edited = spliceJsonlByLine(jsonlPath, sourceLine, compactLines);
		if (!edited)
		{
			ws.send(Data(toJson(ErrorMessage("error", "Raw event not found in JSONL file", tid)).representation));
			return;
		}

		host_.invalidateJsonlLineage(tid);
		td.history.reset(watermarkFromPath(jsonlPath));
		host_.unsubscribeTaskHistorySubscribers(tid);
		host_.emitTaskReload(tid, "edit");
		host_.broadcastTaskUpdate(tid);
	}

private:
	bool requireHistoryAccess(MutationReplySocket ws, int tid, string failure,
		out HistoryAccess access)
	{
		auto resolution = host_.resolveTaskHistory(tid);
		final switch (resolution.kind)
		{
		case TaskHistoryResolutionKind.access:
			access = resolution.requireAccess();
			return true;
		case TaskHistoryResolutionKind.unavailable:
			host_.reportUnavailableHistory(tid, resolution);
			break;
		case TaskHistoryResolutionKind.noSession:
		case TaskHistoryResolutionKind.orphanAgent:
			break;
		}
		ws.send(Data(toJson(ErrorMessage("error", failure, tid)).representation));
		return false;
	}

	private struct CodexNativeChildSpec
	{
		string titleSuffix;
		string emptyTitle;
		string relationType;
		string failurePrefix;
	}

	private alias CodexNativeChildMaterialized =
		void delegate(int childTid, string workspace, string projectPath);

	/// The Codex cold scanner recursively examines only profile.root/sessions.
	/// Keep the temporary thread/fork input inside the mounted profile root but
	/// outside that namespace, so it cannot impersonate a rollout during the
	/// native operation.
	private string makeCodexForkInputPath(const ref HistoryAccess source)
	{
		import std.algorithm : startsWith;
		import std.path : buildPath, isAbsolute;
		import std.uuid : randomUUID;

		enforce(source.profile.driver == AgentDriver.codex,
			"Codex native fork input requires a Codex history profile");
		auto sessionsRoot = buildPath(source.profile.root, "sessions");
		enforce(source.path.length > 0 && isAbsolute(source.path)
			&& source.path.startsWith(sessionsRoot ~ "/"),
			"Codex native fork source is not inside the captured sessions directory");
		auto inputPath = buildPath(source.profile.root,
			".cydo-fork-input-" ~ randomUUID().toString() ~ ".jsonl");
		enforce(!(inputPath == sessionsRoot || inputPath.startsWith(sessionsRoot ~ "/")),
			"Codex native fork input must not be cold-scanned as a session");
		return inputPath;
	}

	void beginCodexNativeFork(WebSocketAdapter ws, int tid, HistoryAccess source,
		HistoryBoundary boundary, CodexAgent ca, CodexSession forkOwner,
		CodexForkSourceOperation operation)
	{
		CodexNativeChildSpec childSpec;
		childSpec.titleSuffix = " (fork)";
		childSpec.emptyTitle = "(fork)";
		childSpec.relationType = "fork";
		childSpec.failurePrefix = "Fork failed";
		materializeCodexNativeChild(
			MutationReplySocket((Data data) => ws.send(data)), tid, source,
			boundary.anchor, ca, forkOwner, operation, childSpec,
			(int childTid, string workspace, string projectPath) {
				host_.broadcastTaskCreated(TaskCreatedMessage("task_created", childTid,
					workspace, projectPath, tid, "fork"));
				host_.broadcastTaskUpdate(childTid);
				host_.broadcastFocusHint(tid, childTid);
			},
		);
	}

	void materializeCodexNativeChild(MutationReplySocket ws, int tid,
		HistoryAccess source, string forkAnchor, CodexAgent ca,
		CodexSession forkOwner, CodexForkSourceOperation operation,
		CodexNativeChildSpec childSpec,
		CodexNativeChildMaterialized onMaterialized)
	{
		import std.datetime : Clock;
		import std.file : isFile, remove;
		import std.path : isAbsolute;
		import std.stdio : File;

		auto td = host_.getTask(tid);
		if (td is null)
		{
			if (operation !is null)
				operation.closeStdin();
			return;
		}
		assert(forkOwner !is null,
			"Codex-native fork requires its exact live source owner");
		enforce(forkAnchor.length > 0,
			"Codex-native fork requires a source boundary");
		enforce(childSpec.titleSuffix.length > 0 && childSpec.emptyTitle.length > 0
			&& childSpec.relationType.length > 0 && childSpec.failurePrefix.length > 0,
			"Codex-native child requires complete durable child metadata");
		enforce(onMaterialized !is null,
			"Codex-native child requires a completion continuation");

		auto sourceAgent = source.agent;
		auto sourcePath = source.path;
		auto sourceWorkspace = td.workspace.idup;
		auto sourceProjectPath = td.projectPath.idup;
		auto sourceTitle = td.title.idup;
		auto sourceDescription = td.description.idup;
		auto sourceTaskType = td.taskType.idup;
		auto sourceAgentName = td.agentName.idup;
		auto sourceWorktreeTid = td.worktreeTid;
		string prefixPath;
		int childTid = -1;
		ProcessLaunch childLaunch;
		bool ownsChildLaunch;
		bool settled;

		void removePrefix()
		{
			try
			{
				if (prefixPath.length > 0 && exists(prefixPath))
					remove(prefixPath);
			}
			catch (Exception)
			{
			}
		}

		void cleanupChildLaunch()
		{
			if (!ownsChildLaunch)
				return;
			ownsChildLaunch = false;
			cleanup(childLaunch.sandbox);
		}

		void cleanupFailure()
		{
			cleanupChildLaunch();
			removePrefix();
			if (childTid >= 0)
			{
				host_.removeTask(childTid);
				host_.deleteTask(childTid);
				childTid = -1;
			}
			if (operation !is null)
				operation.closeStdin();
		}

		void fail(string message)
		{
			if (settled)
				return;
			settled = true;
			cleanupFailure();
			ws.send(Data(toJson(ErrorMessage("error", childSpec.failurePrefix ~ ": " ~ message,
				tid)).representation));
		}

		try
		{
			prefixPath = makeCodexForkInputPath(source);
			if (!writeJsonlPrefix(sourcePath, prefixPath, forkAnchor,
				&sourceAgent.forkIdMatchesLine))
			{
				fail("message UUID not found in task history");
				return;
			}

			childTid = createForkTask(*host_.persistence(), tid, "", sourceProjectPath,
				sourceWorkspace, sourceTitle, sourceDescription, sourceTaskType,
				sourceAgentName);
			if (sourceWorktreeTid > 0)
				host_.persistence().setWorktreeTid(childTid, sourceWorktreeTid);
			auto newTd = TaskData(childTid, sourceWorkspace, sourceProjectPath);
			newTd.title = sourceTitle.length > 0
				? sourceTitle ~ childSpec.titleSuffix : childSpec.emptyTitle;
			newTd.parentTid = tid;
			newTd.relationType = childSpec.relationType;
			newTd.status = TaskStatus.completed;
			newTd.agentName = sourceAgentName;
			newTd.description = sourceDescription;
			newTd.taskType = sourceTaskType;
			newTd.worktreeTid = sourceWorktreeTid;
			newTd.createdAt = Clock.currStdTime;
			newTd.lastActive = newTd.createdAt;
			host_.setRelationType(childTid, childSpec.relationType);
			host_.setTitle(childTid, newTd.title);
			host_.putTask(childTid, move(newTd));
			auto child = host_.getTask(childTid);
			assert(child !is null, "Fork child task must exist after insertion");
			child.history.reset(Watermark.none());

			auto childAgent = host_.agentForTask(childTid);
			auto childTypeDef = host_.taskTypeForProject(child.projectPath,
				child.taskType);
			auto launch = host_.prepareOperationSessionLaunch(childTid, childAgent,
				childTypeDef);
			childLaunch = launch.processLaunch;
			ownsChildLaunch = true;
			enforce(childLaunch.nativeHistoryProfile.driver == source.profile.driver
				&& childLaunch.nativeHistoryProfile.root == source.profile.root,
				"Codex native fork child launch must use the captured source profile");

			auto fork = ca.forkSession(forkOwner, childTid, source.sessionId,
				prefixPath, childLaunch, launch.sessionConfig);
			fork.then((ThreadForkOutcome outcome) {
				if (settled)
					return;
				if (!outcome.ok)
				{
					fail(outcome.error);
					return;
				}

				bool releasedLease;
				try
				{
					enforce(outcome.historyLease !is null,
						"Codex native fork returned no history-path lease");
					auto historyPath = outcome.historyLease.path;
					enforce(historyPath.length > 0 && isAbsolute(historyPath),
						"Codex native fork returned a non-absolute history path");
					enforce(exists(historyPath) && isFile(historyPath),
						"Codex native fork returned an unreadable history path");
					auto readable = File(historyPath, "r");
					scope(exit) readable.close();

					auto currentChild = host_.getTask(childTid);
					assert(currentChild !is null,
						"Fork child task must exist until fork completion");
					currentChild.agentSessionId = outcome.threadId;
					host_.setAgentSessionId(childTid, outcome.threadId);
					currentChild.processQueue = new StateQueue!ProcessState(
						host_.makeProcessQueueSF(childTid), ProcessState.Dead);
					currentChild.archiveQueue = new StateQueue!ArchiveState(
						host_.makeArchiveQueueSF(childTid), ArchiveState.Unarchived);
					currentChild.history.reset(watermarkFromPath(historyPath));

					outcome.historyLease.release();
					releasedLease = true;
					removePrefix();
					cleanupChildLaunch();
					if (operation !is null)
						operation.closeStdin();
					settled = true;
					onMaterialized(childTid, sourceWorkspace, sourceProjectPath);
				}
				catch (Exception e)
				{
					if (!releasedLease && outcome.historyLease !is null)
						outcome.historyLease.release();
					fail(e.msg);
				}
			}, (Exception e) {
				fail(e.msg);
			}).ignoreResult();
		}
		catch (Exception e)
		{
			fail(e.msg);
		}
	}

	/// A JSONL undo keeps its outer truncate semantics, but a dead Codex source
	/// can create the durable pre-undo child only through the route-ready
	/// operation owner and its owner-bound thread/fork lease.
	void beginCodexJsonlUndoBackup(MutationReplySocket ws, int tid,
		HistoryAccess source, string lastForkId, void delegate() continueUndo)
	{
		auto codex = cast(CodexAgent) source.agent;
		assert(codex !is null && source.profile.driver == AgentDriver.codex,
			"Codex JSONL undo backup requires Codex history access");
		enforce(lastForkId.length > 0,
			"Codex JSONL undo backup requires the last persisted boundary");
		enforce(continueUndo !is null,
			"Codex JSONL undo backup requires a truncate continuation");

		CodexForkSourceOperation operation;
		try
			operation = host_.openCodexForkSourceOperation(tid, source);
		catch (Exception e)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Undo failed: pre-undo backup: " ~ e.msg, tid)).representation));
			return;
		}

		operation.routeReady.then((CodexSession owner) {
			CodexNativeChildSpec childSpec;
			childSpec.titleSuffix = " (pre-undo)";
			childSpec.emptyTitle = "(pre-undo)";
			childSpec.relationType = "undo-backup";
			childSpec.failurePrefix = "Undo failed: pre-undo backup";
			materializeCodexNativeChild(ws, tid, source, lastForkId, codex,
				owner, operation, childSpec,
				(int childTid, string workspace, string projectPath) {
					host_.broadcastTaskCreated(TaskCreatedMessage("task_created", childTid,
						workspace, projectPath, tid, "undo-backup"));
					host_.broadcastTaskUpdate(childTid);
					continueUndo();
				},
			);
		}, (Exception e) {
			operation.closeStdin();
			ws.send(Data(toJson(ErrorMessage("error",
				"Undo failed: pre-undo backup: " ~ e.msg, tid)).representation));
		}).ignoreResult();
	}

	static size_t findJsonObjectEnd(string input, size_t start)
	{
		assert(start < input.length && input[start] == '{');

		int depth = 0;
		bool inString = false;
		bool escaping = false;

		foreach (i, ch; input[start .. $])
		{
			if (inString)
			{
				if (escaping)
				{
					escaping = false;
					continue;
				}
				if (ch == '\\')
				{
					escaping = true;
					continue;
				}
				if (ch == '"')
					inString = false;
				continue;
			}

			switch (ch)
			{
				case '"':
					inString = true;
					break;
				case '{':
					depth++;
					break;
				case '}':
					depth--;
					if (depth == 0)
						return start + i + 1;
					break;
				default:
					break;
			}
		}

		throw new Exception("Invalid JSON in edited event");
	}

	static string[] compactRawEventObjectSequence(string input)
	{
		import std.ascii : isWhite;
		import std.json : JSONType, parseJSON;

		string[] compactLines;
		size_t pos = 0;
		while (true)
		{
			while (pos < input.length && input[pos].isWhite)
				pos++;
			if (pos >= input.length)
				return compactLines;
			if (input[pos] != '{')
				throw new Exception("Edited event must contain only JSON objects");

			auto end = findJsonObjectEnd(input, pos);
			try
			{
				auto parsed = parseJSON(input[pos .. end]);
				if (parsed.type != JSONType.object)
					throw new Exception("Edited event must contain only JSON objects");
				compactLines ~= parsed.toString();
			}
			catch (Exception e)
			{
				if (e.msg == "Edited event must contain only JSON objects")
					throw e;
				throw new Exception("Invalid JSON in edited event");
			}
			pos = end;
		}
	}

	unittest
	{
		import std.exception : assertThrown;
		import std.json : parseJSON;

		assert(compactRawEventObjectSequence(" \n\t ").length == 0);

		auto compact = compactRawEventObjectSequence(
			"{\n"
			~ "  \"message\": \"brace: } and quote: \\\\\\\"\",\n"
			~ "  \"nested\": {\"value\": 1}\n"
			~ "}\n"
			~ "{\"message\":\"two\"}{\"message\":\"three\"}");
		assert(compact.length == 3);
		assert(parseJSON(compact[0])["message"].str == `brace: } and quote: \"`);
		assert(parseJSON(compact[1])["message"].str == "two");
		assert(parseJSON(compact[2])["message"].str == "three");

		assertThrown!Exception(compactRawEventObjectSequence("null"));
		assertThrown!Exception(compactRawEventObjectSequence("{\"message\":1} trailing"));
		assertThrown!Exception(compactRawEventObjectSequence("{\"message\":"));
	}

	void fallbackUndoKillAndTruncate(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryOperationMechanism mechanism,
		HistoryAccess access, ProcessLaunch liveLaunch)
	{
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		auto ta = access.agent;

		auto jsonlPathSnap = access.path;
		auto jsonlSnap = host_.getUndoJsonl(tid);
		host_.clearUndoJsonl(tid);

		bool snapshotContainsUndoAnchor(string snapshot, string forkId)
		{
			import std.string : lineSplitter;

			if (snapshot.length == 0 || forkId.length == 0)
				return false;

			int lnum = 0;
			foreach (rawLine; snapshot.lineSplitter)
			{
				lnum++;
				if (rawLine.length == 0)
					continue;
				if (ta.forkIdMatchesLine(rawLine, lnum, forkId))
					return true;
			}
			return false;
		}

		td.undoStopInProgress = true;
		if (auto session = host_.sessionForTask(tid))
			session.invalidatePendingSubmittedMessages();
		td.processQueue.setGoal(ProcessState.Dead).then(() {
			if (jsonlSnap.length > 0 && jsonlPathSnap.length > 0 &&
				snapshotContainsUndoAnchor(jsonlSnap, boundary.anchor))
			{
				import std.file : write;

				write(jsonlPathSnap, jsonlSnap);
			}
			performUndoExecution(ws, tid, json, boundary, mechanism, access,
				liveLaunch, false);
		}).ignoreResult();
		host_.stopTask(tid);
	}

	void performUndoExecution(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryOperationMechanism mechanism,
		HistoryAccess access, ProcessLaunch capturedLiveLaunch,
		bool materializeDeadCodexBackup)
	{
		import std.algorithm : canFind, startsWith;

		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;

		auto ta = access.agent;
		assert(mechanism == HistoryOperationMechanism.jsonl,
			"JSONL undo execution requires the JSONL mechanism");
		auto rewindLaunch = capturedLiveLaunch;
		bool ownsFreshLaunch;
		if (json.revert_files && rewindLaunch.nativeHistoryProfile.root.length == 0)
		{
			auto typeDef = host_.taskTypeForProject(td.projectPath, td.taskType);
			auto fresh = host_.prepareTaskSessionLaunch(tid, ta, typeDef);
			rewindLaunch = fresh.processLaunch;
			td.launch = ProcessLaunch.init;
			ownsFreshLaunch = true;
		}
		scope(exit)
			if (ownsFreshLaunch)
				cleanup(rewindLaunch.sandbox);

		string rewindOutput;
		if (json.revert_files)
		{
			auto rewindResult = ta.rewindFiles(access.sessionId,
				boundary.checkpoint_uuid, access.effectiveCwd, rewindLaunch);
			if (rewindResult.success)
				rewindOutput = rewindResult.output;
			else if (!rewindResult.output.canFind("No file checkpoint found"))
			{
				ws.send(Data(toJson(ErrorMessage("error", "File revert failed: " ~ rewindResult.output, tid)).representation));
				return;
			}
		}

		if (json.revert_conversation)
		{
			import std.datetime : Clock;

			auto historyPath = access.path;
			auto boundaries = exists(historyPath)
				? ta.extractPersistedHistoryBoundaries(readText(historyPath)) : null;
			auto lastForkId = boundaries.length > 0 ? boundaries[$ - 1].anchor : null;
			if (lastForkId.length > 0)
			{
				if (materializeDeadCodexBackup)
				{
					beginCodexJsonlUndoBackup(ws, tid, access, lastForkId, () {
						finishUndoExecution(ws, tid, json, boundary, access,
							rewindOutput);
					});
					return;
				}
				auto destination = host_.prepareHistoryForkDestination(tid);
				auto backup = forkTask(*host_.persistence(), tid, access,
					lastForkId, td.projectPath, td.workspace, td.title, destination,
					&ta.rewriteSessionId, &ta.forkIdMatchesLine,
					td.description, td.taskType, td.agentName);
				if (backup.tid >= 0)
				{
					if (td.worktreeTid > 0)
						host_.persistence().setWorktreeTid(backup.tid, td.worktreeTid);
					auto bTd = TaskData(backup.tid, td.workspace, td.projectPath);
					bTd.title = td.title.length > 0 ? td.title ~ " (pre-undo)" : "(pre-undo)";
					bTd.agentSessionId = backup.agentSessionId;
					bTd.parentTid = tid;
					bTd.relationType = "undo-backup";
					bTd.status = TaskStatus.completed;
					bTd.agentName = td.agentName;
					bTd.description = td.description;
					bTd.taskType = td.taskType;
					bTd.worktreeTid = td.worktreeTid;
					bTd.createdAt = Clock.currStdTime;
					bTd.lastActive = bTd.createdAt;
					host_.setRelationType(backup.tid, "undo-backup");
					host_.setTitle(backup.tid, bTd.title);
					host_.putTask(backup.tid, move(bTd));
					auto backupTd = host_.getTask(backup.tid);
					assert(backupTd !is null,
						"Undo backup task must exist after insertion");
					backupTd.processQueue = new StateQueue!ProcessState(
						host_.makeProcessQueueSF(backup.tid),
						ProcessState.Dead,
					);
					backupTd.archiveQueue = new StateQueue!ArchiveState(
						host_.makeArchiveQueueSF(backup.tid),
						ArchiveState.Unarchived,
					);
					backupTd.history.reset(watermarkFromPath(backup.destinationPath));
					host_.broadcastTaskCreated(TaskCreatedMessage("task_created",
						backup.tid, td.workspace, td.projectPath, tid, "undo-backup"));
					host_.broadcastTaskUpdate(backup.tid);
				}
			}
		}

		finishUndoExecution(ws, tid, json, boundary, access, rewindOutput);
	}

	void finishUndoExecution(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryAccess access, string rewindOutput)
	{
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		auto ta = access.agent;

		if (json.revert_conversation)
		{
			auto histJsonlPath = access.path;
			auto removed = truncateJsonl(histJsonlPath, boundary.anchor,
				&ta.forkIdMatchesLine, true);
			if (removed < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"UUID not found for truncation", tid)).representation));
				return;
			}
			host_.invalidateJsonlLineage(tid);
			td.history.reset(watermarkFromPath(histJsonlPath));
			host_.unsubscribeTaskHistorySubscribers(tid);

			if (td.pendingSteeringTexts.length > 0)
			{
				import std.file : exists, readText;
				import std.string : splitLines;

				auto histPath = access.path;
				if (histPath.exists)
				{
					int remaining = 0;
					foreach (line; readText(histPath).splitLines())
						if (ta.isUserMessageLine(line))
							remaining++;
					if (remaining < cast(int) td.pendingSteeringTexts.length)
						td.pendingSteeringTexts = td.pendingSteeringTexts[0 .. remaining].dup;
				}
			}
		}

		ws.send(Data(toJson(UndoResultMessage("undo_result", tid, rewindOutput)).representation));
		host_.emitTaskReload(tid, "");

		if (json.revert_conversation && td.agentSessionId.length > 0)
		{
			td.processQueue.setGoal(ProcessState.Alive).then(() {
				auto current = host_.getTask(tid);
				assert(current !is null,
					"Undo task must exist while auto-resume is scheduled");
				host_.transitionTaskFrom(tid,
					[TaskStatus.pending, TaskStatus.alive, TaskStatus.waiting,
						TaskStatus.completed, TaskStatus.failed], TaskStatus.active,
					TaskNotificationChange.preserve);
				try
					host_.generateSuggestions(tid);
				catch (Exception e)
					warningf("Error generating suggestions: %s", e.msg);
			}).ignoreResult();
		}

		host_.broadcastTaskUpdate(tid);
	}
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import cydo.runtime.launch.types : NativeHistoryProfile;
	import std.file : remove, write;

	enum tid = 71;
	auto task = TaskData(tid, "local", "/tmp");
	task.agentName = "claude";
	task.agentSessionId = "session";
	Agent agent = new ClaudeCodeAgent();
	auto historyPath = "/tmp/cydo-mutations-undo-resolution.jsonl";
	write(historyPath, "");
	scope(exit) remove(historyPath);
	int replies;
	int sideEffects;
	enum Resolution { forged, stale, noCheckpoint }
	Resolution resolution;

	TaskMutationServiceHost host;
	host.getTask = (int value) => value == tid ? &task : null;
	host.agentForTask = (int) => agent;
	host.sessionForTask = (int) => null;
	host.taskAlive = (int) => false;
	host.codexForkSourceState = (int) => CodexForkSourceState.dead;
	host.stopTask = (int) { sideEffects++; assert(false); };
	host.resolveTaskHistory = (int) => TaskHistoryResolution.access(HistoryAccess(
		agent, NativeHistoryProfile(agent.driver, "/tmp"), task.agentSessionId,
		"/tmp", historyPath));
	host.clearUndoJsonl = (int) { sideEffects++; assert(false); };
	host.invalidateJsonlLineage = (int) { sideEffects++; assert(false); };
	host.startJsonlWatch = (int) { sideEffects++; assert(false); };
	host.unsubscribeTaskHistorySubscribers = (int) { sideEffects++; assert(false); };
	host.emitTaskReload = (int, string) { sideEffects++; assert(false); };
	host.broadcastTaskUpdate = (int) { sideEffects++; assert(false); };
	host.transitionTaskFrom = (int, TaskStatus[], TaskStatus, TaskNotificationChange) {
		sideEffects++; assert(false);
	};
	host.generateSuggestions = (int) { sideEffects++; assert(false); };
	host.resolveFreshPersistedBoundary = (int, const ref HistoryAccess access,
		string, out HistoryBoundary boundary) {
		if (resolution != Resolution.noCheckpoint)
			return false;
		boundary = HistoryBoundary("assistant", HistoryBoundaryKind.agent_turn, "");
		return true;
	};

	auto service = new TaskMutationService(host);
	void delegate(Data) reply = (Data) { replies++; };

	foreach (dryRun; [true, false])
	{
		resolution = Resolution.forged;
		service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
			after_uuid: "line:999999", dry_run: dryRun,
			revert_conversation: true));
	}
	assert(replies == 2);
	assert(sideEffects == 0);

	// A syntactically plausible line anchor which was invalidated by rollback is
	// rejected by fresh resolution before either preview or execution can mutate.
	foreach (dryRun; [true, false])
	{
		resolution = Resolution.stale;
		service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
			after_uuid: "line:4", dry_run: dryRun, revert_conversation: true));
	}
	assert(replies == 4);
	assert(sideEffects == 0);

	// A resolved assistant boundary is valid for conversation undo but never for
	// file rewind; both preview and confirmation reject the forged file request.
	foreach (dryRun; [true, false])
	{
		resolution = Resolution.noCheckpoint;
		service.handleUndoTaskMsg(reply, WsMessage(type: "undo_task", tid: tid,
			after_uuid: "assistant", dry_run: dryRun, revert_conversation: true,
			revert_files: true));
	}
	assert(replies == 6);
	assert(sideEffects == 0);
}
