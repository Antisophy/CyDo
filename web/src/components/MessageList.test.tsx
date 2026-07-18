import { describe, expect, it } from "vitest";
import renderToString from "preact-render-to-string";
import { MessageList } from "./MessageList";
import { DevModeContext } from "../devMode";
import type { DisplayMessage } from "../types";

describe("MessageList parse-error rendering", () => {
  it("shows parse_error system messages in normal mode", () => {
    const parseError: DisplayMessage = {
      id: "msg-1",
      type: "system",
      subtype: "parse_error",
      content: [
        {
          type: "text",
          text: 'Unknown message type: future_protocol\n{"type":"future_protocol"}',
        },
      ],
    };

    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[parseError]}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );

    expect(html).toContain("Unknown message type: future_protocol");
    expect(html).toContain("<summary>Details</summary>");
  });

  it("hides unknown system subtype parse errors outside dev mode", () => {
    const parseError: DisplayMessage = {
      id: "msg-1",
      type: "system",
      subtype: "parse_error",
      content: [
        {
          type: "text",
          text: 'Unknown system subtype: thinking_tokens\n{"type":"system","subtype":"thinking_tokens"}',
        },
      ],
    };

    const normalHtml = renderToString(
      <DevModeContext.Provider value={false}>
        <MessageList
          taskTid={1}
          messages={[parseError]}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );
    const devHtml = renderToString(
      <DevModeContext.Provider value={true}>
        <MessageList
          taskTid={1}
          messages={[parseError]}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );

    expect(normalHtml).not.toContain("Unknown system subtype: thinking_tokens");
    expect(devHtml).toContain("Unknown system subtype: thinking_tokens");
  });
});

describe("MessageList metadata rendering", () => {
  const metadata: DisplayMessage = {
    id: "metadata-1",
    type: "system",
    subtype: "metadata",
    content: [],
    rawSource: { type: "session/metadata", model: "gpt-5.6-sol" },
  };

  it("omits metadata records entirely outside dev mode", () => {
    const html = renderToString(
      <DevModeContext.Provider value={false}>
        <MessageList
          taskTid={1}
          messages={[metadata]}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );

    expect(html).not.toContain("msg-metadata-1");
    expect(html).not.toContain("view-source-btn");
    expect(html).not.toContain("Session metadata");
  });

  it("renders metadata records with their source viewer in dev mode", () => {
    const html = renderToString(
      <DevModeContext.Provider value={true}>
        <MessageList
          taskTid={1}
          messages={[metadata]}
          blocks={new Map()}
          isProcessing={false}
          bandStatus=""
        />
      </DevModeContext.Provider>,
    );

    expect(html).toContain("msg-metadata-1");
    expect(html).toContain("Session metadata");
    expect(html).toContain("view-source-btn");
  });
});

describe("MessageList task diagnostics", () => {
  it("renders error diagnostics as markdown blocks without user controls", () => {
    const diagnostic: DisplayMessage = {
      id: "diagnostic-1",
      type: "diagnostic",
      content: [{ type: "text", text: "**The session is unavailable.**" }],
      diagnostic: {
        severity: "error",
        subject: "Failed to resume session",
      },
    };

    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[diagnostic]}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onEditMessage={() => {}}
        onUndo={() => {}}
      />,
    );

    expect(html).toContain("diagnostic-message diagnostic-error");
    expect(html).toContain("error-block");
    expect(html).toContain("Failed to resume session");
    expect(html).toContain("<strong>The session is unavailable.</strong>");
    expect(html).not.toContain("system-user-message");
    expect(html).not.toContain('title="Edit message"');
    expect(html).not.toContain('title="Undo from here"');
  });

  it("renders warning diagnostics as markdown blocks", () => {
    const diagnostic: DisplayMessage = {
      id: "diagnostic-warning-1",
      type: "diagnostic",
      content: [
        {
          type: "text",
          text: "- The latest turn could not be loaded.\n- Try reloading the task.",
        },
      ],
      diagnostic: { severity: "warning", subject: "History is incomplete" },
    };
    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[diagnostic]}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
      />,
    );
    expect(html).toContain("diagnostic-message diagnostic-warning");
    expect(html).toContain("warning-block");
    expect(html).toContain("History is incomplete");
    expect(html).toContain("<ul>");
    expect(html).toContain("The latest turn could not be loaded.");
  });

  it("keeps a metadata-bearing CyDo nudge editable", () => {
    const nudge: DisplayMessage = {
      id: "cydo-nudge-1",
      uuid: "nudge-uuid-1",
      type: "user",
      isMeta: true,
      content: [{ type: "text", text: "Please continue." }],
      cydoMeta: { label: "Nudge", severity: "info" },
    };

    const html = renderToString(
      <MessageList
        taskTid={1}
        messages={[nudge]}
        blocks={new Map()}
        isProcessing={false}
        bandStatus=""
        onEditMessage={() => {}}
      />,
    );

    expect(html).toContain("Nudge");
    expect(html).toContain('title="Edit message"');
  });
});
