import { Buffer } from "node:buffer";
import { test, expect, enterSession } from "./fixtures";
import type { Page } from "./fixtures";

type SocketMessage = string | Buffer;

type ControlFrame = {
  type?: string;
  tid?: number;
  correlation_id?: string;
  content?: unknown;
  entry_point?: string;
  agent_name?: string;
  tasks?: readonly { tid?: number }[];
};

interface PassiveRecorder {
  controls(type: string, tid?: number): readonly ControlFrame[];
}

interface InitialSnapshotHold {
  createRequests: number[];
  deleteRequests: number[];
  targetSnapshotHeld(): boolean;
  targetSnapshotDelivered(): boolean;
  release(): void;
}

function parseControlFrame(message: SocketMessage): ControlFrame | null {
  try {
    return JSON.parse(
      typeof message === "string" ? message : message.toString(),
    ) as ControlFrame;
  } catch {
    return null;
  }
}

function hasTask(frame: ControlFrame | null, tid: number): boolean {
  return (
    frame?.type === "tasks_list" &&
    frame.tasks?.some((task) => task.tid === tid) === true
  );
}

function installPassiveRecorder(page: Page): PassiveRecorder {
  const outbound: ControlFrame[] = [];

  page.on("websocket", (socket) => {
    if (!socket.url().endsWith("/ws")) return;
    socket.on("framesent", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame?.type) outbound.push(frame);
    });
  });

  return {
    controls: (type, tid) =>
      outbound.filter(
        (frame) =>
          frame.type === type && (tid === undefined || frame.tid === tid),
      ),
  };
}

async function snapshotTids(page: Page): Promise<Set<string>> {
  const tids = await page
    .locator(".sidebar-item[data-tid]")
    .evaluateAll((els: Element[]) =>
      els.map((el) => el.getAttribute("data-tid")!),
    );
  return new Set(tids);
}

async function waitForNewTid(page: Page, before: Set<string>): Promise<number> {
  let tid: string | undefined;
  await expect(async () => {
    const tids = await page
      .locator(".sidebar-item[data-tid]")
      .evaluateAll((els: Element[]) =>
        els.map((el) => el.getAttribute("data-tid")!),
      );
    tid = tids.find((candidate) => !before.has(candidate));
    expect(tid).toBeTruthy();
  }).toPass({ timeout: 10_000 });
  return Number(tid);
}

async function waitForPersistedForm(
  recorder: PassiveRecorder,
  tid: number,
  text: string,
  entryPoint: string,
  agent: string,
) {
  await expect
    .poll(() => {
      const drafts = recorder.controls("set_draft", tid);
      return (
        recorder
          .controls("set_entry_point", tid)
          .some((frame) => frame.entry_point === entryPoint) &&
        recorder
          .controls("set_agent_name", tid)
          .some((frame) => frame.agent_name === agent) &&
        drafts.at(-1)?.content === text
      );
    })
    .toBe(true);
}

async function installInitialSnapshotHold(
  page: Page,
  targetTid: number,
): Promise<InitialSnapshotHold> {
  const createRequests: number[] = [];
  const deleteRequests: number[] = [];
  const heldServerFrames: SocketMessage[] = [];
  const deferredServerFrames: SocketMessage[] = [];
  let holding = false;
  let deliveredTargetSnapshot = false;
  let replaying = false;
  let release = () => {
    throw new Error("WebSocket route was not installed");
  };

  await page.routeWebSocket(/\/ws$/, (browserSocket) => {
    const serverSocket = browserSocket.connectToServer();

    const deliverServerFrame = (message: SocketMessage) => {
      if (hasTask(parseControlFrame(message), targetTid))
        deliveredTargetSnapshot = true;
      browserSocket.send(message);
    };

    const relayServerFrame = (message: SocketMessage) => {
      if (replaying) {
        deferredServerFrames.push(message);
        return;
      }
      if (holding) {
        heldServerFrames.push(message);
        return;
      }
      if (hasTask(parseControlFrame(message), targetTid)) {
        holding = true;
        heldServerFrames.push(message);
        return;
      }
      deliverServerFrame(message);
    };

    browserSocket.onMessage((message) => {
      const frame = parseControlFrame(message);
      if (frame?.type === "create_task") createRequests.push(1);
      if (frame?.type === "delete_task") deleteRequests.push(frame.tid ?? -1);
      serverSocket.send(message);
    });
    serverSocket.onMessage(relayServerFrame);

    release = () => {
      if (!holding) throw new Error("Target tasks_list was not held");
      holding = false;
      replaying = true;
      try {
        for (const message of heldServerFrames.splice(0))
          deliverServerFrame(message);
        while (deferredServerFrames.length > 0)
          deliverServerFrame(deferredServerFrames.shift()!);
      } finally {
        replaying = false;
      }
    };
  });

  return {
    createRequests,
    deleteRequests,
    targetSnapshotHeld: () => holding,
    targetSnapshotDelivered: () => deliveredTargetSnapshot,
    release: () => release(),
  };
}

