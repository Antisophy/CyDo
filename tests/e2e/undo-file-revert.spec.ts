import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  assistantText,
} from "./fixtures";
import { readFileSync } from "fs";

test(
  "undo file revert uses the selected checkpoint",
  { tag: "@claude-only" },
  async ({ page, backend, agentType }) => {
    const testFile = `${backend.wsDir}/undo-revert-test.txt`;
    const firstContent = "first checkpoint state";
    const secondContent = "selected checkpoint state";
    const thirdContent = "third checkpoint state";
    const fourthContent = "conversation only state";

    await enterSession(page);
    await sendMessage(
      page,
      `create file ${testFile} with content ${firstContent}`,
    );
    await expect(assistantText(page, "Done.")).toBeVisible();
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(firstContent);

    const checkpointAssistant = page
      .locator(".message-wrapper", {
        has: page.locator(".assistant-message").last(),
      })
      .last();
    await checkpointAssistant.hover();
    await expect(checkpointAssistant.locator(".undo-btn")).toHaveAttribute(
      "title",
      "Undo this response and later history, retaining its prompt",
    );
    await checkpointAssistant.locator(".undo-btn").click();
    await expect(page.locator(".undo-dialog")).toContainText(
      "this response has no file checkpoint",
    );
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(1),
    ).toBeDisabled();
    await page.locator(".undo-dialog .btn").first().click();

    await sendMessage(
      page,
      `create file ${testFile} with content ${secondContent}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(2);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(secondContent);

    await sendMessage(
      page,
      `create file ${testFile} with content ${thirdContent}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(3);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(thirdContent);

    await killSession(page, agentType);
    const thirdCheckpointUser = page.locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: thirdContent }),
    });
    await expect(thirdCheckpointUser).toHaveCount(1);
    const thirdUndoButton = thirdCheckpointUser.locator(".undo-btn");
    await expect(thirdUndoButton).toHaveAttribute(
      "title",
      "Undo to this point (file checkpoint available)",
    );
    const thirdForkButton = thirdCheckpointUser.locator(".fork-btn");
    await thirdCheckpointUser.hover();
    await expect(thirdForkButton).toBeVisible();
    await thirdForkButton.focus();
    await page.keyboard.press("Tab");
    await expect(thirdUndoButton).toBeFocused();
    await expect(thirdUndoButton).toBeVisible();
    await thirdUndoButton.press("Enter");
    await expect(page.locator(".undo-dialog")).toBeVisible();
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(1),
    ).toBeChecked();
    await page.locator('.undo-dialog input[type="checkbox"]').nth(0).uncheck();
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(0),
    ).not.toBeChecked();
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(1),
    ).toBeChecked();
    await page.locator(".btn-undo").click();
    await expect(page.locator(".undo-result-banner")).toBeVisible();

    // The selected third checkpoint restores the second write, proving the
    // backend passed the resolved checkpoint rather than an adjacent one.
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(secondContent);

    // Keep conversation history intact so this second file rewind receives
    // the same stored launch as the first one.
    const secondCheckpointUser = page.locator(".message-wrapper", {
      has: page.locator(".user-message", { hasText: secondContent }),
    });
    await expect(secondCheckpointUser).toHaveCount(1);
    const secondUndoButton = secondCheckpointUser.locator(".undo-btn");
    await expect(secondUndoButton).toHaveAttribute(
      "title",
      "Undo to this point (file checkpoint available)",
    );
    const secondForkButton = secondCheckpointUser.locator(".fork-btn");
    await secondCheckpointUser.hover();
    await expect(secondForkButton).toBeVisible();
    await secondForkButton.focus();
    await page.keyboard.press("Tab");
    await expect(secondUndoButton).toBeFocused();
    await expect(secondUndoButton).toBeVisible();
    await secondUndoButton.press("Enter");
    await expect(page.locator(".undo-dialog")).toBeVisible();
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(1),
    ).toBeChecked();
    await page.locator('.undo-dialog input[type="checkbox"]').nth(0).uncheck();
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(0),
    ).not.toBeChecked();
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(1),
    ).toBeChecked();
    await page.locator(".btn-undo").click();
    await expect(page.locator(".undo-result-banner")).toBeVisible();
    await expect
      .poll(() => readFileSync(testFile, "utf8").trimEnd())
      .toBe(firstContent);
    await sendMessage(
      page,
      `create file ${testFile} with content ${fourthContent}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(4);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fourthContent);

    await killSession(page, agentType);
    const conversationOnly = page
      .locator(".message-wrapper", {
        has: page.locator(".user-message", { hasText: fourthContent }),
      })
      .last();
    await conversationOnly.hover();
    await conversationOnly.locator(".undo-btn").click();
    await expect(page.locator(".undo-dialog")).toBeVisible();
    await page.locator('.undo-dialog input[type="checkbox"]').nth(1).uncheck();
    await page.locator(".btn-undo").click();
    await expect(page.locator(".undo-result-banner")).toBeVisible();
    await expect(
      page.locator(".message.user-message:not(.pending)", {
        hasText: fourthContent,
      }),
    ).toHaveCount(0);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fourthContent);
  },
);
