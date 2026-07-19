import { describe, expect, it, vi } from "vitest";
import { makeTaskState, type TaskState } from "./types";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("document", { querySelector: () => null });
});
import { receiveServerError, revertFilesForUndo } from "./useSessionManager";

describe("undo confirmation request", () => {
  it("forwards file revert only for the selected checkpoint boundary", () => {
    expect(revertFilesForUndo(false, true)).toBe(false); // assistant boundary
    expect(revertFilesForUndo(false, true)).toBe(false); // checkpoint-less user
    expect(revertFilesForUndo(false, true)).toBe(false); // unsupported agent
    expect(revertFilesForUndo(true, true)).toBe(true);
  });
});

function task(tid: number, undoPending = false): TaskState {
  return {
    ...makeTaskState(tid, true),
    uuid: `task-${tid}`,
    undoPending: undoPending
      ? {
          afterUuid: `message-${tid}`,
          messagesRemoved: 2,
          canRevertFiles: false,
          retainsPrompt: false,
        }
      : undefined,
  };
}

describe("receiveServerError", () => {
  it("returns the received error fields without changing tasks without a tid", () => {
    const tasks = new Map([["task-1", task(1, true)]]);

    const result = receiveServerError(tasks, "Command failed");

    expect(result.serverError).toEqual({ message: "Command failed" });
    expect(result.tasks).toBe(tasks);
  });

  it("clears undo pending only for the task named by the error", () => {
    const matching = task(1, true);
    const other = task(2, true);
    const tasks = new Map([
      [matching.uuid, matching],
      [other.uuid, other],
    ]);

    const result = receiveServerError(tasks, "Undo failed", 1);

    expect(result.serverError).toEqual({ message: "Undo failed", tid: 1 });
    expect(result.tasks).not.toBe(tasks);
    expect(result.tasks.get(matching.uuid)).toMatchObject({
      undoPending: null,
    });
    expect(result.tasks.get(other.uuid)).toBe(other);
    expect(other.undoPending).toEqual({
      afterUuid: "message-2",
      messagesRemoved: 2,
      canRevertFiles: false,
      retainsPrompt: false,
    });
  });

  it("preserves undo pending when the error names another task", () => {
    const pending = task(1, true);
    const tasks = new Map([[pending.uuid, pending]]);

    const result = receiveServerError(tasks, "Other task failed", 2);

    expect(result.serverError).toEqual({
      message: "Other task failed",
      tid: 2,
    });
    expect(result.tasks).toBe(tasks);
    expect(pending.undoPending).toEqual({
      afterUuid: "message-1",
      messagesRemoved: 2,
      canRevertFiles: false,
      retainsPrompt: false,
    });
  });
});
