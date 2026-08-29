import { Buffer } from "node:buffer";
import { test, expect, enterSession } from "./fixtures";
import type { Page } from "./fixtures";

type SocketMessage = string | Buffer;

type TaskFrame = {
  tid?: number;
  draft?: string;
  entry_point?: string;
  agent_name?: string;
};

type ControlFrame = {
  type?: string;
  tid?: number;
  content?: unknown;
  entry_point?: string;
  agent_name?: string;
  new_draft?: string;
  task?: TaskFrame;
};

type ObservedControl = {
  sequence: number;
  frame: ControlFrame;
};

interface PageObserver {
  mark(): number;
  outbound(
    type?: string,
    query?: { tid?: number; since?: number },
  ): readonly ObservedControl[];
  inbound(
    type?: string,
    query?: { tid?: number; since?: number },
  ): readonly ObservedControl[];
}

interface OutboundHoldingObserver extends PageObserver {
  armOutgoingMutationHold(): number;
  heldOutgoing(): readonly ObservedControl[];
  forwarded(
    type?: string,
    query?: { tid?: number; since?: number },
  ): readonly ObservedControl[];
  releaseOutgoingHold(): void;
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

function frameTid(frame: ControlFrame): number | undefined {
  return frame.tid ?? frame.task?.tid;
}

function filterControls(
  controls: readonly ObservedControl[],
  type: string | undefined,
  query: { tid?: number; since?: number } | undefined,
): readonly ObservedControl[] {
  return controls.filter(
    (control) =>
      (type === undefined || control.frame.type === type) &&
      (query?.tid === undefined || frameTid(control.frame) === query.tid) &&
      (query?.since === undefined || control.sequence > query.since),
  );
}

function installPassiveObserver(page: Page): PageObserver {
  const outbound: ObservedControl[] = [];
  const inbound: ObservedControl[] = [];
  let sequence = 0;

  page.on("websocket", (socket) => {
    if (!socket.url().endsWith("/ws")) return;
    socket.on("framesent", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame?.type) outbound.push({ sequence: ++sequence, frame });
    });
    socket.on("framereceived", (event) => {
      const frame = parseControlFrame(event.payload.toString());
      if (frame?.type) inbound.push({ sequence: ++sequence, frame });
    });
  });

  return {
    mark: () => sequence,
    outbound: (type, query) => filterControls(outbound, type, query),
    inbound: (type, query) => filterControls(inbound, type, query),
  };
}

function isDraftMutation(frame: ControlFrame | null): boolean {
  return (
    frame?.type === "set_entry_point" ||
    frame?.type === "set_agent_name" ||
    frame?.type === "set_draft"
  );
}

async function installOutboundHoldingObserver(
  page: Page,
): Promise<OutboundHoldingObserver> {
  const outbound: ObservedControl[] = [];
  const inbound: ObservedControl[] = [];
  const forwarded: ObservedControl[] = [];
  const held: ObservedControl[] = [];
  const heldFrames: { message: SocketMessage; observed?: ObservedControl }[] =
    [];
  const deferredFrames: {
    message: SocketMessage;
    observed?: ObservedControl;
  }[] = [];
  let sequence = 0;
  let armed = false;
  let holding = false;
  let replaying = false;
  let release = () => {
    throw new Error("WebSocket route was not installed");
  };

  await page.routeWebSocket(/\/ws$/, (browserSocket) => {
    const serverSocket = browserSocket.connectToServer();

    const forwardBrowserFrame = (entry: {
      message: SocketMessage;
      observed?: ObservedControl;
    }) => {
      if (entry.observed) forwarded.push(entry.observed);
      serverSocket.send(entry.message);
    };

    browserSocket.onMessage((message) => {
      const frame = parseControlFrame(message);
      const observed = frame?.type
        ? { sequence: ++sequence, frame }
        : undefined;
      if (observed) outbound.push(observed);
      const entry = { message, observed };

      if (replaying) {
        deferredFrames.push(entry);
        return;
      }
      if (holding || (armed && isDraftMutation(frame))) {
        holding = true;
        heldFrames.push(entry);
        if (observed) held.push(observed);
        return;
      }
      forwardBrowserFrame(entry);
    });

    serverSocket.onMessage((message) => {
      const frame = parseControlFrame(message);
      if (frame?.type) inbound.push({ sequence: ++sequence, frame });
      browserSocket.send(message);
    });

    release = () => {
      if (!holding) throw new Error("No outgoing draft mutation is held");
      armed = false;
      holding = false;
      replaying = true;
      try {
        while (heldFrames.length > 0) forwardBrowserFrame(heldFrames.shift()!);
        while (deferredFrames.length > 0)
          forwardBrowserFrame(deferredFrames.shift()!);
      } finally {
        replaying = false;
      }
    };
  });

  return {
    mark: () => sequence,
    outbound: (type, query) => filterControls(outbound, type, query),
    inbound: (type, query) => filterControls(inbound, type, query),
    armOutgoingMutationHold: () => {
      if (armed || holding) throw new Error("Outgoing mutation hold is active");
      armed = true;
      return sequence;
    },
    heldOutgoing: () => held,
    forwarded: (type, query) => filterControls(forwarded, type, query),
    releaseOutgoingHold: () => release(),
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
  }).toPass();
  return Number(tid);
}

