import { writeTestConfig } from "./test-config";

import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  assistantText,
  lastAssistantText,
} from "./fixtures";
import type { Page } from "./fixtures";

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<string> {
  let newTid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    newTid = tids.find((tid: string) => !before.has(tid));
    expect(newTid).toBeTruthy();
  }).toPass({ timeout: 5_000 });
  return newTid!;
}

test(
  "custom Claude agent keeps configured name across draft, init, and reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    writeTestConfig(
      "/tmp/playwright-home/.config/cydo/config.yaml",
      `default_agent: claude
agents:
  claude:
    driver: claude
  work-claude:
    driver: claude
workspaces:
  local:
    root: /tmp/cydo-test-workspace
`,
    );
    await page.waitForTimeout(500);

    const taskUpdatedEvents: Array<{ tid: number; agent_name: string }> = [];
    const initEvents: Array<{ tid: number; agent_name?: string; agent?: string }> =
      [];
    const setAgentNameFrames: Array<{ tid: number; agent_name: string }> = [];
    page.on("websocket", (ws) => {
      ws.on("framesent", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (
            data.type === "set_agent_name" &&
            typeof data.tid === "number" &&
            typeof data.agent_name === "string"
          ) {
            setAgentNameFrames.push({
              tid: data.tid,
              agent_name: data.agent_name,
            });
          }
        } catch {}
      });
      ws.on("framereceived", (event) => {
        try {
          const data = JSON.parse(event.payload.toString());
          if (data.type === "task_updated" && data.task) {
            taskUpdatedEvents.push({
              tid: data.task.tid,
              agent_name: data.task.agent_name,
            });
          }
          if (
            data.event?.type === "session/init" &&
            typeof data.tid === "number"
          ) {
            initEvents.push({
              tid: data.tid,
              agent_name: data.event.agent_name,
              agent: data.event.agent,
            });
          }
        } catch {}
      });
    });

    await enterSession(page);
    await expect(page.locator(".agent-picker")).toHaveValue("claude");

    const before = await snapshotTids(page);
    const input = page.locator(".input-textarea:visible").first();
    await input.click();
    await input.fill('reply with "custom agent reload transcript test"');

    const draftTid = await waitForNewTid(page, before);
    await expect(
      page.locator(`.sidebar-item[data-tid="${draftTid}"] .draft-label`),
    ).toBeVisible({ timeout: 2_000 });

    await page.locator(".agent-picker").selectOption("work-claude");
    await expect(page.locator(".agent-picker")).toHaveValue("work-claude");
    const tid = parseInt(draftTid, 10);
    await expect
      .poll(() => setAgentNameFrames.find((e) => e.tid === tid))
      .toMatchObject({
        tid,
        agent_name: "work-claude",
      });
    await page.locator(".btn-send:visible").first().click();

    await expect(
      assistantText(page, "custom agent reload transcript test"),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    await expect
      .poll(() => taskUpdatedEvents.filter((e) => e.tid === tid).at(-1))
      .toMatchObject({
        tid,
        agent_name: "work-claude",
      });
    await expect
      .poll(() => initEvents.find((e) => e.tid === tid))
      .toMatchObject({
        tid,
        agent_name: "work-claude",
        agent: "claude",
      });

    await killSession(page, agentType);
    await page.reload();

    const sidebarItem = page.locator(`.sidebar-item[data-tid="${draftTid}"]`);
    await expect(sidebarItem).toBeVisible({ timeout: 15_000 });
    await sidebarItem.click();

    await expect(
      assistantText(page, "custom agent reload transcript test"),
    ).toBeVisible({ timeout: 15_000 });
    await expect(page.locator(".message.assistant-message")).toHaveCount(1);
    await expect(page.locator(".sidebar-item[data-tid]")).toHaveCount(1);
    await expect(
      page.locator(".sidebar-item.sidebar-archive-node", {
        hasText: /Import/,
      }),
    ).not.toBeVisible();
  },
);

test(
  "cold-loaded Claude Edit renders driver-qualified file viewer after history reload",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const timeout = responseTimeout(agentType);

    await enterSession(page);

    // Prime Claude's file cache, then edit — Edit tool call with structuredPatch.
    await sendMessage(page, "read file README.md");
    await expect(lastAssistantText(page, "Done.")).toBeVisible({ timeout });
    await sendMessage(page, "edit file README.md replace test with updated");
    await expect(
      page.locator(".tool-call").filter({
        has: page.locator(".tool-name", { hasText: "Edit" }),
      }),
    ).toBeVisible({ timeout });
    await expect(lastAssistantText(page, "Done.")).toBeVisible({ timeout });

    // Force a cold load: on process exit, resetHistoryWatermarkAfterExit
    // (task_runner.d) resets the HistoryStore, dropping the in-memory buffer
    // that held the live session/init. The next request_history — triggered
    // here by reloading the page — re-reads Claude's own JSONL from disk,
    // which has no session/init record, so Block.driver can only come from
    // the task snapshot's resolved driver, not a live session/init.
    await killSession(page, agentType);
    await page.reload();

    const sidebarItem = page.locator(".sidebar-item[data-tid]").first();
    await expect(sidebarItem).toBeVisible({ timeout: 15_000 });
    await sidebarItem.click();

    const editTool = page.locator(".tool-call").filter({
      has: page.locator(".tool-name", { hasText: "Edit" }),
    });
    await expect(editTool).toBeVisible({ timeout: 15_000 });

    // The view-file button only renders when the Edit tool call resolves to
    // "claude/Edit" — i.e. only when Block.driver was correctly seeded from
    // the cold-loaded task snapshot.
    await editTool.locator(".tool-header").hover();
    await expect(editTool.locator(".tool-view-file")).toBeVisible({
      timeout: 5_000,
    });
  },
);
