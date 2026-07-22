module cydo.workflow.batch.registry;

/**
 * Live batch registry for CyDo's `Task(...)` tool calls.
 *
 * In CyDo terms, a batch is the live backend state for one `Task(...)` call.
 * It tracks the child tids launched by that call, each child's result slot,
 * completion flags, result values, and the event queue that wakes the waiting
 * parent task.
 *
 * Batches exist because a single `Task(...)` can launch multiple children and
 * then wait for a stream of child completion/question events until all slots
 * are complete. If a child asks the parent a question, the batch is suspended
 * and must remain live so `Answer(qid)` can resume that exact `Task(...)`.
 *
 * A parent can therefore own multiple live batches at once: while one batch is
 * suspended on a child question, the parent may launch a newer `Task(...)` that
 * creates another live batch.
 *
 * `BatchRegistry` owns live batch identity and indexes. `App` owns task
 * lifecycle and question-routing policy.
 */
import std.format : format;
import std.conv : to;

import ae.utils.promise : Promise;

import cydo.workflow.batch.router : BatchConsumeKind, BatchConsumeResult, BatchState, assertBatchStateShape,
	buildBatchState, consumeBatchSignal, validateBatchCompletion;
import cydo.mcp : McpResult;
import cydo.domain.tasks.model : BatchSignal;

package(cydo):

/// Exact identity handle for one live batch owned by one parent task.
struct BatchHandle
{
	int parentTid;
	ulong batchId;
}

/// Hash key equivalent of `BatchHandle` used in registry maps.
struct ActiveBatchKey
{
	int parentTid;
	ulong batchId;

	size_t toHash() const nothrow @safe @nogc
	{
		size_t h = cast(size_t)parentTid;
		h ^= cast(size_t)(batchId ^ (batchId >> 32));
		return h;
	}

	bool opEquals(scope const ActiveBatchKey other) const nothrow @safe @nogc
	{
		return parentTid == other.parentTid && batchId == other.batchId;
	}
}

/**
 * Registry of live `Task(...)` batches.
 *
 * Invariants:
 * - Live batch identity is `(parentTid, batchId)`.
 * - A parent may own multiple live batches.
 * - A child tid is owned by zero or one live batch.
 * - A live batch's ordered child list, slot map, and unfinished-child
 *   ownership map agree exactly.
 * - Child ownership is released when that child slot completes.
 * - Finalizing/removing a batch affects only that exact batch handle.
 * - Exact routing uses batch handle, qid route, or child ownership; never
 *   parent recency.
 * - Parent-wide scans are only for predicates like "any live batch?" or
 *   "find any pending child question owned by this parent."
 */
struct BatchRegistry
{
private:
	BatchState[ActiveBatchKey] activeBatches;
	ulong[][int] batchIdsByParentTid;
	ActiveBatchKey[int] batchKeyByChildTid;
	ulong nextBatchId = 1;

	ActiveBatchKey batchKey(BatchHandle handle) const
	{
		return ActiveBatchKey(handle.parentTid, handle.batchId);
	}

	BatchState* findBatch(BatchHandle handle)
	{
		auto key = batchKey(handle);
		return key in activeBatches;
	}

	BatchState* findBatch(ActiveBatchKey key)
	{
		return key in activeBatches;
	}

