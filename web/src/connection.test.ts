import { beforeEach, describe, expect, it, vi } from "vitest";
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

  emitMessage(data: string) {
    this.onmessage?.call(
      this as unknown as WebSocket,
      {
        data,
      } as MessageEvent,
    );
  }
}

describe("Connection client behavior", () => {
  beforeEach(() => {
    MockWebSocket.instances = [];
    Object.defineProperty(globalThis, "location", {
      value: { protocol: "http:", host: "localhost:3940" },
      configurable: true,
    });
    Object.defineProperty(globalThis, "WebSocket", {
      value: MockWebSocket as unknown as typeof WebSocket,
      configurable: true,
    });
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
