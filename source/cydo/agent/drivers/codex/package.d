module cydo.agent.drivers.codex;

import core.time : Duration, msecs, seconds;

import std.algorithm : startsWith;
import std.conv : to;
import std.exception : enforce;
import std.logger : errorf, tracef, warningf;
import std.path : buildPath, dirName, isAbsolute;

import ae.sys.data : Data;
import ae.sys.timing : setTimeout, TimerTask;
import ae.utils.time.types : AbsTime;
import ae.utils.json : JSONExtras, JSONFragment, JSONOptional, JSONPartial,
	jsonParse, toJson;
import ae.utils.serialization.json : JSONName;
import ae.utils.jsonrpc : JsonRpcResponse;
import ae.utils.serialization.store : SerializedObject;

private alias SO = SerializedObject!(immutable char);
import ae.utils.promise : Promise, resolve;
import ae.net.asockets : onNextTick, socketManager;

version (unittest) import ae.net.asockets : ConnectionState, DisconnectType,
	IConnection;
version (unittest) import ae.utils.jsonrpc : JsonRpcRequest;

import cydo.agent.contract : Agent, DiscoveredSession, PersistedHistoryBoundary, OneShotHandle, RewindResult, SessionConfig, SessionMeta;
import cydo.agent.process : AgentProcess, FramingMode;
import cydo.agent.drivers.codex.app_server : CodexSessionRouteTarget;
public import cydo.agent.drivers.codex.process : AppServerProcess;
public import cydo.agent.drivers.codex.rollout;
public import cydo.agent.drivers.codex.rpc;
import cydo.protocol : ContentBlock, ProcessStderrEvent, SessionCompactedEvent,
	TranslatedEvent, extrasToFragment;
import cydo.agent.session : AgentSession, AgentSubmissionReceipt;
import cydo.runtime.config : AgentDriver, ModelSpec, ModelSpecFields;
import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
	SandboxPathOriginKind, SandboxPaths;
import cydo.runtime.launch.types : NativeHistoryProfile, NativeHistoryRule,
	ProcessLaunch;
import cydo.runtime.launch.sandbox : cleanup, cydoBinaryDir, cydoBinaryPath, effectiveEnvValue,
	executableMountPaths, resolveExecutablePath;
import launchSandbox = cydo.runtime.launch.sandbox;
import cydo.foundation.text.title : truncateTitle;

// ---------------------------------------------------------------------------
// CodexAgent — Agent descriptor for OpenAI Codex CLI.
// ---------------------------------------------------------------------------

private struct CodexHistoryKey
{
	string root;
	string sessionId;
}

private struct CodexLiveHistoryPath
{
	CodexSession owner;
	string path;
}

final class CodexForkPathLease
{
private:
	CodexSession owner_;
	CodexHistoryKey key_;
	string path_;
	bool released_;

public:
	this(CodexSession owner, CodexHistoryKey key, string path)
	{
		owner_ = owner;
		key_ = key;
		path_ = path;
	}

	@property string path()
	{
		enforce(!released_, "Codex fork history path lease was released");
		return path_;
	}

	void release()
	{
		if (released_)
			return;
		owner_.releaseForkPath(this);
	}
}

struct ThreadForkOutcome
{
	bool ok;
	string threadId;
	CodexForkPathLease historyLease;
	string rawResultJson;
	string error;
}

/// A real, private source-thread owner used only to issue a native fork after
/// the normal task session has been stopped. It is route-ready only after the
/// app server has registered the exact resumed thread route.
final class CodexForkSourceOwner
{
private:
	CodexSession session_;
	string sourceThreadId_;
	Promise!CodexSession routeReady_;
	bool routeReadySettled_;
	bool closing_;
	bool closed_;
	void delegate() closedHandler_;

public:
	this(CodexSession session, string sourceThreadId)
	{
		enforce(session !is null,
			"Codex fork source owner requires a Codex session");
		enforce(sourceThreadId.length > 0,
			"Codex fork source owner requires a source thread ID");
		session_ = session;
		sourceThreadId_ = sourceThreadId;
		routeReady_ = new Promise!CodexSession;
		session_.onRouteReady = {
			if (routeReadySettled_)
				return;
			try
			{
				enforce(session_.alive,
					"Codex fork source owner exited before its route was ready");
				enforce(session_.currentThreadId == sourceThreadId_,
					"Codex fork source owner resumed a different thread");
				routeReadySettled_ = true;
				routeReady_.fulfill(session_);
			}
			catch (Exception e)
			{
				routeReadySettled_ = true;
				routeReady_.reject(e);
				closeStdin();
			}
		};
		session_.onExit = (int) {
			if (!routeReadySettled_)
			{
				routeReadySettled_ = true;
				routeReady_.reject(new Exception(
					"Codex fork source owner exited before its route was ready"));
			}
			notifyClosed();
		};
	}

	@property Promise!CodexSession routeReady() { return routeReady_; }

	void closeStdin()
	{
		if (closed_ || closing_)
			return;
		closing_ = true;
		if (!routeReadySettled_)
		{
			routeReadySettled_ = true;
			routeReady_.reject(new Exception(
				"Codex fork source owner closed before its route was ready"));
		}
		session_.closeStdin();
		if (!session_.alive)
			notifyClosed();
	}

	@property void onClosed(void delegate() handler)
	{
		closedHandler_ = handler;
		if (closed_ && closedHandler_)
			closedHandler_();
	}

private:
	void notifyClosed()
	{
		if (closed_)
			return;
		closed_ = true;
		if (closedHandler_)
			closedHandler_();
	}
}

private enum RouteOwnerKind { task, forkOperation }

class CodexAgent : Agent
{
	private AppServerProcess[string] serverPool; // keyed by workspace+sandbox signature
	private AppServerStartupGate[string] appServerStartupGates;
	private ModelSpec[string] modelAliasOverrides;
	private string lastMcpConfigPath_;
	private CodexLiveHistoryPath[CodexHistoryKey] liveHistoryPaths_;
	// History replay state: tracks whether task_started has been seen in the current replay.
	private bool histSeenTaskStarted_;

	void resetHistoryReplay()
	{
		histSeenTaskStarted_ = false;
	}

