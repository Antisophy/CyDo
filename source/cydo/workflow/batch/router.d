module cydo.workflow.batch.router;

import std.format : format;

import ae.utils.promise : PromiseQueue;

import cydo.mcp : McpResult;
import cydo.domain.tasks.model : BatchSignal;

package(cydo):

struct BatchState
{
	ulong batchId;
	McpResult[] results;
	bool[] done;
	size_t completed;
	size_t totalChildren;
	int[] childTids;            // ordered child tids
	size_t[int] slotByChildTid; // child tid -> slot in childTids/results
	PromiseQueue!BatchSignal eventQueue;

	bool trySlotForChild(int childTid, out size_t slot) const
	{
		auto slotPtr = childTid in slotByChildTid;
		if (slotPtr is null)
			return false;
		slot = *slotPtr;
		return true;
	}
}

enum BatchConsumeKind { ignored, childDone, question }

struct BatchConsumeResult
{
	BatchConsumeKind kind = BatchConsumeKind.ignored;
	int childTid;
	int qid;
	string questionText;
}

BatchState buildBatchState(ulong batchId, int[] childTids, out string error)
{
	BatchState batch;
	batch.batchId = batchId;
	batch.totalChildren = childTids.length;
	batch.results = new McpResult[childTids.length];
	batch.done = new bool[childTids.length];
	batch.childTids = childTids.dup;

	foreach (i, childTid; childTids)
	{
		if (childTid <= 0)
		{
			error = format!"invalid child tid in batch: %d"(childTid);
			return batch;
		}
		if (childTid in batch.slotByChildTid)
		{
			error = format!"duplicate child tid in batch: %d"(childTid);
			return batch;
		}
		batch.slotByChildTid[childTid] = i;
	}

	error = "";
	return batch;
}

/// Assert the intrinsic representation of one live batch.
///
/// Registry-wide ownership is deliberately not checked here: callers that
/// know the registry use its global invariant, while the pure signal consumer
/// still needs to reject a locally malformed BatchState before it writes a
/// result.
void assertBatchStateShape(in BatchState batch)
{
	auto childCount = batch.childTids.length;
	assert(batch.totalChildren == childCount,
		format!"batch child count mismatch: batch=%s total=%s childTids=%s"(
			batch.batchId, batch.totalChildren, childCount));
	assert(batch.results.length == childCount,
		format!"batch result-state length mismatch: batch=%s results=%s children=%s"(
			batch.batchId, batch.results.length, childCount));
	assert(batch.done.length == childCount,
		format!"batch completion-state length mismatch: batch=%s done=%s children=%s"(
			batch.batchId, batch.done.length, childCount));
	assert(batch.slotByChildTid.length == childCount,
		format!"batch slot-map length mismatch: batch=%s slots=%s children=%s"(
			batch.batchId, batch.slotByChildTid.length, childCount));

	size_t completed;
	foreach (i, childTid; batch.childTids)
	{
		assert(childTid > 0,
			format!"invalid live child tid: batch=%s child=%d slot=%s"(
				batch.batchId, childTid, i));
		auto slot = childTid in batch.slotByChildTid;
		assert(slot !is null,
			format!"batch child missing slot map: batch=%s child=%d slot=%s"(
				batch.batchId, childTid, i));
		assert(*slot == i,
			format!"batch child slot map mismatch: batch=%s child=%d ordered_slot=%s mapped_slot=%s"(
				batch.batchId, childTid, i, *slot));
		if (batch.done[i])
			completed++;
	}

	foreach (childTid, slot; batch.slotByChildTid)
	{
		assert(slot < childCount,
			format!"batch slot map out of range: batch=%s child=%d slot=%s child_count=%s"(
				batch.batchId, childTid, slot, childCount));
		assert(batch.childTids[slot] == childTid,
			format!"batch slot map ordered-child mismatch: batch=%s child=%d slot=%s ordered_child=%d"(
				batch.batchId, childTid, slot, batch.childTids[slot]));
	}

	assert(batch.completed == completed,
		format!"batch completed count mismatch: batch=%s completed=%s done_count=%s"(
			batch.batchId, batch.completed, completed));
}

BatchConsumeResult consumeBatchSignal(ref BatchState batch, BatchSignal sig,
	scope bool delegate(int childTid, int qid) hasPendingQuestion)
{
	BatchConsumeResult result;
	if (sig.batchId != batch.batchId)
		return result;
	assertBatchStateShape(batch);

	assert(sig.slot < batch.childTids.length,
		format!"slot %s out of range for child count %s"
			(sig.slot, batch.childTids.length));
	assert(batch.childTids[sig.slot] == sig.childTid,
		format!"slot %s expects child tid %d but got %d"
			(sig.slot, batch.childTids[sig.slot], sig.childTid));

	size_t mappedSlot;
	assert(batch.trySlotForChild(sig.childTid, mappedSlot),
		format!"child tid %d is missing from the reverse slot map"
			(sig.childTid));
	assert(mappedSlot == sig.slot,
		format!"child tid %d maps to slot %s, signal targeted slot %s"
			(sig.childTid, mappedSlot, sig.slot));

	if (sig.kind == BatchSignal.Kind.childDone)
	{
		if (batch.done[sig.slot])
			return result; // duplicate completion for finished slot
		batch.results[sig.slot] = sig.result;
		batch.done[sig.slot] = true;
		batch.completed++;
		result.kind = BatchConsumeKind.childDone;
		return result;
	}

	if (!hasPendingQuestion(sig.childTid, sig.qid))
		return result; // stale question

	result.kind = BatchConsumeKind.question;
	result.childTid = sig.childTid;
	result.qid = sig.qid;
	result.questionText = sig.questionText;
	return result;
}