async function createPersistedDraft(
  page: Page,
  observer: PageObserver,
  text: string,
): Promise<number> {
  const before = await snapshotTids(page);
  const input = page.locator(".input-textarea:visible");
  await expect(input).toHaveCount(1);
  await input.fill(text);
  const tid = await waitForNewTid(page, before);
  await expect
    .poll(() =>
      observer
        .outbound("set_draft", { tid })
        .some((control) => control.frame.content === text),
    )
    .toBe(true);
  return tid;
}

async function selectPersistedDraft(page: Page, tid: number): Promise<void> {
  const draft = page.locator(`.sidebar-item[data-tid="${tid}"]`);
  await expect(draft).toHaveCount(1);
  await draft.click();
  await expect(page).toHaveURL(new RegExp(`/task/${tid}(?:/|$)`));
  await expect(page.locator(".input-textarea:visible")).toHaveCount(1);
}

async function selectedEntryPoint(page: Page): Promise<string> {
  const entryPoint = await page
    .locator(".task-type-row.selected .task-type-name")
    .textContent();
  if (!entryPoint) throw new Error("Selected entry point was unavailable");
  return entryPoint.trim();
}

async function selectableAgentValues(page: Page): Promise<readonly string[]> {
  return page.locator(".agent-picker:visible option").evaluateAll((options) =>
    options
      .map((option) => option as HTMLOptionElement)
      .filter((option) => option.value.length > 0 && !option.disabled)
      .map((option) => option.value),
  );
}

async function expectControlledForm(
  page: Page,
  text: string,
  entryPoint: string,
  agent: string,
) {
  const input = page.locator(".input-textarea:visible");
  await expect(input).toHaveCount(1);
  await expect(input).toBeEnabled();
  await expect(input).toHaveValue(text);
  await expect(
    page.locator(".task-type-row.selected .task-type-name"),
  ).toHaveText(entryPoint);
  await expect(page.locator(".agent-picker:visible")).toHaveValue(agent);
}

function pendingTaskFlush(
  observer: PageObserver,
  tid: number,
  since: number,
): readonly ObservedControl[] {
  return observer
    .outbound(undefined, { since })
    .filter(
      (control) =>
        control.frame.tid === tid &&
        (control.frame.type === "set_entry_point" ||
          control.frame.type === "set_agent_name" ||
          control.frame.type === "set_draft"),
    );
}

async function observeLoadingTaskInsertion(page: Page): Promise<void> {
  await page.evaluate(() => {
    const testWindow = window as Window & {
      __cydoCrossTabLoading?: {
        state: { inserted: boolean };
        observer: MutationObserver;
      };
    };
    testWindow.__cydoCrossTabLoading?.observer.disconnect();
    const state = { inserted: false };
    const inspect = (node: Node) => {
      if (!(node instanceof Element)) return;
      if (
        node.matches(".session-empty") &&
        node.textContent?.includes("Loading task")
      )
        state.inserted = true;
      if (
        node
          .querySelector(".session-empty")
          ?.textContent?.includes("Loading task")
      )
        state.inserted = true;
    };
    const observer = new MutationObserver((records) => {
      for (const record of records)
        for (const node of record.addedNodes) inspect(node);
    });
    observer.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
    testWindow.__cydoCrossTabLoading = { state, observer };
  });
}

async function loadingTaskWasInserted(page: Page): Promise<boolean> {
  return page.evaluate(() => {
    const state = (
      window as Window & {
        __cydoCrossTabLoading?: { state: { inserted: boolean } };
      }
    ).__cydoCrossTabLoading;
    if (!state) throw new Error("Loading task observer was unavailable");
    return state.state.inserted;
  });
}