	/**
	 * Assert the complete relation represented by the three live indexes.
	 *
	 * A batch keeps historical completed slots in childTids, so they do not
	 * themselves claim a reverse-map entry. The expected reverse map is instead
	 * derived only from unfinished slots. This permits an old completed slot and
	 * one later unfinished owner for the same child, while rejecting every
	 * dangling, missing, duplicate, or wrong reverse entry.
	 */
	void assertRegistryConsistent()
	{
		ActiveBatchKey[int] expectedOwnerByChildTid;

		foreach (key, batch; activeBatches)
		{
			assert(batch.batchId == key.batchId,
				format!"active batch id mismatch parent=%d key_batch=%s state_batch=%s"(
					key.parentTid, key.batchId, batch.batchId));
			assertBatchStateShape(batch);

			foreach (slot, childTid; batch.childTids)
			{
				if (batch.done[slot])
					continue;
				auto existing = childTid in expectedOwnerByChildTid;
				assert(existing is null,
					format!"multiple unfinished child claims child=%d parent=%d batch=%s"(
						childTid, key.parentTid, key.batchId));
				expectedOwnerByChildTid[childTid] = key;
			}
		}

		foreach (parentTid, ids; batchIdsByParentTid)
		{
			assert(ids.length > 0,
				format!"parent index has empty batch list parent=%d"(parentTid));
			bool[ulong] seenBatchIds;
			foreach (batchId; ids)
			{
				assert((batchId in seenBatchIds) is null,
					format!"parent index repeats batch id parent=%d batch=%s"(
						parentTid, batchId));
				seenBatchIds[batchId] = true;
				assert(ActiveBatchKey(parentTid, batchId) in activeBatches,
					format!"parent index points to missing batch parent=%d batch=%s"(
						parentTid, batchId));
			}
		}

		foreach (key, _; activeBatches)
		{
			auto ids = key.parentTid in batchIdsByParentTid;
			assert(ids !is null,
				format!"live batch missing parent index parent=%d batch=%s"(
					key.parentTid, key.batchId));
			size_t occurrences;
			foreach (batchId; *ids)
				if (batchId == key.batchId)
					occurrences++;
			assert(occurrences == 1,
				format!"live batch must appear exactly once in parent index parent=%d batch=%s occurrences=%s"(
					key.parentTid, key.batchId, occurrences));
		}

		foreach (childTid, expected; expectedOwnerByChildTid)
		{
			auto actual = childTid in batchKeyByChildTid;
			assert(actual !is null,
				format!"unfinished child missing reverse owner child=%d parent=%d batch=%s"(
					childTid, expected.parentTid, expected.batchId));
			assert(*actual == expected,
				format!"unfinished child reverse owner mismatch child=%d expected_parent=%d expected_batch=%s actual_parent=%d actual_batch=%s"(
					childTid, expected.parentTid, expected.batchId,
					actual.parentTid, actual.batchId));
		}

		foreach (childTid, actual; batchKeyByChildTid)
		{
			auto expected = childTid in expectedOwnerByChildTid;
			assert(expected !is null,
				format!"reverse owner has no unfinished child claim child=%d owner_parent=%d owner_batch=%s"(
					childTid, actual.parentTid, actual.batchId));
			assert(*expected == actual,
				format!"reverse owner disagrees with unfinished child claim child=%d expected_parent=%d expected_batch=%s actual_parent=%d actual_batch=%s"(
					childTid, expected.parentTid, expected.batchId,
					actual.parentTid, actual.batchId));
		}
	}

	void assertExactLiveSlot(BatchHandle handle, ref const BatchState batch,
		size_t slot, int childTid, string signalKind)
	{
		assert(batch.batchId == handle.batchId,
			format!"%s batch identity mismatch: parent=%d handle_batch=%s state_batch=%s"(
				signalKind, handle.parentTid, handle.batchId, batch.batchId));
		assert(slot < batch.childTids.length,
			format!"%s slot out of range: parent=%d batch=%s child=%d slot=%s child_count=%s"(
				signalKind, handle.parentTid, handle.batchId, childTid, slot,
				batch.childTids.length));
		assert(batch.childTids[slot] == childTid,
			format!"%s slot ownership mismatch: parent=%d batch=%s child=%d slot=%s expected_child=%d"(
				signalKind, handle.parentTid, handle.batchId, childTid, slot,
				batch.childTids[slot]));
		auto mappedSlot = childTid in batch.slotByChildTid;
		assert(mappedSlot !is null,
			format!"%s child missing slot map: parent=%d batch=%s child=%d slot=%s"(
				signalKind, handle.parentTid, handle.batchId, childTid, slot));
		assert(*mappedSlot == slot,
			format!"%s slot map mismatch: parent=%d batch=%s child=%d signal_slot=%s mapped_slot=%s"(
				signalKind, handle.parentTid, handle.batchId, childTid, slot,
				*mappedSlot));
	}

	void addActiveBatch(int parentTid, ref BatchState batch)
	{
		auto key = ActiveBatchKey(parentTid, batch.batchId);
		activeBatches[key] = batch;
		batchIdsByParentTid[parentTid] ~= batch.batchId;
		foreach (childTid; batch.childTids)
			batchKeyByChildTid[childTid] = key;
	}

