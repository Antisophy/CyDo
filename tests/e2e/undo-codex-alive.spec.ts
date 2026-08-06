import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  killSession,
  visibleHistory,
  installCydoE2eBridge,
  undoThroughBridge,
} from "./fixtures";
import { readFileSync } from "fs";
import type { Page } from "@playwright/test";

async function activeTid(page: Page): Promise<number> {
  const tid = await page
    .locator(".sidebar-item.active[data-tid]")
    .getAttribute("data-tid")
    .catch(() => null);
  if (tid !== null) return Number(tid);
  return Number(
    await page.locator(".sidebar-item[data-tid]").last().getAttribute("data-tid"),
  );
}

async function undoAnchorForUserMessage(page: Page, userText: string) {
  const userMessage = page
    .locator(".message-wrapper:visible", {
      has: page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
        { hasText: userText },
      ),
    })
    .last();
  await userMessage.hover();
  const anchor = await userMessage
    .locator(".fork-btn")
    .getAttribute("data-fork-anchor");
  expect(anchor).toMatch(/^line:\d+$/);
  return anchor!;
}

async function expectUndoRequestRejected(
  page: Page,
  tid: number,
  anchor: string,
  dryRun: boolean,
  revertFiles: boolean,
) {
  await undoThroughBridge(page, tid, anchor, dryRun, revertFiles);
  const errorDialog = page.locator(".command-error-dialog");
  await expect(errorDialog).toContainText("UUID not found in task history");
  await errorDialog.getByRole("button", { name: "Dismiss" }).click();
  await expect(errorDialog).not.toBeVisible();
}

async function openUndoDialogForUserMessage(
  page: import("@playwright/test").Page,
  userText: string,
) {
  const userMsg = page
    .locator(".message-wrapper:visible", {
      has: page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
        { hasText: userText },
      ),
    })
    .last();
  await userMsg.hover();
  await expect(userMsg.locator(".undo-btn")).toBeVisible({ timeout: 5_000 });
  await userMsg.locator(".undo-btn").click();
  await expect(page.locator(".undo-dialog:visible")).toBeVisible({
    timeout: 5_000,
  });
}

async function undoUserMessage(
  page: import("@playwright/test").Page,
  userText: string,
) {
  await openUndoDialogForUserMessage(page, userText);
  await page.locator(".btn-undo:visible").click();
}

