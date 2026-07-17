import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
} from "./fixtures";
import type { Page } from "@playwright/test";

async function snapshotTids(
  page: Parameters<typeof sendMessage>[0],
): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(
  page: Parameters<typeof sendMessage>[0],
  before: Set<string>,
): Promise<string> {
  let newTid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    newTid = tids.find((tid: string) => !before.has(tid));
    expect(newTid).toBeTruthy();
  }).toPass({ timeout: 15_000 });
  return newTid!;
}

async function resumeIfNeeded(page: Parameters<typeof sendMessage>[0]) {
  const resumeBtn = page.locator(".btn-banner-resume:visible").first();
  const visible = await resumeBtn
    .isVisible({ timeout: 5_000 })
    .catch(() => false);
  if (visible) {
    await resumeBtn.click();
  }
}

function activeAssistantText(
  page: Parameters<typeof sendMessage>[0],
  text: string,
) {
  return page
    .locator("[style*='display: contents'] [data-testid='assistant-text']", {
      hasText: text,
    })
    .last();
}

function messageWrapper(page: Page, selector: string, text: string) {
  return page
    .locator("[style*='display: contents'] .message-wrapper", {
      has: page.locator(selector, { hasText: text }),
    })
    .last();
}

async function visibleHistory(page: Page) {
  return await page.locator(".message-wrapper").evaluateAll((wrappers) =>
    wrappers
      .filter((wrapper) => wrapper.querySelector(".message:not(.meta-message)"))
      .map((wrapper) => wrapper.textContent),
  );
}

async function forkFromMessage(page: Page, selector: string, text: string) {
  const message = messageWrapper(page, selector, text);
  await message.hover();
  const fork = message.locator(".fork-btn");
  await expect(fork).toBeVisible({ timeout: 5_000 });
  await fork.click();
}

async function undoUserMessage(page: Page, text: string) {
  const message = messageWrapper(
    page,
    ".message.user-message:not(.pending):not(.meta-message)",
    text,
  );
  await message.hover();
  await expect(message.locator(".undo-btn")).toBeVisible({ timeout: 5_000 });
  await message.locator(".undo-btn").click();
  await expect(page.locator(".undo-dialog:visible")).toBeVisible({
    timeout: 5_000,
  });
  await page.locator(".btn-undo:visible").click();
}