	/// Commit an already-preflighted exact batch removal.
	void removePrepared(ActiveBatchKey key, ref const BatchState batch)
	{
		auto idsPtr = key.parentTid in batchIdsByParentTid;
		assert(idsPtr !is null,
			format!"live batch missing parent index before removal parent=%d batch=%s"(
				key.parentTid, key.batchId));
		auto remainingIds = (*idsPtr).dup;
		size_t write;
		size_t occurrences;
		foreach (batchId; remainingIds)
		{
			if (batchId == key.batchId)
			{
				occurrences++;
				continue;
			}
			remainingIds[write++] = batchId;
		}
		remainingIds.length = write;
		assert(occurrences == 1,
			format!"live batch must appear exactly once before removal parent=%d batch=%s occurrences=%s"(
				key.parentTid, key.batchId, occurrences));

		int[] reverseEntriesToRemove;
		foreach (childTid; batch.childTids)
			if (auto owner = childTid in batchKeyByChildTid)
				if (*owner == key)
					reverseEntriesToRemove ~= childTid;

		activeBatches.remove(key);
		if (remainingIds.length > 0)
			batchIdsByParentTid[key.parentTid] = remainingIds;
		else
			batchIdsByParentTid.remove(key.parentTid);
		foreach (childTid; reverseEntriesToRemove)
			batchKeyByChildTid.remove(childTid);
	}

public:
	/**
	 * Register a new live batch for one parent and child tid set.
	 *
	 * Use when handling a new `Task(...)` launch result, before waiting for any
	 * child events. This is an exact registration call: ownership is tied to the
	 * returned `(parentTid, batchId)` handle.
	 *
	 * Returns `false` with non-empty `error` when child input is invalid or an
	 * unfinished child already has a live owner.
	 */
	bool create(int parentTid, int[] childTids, out BatchHandle handle, out string error)
	{
		assertRegistryConsistent();
		string candidateError;
		auto batch = buildBatchState(nextBatchId, childTids, candidateError);
		if (candidateError.length > 0)
		{
			handle = BatchHandle.init;
			error = candidateError;
			return false;
		}
		assertBatchStateShape(batch);
		auto key = ActiveBatchKey(parentTid, batch.batchId);
		assert((key in activeBatches) is null,
			format!"duplicate active batch registration for parent=%d batch=%s"(
				parentTid, batch.batchId));
		foreach (childTid; childTids)
		{
			if (auto owner = childTid in batchKeyByChildTid)
			{
				error = format!"child tid=%d already owned by parent=%d batch=%s"(childTid, owner.parentTid, owner.batchId);
				handle = BatchHandle.init;
				return false;
			}
		}
		addActiveBatch(parentTid, batch);
		handle = BatchHandle(parentTid, batch.batchId);
		nextBatchId++;
		error = "";
		return true;
	}

	/// Exact liveness lookup: do not use this to infer parent or child ownership.
	bool exists(BatchHandle handle)
	{
		return findBatch(handle) !is null;
	}

	/**
	 * Parent-wide predicate: does this parent currently own any live batch?
	 *
	 * Callers use this for broad routing policy checks, not exact event routing.
	 * Every indexed batch must resolve to this parent, and every live batch for
	 * this parent must appear exactly once in the parent index.
	 */
	bool parentHasLiveBatches(int parentTid)
	{
		assertRegistryConsistent();
		auto ids = parentTid in batchIdsByParentTid;
		return ids !is null && ids.length > 0;
	}

	/**
	 * Exact child-ownership lookup across all live batches.
	 *
	 * Use for routing events keyed by child tid. If ownership exists, returns
	 * `true` and fills the owning handle/slot.
	 *
	 * Returns `false` only when no live unfinished slot claims `childTid`.
	 * Structural disagreement in any registry index asserts before this lookup
	 * returns, so callers cannot mistake corruption for an ordinary error.
	 */
	bool findOwnerOfChild(int childTid, out BatchHandle handle, out size_t slot)
	{
		assertRegistryConsistent();
		auto keyPtr = childTid in batchKeyByChildTid;
		if (keyPtr is null)
		{
			handle = BatchHandle.init;
			slot = 0;
			return false;
		}
		auto key = *keyPtr;
		handle = BatchHandle(key.parentTid, key.batchId);
		auto batch = findBatch(key);
		assert(batch !is null,
			format!"reverse owner points to missing batch child=%d owner_parent=%d owner_batch=%s"(
				childTid, key.parentTid, key.batchId));
		auto slotPtr = childTid in batch.slotByChildTid;
		assert(slotPtr !is null && *slotPtr < batch.childTids.length
			&& batch.childTids[*slotPtr] == childTid && !batch.done[*slotPtr],
			format!"reverse owner does not name an unfinished child claim child=%d owner_parent=%d owner_batch=%s"(
				childTid, key.parentTid, key.batchId));
		slot = *slotPtr;
		return true;
	}

