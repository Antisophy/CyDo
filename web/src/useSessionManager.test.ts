import { describe, expect, it, vi } from "vitest";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
  vi.stubGlobal("document", { querySelector: () => null });
});
import { revertFilesForUndo } from "./useSessionManager";

describe("undo confirmation request", () => {
  it("forwards file revert only for the selected checkpoint boundary", () => {
    expect(revertFilesForUndo(false, true)).toBe(false); // assistant boundary
    expect(revertFilesForUndo(false, true)).toBe(false); // checkpoint-less user
    expect(revertFilesForUndo(false, true)).toBe(false); // unsupported agent
    expect(revertFilesForUndo(true, true)).toBe(true);
  });
});
