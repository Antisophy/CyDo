import { beforeEach, describe, expect, it } from "vitest";
import { outbox } from "./outbox";

const entries = new Map<string, string>();

Object.defineProperty(globalThis, "localStorage", {
  value: {
    getItem: (key: string) => entries.get(key) ?? null,
    setItem: (key: string, value: string) => entries.set(key, value),
  },
});

describe("outbox task reload", () => {
  beforeEach(() => {
    entries.clear();
  });

  it("clears submitted entries for the reloaded task without affecting another task", () => {
    outbox.add({
      tid: 1,
      nonce: "submitted",
      content: "removed",
      createdAt: 1,
    });
    outbox.add({ tid: 2, nonce: "other", content: "draft", createdAt: 2 });

    outbox.removeForTask(1);

    expect(outbox.byTid(1)).toEqual([]);
    expect(outbox.byTid(2)).toEqual([
      { tid: 2, nonce: "other", content: "draft", createdAt: 2 },
    ]);
  });
});