	/**
	 * Parent-wide scan for the first child tid matching `matches`.
	 *
	 * Use only for parent-level predicates/questions (for example, find any
	 * pending child question for a parent). Do not use for exact routing of a
	 * known batch event.
	 *
	 * Returns `true` when a match is found and `false` when no matching live
	 * child exists. Every indexed batch must resolve to this parent, and every
	 * live batch for this parent must appear exactly once in the parent index.
	 * Every live child ownership relation is validated before `matches` runs.
	 */
	bool findFirstLiveChild(int parentTid,
		scope bool delegate(int childTid) matches,
		out int childTid)
	{
		assertRegistryConsistent();
		auto ids = parentTid in batchIdsByParentTid;
		if (ids is null || ids.length == 0)
		{
			childTid = 0;
			return false;
		}
		foreach (batchId; *ids)
		{
			auto batch = findBatch(BatchHandle(parentTid, batchId));
			assert(batch !is null,
				format!"parent index points to missing batch parent=%d batch=%s"
					(parentTid, batchId));
			foreach (slot, cTid; batch.childTids)
				if (!batch.done[slot])
					if (matches(cTid))
				{
					childTid = cTid;
					return true;
				}
		}
		childTid = 0;
		return false;
	}

	/**
	 * Wait for one queued signal on an exact live batch handle.
	 *
	 * Callers should use this only after successful `create`, and only with that
	 * exact handle. Returns a promise for the next childDone/question event.
	 *
	 * Returns `false` with empty `error` when the batch is already complete.
	 * Returns `false` with non-empty `error` when the batch disappeared.
	 */
	bool waitOne(BatchHandle handle,
		out Promise!BatchSignal event, out string error)
	{
		auto batch = findBatch(handle);
		if (batch is null)
		{
			event = null;
			error = format!"batch disappeared while waiting for parent tid=%d batch=%s"
				(handle.parentTid, handle.batchId);
			return false;
		}
		assertBatchStateShape(*batch);
		if (batch.completed >= batch.totalChildren)
		{
			event = null;
			error = "";
			return false;
		}
		event = batch.eventQueue.waitOne();
		error = "";
		return true;
	}

	/**
	 * Consume one signal for an exact live batch and update batch state.
	 *
	 * Use this immediately after `waitOne` resolves. This is exact routing; pass
	 * the same handle that produced the signal. On `childDone`, ownership for
	 * the completed slot is released.
	 *
	 * A foreign batch signal remains ignored. Every same-batch signal is
	 * globally and exactly preflighted before the pure consumer can mutate a
	 * result slot; a real completion then removes its already-proven reverse
	 * claim without another fallible ownership branch.
	 */
	BatchConsumeResult consume(BatchHandle handle, BatchSignal signal,
		scope bool delegate(int childTid, int qid) hasPendingQuestion,
		out string error)
	{
		BatchConsumeResult ignored;
		auto batch = findBatch(handle);
		if (batch is null)
		{
			error = format!"batch disappeared after event for parent tid=%d batch=%s"
				(handle.parentTid, handle.batchId);
			return ignored;
		}
		if (signal.batchId != batch.batchId)
		{
			error = "";
			return consumeBatchSignal(*batch, signal, hasPendingQuestion);
		}

		assertRegistryConsistent();
		assertExactLiveSlot(handle, *batch, signal.slot, signal.childTid,
			"batch signal");
		bool releasesChild = signal.kind == BatchSignal.Kind.childDone
			&& !batch.done[signal.slot];
		if (releasesChild)
		{
			auto owner = signal.childTid in batchKeyByChildTid;
			assert(owner !is null && *owner == batchKey(handle),
				format!"unfinished completion missing exact reverse owner parent=%d batch=%s child=%d slot=%s"(
					handle.parentTid, handle.batchId, signal.childTid, signal.slot));
		}
		auto consumed = consumeBatchSignal(*batch, signal, hasPendingQuestion);
		if (releasesChild)
			batchKeyByChildTid.remove(signal.childTid);
		error = "";
		return consumed;
	}

	/**
	 * Finalize an exact completed batch and return ordered child results.
	 *
	 * Use only after the batch reaches completion. This validates completion
	 * invariants, copies results, and removes that exact batch from the live
	 * registry.
	 *
	 * Returns `false` with non-empty `error` when the batch is missing or any
	 * completion/index invariant is broken.
	 */
	bool finalize(BatchHandle handle,
		out McpResult[] results, out string error)
	{
		auto batch = findBatch(handle);
		if (batch is null)
		{
			results = null;
			error = format!"batch missing before finalization for parent tid=%d batch=%s"
				(handle.parentTid, handle.batchId);
			return false;
		}

		assertRegistryConsistent();
		auto invariantError = validateBatchCompletion(*batch);
		if (invariantError.length > 0)
		{
			results = null;
			error = format!"cannot finalize parent tid=%d batch=%s: %s"
				(handle.parentTid, handle.batchId, invariantError);
			return false;
		}

		auto finalizedResults = batch.results.dup;
		removePrepared(batchKey(handle), *batch);
		results = finalizedResults;
		error = "";
		return true;
	}

