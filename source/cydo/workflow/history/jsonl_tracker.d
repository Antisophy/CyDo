module cydo.workflow.history.jsonl_tracker;

import std.stdio : File;
import std.string : representation;

import ae.net.http.websocket : WebSocketAdapter;
import ae.sys.data : Data;
import ae.sys.inotify : INotify;
import ae.sys.timing : setTimeout, TimerTask;

import cydo.agent.contract : Agent, PersistedHistoryBoundary, PersistedHistoryBoundaryKind;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
import cydo.runtime.config : AgentDriver;
import cydo.foundation.platform.inotify : RefCountedINotify;
import cydo.domain.tasks.model : TaskData, Watermark,
	extractEventFromEnvelope;

struct JsonlTracker
{
	private static bool boundaryHasCheckpoint(AgentDriver driver,
		PersistedHistoryBoundaryKind kind)
	{
		return driver == AgentDriver.claude && kind == PersistedHistoryBoundaryKind.user;
	}
	struct LiveBoundaryCandidate { size_t seq; PersistedHistoryBoundaryKind kind; string identity; ulong generation; }
	struct PersistedBoundaryCandidate { PersistedHistoryBoundary boundary; size_t sourceLine; bool requiresIdentity; ulong generation; }
	struct BoundaryReconcileState {
		size_t readPos;
		size_t lineCount;
		LiveBoundaryCandidate[][PersistedHistoryBoundaryKind] liveByKind;
		PersistedBoundaryCandidate[][PersistedHistoryBoundaryKind] persistedByKind;
		ubyte[] partialLine;
	}
	Agent delegate(int tid) getAgent;
	TaskData* delegate(int tid) getTask;
	ulong delegate(int tid) historyGeneration;
	string delegate(int tid) getEffectiveCwd;
	void delegate(int tid, string msg) sendToSubscribed;
	void delegate(int tid, size_t seq, HistoryBoundary boundary, bool publish, ulong generation) onBoundaryResolved;
	void delegate(int tid) onLineageInvalidated;

	private RefCountedINotify rcINotify;
	private RefCountedINotify.Handle[int] jsonlWatches;
	private size_t[int] jsonlReadPos;
	private string[int] jsonlPaths;
	private int[int] jsonlLineCount;
	private BoundaryReconcileState[int] boundaryState;
	private ulong[int] lineageGeneration;
	private TimerTask[int] jsonlRetryTimers;
	// Snapshot of JSONL content taken just before broadcast, used for undo
	// when the agent compacts the file (e.g. Codex auto-compaction).
	private string[int] undoJsonl;

	void noteLiveBoundaryCandidate(int tid, size_t seq, string event,
		string raw = null, int sourceLine = 0, bool isContextBootstrap = false)
	{
		import ae.utils.json : JSONOptional, JSONPartial, jsonParse;
		@JSONPartial static struct Probe { string type; @JSONOptional string item_type;
			@JSONOptional string uuid; @JSONOptional string item_id;
			@JSONOptional bool is_meta; @JSONOptional bool is_synthetic; @JSONOptional bool pending; @JSONOptional bool is_sidechain;
			@JSONOptional string parent_tool_use_id; }
		auto p = jsonParse!Probe(event);
		PersistedHistoryBoundaryKind kind;
		if (p.type == "item/started" && p.item_type == "user_message"
			&& !p.is_synthetic && !p.pending && !p.is_sidechain
			&& p.parent_tool_use_id.length == 0)
			kind = PersistedHistoryBoundaryKind.user;
		else if (p.type == "turn/stop" && !p.is_sidechain && p.parent_tool_use_id.length == 0)
			kind = PersistedHistoryBoundaryKind.agent_turn;
		else return;
		if (tid !in boundaryState)
			boundaryState[tid] = BoundaryReconcileState.init;
		if (getAgent(tid).driver == AgentDriver.codex && isContextBootstrap
			&& kind == PersistedHistoryBoundaryKind.user)
			return;
		auto identity = p.uuid.length > 0 ? p.uuid : p.item_id;
		boundaryState[tid].liveByKind[kind] ~= LiveBoundaryCandidate(seq, kind,
			identity, historyGeneration(tid));
		drainLiveBoundaries(tid, kind);
	}

