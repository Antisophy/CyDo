import { describe, expect, it, vi } from "vitest";
import renderToString from "preact-render-to-string";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
});

import { UndoConfirmDialog } from "./SessionView";

describe("UndoConfirmDialog", () => {
  const render = (props: Partial<Parameters<typeof UndoConfirmDialog>[0]>) =>
    renderToString(
      <UndoConfirmDialog
        messagesRemoved={1}
        canRevertFiles={false}
        retainsPrompt={false}
        supportsFileRevert={true}
        onConfirm={() => {}}
        onDismiss={() => {}}
        {...props}
      />,
    );

  it("enables and checks file revert only for the selected checkpoint", () => {
    const html = render({ canRevertFiles: true });
    expect(html).toContain("checked");
    expect(html).not.toContain("disabled");
  });

  it("explains unavailable file revert for each selected point", () => {
    expect(render({ retainsPrompt: true })).toContain(
      "this response has no file checkpoint",
    );
    expect(render({})).toContain(
      "this point has no file checkpoint and cannot restore files",
    );
    expect(render({ supportsFileRevert: false })).toContain(
      "not supported for this agent type",
    );
  });
});
