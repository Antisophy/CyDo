import { describe, expect, it, vi } from "vitest";
import renderToString from "preact-render-to-string";
import { makeTaskState, type TaskState } from "../types";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
});

import { SessionView, UndoConfirmDialog } from "./SessionView";

function renderSession(undoPending: TaskState["undoPending"]) {
  return renderToString(
    <SessionView
      task={{ ...makeTaskState(7), undoPending }}
      connected={true}
      tasksLoading={false}
      isActive={true}
      onSend={() => {}}
      onInterrupt={() => {}}
      onStop={() => {}}
      onCloseStdin={() => {}}
      onResume={() => {}}
      onFork={() => {}}
      onUndo={() => {}}
      onUndoConfirm={() => {}}
      onUndoDismiss={() => {}}
      onClearInputDraft={() => {}}
      onAskUserResponse={() => {}}
      onPermissionPromptResponse={() => {}}
      theme="dark"
      onToggleTheme={() => {}}
      onToggleSidebar={() => {}}
    />,
  );
}

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

describe("SessionView undo pending", () => {
  it("hides a requesting undo", () => {
    const html = renderSession({
      afterUuid: "boundary-7",
      kind: "requesting",
      canRevertFiles: false,
      retainsPrompt: false,
    });

    expect(html).not.toContain("undo-dialog");
    expect(html).not.toContain("undo-dialog-count");
  });

  it("renders history-entry preview with existing count wording", () => {
    const html = renderSession({
      afterUuid: "boundary-7",
      kind: "history_entries",
      messagesRemoved: 1,
      canRevertFiles: false,
      retainsPrompt: false,
    });

    expect(html).toContain("undo-dialog");
    expect(html).toContain("1 message will be removed.");
  });

  it("renders Codex-turn preview with existing count wording", () => {
    const html = renderSession({
      afterUuid: "boundary-7",
      kind: "codex_turns",
      messagesRemoved: 2,
      canRevertFiles: false,
      retainsPrompt: false,
    });

    expect(html).toContain("undo-dialog");
    expect(html).toContain("2 messages will be removed.");
  });
});