	private void drainLiveBoundaries(int tid, PersistedHistoryBoundaryKind kind)
	{
		import std.algorithm : startsWith;
		while (true)
		{
			auto state = tid in boundaryState;
			if (state is null) return;
			auto lives = kind in (*state).liveByKind;
			auto persistedCandidates = kind in (*state).persistedByKind;
			if (lives is null || persistedCandidates is null || lives.length == 0
				|| persistedCandidates.length == 0) return;
			auto liveCandidates = (*lives).dup;
			auto candidates = (*persistedCandidates).dup;
			auto current = historyGeneration(tid);
			foreach (live; liveCandidates)
				assert(live.generation <= current,
					"history boundary candidate belongs to a future generation");
			ptrdiff_t liveIndex = -1;
			ptrdiff_t persistedIndex = -1;
			foreach (i, persisted; candidates)
			{
				assert(persisted.generation <= current,
					"history boundary candidate belongs to a future generation");
				if (persisted.generation < current)
					continue;
				foreach (j, live; liveCandidates)
					if (live.generation == current && live.identity.length > 0
						&& persisted.boundary.anchor == live.identity)
					{
						liveIndex = cast(ptrdiff_t) j;
						persistedIndex = cast(ptrdiff_t) i;
						break;
					}
				if (persistedIndex >= 0)
					break;
			}
			if (persistedIndex < 0)
			{
				auto live = liveCandidates[0];
				if (live.generation < current)
				{
					(*state).liveByKind[kind] = liveCandidates[1 .. $];
					continue;
				}
				foreach (i, persisted; candidates)
				{
					if (persisted.generation < current)
						continue;
					auto nativeRecord = !persisted.boundary.anchor.startsWith("enqueue-");
					if ((nativeRecord && persisted.boundary.anchor.startsWith("line:"))
						|| (nativeRecord && getAgent(tid).driver == AgentDriver.claude
							&& kind == PersistedHistoryBoundaryKind.user)
						|| (kind == PersistedHistoryBoundaryKind.agent_turn
							&& live.identity.length == 0))
					{
						liveIndex = 0;
						persistedIndex = cast(ptrdiff_t) i;
						break;
					}
				}
			}
			if (persistedIndex < 0) return;
			auto live = liveCandidates[cast(size_t) liveIndex];
			auto persisted = (*persistedCandidates)[cast(size_t) persistedIndex];
			LiveBoundaryCandidate[] remainingLives;
			foreach (i, candidate; liveCandidates)
				if (i != liveIndex)
					remainingLives ~= candidate;
			(*state).liveByKind[kind] = remainingLives;
			PersistedBoundaryCandidate[] remaining;
			foreach (i, candidate; candidates)
				if (i != persistedIndex)
					remaining ~= candidate;
			(*state).persistedByKind[kind] = remaining;
			resolveBoundary(tid, live.seq, persisted.boundary, true, live.generation);
		}
	}

	private static size_t completeJsonlByteCount(string content)
	{
		import std.string : lastIndexOf;
		auto lastNewline = content.lastIndexOf('\n');
		return lastNewline < 0 ? 0 : lastNewline + 1;
	}

	void invalidateLineage(int tid)
	{
		lineageGeneration[tid]++;
		stopJsonlWatch(tid);
	}

	void finalReconcileJsonlIfPresent(int tid)
	{
		auto td = getTask(tid);
		assert(td !is null && td.history.isLoaded,
			"final JSONL reconciliation requires a loaded current task history");
		auto path = tid in jsonlPaths;
		if (path is null)
		{
			if (td.agentSessionId.length == 0) return;
			auto resolved = getAgent(tid).historyPath(td.agentSessionId, getEffectiveCwd(tid));
			import std.file : exists;
			if (resolved.length == 0 || !exists(resolved)) return;
			attachAndCatchUp(tid, resolved, false);
			return;
		}
		attachAndCatchUp(tid, *path, false);
	}