	/**
	 * Enqueue a `childDone` signal for an exact live batch slot ownership.
	 *
	 * An already-removed batch is a stale late signal and is safely ignored.
	 * A live batch must own the supplied slot/child tuple.
	 */
	void enqueueChildDone(BatchHandle handle, size_t slot, int childTid,
		McpResult result)
	{
		auto batch = findBatch(handle);
		if (batch is null)
			return;
		assertRegistryConsistent();
		assertExactLiveSlot(handle, *batch, slot, childTid, "childDone");
		batch.eventQueue.fulfillOne(BatchSignal.childDone(handle.batchId, slot, childTid, result));
	}

	/**
	 * Enqueue a child question signal for an exact live batch slot ownership.
	 *
	 * An already-removed batch is a stale late signal and is safely ignored.
	 * A live batch must own the supplied slot/child tuple.
	 */
	void enqueueQuestion(BatchHandle handle, size_t slot, int childTid,
		string questionText, int qid)
	{
		auto batch = findBatch(handle);
		if (batch is null)
			return;
		assertRegistryConsistent();
		assertExactLiveSlot(handle, *batch, slot, childTid, "question");
		batch.eventQueue.fulfillOne(BatchSignal.question(handle.batchId, slot, childTid, questionText, qid));
	}

	/**
	 * Remove one exact batch handle from all live indexes.
	 *
	 * `remove` is batch-specific and never targets "latest for parent". Returns
	 * `true` with empty `error` when the batch is already absent (stale late
	 * cleanup signal). A live removal globally preflights before changing any
	 * index, so structural disagreement asserts rather than leaving a partial
	 * cleanup behind.
	 */
	bool remove(BatchHandle handle, out string error)
	{
		auto key = batchKey(handle);
		auto batchPtr = key in activeBatches;
		if (batchPtr is null)
		{
			error = "";
			return true;
		}
		assertRegistryConsistent();
		removePrepared(key, *batchPtr);
		error = "";
		return true;
	}
}

unittest
{
	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [11], first, error), error);
	assert(registry.create(100, [22], second, error), error);
	assert(registry.exists(first));
	assert(registry.exists(second));

	size_t slot;
	BatchHandle owner;
	assert(registry.findOwnerOfChild(11, owner, slot));
	assert(owner.parentTid == 100 && owner.batchId == first.batchId);
	assert(registry.findOwnerOfChild(22, owner, slot));
	assert(owner.parentTid == 100 && owner.batchId == second.batchId);
}

unittest
{
	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [11], first, error), error);
	assert(!registry.create(100, [11], second, error));
	assert(error == "child tid=11 already owned by parent=100 batch=" ~ first.batchId.to!string);
}

unittest
{
	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11, 22], handle, error), error);

	auto consumed = registry.consume(handle,
		BatchSignal.childDone(handle.batchId, 0, 11, McpResult("done", false)),
		(int childTid, int qid) => false,
		error);
	assert(error.length == 0);
	assert(consumed.kind == BatchConsumeKind.childDone);

	size_t slot;
	BatchHandle owner;
	assert(!registry.findOwnerOfChild(11, owner, slot));
	assert(registry.findOwnerOfChild(22, owner, slot));
	assert(owner.batchId == handle.batchId);
	assert(slot == 1);
	assert(registry.exists(handle));
}

