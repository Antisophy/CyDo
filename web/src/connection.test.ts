import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { Connection } from "./connection";

class MockWebSocket {
  static OPEN = 1;
  static instances: MockWebSocket[] = [];

  binaryType: BinaryType = "blob";
  readyState = MockWebSocket.OPEN;
  onopen: ((this: WebSocket, ev: Event) => unknown) | null = null;
  onclose: ((this: WebSocket, ev: CloseEvent) => unknown) | null = null;
  onerror: ((this: WebSocket, ev: Event) => unknown) | null = null;
  onmessage: ((this: WebSocket, ev: MessageEvent) => unknown) | null = null;
  readonly send = vi.fn();
  readonly close = vi.fn();

  constructor() {
    MockWebSocket.instances.push(this);
  }

  emitMessage(data: string | ArrayBuffer) {
    this.onmessage?.call(
      this as unknown as WebSocket,
      {
        data,
      } as MessageEvent,
    );
  }

  emitClose() {
    this.onclose?.call(this as unknown as WebSocket, {} as CloseEvent);
  }
}

class AnimationFrameController {
  private nextId = 0;
  private frames = new Map<
    number,
    { callback: FrameRequestCallback; cancelled: boolean }
  >();
  readonly cancelled: number[] = [];

  reset() {
    this.nextId = 0;
    this.frames.clear();
    this.cancelled.length = 0;
  }

  request = (callback: FrameRequestCallback) => {
    const id = ++this.nextId;
    this.frames.set(id, { callback, cancelled: false });
    return id;
  };

  cancel = (id: number) => {
    const frame = this.frames.get(id);
    if (!frame) return;
    frame.cancelled = true;
    this.cancelled.push(id);
  };

  pendingIds() {
    return [...this.frames]
      .filter(([, frame]) => !frame.cancelled)
      .map(([id]) => id);
  }

  runNext() {
    const id = this.pendingIds()[0];
    if (id === undefined) throw new Error("No animation frame is pending");
    this.run(id);
    return id;
  }

  run(id: number, allowCancelled = false) {
    const frame = this.frames.get(id);
    if (!frame) throw new Error(`Unknown animation frame ${id}`);
    this.frames.delete(id);
    if (!frame.cancelled || allowCancelled) frame.callback(0);
  }
}

const animationFrames = new AnimationFrameController();
const visibilityListeners = new Set<EventListener>();
let pageHidden = false;

function setPageHidden(hidden: boolean) {
  pageHidden = hidden;
}

function emitVisibilityChange() {
  for (const listener of [...visibilityListeners])
    listener({ type: "visibilitychange" } as Event);
}

function tasksList(complete: unknown, tasks: unknown = []) {
  return JSON.stringify({ type: "tasks_list", complete, tasks });
}

function taskEvent(tid: number) {
  return JSON.stringify({ tid, event: { type: "turn/stop" } });
}

