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
    const thirdContent = "conversation only state";

    await enterSession(page);
    await sendMessage(
      page,
      `create file ${testFile} with content ${firstContent}`,
    );
    await expect(assistantText(page, "Done.")).toBeVisible({ timeout: 30_000 });
  expect(readFileSync(testFile, "utf8").trimEnd()).toBe(firstContent);

    await sendMessage(
      page,
      `create file ${testFile} with content ${secondContent}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(2, {
      timeout: 30_000,
    });
  expect(readFileSync(testFile, "utf8").trimEnd()).toBe(secondContent);

    await killSession(page, agentType);
    const selectedUser = page
      .locator(".message-wrapper", {
        has: page.locator(".user-message", { hasText: secondContent }),
      })
      .last();
    await selectedUser.hover();
    await selectedUser.locator(".undo-btn").click();
    await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
    await expect(
      page.locator('.undo-dialog input[type="checkbox"]').nth(1),
    ).toBeChecked();
    await page.locator(".btn-undo").click();
    await expect(page.locator(".undo-result-banner")).toBeVisible({
      timeout: 15_000,
    });

    // The selected second checkpoint restores the first write, proving the
    // backend passed the resolved checkpoint rather than an adjacent one.
  expect(readFileSync(testFile, "utf8").trimEnd()).toBe(firstContent);

    await sendMessage(
      page,
      `create file ${testFile} with content ${thirdContent}`,
    );
    await expect(assistantText(page, "Done.")).toHaveCount(2, {
      timeout: 30_000,
    });
  expect(readFileSync(testFile, "utf8").trimEnd()).toBe(thirdContent);

    await killSession(page, agentType);
    const conversationOnly = page
      .locator(".message-wrapper", {
        has: page.locator(".user-message", { hasText: thirdContent }),
      })
      .last();
    await conversationOnly.hover();
    await conversationOnly.locator(".undo-btn").click();
    await expect(page.locator(".undo-dialog")).toBeVisible({ timeout: 5_000 });
    await page.locator('.undo-dialog input[type="checkbox"]').nth(1).uncheck();
    await page.locator(".btn-undo").click();
    await expect(page.locator(".undo-result-banner")).toBeVisible({
      timeout: 15_000,
    });
  expect(readFileSync(testFile, "utf8").trimEnd()).toBe(thirdContent);
  },
);
