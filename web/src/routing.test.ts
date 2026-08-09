import { describe, expect, it } from "vitest";
import {
  buildProjectHref,
  buildScopedHref,
  canonicalTaskRedirect,
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

describe("canonicalTaskRedirect", () => {
  it("returns null when the URL is already canonical", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "proj",
        urlWorkspace: "ws",
        urlProject: "proj",
      }),
    ).toBeNull();
  });

  it("redirects a legacy /task/<tid> URL to the canonical path", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "proj",
        urlWorkspace: null,
        urlProject: null,
      }),
    ).toBe("/ws/proj/task/7");
  });

  it("redirects a URL naming the wrong scope to the correct path", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "proj",
        urlWorkspace: "bogus-ws",
        urlProject: "bogus-proj",
      }),
    ).toBe("/ws/proj/task/7");
  });

  it("returns null when the task's workspace cannot be resolved", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: null,
        taskProject: "proj",
        urlWorkspace: "ws",
        urlProject: "proj",
      }),
    ).toBeNull();
  });

  it("returns null when the task's project cannot be resolved", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: null,
        urlWorkspace: "ws",
        urlProject: "proj",
      }),
    ).toBeNull();
  });

  it("returns null for a project name containing '/' whose URL segment is already decoded", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "a/b",
        urlWorkspace: "ws",
        urlProject: "a/b",
      }),
    ).toBeNull();
  });

  it("is a fixed point for a project name containing ':' (loop guard)", () => {
    expect(
      canonicalTaskRedirect({
        tid: 7,
        taskWorkspace: "ws",
        taskProject: "a:b",
        urlWorkspace: "ws",
        urlProject: "a/b",
      }),
    ).toBeNull();
  });
});