describe("Connection client behavior", () => {
  beforeEach(() => {
    MockWebSocket.instances = [];
    animationFrames.reset();
    visibilityListeners.clear();
    pageHidden = false;
    vi.stubGlobal("location", { protocol: "http:", host: "localhost:3940" });
    vi.stubGlobal("WebSocket", MockWebSocket as unknown as typeof WebSocket);
    vi.stubGlobal("document", {
      get hidden() {
        return pageHidden;
      },
      addEventListener(type: string, listener: EventListener) {
        if (type === "visibilitychange") visibilityListeners.add(listener);
      },
      removeEventListener(type: string, listener: EventListener) {
        if (type === "visibilitychange") visibilityListeners.delete(listener);
      },
    });
    vi.stubGlobal("requestAnimationFrame", animationFrames.request);
    vi.stubGlobal("cancelAnimationFrame", animationFrames.cancel);
    vi.spyOn(console, "warn").mockImplementation(() => undefined);
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("reports invalid JSON payloads through onClientError", () => {
    const conn = new Connection();
    const errors: string[] = [];
    conn.onClientError = (message) => {
      errors.push(message);
    };

    conn.connect();
    const ws = MockWebSocket.instances[0]!;
    ws.emitMessage("{bad json");

    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("Failed to parse WebSocket message");
    expect(ws.close).not.toHaveBeenCalled();
  });

  it("reports task envelopes missing both event payload forms", () => {
    const conn = new Connection();
    const errors: string[] = [];
    conn.onClientError = (message) => {
      errors.push(message);
    };

    conn.connect();
    const ws = MockWebSocket.instances[0]!;
    ws.emitMessage(JSON.stringify({ tid: 7, seq: 1 }));

    expect(errors).toEqual([
      "Invalid task envelope for task 7: missing event payload",
    ]);
  });

  it("reports unknown top-level websocket messages", () => {
    const conn = new Connection();
    const errors: string[] = [];
    conn.onClientError = (message) => {
      errors.push(message);
    };

    conn.connect();
    const ws = MockWebSocket.instances[0]!;
    ws.emitMessage(JSON.stringify({ type: "future_protocol", payload: {} }));

    expect(errors).toEqual(["Unknown WebSocket message type: future_protocol"]);
  });

  it("routes agent_usage as a control message", () => {
    const conn = new Connection();
    const controls: string[] = [];
    conn.onControlMessage = (msg) => {
      controls.push(msg.type);
    };

    conn.connect();
    const ws = MockWebSocket.instances[0]!;
    ws.emitMessage(
      JSON.stringify({
        type: "agent_usage",
        agent: "claude",
        updated_at: 1715702400,
        limits: {
          five_hour: { utilization: 42.5, resetsAt: 1715703000 },
        },
      }),
    );

    expect(controls).toEqual(["agent_usage"]);
  });

  describe("incremental task-list gate", () => {
    it("dispatches a terminal first list immediately and drains later raw frames FIFO after two animation frames", () => {
      const conn = new Connection();
      const received: string[] = [];
      const parse = vi.spyOn(JSON, "parse");
      conn.onControlMessage = (message) => {
        received.push(
          message.type === "tasks_list"
            ? `tasks_list:${message.complete}`
            : message.type,
        );
      };
      conn.onTaskMessage = (tid) => received.push(`task:${tid}`);

      conn.connect();
      const ws = MockWebSocket.instances[0]!;
      ws.emitMessage(tasksList(true));

      expect(received).toEqual(["tasks_list:true"]);
      expect(parse).toHaveBeenCalledTimes(1);
      expect(animationFrames.pendingIds()).toHaveLength(1);

      ws.emitMessage(JSON.stringify({ type: "task_updated" }));
      ws.emitMessage(taskEvent(7));
      ws.emitMessage(JSON.stringify({ type: "title_update" }));

      expect(received).toEqual(["tasks_list:true"]);
      expect(parse).toHaveBeenCalledTimes(1);

      animationFrames.runNext();

      expect(received).toEqual(["tasks_list:true"]);
      expect(parse).toHaveBeenCalledTimes(1);
      expect(animationFrames.pendingIds()).toHaveLength(1);

      animationFrames.runNext();

      expect(received).toEqual([
        "tasks_list:true",
        "task_updated",
        "task:7",
        "title_update",
      ]);
      expect(parse).toHaveBeenCalledTimes(4);
      expect(animationFrames.pendingIds()).toEqual([]);
    });

    it.each([
      ["a non-boolean complete flag", "false", []],
      ["a non-array tasks payload", false, {}],
    ])("reports %s as a client error", (_description, complete, tasks) => {
      const conn = new Connection();
      const errors: string[] = [];
      const controls = vi.fn();
      conn.onClientError = (message) => errors.push(message);
      conn.onControlMessage = controls;

      conn.connect();
      MockWebSocket.instances[0]!.emitMessage(tasksList(complete, tasks));

      expect(controls).not.toHaveBeenCalled();
      expect(errors).toHaveLength(1);
      expect(errors[0]).toContain("Failed to parse WebSocket message");
      expect(animationFrames.pendingIds()).toEqual([]);
    });

    it("does not pause when the first task list arrives while hidden", () => {
      setPageHidden(true);
      const conn = new Connection();
      const received: string[] = [];
      conn.onControlMessage = (message) => received.push(message.type);
      conn.onTaskMessage = (tid) => received.push(`task:${tid}`);

      conn.connect();
      const ws = MockWebSocket.instances[0]!;
      ws.emitMessage(tasksList(false));
      ws.emitMessage(taskEvent(3));

      expect(received).toEqual(["tasks_list", "task:3"]);
      expect(animationFrames.pendingIds()).toEqual([]);
    });

    it("cancels the gate and drains queued frames when the page becomes hidden", () => {
      const conn = new Connection();
      const received: string[] = [];
      conn.onControlMessage = (message) => received.push(message.type);
      conn.onTaskMessage = (tid) => received.push(`task:${tid}`);

      conn.connect();
      const ws = MockWebSocket.instances[0]!;
      ws.emitMessage(tasksList(false));
      const firstFrame = animationFrames.pendingIds()[0]!;
      ws.emitMessage(taskEvent(3));

      setPageHidden(true);
      emitVisibilityChange();

      expect(received).toEqual(["tasks_list", "task:3"]);
      expect(animationFrames.cancelled).toContain(firstFrame);
      expect(animationFrames.pendingIds()).toEqual([]);

      animationFrames.run(firstFrame, true);
      expect(received).toEqual(["tasks_list", "task:3"]);
    });

    it("cleans up the gate when first-list dispatch throws", () => {
      const conn = new Connection();
      const errors: string[] = [];
      const taskMessages = vi.fn();
      conn.onControlMessage = () => {
        throw new Error("render failed");
      };
      conn.onClientError = (message) => errors.push(message);
      conn.onTaskMessage = taskMessages;

      conn.connect();
      const ws = MockWebSocket.instances[0]!;
      ws.emitMessage(tasksList(false));

      expect(errors).toHaveLength(1);
      expect(animationFrames.cancelled).toHaveLength(1);
      expect(animationFrames.pendingIds()).toEqual([]);

      ws.emitMessage(taskEvent(9));
      expect(taskMessages).toHaveBeenCalledOnce();
      expect(taskMessages.mock.calls[0]?.slice(0, 2)).toEqual([
        9,
        { type: "turn/stop" },
      ]);
    });

    it("drops queued frames and stale release callbacks after close and reconnect", () => {
      vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
      const conn = new Connection();
      const received: string[] = [];
      conn.onControlMessage = (message) => {
        received.push(
          message.type === "tasks_list"
            ? `tasks_list:${message.complete}`
            : message.type,
        );
      };
      conn.onTaskMessage = (tid) => received.push(`task:${tid}`);

      conn.connect();
      const firstSocket = MockWebSocket.instances[0]!;
      firstSocket.emitMessage(tasksList(false));
      animationFrames.runNext();
      const staleRelease = animationFrames.pendingIds()[0]!;
      firstSocket.emitMessage(taskEvent(1));
      firstSocket.emitClose();

      expect(animationFrames.cancelled).toContain(staleRelease);

      vi.advanceTimersByTime(2_000);
      const secondSocket = MockWebSocket.instances[1]!;
      animationFrames.run(staleRelease, true);
      firstSocket.emitMessage(taskEvent(2));

      expect(received).toEqual(["tasks_list:false"]);

      secondSocket.emitMessage(tasksList(true));
      expect(received).toEqual(["tasks_list:false", "tasks_list:true"]);
    });
  });

  it("rejects malformed history operation policies", () => {
    const conn = new Connection();
    const errors: string[] = [];
    conn.onClientError = (message) => errors.push(message);
    conn.connect();
    MockWebSocket.instances[0]!.emitMessage(
      JSON.stringify({
        type: "history_operations",
        tid: 1,
        history_operations: {
          fork: { user: "unknown" },
          undo: { user: "jsonl" },
        },
      }),
    );
    expect(errors).toHaveLength(1);
    expect(errors[0]).toContain("Failed to parse WebSocket message");
  });

  it("routes replacements separately from ordinary task events", () => {
    const conn = new Connection();
    const ordinary = vi.fn();
    const replacement = vi.fn();
    conn.onTaskMessage = ordinary;
    conn.onHistoryBoundaryReplaced = replacement;
    conn.connect();
    MockWebSocket.instances[0]!.emitMessage(
      JSON.stringify({
        type: "task_history_boundary_replaced",
        tid: 7,
        seq: 4,
        ts: 9,
        event: {
          type: "turn/stop",
          history_boundary: { anchor: "a", kind: "agent_turn" },
        },
      }),
    );
    expect(replacement).toHaveBeenCalledOnce();
    expect(ordinary).not.toHaveBeenCalled();
  });
  it("sends task promotion with its target workspace", () => {
    const conn = new Connection();
    conn.connect();

    const ws = MockWebSocket.instances[0]!;
    conn.promoteTask(7, "destination");

    expect(ws.send).toHaveBeenCalledWith(
      JSON.stringify({
        type: "promote_task",
        tid: 7,
        workspace: "destination",
      }),
    );
  });

  describe("undo request serialization", () => {
    function lastSentJson(ws: MockWebSocket): Record<string, unknown> {
      const call = ws.send.mock.calls.at(-1);
      expect(call).toBeDefined();
      return JSON.parse(call![0] as string) as Record<string, unknown>;
    }

    it("omits the expected turn count from preview requests", () => {
      const conn = new Connection();
      conn.connect();
      const ws = MockWebSocket.instances[0]!;

      conn.undoTask(7, "boundary-7", true, false, false);

      const request = lastSentJson(ws);
      expect(request).toMatchObject({
        type: "undo_task",
        tid: 7,
        after_uuid: "boundary-7",
        dry_run: true,
      });
      expect(request).not.toHaveProperty("expected_num_turns");
    });

    it("serializes the expected native turn count for a confirmation", () => {
      const conn = new Connection();
      conn.connect();
      const ws = MockWebSocket.instances[0]!;

      conn.undoTask(7, "boundary-7", false, true, false, 3);

      expect(lastSentJson(ws)).toMatchObject({
        type: "undo_task",
        tid: 7,
        after_uuid: "boundary-7",
        dry_run: false,
        expected_num_turns: 3,
      });
    });

    it("omits the expected turn count for history-entry confirmations", () => {
      const conn = new Connection();
      conn.connect();
      const ws = MockWebSocket.instances[0]!;

      conn.undoTask(7, "boundary-7", false, true, false, undefined);

      expect(lastSentJson(ws)).not.toHaveProperty("expected_num_turns");
    });
  });
});