test(
  "codex alive-path undo: session stays alive after undo",
  { tag: "@codex-only" },
  async ({ page }) => {
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {
          // ignore non-JSON frames
        }
      });
    });

    await enterSession(page);

    await sendMessage(page, 'Please reply with "alive-one"');
    await expect(assistantText(page, "alive-one")).toBeVisible({
      timeout: 90_000,
    });

    await sendMessage(page, 'Please reply with "alive-two"');
    await expect(assistantText(page, "alive-two")).toBeVisible({
      timeout: 90_000,
    });

    await sendMessage(page, 'Please reply with "alive-three"');
    await expect(assistantText(page, "alive-three")).toBeVisible({
      timeout: 90_000,
    });

    await sendMessage(page, 'Please reply with "alive-four"');
    await expect(assistantText(page, "alive-four")).toBeVisible({
      timeout: 90_000,
    });

    await sendMessage(page, 'Please reply with "alive-five"');
    await expect(assistantText(page, "alive-five")).toBeVisible({
      timeout: 90_000,
    });

    // Session is idle but alive — do NOT kill it before undoing.
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
      timeout: 15_000,
    });

    const assistantUndo = page
      .locator(".message-wrapper:visible", {
        has: page.locator(".assistant-message:visible", {
          hasText: "alive-three",
        }),
      })
      .last();
    await assistantUndo.hover();
    await expect(assistantUndo.locator(".undo-btn")).toHaveCount(0);

    await openUndoDialogForUserMessage(page, 'Please reply with "alive-three"');
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "3 messages will be removed.",
    );
    const rollbackFrameStart = frames.length;
    await page.locator(".btn-undo:visible").click();

    // After undo: exactly turns 1-2 remain.
    await expect(
      page.locator(
        ".message.user-message:not(.pending):not(.meta-message):visible",
      ),
    ).toHaveCount(2, { timeout: 15_000 });

    // After undo: exactly 2 assistant messages remain.
    await expect(
      page.locator(".message.assistant-message:visible"),
    ).toHaveCount(2, {
      timeout: 15_000,
    });

    // alive-one/alive-two remain.
    await expect(
      page.locator(".message.user-message:not(.pending):visible", {
        hasText: "alive-one",
      }),
    ).toBeVisible();
    await expect(
      page.locator(".message.user-message:not(.pending):visible", {
        hasText: "alive-two",
      }),
    ).toBeVisible();
    await expect(assistantText(page, "alive-one")).toBeVisible();
    await expect(assistantText(page, "alive-two")).toBeVisible();

    // alive-three..alive-five are gone.
    for (const marker of ["alive-three", "alive-four", "alive-five"]) {
      await expect(
        page.locator(".message.user-message:visible", { hasText: marker }),
      ).not.toBeVisible();
      await expect(assistantText(page, marker)).not.toBeVisible();
    }

    // Session is still alive: input box is visible and enabled.
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
      timeout: 15_000,
    });

    const rollbackFrames = () => frames.slice(rollbackFrameStart);
    await expect
      .poll(
        () => {
          const reloads = rollbackFrames().filter(
            (frame) => frame?.type === "task_reload",
          );
          const reloadIdx = rollbackFrames().findIndex(
            (frame) => frame?.type === "task_reload",
          );
          const historyEndIdx = rollbackFrames().findIndex(
            (frame, idx) =>
              idx > reloadIdx && frame?.type === "task_history_end",
          );
          return reloads.length === 1 && historyEndIdx > reloadIdx;
        },
        { timeout: 15_000 },
      )
      .toBe(true);
    expect(
      rollbackFrames().findIndex((frame) => frame?.type === "task_history_end"),
    ).toBeGreaterThan(
      rollbackFrames().findIndex((frame) => frame?.type === "task_reload"),
    );

    // Send a follow-up message to confirm the session is fully functional.
    await sendMessage(page, 'Please reply with "alive-six"');
    await expect
      .poll(
        () =>
          rollbackFrames().some(
            (frame) =>
              typeof frame?.agentAck === "string" && frame.agentAck.length > 0,
          ),
        { timeout: 15_000 },
      )
      .toBe(true);
    await expect(assistantText(page, "alive-six")).toBeVisible({
      timeout: 90_000,
    });
    await expect(
      page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
        { hasText: "alive-six" },
      ),
    ).toBeVisible();
    expect(
      rollbackFrames().filter((frame) => frame?.type === "task_reload"),
    ).toHaveLength(1);
    expect(
      rollbackFrames().some(
        (frame) =>
          frame?.type === "task_reload" && frame?.reason === "history_lineage",
      ),
    ).toBe(false);
  },
);

test(
  "codex alive-path undo counts only active turns after prior rollback",
  { tag: "@codex-only" },
  async ({ page }) => {
    await enterSession(page);

    for (const marker of [
      "rolled-count-one",
      "rolled-count-two",
      "rolled-count-three",
    ]) {
      await sendMessage(page, `Please reply with "${marker}"`);
      await expect(assistantText(page, marker)).toBeVisible({
        timeout: 90_000,
      });
    }

    await undoUserMessage(page, 'Please reply with "rolled-count-three"');
    await expect(
      page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
      ),
    ).toHaveCount(2, { timeout: 15_000 });

    await sendMessage(page, 'Please reply with "rolled-count-four"');
    await expect(assistantText(page, "rolled-count-four")).toBeVisible({
      timeout: 90_000,
    });

    await openUndoDialogForUserMessage(
      page,
      'Please reply with "rolled-count-two"',
    );
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "2 messages will be removed.",
    );
    await page.locator(".btn-undo:visible").click();

    await expect(
      page.locator(
        ".message.user-message:visible:not(.pending):not(.meta-message)",
      ),
    ).toHaveCount(1, { timeout: 15_000 });
    await expect(
      page.locator(".message.assistant-message:visible"),
    ).toHaveCount(1, { timeout: 15_000 });

    await expect(
      page.locator(".message.user-message:visible", {
        hasText: "rolled-count-one",
      }),
    ).toBeVisible();
    await expect(assistantText(page, "rolled-count-one")).toBeVisible();

    for (const marker of [
      "rolled-count-two",
      "rolled-count-three",
      "rolled-count-four",
    ]) {
      await expect(
        page.locator(".message.user-message:visible", { hasText: marker }),
      ).not.toBeVisible();
      await expect(assistantText(page, marker)).not.toBeVisible();
    }
  },
);

