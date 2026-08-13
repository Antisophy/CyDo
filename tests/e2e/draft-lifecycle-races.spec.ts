import { Buffer } from "node:buffer";
import { test, expect, enterSession } from "./fixtures";
import type { Page } from "./fixtures";

type SocketMessage = string | Buffer;

type ControlFrame = {
  type?: string;
  tid?: number;
  correlation_id?: string;
  content?: unknown;
};

type CreateRequest = {
  correlationId: string | null;
  content: unknown;
  sentAfterDeleteAck: boolean;
};

type CreatedTask = {
  tid: number;
  correlationId: string | null;
};

interface DraftRaceProxy {
  createRequests: CreateRequest[];
  deleteRequests: number[];
  taskCreated: CreatedTask[];
  taskDeleted: number[];
  bootstrapComplete(): boolean;
  createdTid(correlationId: string): number | null;
  isCreateHeld(): boolean;
  isDeleteAckHeld(): boolean;
  armDeleteAckHold(): void;
  releaseCreateAck(): void;
  releaseDeleteAck(): void;
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

async function installDraftRaceProxy(page: Page): Promise<DraftRaceProxy> {
  const createRequests: CreateRequest[] = [];
  const deleteRequests: number[] = [];
  const taskCreated: CreatedTask[] = [];
  const taskDeleted: number[] = [];
  const bootstrapFrames = new Set<string>();
  const heldCreateFrames: SocketMessage[] = [];
  const heldDeleteFrames: SocketMessage[] = [];
  const deferredServerFrames: SocketMessage[] = [];

  let createCorrelation: string | null = null;
  let createdTid: number | null = null;
  let holdingCreate = false;
  let holdingDelete = false;
  let deleteAckArmed = false;
  let deleteAckReleased = false;
  let replayingServerFrames = false;
  let armDeletionAck = () => {
    throw new Error("WebSocket route was not installed");
  };
  let releaseCreationAck = () => {
    throw new Error("WebSocket route was not installed");
  };
  let releaseDeletionAck = () => {
    throw new Error("WebSocket route was not installed");
  };

  await page.routeWebSocket(/\/ws$/, (browserSocket) => {
    const serverSocket = browserSocket.connectToServer();

    const consumeServerFrame = (message: SocketMessage) => {
      const frame = parseControlFrame(message);
      if (frame?.type) bootstrapFrames.add(frame.type);

      if (frame?.type === "task_created" && typeof frame.tid === "number") {
        taskCreated.push({
          tid: frame.tid,
          correlationId:
            typeof frame.correlation_id === "string"
              ? frame.correlation_id
              : null,
        });
      }
      if (frame?.type === "task_deleted" && typeof frame.tid === "number")
        taskDeleted.push(frame.tid);

      if (holdingCreate) {
        heldCreateFrames.push(message);
        return;
      }

      if (
        createdTid === null &&
        createCorrelation !== null &&
        frame?.type === "task_created" &&
        frame.correlation_id === createCorrelation &&
        typeof frame.tid === "number"
      ) {
        createdTid = frame.tid;
        holdingCreate = true;
        heldCreateFrames.push(message);
        return;
      }

      if (holdingDelete) {
        heldDeleteFrames.push(message);
        return;
      }

      if (
        deleteAckArmed &&
        createdTid !== null &&
        frame?.type === "task_deleted" &&
        frame.tid === createdTid
      ) {
        holdingDelete = true;
        heldDeleteFrames.push(message);
        return;
      }

      browserSocket.send(message);
    };

    const relayServerFrame = (message: SocketMessage) => {
      if (replayingServerFrames) {
        deferredServerFrames.push(message);
        return;
      }
      consumeServerFrame(message);
    };

    const replayHeldFrames = (frames: SocketMessage[]) => {
      replayingServerFrames = true;
      try {
        while (frames.length > 0) browserSocket.send(frames.shift()!);
        while (deferredServerFrames.length > 0) {
          const deferred = deferredServerFrames.splice(0);
          for (const frame of deferred) consumeServerFrame(frame);
        }
      } finally {
        replayingServerFrames = false;
      }
    };

    browserSocket.onMessage((message) => {
      const frame = parseControlFrame(message);
      if (frame?.type === "create_task") {
        const correlationId =
          typeof frame.correlation_id === "string"
            ? frame.correlation_id
            : null;
        createRequests.push({
          correlationId,
          content: frame.content,
          sentAfterDeleteAck: deleteAckReleased,
        });
        if (createCorrelation === null && correlationId !== null)
          createCorrelation = correlationId;
      }
      if (frame?.type === "delete_task" && typeof frame.tid === "number")
        deleteRequests.push(frame.tid);
      serverSocket.send(message);
    });
    serverSocket.onMessage(relayServerFrame);

    releaseCreationAck = () => {
      if (!holdingCreate)
        throw new Error("task_created was not being held before release");
      holdingCreate = false;
      replayHeldFrames(heldCreateFrames);
    };
    armDeletionAck = () => {
      if (!holdingCreate)
        throw new Error(
          "task_deleted must be armed before task_created release",
        );
      deleteAckArmed = true;
    };
    releaseDeletionAck = () => {
      if (!holdingDelete)
        throw new Error("task_deleted was not being held before release");
      holdingDelete = false;
      deleteAckReleased = true;
      replayHeldFrames(heldDeleteFrames);
    };
  });

  const proxy: DraftRaceProxy = {
    createRequests,
    deleteRequests,
    taskCreated,
    taskDeleted,
    bootstrapComplete: () =>
      [
        "workspaces_list",
        "task_types_list",
        "agents_list",
        "tasks_list",
        "server_status",
        "notices_list",
      ].every((type) => bootstrapFrames.has(type)),
    createdTid: (correlationId) =>
      taskCreated.find((task) => task.correlationId === correlationId)?.tid ??
      null,
    isCreateHeld: () => holdingCreate,
    isDeleteAckHeld: () => holdingDelete,
    armDeleteAckHold: () => armDeletionAck(),
    releaseCreateAck: () => releaseCreationAck(),
    releaseDeleteAck: () => releaseDeletionAck(),
  };

  return proxy;
}

function requireCorrelation(request: CreateRequest, label: string): string {
  if (!request.correlationId)
    throw new Error(`${label} create_task did not carry a correlation_id`);
  return request.correlationId;
}

async function waitForCreatedTid(
  proxy: DraftRaceProxy,
  correlationId: string,
): Promise<number> {
  await expect.poll(() => proxy.createdTid(correlationId)).not.toBeNull();
  const tid = proxy.createdTid(correlationId);
  if (tid === null)
    throw new Error(`task_created missing for ${correlationId}`);
  return tid;
}

async function expectControlledTextarea(page: Page, value: string) {
  const input = page.locator(".input-textarea:visible");
  await expect(input).toHaveCount(1);
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue(value);
}

async function expectNoTaskLoading(page: Page) {
  await expect(
    page.locator(".session-empty", { hasText: "Loading task…" }),
  ).toHaveCount(0);
}

async function observeDeleteAcknowledgementProcessing(page: Page) {
  await page.evaluate(() => {
    const storage = Storage.prototype as Storage & {
      __cydoDraftDeleteSetItemWrapped?: boolean;
      __cydoDraftDeleteOriginalSetItem?: Storage["setItem"];
    };
    const testWindow = window as Window & {
      __cydoDraftDeleteOutboxWrites?: number;
    };
    testWindow.__cydoDraftDeleteOutboxWrites = 0;
    if (storage.__cydoDraftDeleteSetItemWrapped) return;

    storage.__cydoDraftDeleteOriginalSetItem = storage.setItem;
    storage.setItem = function (key: string, value: string) {
      if (key === "cydo.outbox.v1") {
        testWindow.__cydoDraftDeleteOutboxWrites =
          (testWindow.__cydoDraftDeleteOutboxWrites ?? 0) + 1;
      }
      storage.__cydoDraftDeleteOriginalSetItem!.call(this, key, value);
    };
    storage.__cydoDraftDeleteSetItemWrapped = true;
  });
}

async function waitForDeleteAcknowledgementProcessing(page: Page) {
  await expect
    .poll(() =>
      page.evaluate(
        () =>
          (
            window as Window & {
              __cydoDraftDeleteOutboxWrites?: number;
            }
          ).__cydoDraftDeleteOutboxWrites ?? 0,
      ),
    )
    .toBeGreaterThan(0);
  await page.evaluate(
    () =>
      new Promise<void>((resolve) => {
        requestAnimationFrame(() => {
          requestAnimationFrame(() => resolve());
        });
      }),
  );
}

async function observeStaleProjection(page: Page, tid: number) {
  await page.evaluate((staleTid) => {
    const selector = `.sidebar-item[data-tid="${staleTid}"]`;
    const state = { sawRoute: false, sawSidebar: false };
    const inspect = () => {
      if (new RegExp(`/task/${staleTid}(?:/|$)`).test(location.pathname))
        state.sawRoute = true;
      if (document.querySelector(selector)) state.sawSidebar = true;
    };
    const observer = new MutationObserver((records) => {
      for (const record of records) {
        for (const node of record.addedNodes) {
          if (
            node instanceof Element &&
            (node.matches(selector) || node.querySelector(selector))
          ) {
            state.sawSidebar = true;
          }
        }
      }
      inspect();
    });
    observer.observe(document.documentElement, {
      subtree: true,
      childList: true,
      attributes: true,
    });
    inspect();
    (
      window as Window & {
        __cydoDraftLifecycleStaleProjection?: {
          state: typeof state;
          observer: MutationObserver;
        };
      }
    ).__cydoDraftLifecycleStaleProjection = { state, observer };
  }, tid);
}

async function expectNoStaleProjection(page: Page, tid: number) {
  await expect(page).not.toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(0);
  await expect
    .poll(() =>
      page.evaluate(() => {
        const state = (
          window as Window & {
            __cydoDraftLifecycleStaleProjection?: {
              state: {
                sawRoute: boolean;
                sawSidebar: boolean;
              };
            };
          }
        ).__cydoDraftLifecycleStaleProjection;
        if (!state) throw new Error("stale-projection observer is unavailable");
        return state.state;
      }),
    )
    .toEqual({ sawRoute: false, sawSidebar: false });
}

test("clear and retype waits for stale draft deletion before creating a replacement", async ({
  page,
}) => {
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const input = page.locator(".input-textarea:visible");
  await input.fill("draft A that must never be projected");

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const createA = proxy.createRequests[0]!;
  expect(createA.content).toEqual([]);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(proxy, correlationA);
  expect(proxy.isCreateHeld()).toBe(true);
  await observeStaleProjection(page, tidA);

  await input.fill("");
  await input.fill("replacement B stays controlled");
  await expectControlledTextarea(page, "replacement B stays controlled");
  await expectNoTaskLoading(page);
  expect(proxy.createRequests).toHaveLength(1);

  proxy.armDeleteAckHold();
  proxy.releaseCreateAck();

  await expect.poll(() => proxy.deleteRequests).toEqual([tidA]);
  await expect.poll(() => proxy.isDeleteAckHeld()).toBe(true);
  expect(proxy.createRequests).toHaveLength(1);
  await expectControlledTextarea(page, "replacement B stays controlled");
  await expectNoTaskLoading(page);
  await expectNoStaleProjection(page, tidA);

  proxy.releaseDeleteAck();

  await expect.poll(() => proxy.createRequests.length).toBe(2);
  const createB = proxy.createRequests[1]!;
  expect(createB.content).toEqual([]);
  expect(createB.sentAfterDeleteAck).toBe(true);
  const correlationB = requireCorrelation(createB, "B");
  expect(correlationB).not.toBe(correlationA);
  const tidB = await waitForCreatedTid(proxy, correlationB);
  expect(tidB).not.toBe(tidA);

  await expectControlledTextarea(page, "replacement B stays controlled");
  await expectNoTaskLoading(page);
  await expectNoStaleProjection(page, tidA);
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    1,
  );
  expect(proxy.deleteRequests).toEqual([tidA]);
  expect(proxy.taskDeleted.filter((tid) => tid === tidA)).toHaveLength(1);
});