string validateBatchCompletion(in BatchState batch)
{
	assertBatchStateShape(batch);
	if (batch.completed != batch.totalChildren)
		return format!"batch completed mismatch: completed=%s total=%s"(batch.completed, batch.totalChildren);
	foreach (i, d; batch.done)
		if (!d)
			return format!"batch slot %s unfinished"(i);
	return "";
}

unittest
{
	import core.exception : AssertError;
	import std.exception : assertThrown;

	void assertResultStateUnchanged(ref BatchState batch)
	{
		assert(batch.completed == 0);
		assert(batch.done == [false, false]);
		assert(batch.results[0].text.length == 0);
		assert(batch.results[1].text.length == 0);
	}

	{
		string error;
		auto batch = buildBatchState(10, [101, 202], error);
		assert(error.length == 0);
		auto foreignBatch = consumeBatchSignal(batch,
			BatchSignal.childDone(99, 0, 101,
				McpResult("foreign-batch", false)),
			(int childTid, int qid) => false);
		assert(foreignBatch.kind == BatchConsumeKind.ignored);
		assertResultStateUnchanged(batch);
	}

	{
		string error;
		auto batch = buildBatchState(10, [7, 8], error);
		assert(error.length == 0);
		assertThrown!AssertError(consumeBatchSignal(batch,
			BatchSignal.childDone(10, 2, 7,
				McpResult("out-of-range", false)),
			(int childTid, int qid) => false));
		assertResultStateUnchanged(batch);
	}

	{
		string error;
		auto batch = buildBatchState(10, [7, 8], error);
		assert(error.length == 0);
		assertThrown!AssertError(consumeBatchSignal(batch,
			BatchSignal.childDone(10, 1, 7,
				McpResult("wrong-child", false)),
			(int childTid, int qid) => false));
		assertResultStateUnchanged(batch);
	}

	{
		string error;
		auto batch = buildBatchState(10, [7, 8], error);
		assert(error.length == 0);
		batch.slotByChildTid[7] = 1;
		assertThrown!AssertError(consumeBatchSignal(batch,
			BatchSignal.childDone(10, 0, 7,
				McpResult("wrong-reverse-map", false)),
			(int childTid, int qid) => false));
		assertResultStateUnchanged(batch);
	}
}

unittest
{
	string err;
	auto batch = buildBatchState(11, [501], err);
	assert(err.length == 0);

	auto first = consumeBatchSignal(batch,
		BatchSignal.childDone(11, 0, 501, McpResult("first", false)),
		(int childTid, int qid) => false);
	assert(first.kind == BatchConsumeKind.childDone);
	assert(batch.completed == 1);
	assert(batch.results[0].text == "first");

	auto duplicate = consumeBatchSignal(batch,
		BatchSignal.childDone(11, 0, 501, McpResult("duplicate", false)),
		(int childTid, int qid) => false);
	assert(duplicate.kind == BatchConsumeKind.ignored);
	assert(batch.completed == 1);
	assert(batch.results[0].text == "first");
}

unittest
{
	string err;
	auto batch = buildBatchState(12, [1, 2, 3], err);
	assert(err.length == 0);

	consumeBatchSignal(batch, BatchSignal.childDone(12, 2, 3, McpResult("C", false)),
		(int childTid, int qid) => false);
	consumeBatchSignal(batch, BatchSignal.childDone(12, 0, 1, McpResult("A", false)),
		(int childTid, int qid) => false);
	consumeBatchSignal(batch, BatchSignal.childDone(12, 1, 2, McpResult("B", false)),
		(int childTid, int qid) => false);

	assert(batch.completed == 3);
	assert(batch.results[0].text == "A");
	assert(batch.results[1].text == "B");
	assert(batch.results[2].text == "C");
	assert(validateBatchCompletion(batch).length == 0);
}

unittest
{
	string err;
	auto batch = buildBatchState(13, [7, 8], err);
	assert(err.length == 0);

	auto doneA = consumeBatchSignal(batch,
		BatchSignal.childDone(13, 0, 7, McpResult("slot-a", false)),
		(int childTid, int qid) => childTid == 8 && qid == 42);
	assert(doneA.kind == BatchConsumeKind.childDone);
	assert(batch.completed == 1);

	auto staleQuestion = consumeBatchSignal(batch,
		BatchSignal.question(13, 1, 8, "stale", 41),
		(int childTid, int qid) => childTid == 8 && qid == 42);
	assert(staleQuestion.kind == BatchConsumeKind.ignored);
	assert(batch.completed == 1);
	assert(batch.done[0] && !batch.done[1]);

	auto question = consumeBatchSignal(batch,
		BatchSignal.question(13, 1, 8, "ready", 42),
		(int childTid, int qid) => childTid == 8 && qid == 42);
	assert(question.kind == BatchConsumeKind.question);
	assert(question.childTid == 8);
	assert(question.qid == 42);
	assert(question.questionText == "ready");
	assert(batch.completed == 1);
	assert(batch.done[0] && !batch.done[1]);

	auto doneB = consumeBatchSignal(batch,
		BatchSignal.childDone(13, 1, 8, McpResult("slot-b", false)),
		(int childTid, int qid) => false);
	assert(doneB.kind == BatchConsumeKind.childDone);
	assert(batch.completed == 2);
	assert(batch.results[0].text == "slot-a");
	assert(batch.results[1].text == "slot-b");
	assert(validateBatchCompletion(batch).length == 0);
}