test("draft creation syncs title and body to another tab", async ({
  page,
  browser,
  baseURL,
}) => {
  const observer = installPassiveObserver(page);
  const context2 = await browser.newContext({ baseURL });
  const page2 = await context2.newPage();

  await enterSession(page);
  await enterSession(page2);

  const draftText = "cross tab draft sync body";
  const draftTid = await createPersistedDraft(page, observer, draftText);

  const tab2Draft = page2.locator(`.sidebar-item[data-tid="${draftTid}"]`);
  await expect(tab2Draft).toHaveCount(1);
  await expect(tab2Draft.locator(".sidebar-label")).toHaveText(draftText);
  await tab2Draft.click();
  await expect(page2.locator(".input-textarea:visible")).toHaveValue(draftText);

  await context2.close();
  await page.locator(".input-textarea:visible").fill("");
  await expect(
    page.locator(`.sidebar-item[data-tid="${draftTid}"]`),
  ).toHaveCount(0);
});

test("a pristine adopted draft accepts peer text and configuration", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const observer1 = installPassiveObserver(page);
  const context2 = await browser.newContext({ baseURL });
  const page2 = await context2.newPage();
  const observer2 = await installOutboundHoldingObserver(page2);

  await enterSession(page);
  await enterSession(page2);

  const baselineEntryPoint = await selectedEntryPoint(page);
  const baselineAgent = await page
    .locator(".agent-picker:visible")
    .inputValue();
  const peerAgent = agentType === "codex" ? "claude" : "codex";
  expect(await selectableAgentValues(page)).toContain(peerAgent);
  expect(peerAgent).not.toBe(baselineAgent);
  expect(baselineEntryPoint).not.toBe("blank");

  const baselineText = "pristine baseline text";
  const tid = await createPersistedDraft(page, observer1, baselineText);
  await selectPersistedDraft(page2, tid);
  await expectControlledForm(
    page2,
    baselineText,
    baselineEntryPoint,
    baselineAgent,
  );
  expect(observer2.outbound("create_task")).toHaveLength(0);

  const peerText = "pristine peer first line\nsecond peer line";
  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await page.locator(".agent-picker:visible").selectOption(peerAgent);
  await page.locator(".input-textarea:visible").fill(peerText);

  await expect
    .poll(() => {
      const peerDraftArrived = observer2
        .inbound("draft_updated", { tid })
        .some((control) => control.frame.new_draft === peerText);
      const peerConfigurationArrived = observer2
        .inbound("task_updated", { tid })
        .some(
          (control) =>
            control.frame.task?.entry_point === "blank" &&
            control.frame.task.agent_name === peerAgent,
        );
      return peerDraftArrived && peerConfigurationArrived;
    })
    .toBe(true);
  await expectControlledForm(page2, peerText, "blank", peerAgent);
  await expect(
    page2.locator(`.sidebar-item[data-tid="${tid}"] .sidebar-label`),
  ).toHaveText("pristine peer first line");
  await expect(
    page2.locator(`.sidebar-item[data-tid="${tid}"] .task-type-icon-blank`),
  ).toBeVisible();
  await expect(page2.locator(".input-textarea:visible")).toHaveCount(1);
  expect(observer1.outbound("create_task")).toHaveLength(1);
  expect(observer2.outbound("create_task")).toHaveLength(0);

  await context2.close();
  await page.locator(".input-textarea:visible").fill("");
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(0);
});

