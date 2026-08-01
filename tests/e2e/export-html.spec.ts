import { spawnSync } from "child_process";
import { readFileSync, unlinkSync, writeFileSync } from "fs";

import {
  test,
  expect,
  enterSession,
  sendMessage,
  killSession,
  responseTimeout,
  lastAssistantText,
} from "./fixtures";

test("export-html creates viewable HTML file", { tag: "@claude-only" }, async ({ page, backend, agentType }, testInfo) => {

  const outputPath = "/tmp/cydo-export-test.html";

  try {
    await enterSession(page);
    await sendMessage(page, 'reply with "export-marker-ok"');
    await expect(lastAssistantText(page, "export-marker-ok")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    await killSession(page, agentType);

    const tid = await page.locator(".sidebar-item.active").getAttribute("data-tid");
    expect(tid).toBeTruthy();

    const result = spawnSync(
      process.env.CYDO_BIN!,
      ["export-html", tid!, "--output", outputPath],
      {
        env: {
          ...process.env,
          XDG_DATA_HOME: "/tmp/cydo-backend/data",
        },
        encoding: "utf8",
      },
    );
    if (result.status !== 0) {
      throw new Error(`cydo export-html failed (status ${result.status}):\nstdout: ${result.stdout}\nstderr: ${result.stderr}`);
    }

    await page.goto(`file://${outputPath}`);

    await expect(
      page.locator('[data-testid="assistant-text"]', { hasText: "export-marker-ok" }),
    ).toBeVisible({ timeout: 10_000 });

    await expect(page.locator(".sidebar-item")).toHaveCount(
      await page.locator(".sidebar-item").count(),
    );
    const sidebarItems = page.locator(".sidebar-item");
    expect(await sidebarItems.count()).toBeGreaterThan(0);

    await expect(page.locator(".input-textarea")).toHaveCount(0);

    // Assert on the embedded JSON blob directly rather than rendered DOM:
    // the exported HTML loads shiki/mermaid from the esm.sh CDN, unreachable
    // in a network-sandboxed nix build.
    const html = readFileSync(outputPath, "utf8");
    const match = html.match(
      /<script id="cydo-export-data" type="application\/json">([\s\S]*?)<\/script>/,
    );
    expect(match).toBeTruthy();
    const data = JSON.parse(match![1]);
    expect(data.tasks.find((t: { tid: number }) => t.tid === Number(tid))?.driver).toBe("claude");
  } finally {
    try {
      unlinkSync(outputPath);
    } catch {
      // file may not exist if export failed
    }
  }
});

test("export-html includes transcript for custom Claude-backed agent", { tag: "@claude-only" }, async ({ page, agentType }) => {
  const outputPath = "/tmp/cydo-export-custom-agent.html";

  writeFileSync(
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

  try {
    await enterSession(page);
    await page.selectOption(".agent-picker", "work-claude");
    await sendMessage(page, 'reply with "custom-export-marker-ok"');
    await expect(lastAssistantText(page, "custom-export-marker-ok")).toBeVisible(
      { timeout: responseTimeout(agentType) },
    );

    await killSession(page, agentType);

    const tid = await page
      .locator(".sidebar-item.active")
      .getAttribute("data-tid");
    expect(tid).toBeTruthy();

    const result = spawnSync(
      process.env.CYDO_BIN!,
      ["export-html", tid!, "--output", outputPath],
      {
        env: {
          ...process.env,
          XDG_DATA_HOME: "/tmp/cydo-backend/data",
        },
        encoding: "utf8",
      },
    );
    if (result.status !== 0) {
      throw new Error(
        `cydo export-html failed (status ${result.status}):\nstdout: ${result.stdout}\nstderr: ${result.stderr}`,
      );
    }

    await page.goto(`file://${outputPath}`);

    await expect(
      page.locator('[data-testid="assistant-text"]', {
        hasText: "custom-export-marker-ok",
      }),
    ).toBeVisible({ timeout: 10_000 });
  } finally {
    try {
      unlinkSync(outputPath);
    } catch {
      // file may not exist if export failed
    }
  }
});