test(
  "codex fork from older turn truncates later history and isolates branches",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    const taskCreatedEvents: Array<{
      tid: number;
      parent_tid?: number;
      relation_type?: string;
    }> = [];

    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (data.type === "task_created") {
            taskCreatedEvents.push({
              tid: data.tid,
              parent_tid: data.parent_tid,
              relation_type: data.relation_type,
            });
          }
        } catch {
          /* ignore non-JSON frames */
        }
      });
    });

    const turnOne = "FORK_OLD_TURN_ONE";
    const turnTwo = "FORK_OLD_TURN_TWO";
    const forkOnly = "FORK_CHILD_ONLY";
    const parentOnly = "FORK_PARENT_ONLY";

    await enterSession(page);
    const before = await snapshotTids(page);

    await sendMessage(page, `Reply exactly with ${turnOne}`);
    const parentTid = Number(await waitForNewTid(page, before));
    expect(parentTid).toBeGreaterThan(0);
    await expect(activeAssistantText(page, turnOne)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await sendMessage(page, `Reply exactly with ${turnTwo}`);
    await expect(activeAssistantText(page, turnTwo)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await killSession(page, agentType);
    await page.reload();
    await expect(activeAssistantText(page, turnTwo)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await expect(async () => {
      const turnOneAssistant = messageWrapper(
        page,
        ".assistant-message",
        turnOne,
      );
      await turnOneAssistant.hover();
      await expect(turnOneAssistant.locator(".fork-btn")).toBeVisible({
        timeout: 5_000,
      });
    }).toPass({ timeout: 20_000 });

    await forkFromMessage(page, ".assistant-message", turnOne);

    await expect(async () => {
      const fork = taskCreatedEvents.find(
        (event) =>
          event.relation_type === "fork" && event.parent_tid === parentTid,
      );
      expect(fork).toBeTruthy();
    }).toPass({ timeout: 20_000 });

    const forkTid = taskCreatedEvents.find(
      (event) =>
        event.relation_type === "fork" && event.parent_tid === parentTid,
    )!.tid;

    await expect(async () => {
      if (!page.url().endsWith(`/task/${forkTid}`)) {
        await page.locator(`.sidebar-item[data-tid="${forkTid}"]`).click();
      }
      await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`), {
        timeout: 5_000,
      });
    }).toPass({ timeout: 20_000 });

    await expect(activeAssistantText(page, turnOne)).toBeVisible({
      timeout: 15_000,
    });
    await expect(
      page.locator(
        "[style*='display: contents'] [data-testid='assistant-text']",
        {
          hasText: turnTwo,
        },
      ),
    ).toHaveCount(0);

    await resumeIfNeeded(page);
    await sendMessage(page, `Reply exactly with ${forkOnly}`);
    await expect(activeAssistantText(page, forkOnly)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await page.locator(`.sidebar-item[data-tid="${parentTid}"]`).click();
    await expect(page).toHaveURL(new RegExp(`/task/${parentTid}$`), {
      timeout: 15_000,
    });

    await resumeIfNeeded(page);
    await sendMessage(page, `Reply exactly with ${parentOnly}`);
    await expect(activeAssistantText(page, parentOnly)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await expect(
      page.locator(
        "[style*='display: contents'] [data-testid='assistant-text']",
        {
          hasText: forkOnly,
        },
      ),
    ).toHaveCount(0);

    await page.locator(`.sidebar-item[data-tid="${forkTid}"]`).click();
    await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`), {
      timeout: 15_000,
    });
    await expect(activeAssistantText(page, forkOnly)).toBeVisible({
      timeout: 15_000,
    });
    await expect(
      page.locator(
        "[style*='display: contents'] [data-testid='assistant-text']",
        {
          hasText: parentOnly,
        },
      ),
    ).toHaveCount(0);
    await expect(
      page.locator(
        "[style*='display: contents'] [data-testid='assistant-text']",
        {
          hasText: turnTwo,
        },
      ),
    ).toHaveCount(0);
  },
);

test(
  "codex forks inclusively from the current user turn",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    const currentUser = "FORK_CURRENT_USER";
    const currentResponse = "FORK_CURRENT_RESPONSE";
    const earlierUser = "FORK_EARLIER_USER";

    await enterSession(page);
    const before = await snapshotTids(page);

    await sendMessage(page, `Reply exactly with ${earlierUser}`);
    const parentTid = await waitForNewTid(page, before);
    await expect(activeAssistantText(page, earlierUser)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await sendMessage(page, `Reply exactly with ${currentResponse}. Marker ${currentUser}`);
    await expect(activeAssistantText(page, currentResponse)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const parentHistory = await visibleHistory(page);

    await forkFromMessage(page, ".user-message", currentUser);
    const forkTid = await waitForNewTid(page, before);
    await expect(page).toHaveURL(new RegExp(`/task/${forkTid}$`), {
      timeout: 20_000,
    });

    await expect(
      page.locator(".message.user-message:visible", { hasText: currentUser }),
    ).toBeVisible({ timeout: 15_000 });
    await expect(
      page.locator(".message.user-message:visible", { hasText: earlierUser }),
    ).toBeVisible({ timeout: 15_000 });
    await expect(
      page.locator(".message.user-message:visible", { hasText: currentUser }),
    ).toBeVisible({ timeout: 15_000 });
    await expect(activeAssistantText(page, currentResponse)).toHaveCount(0);

    await page.locator(`.sidebar-item[data-tid="${parentTid}"]`).click();
    await page.reload();
    await expect(activeAssistantText(page, currentResponse)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await visibleHistory(page)).toEqual(parentHistory);
  },
);

test(
  "codex rejects a forged line anchor without changing parent history",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    await page.addInitScript(() => {
      (window as Window & { __cydoE2e?: object }).__cydoE2e = {};
    });
    const marker = "FORK_FORGED_PARENT";
    const taskCreatedEvents: Array<{ parent_tid?: number; relation_type?: string }> = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (data.type === "task_created") taskCreatedEvents.push(data);
        } catch {}
      });
    });

    await enterSession(page);
    const before = await snapshotTids(page);
    await sendMessage(page, `Reply exactly with ${marker}`);
    const parentTid = Number(await waitForNewTid(page, before));
    await expect(activeAssistantText(page, marker)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const parentHistory = await visibleHistory(page);
    const tidsBeforeFork = await snapshotTids(page);

    const forkError = page.waitForEvent("dialog");
    await page.evaluate((tid) => {
      if (!window.__cydoE2e?.fork) throw new Error("CyDo e2e fork bridge unavailable");
      window.__cydoE2e.fork(tid, "line:999999");
    }, parentTid);
    const error = await forkError;
    expect(error.message()).toBe("Fork failed: message UUID not found in task history");
    await error.dismiss();
    expect(await snapshotTids(page)).toEqual(tidsBeforeFork);
    expect(taskCreatedEvents.filter((event) => event.parent_tid === parentTid && event.relation_type === "fork")).toHaveLength(0);
    expect(await visibleHistory(page)).toEqual(parentHistory);
    await page.reload();
    await expect(activeAssistantText(page, marker)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await visibleHistory(page)).toEqual(parentHistory);
  },
);