unittest
{
	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [11], first, error), error);
	assert(registry.create(100, [22], second, error), error);

	assert(registry.remove(first, error), error);
	assert(!registry.exists(first));
	assert(registry.exists(second));
	assert(registry.parentHasLiveBatches(100));

	size_t slot;
	BatchHandle owner;
	assert(!registry.findOwnerOfChild(11, owner, slot));
	assert(registry.findOwnerOfChild(22, owner, slot));
	assert(owner.batchId == second.batchId);
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [31, 32], first, error), error);
	assert(registry.create(100, [41], second, error), error);

	int childTid;
	assert(registry.findFirstLiveChild(100,
		(int cTid) => cTid > 0, childTid));
	assert(childTid == 31);

	assert(registry.findFirstLiveChild(100,
		(int cTid) => cTid == 41, childTid));
	assert(childTid == 41);

	assert(!registry.findFirstLiveChild(100,
		(int cTid) => cTid == 99, childTid));
	assert(childTid == 0);
	assert(!registry.parentHasLiveBatches(999));
	registry.batchIdsByParentTid[999] = [];
	assertThrown!AssertError(registry.parentHasLiveBatches(999));
	bool matchesCalled;
	assertThrown!AssertError(registry.findFirstLiveChild(999,
		(int cTid) { matchesCalled = true; return true; }, childTid));
	assert(!matchesCalled);
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(1, [2], handle, error), error);

	assertThrown!AssertError(registry.enqueueChildDone(handle, 1, 2,
		McpResult("wrong slot", false)));
	assertThrown!AssertError(registry.enqueueChildDone(handle, 0, 3,
		McpResult("wrong child", false)));
	assertThrown!AssertError(registry.enqueueQuestion(handle, 1, 2,
		"wrong slot", 10));
	assertThrown!AssertError(registry.enqueueQuestion(handle, 0, 3,
		"wrong child", 11));

	auto consumed = registry.consume(handle,
		BatchSignal.childDone(handle.batchId, 0, 2,
			McpResult("done", false)),
		(int childTid, int qid) => false,
		error);
	assert(error.length == 0);
	assert(consumed.kind == BatchConsumeKind.childDone);
	McpResult[] results;
	assert(registry.finalize(handle, results, error), error);
	assert(!registry.exists(handle));
	registry.enqueueChildDone(handle, 99, 999,
		McpResult("late completion", false));
	registry.enqueueQuestion(handle, 99, 999, "late question", 12);
	assert(!registry.exists(handle));
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);
	auto missingBatchId = handle.batchId + 1000;
	registry.batchIdsByParentTid[100] =
		[missingBatchId] ~ registry.batchIdsByParentTid[100];

	assertThrown!AssertError(registry.parentHasLiveBatches(100));
	int childTid;
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) => false, childTid));
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);
	registry.batchIdsByParentTid.remove(100);

	assertThrown!AssertError(registry.parentHasLiveBatches(100));
	int childTid;
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) => false, childTid));
	registry.batchIdsByParentTid[100] = [];
	assertThrown!AssertError(registry.parentHasLiveBatches(100));
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) => false, childTid));
	assert(registry.exists(handle));
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [11], first, error), error);
	assert(registry.create(100, [22], second, error), error);

	registry.batchIdsByParentTid[100] = [first.batchId];
	assertThrown!AssertError(registry.parentHasLiveBatches(100));
	int childTid;
	bool matchesCalled;
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) { matchesCalled = true; return cTid == 11; }, childTid));
	assert(!matchesCalled);

	registry.batchIdsByParentTid[100] = [first.batchId, first.batchId,
		second.batchId];
	assertThrown!AssertError(registry.parentHasLiveBatches(100));
	matchesCalled = false;
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) { matchesCalled = true; return cTid == 11; }, childTid));
	assert(!matchesCalled);

	registry.batchIdsByParentTid[100] = [first.batchId, second.batchId,
		second.batchId + 1000];
	assertThrown!AssertError(registry.parentHasLiveBatches(100));
	matchesCalled = false;
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) { matchesCalled = true; return cTid == 11; }, childTid));
	assert(!matchesCalled);

	registry.batchIdsByParentTid[100] = [first.batchId, second.batchId];
	BatchHandle foreign;
	assert(registry.create(200, [33], foreign, error), error);
	registry.batchIdsByParentTid[100] = [first.batchId, second.batchId,
		foreign.batchId];
	assertThrown!AssertError(registry.parentHasLiveBatches(100));
	matchesCalled = false;
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) { matchesCalled = true; return cTid == 11; }, childTid));
	assert(!matchesCalled);
	assert(registry.exists(first));
	assert(registry.exists(second));
	assert(registry.exists(foreign));
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle first;
	BatchHandle second;
	string error;
	assert(registry.create(100, [11], first, error), error);
	assert(registry.create(100, [22], second, error), error);

	auto key = ActiveBatchKey(second.parentTid, second.batchId);
	registry.activeBatches[key].childTids[0] = 99;

	int childTid;
	bool matchesCalled;
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) { matchesCalled = true; return cTid == 11; }, childTid));
	assert(!matchesCalled);
	assert(registry.exists(first));
	assert(registry.exists(second));
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);
	auto key = ActiveBatchKey(handle.parentTid, handle.batchId);
	registry.batchIdsByParentTid.remove(100);
	assertThrown!AssertError(registry.remove(handle, error));
	assert(registry.exists(handle));
	assert(registry.activeBatches.length == 1);
	assert((key in registry.activeBatches) !is null);
	assert((11 in registry.batchKeyByChildTid) !is null);
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);
	auto nextBatchId = registry.nextBatchId;
	registry.batchKeyByChildTid.remove(11);

	BatchHandle owner;
	size_t slot;
	assertThrown!AssertError(registry.findOwnerOfChild(11, owner, slot));
	int childTid;
	bool matchesCalled;
	assertThrown!AssertError(registry.findFirstLiveChild(100,
		(int cTid) { matchesCalled = true; return cTid == 11; }, childTid));
	assert(!matchesCalled);

	BatchHandle rejected;
	assertThrown!AssertError(registry.create(100, [0], rejected, error));
	assert(rejected == BatchHandle.init);
	assert(error.length == 0);
	assert(registry.nextBatchId == nextBatchId);
	assert(registry.activeBatches.length == 1);
	auto ids = 100 in registry.batchIdsByParentTid;
	assert(ids !is null && *ids == [handle.batchId]);
	assert((11 in registry.batchKeyByChildTid) is null);
}

