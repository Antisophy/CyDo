import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
  assistantText,
} from "./fixtures";

test(
  "canonicalizes the workspace/project segments of a task URL",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const projectRoot = "/local/cydo-test-workspace";

    // Create a task so we have a real tid.
    await enterSession(page);
    await sendMessage(page, 'Please reply with "alpha"');
    await expect(assistantText(page, "alpha")).toBeVisible({
      timeout: responseTimeout(agentType),
    });

    const canonicalUrl = new URL(page.url()).pathname;
    const tid = Number(canonicalUrl.match(/\/task\/(\d+)$/)![1]);
    expect(canonicalUrl).toBe(`${projectRoot}/task/${tid}`);

    // Install instrumentation for the remainder of the test: count
    // replaceState calls and outbound request_task_types frames. Installed
    // once for the whole page — installing per case would double-wrap.
    await page.addInitScript(() => {
      (window as any).__replaceStateCalls = 0;
      const rs = history.replaceState.bind(history);
      history.replaceState = (...args: Parameters<typeof rs>) => {
        (window as any).__replaceStateCalls++;
        return rs(...args);
      };
      (window as any).__sentTypes = [] as string[];
      const origSend = WebSocket.prototype.send;
      WebSocket.prototype.send = function (data: any) {
        try {
          (window as any).__sentTypes.push(JSON.parse(String(data)).type);
        } catch {
          // ignore non-JSON frames
        }
        return origSend.call(this, data);
      };
    });

    // Case: already-canonical cold load. Zero replaceState calls, and the
    // client (re-)requests project-scoped task types (step 2's fix).
    await page.goto(canonicalUrl);
    await expect(assistantText(page, "alpha")).toBeVisible();
    await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveClass(
      /\bactive\b/,
    );
    await expect
      .poll(
        async () =>
          page.evaluate(() =>
            (window as any).__sentTypes.includes("request_task_types"),
          ),
      )
      .toBe(true);
    expect(await page.evaluate(() => (window as any).__replaceStateCalls)).toBe(
      0,
    );

    // Case: legacy /task/<tid> gets rewritten to the canonical URL.
    await page.goto(`/task/${tid}`);
    await expect(page).toHaveURL(new RegExp(`${projectRoot}/task/${tid}$`));
    await expect(assistantText(page, "alpha")).toBeVisible();
    await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveClass(
      /\bactive\b/,
    );

    // Case: a bogus scope also gets rewritten to the canonical URL.
    await page.goto(`/bogus-ws/bogus-proj/task/${tid}`);
    await expect(page).toHaveURL(new RegExp(`${projectRoot}/task/${tid}$`));
    await expect(assistantText(page, "alpha")).toBeVisible();
    await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveClass(
      /\bactive\b/,
    );

    // Case: the correction replaces rather than pushes, so it never becomes
    // a back-stack entry.
    await page.goto(projectRoot);
    await expect(page.locator(".input-textarea:visible").first()).toBeEnabled();
    await page.goto(`/task/${tid}`);
    await expect(page).toHaveURL(new RegExp(`${projectRoot}/task/${tid}$`));
    await page.goBack();
    expect(new URL(page.url()).pathname).toBe(projectRoot);
  },
);
