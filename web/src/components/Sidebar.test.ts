import { describe, expect, it } from "vitest";
import {
  buildTree,
  flattenTree,
  shouldHandleSidebarAltArchive,
  type SidebarTask,
} from "./Sidebar";

describe("Sidebar archive click guard", () => {
  it("allows Alt-click archive when task is not archiving", () => {
    expect(shouldHandleSidebarAltArchive(true, true, false)).toBe(true);
  });

  it("blocks Alt-click archive while task is archiving", () => {
    expect(shouldHandleSidebarAltArchive(true, true, true)).toBe(false);
  });

  it("blocks non-Alt clicks and missing handlers", () => {
    expect(shouldHandleSidebarAltArchive(false, true, false)).toBe(false);
    expect(shouldHandleSidebarAltArchive(true, false, false)).toBe(false);
  });
});

function task(tid: number, extra: Partial<SidebarTask> = {}): SidebarTask {
  return {
    tid,
    alive: false,
    canStop: false,
    resumable: false,
    isProcessing: false,
    childCount: 0,
    ...extra,
  };
}

function items(tasks: SidebarTask[], activeTaskId: string | null) {
  return flattenTree(buildTree(tasks), activeTaskId, []);
}

describe("Sidebar subtask collapsing", () => {
  const done = { status: "completed" };
  const parentWithTwoDone = [
    task(1),
    task(2, { parentTid: 1, ...done }),
    task(3, { parentTid: 1, ...done }),
  ];

  it("collapses stopped subtasks into a summary row when parent is not selected", () => {
    const flat = items(parentWithTwoDone, null);
    expect(flat.map((i) => i.id)).toEqual(["1", "subtasks:1"]);
    const summary = flat[1]!;
    expect(summary.title).toBe("(2 subtasks)");
    expect(summary.selectId).toBe("1");
    expect(summary.attentionTids).toEqual([2, 3]);
    expect(summary.iconName).toBe("subtasks");
    expect(summary.statusClass).toBe("completed");
  });

  it("counts failed subtasks as stopped, graying the mixed-status icon", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, status: "failed" }),
      task(3, { parentTid: 1, ...done }),
    ];
    const flat = items(tasks, null);
    expect(flat.map((i) => i.id)).toEqual(["1", "subtasks:1"]);
    expect(flat[1]!.statusClass).toBe("");
  });

  it("counts never-started (pending) subtasks as collapsible", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, status: "pending" }),
      task(3, { parentTid: 1, ...done }),
    ];
    expect(items(tasks, null).map((i) => i.id)).toEqual(["1", "subtasks:1"]);
  });

  it("colors the summary icon by the shared status of hidden subtasks", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, status: "failed" }),
      task(3, { parentTid: 1, status: "failed" }),
    ];
    expect(items(tasks, null)[1]!.statusClass).toBe("failed");
  });

  it("expands subtasks when the parent is selected", () => {
    expect(items(parentWithTwoDone, "1").map((i) => i.id)).toEqual([
      "1",
      "2",
      "3",
    ]);
  });

  it("expands when the selection is inside the collapsed run", () => {
    expect(items(parentWithTwoDone, "3").map((i) => i.id)).toEqual([
      "1",
      "2",
      "3",
    ]);
  });

  it("does not collapse an only stopped subtask", () => {
    const tasks = [task(1), task(2, { parentTid: 1, ...done })];
    expect(items(tasks, null).map((i) => i.id)).toEqual(["1", "2"]);
  });

  it("collapses only the leading stopped run, keeping running children visible", () => {
    const tasks = [
      ...parentWithTwoDone,
      task(4, { parentTid: 1, alive: true }),
      task(5, { parentTid: 1, ...done }),
    ];
    expect(items(tasks, null).map((i) => i.id)).toEqual([
      "1",
      "subtasks:1",
      "4",
      "5",
    ]);
  });

  it("keeps the stopped run collapsed while a running sibling is selected", () => {
    const tasks = [
      ...parentWithTwoDone,
      task(4, { parentTid: 1, alive: true }),
    ];
    expect(items(tasks, "4").map((i) => i.id)).toEqual([
      "1",
      "subtasks:1",
      "4",
    ]);
  });

  it("does not collapse a run interrupted by a running first child", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, alive: true }),
      task(3, { parentTid: 1, ...done }),
      task(4, { parentTid: 1, ...done }),
    ];
    expect(items(tasks, null).map((i) => i.id)).toEqual(["1", "2", "3", "4"]);
  });

  it("treats a subtree with a running descendant as not stopped", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, ...done }),
      task(3, { parentTid: 1, ...done }),
      task(4, { parentTid: 3, alive: true }),
    ];
    expect(items(tasks, null).map((i) => i.id)).toEqual(["1", "2", "3", "4"]);
  });

  it("collapses stopped runs recursively, including under a selected parent's children", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, ...done }),
      task(3, { parentTid: 1, alive: true }),
      task(4, { parentTid: 3, ...done }),
      task(5, { parentTid: 3, ...done }),
    ];
    expect(items(tasks, "1").map((i) => i.id)).toEqual([
      "1",
      "2",
      "3",
      "subtasks:3",
    ]);
  });

  it("treats archived children as stopped and excludes them from the count", () => {
    const tasks = [
      task(1),
      task(2, { parentTid: 1, ...done }),
      task(3, { parentTid: 1, ...done }),
      task(4, { parentTid: 1, resumable: true, archived: true }),
    ];
    const flat = items(tasks, null);
    expect(flat.map((i) => i.id)).toEqual(["1", "subtasks:1"]);
    const summary = flat[1]!;
    expect(summary.title).toBe("(2 subtasks)");
    expect(summary.attentionTids).toEqual([4, 2, 3]);
    // The archived resumable task does not dilute the status vote.
    expect(summary.statusClass).toBe("completed");
  });
});
