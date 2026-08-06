import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test(
  "editing a completed session message to empty keeps history loadable",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const reloadReasons: string[] = [];
    const replacementErrors: string[] = [];
    page.on("pageerror", (error) => {
      if (
        /History replacement matched \d+ messages at seq \d+/.test(
          error.message,
        )
      ) {
        replacementErrors.push(error.message);
      }
    });
    page.on("websocket", (ws) => {
      ws.on("framereceived", (frame) => {
        try {
          const event = JSON.parse(frame.payload.toString()) as {
            type?: string;
            reason?: string;
          };
          if (event.type === "task_reload") {
            reloadReasons.push(event.reason ?? "");
          }
        } catch {
          // Ignore non-JSON WebSocket frames.
        }
      });
    });

    const reply = "empty-edit-history-marker";
    const prompt = `Please reply with "${reply}"`;

    await enterSession(page);
    await sendMessage(page, prompt);
    await expect(assistantText(page, reply)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await page.locator(".btn-banner-end").click();
    await expect(page.locator(".btn-banner-archive")).toBeVisible({
      timeout: 30_000,
    });

    const userMessage = page.locator(".message-wrapper").filter({
      has: page.locator(".message.user-message", { hasText: prompt }),
    });
    await userMessage.hover();
    await userMessage.locator('[title="Edit message"]').click();

    const editReloadStart = reloadReasons.length;
    const editor = page.locator(".message.user-message.editing");
    await expect(editor.locator(".edit-textarea")).toBeVisible({
      timeout: 5_000,
    });
    await editor.locator(".edit-textarea").fill("");
    await editor.locator(".edit-actions .btn-primary").click();
    await expect
      .poll(() => reloadReasons.slice(editReloadStart), { timeout: 15_000 })
      .toContain("edit");

    const reloadErrorStart = replacementErrors.length;
    await page.reload();

    const historyReplacementError = page.locator(".toast-message", {
      hasText: /History replacement matched \d+ messages at seq \d+/,
    });
    const emptyUserMessage = page.locator(".message-wrapper").filter({
      has: page.locator(".message.user-message"),
    });
    await expect
      .poll(
        async () => {
          if (await historyReplacementError.isVisible()) {
            return historyReplacementError.innerText();
          }
          const pageError = replacementErrors.at(reloadErrorStart);
          if (pageError) return pageError;
          if (
            (await assistantText(page, reply).isVisible()) &&
            (await emptyUserMessage.count()) === 1
          ) {
            return "loaded";
          }
          return "loading";
        },
        {
          message:
            "the edited session should finish loading without a history replacement error",
          timeout: 15_000,
        },
      )
      .toBe("loaded");

    await expect(emptyUserMessage.locator(".message.user-message")).toHaveText(
      "",
    );
    await emptyUserMessage.hover();
    await emptyUserMessage.locator('[title="Edit message"]').click();
    await expect(emptyUserMessage.locator(".edit-textarea")).toHaveValue("");
  },
);