	void configureSandbox(ref SandboxPaths paths, ref string[string] env)
	{
		import std.process : environment;

		auto codexPath = resolveExecutablePath(executableName(env), env);
		foreach (path; executableMountPaths(codexPath))
			paths.requireReadVisible(path,
				SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "codex",
					"Codex executable"));
		auto home = environment.get("HOME", "/tmp");
		if (dirName(codexPath) == home ~ "/.npm-packages/bin")
			paths.requireReadVisible(home ~ "/.npm-packages",
				SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "codex",
					"Codex npm package root"));

		paths.requireReadVisible(cydoBinaryDir(),
			SandboxPathOrigin(SandboxPathOriginKind.agentRequirement, "codex",
				"CyDo binary"));

		// Pass through Codex-required env vars so they survive --clearenv
		void passthrough(string key)
		{
			if (key in env)
				return;
			auto val = environment.get(key, "");
			if (val.length > 0)
				env[key] = val;
		}

		passthrough("PATH");
		passthrough("OPENAI_API_KEY");
		passthrough("OPENAI_BASE_URL");
		passthrough("CODEX_API_KEY");
	}

	@property string gitName() { return "Codex CLI"; }
	@property string gitEmail() { return "noreply@openai.com"; }
	override @property AgentDriver driver() { return AgentDriver.codex; }
	override @property NativeHistoryRule nativeHistoryRule()
	{
		return NativeHistoryRule(AgentDriver.codex, "CODEX_HOME", ".codex", null);
	}
	@property string lastMcpConfigPath() { return lastMcpConfigPath_; }
	string executableName(string[string] env)
	{
		return effectiveEnvValue(env, "CYDO_CODEX_BIN", "codex");
	}

	private string serverPoolKey(string workspace, ProcessLaunch launch)
	{
		import std.regex : regex, replaceAll;
		auto prefixSig = launch.cmdPrefix is null ? "[]" : toJson(launch.cmdPrefix);
		// Task-local scratch paths differ by tid but are safe to share across
		// Codex threads in the same workspace; ignore only that variance.
		prefixSig = replaceAll(prefixSig, regex(`/\.cydo\/tasks\/\d+/`), "/.cydo/tasks/*");
		return workspace ~ "\n" ~ launch.executablePath ~ "\n" ~ prefixSig;
	}

	private static string buildDeveloperInstructions()
	{
		string devInstructions = "IMPORTANT: Do NOT use the following tools: "
			~ "spawn_agent,update_plan,request_user_input"
			~ ". If you attempt to use them, they will fail.";
		return devInstructions;
	}

	AgentSession createSession(int tid, string resumeSessionId, ProcessLaunch launch,
		SessionConfig config = SessionConfig.init)
	{
		auto workspace = config.workspace.length > 0 ? config.workspace : "default";
		auto server = getOrCreateServer(serverPoolKey(workspace, launch), launch);
		auto session = makeSession(server, tid, config, RouteOwnerKind.task);
		beginSession(server, session, tid, resumeSessionId, launch, config);
		return session;
	}

	/// Resume a stopped source thread into a private owner used exclusively by
	/// one native fork. The caller owns closeStdin after the fork continuation.
	package(cydo) CodexForkSourceOwner openForkSourceOwner(int sourceTid,
		string sourceThreadId, ProcessLaunch launch, SessionConfig config)
	{
		enforce(sourceTid >= 0,
			"Codex fork source owner requires a task ID");
		enforce(sourceThreadId.length > 0,
			"Codex fork source owner requires a source thread ID");
		enforce(launch.nativeHistoryProfile.driver == driver,
			"Codex fork source owner requires a Codex launch profile");
		auto workspace = config.workspace.length > 0 ? config.workspace : "default";
		auto server = getOrCreateServer(serverPoolKey(workspace, launch), launch);
		auto routeTid = server.reserveOperationRouteTid();
		CodexSession session;
		CodexForkSourceOwner owner;
		try
		{
			session = makeSession(server, routeTid, config,
				RouteOwnerKind.forkOperation);
			owner = new CodexForkSourceOwner(session, sourceThreadId);
			beginSession(server, session, sourceTid, sourceThreadId, launch, config);
			return owner;
		}
		catch (Exception e)
		{
			if (owner !is null)
				owner.closeStdin();
			else if (session !is null)
				session.closeStdin();
			else
				server.cancelOperationRouteReservation(routeTid);
			throw e;
		}
	}

	private CodexSession makeSession(AppServerProcess server, int routeTid,
		SessionConfig config, RouteOwnerKind ownerKind)
	{
		auto session = new CodexSession(server, routeTid, config,
			&releaseLiveSessionPaths);
		final switch (ownerKind)
		{
		case RouteOwnerKind.task:
			server.registerSessionByTid(routeTid, session.asRouteTarget());
			break;
		case RouteOwnerKind.forkOperation:
			server.registerOperationSessionByTid(routeTid, session.asRouteTarget());
			break;
		}
		return session;
	}

	private void beginSession(AppServerProcess server, CodexSession session,
		int mcpTid, string resumeSessionId, ProcessLaunch launch, SessionConfig config)
	{

		auto model = config.model.length > 0 ? config.model : "codex-mini-latest";
		auto workDir = launch.workDir.length > 0
			? launch.workDir
			: (config.workDir.length > 0 ? config.workDir : ".");
		auto devInstructions = buildDeveloperInstructions();

		// Build config override (reasoning summary + MCP tools).
		auto configOverride = buildConfigOverride(mcpTid, config);

		server.onReady(() {
			void startFreshThread()
			{
				ThreadStartParams tsp;
				tsp.cwd = workDir;
				tsp.model = model;
				tsp.approvalPolicy = "never";
				tsp.sandbox = "danger-full-access";
				if (devInstructions.length > 0)
					tsp.developerInstructions = devInstructions;
				tsp.config = JSONFragment(configOverride);

				server.sendRequest("thread/start",
					toJson(tsp)
				).then((JsonRpcResponse resp) {
					try
					{
						auto result = resp.getResult!ThreadStartResult();
						enforce(result.thread.id.length > 0,
							"thread/start returned an empty thread id");
						if (result.thread.path.length > 0)
							registerLiveSessionPath(session, launch.nativeHistoryProfile,
								result.thread.id, result.thread.path);
						session.onThreadStarted(result, null, model, workDir,
							resp.result.toJson());
					}
					catch (Exception e)
					{
						warningf("thread/start error: %s", e.msg);
						session.onThreadStartFailed(e);
						return;
					}
				}, (Exception e) {
					session.onThreadStartFailed(e);
				});
			}

			if (resumeSessionId.length > 0)
			{
				ThreadResumeParams trp;
				trp.threadId = resumeSessionId;
				trp.model = model;
				trp.cwd = workDir;
				trp.approvalPolicy = "never";
				trp.sandbox = "danger-full-access";
				if (devInstructions.length > 0)
					trp.developerInstructions = devInstructions;
				// Spike finding (.cydo/tasks/34497/output.md): if the pooled
				// app-server still holds this thread open, a changed effort here
				// is silently ignored — the thread keeps its original effort.
				trp.config = JSONFragment(configOverride);

				server.sendRequest("thread/resume",
					toJson(trp)
				).then((JsonRpcResponse resp) {
					try
					{
						auto result = resp.getResult!ThreadStartResult();
						enforce(result.thread.id.length > 0,
							"thread/resume returned an empty thread id");
						enforce(result.thread.id == resumeSessionId,
							"thread/resume returned a different thread id");
						if (result.thread.path.length > 0)
							registerLiveSessionPath(session, launch.nativeHistoryProfile,
								result.thread.id, result.thread.path);
						session.onThreadStarted(result, resumeSessionId, model, workDir,
							resp.result.toJson());
					}
					catch (Exception e)
					{
						warningf("thread/resume error: %s", e.msg);
						session.onThreadStartFailed(e);
						return;
					}
				}, (Exception e) {
					session.onThreadStartFailed(e);
				});
			}
			else
				startFreshThread();
		});
	}

	Promise!ThreadForkOutcome forkSession(CodexSession forkOwner, int childTid,
		string sourceThreadId, string forkSourcePath, ProcessLaunch childLaunch,
		SessionConfig childConfig)
	{
		enforce(forkOwner !is null && forkOwner.alive,
			"Codex native fork requires a live parent session");
		enforce(forkOwner.currentThreadId == sourceThreadId,
			"Codex native fork source does not match its parent session");
		enforce(childLaunch.nativeHistoryProfile.driver == driver,
			"Codex native fork child launch does not carry a Codex profile");
		enforce(forkSourcePath.length > 0 && isAbsolute(forkSourcePath),
			"Codex native fork requires an absolute captured source path");
		auto outcome = new Promise!ThreadForkOutcome;
		auto workspace = childConfig.workspace.length > 0 ? childConfig.workspace : "default";
		auto server = forkOwner.server;
		auto model = childConfig.model.length > 0 ? childConfig.model : "codex-mini-latest";
		auto workDir = childLaunch.workDir.length > 0
			? childLaunch.workDir
			: (childConfig.workDir.length > 0 ? childConfig.workDir : ".");
		auto devInstructions = buildDeveloperInstructions();
		auto configOverride = buildConfigOverride(childTid, childConfig);

		server.onReady(() {
			ThreadForkParams tfp;
			tfp.threadId = sourceThreadId;
			tfp.path = forkSourcePath;
			tfp.model = model;
			tfp.cwd = workDir;
			tfp.approvalPolicy = "never";
			tfp.sandbox = "danger-full-access";
			if (devInstructions.length > 0)
				tfp.developerInstructions = devInstructions;
			tfp.config = JSONFragment(configOverride);

			server.sendRequest("thread/fork", toJson(tfp))
				.then((JsonRpcResponse resp) {
					ThreadStartResult result;
					try
						result = resp.getResult!ThreadStartResult();
					catch (Exception e)
					{
						outcome.fulfill(ThreadForkOutcome(false, "", null, "", e.msg));
						return;
					}
					if (result.thread.id.length == 0)
					{
						outcome.fulfill(ThreadForkOutcome(false, "", null, resp.result.toJson(),
							"thread/fork returned empty thread id"));
						return;
					}
					if (!forkOwner.alive)
					{
						outcome.fulfill(ThreadForkOutcome(false, "", null,
							resp.result.toJson(), "Codex fork parent exited"));
						return;
					}
					CodexForkPathLease lease;
					try
						lease = forkOwner.registerForkPath(childLaunch.nativeHistoryProfile,
							result.thread.id, result.thread.path);
					catch (Exception e)
					{
						outcome.fulfill(ThreadForkOutcome(false, "", null,
							resp.result.toJson(), e.msg));
						return;
					}
					outcome.fulfill(ThreadForkOutcome(true, result.thread.id, lease,
						resp.result.toJson(), ""));
				}, (Exception e) {
					outcome.fulfill(ThreadForkOutcome(false, "", null, "", e.msg));
				}).ignoreResult();
		});

		return outcome;
	}

	/// Roll back `numTurns` turns from the end of the given thread.
	/// The session must be alive and idle (no turn in progress).
	Promise!ThreadRollbackOutcome rollbackThread(string threadId, uint numTurns,
		string capturedHistoryPath, ProcessLaunch launch, string workspace)
	{
		enforce(capturedHistoryPath.length > 0 && isAbsolute(capturedHistoryPath),
			"Codex rollback requires an absolute captured history path");
		auto outcome = new Promise!ThreadRollbackOutcome;
		auto ws = workspace.length > 0 ? workspace : "default";
		auto server = getOrCreateServer(serverPoolKey(ws, launch), launch);

		server.onReady(() {
			import std.file : exists, getSize;
			size_t rollbackStart;
			if (exists(capturedHistoryPath))
				rollbackStart = getSize(capturedHistoryPath);

			void waitForRollbackMarker(uint attemptsRemaining)
			{
				import std.file : exists, readText;
				import std.string : lineSplitter;

				if (exists(capturedHistoryPath))
				{
					auto content = readText(capturedHistoryPath);
					if (content.length < rollbackStart)
						rollbackStart = 0;
					foreach (line; content[rollbackStart .. $].lineSplitter)
					{
						auto probe = parseRolloutLineProbe(line);
						if (probe.isThreadRolledBack && probe.rollbackNumTurns == numTurns)
						{
							tracef("Codex rollback marker observed: thread=%s turns=%d offset=%d",
								threadId, numTurns, rollbackStart);
							outcome.fulfill(ThreadRollbackOutcome(true, ""));
							return;
						}
					}
				}
				if (attemptsRemaining == 0)
				{
					outcome.fulfill(ThreadRollbackOutcome(false,
						"thread/rollback completed without a persisted thread_rolled_back marker"));
					return;
				}
				setTimeout({ waitForRollbackMarker(attemptsRemaining - 1); }, 10.msecs);
			}

			ThreadRollbackParams params;
			params.threadId = threadId;
			params.numTurns = numTurns;

			server.sendRequest("thread/rollback", toJson(params))
				.then((JsonRpcResponse resp) {
					try
						resp.getResult!SO(); // throws on RPC error
					catch (Exception e)
					{
						outcome.fulfill(ThreadRollbackOutcome(false, e.msg));
						return;
					}
					waitForRollbackMarker(500);
				});
		});

		return outcome;
	}

	private AppServerProcess getOrCreateServer(string poolKey, ProcessLaunch launch)
	{
		if (auto existing = poolKey in serverPool)
			if (!existing.dead)
				return *existing;

		auto codexBin = launch.executablePath.length > 0
			? launch.executablePath
			: executableName(launch.sandbox.env);
		string[] codexArgs = [codexBin, "app-server", "--listen", "stdio://"];
		string[] args;
		if (launch.cmdPrefix !is null)
			args = launch.cmdPrefix ~ codexArgs;
		else
			args = codexArgs;

		auto codexHome = launch.nativeHistoryProfile.root;
		auto server = new AppServerProcess(args);
		serverPool[poolKey] = server;
		AppServerStartupRequest startupRequest;
		server.onShutdown_ = {
			serverPool.remove(poolKey);
			cancelQueuedAppServerStartup(startupRequest);
		};
		server.onCancelStartup_ = { cancelQueuedAppServerStartup(startupRequest); };
		startupRequest = queueAppServerStartup(codexHome, server);
		return server;
	}

	private AppServerStartupRequest queueAppServerStartup(string codexHome,
		AppServerProcess server)
	{
		auto gate = codexHome in appServerStartupGates;
		if (gate is null)
		{
			appServerStartupGates[codexHome] = new AppServerStartupGate;
			gate = codexHome in appServerStartupGates;
		}
		auto request = new AppServerStartupRequest(codexHome, server);
		(*gate).queue ~= request;
		startNextAppServerStartup(codexHome);
		return request;
	}

	private void startNextAppServerStartup(string codexHome)
	{
		auto gate = codexHome in appServerStartupGates;
		if (gate is null || (*gate).busy)
			return;
		while ((*gate).queue.length > 0)
		{
			auto request = (*gate).queue[0];
			(*gate).queue = (*gate).queue[1 .. $];
			if (request.cancelled)
				continue;
			(*gate).busy = true;
			auto lease = new AppServerStartupLease(codexHome, request);
			request.lease = lease;
			lease.timeout = setTimeout({ releaseAppServerStartup(lease); }, 30.seconds);
			request.server.startProcess({ releaseAppServerStartup(lease); });
			return;
		}
		appServerStartupGates.remove(codexHome);
	}

	private void releaseAppServerStartup(AppServerStartupLease lease)
	{
		if (lease.released)
			return;
		lease.released = true;
		if (lease.timeout !is null && lease.timeout.isWaiting)
			lease.timeout.cancel();
		auto gate = lease.codexHome in appServerStartupGates;
		if (gate is null)
			return;
		(*gate).busy = false;
		startNextAppServerStartup(lease.codexHome);
	}

	private void cancelQueuedAppServerStartup(AppServerStartupRequest request)
	{
		if (request is null || request.lease !is null)
			return;
		request.cancelled = true;
		auto gate = request.codexHome in appServerStartupGates;
		if (gate is null)
			return;
		foreach (i, queued; (*gate).queue)
			if (queued is request)
			{
				(*gate).queue = (*gate).queue[0 .. i] ~ (*gate).queue[i + 1 .. $];
				break;
			}
	}

	/// Shut down all pooled server processes (safety net for app shutdown).
	void shutdownAllServers()
	{
		auto servers = serverPool.values;
		serverPool = null;
		foreach (server; servers)
			server.shutdown();
	}

	string extractResultText(string line)
	{
		import std.algorithm : canFind;
		if (!line.canFind(`"turn/result"`))
			return "";

		@JSONPartial
		static struct ResultProbe
		{
			string type;
			string result;
		}

		try
		{
			auto probe = jsonParse!ResultProbe(line);
			if (probe.type == "turn/result")
				return probe.result;

			warningf("Unexpected turn/result event: %s", line);
			return "";
		}
		catch (Exception e)
		{
			warningf("Error parsing result: %s", e.msg);
			return "";
		}
	}

	string extractAssistantText(string line)
	{
		import std.algorithm : canFind;

		// New format: item/started with item_type=text
		if (line.canFind(`"item/started"`))
		{
			@JSONPartial static struct ItemStartedProbe { string type; string item_type; string text; }
			try
			{
				auto probe = jsonParse!ItemStartedProbe(line);
				if (probe.type == "item/started" && probe.item_type == "text" && probe.text.length > 0)
					return probe.text;
			}
			catch (Exception) {}
		}

		return "";
	}

	void setModelAliases(ModelSpec[string] aliases)
	{
		modelAliasOverrides = aliases;
	}

	private static string defaultModelForClass(string modelClass)
	{
		switch (modelClass)
		{
			case "small":  return "gpt-5.6-luna";
			case "medium": return "gpt-5.6-terra";
			case "large":  return "gpt-5.6-sol";
			default:       return modelClass; // open-ended labels pass through
		}
	}

	ModelSpec resolveModelSpec(string modelClass)
	{
		ModelSpec spec;
		if (auto p = modelClass in modelAliasOverrides)
			spec = *p;
		if (spec.model.length == 0)
			spec.model = defaultModelForClass(modelClass);
		return spec;
	}

	unittest
	{
		auto agent = new CodexAgent();

		// 14. with no overrides, hardcoded defaults and empty effort
		assert(agent.resolveModelSpec("small") == ModelSpec(ModelSpecFields("gpt-5.6-luna")));
		assert(agent.resolveModelSpec("medium") == ModelSpec(ModelSpecFields("gpt-5.6-terra")));
		assert(agent.resolveModelSpec("large") == ModelSpec(ModelSpecFields("gpt-5.6-sol")));

		// 15. an override replaces the default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("custom-model"))]);
		assert(agent.resolveModelSpec("large").model == "custom-model");

		// 16. an effort-only override keeps the driver's default model
		agent.setModelAliases(["large": ModelSpec(ModelSpecFields("", "high"))]);
		auto effortOnly = agent.resolveModelSpec("large");
		assert(effortOnly.model == "gpt-5.6-sol");
		assert(effortOnly.effort == "high");

		// 17. an unknown class passes through, and can still be overridden
		agent.setModelAliases(null);
		auto passthrough = agent.resolveModelSpec("best");
		assert(passthrough.model == "best");
		assert(passthrough.effort == "");
		agent.setModelAliases(["best": ModelSpec(ModelSpecFields("opus", "max"))]);
		auto customClass = agent.resolveModelSpec("best");
		assert(customClass.model == "opus");
		assert(customClass.effort == "max");

		// 18. the empty-class edge stays inert
		agent.setModelAliases(null);
		assert(agent.resolveModelSpec("").model == "");
	}

	string historyPath(string sessionId, string effectiveCwd,
		const ref NativeHistoryProfile profile)
	{
		enforce(sessionId.length > 0,
			"Codex history path requires a session ID");
		foreach (ref session; scanSessions(profile))
			if (session.sessionId == sessionId)
				return session.exactHistoryPath;
		return null;
	}

	string createHistoryForkDestination(string sessionId, string effectiveCwd,
		const ref NativeHistoryProfile profile)
	{
		enforce(false,
			"Codex generic history forks must use the native thread RPC path");
		assert(false);
	}

	package(cydo) string liveSessionPath(CodexSession owner,
		const ref NativeHistoryProfile profile, string sessionId)
	{
		validateProfile(profile);
		enforce(owner !is null,
			"Codex live history lookup requires an owner");
		auto entry = CodexHistoryKey(profile.root, sessionId) in liveHistoryPaths_;
		if (entry is null)
			return null;
		enforce((*entry).owner is owner,
			"Codex live history path belongs to a different session owner");
		return (*entry).path;
	}

	private void registerLiveSessionPath(CodexSession owner,
		const ref NativeHistoryProfile profile, string sessionId, string path)
	{
		validateProfile(profile);
		enforce(owner !is null,
			"Codex live history registration requires an owner");
		enforce(sessionId.length > 0,
			"Codex live history registration requires a session ID");
		validateProfilePath(profile, path);
		auto key = CodexHistoryKey(profile.root, sessionId);
		if (auto existing = key in liveHistoryPaths_)
			enforce((*existing).owner is owner,
				"Codex live history path is already owned by another session");
		liveHistoryPaths_[key] = CodexLiveHistoryPath(owner, path);
	}

	private void releaseLiveSessionPaths(CodexSession owner)
	{
		CodexHistoryKey[] keys;
		foreach (key, value; liveHistoryPaths_)
			if (value.owner is owner)
				keys ~= key;
		foreach (key; keys)
			liveHistoryPaths_.remove(key);
	}

	private void validateProfile(const ref NativeHistoryProfile profile)
	{
		enforce(profile.driver == driver,
			"Codex history profile driver does not match Codex");
		enforce(profile.root.length > 0 && isAbsolute(profile.root),
			"Codex history profile requires an absolute root");
	}

	private static void validateProfilePath(const ref NativeHistoryProfile profile,
		string path)
	{
		import std.path : buildPath;

		auto sessionsRoot = buildPath(profile.root, "sessions");
		enforce(path.length > 0 && isAbsolute(path)
			&& (path == sessionsRoot || path.startsWith(sessionsRoot ~ "/")),
			"Codex thread path is not inside the supplied profile sessions directory");
	}

	private DiscoveredSession[] scanSessions(const ref NativeHistoryProfile profile)
	{
		import std.file : DirEntry, dirEntries, exists, SpanMode;
		import std.path : baseName, buildPath;
		import std.regex : ctRegex, matchFirst;

		validateProfile(profile);
		auto sessionsDir = buildPath(profile.root, "sessions");
		if (!exists(sessionsDir))
			return [];

		enum uuidRx = ctRegex!`[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`;
		bool[string] seen;
		DiscoveredSession[] result;
		foreach (DirEntry entry; dirEntries(sessionsDir, "*.jsonl", SpanMode.depth))
		{
			auto base = baseName(entry.name, ".jsonl");
			auto match = base.matchFirst(uuidRx);
			auto sessionId = match.empty ? base : match.hit;
			enforce(sessionId !in seen,
				"Codex profile contains duplicate rollout histories for session " ~ sessionId);
			seen[sessionId] = true;
			DiscoveredSession session;
			session.sessionId = sessionId;
			session.mtime = entry.timeLastModified.stdTime;
			session.projectPath = "";
			session.exactHistoryPath = entry.name;
			result ~= session;
		}
		return result;
	}

	TranslatedEvent[] translateHistoryLine(string line, int lineNum)
	{
		import std.conv : to;
		import cydo.protocol : parseIso8601Timestamp;

		// Codex JSONL lines: { timestamp, type, payload }
		// type is one of: session_meta, response_item, event_msg, turn_context, compacted
		@JSONPartial static struct TimestampProbe { @JSONOptional string timestamp; }
		AbsTime ts;
		try { ts = parseIso8601Timestamp(jsonParse!TimestampProbe(line).timestamp); }
		catch (Exception) {}

		auto probe = parseRolloutLineProbe(line);
		if (probe.isSessionMeta)
		{
			auto t = translateRolloutSessionMeta(line);
			return t !is null ? [TranslatedEvent(t, line, ts)] : [];
		}
		else if (probe.isTurnContext)
		{
			auto t = translateRolloutTurnContext(line);
			return t !is null ? [TranslatedEvent(t, line, ts)] : [];
		}
		else if (probe.isResponseItem)
		{
			// Pass line-number fork ID for user/assistant messages
			string forkId = null;
			if (probe.isForkableMessage)
				forkId = "line:" ~ to!string(lineNum);
			// Lines before task_started are system context injected by Codex — mark as meta.
			bool forceMeta = !histSeenTaskStarted_;
			auto results = translateRolloutResponseItem(line, forkId, forceMeta);
			TranslatedEvent[] evs;
			foreach (r; results)
				evs ~= TranslatedEvent(r, line, ts);
			return evs;
		}
		else if (probe.isEventMsg)
		{
			if (!histSeenTaskStarted_ && probe.isTaskStarted)
				histSeenTaskStarted_ = true;
			auto t = translateRolloutEventMsg(line);
			return t !is null ? [TranslatedEvent(t, line, ts)] : [];
		}
		// Skip compacted, unknown
		return [];
	}

	TranslatedEvent[] translateLiveEvent(string rawLine)
	{
		// CodexSession emits new-format events natively; pass through unchanged.
		import std.datetime : Clock;
		return [TranslatedEvent(rawLine, null, AbsTime(Clock.currStdTime))];
	}

	bool isTurnResult(string rawLine)
	{
		import std.algorithm : canFind;
		return rawLine.canFind(`"type":"turn/result"`);
	}

	bool isUserMessageLine(string rawLine)
	{
		return parseRolloutLineProbe(rawLine).isUserMessage;
	}

	bool isAssistantMessageLine(string rawLine)
	{
		return parseRolloutLineProbe(rawLine).isAssistantMessage;
	}

	string rewriteSessionId(string line, string oldId, string newId)
	{
		import std.array : replace;
		return line
			.replace(`"threadId":"` ~ oldId ~ `"`, `"threadId":"` ~ newId ~ `"`)
			.replace(`"session_id":"` ~ oldId ~ `"`, `"session_id":"` ~ newId ~ `"`);
	}

	PersistedHistoryBoundary[] extractPersistedHistoryBoundaries(string content, int lineOffset = 0)
	{
		return extractPersistedHistoryBoundariesImpl(content, lineOffset);
	}

	bool forkIdMatchesLine(string line, int lineNum, string forkId)
	{
		import std.conv : to;
		// Fork IDs are "line:<N>" — match on line number
		if (forkId.length > 5 && forkId[0 .. 5] == "line:")
		{
			try
				return lineNum == to!int(forkId[5 .. $]);
			catch (Exception)
				return false;
		}
		return false;
	}

	bool isForkableLine(string line)
	{
		return parseRolloutLineProbe(line).isForkableMessage;
	}

	@property bool needsBash() { return false; }
	@property bool supportsFileRevert() { return false; }
	// https://github.com/openai/codex/issues/19045
	// Codex app-server developerInstructions are unreliable after
	// thread/resume and keep-context mode switches, so task system prompts
	// must be delivered via normal user input instead.
	@property bool supportsDeveloperPrompt() { return false; }

	RewindResult rewindFiles(string sessionId, string afterUuid, string cwd,
		ProcessLaunch launch)
	{
		return RewindResult(false, "File revert is not supported for Codex sessions");
	}

	/// Currently unused — no callers in the codebase. Implement if a caller is added.
	string extractUserText(string line) { return ""; }

	DiscoveredSession[] enumerateAllSessions(const ref NativeHistoryProfile profile)
	{
		return scanSessions(profile);
	}

	SessionMeta readSessionMeta(const ref DiscoveredSession session)
	{
		import std.algorithm : canFind;
		import std.stdio : File;
		if (session.exactHistoryPath.length == 0)
			return SessionMeta.init;

		SessionMeta meta;
		try
		{
			int lineCount = 0;
			auto f = File(session.exactHistoryPath, "r");
			foreach (line; f.byLine)
			{
				if (lineCount++ > 50)
					break;
				string lineStr = cast(string) line.idup;
				// Extract cwd from session_meta line
				if (meta.projectPath.length == 0 && lineStr.canFind(`"type":"session_meta"`))
				{
					@JSONPartial
					static struct SessionMetaProbe
					{
						@JSONPartial
						static struct Payload { string cwd; }
						Payload payload;
					}
					try
					{
						auto probe = jsonParse!SessionMetaProbe(lineStr);
						if (probe.payload.cwd.length > 0)
							meta.projectPath = probe.payload.cwd;
					}
					catch (Exception) {}
				}
				// Extract title from first user response_item
				if (meta.title.length == 0 && lineStr.canFind(`"type":"response_item"`)
					&& lineStr.canFind(`"role":"user"`))
				{
					@JSONPartial
					static struct RiProbe
					{
						@JSONPartial
						static struct Payload
						{
							string role;
							@JSONPartial
							static struct ContentItem { string type; string text; }
							ContentItem[] content;
						}
						Payload payload;
					}
					try
					{
						auto probe = jsonParse!RiProbe(lineStr);
						if (probe.payload.role == "user")
						{
							string text;
							foreach (ref ci; probe.payload.content)
								if (ci.type == "input_text" || ci.type == "text")
									text ~= ci.text;
							if (text.length > 0)
								meta.title = truncateTitle(text, 80);
						}
					}
					catch (Exception) {}
				}
				if (meta.title.length > 0 && meta.projectPath.length > 0)
					break;
			}
		}
		catch (Exception e)
		{ tracef("readSessionMeta(codex, %s): error: %s", session.sessionId, e.msg); }
		return meta;
	}

	string matchProject(const ref DiscoveredSession session,
		const string[] knownProjectPaths) { return ""; }

	private string prepareIsolatedOneShotHome(ProcessLaunch launch)
	{
		import std.file : copy, exists, mkdirRecurse;
		import std.uuid : randomUUID;

		// Codex 0.139 roots its SQLite state runtime at CODEX_HOME.  Keep
		// short-lived `codex exec` runs off the app-server's state database,
		// while preserving the configured provider/auth settings.
		auto codexHome = launch.nativeHistoryProfile.root;
		auto oneShotHome = buildPath(codexHome, "oneshot", randomUUID().toString());
		scope (failure)
			removeOneShotHome(oneShotHome);
		mkdirRecurse(oneShotHome);

		auto configPath = buildPath(codexHome, "config.toml");
		if (exists(configPath))
			copy(configPath, buildPath(oneShotHome, "config.toml"));
		mkdirRecurse(buildPath(oneShotHome, "shell_snapshots"));
		return oneShotHome;
	}

	private static string[] buildOneShotArgs(string executablePath, string prompt,
		string model, string effort, string[] cmdPrefix)
	{
		string[] codexArgs = [
			executablePath,
			"exec",
			"--ephemeral",
			"--skip-git-repo-check",
			"-m", model,
		];
		// The TOML quotes are deliberate: `-c` parses the value as TOML and only
		// falls back to a raw string literal on parse failure, so quoting makes
		// the intent explicit.
		if (effort.length > 0)
			codexArgs ~= ["-c", `model_reasoning_effort="` ~ effort ~ `"`];
		codexArgs ~= prompt;
		return cmdPrefix !is null ? cmdPrefix ~ codexArgs : codexArgs;
	}

	unittest
	{
		import std.algorithm : canFind, countUntil;

		// 24. -c is immediately followed by model_reasoning_effort="high" when
		// effort is set; absent when it is not. prompt stays the final positional.
		auto withEffort = buildOneShotArgs("codex", "hi", "gpt-5.6-sol", "high", null);
		auto i = withEffort.countUntil("-c");
		assert(i >= 0 && withEffort[i + 1] == `model_reasoning_effort="high"`);
		assert(withEffort[$ - 1] == "hi");

		auto withoutEffort = buildOneShotArgs("codex", "hi", "gpt-5.6-sol", "", null);
		assert(!withoutEffort.canFind("-c"));
		assert(withoutEffort[$ - 1] == "hi");
	}

	OneShotHandle completeOneShot(string prompt, string modelClass,
		ProcessLaunch launch)
	{
		import std.string : strip;

		auto promise = new Promise!string;
		string oneShotHome;
		ProcessLaunch oneShotLaunch;
		bool hasOneShotLaunch;
		AgentProcess proc;
		try
		{
			oneShotHome = prepareIsolatedOneShotHome(launch);
			oneShotLaunch = launchSandbox.withProcessLaunchEnv(launch, "CODEX_HOME",
				oneShotHome);
			hasOneShotLaunch = true;

			auto spec = resolveModelSpec(modelClass);
			auto executablePath = oneShotLaunch.executablePath.length > 0
				? oneShotLaunch.executablePath
				: executableName(oneShotLaunch.sandbox.env);
			auto args = buildOneShotArgs(executablePath, prompt, spec.model,
				spec.effort, oneShotLaunch.cmdPrefix);

			// When sandboxed, cmdPrefix carries the resolved env/cwd. Otherwise
			// inherit the parent environment, matching AppServerProcess.
			// --skip-git-repo-check avoids the "not inside a trusted directory"
			// error when the process CWD is not a git repo root.
			proc = new AgentProcess(args, noStdin: true,
				mode: FramingMode.raw, logName: "codex-oneshot");
		}
		catch (Exception e)
		{
			if (hasOneShotLaunch)
				cleanup(oneShotLaunch.sandbox);
			removeOneShotHome(oneShotHome);
			errorf("completeOneShot: failed to prepare or spawn codex: %s", e.msg);
			promise.reject(new Exception("failed to prepare or spawn codex: " ~ e.msg));
			return OneShotHandle(promise, null);
		}

		// When stdout is a pipe (not a TTY), codex exec writes only the final
		// response text to stdout; all headers and diagnostics go to stderr.
		string responseText;
		string stderrText;

		proc.onStdoutLine = (string chunk) {
			responseText ~= chunk;
		};

		proc.onStderrLine = (string line) {
			stderrText ~= line ~ "\n";
		};

		proc.onExit = (int status) {
			cleanup(oneShotLaunch.sandbox);
			removeOneShotHome(oneShotHome);

			if (status != 0)
			{
				auto msg = "codex exited with status " ~ status.to!string;
				if (stderrText.length > 0)
					errorf("completeOneShot: %s\n%s", msg, stderrText);
				promise.reject(new Exception(msg));
			}
			else
			{
				if (stderrText.length > 0)
					warningf("codex oneshot stderr: %s", stderrText.strip());
				promise.fulfill(responseText.strip());
			}
		};

		void cancel() { proc.killAfterTimeout(0.seconds); }

		return OneShotHandle(promise, &cancel);
	}

	private void removeOneShotHome(string oneShotHome)
	{
		import std.file : exists, rmdirRecurse;

		if (oneShotHome.length == 0 || !exists(oneShotHome))
			return;
		try
			rmdirRecurse(oneShotHome);
		catch (Exception e)
			warningf("completeOneShot: failed to remove %s: %s", oneShotHome, e.msg);
	}
}