test(
  "codex capability loss falls back to JSONL assistant undo",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    const prompt = "CODEX_FALLBACK_PROMPT";
    const response = "CODEX_FALLBACK_RESPONSE";
    const later = "CODEX_FALLBACK_LATER";

    await enterSession(page);

    // Produce a real native rollback marker and leave its dead physical records
    // in Codex's JSONL before switching mechanisms.
    await sendMessage(page, 'Please reply with "CODEX_ROLLBACK_LIVE"');
    await expect(assistantText(page, "CODEX_ROLLBACK_LIVE")).toBeVisible({
      timeout: 90_000,
    });
    await sendMessage(page, 'Please reply with "CODEX_ROLLBACK_DEAD"');
    await expect(assistantText(page, "CODEX_ROLLBACK_DEAD")).toBeVisible({
      timeout: 90_000,
    });
    await undoUserMessage(page, 'Please reply with "CODEX_ROLLBACK_DEAD"');
    await expect(assistantText(page, "CODEX_ROLLBACK_DEAD")).toHaveCount(0, {
      timeout: 15_000,
    });

    await sendMessage(page, `Reply exactly with ${response}. ${prompt}`);
    await expect(assistantText(page, response)).toBeVisible({
      timeout: 90_000,
    });
    await sendMessage(page, `Reply exactly with ${later}`);
    await expect(assistantText(page, later)).toBeVisible({ timeout: 90_000 });
    await killSession(page, agentType);

    const assistant = page
      .locator(".message-wrapper:visible", {
        has: page.locator(".assistant-message:visible", { hasText: response }),
      })
      .last();
    await assistant.hover();
    await expect(assistant.locator(".undo-btn")).toBeVisible({
      timeout: 5_000,
    });
    await assistant.locator(".undo-btn").click();
    await expect(
      page.locator(".undo-dialog-prompt-retention:visible"),
    ).toHaveText("The preceding prompt will be retained.");
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "3 messages will be removed.",
    );
    await page.locator(".btn-undo:visible").click();

    await expect(assistantText(page, response)).toHaveCount(0, {
      timeout: 15_000,
    });
    await expect(assistantText(page, later)).toHaveCount(0, {
      timeout: 15_000,
    });
    await expect(
      page.locator(".message.user-message:visible:not(.pending)", {
        hasText: prompt,
      }),
    ).toBeVisible({ timeout: 15_000 });

    await page.reload();
    for (const marker of ["CODEX_ROLLBACK_DEAD", response, later]) {
      await expect(assistantText(page, marker)).toHaveCount(0, {
        timeout: 15_000,
      });
    }
    await expect(
      page.locator(".message.user-message:visible:not(.pending)", {
        hasText: "CODEX_ROLLBACK_DEAD",
      }),
    ).toHaveCount(0);
    await expect(
      page.locator(".message.user-message:visible:not(.pending)", {
        hasText: prompt,
      }),
    ).toBeVisible({ timeout: 15_000 });

    await sendMessage(page, 'Please reply with "CODEX_FALLBACK_FOLLOW_UP"');
    await expect(assistantText(page, "CODEX_FALLBACK_FOLLOW_UP")).toBeVisible({
      timeout: 90_000,
    });
  },
);

