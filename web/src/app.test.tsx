import {
  h,
  options,
  toChildArray,
  type ComponentChildren,
  type VNode,
} from "preact";
import renderToString from "preact-render-to-string";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { TaskManager } from "./useSessionManager";

const state = vi.hoisted(() => ({
  serverError: null as TaskManager["serverError"],
  dismissServerError: vi.fn(),
}));

vi.hoisted(() => {
  Object.defineProperty(globalThis, "CSS", {
    value: { supports: () => false },
    configurable: true,
  });
});

vi.mock("./useSessionManager", () => ({
  useTaskManager: () =>
    ({
      tasks: new Map(),
      activeTaskId: null,
      activeTaskIdRef: { current: null },
      setActiveTaskId: vi.fn(),
      connected: true,
      send: vi.fn(),
      interrupt: vi.fn(),
      stop: vi.fn(),
      closeStdin: vi.fn(),
      resume: vi.fn(),
      promote: vi.fn(),
      fork: vi.fn(),
      undoPreview: vi.fn(),
      undoConfirm: vi.fn(),
      undoDismiss: vi.fn(),
      dismissAttention: vi.fn(),
      clearInputDraft: vi.fn(),
      setArchived: vi.fn(),
      saveDraft: vi.fn(),
      setEntryPoint: vi.fn(),
      setAgentName: vi.fn(),
      sendAskUserResponse: vi.fn(),
      sendPermissionPromptResponse: vi.fn(),
      editMessage: vi.fn(),
      editRawEvent: vi.fn(),
      createDraftTask: vi.fn(),
      deleteDraftTask: vi.fn(),
      draftRenderKey: null,
      sidebarTasks: [],
      workspaces: [],
      entryPoints: [],
      typeInfo: [],
      agents: [],
      defaultAgent: "",
      defaultTaskType: "",
      activeWorkspace: null,
      activeProject: null,
      notices: {},
      localNotices: {},
      agentUsage: {},
      serverError: state.serverError,
      dismissServerError: state.dismissServerError,
      devMode: false,
      navigateHome: vi.fn(),
      navigateToProject: vi.fn(),
      getProjectHref: vi.fn(),
      getTaskHref: vi.fn(),
      getByTid: vi.fn(),
      refreshWorkspaces: vi.fn(),
      scanState: "idle",
    }) as unknown as TaskManager,
}));

vi.mock("preact-iso", () => ({
  Router: ({ children }: { children: ComponentChildren }) => {
    const firstRoute = toChildArray(children)[0] as VNode<{
      component: () => VNode;
    }>;
    return h(firstRoute.props.component, {});
  },
  Route: () => null,
}));

vi.mock("./useTheme", () => ({
  ThemeContext: {
    Provider: ({ children }: { children: ComponentChildren }) => children,
  },
  useTheme: () => ({ theme: "dark", toggleTheme: vi.fn() }),
}));

vi.mock("./useToast", () => ({
  useToast: () => ({
    toasts: [],
    addToast: vi.fn(),
    dismissToast: vi.fn(),
    clearToasts: vi.fn(),
  }),
}));

vi.mock("./useNotifications", () => ({
  useNotifications: () => new Set(),
}));

vi.mock("./useErrorOverlay", () => ({
  useErrorCapture: () => {},
}));

import { App } from "./app";

describe("server command errors", () => {
  beforeEach(() => {
    state.serverError = null;
    state.dismissServerError.mockReset();
  });

  it("renders the server error dialog and dismisses it", () => {
    state.serverError = { message: "Undo target is no longer valid", tid: 7 };

    let dismiss: (() => void) | undefined;
    const previousVNode = options.vnode?.bind(options);
    options.vnode = (vnode: VNode) => {
      previousVNode?.(vnode);
      if (vnode.type === "button" && vnode.props.children === "Dismiss") {
        dismiss = (vnode.props as unknown as { onClick: () => void }).onClick;
      }
    };
    try {
      const html = renderToString(h(App, {}));
      expect(html).toContain("Command failed");
      expect(html).toContain("Undo target is no longer valid");
      expect(dismiss).toBe(state.dismissServerError);

      dismiss?.();
      expect(state.dismissServerError).toHaveBeenCalledOnce();
    } finally {
      options.vnode = previousVNode;
    }
  });

  it("hides the dialog after its error state is cleared", () => {
    state.serverError = { message: "Undo failed" };
    expect(renderToString(h(App, {}))).toContain("Command failed");

    state.serverError = null;
    expect(renderToString(h(App, {}))).not.toContain("Command failed");
  });
});