test("clear-only waits for stale draft deletion and leaves a usable blank form", async ({
  page,
}) => {
  const proxy = await installDraftRaceProxy(page);
  await enterSession(page);
  await expect.poll(() => proxy.bootstrapComplete()).toBe(true);

  const input = page.locator(".input-textarea:visible");
  await input.fill("draft A that will be cleared");

  await expect.poll(() => proxy.createRequests.length).toBe(1);
  const createA = proxy.createRequests[0]!;
  expect(createA.content).toEqual([]);
  const correlationA = requireCorrelation(createA, "A");
  const tidA = await waitForCreatedTid(proxy, correlationA);
  expect(proxy.isCreateHeld()).toBe(true);
  await observeStaleProjection(page, tidA);

  await input.fill("");
  await expectControlledTextarea(page, "");
  await expectNoTaskLoading(page);
  expect(proxy.createRequests).toHaveLength(1);

  proxy.armDeleteAckHold();
  proxy.releaseCreateAck();

  await expect.poll(() => proxy.deleteRequests).toEqual([tidA]);
  await expect.poll(() => proxy.isDeleteAckHeld()).toBe(true);
  expect(proxy.createRequests).toHaveLength(1);
  await expectControlledTextarea(page, "");
  await expectNoTaskLoading(page);
  await expectNoStaleProjection(page, tidA);

  await observeDeleteAcknowledgementProcessing(page);
  proxy.releaseDeleteAck();

  await waitForDeleteAcknowledgementProcessing(page);
  await expectControlledTextarea(page, "");
  await expectNoTaskLoading(page);
  await expectNoStaleProjection(page, tidA);
  const blankInput = page.locator(".input-textarea:visible");
  await blankInput.click();
  await expect(blankInput).toBeFocused();
  expect(proxy.createRequests).toHaveLength(1);
  expect(proxy.deleteRequests).toEqual([tidA]);
  expect(proxy.taskDeleted.filter((tid) => tid === tidA)).toHaveLength(1);
});
