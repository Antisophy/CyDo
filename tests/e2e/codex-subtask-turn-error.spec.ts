/**
 * Reproducer for sub-task terminal agent errors being dropped.
 *
 * Bug: when a sub-task's agent failed terminally mid-turn (e.g. Codex reports
 * usageLimitExceeded), the driver discarded the error carried by the failed
 * turn/completed notification and emitted an empty "success" turn/result. The
 * sub-task was then finalized as a successful completion with a blank summary,
 * so the parent's Task tool call returned a blank response.
 *
 * The mock API answers the child's prompt with HTTP 429
 * {"error":{"type":"usage_limit_reached"}}, which the real Codex binary
 * translates into an `error` notification plus turn/completed status=failed.
 * The parent must receive a Task result carrying the usage-limit message.
 */
import { test, expect, enterSession, sendMessage } from "./fixtures";

test(
  "codex sub-task terminal error is delivered to the parent",
  { tag: "@codex-only" },
  async ({ page }) => {
    await enterSession(page);

    await sendMessage(page, "call task research fail with usage limit");

    // The parent's Task tool result must surface the child's error message
    // instead of a blank response.
    const messageList = page.locator('[style*="display: contents"] .message-list');
    await expect(
      messageList.getByText(/hit your usage limit/i).last(),
    ).toBeVisible();
  },
);
