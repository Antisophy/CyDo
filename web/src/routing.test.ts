import { describe, expect, it } from "vitest";
import {
  buildProjectHref,
  buildScopedHref,
  decodeProjectSegment,
  encodeProjectName,
  taskPath,
} from "./routing";

describe("encodeProjectName", () => {
  it("replaces slashes with colons", () => {
    expect(encodeProjectName("a/b")).toBe("a:b");
  });
});

describe("decodeProjectSegment", () => {
  it("replaces colons with slashes", () => {
    expect(decodeProjectSegment("a:b")).toBe("a/b");
  });
});

describe("buildProjectHref", () => {
  it("builds a workspace/project href", () => {
    expect(buildProjectHref("ws", "a/b")).toBe("/ws/a:b");
  });
});

describe("taskPath", () => {
  it("builds a task href under the project", () => {
    expect(taskPath("ws", "a/b", 7)).toBe("/ws/a:b/task/7");
  });
});

describe("buildScopedHref", () => {
  it("returns the bare suffix when workspace/project are null", () => {
    expect(buildScopedHref(null, null, "/task/7")).toBe("/task/7");
  });

  it("scopes the suffix under the workspace/project href", () => {
    expect(buildScopedHref("ws", "p", "/archive")).toBe("/ws/p/archive");
  });
});