test("direct persisted draft route adopts after its initial task snapshot", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const seedContext = await browser.newContext({ baseURL });
  const seedPage = await seedContext.newPage();
  const seedRecorder = installPassiveRecorder(seedPage);
  const persistedText = "adopt before tasks list\nwith complete persisted body";
  const persistedAgent = agentType === "codex" ? "claude" : "codex";

  await seedPage.goto(baseURL!);
  await enterSession(seedPage);
  await expect(
    seedPage.locator(`.agent-picker option[value="${persistedAgent}"]`),
  ).toHaveCount(1);
  await seedPage.locator(".task-type-row", { hasText: "blank" }).click();
  await expect(
    seedPage.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await seedPage.locator(".agent-picker:visible").selectOption(persistedAgent);
  await expect(seedPage.locator(".agent-picker:visible")).toHaveValue(
    persistedAgent,
  );

  const before = await snapshotTids(seedPage);
  await seedPage.locator(".input-textarea:visible").fill(persistedText);
  const tid = await waitForNewTid(seedPage, before);
  await waitForPersistedForm(
    seedRecorder,
    tid,
    persistedText,
    "blank",
    persistedAgent,
  );
  const targetLink = seedPage.locator(`.sidebar-item[data-tid="${tid}"]`);
  await expect(targetLink).toHaveCount(1);
  const targetHref = await targetLink.getAttribute("href");
  if (!targetHref)
    throw new Error("Persisted sidebar draft did not have a URL");
  const targetURL = new URL(targetHref, seedPage.url()).toString();
  const projectPath = new URL(targetURL).pathname.replace(/\/task\/\d+$/, "");

  await seedContext.close();

  const proxy = await installInitialSnapshotHold(page, tid);
  await page.goto(targetURL);
  await expect.poll(() => proxy.targetSnapshotHeld()).toBe(true);
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  expect(proxy.createRequests).toEqual([]);
  expect(proxy.deleteRequests).toEqual([]);

  proxy.release();
  await expect.poll(() => proxy.targetSnapshotDelivered()).toBe(true);
  const input = page.locator(".input-textarea:visible");
  await expect(input).toHaveCount(1);
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue(persistedText);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(page.locator(".agent-picker:visible")).toHaveValue(
    persistedAgent,
  );
  await expect(
    page.locator(".session-empty:visible", { hasText: "Loading task" }),
  ).toHaveCount(0);
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(1);
  expect(proxy.createRequests).toEqual([]);
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));

  await page.locator(".sidebar-back-btn:visible").click();
  await expect(page).toHaveURL(/\/$/);
  await page.goBack();
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  await expect(input).toHaveCount(1);
  await expect(input).toHaveValue(persistedText);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(page.locator(".agent-picker:visible")).toHaveValue(
    persistedAgent,
  );
  expect(proxy.createRequests).toEqual([]);
  expect(proxy.deleteRequests).toEqual([]);

  await input.fill("");
  await expect(page).toHaveURL(new RegExp(`${projectPath}$`));
  await expect.poll(() => proxy.deleteRequests).toEqual([tid]);
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(0);
  await expect(input).toHaveCount(1);
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue("");
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText("blank");
  await expect(page.locator(".agent-picker:visible")).toHaveValue(
    persistedAgent,
  );
  expect(proxy.createRequests).toEqual([]);
  expect(proxy.deleteRequests).toEqual([tid]);
});