unittest
{
	BatchRegistry healthy;
	BatchHandle rejected;
	string error;
	assert(!healthy.create(100, [0], rejected, error));
	assert(error.length > 0);
	assert(rejected == BatchHandle.init);
	assert(healthy.nextBatchId == 1);
	assert(healthy.activeBatches.length == 0);
	assert(healthy.batchIdsByParentTid.length == 0);
	assert(healthy.batchKeyByChildTid.length == 0);
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle first;
	string error;
	assert(registry.create(100, [11], first, error), error);
	registry.nextBatchId = first.batchId;

	BatchHandle rejected;
	string rejectedError;
	assertThrown!AssertError(registry.create(100, [22], rejected,
		rejectedError));
	assert(rejected == BatchHandle.init);
	assert(rejectedError.length == 0);
	assert(registry.nextBatchId == first.batchId);
	assert(registry.activeBatches.length == 1);
	auto batch = ActiveBatchKey(first.parentTid, first.batchId)
		in registry.activeBatches;
	assert(batch !is null && (*batch).childTids == [11]);
	auto ids = first.parentTid in registry.batchIdsByParentTid;
	assert(ids !is null && *ids == [first.batchId]);
	auto owner = 11 in registry.batchKeyByChildTid;
	assert(owner !is null && *owner == ActiveBatchKey(first.parentTid,
		first.batchId));
	assert((22 in registry.batchKeyByChildTid) is null);
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	{
		BatchRegistry registry;
		BatchHandle handle;
		string error;
		assert(registry.create(100, [11], handle, error), error);
		registry.batchKeyByChildTid[11] = ActiveBatchKey(999, 999);

		BatchHandle owner;
		size_t slot;
		assertThrown!AssertError(registry.findOwnerOfChild(11, owner, slot));
	}

	{
		BatchRegistry registry;
		BatchHandle claimed;
		BatchHandle wrong;
		string error;
		assert(registry.create(100, [11], claimed, error), error);
		assert(registry.create(100, [22], wrong, error), error);
		registry.batchKeyByChildTid[11] = ActiveBatchKey(wrong.parentTid,
			wrong.batchId);

		BatchHandle owner;
		size_t slot;
		assertThrown!AssertError(registry.findOwnerOfChild(11, owner, slot));
	}

	{
		BatchRegistry registry;
		BatchHandle completed;
		string error;
		assert(registry.create(100, [11], completed, error), error);
		assert(registry.consume(completed,
			BatchSignal.childDone(completed.batchId, 0, 11,
				McpResult("done", false)),
			(int childTid, int qid) => false, error).kind
			== BatchConsumeKind.childDone);
		assert(error.length == 0);
		registry.batchKeyByChildTid[11] = ActiveBatchKey(completed.parentTid,
			completed.batchId);

		BatchHandle owner;
		size_t slot;
		assertThrown!AssertError(registry.findOwnerOfChild(11, owner, slot));
	}

	{
		BatchRegistry registry;
		BatchHandle handle;
		string error;
		assert(registry.create(100, [11], handle, error), error);
		registry.batchKeyByChildTid[99] = ActiveBatchKey(handle.parentTid,
			handle.batchId);

		int childTid;
		bool matchesCalled;
		assertThrown!AssertError(registry.findFirstLiveChild(100,
			(int cTid) { matchesCalled = true; return true; }, childTid));
		assert(!matchesCalled);
	}

	{
		BatchRegistry registry;
		BatchHandle first;
		BatchHandle second;
		string error;
		assert(registry.create(100, [11], first, error), error);
		assert(registry.create(200, [22], second, error), error);
		auto secondKey = ActiveBatchKey(second.parentTid, second.batchId);
		registry.activeBatches[secondKey].childTids[0] = 11;
		registry.activeBatches[secondKey].slotByChildTid.remove(22);
		registry.activeBatches[secondKey].slotByChildTid[11] = 0;
		registry.batchKeyByChildTid.remove(22);

		BatchHandle owner;
		size_t slot;
		assertThrown!AssertError(registry.findOwnerOfChild(11, owner, slot));
	}
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);
	auto key = ActiveBatchKey(handle.parentTid, handle.batchId);
	registry.batchKeyByChildTid.remove(11);

	assertThrown!AssertError(registry.consume(handle,
		BatchSignal.childDone(handle.batchId, 0, 11, McpResult("done", false)),
		(int childTid, int qid) => false, error));
	auto batch = key in registry.activeBatches;
	assert(batch !is null);
	assert((*batch).results[0].text.length == 0);
	assert(!(*batch).done[0]);
	assert((*batch).completed == 0);
	assert((11 in registry.batchKeyByChildTid) is null);
}