	/// Start watching the JSONL file (or directory if file doesn't exist yet).
	void startJsonlWatch(int tid)
	{
		import std.file : exists, mkdirRecurse;
		import std.path : baseName, dirName;
		import std.logger : tracef;

		auto td = getTask(tid);
		if (td is null)
			return;
		if (tid in jsonlWatches)
			return;
		if (td.agentSessionId.length == 0)
			return;

		auto jsonlPath = getAgent(tid).historyPath(td.agentSessionId, getEffectiveCwd(tid));
		tracef("[jsonl] startJsonlWatch tid=%d sessionId=%s jsonlPath=%s exists=%s",
			tid, td.agentSessionId, jsonlPath, jsonlPath.length > 0 && exists(jsonlPath));
		if (jsonlPath.length == 0)
		{
			// File not discoverable yet (e.g. Codex — JSONL created asynchronously).
			// Schedule a retry so the watch gets established once the file appears.
			import core.time : seconds;
			if (tid !in jsonlRetryTimers)
			{
				auto generation = lineageGeneration.get(tid, 0);
				jsonlRetryTimers[tid] = setTimeout({
					jsonlRetryTimers.remove(tid);
					if (lineageGeneration.get(tid, 0) == generation)
						startJsonlWatch(tid);
				}, 2.seconds);
			}
			return;
		}

		if (auto t = tid in jsonlRetryTimers)
		{
			(*t).cancel();
			jsonlRetryTimers.remove(tid);
		}

		if (exists(jsonlPath))
		{
			watchJsonlFile(tid, jsonlPath);
		}
		else
		{
			// File doesn't exist yet — watch directory for its creation.
			auto dirPath = dirName(jsonlPath);
			auto fileName = baseName(jsonlPath);
			mkdirRecurse(dirPath);
			auto generation = lineageGeneration.get(tid, 0);
			jsonlWatches[tid] = rcINotify.add(dirPath, INotify.Mask.create,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					if (lineageGeneration.get(tid, 0) == generation && name == fileName)
					{
						// File appeared — switch to file watch
						if (auto h = tid in jsonlWatches)
						{
							rcINotify.remove(*h);
							jsonlWatches.remove(tid);
						}
						watchJsonlFile(tid, jsonlPath);
					}
				}
			);
		}
	}

	/// Establish the lineage cursor, register the watch, then consume every
	/// complete line visible after registration.  Watching is an optimization
	/// for later growth; this catch-up is the correctness boundary.
	private void attachAndCatchUp(int tid, string jsonlPath, bool installWatch = true)
	{
		jsonlPaths[tid] = jsonlPath;
		if (tid !in jsonlReadPos)
		{
			if (tid in boundaryState)
			{
				// A live candidate predates attachment, so this lineage must
				// consume all persisted complete lines.
				jsonlReadPos[tid] = 0;
				jsonlLineCount[tid] = 0;
			}
			else
			{
				// A resumed lineage cannot pair a newly emitted live event with
				// any pre-existing persisted turn.
				import std.file : getSize;
				jsonlReadPos[tid] = getSize(jsonlPath);
				jsonlLineCount[tid] = 0;
				boundaryState[tid] = BoundaryReconcileState.init;
			}
		}
		if (installWatch && tid !in jsonlWatches)
		{
			auto generation = lineageGeneration.get(tid, 0);
			jsonlWatches[tid] = rcINotify.add(jsonlPath, INotify.Mask.modify,
				(in char[] name, INotify.Mask mask, uint cookie)
				{
					if (lineageGeneration.get(tid, 0) == generation)
						processNewJsonlContent(tid, jsonlPath);
				}
			);
		}
		processNewJsonlContent(tid, jsonlPath);
	}

	void watchJsonlFile(int tid, string jsonlPath)
	{
		attachAndCatchUp(tid, jsonlPath);
	}

	/// Read new content from the JSONL file and reconcile persisted boundaries.
	void processNewJsonlContent(int tid, string jsonlPath)
	{
		import std.file : exists, getSize;
		import std.logger : tracef;

		if (jsonlPath.length == 0 || !exists(jsonlPath))
		{
			tracef("[jsonl] processNewJsonlContent tid=%d: path missing/nonexistent: %s", tid, jsonlPath);
			return;
		}
		auto fileSize = getSize(jsonlPath);
		auto lastPos = jsonlReadPos.get(tid, 0);
		if (fileSize < lastPos)
		{
			tracef("[jsonl] processNewJsonlContent tid=%d: file shrank (was %d, now %d)", tid, lastPos, fileSize);
			onLineageInvalidated(tid);
			return;
		}
		if (fileSize <= lastPos)
			return;

		auto f = File(jsonlPath, "r");
		f.seek(lastPos);
		char[] buf;
		buf.length = cast(size_t)(fileSize - lastPos);
		auto got = f.rawRead(buf);
		auto newContent = cast(string) got;
		auto completeBytes = completeJsonlByteCount(newContent);
		if (completeBytes == 0)
			return;
		auto completeContent = newContent[0 .. completeBytes];
		jsonlReadPos[tid] = lastPos + completeContent.length;
		if (tid !in boundaryState)
			boundaryState[tid] = BoundaryReconcileState.init;
		boundaryState[tid].partialLine = cast(ubyte[]) newContent[completeBytes .. $].dup;

		auto lineOffset = jsonlLineCount.get(tid, 0);
		auto boundaries = getAgent(tid).extractPersistedHistoryBoundaries(completeContent, lineOffset);
		tracef("[jsonl] processNewJsonlContent tid=%d path=%s newBytes=%d boundaries=%d", tid, jsonlPath, got.length, boundaries.length);

		import std.string : lineSplitter;
		int newLines = 0;
		foreach (_; completeContent.lineSplitter)
			newLines++;
		jsonlLineCount[tid] = lineOffset + newLines;

		import std.algorithm : canFind;
		bool hasRollback = completeContent.canFind(`"thread_rolled_back"`);
		if (hasRollback)
		{
			onLineageInvalidated(tid);
			return;
		}
		foreach (boundary; boundaries)
		{
			if (tid !in boundaryState)
				boundaryState[tid] = BoundaryReconcileState.init;
			auto task = getTask(tid);
			if (boundaryHasCheckpoint(getAgent(tid).driver, boundary.kind))
				boundary.checkpointUuid = task.checkpointUuidForAnchor(boundary.anchor);
			boundaryState[tid].persistedByKind[boundary.kind] ~= PersistedBoundaryCandidate(boundary,
				cast(size_t) boundary.sourceLine, true, historyGeneration(tid));
			drainLiveBoundaries(tid, boundary.kind);
		}
	}

	/// Stop all JSONL watches and clear all snapshots (used during shutdown).
	void stopAllWatches()
	{
		foreach (tid; jsonlWatches.keys)
			stopJsonlWatch(tid);
		foreach (tid; jsonlRetryTimers.keys)
			stopJsonlWatch(tid);
		undoJsonl = null;
	}

	/// Stop watching the JSONL file for a task.
	void stopJsonlWatch(int tid)
	{
		if (auto t = tid in jsonlRetryTimers)
		{
			(*t).cancel();
			jsonlRetryTimers.remove(tid);
		}
		if (auto h = tid in jsonlWatches)
		{
			rcINotify.remove(*h);
			jsonlWatches.remove(tid);
		}
		jsonlReadPos.remove(tid);
		jsonlPaths.remove(tid);
		jsonlLineCount.remove(tid);
		boundaryState.remove(tid);
		// Do NOT remove undoJsonl here: for agents that auto-restart (e.g. Codex
		// exits with SIGTERM and is restarted), the snapshot captured before the
		// stall message is still valid and must survive the restart cycle.
	}

	/// Return the pre-compaction JSONL snapshot for undo, or "" if none.
	string getUndoJsonl(int tid) { return undoJsonl.get(tid, ""); }

	/// Clear the undo snapshot for a task (call after the snapshot has been used).
	void clearUndoJsonl(int tid) { undoJsonl.remove(tid); }

	/// Save the current JSONL content as the undo snapshot for this task.
	/// Call this just before sending a new message to the agent, so the
	/// snapshot captures the state before any agent-side compaction.
	void captureUndoSnapshot(int tid)
	{
		import std.file : exists, readText;
		import std.logger : tracef;

		auto td = getTask(tid);
		if (td is null || td.agentSessionId.length == 0)
			return;
		auto jsonlPath = getAgent(tid).historyPath(td.agentSessionId, getEffectiveCwd(tid));
		if (jsonlPath.length == 0 || !exists(jsonlPath))
			return;
		undoJsonl[tid] = readText(jsonlPath);
		tracef("[jsonl] captureUndoSnapshot tid=%d path=%s bytes=%d", tid, jsonlPath, undoJsonl[tid].length);
	}


	private void resolveBoundary(int tid, size_t seq, PersistedHistoryBoundary boundary,
		bool publish, ulong generation)
	{
		if (onBoundaryResolved is null)
			return;
		onBoundaryResolved(tid, seq, HistoryBoundary(boundary.anchor,
			boundary.kind == PersistedHistoryBoundaryKind.user
				? HistoryBoundaryKind.user : HistoryBoundaryKind.agent_turn,
			boundary.checkpointUuid), publish, generation);
	}
}

