import { makeTaskState, type TaskState } from "./types";
import { canonicalUserTextFromDisplayMessage } from "./userText";

export function snapshotUserDrafts(task: TaskState): string[] | undefined {
  const drafts = task.messages
    .filter((message) => message.type === "user")
    .map((message) => canonicalUserTextFromDisplayMessage(message))
    .filter((text) => text.length > 0);
  return drafts.length > 0 ? drafts : undefined;
}

export function reconcileInputDraft(task: TaskState): string | undefined {
  if (!task.preReloadDrafts || task.preReloadDrafts.length === 0) {
    return undefined;
  }

  const finalCounts = new Map<string, number>();
  for (const message of task.messages) {
    if (message.type !== "user") continue;
    const text = canonicalUserTextFromDisplayMessage(message);
    if (text.length === 0) continue;
    finalCounts.set(text, (finalCounts.get(text) ?? 0) + 1);
  }
  const remaining: string[] = [];
  for (const text of task.preReloadDrafts) {
    const count = finalCounts.get(text) ?? 0;
    if (count > 0) finalCounts.set(text, count - 1);
    else remaining.push(text);
  }
  return remaining.length > 0 ? remaining.join("\n\n") : undefined;
}

/**
 * task_history_start marks the beginning of a full replay bundle for one task.
 * The replay must rebuild timeline state from scratch so repeated bundles do
 * not duplicate transcript messages, blocks, or tracked artifacts.
 */
export function resetTaskForHistoryReplay(
  task: TaskState,
  total: number,
): TaskState {
  const pendingUserMessages = task.messages.filter(
    (message) =>
      message.type === "user" && message.ackState === 4 && message.nonce,
  );

  const reset = makeTaskState(
    task.tid,
    task.alive,
    task.resumable,
    task.title,
    false,
    task.workspace,
    task.projectPath,
    task.parentTid,
    task.relationType,
    task.status,
    task.isProcessing,
    task.stdinClosed,
    task.needsAttention,
    task.hasPendingQuestion,
    task.taskType,
    task.archived || false,
    task.createdAt,
    task.lastActive,
    task.agentType,
    task.entryPoint,
    task.archiving || false,
    task.canStop,
  );

  return {
    ...reset,
    uuid: task.uuid,
    everLoaded: task.everLoaded,
    messages: pendingUserMessages,
    msgIdCounter: Math.max(reset.msgIdCounter, task.msgIdCounter),
    historyTotal: total,
    historyReceived: 0,
    pendingHistoryReplies: task.pendingHistoryReplies,
    preReloadDrafts: task.preReloadDrafts,
    inputDraft: task.inputDraft,
    error: task.error,
    undoPending: task.undoPending,
    undoResult: task.undoResult,
    suggestions: task.suggestions,
    serverDraft: task.serverDraft,
    pendingAskUser: task.pendingAskUser,
    pendingPermission: task.pendingPermission,
  };
}
