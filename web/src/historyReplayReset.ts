import type { TaskState } from "./types";
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

type TaskResetLifecycle = Pick<
  TaskState,
  | "alive"
  | "isProcessing"
  | "stdinClosed"
  | "canStop"
  | "needsAttention"
  | "hasPendingQuestion"
>;

function resetTaskTimeline(
  task: TaskState,
  lifecycle: TaskResetLifecycle,
): TaskState {
  return {
    ...task,
    messages: [],
    replacementEvents: new Map(),
    sessionInfo: null,
    sessionStatus: null,
    totalCost: 0,
    msgIdCounter: 0,
    historyLoaded: false,
    historyTotal: undefined,
    historyReceived: undefined,
    inputDraft: undefined,
    historyOperations: null,
    error: undefined,
    undoPending: undefined,
    suggestions: undefined,
    serverDraft: undefined,
    pendingAskUser: undefined,
    pendingPermission: undefined,
    trackedFiles: new Map(),
    blocks: new Map(),
    itemIdMap: new Map(),
    pendingCydoTaskItemIds: [],
    spawnedTidsByItemId: new Map(),
    ...lifecycle,
  };
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

  const reset = resetTaskTimeline(task, {
    alive: task.alive,
    isProcessing: task.isProcessing,
    stdinClosed: task.stdinClosed,
    canStop: task.canStop,
    needsAttention: task.needsAttention,
    hasPendingQuestion: task.hasPendingQuestion,
  });

  return {
    ...reset,
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

export function resetTaskForReload(
  task: TaskState,
  preReloadDrafts: string[] | undefined,
): TaskState {
  return {
    ...resetTaskTimeline(task, {
      alive: false,
      isProcessing: false,
      stdinClosed: false,
      canStop: false,
      needsAttention: false,
      hasPendingQuestion: false,
    }),
    preReloadDrafts,
  };
}

/**
 * A task_reload has already reset the old lineage before it asks for history.
 * Keep live events received between that reset and task_history_start: the
 * replay response is a snapshot and cannot contain those newer events.
 */
export function beginTaskHistoryReplay(
  task: TaskState,
  total: number,
): TaskState {
  if (task.pendingHistoryReplies === 0)
    return resetTaskForHistoryReplay(task, total);

  return {
    ...task,
    historyLoaded: false,
    historyTotal: total,
    historyReceived: 0,
  };
}