test(
  "codex rejects a stale line anchor after dead-session rollback without creating a child",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
    await page.addInitScript(() => {
      (window as Window & { __cydoE2e?: object }).__cydoE2e = {};
    });
    const retained = "FORK_STALE_RETAINED";
    const rolledBack = "FORK_STALE_ROLLED_BACK";
    const taskCreatedEvents: Array<{
      parent_tid?: number;
      relation_type?: string;
    }> = [];

    page.on("websocket", (ws) => {
      ws.on("framereceived", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (data.type === "task_created") taskCreatedEvents.push(data);
        } catch {
          // Ignore non-JSON frames.
        }
      });
    });

    await enterSession(page);
    const before = await snapshotTids(page);
    await sendMessage(page, `Reply exactly with ${retained}`);
    const parentTid = Number(await waitForNewTid(page, before));
    await expect(activeAssistantText(page, retained)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    await sendMessage(page, `Reply exactly with ${rolledBack}`);
    await expect(activeAssistantText(page, rolledBack)).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    const staleMessage = messageWrapper(page, ".user-message", rolledBack);
    await staleMessage.hover();
    const staleFork = staleMessage.locator(".fork-btn");
    await expect(staleFork).toBeVisible({ timeout: 5_000 });
    const staleTid = Number(await staleFork.getAttribute("data-fork-tid"));
    const staleAnchor = await staleFork.getAttribute("data-fork-anchor");
    expect(staleTid).toBe(parentTid);
    expect(staleAnchor).toMatch(/^line:\d+$/);

    await killSession(page, agentType);
    await undoUserMessage(page, rolledBack);
    await expect(
      page.locator(".message.user-message:visible", { hasText: rolledBack }),
    ).toHaveCount(0, { timeout: 15_000 });
    await page.reload();
    await expect(activeAssistantText(page, retained)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    const tidsBeforeFork = await snapshotTids(page);
    const parentHistory = await visibleHistory(page);

    const forkError = page.waitForEvent("dialog");
    await page.evaluate(({ tid, anchor }) => {
      if (!window.__cydoE2e?.fork) throw new Error("CyDo e2e fork bridge unavailable");
      window.__cydoE2e.fork(tid, anchor);
    }, { tid: staleTid, anchor: staleAnchor! });
    const error = await forkError;
    expect(error.message()).toBe("Fork failed: message UUID not found in task history");
    await error.dismiss();
    expect(await snapshotTids(page)).toEqual(tidsBeforeFork);
    expect(
      taskCreatedEvents.filter(
        (event) =>
          event.parent_tid === parentTid && event.relation_type === "fork",
      ),
    ).toHaveLength(0);
    expect(await visibleHistory(page)).toEqual(parentHistory);
    await page.reload();
    await expect(activeAssistantText(page, retained)).toBeVisible({
      timeout: responseTimeout(agentType),
    });
    expect(await visibleHistory(page)).toEqual(parentHistory);
  },
);
