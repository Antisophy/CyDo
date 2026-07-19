module cydo.workflow.tasks.mutations;

import core.lifetime : move;

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
import cydo.workflow.history.operations : HistoryOperation, HistoryOperationMechanism,
	allowsFileRevert, allowsOperation, selectHistoryOperations;
import cydo.workflow.history.jsonl_store : countLinesAfterForkId,
	editJsonlMessage, forkTask, spliceJsonlByLine,
	truncateJsonl, writeJsonlPrefix;
import cydo.workflow.sessions.task_runner : TaskSessionLaunch;

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

	string delegate(const TaskData* td) effectiveCwd;
	TaskSessionLaunch delegate(int tid, Agent taskAgent,
		TaskTypeDef* typeDef) prepareTaskSessionLaunch;
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
	bool delegate(int tid, string requestedAnchor, out HistoryBoundary boundary)
		resolveFreshPersistedBoundary;
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

		auto ta = host_.agentForTask(tid);
		HistoryBoundary boundary;
		if (!host_.resolveFreshPersistedBoundary(tid, json.after_uuid, boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}
		auto codexSession = cast(CodexSession) host_.sessionForTask(tid);
		auto operations = selectHistoryOperations(ta.driver, host_.taskAlive(tid),
			codexSession !is null && codexSession.canRollbackThread);
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
			import std.datetime : Clock;
			import std.file : exists, remove;
			import std.path : baseName, buildPath, dirName;
			import std.uuid : randomUUID;

			auto sourcePath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
			if (sourcePath.length == 0)
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: task history file not found", tid)).representation));
				return;
			}

			auto forkSourcePath = buildPath(dirName(sourcePath),
				"fork-source-" ~ randomUUID().toString() ~ "-" ~ baseName(sourcePath));
			if (!writeJsonlPrefix(sourcePath, forkSourcePath, boundary.anchor,
				&ta.forkIdMatchesLine))
			{
				ws.send(Data(toJson(ErrorMessage("error",
					"Fork failed: message UUID not found in task history", tid)).representation));
				return;
			}

			auto childTid = createForkTask(*host_.persistence(), tid, "", td.projectPath,
				td.workspace, td.title, td.description, td.taskType, td.agentType);
			auto newTd = TaskData(childTid, td.workspace, td.projectPath);
			newTd.title = td.title.length > 0 ? td.title ~ " (fork)" : "(fork)";
			newTd.parentTid = tid;
			newTd.relationType = "fork";
			newTd.status = TaskStatus.completed;
			newTd.agentType = td.agentType;
			newTd.description = td.description;
			newTd.taskType = td.taskType;
			newTd.createdAt = Clock.currStdTime;
			newTd.lastActive = newTd.createdAt;
			host_.putTask(childTid, move(newTd));
			auto child = host_.getTask(childTid);
			assert(child !is null, "Fork child task must exist after insertion");
			child.history.reset(Watermark.none());

			auto childAgent = host_.agentForTask(childTid);
			auto childTypeDef = host_.taskTypeForProject(child.projectPath, child.taskType);
			auto launch = host_.prepareTaskSessionLaunch(childTid, childAgent, childTypeDef);

			ca.forkSession(childTid, td.agentSessionId, launch.processLaunch,
				launch.sessionConfig, forkSourcePath)
				.then((ThreadForkOutcome outcome) {
					try
					{
						if (exists(forkSourcePath))
							remove(forkSourcePath);
					}
					catch (Exception)
					{
					}
					if (!outcome.ok)
					{
						host_.removeTask(childTid);
						host_.deleteTask(childTid);
						ws.send(Data(toJson(ErrorMessage("error",
							"Fork failed: " ~ outcome.error, tid)).representation));
						return;
					}

					auto currentChild = host_.getTask(childTid);
					assert(currentChild !is null,
						"Fork child task must exist until fork completion");
					currentChild.agentSessionId = outcome.threadId;
					host_.setAgentSessionId(childTid, outcome.threadId);
					currentChild.processQueue = new StateQueue!ProcessState(
						host_.makeProcessQueueSF(childTid),
						ProcessState.Dead,
					);
					currentChild.archiveQueue = new StateQueue!ArchiveState(
						host_.makeArchiveQueueSF(childTid),
						ArchiveState.Unarchived,
					);
					auto jp = childAgent.historyPath(outcome.threadId,
						host_.effectiveCwd(currentChild));
					currentChild.history.reset(watermarkFromPath(jp));

					host_.broadcastTaskCreated(TaskCreatedMessage("task_created", childTid,
						td.workspace, td.projectPath, tid, "fork"));
					host_.broadcastTaskUpdate(childTid);
					host_.broadcastFocusHint(tid, childTid);
				});
			return;
		}

		auto result = forkTask(*host_.persistence(), tid, td.agentSessionId, boundary.anchor,
			td.projectPath, td.workspace, td.title,
			(string sid) => ta.historyPath(sid,
				sid == td.agentSessionId ? host_.effectiveCwd(td) : td.projectPath),
			&ta.rewriteSessionId, &ta.forkIdMatchesLine, td.description, td.taskType,
			td.agentType);
		if (result.tid < 0)
		{
			ws.send(Data(toJson(ErrorMessage("error",
				"Fork failed: message UUID not found in task history", tid)).representation));
			return;
		}

		import std.datetime : Clock;

		auto newTd = TaskData(result.tid, td.workspace, td.projectPath);
		newTd.title = td.title.length > 0 ? td.title ~ " (fork)" : "(fork)";
		newTd.agentSessionId = result.agentSessionId;
		newTd.parentTid = tid;
		newTd.relationType = "fork";
		newTd.status = TaskStatus.completed;
		newTd.agentType = td.agentType;
		newTd.description = td.description;
		newTd.taskType = td.taskType;
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
		auto jp = ta.historyPath(result.agentSessionId, host_.effectiveCwd(child));
		child.history.reset(watermarkFromPath(jp));

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

		auto ta = host_.agentForTask(tid);
		HistoryBoundary boundary;
		if (!host_.resolveFreshPersistedBoundary(tid, json.after_uuid, boundary))
		{
			ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
			return;
		}
		auto codexSession = cast(CodexSession) host_.sessionForTask(tid);
		auto operations = selectHistoryOperations(ta.driver, host_.taskAlive(tid),
			codexSession !is null && codexSession.canRollbackThread);
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

				auto jsonlPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
				if (jsonlPath.length == 0 || !exists(jsonlPath))
				{
					ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
					return;
				}

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

				auto jsonlPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
				if (jsonlPath.length == 0 || !exists(jsonlPath))
				{
					ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
					return;
				}
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
				ta.historyPath(td.agentSessionId, host_.effectiveCwd(td)),
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

				auto jsonlPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
				if (jsonlPath.length == 0 || !exists(jsonlPath))
				{
					ws.send(Data(toJson(ErrorMessage("error", "UUID not found in task history", tid)).representation));
					return;
				}

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

				ca.rollbackThread(td.agentSessionId, numTurns, td.launch, td.workspace)
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
						auto jp = ta.historyPath(td2.agentSessionId,
							host_.effectiveCwd(td2));
						td2.history.reset(watermarkFromPath(jp));
						host_.unsubscribeTaskHistorySubscribers(tid);

						if (td2.pendingSteeringTexts.length > 0)
						{
							import std.file : exists, readText;

							auto histPath = ta.historyPath(td2.agentSessionId,
								host_.effectiveCwd(td2));
							if (histPath.length > 0 && histPath.exists)
							{
							auto boundaries = ta.extractPersistedHistoryBoundaries(readText(histPath));
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
			fallbackUndoKillAndTruncate(ws, tid, json, boundary, mechanism);
			return;
		}

		if (auto session = host_.sessionForTask(tid))
			session.invalidatePendingSubmittedMessages();
		performUndoExecution(ws, tid, json, boundary, mechanism);
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

		auto ta = host_.agentForTask(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
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
		auto ta = host_.agentForTask(tid);
		auto jsonlPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
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
		HistoryBoundary boundary, HistoryOperationMechanism mechanism)
	{
		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;
		auto ta = host_.agentForTask(tid);

		auto jsonlPathSnap = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
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
			performUndoExecution(ws, tid, json, boundary, mechanism);
		}).ignoreResult();
		host_.stopTask(tid);
	}

	void performUndoExecution(MutationReplySocket ws, int tid, WsMessage json,
		HistoryBoundary boundary, HistoryOperationMechanism mechanism)
	{
		import std.algorithm : canFind, startsWith;

		auto td = host_.getTask(tid);
		if (tid < 0 || td is null)
			return;

		auto ta = host_.agentForTask(tid);
		assert(mechanism == HistoryOperationMechanism.jsonl,
			"JSONL undo execution requires the JSONL mechanism");

		string rewindOutput;
		if (json.revert_files)
		{
			auto rewindResult = ta.rewindFiles(td.agentSessionId, boundary.checkpoint_uuid,
				host_.effectiveCwd(td), td.launch);
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

			auto historyPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
			auto boundaries = historyPath.length > 0 && exists(historyPath)
				? ta.extractPersistedHistoryBoundaries(readText(historyPath)) : null;
			auto lastForkId = boundaries.length > 0 ? boundaries[$ - 1].anchor : null;
			if (lastForkId.length > 0)
			{
				auto backup = forkTask(*host_.persistence(), tid, td.agentSessionId,
					lastForkId, td.projectPath, td.workspace, td.title,
					(string sid) => ta.historyPath(sid,
						sid == td.agentSessionId ? host_.effectiveCwd(td) : td.projectPath),
					&ta.rewriteSessionId, &ta.forkIdMatchesLine,
					td.description, td.taskType, td.agentType);
				if (backup.tid >= 0)
				{
					auto bTd = TaskData(backup.tid, td.workspace, td.projectPath);
					bTd.title = td.title.length > 0 ? td.title ~ " (pre-undo)" : "(pre-undo)";
					bTd.agentSessionId = backup.agentSessionId;
					bTd.parentTid = tid;
					bTd.relationType = "undo-backup";
					bTd.status = TaskStatus.completed;
					bTd.agentType = td.agentType;
					bTd.description = td.description;
					bTd.taskType = td.taskType;
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
					auto jp = ta.historyPath(backup.agentSessionId,
						host_.effectiveCwd(backupTd));
					backupTd.history.reset(watermarkFromPath(jp));
					host_.broadcastTaskCreated(TaskCreatedMessage("task_created",
						backup.tid, td.workspace, td.projectPath, tid, "undo-backup"));
					host_.broadcastTaskUpdate(backup.tid);
				}
			}
		}

		if (json.revert_conversation)
		{
			auto histJsonlPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
			auto removed = truncateJsonl(histJsonlPath, boundary.anchor,
				&ta.forkIdMatchesLine, true);
			if (removed < 0)
			{
				ws.send(Data(toJson(ErrorMessage("error", "UUID not found for truncation", tid)).representation));
				return;
			}
			host_.invalidateJsonlLineage(tid);
			td.history.reset(watermarkFromPath(histJsonlPath));
			host_.unsubscribeTaskHistorySubscribers(tid);

			if (td.pendingSteeringTexts.length > 0)
			{
				import std.file : exists, readText;
				import std.string : splitLines;

				auto histPath = ta.historyPath(td.agentSessionId, host_.effectiveCwd(td));
				if (histPath.length > 0 && histPath.exists)
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

	enum tid = 71;
	auto task = TaskData(tid, "local", "/tmp");
	task.agentType = "claude";
	task.agentSessionId = "session";
	Agent agent = new ClaudeCodeAgent();
	int replies;
	int sideEffects;
	enum Resolution { forged, stale, noCheckpoint }
	Resolution resolution;

	TaskMutationServiceHost host;
	host.getTask = (int value) => value == tid ? &task : null;
	host.agentForTask = (int) => agent;
	host.sessionForTask = (int) => null;
	host.taskAlive = (int) => false;
	host.stopTask = (int) { sideEffects++; assert(false); };
	host.effectiveCwd = (const TaskData*) => "/tmp";
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
	host.resolveFreshPersistedBoundary = (int, string, out HistoryBoundary boundary) {
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