unittest
{
	assert(JsonlTracker.boundaryHasCheckpoint(AgentDriver.claude,
		PersistedHistoryBoundaryKind.user));
	assert(!JsonlTracker.boundaryHasCheckpoint(AgentDriver.claude,
		PersistedHistoryBoundaryKind.agent_turn));
	assert(!JsonlTracker.boundaryHasCheckpoint(AgentDriver.codex,
		PersistedHistoryBoundaryKind.user));
}

unittest
{
	import std.conv : to;
	JsonlTracker tracker;
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] = [
		JsonlTracker.LiveBoundaryCandidate(3, PersistedHistoryBoundaryKind.user, "bootstrap", 0),
		JsonlTracker.LiveBoundaryCandidate(10, PersistedHistoryBoundaryKind.user, "second", 0),
		JsonlTracker.LiveBoundaryCandidate(17, PersistedHistoryBoundaryKind.user, "third", 0),
	];
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] = [
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("second", PersistedHistoryBoundaryKind.user, null), 2, true, 0),
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("third", PersistedHistoryBoundaryKind.user, null), 3, true, 0),
	];
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["second:10", "third:17"]);
	auto pending = tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user];
	assert(pending.length == 1 && pending[0].identity == "bootstrap");
}

unittest
{
	import cydo.agent.drivers.codex : CodexAgent;
	import std.conv : to;
	JsonlTracker tracker;
	tracker.getAgent = (int) => cast(Agent) new CodexAgent();
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.noteLiveBoundaryCandidate(1, 4,
		`{"type":"item/started","item_type":"user_message","item_id":"codex-user-0"}`,
		null, 0, true);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("line:18",
			PersistedHistoryBoundaryKind.user, null), 18, true, 0);
	tracker.noteLiveBoundaryCandidate(1, 11,
		`{"type":"item/started","item_type":"user_message","item_id":"codex-user-1"}`);
	assert(resolved == ["line:18:11"]);
}