test("a diverged adopted draft retains local fields until its held write wins", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const observer1 = installPassiveObserver(page);
  const context2 = await browser.newContext({ baseURL });
  const page2 = await context2.newPage();
  const observer2 = await installOutboundHoldingObserver(page2);

  await enterSession(page);
  await enterSession(page2);

  const baselineEntryPoint = await selectedEntryPoint(page);
  const baselineAgent = await page
    .locator(".agent-picker:visible")
    .inputValue();
  const receiverAgent = agentType === "codex" ? "claude" : "codex";
  expect(baselineAgent).toBe(agentType);
  expect(await selectableAgentValues(page)).toEqual(
    expect.arrayContaining([baselineAgent, receiverAgent]),
  );
  expect(receiverAgent).not.toBe(baselineAgent);
  expect(new Set([baselineEntryPoint, "isolated", "blank"]).size).toBe(3);
  await expect(
    page.locator(".task-type-row", { hasText: "isolated" }),
  ).toHaveCount(1);
  await expect(
    page.locator(".task-type-row", { hasText: "blank" }),
  ).toHaveCount(1);

  const baselineText = "diverged baseline text";
  const tid = await createPersistedDraft(page, observer1, baselineText);
  await selectPersistedDraft(page2, tid);
  await expectControlledForm(
    page2,
    baselineText,
    baselineEntryPoint,
    baselineAgent,
  );
  expect(observer2.outbound("create_task")).toHaveLength(0);

  const receiverText = "receiver keeps this first line\nreceiver second line";
  const holdStart = observer2.armOutgoingMutationHold();
  await page2.locator(".task-type-row", { hasText: "isolated" }).click();
  await page2.locator(".agent-picker:visible").selectOption(receiverAgent);
  await page2.locator(".input-textarea:visible").fill(receiverText);
  await expect
    .poll(() =>
      observer2
        .heldOutgoing()
        .filter(
          (control) =>
            control.frame.tid === tid &&
            (control.frame.type === "set_entry_point" ||
              control.frame.type === "set_agent_name" ||
              control.frame.type === "set_draft"),
        )
        .map((control) => ({
          type: control.frame.type,
          entryPoint: control.frame.entry_point,
          agent: control.frame.agent_name,
          content: control.frame.content,
        })),
    )
    .toEqual([
      {
        type: "set_entry_point",
        entryPoint: "isolated",
        agent: undefined,
        content: undefined,
      },
      {
        type: "set_agent_name",
        entryPoint: undefined,
        agent: receiverAgent,
        content: undefined,
      },
      {
        type: "set_draft",
        entryPoint: undefined,
        agent: undefined,
        content: receiverText,
      },
    ]);
  expect(
    observer2.forwarded("set_entry_point", { tid, since: holdStart }),
  ).toHaveLength(0);
  expect(
    observer2.forwarded("set_agent_name", { tid, since: holdStart }),
  ).toHaveLength(0);
  expect(
    observer2.forwarded("set_draft", { tid, since: holdStart }),
  ).toHaveLength(0);

  const peerStart = observer2.mark();
  const senderStart = observer1.mark();
  await expect(page.locator(".agent-picker:visible")).toHaveValue(
    baselineAgent,
  );
  const senderText = "sender peer first line\nsender second line";
  await page.locator(".input-textarea:visible").fill(senderText);
  await expect
    .poll(() => {
      const senderDraftSent = observer1
        .outbound("set_draft", { tid, since: senderStart })
        .some((control) => control.frame.content === senderText);
      const peerDraftArrived = observer2
        .inbound("draft_updated", { tid, since: peerStart })
        .some((control) => control.frame.new_draft === senderText);
      return senderDraftSent && peerDraftArrived;
    })
    .toBe(true);

  await page.locator(".task-type-row", { hasText: "blank" }).click();
  await expect
    .poll(() => {
      const senderEntryPointSent = observer1
        .outbound("set_entry_point", { tid, since: senderStart })
        .some((control) => control.frame.entry_point === "blank");
      const peerFullSnapshotArrived = observer2
        .inbound("task_updated", { tid, since: peerStart })
        .some((control) => {
          const task = control.frame.task;
          return (
            task?.draft === senderText &&
            task.entry_point === "blank" &&
            task.agent_name === baselineAgent
          );
        });
      return senderEntryPointSent && peerFullSnapshotArrived;
    })
    .toBe(true);
  await expectControlledForm(page2, receiverText, "isolated", receiverAgent);
  await expect(
    page2.locator(`.sidebar-item[data-tid="${tid}"] .sidebar-label`),
  ).toHaveText("receiver keeps this first line");
  await expect(page2.locator(".input-textarea:visible")).toHaveCount(1);

  const releaseStart = observer1.mark();
  observer2.releaseOutgoingHold();
  await expect
    .poll(() =>
      observer2
        .forwarded(undefined, { since: holdStart })
        .filter(
          (control) =>
            control.frame.tid === tid &&
            (control.frame.type === "set_entry_point" ||
              control.frame.type === "set_agent_name" ||
              control.frame.type === "set_draft"),
        )
        .map((control) => ({
          type: control.frame.type,
          entryPoint: control.frame.entry_point,
          agent: control.frame.agent_name,
          content: control.frame.content,
        })),
    )
    .toEqual([
      {
        type: "set_entry_point",
        entryPoint: "isolated",
        agent: undefined,
        content: undefined,
      },
      {
        type: "set_agent_name",
        entryPoint: undefined,
        agent: receiverAgent,
        content: undefined,
      },
      {
        type: "set_draft",
        entryPoint: undefined,
        agent: undefined,
        content: receiverText,
      },
    ]);
  expect(observer2.forwarded("create_task", { since: holdStart })).toHaveLength(
    0,
  );
  expect(observer2.forwarded("delete_task", { since: holdStart })).toHaveLength(
    0,
  );
  await expect
    .poll(() => {
      const receiverConfigurationArrived = observer1
        .inbound("task_updated", { tid, since: releaseStart })
        .some(
          (control) =>
            control.frame.task?.entry_point === "isolated" &&
            control.frame.task.agent_name === receiverAgent,
        );
      const receiverDraftArrived = observer1
        .inbound("draft_updated", { tid, since: releaseStart })
        .some((control) => control.frame.new_draft === receiverText);
      return receiverConfigurationArrived && receiverDraftArrived;
    })
    .toBe(true);

  const targetHref = await page
    .locator(`.sidebar-item[data-tid="${tid}"]`)
    .getAttribute("href");
  if (!targetHref)
    throw new Error("Persisted sidebar draft did not have a URL");
  const context3 = await browser.newContext({ baseURL });
  const page3 = await context3.newPage();
  await page3.goto(new URL(targetHref, page.url()).toString());
  await expectControlledForm(page3, receiverText, "isolated", receiverAgent);

  await context3.close();
  await context2.close();
  await page.locator(".input-textarea:visible").fill("");
  await expect(page.locator(`.sidebar-item[data-tid="${tid}"]`)).toHaveCount(0);
});

