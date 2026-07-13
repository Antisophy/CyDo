import { test, expect, enterSession, sendMessage } from "./fixtures";

type ParentEvent =
  | { kind: "status"; status: string; isProcessing: boolean }
  | { kind: "output"; type: string; deltaType?: string };

test(
  "background continuation resumes a waiting parent exactly once",
  { tag: "@codex-only" },
  async ({ page }) => {
    const events: ParentEvent[] = [];
    page.on("websocket", (ws) => {
      ws.on("framereceived", (frame) => {
        try {
          const data = JSON.parse(frame.payload.toString()) as {
            type?: string;
            task?: { tid?: number; status?: string; isProcessing?: boolean };
            tid?: number;
            event?: { type?: string; delta_type?: string };
          };
          if (
            data.type === "task_updated" &&
            data.task?.tid === 1 &&
            typeof data.task.status === "string" &&
            typeof data.task.isProcessing === "boolean"
          ) {
            events.push({
              kind: "status",
              status: data.task.status,
              isProcessing: data.task.isProcessing,
            });
          } else if (data.tid === 1 && typeof data.event?.type === "string") {
            events.push({
              kind: "output",
              type: data.event.type,
              deltaType: data.event.delta_type,
            });
          }
        } catch {
          // Ignore non-JSON frames and unrelated events.
        }
      });
    });

    await enterSession(page);
    const waitingStart = events.length;
    await sendMessage(page, "call waiting background resume fixture");
    await expect
      .poll(
        () =>
          events
            .slice(waitingStart)
            .some((event) => event.kind === "status" && event.status === "waiting"),
        { timeout: 30_000 },
      )
      .toBe(true);

    await expect
      .poll(
        () => {
          const afterStart = events.slice(waitingStart);
          const waitingIndex = afterStart.findIndex(
            (event) => event.kind === "status" && event.status === "waiting",
          );
          const backgroundIndex = afterStart.findIndex(
            (event, index) =>
              index > waitingIndex &&
              event.kind === "output" &&
              event.type === "cydo/task_spawned",
          );
          if (backgroundIndex < 0) return -1;
          return afterStart.findIndex(
            (event, index) =>
              index > backgroundIndex &&
              event.kind === "status" &&
              event.status === "active" &&
              event.isProcessing,
          );
        },
        { timeout: 30_000 },
      )
      .toBeGreaterThanOrEqual(0);

    const resumedEvents = events.slice(waitingStart);
    const waitingIndex = resumedEvents.findIndex(
      (event) => event.kind === "status" && event.status === "waiting",
    );
    const backgroundIndex = resumedEvents.findIndex(
      (event, index) =>
        index > waitingIndex &&
        event.kind === "output" &&
        event.type === "cydo/task_spawned",
    );
    expect(backgroundIndex).toBeGreaterThan(waitingIndex);
    expect(
      resumedEvents.slice(waitingIndex + 1, backgroundIndex).some(
        (event) => event.kind === "status" && event.status !== "waiting",
      ),
    ).toBe(false);

    const afterBackground = resumedEvents.slice(backgroundIndex + 1);
    const activeIndex = afterBackground.findIndex(
      (event) =>
        event.kind === "status" &&
        event.status === "active" &&
        event.isProcessing,
    );
    expect(activeIndex).toBeGreaterThanOrEqual(0);
    expect(
      afterBackground.filter(
        (event) =>
          event.kind === "status" &&
          event.status === "active" &&
          event.isProcessing,
      ),
    ).toHaveLength(1);

    expect(
      events
        .slice(waitingStart + backgroundIndex + 1)
        .filter(
          (event) =>
            event.kind === "status" &&
            event.status === "active" &&
            event.isProcessing,
        ),
    ).toHaveLength(1);

    await expect(
      page.locator('.sidebar-item[data-tid="1"] .task-type-icon.waiting'),
    ).not.toBeVisible();

    const activeEventIndex = waitingStart + backgroundIndex + activeIndex + 1;
    await expect
      .poll(
        () =>
          events
            .slice(activeEventIndex + 1)
            .some(
              (event) =>
                event.kind === "output" &&
                event.type === "item/delta" &&
                event.deltaType === "text_delta",
            ),
        { timeout: 90_000 },
      )
      .toBe(true);
    await expect
      .poll(
        () =>
          events
            .slice(activeEventIndex + 1)
            .some((event) => event.kind === "output" && event.type === "turn/result"),
        { timeout: 90_000 },
      )
      .toBe(true);
    await expect
      .poll(
        () =>
          events
            .slice(activeEventIndex + 1)
            .some((event) => event.kind === "status" && event.status === "alive"),
        { timeout: 90_000 },
      )
      .toBe(true);

    await page.reload();
    await expect(
      page.locator('.sidebar-item[data-tid="1"] .task-type-icon.alive'),
    ).toBeVisible();
  },
);