unittest
{
	import cydo.agent.drivers.codex : CodexAgent;
	import std.conv : to;
	JsonlTracker tracker;
	tracker.getAgent = (int) => cast(Agent) new CodexAgent();
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.noteLiveBoundaryCandidate(1, 4,
		`{"type":"item/started","item_type":"user_message","item_id":"codex-user-0"}`,
		null, 0, true);
	tracker.noteLiveBoundaryCandidate(1, 11,
		`{"type":"item/started","item_type":"user_message","item_id":"codex-user-1"}`);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("line:18",
			PersistedHistoryBoundaryKind.user, null), 18, true, 0);
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["line:18:11"]);
}

unittest
{
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	import std.conv : to;
	JsonlTracker tracker;
	tracker.getAgent = (int) => cast(Agent) new ClaudeCodeAgent();
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("line:4",
			PersistedHistoryBoundaryKind.user, null, 4), 4, false, 0);
	tracker.noteLiveBoundaryCandidate(1, 4,
		`{"type":"item/started","item_type":"user_message","uuid":"live-user","meta":{"label":"Session start: agentic"}}`);
	assert(resolved == ["line:4:4"]);
}

unittest
{
	import std.file : remove, write;
	import cydo.agent.drivers.codex : CodexAgent;
	auto path = "/tmp/cydo-jsonl-tracker-attach.jsonl";
	write(path, `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n");
	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.getAgent = (int) => cast(Agent) new CodexAgent();
	tracker.historyGeneration = (int) => task.history.generation;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary b, bool, ulong) { resolved ~= b.anchor; };
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(0, PersistedHistoryBoundaryKind.user, "", task.history.generation);
	tracker.attachAndCatchUp(1, path, false);
	assert(resolved == ["line:2"]);
	tracker.stopJsonlWatch(1);
	tracker.attachAndCatchUp(1, path, false);
	assert(tracker.jsonlReadPos[1] > 0);
	assert(resolved == ["line:2"]);
	remove(path);
}

unittest
{
	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	tracker.finalReconcileJsonlIfPresent(1);
	assert(1 !in tracker.jsonlPaths);
}

unittest
{
	import std.file : getSize, readText, remove, write;
	import std.conv : to;
	import cydo.agent.drivers.codex : CodexAgent;
	import ae.utils.json : JSONFragment, toJson;
	import cydo.protocol : TaskEventEnvelope;
	auto path = "/tmp/cydo-jsonl-tracker-final-flush.jsonl";
	write(path, `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n");
	TaskData task = TaskData(1, "", "");
	task.agentSessionId = "session";
	task.history.reset(Watermark.none());
	task.history.appendLive(Data(toJson(TaskEventEnvelope(1, 1,
		JSONFragment(`{"type":"item/started","item_type":"user_message"}`))).representation), null);
	JsonlTracker tracker;
	tracker.getTask = (int) => &task;
	tracker.getAgent = (int) => cast(Agent) new CodexAgent();
	tracker.getEffectiveCwd = (int) => "";
	tracker.historyGeneration = (int) => task.history.generation;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.jsonlReadPos[1] = getSize(path);
	tracker.jsonlPaths[1] = path;
	tracker.jsonlLineCount[1] = 1;
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(0, PersistedHistoryBoundaryKind.user, "", task.history.generation);
	write(path, readText(path) ~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n");
	tracker.finalReconcileJsonlIfPresent(1);
	assert(resolved == ["line:2:0"]);
	tracker.finalReconcileJsonlIfPresent(1);
	assert(resolved == ["line:2:0"]);
	remove(path);
}

unittest
{
	import std.exception : assertThrown;
	import core.exception : AssertError;
	import std.conv : to;
	JsonlTracker tracker;
	ulong current = 2;
	tracker.historyGeneration = (int) => current;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	auto staleLive = JsonlTracker.LiveBoundaryCandidate(1, PersistedHistoryBoundaryKind.user, "old", 1);
	auto currentLive = JsonlTracker.LiveBoundaryCandidate(2, PersistedHistoryBoundaryKind.user, "new", 2);
	auto stalePersisted = JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("old", PersistedHistoryBoundaryKind.user, null), 1, true, 1);
	auto currentPersisted = JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("new", PersistedHistoryBoundaryKind.user, null), 2, true, 2);
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~= [staleLive, currentLive];
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~= [stalePersisted, currentPersisted];
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["new:2"]);
	tracker.boundaryState[2] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[2].liveByKind[PersistedHistoryBoundaryKind.user] ~= currentLive;
	tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.user] ~= stalePersisted;
	tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.user] ~= currentPersisted;
	tracker.drainLiveBoundaries(2, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["new:2", "new:2"]);
	tracker.boundaryState[3] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[3].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(3, PersistedHistoryBoundaryKind.user, "future", 3);
	tracker.boundaryState[3].persistedByKind[PersistedHistoryBoundaryKind.user] ~= currentPersisted;
	assertThrown!AssertError(tracker.drainLiveBoundaries(3, PersistedHistoryBoundaryKind.user));
}

