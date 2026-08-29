import { test, expect, enterSession, sendMessage } from "./fixtures";

test.use({ backendEnv: { MCP_TOOL_TIMEOUT: "2000" } });

test(
  "AskUserQuestion remains pending beyond the total MCP timeout",
  { tag: "@claude-only" },
  async ({ page }) => {
    await enterSession(page);
    await sendMessage(page, "call askuserquestion Should I keep waiting?");

    const form = page.locator(".ask-user-form");
    await expect(form).toBeVisible();

    const toolCall = page
      .locator(".tool-call")
      .filter({
        has: page.locator(".tool-name", { hasText: "AskUserQuestion" }),
      })
      .last();
    await expect(toolCall).toBeVisible();

    // This MCP call intentionally remains unanswered. CyDo's task-interop
    // tools must be allowed to block indefinitely, so it must still be
    // pending after Claude's configured two-second total-duration limit.
    await page.waitForTimeout(3_000);
    await expect(toolCall.locator(".tool-icon-spinner")).toBeVisible();
    await expect(form).toBeVisible();
    expect(await toolCall.textContent()).not.toMatch(
      /MCP server "cydo" tool "AskUserQuestion" timed out/i,
    );
  },
);