unittest
{
	import std.file : exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.runtime.config : PathMode, SandboxConfig;
	import cydo.runtime.launch.sandbox_resolver : resolveSandbox;
	import cydo.runtime.launch.types : AgentSandboxConfig;

	auto root = buildPath(tempDir(), "cydo-codex-configure-sandbox");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);

	auto environmentKeys = ["HOME", "PATH", "CODEX_HOME", "OPENAI_API_KEY",
		"OPENAI_BASE_URL", "CODEX_API_KEY"];
	string[string] previousEnvironment;
	bool[string] hadEnvironment;
	foreach (key; environmentKeys)
	{
		hadEnvironment[key] = key in environment;
		previousEnvironment[key] = environment.get(key, "");
	}
	scope (exit)
	{
		foreach (key; environmentKeys)
		{
			if (hadEnvironment[key])
				environment[key] = previousEnvironment[key];
			else
				environment.remove(key);
		}
	}

	auto home = buildPath(root, "home");
	auto codexHome = buildPath(home, "configured-codex-home");
	auto npmRoot = buildPath(home, ".npm-packages");
	auto executableDir = buildPath(npmRoot, "bin");
	auto executable = buildPath(executableDir, "codex");
	mkdirRecurse(codexHome);
	mkdirRecurse(executableDir);
	write(executable, "#!/bin/sh\nexit 0\n");
	execute(["chmod", "+x", executable]);
	environment["HOME"] = home;
	environment["CODEX_HOME"] = codexHome;
	environment["OPENAI_API_KEY"] = "test-openai-key";
	environment["OPENAI_BASE_URL"] = "https://codex.test.invalid/v1";
	environment["CODEX_API_KEY"] = "test-codex-key";
	environment["PATH"] = executableDir;

	auto agent = new CodexAgent;
	auto cydoDir = cydoBinaryDir();
	assert(cydoDir.length > 0);

	SandboxConfig global;
	global.paths = [
		executableDir: PathMode.rw,
		cydoDir: PathMode.always_rw,
	];
	global.env = [
		"CYDO_CODEX_BIN": executable,
		"PATH": executableDir,
	];
	auto executableMounts = executableMountPaths(resolveExecutablePath(executable, global.env));
	assert(executableMounts.length == 1);
	assert(executableMounts[0] == executableDir);
	AgentSandboxConfig agentSandbox;
	agentSandbox.configureSandbox = (ref SandboxPaths paths, ref string[string] env) {
		agent.configureSandbox(paths, env);
	};
	agentSandbox.agentName = "codex";
	agentSandbox.workspaceName = "test";
	auto resolved = resolveSandbox(global, SandboxConfig.init, SandboxConfig.init,
		agentSandbox, "");

	auto executableView = resolved.paths.exact(executableDir).get;
	assert(executableView.declaration.get.mode == PathMode.rw);
	assert(executableView.effectiveMode == PathMode.rw);
	auto cydoView = resolved.paths.exact(cydoDir).get;
	assert(cydoView.declaration.get.mode == PathMode.always_rw);
	assert(cydoView.effectiveMode == PathMode.always_rw);

	// Native history is materialized by prepareProcessLaunch, not while the
	// driver configures executable visibility and credential passthrough.
	assert(resolved.paths.exact(codexHome).isNull);
	auto nativeRule = agent.nativeHistoryRule;
	assert(nativeRule.driver == AgentDriver.codex);
	assert(nativeRule.profileEnvName == "CODEX_HOME");
	assert(nativeRule.homeRelativeDefault == ".codex");
	assert(nativeRule.homeSupportRequirements.length == 0);
	assert(resolved.env["PATH"] == executableDir);
	assert(("CODEX_HOME" in resolved.env) is null);
	assert(resolved.env["OPENAI_API_KEY"] == "test-openai-key");
	assert(resolved.env["OPENAI_BASE_URL"] == "https://codex.test.invalid/v1");
	assert(resolved.env["CODEX_API_KEY"] == "test-codex-key");

	// A configured profile selector remains in the resolved child environment,
	// but configureSandbox must not turn it into a native-history mount.
	auto configuredCodexHome = buildPath(home, "sandbox-codex-home");
	SandboxConfig configuredGlobal;
	configuredGlobal.env = [
		"CYDO_CODEX_BIN": executable,
		"PATH": executableDir,
		"CODEX_HOME": configuredCodexHome,
	];
	auto configuredResolved = resolveSandbox(configuredGlobal, SandboxConfig.init,
		SandboxConfig.init, agentSandbox, "");
	assert(configuredResolved.paths.exact(configuredCodexHome).isNull);
	assert(configuredResolved.paths.exact(codexHome).isNull);
	assert(configuredResolved.env["CODEX_HOME"] == configuredCodexHome);

	// Missing launch values do not inherit host CODEX_HOME during driver setup.
	SandboxPaths defaultPaths;
	string[string] defaultEnv = ["CYDO_CODEX_BIN": executable];
	agent.configureSandbox(defaultPaths, defaultEnv);
	assert(defaultEnv["PATH"] == executableDir);
	assert(("CODEX_HOME" in defaultEnv) is null);
	assert(defaultPaths.exact(codexHome).isNull);
	assert(defaultEnv["OPENAI_API_KEY"] == "test-openai-key");
	assert(defaultEnv["OPENAI_BASE_URL"] == "https://codex.test.invalid/v1");
	assert(defaultEnv["CODEX_API_KEY"] == "test-codex-key");
	foreach (path; executableMounts)
		assert(defaultPaths.exact(path).get.effectiveMode == PathMode.ro);
	auto npmView = defaultPaths.exact(npmRoot).get;
	assert(npmView.requirement.get.access == PathAccess.ro);
	assert(npmView.effectiveMode == PathMode.ro);

	// Writable ancestors satisfy read visibility without producing a child mount.
	auto origin = SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
		"codex test", "pre-existing host access");
	SandboxPaths ancestorPaths;
	auto executableParent = dirName(executableDir);
	auto cydoParent = dirName(cydoDir);
	ancestorPaths.require(executableParent, PathAccess.rw, origin);
	ancestorPaths.require(cydoParent, PathAccess.alwaysRw, origin);
	string[string] ancestorEnv = [
		"CYDO_CODEX_BIN": executable,
		"PATH": executableDir,
	];
	agent.configureSandbox(ancestorPaths, ancestorEnv);
	assert(ancestorPaths.exact(executableParent).get.effectiveMode == PathMode.rw);
	assert(ancestorPaths.exact(executableDir).isNull);
	assert(ancestorPaths.exact(cydoParent).get.effectiveMode == PathMode.always_rw);
	assert(ancestorPaths.exact(cydoDir).isNull);
}

unittest
{
	import std.algorithm : canFind;
	import std.file : exists, mkdirRecurse, readText, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.runtime.config : PathMode;
	import cydo.runtime.launch.sandbox : cleanup, prepareProcessLaunch,
		resolveNativeHistoryProfile;
	import cydo.runtime.launch.types : ResolvedSandbox;

	auto root = buildPath("/tmp", "cydo-codex-oneshot-native-profile-clone");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto prefixTempDir = buildPath(root, "prefix-temps");
	auto childHome = buildPath(root, "child-home");
	auto suppliedProfile = buildPath(root, "supplied-profile");
	auto hostProfile = buildPath(root, "host-profile");
	mkdirRecurse(fakeBin);
	mkdirRecurse(prefixTempDir);
	mkdirRecurse(childHome);
	mkdirRecurse(suppliedProfile);
	mkdirRecurse(hostProfile);
	write(buildPath(fakeBin, "bwrap"), "");
	write(buildPath(suppliedProfile, "config.toml"), "provider = \"supplied\"\n");
	write(buildPath(hostProfile, "config.toml"), "provider = \"host\"\n");

	auto oldCodexHome = environment.get("CODEX_HOME", "");
	auto oldHome = environment.get("HOME", "");
	auto oldPath = environment.get("PATH", "");
	auto oldTmpDir = environment.get("TMPDIR", "");
	auto oldUser = environment.get("USER", "");
	bool hadCodexHome = "CODEX_HOME" in environment;
	bool hadTmpDir = "TMPDIR" in environment;
	bool hadUser = "USER" in environment;
	scope (exit)
	{
		if (hadCodexHome)
			environment["CODEX_HOME"] = oldCodexHome;
		else
			environment.remove("CODEX_HOME");
		environment["HOME"] = oldHome;
		environment["PATH"] = oldPath;
		if (hadTmpDir)
			environment["TMPDIR"] = oldTmpDir;
		else
			environment.remove("TMPDIR");
		if (hadUser)
			environment["USER"] = oldUser;
		else
			environment.remove("USER");
	}
	environment["CODEX_HOME"] = hostProfile;
	environment["HOME"] = childHome;
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	environment["TMPDIR"] = prefixTempDir;
	environment["USER"] = "root";

	auto agent = new CodexAgent();
	auto rule = agent.nativeHistoryRule;
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = childHome;
	sandbox.env["CODEX_HOME"] = suppliedProfile;
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	auto source = prepareProcessLaunch(sandbox, rule, profile, buildPath(root, "workdir"));
	bool sourceCleaned;
	scope (exit)
		if (!sourceCleaned)
			cleanup(source.sandbox);
	auto sourceOwnedTemp = buildPath(root, "source-owned-temp");
	write(sourceOwnedTemp, "source-owned");
	source.preProfileSandbox.tempFiles ~= sourceOwnedTemp;
	source.sandbox.tempFiles ~= sourceOwnedTemp;
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto sourcePreProfilePaths = source.preProfileSandbox.paths.snapshot;
	auto sourcePreProfileEnv = source.preProfileSandbox.env.dup;
	auto sourcePreProfileTempFiles = source.preProfileSandbox.tempFiles.dup;
	assert(sourceTempFiles.length > 0);
	assert(sourceTempFiles.canFind(sourceOwnedTemp));
	assert(sourcePreProfileTempFiles.canFind(sourceOwnedTemp));

	auto oneShotHome = agent.prepareIsolatedOneShotHome(source);
	assert(dirName(oneShotHome) == buildPath(suppliedProfile, "oneshot"));
	assert(exists(buildPath(oneShotHome, "shell_snapshots")));
	assert(readText(buildPath(oneShotHome, "config.toml")) == "provider = \"supplied\"\n");
	assert(!exists(buildPath(hostProfile, "oneshot")));

	auto clone = launchSandbox.withProcessLaunchEnv(source, "CODEX_HOME", oneShotHome);
	auto cloneTempFiles = clone.sandbox.tempFiles.dup;
	assert(clone.nativeHistoryProfile.driver == AgentDriver.codex);
	assert(clone.nativeHistoryProfile.root == oneShotHome);
	assert(clone.sandbox.env["CODEX_HOME"] == oneShotHome);
	assert(clone.sandbox.paths.exact(suppliedProfile).isNull);
	assert(clone.sandbox.paths.exact(oneShotHome).get.effectiveMode == PathMode.rw);
	assert(clone.sandbox.tempFiles.length > 0);
	foreach (tempFile; cloneTempFiles)
		assert(!sourceTempFiles.canFind(tempFile));
	assert(!cloneTempFiles.canFind(sourceOwnedTemp));
	assert(clone.cmdPrefix != sourcePrefix);
	assert(!clone.cmdPrefix.canFind(suppliedProfile));
	assert(clone.cmdPrefix.canFind(oneShotHome));

	assert(source.nativeHistoryProfile.driver == AgentDriver.codex);
	assert(source.nativeHistoryProfile.root == suppliedProfile);
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.env == sourceEnv);
	assert(source.sandbox.tempFiles == sourceTempFiles);
	assert(source.cmdPrefix == sourcePrefix);
	assert(source.preProfileSandbox.paths.snapshot == sourcePreProfilePaths);
	assert(source.preProfileSandbox.env == sourcePreProfileEnv);
	assert(source.preProfileSandbox.tempFiles == sourcePreProfileTempFiles);

	cleanup(clone.sandbox);
	foreach (tempFile; cloneTempFiles)
		assert(!exists(tempFile));
	foreach (tempFile; sourceTempFiles)
		assert(exists(tempFile));
	rmdirRecurse(oneShotHome);
	assert(!exists(oneShotHome));
	cleanup(source.sandbox);
	sourceCleaned = true;
	assert(!exists(sourceOwnedTemp));
	assert(source.sandbox.tempFiles.length == 0);
}

unittest
{
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;

	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection);
	auto session = new CodexSession(server, 1, SessionConfig.init);
	string[] order;
	session.onRouteReady = {
		assert(server.hasThreadRouteForTest("codex-native-id"));
		order ~= "route";
	};
	session.onNativeSessionStarted = (string sessionId) {
		order ~= "native:" ~ sessionId;
	};
	session.onOutput = (TranslatedEvent event) { order ~= "output"; };
	ThreadStartResult started;
	started.thread.id = "codex-native-id";
	session.onThreadStarted(started, null, "test-model", "/test/workdir",
		`{"thread":{"id":"codex-native-id"}}`);
	assert(order.length >= 3
		&& order[0] == "native:codex-native-id"
		&& order[1] == "route"
		&& order[2] == "output",
		"Codex must register its route before publishing route readiness");

	auto lateConnection = new TestCodexConnection;
	auto lateServer = makeTestAppServerProcess(lateConnection);
	auto lateSession = new CodexSession(lateServer, 2, SessionConfig.init);
	ThreadStartResult lateStarted;
	lateStarted.thread.id = "codex-late-id";
	lateSession.onThreadStarted(lateStarted, "codex-late-id", "test-model",
		"/test/workdir", `{"thread":{"id":"codex-late-id"}}`);
	string delivered;
	lateSession.onNativeSessionStarted = (string sessionId) { delivered = sessionId; };
	assert(delivered == "codex-late-id");
}