unittest
{
	import std.conv : to;
	// A boundary pair can be captured before a reset but resolved only after it.
	// Publication must reject that old lineage and accept a replacement pair.
	JsonlTracker tracker;
	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	tracker.historyGeneration = (int) => task.history.generation;
	string[] resolved;
	tracker.onBoundaryResolved = (int tid, size_t seq, HistoryBoundary boundary, bool,
		ulong generation) {
		if (tracker.historyGeneration(tid) == generation)
			resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	auto stale = task.history.generation;
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(12, PersistedHistoryBoundaryKind.user, "stale", stale);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("stale",
			PersistedHistoryBoundaryKind.user, null), 1, true, stale);
	task.history.reset(Watermark.none());
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved.length == 0);

	auto current = task.history.generation;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(1, PersistedHistoryBoundaryKind.user, "current", current);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("current",
			PersistedHistoryBoundaryKind.user, null), 2, true, current);
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["current:1"]);
}

unittest
{
	import std.conv : to;
	import cydo.agent.drivers.claude : ClaudeCodeAgent;
	string[] resolved;
	JsonlTracker tracker;
	tracker.getAgent = (int) => cast(Agent) new ClaudeCodeAgent();
	tracker.historyGeneration = (int) => 0;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	// Live callback first: the canonical persisted identity resolves the queued live event.
	tracker.noteLiveBoundaryCandidate(1, 7,
		`{"type":"item/started","item_type":"user_message","uuid":"u"}`);
	assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user].length == 1);
	tracker.invalidateLineage(1);
	tracker.historyGeneration = (int) => 0;
	tracker.noteLiveBoundaryCandidate(1, 7,
		`{"type":"item/started","item_type":"user_message","uuid":"u","meta":null}`);
	assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user].length == 1);
	tracker.invalidateLineage(1);
	tracker.historyGeneration = (int) => 0;

	// Live callback first: the canonical persisted identity resolves the queued live event.
	tracker.noteLiveBoundaryCandidate(1, 7,
		`{"type":"item/started","item_type":"user_message","uuid":"u"}`);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("u", PersistedHistoryBoundaryKind.user, null), 1, true, 0);
	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["u:7"]);
	assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user].length == 0);
	assert(tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user].length == 0);

	// Persisted callback first: noteLiveBoundaryCandidate drains the matching canonical queue.
	tracker.boundaryState[2] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.agent_turn] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("turn", PersistedHistoryBoundaryKind.agent_turn, null), 1, true, 0);
	tracker.noteLiveBoundaryCandidate(2, 8, `{"type":"turn/stop","uuid":"turn"}`);
	assert(resolved == ["u:7", "turn:8"]);
	assert(tracker.boundaryState[2].liveByKind[PersistedHistoryBoundaryKind.agent_turn].length == 0);
	assert(tracker.boundaryState[2].persistedByKind[PersistedHistoryBoundaryKind.agent_turn].length == 0);

	// Line anchors have no shared identity and drain FIFO in either callback order.
	tracker.boundaryState[3] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[3].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("line:10", PersistedHistoryBoundaryKind.user, null), 10, false, 0);
	tracker.noteLiveBoundaryCandidate(3, 9,
		`{"type":"item/started","item_type":"user_message"}`);
	assert(resolved == ["u:7", "turn:8", "line:10:9"]);

	// Claude assistant message_stop has no UUID in its live turn/stop event;
	// its persisted assistant UUID must therefore resolve FIFO, unlike users.
	tracker.boundaryState[4] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[4].liveByKind[PersistedHistoryBoundaryKind.agent_turn] ~=
		JsonlTracker.LiveBoundaryCandidate(10, PersistedHistoryBoundaryKind.agent_turn, "", 0);
	tracker.boundaryState[4].persistedByKind[PersistedHistoryBoundaryKind.agent_turn] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("assistant", PersistedHistoryBoundaryKind.agent_turn, null), 1, false, 0);
	tracker.drainLiveBoundaries(4, PersistedHistoryBoundaryKind.agent_turn);
	assert(resolved[$ - 1] == "assistant:10");

	tracker.boundaryState[5] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[5].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(11, PersistedHistoryBoundaryKind.user, "user-a", 0);
	tracker.boundaryState[5].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("user-b", PersistedHistoryBoundaryKind.user, null), 1, true, 0);
	tracker.drainLiveBoundaries(5, PersistedHistoryBoundaryKind.user);
	assert(resolved[$ - 1] == "user-b:11");
}

