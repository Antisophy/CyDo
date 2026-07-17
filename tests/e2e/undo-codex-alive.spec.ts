import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  killSession,
} from "./fixtures";

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