test(
  "codex rejects a plausible forged undo line anchor without side effects",
  { tag: "@codex-only" },
  async ({ page, backend }) => {
    await installCydoE2eBridge(page);
    const marker = "UNDO_FORGED_CANONICAL";
    const probe = "UNDO_FORGED_ALIVE";
    const testFile = `${backend.wsDir}/tmp/codex-fileviewer-create.txt`;
    const fileContent = "hello from create fixture";
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {
          // Ignore non-JSON frames.
        }
      });
    });

    await enterSession(page);
    await sendMessage(page, "codex filechange create fixture");
    await expect(assistantText(page, "Done.")).toBeVisible({ timeout: 90_000 });
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fileContent);
    await sendMessage(page, `Reply exactly with ${marker}`);
    await expect(assistantText(page, marker)).toBeVisible({ timeout: 90_000 });
    const tid = await activeTid(page);
    const history = await visibleHistory(page);
    const frameStart = frames.length;

    await expectUndoRequestRejected(page, tid, "line:999999", true, false);
    await expectUndoRequestRejected(page, tid, "line:999999", false, true);

    await expect.poll(() => frames.slice(frameStart).filter(
      (frame) => frame?.type === "error",
    ).length).toBe(2);
    expect(
      frames
        .slice(frameStart)
        .filter((frame) => frame?.type === "error")
        .map((frame) => ({ tid: frame.tid, message: frame.message })),
    ).toEqual([
      { tid, message: "UUID not found in task history" },
      { tid, message: "UUID not found in task history" },
    ]);
    expect(
      frames.slice(frameStart).some(
        (frame) =>
          frame?.type === "undo_preview" ||
          frame?.type === "undo_result" ||
          frame?.type === "task_reload",
      ),
    ).toBe(false);
    expect(await visibleHistory(page)).toEqual(history);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fileContent);
    await page.reload();
    await expect(assistantText(page, marker)).toBeVisible({ timeout: 15_000 });
    expect(await visibleHistory(page)).toEqual(history);
    expect(readFileSync(testFile, "utf8").trimEnd()).toBe(fileContent);
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
      timeout: 15_000,
    });
    await sendMessage(page, `Reply exactly with ${probe}`);
    await expect(assistantText(page, probe)).toBeVisible({ timeout: 90_000 });
  },
);

test(
  "codex rejects a rollback-dead undo anchor after canonical reload without side effects",
  { tag: "@codex-only" },
  async ({ page }) => {
    await installCydoE2eBridge(page);
    const retained = "UNDO_STALE_RETAINED";
    const rolledBack = "UNDO_STALE_ROLLED_BACK";
    const frames: any[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          frames.push(JSON.parse(event.payload.toString()));
        } catch {
          // Ignore non-JSON frames.
        }
      });
    });

    await enterSession(page);
    await sendMessage(page, `Reply exactly with ${retained}`);
    await expect(assistantText(page, retained)).toBeVisible({ timeout: 90_000 });
    await sendMessage(page, `Reply exactly with ${rolledBack}`);
    await expect(assistantText(page, rolledBack)).toBeVisible({ timeout: 90_000 });
    const staleAnchor = await undoAnchorForUserMessage(page, rolledBack);
    const tid = await activeTid(page);

    const rollbackFrameStart = frames.length;
    await undoUserMessage(page, `Reply exactly with ${rolledBack}`);
    await expect(assistantText(page, rolledBack)).toHaveCount(0, {
      timeout: 15_000,
    });
    await expect
      .poll(
        () =>
          frames
            .slice(rollbackFrameStart)
            .some((frame) => frame?.type === "undo_result"),
        { timeout: 15_000 },
      )
      .toBe(true);
    await expect
      .poll(
        () =>
          frames
            .slice(rollbackFrameStart)
            .some((frame) => frame?.type === "task_reload"),
        { timeout: 15_000 },
      )
      .toBe(true);
    // Reload from the canonical active boundary set before replaying the old
    // physical JSONL line anchor through the normal request bridge.
    await page.reload();
    await expect(assistantText(page, retained)).toBeVisible({ timeout: 15_000 });
    await expect(assistantText(page, rolledBack)).toHaveCount(0);
    const history = await visibleHistory(page);
    const frameStart = frames.length;

    await expectUndoRequestRejected(page, tid, staleAnchor, false, true);
    await expect.poll(() => frames.slice(frameStart).filter(
      (frame) => frame?.type === "error",
    ).length).toBe(1);
    expect(
      frames
        .slice(frameStart)
        .filter((frame) => frame?.type === "error")
        .map((frame) => ({ tid: frame.tid, message: frame.message })),
    ).toEqual([{ tid, message: "UUID not found in task history" }]);
    expect(
      frames.slice(frameStart).some(
        (frame) =>
          frame?.type === "undo_preview" ||
          frame?.type === "undo_result" ||
          frame?.type === "task_reload",
      ),
    ).toBe(false);
    expect(await visibleHistory(page)).toEqual(history);
    await page.reload();
    await expect(assistantText(page, retained)).toBeVisible({ timeout: 15_000 });
    await expect(assistantText(page, rolledBack)).toHaveCount(0);
    expect(await visibleHistory(page)).toEqual(history);
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled({
      timeout: 15_000,
    });
    await sendMessage(page, "Reply exactly with UNDO_STALE_ALIVE");
    await expect(assistantText(page, "UNDO_STALE_ALIVE")).toBeVisible({
      timeout: 90_000,
    });
  },
);

