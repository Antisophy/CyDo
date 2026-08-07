import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test(
  "Claude replay confirmation replaces the pending user message during a turn",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const prompt =
      "run delayed command sleep 20 && echo replay-reconciliation-finished";

    await enterSession(page);

    await sendMessage(page, 'reply with "replay-reconciliation-ready"');
    await expect(
      assistantText(page, "replay-reconciliation-ready"),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    await sendMessage(page, prompt);

    await expect(
      page.locator(".tool-call", { hasText: "sleep 20" }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });
    await expect(page.locator(".btn-banner-stop")).toBeVisible();
    await expect(
      page.locator(".tool-result", {
        hasText: "replay-reconciliation-finished",
      }),
    ).not.toBeVisible();

    const matchingBubbles = page.locator(
      ".message.user-message:not(.system-user-message):not(.steering-message)",
      { hasText: prompt },
    );
    await expect(
      matchingBubbles,
      "the replay-backed confirmation should replace the pending copy",
    ).toHaveCount(1);

    const matchingWrapper = page
      .locator(".message-wrapper")
      .filter({ has: matchingBubbles });
    await expect(matchingWrapper).toHaveCount(1);
    await matchingWrapper.hover();
    await expect(
      matchingWrapper.locator(".view-source-btn"),
      "the sole canonical bubble should have the replay-backed source",
    ).toHaveCount(1);
    await expect(matchingWrapper.locator(".view-source-btn")).toBeVisible();
  },
);