unittest
{
	BatchRegistry registry;
	BatchHandle oldHandle;
	BatchHandle laterHandle;
	string error;
	assert(registry.create(100, [11, 22], oldHandle, error), error);
	assert(registry.consume(oldHandle,
		BatchSignal.childDone(oldHandle.batchId, 0, 11,
			McpResult("old first", false)),
		(int childTid, int qid) => false, error).kind == BatchConsumeKind.childDone);
	assert(error.length == 0);

	assert(registry.create(100, [11], laterHandle, error), error);
	int childTid;
	assert(registry.findFirstLiveChild(100, (int cTid) => cTid == 11,
		childTid));
	assert(childTid == 11);

	assert(registry.consume(oldHandle,
		BatchSignal.childDone(oldHandle.batchId, 1, 22,
			McpResult("old second", false)),
		(int childTid, int qid) => false, error).kind == BatchConsumeKind.childDone);
	assert(error.length == 0);
	McpResult[] results;
	assert(registry.finalize(oldHandle, results, error), error);
	assert(results.length == 2);

	BatchHandle owner;
	size_t slot;
	assert(registry.findOwnerOfChild(11, owner, slot));
	assert(owner.parentTid == laterHandle.parentTid
		&& owner.batchId == laterHandle.batchId && slot == 0);
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);
	assert(registry.consume(handle,
		BatchSignal.childDone(handle.batchId, 0, 11, McpResult("done", false)),
		(int childTid, int qid) => false, error).kind == BatchConsumeKind.childDone);
	assert(error.length == 0);
	registry.batchIdsByParentTid.remove(100);

	McpResult[] results;
	assertThrown!AssertError(registry.finalize(handle, results, error));
	assert(registry.exists(handle));
	assert(registry.activeBatches.length == 1);
}

unittest
{
	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);

	McpResult[] results;
	assert(!registry.finalize(handle, results, error));
	assert(error.length > 0);
	assert(results is null);
	assert(registry.exists(handle));
	auto batch = ActiveBatchKey(handle.parentTid, handle.batchId)
		in registry.activeBatches;
	assert(batch !is null);
	assert(!(*batch).done[0]);
	assert((*batch).completed == 0);
	assert((11 in registry.batchKeyByChildTid) !is null);
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	BatchRegistry registry;
	BatchHandle handle;
	string error;
	assert(registry.create(100, [11], handle, error), error);
	assert(registry.consume(handle,
		BatchSignal.childDone(handle.batchId, 0, 11, McpResult("done", false)),
		(int childTid, int qid) => false, error).kind == BatchConsumeKind.childDone);
	assert(error.length == 0);
	auto key = ActiveBatchKey(handle.parentTid, handle.batchId);
	registry.batchKeyByChildTid[11] = key;

	McpResult[] results;
	assertThrown!AssertError(registry.finalize(handle, results, error));
	assert(registry.exists(handle));
	assert(registry.activeBatches.length == 1);
	assert((11 in registry.batchKeyByChildTid) !is null);
}
