import { describe, expect, it } from "vitest";
import renderToString from "preact-render-to-string";
import { DevModeContext } from "../devMode";
import type { Block, DisplayMessage } from "../types";
import { AssistantMessage } from "./AssistantMessage";

function renderAssistantMessage(message: DisplayMessage, block: Block): string {
  return renderToString(
    <DevModeContext.Provider value={false}>
      <AssistantMessage
        message={message}
        resolvedBlocks={[block]}
        onViewFile={() => {}}
        semanticSelectors={false}
      />
    </DevModeContext.Provider>,
  );
}

describe("AssistantMessage diagnostic blocks", () => {
  it("renders the diagnostic subject and Markdown body with warning styling", () => {
    const html = renderAssistantMessage(
      {
        id: "diagnostic-msg-1",
        type: "assistant",
        content: [],
        blockIds: ["diagnostic-1"],
        streaming: false,
        nextCreationOrder: 1,
      },
      {
        itemId: "diagnostic-1",
        type: "diagnostic",
        severity: "warning",
        subject: "Agent error (retrying)",
        text: "Try **again** shortly.",
        completed: true,
        creationOrder: 0,
      },
    );

    expect(html).toContain("warning-block");
    expect(html).toContain("Agent error (retrying)");
    expect(html).toContain("Try <strong>again</strong> shortly.");
  });
});