test("stable persisted drafts switch A to B and back without lifecycle RPCs", async ({
  page,
  browser,
  baseURL,
  agentType,
}) => {
  const observer1 = installPassiveObserver(page);
  const context2 = await browser.newContext({ baseURL });
  const page2 = await context2.newPage();
  const observer2 = installPassiveObserver(page2);

  await enterSession(page);
  await enterSession(page2);

  const baselineEntryPoint = await selectedEntryPoint(page);
  const baselineAgent = await page
    .locator(".agent-picker:visible")
    .inputValue();
  const agentB = agentType === "codex" ? "claude" : "codex";
  const agentALatest = baselineAgent;
  expect(baselineAgent).toBe(agentType);
  expect(await selectableAgentValues(page)).toEqual(
    expect.arrayContaining([agentALatest, agentB]),
  );
  expect(agentB).not.toBe(agentALatest);
  expect(new Set([baselineEntryPoint, "blank", "isolated"]).size).toBe(3);

  const textA = "switch persisted A baseline";
  const tidA = await createPersistedDraft(page, observer1, textA);
  await page2.locator(".task-type-row", { hasText: "blank" }).click();
  await page2.locator(".agent-picker:visible").selectOption(agentB);
  const textB = "switch persisted B baseline";
  const tidB = await createPersistedDraft(page2, observer2, textB);
  expect(tidB).not.toBe(tidA);
  await expect(page2.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    1,
  );
  await expect(
    page2.locator(`.sidebar-item[data-tid="${tidA}"] .sidebar-label`),
  ).toHaveText(textA);
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    1,
  );
  await expect(
    page.locator(`.sidebar-item[data-tid="${tidB}"] .sidebar-label`),
  ).toHaveText(textB);
  await expect
    .poll(() =>
      observer1
        .inbound("task_updated", { tid: tidB })
        .some(
          (control) =>
            control.frame.task?.entry_point === "blank" &&
            control.frame.task.agent_name === agentB,
        ),
    )
    .toBe(true);

  const latestA = "switch persisted A latest local text";
  const entryPointAStart = observer1.mark();
  await page.locator(".task-type-row", { hasText: "isolated" }).click();
  await expect
    .poll(() =>
      observer1
        .outbound("set_entry_point", { tid: tidA, since: entryPointAStart })
        .some((control) => control.frame.entry_point === "isolated"),
    )
    .toBe(true);
  const editAStart = observer1.mark();
  const peerEditAStart = observer2.mark();
  await page.locator(".input-textarea:visible").fill(latestA);
  await expect
    .poll(() => {
      const localDraftSent = observer1
        .outbound("set_draft", { tid: tidA, since: editAStart })
        .some((control) => control.frame.content === latestA);
      const peerDraftArrived = observer2
        .inbound("draft_updated", { tid: tidA, since: peerEditAStart })
        .some((control) => control.frame.new_draft === latestA);
      return localDraftSent && peerDraftArrived;
    })
    .toBe(true);
  await expectControlledForm(page, latestA, "isolated", agentALatest);

  const bRow = page.locator(`.sidebar-item[data-tid="${tidB}"]`);
  await expect(page.locator(".input-textarea:visible")).toBeFocused();
  const preFocusBStart = observer1.mark();
  await bRow.focus();
  await expect(bRow).toBeFocused();
  await expect
    .poll(() =>
      observer1
        .outbound("set_draft", { tid: tidA, since: preFocusBStart })
        .map((control) => control.frame.content),
    )
    .toEqual([latestA]);
  await observeLoadingTaskInsertion(page);
  const switchToBStart = observer1.mark();
  await bRow.click();
  await expectControlledForm(page, textB, "blank", agentB);
  await expect(page).toHaveURL(new RegExp(`/task/${tidB}(?:/|$)`));
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    1,
  );
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    1,
  );
  await expect
    .poll(() =>
      pendingTaskFlush(observer1, tidA, switchToBStart).map(
        (control) => control.frame.type,
      ),
    )
    .toEqual(["set_entry_point", "set_agent_name", "set_draft"]);
  expect(pendingTaskFlush(observer1, tidA, switchToBStart)).toEqual([
    expect.objectContaining({
      frame: expect.objectContaining({
        type: "set_entry_point",
        entry_point: "isolated",
      }),
    }),
    expect.objectContaining({
      frame: expect.objectContaining({
        type: "set_agent_name",
        agent_name: agentALatest,
      }),
    }),
    expect.objectContaining({
      frame: expect.objectContaining({
        type: "set_draft",
        content: latestA,
      }),
    }),
  ]);
  expect(
    observer1
      .outbound(undefined, { since: switchToBStart })
      .filter(
        (control) =>
          control.frame.type === "create_task" ||
          control.frame.type === "delete_task",
      ),
  ).toEqual([]);
  expect(await loadingTaskWasInserted(page)).toBe(false);
  await expect(
    page.locator(".session-empty:visible", { hasText: "Loading task" }),
  ).toHaveCount(0);

  const aRow = page.locator(`.sidebar-item[data-tid="${tidA}"]`);
  await expect(page.locator(".input-textarea:visible")).toBeFocused();
  const preFocusAStart = observer1.mark();
  await aRow.focus();
  await expect(aRow).toBeFocused();
  await expect
    .poll(() =>
      observer1
        .outbound("set_draft", { tid: tidB, since: preFocusAStart })
        .map((control) => control.frame.content),
    )
    .toEqual([textB]);
  await observeLoadingTaskInsertion(page);
  const switchToAStart = observer1.mark();
  await aRow.click();
  await expectControlledForm(page, latestA, "isolated", agentALatest);
  await expect(page).toHaveURL(new RegExp(`/task/${tidA}(?:/|$)`));
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    1,
  );
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    1,
  );
  await expect
    .poll(() =>
      pendingTaskFlush(observer1, tidB, switchToAStart).map(
        (control) => control.frame.type,
      ),
    )
    .toEqual(["set_entry_point", "set_agent_name", "set_draft"]);
  expect(pendingTaskFlush(observer1, tidB, switchToAStart)).toEqual([
    expect.objectContaining({
      frame: expect.objectContaining({
        type: "set_entry_point",
        entry_point: "blank",
      }),
    }),
    expect.objectContaining({
      frame: expect.objectContaining({
        type: "set_agent_name",
        agent_name: agentB,
      }),
    }),
    expect.objectContaining({
      frame: expect.objectContaining({ type: "set_draft", content: textB }),
    }),
  ]);
  expect(
    observer1
      .outbound(undefined, { since: switchToAStart })
      .filter(
        (control) =>
          control.frame.type === "create_task" ||
          control.frame.type === "delete_task",
      ),
  ).toEqual([]);
  expect(await loadingTaskWasInserted(page)).toBe(false);
  await expect(
    page.locator(".session-empty:visible", { hasText: "Loading task" }),
  ).toHaveCount(0);

  await page2.locator(".input-textarea:visible").fill("");
  await expect(page2.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    0,
  );
  await expect(page.locator(`.sidebar-item[data-tid="${tidB}"]`)).toHaveCount(
    0,
  );
  await context2.close();
  await page.locator(".input-textarea:visible").fill("");
  await expect(page.locator(`.sidebar-item[data-tid="${tidA}"]`)).toHaveCount(
    0,
  );
});