unittest
{
	import ae.net.asockets : socketManager;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;

	void drainNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	JsonRpcResponse threadResponse(string threadId, string threadPath)
	{
		ThreadStartResult result;
		result.thread.id = threadId;
		result.thread.path = threadPath;
		JsonRpcResponse response;
		response.result = SO.from(result);
		return response;
	}

	auto connection = new TestCodexConnection;
	auto server = makeTestAppServerProcess(connection);
	auto agent = new CodexAgent;
	ProcessLaunch sourceLaunch;
	sourceLaunch.executablePath = "unused-test-codex";
	sourceLaunch.workDir = "/test/source-workdir";
	sourceLaunch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex,
		"/test/source-profile");
	SessionConfig sourceConfig;
	sourceConfig.workspace = "operation-owner";
	sourceConfig.model = "test-model";
	agent.serverPool[agent.serverPoolKey(sourceConfig.workspace, sourceLaunch)] = server;

	auto operation = agent.openForkSourceOwner(71, "source-thread", sourceLaunch,
		sourceConfig);
	CodexSession owner;
	bool ownerReady;
	operation.routeReady.then((CodexSession value) {
		owner = value;
		ownerReady = true;
	}, (Exception e) {
		assert(false, e.msg);
	}).ignoreResult();

	auto resumeRequest = connection.takeRequest("thread/resume");
	auto resumeParams = jsonParse!ThreadResumeParams(toJson(resumeRequest.params));
	assert(resumeParams.threadId == "source-thread"
		&& resumeParams.cwd == "/test/source-workdir");
	connection.respond(resumeRequest, threadResponse("source-thread",
		"/test/source-profile/sessions/2026/08/source-thread.jsonl"));
	drainNextTicks();
	assert(ownerReady && owner !is null && owner.alive);
	assert(server.hasThreadRouteForTest("source-thread"));

	ProcessLaunch childLaunch;
	childLaunch.workDir = "/test/child-workdir";
	childLaunch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex,
		"/test/child-profile");
	SessionConfig childConfig;
	childConfig.workspace = sourceConfig.workspace;
	childConfig.model = "test-model";
	auto fork = agent.forkSession(owner, 72, "source-thread",
		"/test/source-profile/sessions/fork-source.jsonl", childLaunch, childConfig);
	auto forkRequest = connection.takeRequest("thread/fork");
	auto forkParams = jsonParse!ThreadForkParams(toJson(forkRequest.params));
	assert(forkParams.threadId == "source-thread"
		&& forkParams.path == "/test/source-profile/sessions/fork-source.jsonl");

	ThreadForkOutcome outcome;
	bool forkSettled;
	fork.then((ThreadForkOutcome value) {
		outcome = value;
		forkSettled = true;
	}, (Exception e) {
		assert(false, e.msg);
	}).ignoreResult();
	connection.respond(forkRequest, threadResponse("child-thread",
		"/test/child-profile/sessions/2026/08/child-thread.jsonl"));
	drainNextTicks();
	assert(forkSettled && outcome.ok && outcome.threadId == "child-thread"
		&& outcome.historyLease.path
			== "/test/child-profile/sessions/2026/08/child-thread.jsonl");
	outcome.historyLease.release();

	operation.closeStdin();
	assert(!owner.alive);
	assert(!server.hasThreadRouteForTest("source-thread"));
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm : canFind;
	import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse, tempDir, write;
	import std.path : buildPath;
	import std.process : environment, execute;
	import cydo.runtime.launch.sandbox : cleanup, prepareProcessLaunch,
		resolveNativeHistoryProfile;
	import cydo.runtime.launch.sandbox_paths : PathAccess, SandboxPathOrigin,
		SandboxPathOriginKind;
	import cydo.runtime.launch.types : ResolvedSandbox;

	auto root = buildPath("/tmp", "cydo-codex-oneshot-clone-temp-ownership");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto fakeBwrap = buildPath(fakeBin, "bwrap");
	auto fakeCodex = buildPath(fakeBin, "codex");
	auto hostHome = buildPath(root, "host-home");
	auto childHome = buildPath(root, "child-home");
	auto profileRoot = buildPath(root, "profile");
	mkdirRecurse(fakeBin);
	mkdirRecurse(buildPath(hostHome, ".config", "git"));
	mkdirRecurse(childHome);
	mkdirRecurse(profileRoot);
	auto shell = environment.get("SHELL", "/bin/sh");
	auto hostEnv = environment.toAA();
	auto sleep = resolveExecutablePath("sleep", hostEnv);
	assert(sleep.length > 0);
	write(fakeBwrap, "#!" ~ shell ~ "\n"
		~ "while [ \"$1\" != \"--\" ]; do shift; done\n"
		~ "shift\n"
		~ "exec \"$@\"\n");
	write(fakeCodex, "#!" ~ shell ~ "\n"
		~ "case \"$*\" in\n"
		~ "*one-shot-failure*)\n"
		~ "\t\"" ~ sleep ~ "\" 0.05\n"
		~ "\tprintf 'one-shot failure\\n' >&2\n"
		~ "\texit 17\n"
		~ "\t;;\n"
		~ "*)\n"
		~ "\tprintf 'one-shot success\\n'\n"
		~ "\t;;\n"
		~ "esac\n");
	assert(execute(["chmod", "+x", fakeBwrap]).status == 0);
	assert(execute(["chmod", "+x", fakeCodex]).status == 0);

	auto oldHome = environment.get("HOME", "");
	auto oldPath = environment.get("PATH", "");
	auto oldUser = environment.get("USER", "");
	bool hadUser = "USER" in environment;
	scope (exit)
	{
		environment["HOME"] = oldHome;
		environment["PATH"] = oldPath;
		if (hadUser)
			environment["USER"] = oldUser;
		else
			environment.remove("USER");
	}
	environment["HOME"] = hostHome;
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	environment["USER"] = "root";

	auto agent = new CodexAgent();
	auto rule = agent.nativeHistoryRule;
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = childHome;
	sandbox.env["PATH"] = fakeBin;
	sandbox.env["CODEX_HOME"] = profileRoot;
	sandbox.gitName = "one-shot clone temp ownership";
	sandbox.paths.require(root, PathAccess.rw,
		SandboxPathOrigin(SandboxPathOriginKind.launchRequirement,
			"one-shot clone temp ownership", "test root"));
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	auto source = prepareProcessLaunch(sandbox, rule, profile, "", fakeCodex);
	bool sourceCleaned;
	scope (exit)
		if (!sourceCleaned)
			cleanup(source.sandbox);
	auto sourceOwnedTemp = buildPath(root, "source-owned-temp");
	write(sourceOwnedTemp, "source-owned");
	source.preProfileSandbox.tempFiles ~= sourceOwnedTemp;
	source.sandbox.tempFiles ~= sourceOwnedTemp;
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto sourcePreProfilePaths = source.preProfileSandbox.paths.snapshot;
	auto sourcePreProfileEnv = source.preProfileSandbox.env.dup;
	auto sourcePreProfileTempFiles = source.preProfileSandbox.tempFiles.dup;
	assert(sourceTempFiles.canFind(sourceOwnedTemp));
	assert(sourcePreProfileTempFiles.canFind(sourceOwnedTemp));
	auto oneShotParent = buildPath(profileRoot, "oneshot");
	string[] tempEntries()
	{
		string[] entries;
		foreach (entry; dirEntries(tempDir(), SpanMode.shallow))
			entries ~= entry.name;
		return entries;
	}
	void assertSourceUnchanged()
	{
		assert(source.nativeHistoryProfile.driver == AgentDriver.codex);
		assert(source.nativeHistoryProfile.root == profileRoot);
		assert(source.sandbox.paths.snapshot == sourcePaths);
		assert(source.sandbox.env == sourceEnv);
		assert(source.sandbox.tempFiles == sourceTempFiles);
		assert(source.cmdPrefix == sourcePrefix);
		assert(source.preProfileSandbox.paths.snapshot == sourcePreProfilePaths);
		assert(source.preProfileSandbox.env == sourcePreProfileEnv);
		assert(source.preProfileSandbox.tempFiles == sourcePreProfileTempFiles);
	}
	void assertOneShotArtifactsRemoved(string outcome, const string[] tempEntriesBefore)
	{
		assert(exists(sourceOwnedTemp), outcome ~ " removed source-owned temp file");
		foreach (tempFile; sourceTempFiles)
			assert(exists(tempFile), outcome ~ " removed source temp file: " ~ tempFile);
		if (exists(oneShotParent))
			foreach (entry; dirEntries(oneShotParent, SpanMode.shallow))
				assert(false, outcome ~ " leaked one-shot home: " ~ entry.name);
		foreach (entry; dirEntries(tempDir(), SpanMode.shallow))
			assert(tempEntriesBefore.canFind(entry.name),
				outcome ~ " leaked clone prefix temp file: " ~ entry.name);
		assertSourceUnchanged();
	}

	auto tempEntriesBeforeSuccess = tempEntries();
	auto success = agent.completeOneShot("one-shot-success", "small", source);
	assert(success.cancel !is null);
	bool fulfilled;
	bool successRejected;
	bool baselineAtSuccess;
	string response;
	success.promise.then((string result) {
		fulfilled = true;
		baselineAtSuccess = exists(sourceOwnedTemp);
		response = result;
	}).except((Exception) {
		successRejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(fulfilled);
	assert(!successRejected);
	assert(response == "one-shot success");
	assert(baselineAtSuccess);
	assertOneShotArtifactsRemoved("successful one-shot", tempEntriesBeforeSuccess);

	auto tempEntriesBeforeFailure = tempEntries();
	auto failure = agent.completeOneShot("one-shot-failure", "small", source);
	assert(failure.cancel !is null);
	bool failureFulfilled;
	bool rejected;
	bool baselineAtFailure;
	failure.promise.then((string) {
		failureFulfilled = true;
	}).except((Exception) {
		rejected = true;
		baselineAtFailure = exists(sourceOwnedTemp);
	}).ignoreResult();
	socketManager.loop();
	assert(!failureFulfilled);
	assert(rejected);
	assert(baselineAtFailure);
	assertOneShotArtifactsRemoved("nonzero one-shot", tempEntriesBeforeFailure);

	cleanup(source.sandbox);
	sourceCleaned = true;
	assert(!exists(sourceOwnedTemp));
	assert(source.sandbox.tempFiles.length == 0);
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;
	import cydo.runtime.launch.types : NativeHistoryProfile, ProcessLaunch;

	auto root = buildPath("/tmp", "cydo-codex-oneshot-settings-copy-failure");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto profileRoot = buildPath(root, "profile");
	mkdirRecurse(buildPath(profileRoot, "config.toml"));

	ProcessLaunch launch;
	launch.nativeHistoryProfile = NativeHistoryProfile(AgentDriver.codex, profileRoot);
	auto handle = (new CodexAgent()).completeOneShot("prompt", "small", launch);
	assert(handle.cancel is null);
	bool rejected;
	handle.promise.except((Exception e) {
		rejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(rejected);
	auto oneShotParent = buildPath(profileRoot, "oneshot");
	if (exists(oneShotParent))
		foreach (entry; dirEntries(oneShotParent, SpanMode.shallow))
			assert(false, "settings-copy failure leaked one-shot home: " ~ entry.name);
}

unittest
{
	import ae.net.asockets : socketManager;
	import std.algorithm : canFind;
	import std.file : SpanMode, dirEntries, exists, mkdirRecurse, rmdirRecurse, write;
	import std.path : buildPath;
	import std.process : environment;
	import cydo.runtime.launch.sandbox : cleanup, prepareProcessLaunch,
		resolveNativeHistoryProfile;
	import cydo.runtime.launch.types : ResolvedSandbox;

	auto root = buildPath("/tmp", "cydo-codex-oneshot-clone-materialization-failure");
	if (exists(root))
		rmdirRecurse(root);
	scope (exit)
		if (exists(root))
			rmdirRecurse(root);
	auto fakeBin = buildPath(root, "bin");
	auto prefixTempDir = buildPath(root, "prefix-temps");
	auto hostHome = buildPath(root, "host-home");
	auto childHome = buildPath(root, "child-home");
	auto profileRoot = buildPath(root, "profile");
	mkdirRecurse(fakeBin);
	mkdirRecurse(prefixTempDir);
	mkdirRecurse(hostHome);
	mkdirRecurse(childHome);
	mkdirRecurse(profileRoot);
	write(buildPath(fakeBin, "bwrap"), "");
	write(buildPath(profileRoot, "config.toml"), "provider = \"configured\"\n");

	auto oldHome = environment.get("HOME", "");
	auto oldPath = environment.get("PATH", "");
	auto oldTmpDir = environment.get("TMPDIR", "");
	auto oldUser = environment.get("USER", "");
	bool hadTmpDir = "TMPDIR" in environment;
	bool hadUser = "USER" in environment;
	scope (exit)
	{
		environment["HOME"] = oldHome;
		environment["PATH"] = oldPath;
		if (hadTmpDir)
			environment["TMPDIR"] = oldTmpDir;
		else
			environment.remove("TMPDIR");
		if (hadUser)
			environment["USER"] = oldUser;
		else
			environment.remove("USER");
	}
	environment["HOME"] = hostHome;
	environment["PATH"] = fakeBin ~ ":" ~ oldPath;
	environment["TMPDIR"] = prefixTempDir;
	environment["USER"] = "root";

	auto agent = new CodexAgent();
	auto rule = agent.nativeHistoryRule;
	ResolvedSandbox sandbox;
	sandbox.isolate_filesystem = true;
	sandbox.env["HOME"] = childHome;
	sandbox.env["CODEX_HOME"] = profileRoot;
	auto profile = resolveNativeHistoryProfile(sandbox, rule);
	auto source = prepareProcessLaunch(sandbox, rule, profile, "");
	cleanup(source.sandbox);
	source.preProfileSandbox.gitName = "clone materialization failure";
	mkdirRecurse(buildPath(hostHome, ".config", "git", "config"));
	auto sourceOwnedTemp = buildPath(root, "source-owned-temp");
	write(sourceOwnedTemp, "source-owned");
	source.preProfileSandbox.tempFiles ~= sourceOwnedTemp;
	source.sandbox.tempFiles ~= sourceOwnedTemp;
	auto sourcePaths = source.sandbox.paths.snapshot;
	auto sourceEnv = source.sandbox.env.dup;
	auto sourceTempFiles = source.sandbox.tempFiles.dup;
	auto sourcePrefix = source.cmdPrefix.dup;
	auto sourcePreProfilePaths = source.preProfileSandbox.paths.snapshot;
	auto sourcePreProfileEnv = source.preProfileSandbox.env.dup;
	auto sourcePreProfileTempFiles = source.preProfileSandbox.tempFiles.dup;
	assert(sourceTempFiles.canFind(sourceOwnedTemp));
	assert(sourcePreProfileTempFiles.canFind(sourceOwnedTemp));
	bool sourceBaselineCleaned;
	scope (exit)
		if (!sourceBaselineCleaned)
			cleanup(source.sandbox);

	auto handle = agent.completeOneShot("prompt", "small", source);
	assert(handle.cancel is null);
	bool rejected;
	handle.promise.except((Exception e) {
		rejected = true;
	}).ignoreResult();
	socketManager.loop();
	assert(rejected);
	assert(exists(sourceOwnedTemp));
	assert(source.sandbox.paths.snapshot == sourcePaths);
	assert(source.sandbox.env == sourceEnv);
	assert(source.sandbox.tempFiles == sourceTempFiles);
	assert(source.cmdPrefix == sourcePrefix);
	assert(source.preProfileSandbox.paths.snapshot == sourcePreProfilePaths);
	assert(source.preProfileSandbox.env == sourcePreProfileEnv);
	assert(source.preProfileSandbox.tempFiles == sourcePreProfileTempFiles);
	auto oneShotParent = buildPath(profileRoot, "oneshot");
	if (exists(oneShotParent))
		foreach (entry; dirEntries(oneShotParent, SpanMode.shallow))
			assert(false, "clone materialization failure leaked one-shot home: " ~ entry.name);
	foreach (entry; dirEntries(prefixTempDir, SpanMode.shallow))
		assert(false, "clone materialization failure leaked prefix temp file: " ~ entry.name);
	cleanup(source.sandbox);
	sourceBaselineCleaned = true;
	assert(!exists(sourceOwnedTemp));
	assert(source.sandbox.tempFiles.length == 0);
}

private class AppServerStartupGate
{
	bool busy;
	AppServerStartupRequest[] queue;
}

private class AppServerStartupRequest
{
	this(string codexHome, AppServerProcess server)
	{
		this.codexHome = codexHome;
		this.server = server;
	}
	string codexHome;
	AppServerProcess server;
	bool cancelled;
	AppServerStartupLease lease;
}

private class AppServerStartupLease
{
	this(string codexHome, AppServerStartupRequest request)
	{
		this.codexHome = codexHome;
		this.request = request;
	}
	string codexHome;
	AppServerStartupRequest request;
	TimerTask timeout;
	bool released;
}

// ---------------------------------------------------------------------------
// CodexSession — one Codex thread, implementing AgentSession.
// ---------------------------------------------------------------------------

class CodexSession : AgentSession
{
	private AppServerProcess server;
	private void delegate(CodexSession owner) releaseLivePaths_;
	private int tid;
	private string threadId;
	private string nativeSessionId_;
	private void delegate(string sessionId) nativeSessionStartedHandler_;
	private bool routeReady_;
	private void delegate() routeReadyHandler_;
	private CodexForkPathLease[CodexHistoryKey] forkPaths_;
	private string activeTurnId_;
	private string model;
	private string workDir;
	private bool alive_;
	private bool turnInProgress;
	private bool hadItemsSinceLastStop_;

	// Active item tracking for item/delta routing.
	private string activeItemId_;              // most recently started item (for delta routing)
	private string[string] activeItemTypes_;   // itemId → itemType for all active items
	private int itemCounter_;                  // monotonic counter for generating item IDs
	private string lastResultText_;             // last completed text content, for turn/result

	private string sessionId;
	private string agentName_;

	private enum SubmissionOperation { queued, starting, steering }

	/// One caller-owned submission through readiness, request response, and echo.
	private static final class PendingMessage
	{
		ContentBlock[] content;
		string text;
		string correlationId;
		bool isContextBootstrap;
		SubmissionOperation operation;
		Promise!AgentSubmissionReceipt promise;
		bool settled;
		bool accepted;
		TranslatedEvent gatedUserEcho;
		bool hasGatedUserEcho;

		this(const(ContentBlock)[] content, string text, string correlationId,
			bool isContextBootstrap)
		{
			this.content = content.dup;
			this.text = text;
			this.correlationId = correlationId;
			this.isContextBootstrap = isContextBootstrap;
			this.operation = SubmissionOperation.queued;
			this.promise = new Promise!AgentSubmissionReceipt;
		}
	}

	// Records pending thread readiness or a request response.
	private PendingMessage[] pendingMessages_;
	private PendingMessage[] inFlightMessages_;
	// Sent records stay in native echo order until either their response and
	// echo have both arrived or their request is rejected.
	private PendingMessage[] expectedEchoMessages_;
	private bool startInFlight_;

	// Callbacks
	package void delegate(TranslatedEvent) outputHandler_;
	package void delegate(string line) stderrHandler_;
	private void delegate(int status) exitHandler_;

	this(AppServerProcess server, int tid, SessionConfig config,
		void delegate(CodexSession owner) releaseLivePaths = null)
	{
		this.server = server;
		this.tid = tid;
		this.alive_ = true;
		this.agentName_ = config.agentName;
		this.releaseLivePaths_ = releaseLivePaths;
	}

	package @property string currentThreadId() { return threadId; }

	package void notifyNativeSessionStarted(string id)
	{
		if (nativeSessionId_ !is null)
		{
			enforce(nativeSessionId_ == id,
				"Codex session reported conflicting native session IDs");
			return;
		}
		nativeSessionId_ = id;
		if (nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(id);
	}

	package void notifyRouteReady()
	{
		enforce(threadId.length > 0,
			"Codex route readiness requires a thread ID");
		routeReady_ = true;
		if (routeReadyHandler_)
			routeReadyHandler_();
	}

	package CodexForkPathLease registerForkPath(
		const ref NativeHistoryProfile profile, string childSessionId, string childPath)
	{
		enforce(profile.driver == AgentDriver.codex,
			"Codex fork path requires a Codex child profile");
		enforce(childSessionId.length > 0,
			"Codex fork path requires a child session ID");
		auto sessionsRoot = buildPath(profile.root, "sessions");
		enforce(childPath.length > 0 && isAbsolute(childPath)
			&& (childPath == sessionsRoot || childPath.startsWith(sessionsRoot ~ "/")),
			"Codex fork path is not inside the child profile sessions directory");
		auto key = CodexHistoryKey(profile.root, childSessionId);
		enforce(key !in forkPaths_,
			"Codex fork path lease already exists for the child session");
		auto lease = new CodexForkPathLease(this, key, childPath);
		forkPaths_[key] = lease;
		return lease;
	}

	private void releaseForkPath(CodexForkPathLease lease)
	{
		if (lease is null || lease.released_)
			return;
		auto current = lease.key_ in forkPaths_;
		if (current !is null && *current is lease)
			forkPaths_.remove(lease.key_);
		lease.released_ = true;
	}

	private void releaseAllForkPaths()
	{
		auto leases = forkPaths_.values;
		forkPaths_ = null;
		foreach (lease; leases)
			lease.released_ = true;
	}

	private void releaseNativeHistoryPaths()
	{
		releaseAllForkPaths();
		if (releaseLivePaths_)
			releaseLivePaths_(this);
	}

	package CodexSessionRouteTarget asRouteTarget()
	{
		return CodexSessionRouteTarget(
			&handleItemStarted,
			&handleDelta,
			&handleTerminalInteraction,
			&handleItemCompleted,
			&handleTurnCompleted,
			&handleTurnStarted,
			&handleTokenUsageUpdated,
			&onServerExit,
			(string line) {
				if (stderrHandler_)
					stderrHandler_(line);
			},
			(TranslatedEvent ev) {
				if (outputHandler_)
					outputHandler_(ev);
			},
		);
	}

	/// Called when thread/start or thread/resume response arrives.
	package void onThreadStarted(ThreadStartResult result, string resumeId,
		string model, string workDir, string rawResultJson)
	{
		this.model = model;
		this.workDir = workDir;

		if (result.thread.id.length > 0)
			threadId = result.thread.id;

		if (threadId.length == 0 && resumeId.length > 0)
			threadId = resumeId;

		if (threadId.length == 0)
		{
			if (outputHandler_)
			{
				ProcessStderrEvent ev;
				ev.text = "Failed to start Codex thread";
				outputHandler_(TranslatedEvent(toJson(ev), null));
			}
			onThreadStartFailed(new Exception("Failed to start Codex thread"));
			return;
		}

		sessionId = threadId;
		server.registerSession(threadId, asRouteTarget());
		notifyNativeSessionStarted(threadId);
		notifyRouteReady();

		// Emit synthetic session/init with raw RPC response as _raw.
		import cydo.protocol : SessionInitEvent, SessionMetadataEvent;
		SessionInitEvent initEv;
		initEv.session_id      = threadId;
		initEv.model           = model;
		initEv.cwd             = workDir;
		initEv.tools           = [];
		initEv.agent_version   = "";
		initEv.permission_mode = "dangerously-skip-permissions";
		initEv.agent           = "codex";
		initEv.agent_name      = agentName_;

		// On resume the JSONL-derived session_meta line provides a canonical
		// session/init; a second synthetic one here would duplicate it.
		if (outputHandler_ && resumeId.length == 0)
			outputHandler_(TranslatedEvent(toJson(initEv), rawResultJson.length > 0 ? rawResultJson : null));

		if (outputHandler_)
		{
			SessionMetadataEvent metadataEv;
			metadataEv.model = model;
			outputHandler_(TranslatedEvent(toJson(metadataEv), null));
		}

		// Drain queued messages now that the thread is ready.
		drainPendingMessages();
	}

	package void onThreadStartFailed(Exception error)
	{
		rejectUnsettledMessages(error);
		closeStdin();
	}

	private void drainPendingMessages()
	{
		if (!alive_)
			return;
		while (pendingMessages_.length > 0)
		{
			if (threadId.length == 0 || startInFlight_
				|| (turnInProgress && activeTurnId_.length == 0))
				return;
			auto submission = pendingMessages_[0];
			pendingMessages_ = pendingMessages_[1 .. $];
			submitMessage(submission);
			if (submission.operation == SubmissionOperation.starting)
				return;
		}
	}

	private void removeInFlightMessage(PendingMessage submission)
	{
		foreach (i, candidate; inFlightMessages_)
			if (candidate is submission)
			{
				inFlightMessages_ = inFlightMessages_[0 .. i]
					~ inFlightMessages_[i + 1 .. $];
				return;
			}
		assert(false, "Codex submission response has no in-flight record");
	}

	private void removeExpectedEchoMessage(PendingMessage submission)
	{
		foreach (i, candidate; expectedEchoMessages_)
			if (candidate is submission)
			{
				expectedEchoMessages_ = expectedEchoMessages_[0 .. i]
					~ expectedEchoMessages_[i + 1 .. $];
				return;
			}
		assert(false, "Codex submission response has no expected user echo");
	}

	private void rejectSubmission(PendingMessage submission, Exception error)
	{
		if (submission.settled)
			return;
		submission.settled = true;
		submission.promise.reject(error);
	}

	private void emitAcceptedUserEcho(PendingMessage submission,
		TranslatedEvent event)
	{
		assert(submission.accepted,
			"Codex user echo emitted before request acceptance");
		auto output = outputHandler_;
		// Queue after fulfillment so App commits acceptance before translating it.
		onNextTick(socketManager, {
			if (output)
				output(event);
		});
	}

	private void releaseGatedUserEcho(PendingMessage submission)
	{
		if (!submission.hasGatedUserEcho)
			return;
		auto event = submission.gatedUserEcho;
		submission.gatedUserEcho = TranslatedEvent.init;
		submission.hasGatedUserEcho = false;
		removeExpectedEchoMessage(submission);
		emitAcceptedUserEcho(submission, event);
	}

	private void fulfillSubmission(PendingMessage submission)
	{
		assert(!submission.settled,
			"Codex submission settled more than once");
		submission.accepted = true;
		submission.settled = true;
		submission.promise.fulfill(AgentSubmissionReceipt.appServerAccepted);
		releaseGatedUserEcho(submission);
	}

	private void rejectUnsettledMessages(Exception error)
	{
		auto queued = pendingMessages_;
		pendingMessages_ = null;
		foreach (submission; queued)
			rejectSubmission(submission, error);

		auto inFlight = inFlightMessages_;
		inFlightMessages_ = null;
		foreach (submission; inFlight)
			rejectSubmission(submission, error);

		expectedEchoMessages_ = null;
		startInFlight_ = false;
	}

	private void resetRejectedStart()
	{
		startInFlight_ = false;
		turnInProgress = false;
		activeTurnId_ = null;
		activeItemId_ = null;
		activeItemTypes_ = null;
		hadItemsSinceLastStop_ = false;
	}

	private void submitSteer(PendingMessage submission)
	{
		submission.operation = SubmissionOperation.steering;
		inFlightMessages_ ~= submission;
		expectedEchoMessages_ ~= submission;
		try
		{
			server.sendRequest("turn/steer",
				toJson(TurnSteerParams(threadId,
					[TurnStartInput("text", submission.text)], activeTurnId_)))
				.then((JsonRpcResponse response) {
					if (submission.settled)
						return;
					removeInFlightMessage(submission);
					if (response.isError)
					{
						removeExpectedEchoMessage(submission);
						rejectSubmission(submission,
							new Exception(response.error.get.message));
						return;
					}
					fulfillSubmission(submission);
				}, (Exception e) {
					if (submission.settled)
						return;
					removeInFlightMessage(submission);
					removeExpectedEchoMessage(submission);
					rejectSubmission(submission, e);
				}).ignoreResult();
		}
		catch (Exception e)
		{
			removeInFlightMessage(submission);
			removeExpectedEchoMessage(submission);
			rejectSubmission(submission, e);
		}
	}

	private void submitStart(PendingMessage submission)
	{
		submission.operation = SubmissionOperation.starting;
		turnInProgress = true;
		startInFlight_ = true;
		activeTurnId_ = null;
		activeItemId_ = null;
		activeItemTypes_ = null;
		hadItemsSinceLastStop_ = false;
		inFlightMessages_ ~= submission;
		expectedEchoMessages_ ~= submission;
		try
		{
			server.sendRequest("turn/start",
				toJson(TurnStartParams(threadId,
					[TurnStartInput("text", submission.text)],
					SandboxPolicy("externalSandbox", "enabled"))))
				.then((JsonRpcResponse response) {
					if (submission.settled)
						return;
					removeInFlightMessage(submission);
					try
					{
						auto result = response.getResult!TurnStartResult();
						if (result.turn.id.length == 0)
							throw new Exception("turn/start returned an empty turn id");
						activeTurnId_ = result.turn.id;
						startInFlight_ = false;
						fulfillSubmission(submission);
						drainPendingMessages();
					}
					catch (Exception e)
					{
						removeExpectedEchoMessage(submission);
						resetRejectedStart();
						rejectSubmission(submission, e);
						drainPendingMessages();
					}
				}, (Exception e) {
					if (submission.settled)
						return;
					removeInFlightMessage(submission);
					removeExpectedEchoMessage(submission);
					resetRejectedStart();
					rejectSubmission(submission, e);
					drainPendingMessages();
				}).ignoreResult();
		}
		catch (Exception e)
		{
			removeInFlightMessage(submission);
			removeExpectedEchoMessage(submission);
			resetRejectedStart();
			rejectSubmission(submission, e);
			drainPendingMessages();
		}
	}

	private void submitMessage(PendingMessage submission)
	{
		assert(!submission.settled,
			"Codex queued submission was already settled");
		assert(threadId.length > 0,
			"Codex submission requires a ready thread");
		if (turnInProgress)
		{
			assert(activeTurnId_.length > 0,
				"Codex submission cannot steer without an active turn id");
			submitSteer(submission);
		}
		else
			submitStart(submission);
	}

	package void handleTurnStarted(TurnRef turn)
	{
		if (turn.id.length == 0)
			return;
		activeTurnId_ = turn.id;
		if (!startInFlight_)
			drainPendingMessages();
	}

	/// Called when the app-server process dies.
	package void onServerExit(int status)
	{
		rejectUnsettledMessages(new Exception("Codex app-server exited before accepting message submission"));
		releaseNativeHistoryPaths();
		if (!alive_)
			return; // Already stopped; avoid double-invocation of exitHandler_.
		alive_ = false;
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(status);
	}

	// ----- AgentSession interface -----

	Promise!AgentSubmissionReceipt sendMessage(const(ContentBlock)[] content, string correlationId = null,
		bool isContextBootstrap = false)
	{
		// Extract text (only text blocks supported; throw on others).
		string text;
		foreach (ref b; content)
		{
			if (b.type == "text") text ~= b.text;
			else throw new Exception("Unsupported content block type for Codex: " ~ b.type);
		}

		auto submission = new PendingMessage(content, text, correlationId,
			isContextBootstrap);
		if (!alive_)
		{
			submission.promise.reject(new Exception(
				"Codex session is no longer alive"));
			return submission.promise;
		}

		if (threadId.length == 0 || startInFlight_
			|| (turnInProgress && activeTurnId_.length == 0))
			pendingMessages_ ~= submission;
		else
			submitMessage(submission);
		return submission.promise;
	}

	void invalidatePendingSubmittedMessages()
	{
		rejectUnsettledMessages(new Exception(
			"Codex message submission was invalidated"));
	}

	@property bool supportsImages() const { return false; }

	@property bool canRollbackThread() const
	{
		return alive_ && threadId.length > 0 && !turnInProgress;
	}

	void interrupt()
	{
		if (!alive_ || threadId.length == 0 || !turnInProgress || activeTurnId_.length == 0)
			return;
		server.sendRequest("turn/interrupt",
			toJson(TurnInterruptParams(threadId, activeTurnId_))).ignoreResult();
	}

	void sigint()
	{
		interrupt();
	}

	void stop()
	{
		if (!alive_)
			return;
		rejectUnsettledMessages(new Exception(
			"Codex session closed before accepting message submission"));
		// Codex sessions share a pooled app-server process. Kill is an
		// emergency stop that terminates that process and lets onServerExit
		// propagate the real exit to all attached sessions.
		server.terminate();
	}

	void closeStdin()
	{
		rejectUnsettledMessages(new Exception(
			"Codex session closed before accepting message submission"));
		releaseNativeHistoryPaths();
		if (!alive_)
			return;
		if (threadId.length > 0)
			server.unregisterSession(threadId);
		server.unregisterSessionByTid(tid);
		activeTurnId_ = null;
		alive_ = false;
		auto cb = exitHandler_;
		exitHandler_ = null;
		if (cb)
			cb(0); // zero = clean close
	}

	void killAfterTimeout(Duration timeout) {} // no-op: closeStdin fires exit immediately

	@property bool canStopAfterCloseStdin() const
	{
		return true;
	}

	@property void onNativeSessionStarted(void delegate(string sessionId) callback)
	{
		nativeSessionStartedHandler_ = callback;
		if (nativeSessionId_ !is null && nativeSessionStartedHandler_)
			nativeSessionStartedHandler_(nativeSessionId_);
	}
	package @property void onRouteReady(void delegate() callback)
	{
		routeReadyHandler_ = callback;
		if (routeReady_ && routeReadyHandler_)
			routeReadyHandler_();
	}

	@property void onOutput(void delegate(TranslatedEvent) dg) { outputHandler_ = dg; }
	@property void onStderr(void delegate(string line) dg) { stderrHandler_ = dg; }
	@property void onExit(void delegate(int status) dg) { exitHandler_ = dg; }
	@property bool alive() { return alive_ && !server.dead; }

	// ----- Notification handling (routed by CodexServerRouter) -----

	package void handleItemStarted(ItemStartedParams params, string rawNotification)
	{
		import cydo.protocol : ItemStartedEvent;
		if (params.turnId.length > 0)
			activeTurnId_ = params.turnId;

		auto item = params.item;

		ItemStartedEvent ev;

		if (item.type == "userMessage")
		{
			// Echo user message as item/started type=user_message.
			if (item.content && outputHandler_)
			{
				ev.item_type = "user_message";
				// Extract text from content array: [{type:"input_text",text:"..."}]
				@JSONPartial
				static struct InputTextItem { @JSONOptional string text; }
				string userText;
				try
				{
					auto items = jsonParse!(InputTextItem[])(toJson(item.content));
					foreach (ref i; items)
						userText ~= i.text;
				}
				catch (Exception) {}
				if (userText.length == 0)
					userText = item.text;
				ev.item_id = "codex-user-" ~ to!string(itemCounter_++);
				ContentBlock cb;
				cb.type = "text";
				cb.text = userText;
				ev.content = [cb];
				assert(expectedEchoMessages_.length > 0,
					"Codex native user echo has no expected submission");
				auto submission = expectedEchoMessages_[0];
				assert(userText == submission.text,
					"Codex native user echo text does not match expected submission");
				ev.correlation_id = submission.correlationId;
				auto translated = TranslatedEvent(toJson(ev), rawNotification,
					AbsTime.init, 0, submission.isContextBootstrap);
				if (submission.accepted)
				{
					expectedEchoMessages_ = expectedEchoMessages_[1 .. $];
					emitAcceptedUserEcho(submission, translated);
				}
				else
				{
					assert(!submission.hasGatedUserEcho,
						"Codex submission received multiple native user echoes");
					submission.gatedUserEcho = translated;
					submission.hasGatedUserEcho = true;
				}
				return;
			}
			return;
		}

		// Assign item ID: use native id if available, else generate one.
		auto itemId = item.id.length > 0 ? item.id : "codex-item-" ~ to!string(itemCounter_++);
		activeItemId_ = itemId;

		switch (item.type)
		{
			case "agentMessage":
				activeItemTypes_[itemId] = "text";
				ev.item_type = "text";
				// Reset + capture text for result extraction. Text may arrive
				// fully formed here (no deltas) or be empty with deltas following.
				lastResultText_ = item.text;
				break;
			case "reasoning":
				activeItemTypes_[itemId] = "thinking";
				ev.item_type = "thinking";
				break;
			case "commandExecution":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "commandExecution";
				string cmdInput = extractCommandExecutionInput(
					item.commandActions ? JSONFragment(toJson(item.commandActions)) : JSONFragment.init,
					item.action ? JSONFragment(toJson(item.action)) : JSONFragment.init,
					item.command);
				if (cmdInput.length > 0 && cmdInput != `{}`)
					ev.input = JSONFragment(cmdInput);
				break;
			case "fileChange":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "fileChange";
				// Include changes directly so the frontend can show the File Viewer button
				// without relying on _raw (which is stripped before broadcast).
				if (item.changes)
					ev.input = JSONFragment(`{"changes":` ~ toJson(item.changes) ~ `}`);
				break;
			case "mcpToolCall":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				if (item.tool.length > 0)
				{
					ev.name = item.tool;
					if (item.server.length > 0)
					{
						ev.tool_server = item.server;
						ev.tool_source = "mcp";
					}
				}
				else
					ev.name = item.name.length > 0 ? item.name : "unknown";
				if (item.arguments_)
					ev.input = JSONFragment(toJson(item.arguments_));
				break;
			case "webSearch":
				activeItemTypes_[itemId] = "tool_use";
				ev.item_type = "tool_use";
				ev.name = "webSearch";
				if (item.query)
					ev.input = JSONFragment(`{"query":` ~ toJson(item.query) ~ `}`);
				break;
			case "contextCompaction":
				activeItemTypes_[itemId] = "contextCompaction";
				import cydo.protocol : SessionStatusEvent;
				SessionStatusEvent statusEv;
				statusEv.status = "Compacting context...";
				if (outputHandler_)
					outputHandler_(TranslatedEvent(toJson(statusEv), rawNotification));
				return;  // Emit session/status instead of item/started
			default:
				activeItemTypes_[itemId] = "text";
				ev.item_type = "text";
				break;
		}
		hadItemsSinceLastStop_ = true;

		ev.item_id = itemId;

		// If item/started already contains text (e.g. during history replay),
		// include it directly in the event.
		if (item.text.length > 0)
			ev.text = item.text;

		// Forward Codex extras (processId, status, cwd, commandActions, etc.) to extras.
		ev.extras = extrasToFragment(item.extras);

		if (outputHandler_)
			outputHandler_(TranslatedEvent(toJson(ev), rawNotification));
	}

	/// Handle any delta notification (text, thinking, or command output).
	package void handleDelta(DeltaParams params, string deltaType, string rawNotification)
	{
		if (outputHandler_ is null)
			return;
		auto itemId = params.itemId.length > 0 ? params.itemId : activeItemId_;
		if (itemId.length == 0)
			return;

		// Accumulate text deltas for result extraction.
		if (deltaType == "text_delta")
		{
			auto pType = itemId in activeItemTypes_;
			if (pType !is null && *pType == "text")
				lastResultText_ ~= params.delta;
		}

		import cydo.protocol : ItemDeltaEvent;
		ItemDeltaEvent ev;
		ev.item_id = itemId;
		ev.delta_type = deltaType;
		ev.content = params.delta;
		outputHandler_(TranslatedEvent(toJson(ev), rawNotification));
	}

	/// Handle terminal interaction notification (stdin written to a running process).
	package void handleTerminalInteraction(TerminalInteractionParams params, string rawNotification)
	{
		if (outputHandler_ is null)
			return;

		import cydo.protocol : ItemDeltaEvent;
		ItemDeltaEvent ev;
		ev.item_id = params.itemId.length > 0 ? params.itemId : activeItemId_;
		ev.delta_type = "stdin_delta";
		ev.content = params.stdin;
		outputHandler_(TranslatedEvent(toJson(ev), rawNotification));
	}

	package void handleItemCompleted(ItemCompletedParams params, string rawNotification)
	{
		// Determine which item completed: prefer explicit ID from params.
		string itemId = (params.item.id.length > 0) ? params.item.id : activeItemId_;
		if (itemId.length == 0)
			return;

		// Look up item type from map.
		auto pType = itemId in activeItemTypes_;
		if (pType is null)
			return; // unknown item, skip
		string itemType = *pType;

		if (itemType == "contextCompaction")
		{
			// Codex 0.139 reports compaction as an item instead of sending the
			// older thread/compacted notification.  Clear the transient status
			// and emit CyDo's durable compact-boundary event.
			import cydo.protocol : SessionStatusEvent;
			SessionStatusEvent clearEv;
			if (outputHandler_)
			{
				outputHandler_(TranslatedEvent(toJson(clearEv), rawNotification));
				outputHandler_(TranslatedEvent(toJson(SessionCompactedEvent()), rawNotification));
			}
			activeItemTypes_.remove(itemId);
			if (activeItemId_ == itemId)
				activeItemId_ = null;
			return;
		}

		import cydo.protocol : ItemCompletedEvent, ItemResultEvent;
		ItemCompletedEvent ev;
		ev.item_id = itemId;
		ev.is_error = params.item.is_error;
		// Derive is_error from Codex status field (Codex uses "failed" instead of is_error).
		if (!ev.is_error && params.item.status == "failed")
			ev.is_error = true;

		if (itemType == "tool_use" && params.item.aggregatedOutput.length > 0)
			ev.output = params.item.aggregatedOutput;

		// Forward remaining Codex extras (processId, commandActions, type, etc.) to extras.
		ev.extras = extrasToFragment(params.item.extras);

		// For webSearch items, propagate the completed query into the input field
		// so the frontend subtitle updates from the empty started-query to the real query.
		if (params.item.type == "webSearch" && params.item.query)
			ev.input = JSONFragment(`{"query":` ~ toJson(params.item.query) ~ `}`);

		if (outputHandler_)
			outputHandler_(TranslatedEvent(toJson(ev), rawNotification));

		// Emit item/result for tool_use items so the frontend can display the output.
		// item/result must come AFTER item/completed so the tool_use block is
		// already in content[] when reduceItemResult searches for it.
		if (itemType == "tool_use" && outputHandler_)
		{
			ItemResultEvent resEv;
			resEv.item_id = itemId;
			resEv.is_error = ev.is_error;
			string toolErrorMessage;
			if (resEv.is_error && params.item.error)
			{
				@JSONPartial
				static struct ItemErrorPayload
				{
					@JSONOptional string message;
				}

				try
				{
					toolErrorMessage = jsonParse!ItemErrorPayload(toJson(params.item.error)).message;
				}
				catch (Exception) {}

				if (toolErrorMessage.length == 0)
				{
					try
					{
						toolErrorMessage = jsonParse!string(toJson(params.item.error));
					}
					catch (Exception) {}
				}
			}

			// Item type is now an explicit field.
			string itemTypeName = params.item.type;

			if (params.item.aggregatedOutput.length > 0)
				resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(params.item.aggregatedOutput) ~ `}]`);
			else
			{
				@JSONPartial
				static struct ResultPayload
				{
					@JSONOptional JSONFragment content;
					@JSONName("structuredContent") @JSONOptional JSONFragment structuredContent;
				}

				bool hasResultContent = false;
				if (params.item.result)
				{
					try
					{
						auto payload = jsonParse!ResultPayload(toJson(params.item.result));
						if (payload.content.json !is null)
						{
							resEv.content = payload.content;
							hasResultContent = true;
						}
						if (payload.structuredContent.json !is null)
							resEv.tool_result = payload.structuredContent;
					}
					catch (Exception) {}
				}

				if (!hasResultContent)
				{
					if (itemTypeName == "webSearch")
					{
						// Pass Codex web search data as structured tool_result for the frontend
						// to interpret. Set content to empty text (required field).
						if (toolErrorMessage.length > 0)
							resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(toolErrorMessage) ~ `}]`);
						else
							resEv.content = JSONFragment(`[{"type":"text","text":""}]`);

						import std.array : appender;
						auto tr = appender!string;
						tr ~= `{`;

						// Include the main query
						if (params.item.query)
							tr ~= `"query":` ~ toJson(params.item.query);

						// Include the queries array from action
						if (params.item.action)
						{
							@JSONPartial
							static struct WebSearchAction
							{
								@JSONOptional JSONFragment queries;  // preserve raw JSON
							}
							try
							{
								auto act = jsonParse!WebSearchAction(toJson(params.item.action));
								if (act.queries.json !is null)
								{
									if (params.item.query)
										tr ~= `,`;
									tr ~= `"queries":` ~ act.queries.json;
								}
							}
							catch (Exception) {}
						}

						tr ~= `}`;
						resEv.tool_result = JSONFragment(tr.data);
					}
					else if (toolErrorMessage.length > 0)
						resEv.content = JSONFragment(`[{"type":"text","text":` ~ toJson(toolErrorMessage) ~ `}]`);
					else
						resEv.content = JSONFragment(`[{"type":"text","text":""}]`);
				}
			}

			// Build structured tool_result for commandExecution items.
			// Surfaces exitCode, status, durationMs, command, cwd for frontend rendering.
			if (itemTypeName == "commandExecution")
			{
				import std.array : appender;
				auto tr = appender!string;
				tr ~= `{`;
				bool trFirst = true;
				if (params.item.status.length > 0)
				{
					tr ~= `"status":` ~ toJson(params.item.status);
					trFirst = false;
				}
				// Always include exitCode for commandExecution items.
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"exitCode":` ~ to!string(params.item.exitCode);
					trFirst = false;
				}
				if (params.item.durationMs > 0)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"durationMs":` ~ to!string(params.item.durationMs);
					trFirst = false;
				}
				if (params.item.command.length > 0)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"command":` ~ toJson(params.item.command);
					trFirst = false;
				}
				if (params.item.cwd.length > 0)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"cwd":` ~ toJson(params.item.cwd);
					trFirst = false;
				}
				if (params.item.processId.length > 0)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"processId":` ~ toJson(params.item.processId);
					trFirst = false;
				}
				if (params.item.commandActions)
				{
					if (!trFirst) tr ~= `,`;
					tr ~= `"commandActions":` ~ toJson(params.item.commandActions);
					trFirst = false;
				}
				tr ~= `}`;
				if (!trFirst)
					resEv.tool_result = JSONFragment(tr.data);
			}

			outputHandler_(TranslatedEvent(toJson(resEv), rawNotification));
		}

		// Remove from tracking.
		activeItemTypes_.remove(itemId);
		if (activeItemId_ == itemId)
			activeItemId_ = null;
	}

	package void handleTurnCompleted(TurnCompletedParams params, string rawNotification)
	{
		turnInProgress = false;
		activeTurnId_ = null;

		// Do NOT clear activeItemId_ or activeItemTypes_ here — background items
		// may still complete after the turn ends.

		// 1. turn/stop — only if items were emitted since the last intermediate stop
		if (hadItemsSinceLastStop_ && outputHandler_)
		{
			import cydo.protocol : TurnStopEvent, UsageInfo;
			TurnStopEvent tsev;
			tsev.model = model;
			tsev.usage = UsageInfo(0, 0);
			outputHandler_(TranslatedEvent(toJson(tsev), rawNotification));
		}
		hadItemsSinceLastStop_ = false;

		// 2. turn/result — always emitted
		if (outputHandler_)
		{
			import cydo.agent.drivers.codex.app_server : extractCodexErrorMessage;
			import cydo.protocol : TurnResultEvent, UsageInfo;
			TurnResultEvent tre;
			tre.num_turns = 1;
			tre.usage = UsageInfo(0, 0);
			tre.result = lastResultText_;
			if (params.turn.status == "failed")
			{
				auto message = extractCodexErrorMessage(params.turn.error);
				if (message.length == 0)
					message = "Unknown error";
				tre.subtype = "error";
				tre.is_error = true;
				tre.errors = [message];
				tre.result = lastResultText_.length > 0
					? lastResultText_ ~ "\n\n" ~ message : message;
			}
			else
				tre.subtype = "success";
			outputHandler_(TranslatedEvent(toJson(tre), rawNotification));
		}
		lastResultText_ = null;
		drainPendingMessages();
	}

	package void handleTokenUsageUpdated(TokenUsageUpdatedParams params, string rawNotification)
	{
		if (!turnInProgress || !hadItemsSinceLastStop_)
			return;

		hadItemsSinceLastStop_ = false;

		if (outputHandler_)
		{
			import cydo.protocol : TurnStopEvent, UsageInfo;
			TurnStopEvent tsev;
			tsev.model = model;
			if (params.tokenUsage != TokenUsagePayload.init
				&& params.tokenUsage.last != TokenUsageBreakdown.init)
				tsev.usage = UsageInfo(params.tokenUsage.last.inputTokens,
					params.tokenUsage.last.outputTokens);
			else
				tsev.usage = UsageInfo(0, 0);
			outputHandler_(TranslatedEvent(toJson(tsev), rawNotification));
		}
	}
}

version (unittest) private final class TestCodexConnection : IConnection
{
	string[] sentMessages;
	private ReadDataHandler readDataHandler;

	@property ConnectionState state()
	{
		return ConnectionState.connected;
	}

	void send(scope Data[] data, int priority = DEFAULT_PRIORITY)
	{
		ubyte[] message;
		foreach (ref datum; data)
			datum.enter((contents) { message ~= cast(ubyte[]) contents; });
		sentMessages ~= cast(string) message;
	}
	alias send = IConnection.send;

	JsonRpcRequest takeRequest(string expectedMethod)
	{
		assert(sentMessages.length > 0,
			"Codex test connection has no pending request");
		auto request = jsonParse!JsonRpcRequest(sentMessages[0]);
		sentMessages = sentMessages[1 .. $];
		assert(request.method == expectedMethod,
			"Unexpected Codex request method: " ~ request.method);
		assert(request.id, "Codex request has no JSON-RPC id");
		return request;
	}

	JsonRpcRequest takeRequest(Params)(string expectedMethod, string expectedText)
	{
		auto request = takeRequest(expectedMethod);
		auto params = jsonParse!Params(toJson(request.params));
		assert(params.input.length == 1 && params.input[0].text == expectedText,
			"Unexpected Codex request input");
		return request;
	}

	void respond(JsonRpcRequest request, JsonRpcResponse response)
	{
		import ae.utils.array : asBytes;

		assert(readDataHandler !is null,
			"Codex test connection has no response handler");
		response.id = request.id;
		readDataHandler(Data(toJson(response).asBytes));
	}

	void disconnect(string reason = defaultDisconnectReason,
		DisconnectType type = DisconnectType.requested)
	{
		assert(false, reason);
	}
	@property void handleConnect(ConnectHandler value) {}
	@property void handleReadData(ReadDataHandler value) { readDataHandler = value; }
	@property void handleDisconnect(DisconnectHandler value) {}
	@property void handleBufferFlushed(BufferFlushedHandler value) {}
}

version (unittest) private final class TestSubmissionOutcome
{
	int acceptedCount;
	int rejectedCount;
	string rejectionMessage;

	this(Promise!AgentSubmissionReceipt promise)
	{
		promise.then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			acceptedCount++;
		}, (Exception error) {
			rejectedCount++;
			rejectionMessage = error.msg;
		}).ignoreResult();
	}
}

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

private:

/// Build a JSON config override object passed as the "config" field in
/// thread/start params. Includes reasoning summary and, when available,
/// MCP server config for CyDo tools.
string buildConfigOverride(int tid, SessionConfig config)
{
	import std.array : join;
	import std.process : environment;

	JSONFragment[string] overrides;

	// Always request reasoning summaries from the model.
	overrides["model_reasoning_summary"] = JSONFragment(`"auto"`);

	// Verified against codex v0.147.0 (.cydo/tasks/34497/output.md): an unknown
	// config key here is silently ignored, so this key string is load-bearing.
	if (config.effort.length > 0)
		overrides["model_reasoning_effort"] = JSONFragment(toJson(config.effort));

	// Disable Codex's built-in multi-agent collaboration feature. CyDo agents must
	// delegate only via mcp__cydo__Task, never Codex's own spawn_agent/team tools.
	// Turning the feature off removes both the collaboration tools and the injected
	// "team of agents" framing in one shot.
	overrides["features.multi_agent"] = JSONFragment("false");

	// Force CyDo's MCP tools to be exposed as top-level DIRECT model tools rather
	// than nested inside Codex's code-mode `exec` sandbox. In code mode the exec
	// cell yields control back to the model after a 10s timer while an awaited
	// tools.mcp__cydo__Task(...) is still pending, which breaks the strict-blocking
	// invariant (parent must do no inference until the child completes). The
	// direct-call path awaits the full MCP result with no yield timer.
	// Note: features.code_mode=false is insufficient — model tool_mode metadata
	// ("code_mode_only") overrides the feature flag; this per-namespace knob wins.
	overrides["features.code_mode.direct_only_tool_namespaces"] = JSONFragment(`["mcp__cydo"]`);

	// If CYDO_CODEX_COMPACT_LIMIT is set (test-only), override compaction threshold.
	auto compactLimit = environment.get("CYDO_CODEX_COMPACT_LIMIT", "");
	if (compactLimit.length > 0)
	{
		overrides["model_auto_compact_token_limit"] = JSONFragment(compactLimit);
		overrides["model_context_window"] = JSONFragment(compactLimit);
	}

	auto cydoBin = cydoBinaryPath;
	if (cydoBin.length > 0)
	{
		string[string] env;
		env["CYDO_TID"] = to!string(tid);
		env["CYDO_SOCKET"] = config.mcpSocketPath;
		env["CYDO_CREATABLE_TYPES"] = config.creatableTaskTypes;
		env["CYDO_SWITCHMODES"] = config.switchModes;
		env["CYDO_HANDOFFS"] = config.handoffs;
		env["CYDO_INCLUDE_TOOLS"] = config.includeTools is null ? "" : config.includeTools.join(",");

		auto toolTimeout = environment.get("CYDO_TEST_CODEX_MCP_TOOL_TIMEOUT_SEC", "");
		auto serverConfig = McpServerConfig(
			cydoBin,
			["mcp-server"],
			env,
			toolTimeout.length > 0 ? to!uint(toolTimeout) : 100000000,
		);

		overrides["mcp_servers.cydo"] = JSONFragment(toJson(serverConfig));
	}

	return toJson(overrides);
}

unittest
{
	@JSONPartial struct StartedNotification { ItemStartedParams params; }
	@JSONPartial struct CompletedNotification { ItemCompletedParams params; }
	import cydo.protocol : TurnStopEvent;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);
	session.handleTurnStarted(TurnRef("turn"));
	auto compactStarted = jsonParse!StartedNotification(
		`{"params":{"turnId":"turn","item":{"id":"compact","type":"contextCompaction"}}}`);
	session.handleItemStarted(compactStarted.params, "compact-start");
	session.handleTokenUsageUpdated(TokenUsageUpdatedParams.init, "usage");
	auto compactCompleted = jsonParse!CompletedNotification(
		`{"params":{"item":{"id":"compact","type":"contextCompaction"}}}`);
	session.handleItemCompleted(compactCompleted.params, "compact-complete");
	import std.algorithm : canFind;
	assert(!emitted.canFind!(event => event.canFind(`"type":"turn/stop"`)));
	auto realStarted = jsonParse!StartedNotification(
		`{"params":{"turnId":"turn","item":{"id":"message","type":"agentMessage"}}}`);
	session.handleItemStarted(realStarted.params, "message-start");
	session.handleTurnCompleted(TurnCompletedParams("thread"), "turn-complete");
	int stops;
	foreach (event; emitted)
		if (event.canFind(`"type":"turn/stop"`)) stops++;
	assert(stops == 1);
}

unittest
{
	@JSONPartial struct EmittedTurnResult
	{
		string type;
		string subtype;
		@JSONOptional bool is_error;
		@JSONOptional string result;
		@JSONOptional string[] errors;
	}
	@JSONPartial struct CompletedNotification { TurnCompletedParams params; }
	@JSONPartial struct StartedNotification { ItemStartedParams params; }

	// A terminal turn failure (e.g. usage limit exceeded) must surface the
	// error in the turn/result event instead of reporting an empty success.
	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	session.onOutput((TranslatedEvent ev) { emitted ~= ev.translated; });
	auto failed = jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread-failed","turn":{"id":"turn-1","status":"failed",`
		~ `"error":{"message":"You've hit your usage limit.",`
		~ `"codexErrorInfo":"usageLimitExceeded","additionalDetails":null}}}}`);
	session.handleTurnCompleted(failed.params, "raw-failed");
	auto ev = jsonParse!EmittedTurnResult(emitted[$ - 1]);
	assert(ev.type == "turn/result");
	assert(ev.subtype == "error");
	assert(ev.is_error);
	assert(ev.result == "You've hit your usage limit.");
	assert(ev.errors == ["You've hit your usage limit."]);
	auto agent = new CodexAgent;
	assert(agent.isTurnResult(emitted[$ - 1]));
	assert(agent.extractResultText(emitted[$ - 1]) == "You've hit your usage limit.");

	// A failed turn that produced partial agent text keeps that text and
	// appends the error message.
	auto partialStarted = jsonParse!StartedNotification(
		`{"params":{"threadId":"thread-failed","turnId":"turn-2",`
		~ `"item":{"id":"msg","type":"agentMessage","text":"Partial answer."}}}`);
	session.handleItemStarted(partialStarted.params, "partial-start");
	session.handleTurnCompleted(failed.params, "raw-failed");
	ev = jsonParse!EmittedTurnResult(emitted[$ - 1]);
	assert(ev.is_error);
	assert(ev.result == "Partial answer.\n\nYou've hit your usage limit.");
	assert(ev.errors == ["You've hit your usage limit."]);

	// A failed turn with no error payload still reports an error.
	auto failedNoDetail = jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread-failed","turn":{"id":"turn-3","status":"failed","error":null}}}`);
	session.handleTurnCompleted(failedNoDetail.params, "raw-failed-no-detail");
	ev = jsonParse!EmittedTurnResult(emitted[$ - 1]);
	assert(ev.is_error);
	assert(ev.result == "Unknown error");
	assert(ev.errors == ["Unknown error"]);

	// A successful turn keeps the success subtype.
	auto ok = jsonParse!CompletedNotification(
		`{"params":{"threadId":"thread-failed","turn":{"id":"turn-4","status":"completed","error":null}}}`);
	session.handleTurnCompleted(ok.params, "raw-ok");
	ev = jsonParse!EmittedTurnResult(emitted[$ - 1]);
	assert(ev.subtype == "success");
	assert(!ev.is_error);
}

unittest
{
	import std.string : indexOf;

	SessionConfig noEffort;
	auto overrides = buildConfigOverride(1, noEffort);
	assert(overrides.indexOf(`"features.multi_agent":false`) >= 0,
		"Codex config must disable the built-in multi-agent feature; actual=" ~ overrides);
	assert(overrides.indexOf(`"features.code_mode.direct_only_tool_namespaces":["mcp__cydo"]`) >= 0,
		"Codex config must expose CyDo MCP tools as direct calls; actual=" ~ overrides);
	assert(overrides.indexOf(`"model_reasoning_effort"`) < 0,
		"empty effort must not add the key at all; actual=" ~ overrides);

	// 22. a non-empty effort adds the model_reasoning_effort key verbatim
	SessionConfig withEffort;
	withEffort.effort = "high";
	auto overridesWithEffort = buildConfigOverride(1, withEffort);
	assert(overridesWithEffort.indexOf(`"model_reasoning_effort":"high"`) >= 0,
		"Codex config must carry model_reasoning_effort; actual=" ~ overridesWithEffort);
}

/// Extract display-level command input from a live Codex commandExecution item.
string extractCommandExecutionInput(JSONFragment commandActions, JSONFragment action, string command)
{
	import cydo.protocol : CommandInput;

	string actionType;
	auto actionCommand = extractCommandActionsCommand(commandActions, actionType);
	if (command.length > 0)
	{
		if (actionType == "unknown" && actionCommand.length > 0)
			return toJson(CommandInput(actionCommand, ""));
		return toJson(CommandInput(command, ""));
	}

	if (actionCommand.length > 0)
		return toJson(CommandInput(actionCommand, ""));

	auto fromAction = extractCommandInput(action);
	if (fromAction.length > 0 && fromAction != `{}`)
		return fromAction;

	return `{}`;
}

/// Extract a fallback command from Codex commandActions when no executed command
/// field is available.
string extractCommandActionsInput(JSONFragment commandActions)
{
	auto command = extractCommandActionsCommand(commandActions);
	if (command.length == 0)
		return `{}`;

	import cydo.protocol : CommandInput;
	return toJson(CommandInput(command, ""));
}

/// Extract a single user-level command from Codex commandActions.
string extractCommandActionsCommand(JSONFragment commandActions)
{
	string actionType;
	return extractCommandActionsCommand(commandActions, actionType);
}

/// Extract a single user-level command and its action type from Codex commandActions.
string extractCommandActionsCommand(JSONFragment commandActions, out string actionType)
{
	if (commandActions.json is null || commandActions.json.length == 0)
		return "";

	@JSONPartial
	static struct CommandAction
	{
		@JSONOptional string type;
		@JSONOptional string command;
	}

	try
	{
		auto actions = jsonParse!(CommandAction[])(commandActions.json);
		if (actions.length != 1 || actions[0].command.length == 0)
			return "";
		actionType = actions[0].type;
		return actions[0].command;
	}
	catch (Exception e)
	{ tracef("extractCommandActionsInput: parse error: %s", e.msg); }
	return "";
}

unittest
{
	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct EmittedStartedEvent
	{
		string type;
		string name;
		@JSONOptional JSONFragment input;
	}

	@JSONPartial
	struct ParsedCommandInput
	{
		string command;
		string description;
	}

	enum userCommand =
		`/run/current-system/sw/bin/zsh -lc "python - <<'PY'\nprint(\"wrapped\")\nPY"`;
	enum wrappedCommand =
		`/nix/store/v8sa6r6q037ihghxfbwzjj4p59v2x0pv-bash-5.3p9/bin/bash -lc "/run/current-system/sw/bin/zsh -lc \"python - <<'PY'\nprint(\\\"wrapped\\\")\nPY\""`;
	auto startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-command","turnId":"turn-command","item":{"id":"call_command","type":"commandExecution","command":`
		~ toJson(wrappedCommand)
		~ `,"commandActions":[{"type":"unknown","command":`
		~ toJson(userCommand)
		~ `}]}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto startedEvent = jsonParse!EmittedStartedEvent(emitted[0]);
	assert(startedEvent.type == "item/started");
	assert(startedEvent.name == "commandExecution");
	assert(startedEvent.input.json !is null);

	auto input = jsonParse!ParsedCommandInput(startedEvent.input.json);
	assert(
		input.command == userCommand && input.description == "",
		"expected multiline commandAction to preserve semantic command; actual=" ~ input.command,
	);
}

unittest
{
	import ae.net.asockets : socketManager;
	import cydo.protocol : ItemStartedEvent;

	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	@JSONPartial struct StartedNotification { ItemStartedParams params; }
	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	TranslatedEvent[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev; }
	session.onOutput(&sink);
	auto bootstrapSubmission = new CodexSession.PendingMessage(
		[ContentBlock("text", "ignored")], "ignored", null, true);
	auto ordinarySubmission = new CodexSession.PendingMessage(
		[ContentBlock("text", "ordinary")], "ordinary", "ordinary-nonce", false);
	bootstrapSubmission.accepted = true;
	bootstrapSubmission.settled = true;
	ordinarySubmission.accepted = true;
	ordinarySubmission.settled = true;
	session.expectedEchoMessages_ ~= bootstrapSubmission;
	session.expectedEchoMessages_ ~= ordinarySubmission;
	auto bootstrap = jsonParse!StartedNotification(
		`{"params":{"item":{"id":"bootstrap","type":"userMessage","content":[{"type":"text","text":"ignored"}]}}}`);
	session.handleItemStarted(bootstrap.params, "bootstrap");
	drainPromiseNextTicks();
	assert(emitted.length == 1 && emitted[0].isContextBootstrap);
	auto ordinary = jsonParse!StartedNotification(
		`{"params":{"item":{"id":"ordinary","type":"userMessage","content":[{"type":"text","text":"ordinary"}]}}}`);
	session.handleItemStarted(ordinary.params, "ordinary");
	drainPromiseNextTicks();
	auto ordinaryEvent = jsonParse!ItemStartedEvent(emitted[1].translated);
	assert(emitted.length == 2 && !emitted[1].isContextBootstrap
		&& ordinaryEvent.correlation_id == "ordinary-nonce"
		&& session.expectedEchoMessages_.length == 0);
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	@JSONPartial struct StartedNotification { ItemStartedParams params; }

	void ignoreOutput(TranslatedEvent event) {}

	// Native echoes must match the expected submission FIFO. A second echo
	// arriving before the first is a text/order mismatch, not an event that can
	// be correlated to whichever matching submission happens to be queued.
	{
		auto session = new CodexSession(cast(AppServerProcess) null, 1,
			SessionConfig.init);
		session.onOutput(&ignoreOutput);
		auto first = new CodexSession.PendingMessage(
			[ContentBlock("text", "first")], "first", "first-nonce", false);
		auto second = new CodexSession.PendingMessage(
			[ContentBlock("text", "second")], "second", "second-nonce", false);
		first.accepted = true;
		second.accepted = true;
		session.expectedEchoMessages_ = [first, second];
		auto outOfOrder = jsonParse!StartedNotification(
			`{"params":{"item":{"id":"native-second","type":"userMessage","content":[{"type":"text","text":"second"}]}}}`);
		assertThrown!AssertError(session.handleItemStarted(outOfOrder.params,
			"out-of-order"));
		assert(session.expectedEchoMessages_ == [first, second]);
	}

	// A gated first echo remains attached to its submission until request
	// acceptance, so a second native echo for that submission is invalid.
	{
		auto session = new CodexSession(cast(AppServerProcess) null, 1,
			SessionConfig.init);
		session.onOutput(&ignoreOutput);
		auto submission = new CodexSession.PendingMessage(
			[ContentBlock("text", "once")], "once", "once-nonce", false);
		session.expectedEchoMessages_ = [submission];
		auto echo = jsonParse!StartedNotification(
			`{"params":{"item":{"id":"native-once","type":"userMessage","content":[{"type":"text","text":"once"}]}}}`);
		session.handleItemStarted(echo.params, "first-echo");
		assert(submission.hasGatedUserEcho);
		assertThrown!AssertError(session.handleItemStarted(echo.params,
			"duplicate-echo"));
	}

	// A native user echo without a live originating submission is an invariant
	// violation rather than an uncorrelated output event.
	{
		auto session = new CodexSession(cast(AppServerProcess) null, 1,
			SessionConfig.init);
		session.onOutput(&ignoreOutput);
		auto unexpected = jsonParse!StartedNotification(
			`{"params":{"item":{"id":"native-unexpected","type":"userMessage","content":[{"type":"text","text":"unexpected"}]}}}`);
		assertThrown!AssertError(session.handleItemStarted(unexpected.params,
			"no-expected-echo"));
	}
}

unittest
{
	import std.algorithm.searching : canFind;

	@JSONPartial struct StartedNotification { ItemStartedParams params; }
	@JSONPartial struct EmittedStartedEvent { JSONFragment input; }
	@JSONPartial struct ParsedCommandInput { string command; }

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"019f815e-a188-7ae1-8802-4bb069784c21","turnId":"019f8595-526f-7df3-9824-f7bda4b4c0f9","item":{"type":"commandExecution","id":"exec-24065314-fcdb-4934-8299-1cd7bd4095bc","command":"/run/current-system/sw/bin/zsh -lc \"wc -l /home/vladimir/work/cydo/.cydo/tasks/32026/output.md && sed -n '1,520p' /home/vladimir/work/cydo/.cydo/tasks/32026/output.md\"","cwd":"/home/vladimir/work/cydo/.cydo/tasks/31903/worktree","status":"inProgress","processId":"16474","commandActions":[{"type":"read","command":"sed -n '1,520p' /home/vladimir/work/cydo/.cydo/tasks/32026/output.md","name":"output.md","path":"/home/vladimir/work/cydo/.cydo/tasks/32026/output.md"}],"source":"unifiedExecStartup"}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);
	auto startedEvent = jsonParse!EmittedStartedEvent(emitted[0]);
	auto input = jsonParse!ParsedCommandInput(startedEvent.input.json);
	assert(
		input.command.canFind("wc -l") && input.command.canFind("sed -n"),
		"expected compound commandExecution input to preserve both wc and sed; actual="
			~ input.command,
	);
}

unittest
{
	@JSONPartial
	struct ParsedCommandInput
	{
		string command;
		string description;
	}

	enum multiActions =
		`[{"type":"read","command":"sed -n '1,1p' file"},{"type":"read","command":"sed -n '2,2p' file"}]`;
	enum wrappedCommand =
		`/nix/store/bash/bin/bash -lc "sed -n '1,1p' file\nprintf '\n--- section ---\n'\nsed -n '2,2p' file"`;

	auto input = jsonParse!ParsedCommandInput(
		extractCommandExecutionInput(JSONFragment(multiActions), JSONFragment.init, wrappedCommand));
	assert(
		input.command == wrappedCommand && input.description == "",
		"expected multi-action commandExecution input to preserve wrapper; actual=" ~ input.command,
	);
}

unittest
{
	ThreadForkParams tfp;
	tfp.threadId = "thread-parent";
	tfp.path = "/tmp/fork-source.jsonl";
	tfp.model = "gpt-5.3-codex";
	tfp.cwd = "/tmp/worktree";
	tfp.approvalPolicy = "never";
	tfp.sandbox = "danger-full-access";
	tfp.developerInstructions = "dev-instructions";
	tfp.config = JSONFragment(`{"mcp_servers.cydo":{"command":"cydo"}}`);
	auto forkJson = toJson(tfp);
	assert(
		forkJson == `{"threadId":"thread-parent","path":"/tmp/fork-source.jsonl","model":"gpt-5.3-codex","cwd":"/tmp/worktree","approvalPolicy":"never","sandbox":"danger-full-access","developerInstructions":"dev-instructions","config":{"mcp_servers.cydo":{"command":"cydo"}}}`,
		"thread/fork payload must preserve the source thread id/path; actual=" ~ forkJson,
	);

	auto steerJson = toJson(TurnSteerParams(
		"thread-steer",
		[TurnStartInput("text", "stage and nix flake check")],
		"turn-steer",
	));
	assert(
		steerJson == `{"threadId":"thread-steer","input":[{"type":"text","text":"stage and nix flake check"}],"expectedTurnId":"turn-steer"}`,
		"turn/steer payload must use input + expectedTurnId for Codex v2; actual=" ~ steerJson,
	);

	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct CompletedNotification
	{
		ItemCompletedParams params;
	}

	@JSONPartial
	struct EmittedStartedEvent
	{
		string type;
		@JSONOptional JSONFragment input;
	}

	@JSONPartial
	struct AskQuestionOption
	{
		string label;
		string description;
	}

	@JSONPartial
	struct AskQuestion
	{
		string header;
		string question;
		AskQuestionOption[] options;
		@JSONOptional bool multiSelect;
	}

	@JSONPartial
	struct AskUserQuestionInput
	{
		AskQuestion[] questions;
	}

	@JSONPartial
	struct EmittedResultEvent
	{
		string type;
		JSONFragment content;
	}

	@JSONPartial
	struct DeltaNotification
	{
		DeltaParams params;
	}

	@JSONPartial
	struct EmittedDeltaEvent
	{
		string type;
		string item_id;
		string delta_type;
		string content;
	}

	@JSONPartial
	struct TextContentBlock
	{
		string type;
		@JSONOptional string text;
	}

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-ask","turnId":"turn-ask","item":{"id":"mcp-call-ask","type":"mcpToolCall","server":"cydo","tool":"AskUserQuestion","arguments":{"questions":[{"header":"Test","question":"Do you agree?","options":[{"label":"Yes","description":"Confirm"},{"label":"No","description":"Deny"}],"multiSelect":false}]}}}}`;

	enum completedPayload =
		`{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-ask","item":{"id":"mcp-call-ask","result":{"content":[{"type":"text","text":"User has answered your questions: \"Do you agree?\"=\"Yes\"."}]}}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto completed = jsonParse!CompletedNotification(completedPayload);
	session.handleItemCompleted(completed.params, completedPayload);

	auto startedEvent = jsonParse!EmittedStartedEvent(emitted[0]);
	auto resultEvent = jsonParse!EmittedResultEvent(emitted[$ - 1]);

	bool inputOk = false;
	string actualInput = "<missing>";
	if (startedEvent.input.json !is null)
	{
		actualInput = startedEvent.input.json;
		const parsedInput = jsonParse!AskUserQuestionInput(startedEvent.input.json);
		inputOk =
			parsedInput.questions.length == 1
			&& parsedInput.questions[0].header == "Test"
			&& parsedInput.questions[0].question == "Do you agree?"
			&& parsedInput.questions[0].options.length == 2
			&& parsedInput.questions[0].options[0].label == "Yes";
	}

	auto blocks = jsonParse!(TextContentBlock[])(resultEvent.content.json);
	const actualResult =
		blocks.length > 0 && blocks[0].text.length > 0 ? blocks[0].text : "<empty>";
	const resultOk =
		blocks.length == 1
		&& blocks[0].type == "text"
		&& actualResult == `User has answered your questions: "Do you agree?"="Yes".`;

	assert(
		inputOk && resultOk,
		"expected Codex mcpToolCall AskUserQuestion payload to survive translation; "
			~ "actual input=" ~ actualInput ~ " actual result=" ~ actualResult,
	);

	enum lateDeltaPayload =
		`{"jsonrpc":"2.0","method":"item/commandExecution/outputDelta","params":{"threadId":"thread-ask","turnId":"turn-ask","itemId":"mcp-call-ask","delta":"late-output-marker\n"}}`;

	auto lateDelta = jsonParse!DeltaNotification(lateDeltaPayload);
	session.handleTurnCompleted(TurnCompletedParams("thread-ask"),
		`{"jsonrpc":"2.0","method":"turn/completed","params":{"threadId":"thread-ask"}}`);
	session.handleDelta(lateDelta.params, "output_delta", lateDeltaPayload);

	auto lateDeltaEvent = jsonParse!EmittedDeltaEvent(emitted[$ - 1]);
	assert(
		lateDeltaEvent.type == "item/delta"
			&& lateDeltaEvent.item_id == "mcp-call-ask"
			&& lateDeltaEvent.delta_type == "output_delta"
			&& lateDeltaEvent.content == "late-output-marker\n",
		"expected late Codex output_delta to keep its itemId after turn completion",
	);
}

unittest
{
	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct CompletedNotification
	{
		ItemCompletedParams params;
	}

	@JSONPartial
	struct EmittedResultEvent
	{
		string type;
		string item_id;
		@JSONOptional bool is_error;
		JSONFragment content;
	}

	@JSONPartial
	struct TextContentBlock
	{
		string type;
		@JSONOptional string text;
	}

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-task-failed","turnId":"turn-task-failed","item":{"id":"call_qQ5hScvoPoBX2kntB3IYtUM9","type":"mcpToolCall","server":"cydo","tool":"Task","arguments":{"tasks":[{"description":"demo","prompt":"demo","task_type":"review"}]}}}}`;

	enum completedPayload =
		`{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-task-failed","item":{"id":"call_qQ5hScvoPoBX2kntB3IYtUM9","status":"failed","type":"mcpToolCall","result":null,"server":"cydo","tool":"Task","error":{"message":"tool call error: tool call failed for cydo/Task\n\nCaused by:\n    Transport closed"}}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto completed = jsonParse!CompletedNotification(completedPayload);
	session.handleItemCompleted(completed.params, completedPayload);

	auto resultEvent = jsonParse!EmittedResultEvent(emitted[$ - 1]);
	auto blocks = jsonParse!(TextContentBlock[])(resultEvent.content.json);
	auto actualResult = blocks.length > 0 ? blocks[0].text : "<empty>";

	const marker = "Transport closed";
	const hasTransportClosed =
		actualResult.length >= marker.length
		&& actualResult[$ - marker.length .. $] == marker;

	assert(
		resultEvent.type == "item/result"
			&& resultEvent.item_id == "call_qQ5hScvoPoBX2kntB3IYtUM9"
			&& resultEvent.is_error
			&& blocks.length == 1
			&& blocks[0].type == "text"
			&& hasTransportClosed,
		"expected failed mcp tool result to surface error text; actual result=" ~ actualResult,
	);
}

unittest
{
	import ae.net.asockets : socketManager;
	import ae.utils.jsonrpc : JsonRpcError, JsonRpcErrorCode;
	import std.algorithm.searching : canFind;
	import cydo.agent.drivers.codex.process : makeTestAppServerProcess;
	import cydo.protocol : ItemStartedEvent;

	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	void drainPromiseNextTicks()
	{
		for (;;)
		{
			auto handlers = __traits(getMember, socketManager, "nextTickHandlers");
			if (handlers.length == 0)
				return;
			mixin(`__traits(getMember, socketManager, "nextTickHandlers") = null;`);
			foreach (handler; handlers)
				handler();
		}
	}

	JsonRpcResponse turnStartResponse(string turnId)
	{
		JsonRpcResponse response;
		response.result = SO.from(TurnStartResult(TurnRef(turnId)));
		return response;
	}

	JsonRpcResponse rejectedResponse(string message)
	{
		JsonRpcResponse response;
		response.error = JsonRpcError.fromCode(JsonRpcErrorCode.invalidRequest,
			message);
		return response;
	}

	JsonRpcResponse acceptedResponse()
	{
		JsonRpcResponse response;
		response.result = SO.from(true);
		return response;
	}

	void assertAcceptedOnce(TestSubmissionOutcome outcome)
	{
		assert(outcome.acceptedCount == 1 && outcome.rejectedCount == 0);
	}

	void assertRejectedOnce(TestSubmissionOutcome outcome)
	{
		assert(outcome.acceptedCount == 0 && outcome.rejectedCount == 1);
		assert(outcome.rejectionMessage.length > 0);
	}

	void exerciseThreadSetupFailure(string resumeSessionId,
		string expectedMethod)
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto agent = new CodexAgent;
		ProcessLaunch launch;
		launch.executablePath = "unused-test-codex";
		launch.workDir = "/test/workdir";
		SessionConfig config;
		config.workspace = expectedMethod;
		config.model = "test-model";
		agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;

		auto session = cast(CodexSession) agent.createSession(
			31, resumeSessionId, launch, config);
		assert(session !is null);
		auto setupRequest = connection.takeRequest(expectedMethod);
		if (resumeSessionId.length > 0)
		{
			auto params = jsonParse!ThreadResumeParams(toJson(setupRequest.params));
			assert(params.threadId == resumeSessionId
				&& params.model == "test-model"
				&& params.cwd == "/test/workdir");
		}
		else
		{
			auto params = jsonParse!ThreadStartParams(toJson(setupRequest.params));
			assert(params.model == "test-model"
				&& params.cwd == "/test/workdir");
		}

		auto first = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "queued setup first")], "setup-first"));
		auto second = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "queued setup second")], "setup-second"));
		assert(connection.sentMessages.length == 0);
		assert(session.pendingMessages_.length == 2
			&& session.inFlightMessages_.length == 0);

		connection.respond(setupRequest,
			rejectedResponse(expectedMethod ~ " failed"));
		drainPromiseNextTicks();
		assertRejectedOnce(first);
		assertRejectedOnce(second);
		assert(first.rejectionMessage == expectedMethod ~ " failed"
			&& second.rejectionMessage == expectedMethod ~ " failed");
		assert(!session.alive_);
		assert(session.pendingMessages_.length == 0
			&& session.inFlightMessages_.length == 0);

		session.onThreadStartFailed(new Exception("duplicate setup failure"));
		drainPromiseNextTicks();
		assertRejectedOnce(first);
		assertRejectedOnce(second);
		assert(connection.sentMessages.length == 0);
	}

	exerciseThreadSetupFailure(null, "thread/start");
	exerciseThreadSetupFailure("resume-thread", "thread/resume");

	// 23. SessionConfig.effort flows into the thread/start config override.
	{
		import std.algorithm : canFind;

		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto agent = new CodexAgent;
		ProcessLaunch launch;
		launch.executablePath = "unused-test-codex";
		launch.workDir = "/test/workdir";
		SessionConfig config;
		config.workspace = "effort-test";
		config.model = "test-model";
		config.effort = "high";
		agent.serverPool[agent.serverPoolKey(config.workspace, launch)] = server;

		auto session = cast(CodexSession) agent.createSession(32, null, launch, config);
		assert(session !is null);
		auto setupRequest = connection.takeRequest("thread/start");
		auto params = jsonParse!ThreadStartParams(toJson(setupRequest.params));
		assert(params.model == "test-model");
		assert(params.config.json.canFind(`"model_reasoning_effort":"high"`));
	}

	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init);
		auto first = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "first")], "first-nonce", true));
		assert(session.pendingMessages_.length == 1);
		assert(connection.sentMessages.length == 0);

		ThreadStartResult ready;
		ready.thread.id = "thread";
		session.onThreadStarted(ready, null, "test-model", "/test/workdir",
			`{"thread":{"id":"thread"}}`);
		auto firstRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "first");
		auto firstParams = jsonParse!TurnStartParams(toJson(firstRequest.params));
		assert(firstParams.threadId == "thread");
		connection.respond(firstRequest, turnStartResponse("turn-first"));
		drainPromiseNextTicks();
		assertAcceptedOnce(first);
		assert(session.turnInProgress && !session.startInFlight_
			&& session.activeTurnId_ == "turn-first");

		auto steerAccepted = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "accepted steer")], "steer-nonce"));
		auto steerRejected = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "stale steer")], "stale-nonce"));
		auto acceptedSteerRequest = connection.takeRequest!TurnSteerParams(
			"turn/steer", "accepted steer");
		auto rejectedSteerRequest = connection.takeRequest!TurnSteerParams(
			"turn/steer", "stale steer");
		auto acceptedSteerParams = jsonParse!TurnSteerParams(
			toJson(acceptedSteerRequest.params));
		auto rejectedSteerParams = jsonParse!TurnSteerParams(
			toJson(rejectedSteerRequest.params));
		assert(acceptedSteerParams.threadId == "thread"
			&& acceptedSteerParams.expectedTurnId == "turn-first");
		assert(rejectedSteerParams.threadId == "thread"
			&& rejectedSteerParams.expectedTurnId == "turn-first");
		assert(acceptedSteerRequest.id.toJson()
			!= rejectedSteerRequest.id.toJson());

		connection.respond(rejectedSteerRequest,
			rejectedResponse("stale expected turn"));
		drainPromiseNextTicks();
		assertRejectedOnce(steerRejected);
		assert(steerRejected.rejectionMessage == "stale expected turn");
		assert(steerAccepted.acceptedCount == 0
			&& steerAccepted.rejectedCount == 0);
		assert(session.turnInProgress
			&& session.activeTurnId_ == "turn-first");
		assert(session.expectedEchoMessages_.length == 2);

		connection.respond(acceptedSteerRequest, acceptedResponse());
		drainPromiseNextTicks();
		assertAcceptedOnce(steerAccepted);
		assert(session.turnInProgress
			&& session.activeTurnId_ == "turn-first");
		assert(session.expectedEchoMessages_.length == 2);

		TranslatedEvent[] emitted;
		session.onOutput = (TranslatedEvent event) { emitted ~= event; };
		enum firstEcho = `{"params":{"threadId":"thread","turnId":"turn-first","item":{"id":"user-first","type":"userMessage","content":[{"type":"text","text":"first"}]}}}`;
		auto notification = jsonParse!StartedNotification(firstEcho);
		session.handleItemStarted(notification.params, firstEcho);
		drainPromiseNextTicks();
		auto emittedUser = jsonParse!ItemStartedEvent(emitted[0].translated);
		assert(emittedUser.correlation_id == "first-nonce"
			&& emitted[0].isContextBootstrap);

		enum steerEcho = `{"params":{"threadId":"thread","turnId":"turn-first","item":{"id":"user-steer","type":"userMessage","content":[{"type":"text","text":"accepted steer"}]}}}`;
		notification = jsonParse!StartedNotification(steerEcho);
		session.handleItemStarted(notification.params, steerEcho);
		drainPromiseNextTicks();
		emittedUser = jsonParse!ItemStartedEvent(emitted[1].translated);
		assert(emittedUser.correlation_id == "steer-nonce"
			&& !emitted[1].isContextBootstrap);
		assert(session.expectedEchoMessages_.length == 0);
	}

	// A successful request response and item/started notification can arrive
	// back-to-back. The App acceptance continuation must run before either echo.
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init);
		session.threadId = "echo-order";

		bool firstAccepted;
		bool secondAccepted;
		string[] correlations;
		session.onOutput = (TranslatedEvent event) {
			if (!event.translated.canFind(`"item_type":"user_message"`))
				return;
			auto user = jsonParse!ItemStartedEvent(event.translated);
			if (user.correlation_id == "first-nonce")
				assert(firstAccepted);
			else
			{
				assert(user.correlation_id == "second-nonce");
				assert(secondAccepted);
			}
			correlations ~= user.correlation_id;
		};

		session.sendMessage([ContentBlock("text", "first prompt")],
			"first-nonce").then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			firstAccepted = true;
		}).ignoreResult();
		auto firstRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "first prompt");
		connection.respond(firstRequest, turnStartResponse("first-turn"));
		enum firstEcho = `{"params":{"threadId":"echo-order","turnId":"first-turn","item":{"id":"first-native","type":"userMessage","content":[{"type":"text","text":"first prompt"}]}}}`;
		auto notification = jsonParse!StartedNotification(firstEcho);
		session.handleItemStarted(notification.params, firstEcho);
		assert(!firstAccepted && correlations.length == 0);
		drainPromiseNextTicks();
		assert(firstAccepted && correlations == ["first-nonce"]);

		session.handleTurnCompleted(TurnCompletedParams("echo-order"),
			`{"method":"turn/completed"}`);
		session.sendMessage([ContentBlock("text", "second prompt")],
			"second-nonce").then((AgentSubmissionReceipt receipt) {
			assert(receipt == AgentSubmissionReceipt.appServerAccepted);
			secondAccepted = true;
		}).ignoreResult();
		auto secondRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "second prompt");
		connection.respond(secondRequest, turnStartResponse("second-turn"));
		enum secondEcho = `{"params":{"threadId":"echo-order","turnId":"second-turn","item":{"id":"second-native","type":"userMessage","content":[{"type":"text","text":"second prompt"}]}}}`;
		notification = jsonParse!StartedNotification(secondEcho);
		session.handleItemStarted(notification.params, secondEcho);
		assert(!secondAccepted && correlations == ["first-nonce"]);
		drainPromiseNextTicks();
		assert(secondAccepted && correlations == ["first-nonce", "second-nonce"]);
	}

	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init);
		session.threadId = "thread";

		auto rejected = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "rejected start")], "rejected"));
		auto rejectedRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "rejected start");
		connection.respond(rejectedRequest,
			rejectedResponse("no successor failure"));
		drainPromiseNextTicks();
		assertRejectedOnce(rejected);
		assert(rejected.rejectionMessage == "no successor failure");
		assert(!session.turnInProgress && !session.startInFlight_
			&& session.activeTurnId_.length == 0
			&& session.pendingMessages_.length == 0
			&& session.inFlightMessages_.length == 0);

		auto later = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "later valid start")], "later"));
		auto laterRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "later valid start");
		assert(rejectedRequest.id.toJson() != laterRequest.id.toJson());
		connection.respond(laterRequest, turnStartResponse("turn-later"));
		drainPromiseNextTicks();
		assertAcceptedOnce(later);
		assert(session.turnInProgress && !session.startInFlight_
			&& session.activeTurnId_ == "turn-later");
	}

	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init);
		session.threadId = "thread";

		auto first = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "rejected start")], "first"));
		auto firstRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "rejected start");
		auto second = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", "accepted successor")], "second"));
		assert(connection.sentMessages.length == 0);
		assert(session.pendingMessages_.length == 1);

		connection.respond(firstRequest,
			rejectedResponse("queued successor failure"));
		drainPromiseNextTicks();
		assertRejectedOnce(first);
		assert(first.rejectionMessage == "queued successor failure");
		assert(second.acceptedCount == 0 && second.rejectedCount == 0);
		assert(session.turnInProgress && session.startInFlight_
			&& session.activeTurnId_.length == 0);
		auto secondRequest = connection.takeRequest!TurnStartParams(
			"turn/start", "accepted successor");
		assert(firstRequest.id.toJson() != secondRequest.id.toJson());

		connection.respond(secondRequest, turnStartResponse("turn-successor"));
		drainPromiseNextTicks();
		assertAcceptedOnce(second);
		assert(session.turnInProgress && !session.startInFlight_
			&& session.activeTurnId_ == "turn-successor"
			&& session.pendingMessages_.length == 0
			&& session.inFlightMessages_.length == 0);
	}

	void exerciseLifecycleLoss(string label,
		void delegate(CodexSession) loseLifecycle, bool remainsAlive)
	{
		auto connection = new TestCodexConnection;
		auto server = makeTestAppServerProcess(connection);
		auto session = new CodexSession(server, 1, SessionConfig.init);
		session.threadId = "thread-" ~ label;

		auto inFlight = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", label ~ " in flight")], label ~ "-flight"));
		auto captured = connection.takeRequest!TurnStartParams(
			"turn/start", label ~ " in flight");
		auto queued = new TestSubmissionOutcome(session.sendMessage(
			[ContentBlock("text", label ~ " queued")], label ~ "-queued"));
		assert(connection.sentMessages.length == 0);
		assert(session.inFlightMessages_.length == 1
			&& session.pendingMessages_.length == 1);

		loseLifecycle(session);
		loseLifecycle(session);
		drainPromiseNextTicks();
		assertRejectedOnce(inFlight);
		assertRejectedOnce(queued);
		assert(session.alive_ == remainsAlive);
		assert(!session.startInFlight_
			&& session.inFlightMessages_.length == 0
			&& session.pendingMessages_.length == 0);

		connection.respond(captured, turnStartResponse("late-" ~ label));
		drainPromiseNextTicks();
		assertRejectedOnce(inFlight);
		assertRejectedOnce(queued);
		assert(session.activeTurnId_.length == 0);
		assert(session.expectedEchoMessages_.length == 0);
		assert(connection.sentMessages.length == 0);
	}

	exerciseLifecycleLoss("thread-setup-owner",
		(CodexSession session) {
			session.onThreadStartFailed(new Exception("thread setup failed"));
		}, false);
	exerciseLifecycleLoss("invalidation",
		(CodexSession session) {
			session.invalidatePendingSubmittedMessages();
		}, true);
	exerciseLifecycleLoss("close-stdin",
		(CodexSession session) {
			session.closeStdin();
		}, false);
	exerciseLifecycleLoss("server-exit",
		(CodexSession session) {
			session.onServerExit(17);
		}, false);
}

unittest
{
	@JSONPartial
	struct StartedNotification
	{
		ItemStartedParams params;
	}

	@JSONPartial
	struct CompletedNotification
	{
		ItemCompletedParams params;
	}

	@JSONPartial
	struct EmittedResultEvent
	{
		string type;
		string item_id;
		@JSONOptional JSONFragment tool_result;
		JSONFragment content;
	}

	@JSONPartial
	struct TextContentBlock
	{
		string type;
		@JSONOptional string text;
	}

	@JSONPartial
	struct StructuredTaskResult
	{
		string status;
		int tid;
		string summary;
	}

	enum startedPayload =
		`{"jsonrpc":"2.0","method":"item/started","params":{"threadId":"thread-task-structured","turnId":"turn-task-structured","item":{"id":"call_structuredTask","type":"mcpToolCall","server":"cydo","tool":"Task","arguments":{"tasks":[{"description":"demo","prompt":"demo","task_type":"review"}]}}}}`;

	enum completedPayload =
		`{"jsonrpc":"2.0","method":"item/completed","params":{"threadId":"thread-task-structured","item":{"id":"call_structuredTask","status":"completed","type":"mcpToolCall","server":"cydo","tool":"Task","result":{"content":[{"type":"text","text":"{\"status\":\"success\",\"tid\":2,\"summary\":\"structured-success\"}"}],"structuredContent":{"status":"success","tid":2,"summary":"structured-success"}}}}}`;

	auto session = new CodexSession(cast(AppServerProcess) null, 1, SessionConfig.init);
	string[] emitted;
	void sink(TranslatedEvent ev) { emitted ~= ev.translated; }
	session.onOutput(&sink);

	auto started = jsonParse!StartedNotification(startedPayload);
	session.handleItemStarted(started.params, startedPayload);

	auto completed = jsonParse!CompletedNotification(completedPayload);
	session.handleItemCompleted(completed.params, completedPayload);

	auto resultEvent = jsonParse!EmittedResultEvent(emitted[$ - 1]);
	auto blocks = jsonParse!(TextContentBlock[])(resultEvent.content.json);
	auto structured = jsonParse!StructuredTaskResult(resultEvent.tool_result.json);

	assert(
		resultEvent.type == "item/result"
			&& resultEvent.item_id == "call_structuredTask"
			&& blocks.length == 1
			&& blocks[0].type == "text"
			&& blocks[0].text == `{"status":"success","tid":2,"summary":"structured-success"}`
			&& structured.status == "success"
			&& structured.tid == 2
			&& structured.summary == "structured-success",
		"expected structuredContent to populate tool_result while preserving text content",
	);
}
