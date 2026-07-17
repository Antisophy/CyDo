module cydo.workflow.history.operations;

import ae.utils.json : JSONOptional;
import cydo.protocol : HistoryBoundary, HistoryBoundaryKind;
import cydo.runtime.config : AgentDriver;

enum HistoryOperation { fork, undo }
enum HistoryOperationMechanism { none, jsonl, codex_native }

struct HistoryOperationKinds
{
	@JSONOptional HistoryOperationMechanism user;
	@JSONOptional HistoryOperationMechanism agent_turn;
}

struct HistoryOperations
{
	HistoryOperationKinds fork;
	HistoryOperationKinds undo;
}

HistoryOperations selectHistoryOperations(AgentDriver driver, bool alive,
	bool canRollbackThread)
{
	HistoryOperations result;
	auto native = alive && driver == AgentDriver.codex && canRollbackThread;
	result.fork.user = native ? HistoryOperationMechanism.codex_native : HistoryOperationMechanism.jsonl;
	result.fork.agent_turn = native ? HistoryOperationMechanism.codex_native : HistoryOperationMechanism.jsonl;
	result.undo.user = native
		? HistoryOperationMechanism.codex_native : HistoryOperationMechanism.jsonl;
	if (!native)
		result.undo.agent_turn = HistoryOperationMechanism.jsonl;
	return result;
}

bool allowsOperation(const HistoryBoundary boundary, const HistoryOperations operations,
	HistoryOperation operation)
{
	auto kinds = operation == HistoryOperation.fork ? operations.fork : operations.undo;
	return boundary.anchor.length > 0 && (boundary.kind == HistoryBoundaryKind.user
		? kinds.user != HistoryOperationMechanism.none
		: kinds.agent_turn != HistoryOperationMechanism.none);
}

bool allowsFileRevert(const HistoryBoundary boundary)
{
	return boundary.checkpoint_uuid.length > 0;
}

unittest
{
	import cydo.protocol : HistoryBoundary;
	auto offline = selectHistoryOperations(AgentDriver.codex, false, false);
	assert(offline.fork.user == HistoryOperationMechanism.jsonl);
	assert(offline.fork.agent_turn == HistoryOperationMechanism.jsonl);
	assert(offline.undo.user == HistoryOperationMechanism.jsonl);
	assert(offline.undo.agent_turn == HistoryOperationMechanism.jsonl);
	auto native = selectHistoryOperations(AgentDriver.codex, true, true);
	assert(native.fork.user == HistoryOperationMechanism.codex_native);
	assert(native.fork.agent_turn == HistoryOperationMechanism.codex_native);
	assert(native.undo.user == HistoryOperationMechanism.codex_native);
	assert(native.undo.agent_turn == HistoryOperationMechanism.none);
	auto boundary = HistoryBoundary("a", HistoryBoundaryKind.agent_turn, "");
	assert(allowsOperation(boundary, offline, HistoryOperation.undo));
	assert(!allowsOperation(boundary, native, HistoryOperation.undo));
	assert(!allowsFileRevert(boundary));
	boundary.checkpoint_uuid = "checkpoint";
	assert(allowsFileRevert(boundary));
}