test(
  "codex second live undo after an interrupted turn retains earlier history",
  { tag: "@codex-only" },
  async ({ page }) => {
    await enterSession(page);

    // The small Codex model uses the v1 interrupted-turn history marker, which
    // is persisted as a contextual role=user response item.
    await page
      .locator(".task-type-row", { hasText: "system_prompt_test" })
      .click();
    await expect(
      page.locator(".task-type-row.selected .task-type-name"),
    ).toHaveText("system_prompt_test");

    for (const marker of [
      "interrupt-undo-one",
      "interrupt-undo-two",
      "interrupt-undo-three",
    ]) {
      await sendMessage(page, `Please reply with "${marker}"`);
      await expect(assistantText(page, marker)).toBeVisible({
        timeout: 90_000,
      });
    }

    await openUndoDialogForUserMessage(
      page,
      'Please reply with "interrupt-undo-three"',
    );
    await expect(page.locator(".undo-dialog-count:visible")).toContainText(
      "1 message will be removed.",
    );
    await page.locator(".btn-undo:visible").click();

    const activeUsers = page.locator(
      ".message.user-message:visible:not(.pending):not(.meta-message)",
    );
    await expect(activeUsers).toHaveCount(2, { timeout: 15_000 });
    await expect(assistantText(page, "interrupt-undo-one")).toBeVisible();
    await expect(assistantText(page, "interrupt-undo-two")).toBeVisible();

    const retainedContextProbe =
      "check context contains aW50ZXJydXB0LXVuZG8tb25l";
    await sendMessage(page, retainedContextProbe);
    await expect(
      assistantText(page, "context-check-passed").last(),
    ).toBeVisible({ timeout: 90_000 });
    await expect(activeUsers).toHaveCount(3, { timeout: 15_000 });

    const interrupted = "stall session interrupt-undo-running";
    await sendMessage(page, interrupted);
    await expect(
      page.locator(".message.user-message:visible:not(.pending)", {
        hasText: interrupted,
      }),
    ).toBeVisible({ timeout: 90_000 });
    await expect(page.locator(".btn-stop:visible")).toBeVisible();
    await page.locator(".btn-stop:visible").click();
    await expect(page.locator(".btn-stop:visible")).toHaveCount(0, {
      timeout: 90_000,
    });
    await expect(activeUsers).toHaveCount(4, { timeout: 15_000 });

    await openUndoDialogForUserMessage(
      page,
      'Please reply with "interrupt-undo-two"',
    );
    // Only interrupt-undo-two, the probe, and the interrupted prompt are
    // active user turns, so the correct rollback count is three.
    const secondUndoCount = page.locator(".undo-dialog-count:visible");
    await expect(secondUndoCount).toContainText("messages will be removed.");
    const secondUndoPreview = await secondUndoCount.innerText();
    await page.locator(".btn-undo:visible").click();

    await expect(activeUsers).toHaveCount(1, { timeout: 15_000 });
    await expect(
      page.locator(".message.assistant-message:visible"),
    ).toHaveCount(1, { timeout: 15_000 });
    await expect(
      page.locator(".message.user-message:visible", {
        hasText: "interrupt-undo-one",
      }),
    ).toBeVisible();
    await expect(assistantText(page, "interrupt-undo-one")).toBeVisible();

    await sendMessage(page, retainedContextProbe);
    const contextProbe = assistantText(
      page,
      /context-check-(?:passed|failed)/,
    ).last();
    await expect(contextProbe).toBeVisible({ timeout: 90_000 });
    expect({
      secondUndoPreview,
      retainedContext: await contextProbe.innerText(),
    }).toEqual({
      secondUndoPreview: "3 messages will be removed.",
      retainedContext: "context-check-passed",
    });
  },
);