unittest
{
	JsonlTracker tracker;
	tracker.historyGeneration = (int) => 0;
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.LiveBoundaryCandidate(4, PersistedHistoryBoundaryKind.user, "user", 0);
	tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
		JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("user",
			PersistedHistoryBoundaryKind.user, null), 1, true, 0);
	tracker.jsonlReadPos[1] = 42;
	tracker.jsonlLineCount[1] = 3;

	tracker.stopJsonlWatch(1);

	assert(1 !in tracker.boundaryState);
	assert(1 !in tracker.jsonlReadPos);
	assert(1 !in tracker.jsonlLineCount);

	// Invalidation advances the watch generation, so a callback captured by the
	// old watch cannot process the replacement lineage.
	tracker.lineageGeneration[2] = 4;
	auto staleGeneration = tracker.lineageGeneration[2];
	tracker.invalidateLineage(2);
	assert(tracker.lineageGeneration[2] != staleGeneration);
}

unittest
{
	import std.string : lineSplitter;
	import cydo.agent.drivers.codex : CodexAgent;

	auto firstNotification = `{"type":"user.message","id":"u"}`;
	assert(JsonlTracker.completeJsonlByteCount(firstNotification) == 0);
	int incompleteLines;
	foreach (_; firstNotification.lineSplitter)
		incompleteLines++;
	assert(incompleteLines == 1);

	auto completedNotification = firstNotification ~ "\n";
	auto completeBytes = JsonlTracker.completeJsonlByteCount(completedNotification);
	assert(completeBytes == completedNotification.length);
	auto completeContent = completedNotification[0 .. completeBytes];
	int completeLines;
	foreach (_; completeContent.lineSplitter)
		completeLines++;
	assert(completeLines == 1);

	auto startup = `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n"
		~ `{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}`;
	auto startupBytes = JsonlTracker.completeJsonlByteCount(startup);
	assert(startupBytes > 0 && startupBytes < startup.length);
	int committedLines;
	foreach (_; startup[0 .. startupBytes].lineSplitter)
		committedLines++;
	Agent agent = new CodexAgent();
	auto completed = startup[startupBytes .. $] ~ "\n";
	auto boundaries = agent.extractPersistedHistoryBoundaries(completed, committedLines);
	assert(boundaries.length == 1);
	assert(boundaries[0].anchor == "line:2");
}

unittest
{
	import std.conv : to;
	import std.file : remove, write;
	import cydo.agent.drivers.codex : CodexAgent;

	// A notification may arrive after stdout supplied the live candidate but
	// before the writer has finished its JSONL line.  The completed line must
	// be consumed once, rather than losing or replaying its boundary.
	auto path = "/tmp/cydo-jsonl-tracker-split-tail.jsonl";
	auto taskStarted = `{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n";
	auto line = `{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}`;
	write(path, taskStarted ~ line[0 .. 20]);

	TaskData task = TaskData(1, "", "");
	task.history.reset(Watermark.none());
	JsonlTracker tracker;
	tracker.getAgent = (int) => cast(Agent) new CodexAgent();
	tracker.getTask = (int) => &task;
	tracker.historyGeneration = (int) => task.history.generation;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.noteLiveBoundaryCandidate(1, 12,
		`{"type":"item/started","item_type":"user_message"}`);

	tracker.processNewJsonlContent(1, path);
	assert(resolved.length == 0);
	File(path, "a").write(line[20 .. $] ~ "\n");
	tracker.processNewJsonlContent(1, path);
	tracker.processNewJsonlContent(1, path);
	assert(resolved.length == 1);
	assert(resolved[0] == "line:2:12");
	remove(path);
}

unittest
{
	import std.conv : to;

	// When both queues already contain consecutive compatible boundaries, one
	// reconciliation pass preserves their full FIFO order.
	JsonlTracker tracker;
	tracker.historyGeneration = (int) => 0;
	string[] resolved;
	tracker.onBoundaryResolved = (int, size_t seq, HistoryBoundary boundary, bool, ulong) {
		resolved ~= boundary.anchor ~ ":" ~ to!string(seq);
	};
	tracker.boundaryState[1] = JsonlTracker.BoundaryReconcileState.init;
	foreach (i; 0 .. 2)
	{
		tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user] ~=
			JsonlTracker.LiveBoundaryCandidate(10 + i, PersistedHistoryBoundaryKind.user, "", 0);
		tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user] ~=
			JsonlTracker.PersistedBoundaryCandidate(PersistedHistoryBoundary("line:" ~ to!string(i + 1),
				PersistedHistoryBoundaryKind.user, null), i + 1, false, 0);
	}

	tracker.drainLiveBoundaries(1, PersistedHistoryBoundaryKind.user);
	assert(resolved == ["line:1:10", "line:2:11"]);
	assert(tracker.boundaryState[1].liveByKind[PersistedHistoryBoundaryKind.user].length == 0);
	assert(tracker.boundaryState[1].persistedByKind[PersistedHistoryBoundaryKind.user].length == 0);
}

unittest
{
	import cydo.agent.drivers.codex : computeRollbackSkipLines;
	auto jsonl =
		`{"type":"event_msg","payload":{"type":"task_started"}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"user","content":[]}}` ~ "\n" ~
		`{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}` ~ "\n" ~
		`{"type":"event_msg","payload":{"type":"thread_rolled_back","num_turns":1}}`;
	auto skipped = computeRollbackSkipLines(jsonl);
	assert(4 in skipped && 5 in skipped);
}
