import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
  visibleHistory,
  currentTaskTid,
  codexRolloutRecords,
  expectUndoRefusalForUserMessage,
} from "./fixtures";

test(
  "codex refuses native undo of a compaction-folded turn without side effects",
  { tag: "@codex-only" },
  async ({ page, agentType }) => {
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
    const timeout = responseTimeout(agentType);

    await sendMessage(page, "trigger compaction");
    await expect(assistantText(page, "Ready for compaction.")).toBeVisible({
      timeout,
    });

    await sendMessage(page, 'reply with "After compaction."');
    await expect(assistantText(page, "After compaction.")).toBeVisible({
      timeout,
    });

    await expect(page.locator(".compact-boundary-message")).toBeVisible({
      timeout,
    });

    const tid = currentTaskTid(page);
    await expect
      .poll(
        () => codexRolloutRecords(tid).some((record) => record.type === "compacted"),
        { timeout: 15_000 },
      )
      .toBe(true);

    // The first user message of a session is folded into the session-start
    // SYSTEM prompt and has no undo affordance at all (finding F2). Pin the
    // session-start-folded message with .first(): if compaction context
    // re-injection ever renders a second "trigger compaction" match, .last()
    // would silently retarget it and this assertion would stop testing F2
    // while still passing.
    const foldedWrapper = page
      .locator(".message-wrapper:visible", {
        has: page.locator(".message.user-message:visible", {
          hasText: "trigger compaction",
        }),
      })
      .first();
    await foldedWrapper.hover({ timeout: 15_000 });
    await expect(foldedWrapper.locator(".undo-btn")).toHaveCount(0);

    const history = await visibleHistory(page);
    // Read before/after the undo attempt below; this spans a multi-second
    // window, so a late-flushed record from the *preceding* turn could in
    // principle fail this check pointing at an innocent undo (plan §3.4).
    const before = codexRolloutRecords(tid).length;
    const frameStart = frames.length;

    await expectUndoRefusalForUserMessage(
      page,
      'reply with "After compaction."',
      "Native Codex undo preparation refused: completed native turn does not match the simple one-user grammar",
    );

    await expect
      .poll(
        () =>
          frames.slice(frameStart).filter((frame) => frame?.type === "error")
            .length,
        { timeout: 15_000 },
      )
      .toBe(1);
    expect(
      frames
        .slice(frameStart)
        .filter((frame) => frame?.type === "error")
        .map((frame) => ({ tid: frame.tid, message: frame.message })),
    ).toEqual([
      {
        tid,
        message:
          "Native Codex undo preparation refused: completed native turn does not match the simple one-user grammar",
      },
    ]);
    expect(
      frames
        .slice(frameStart)
        .some(
          (frame) =>
            frame?.type === "undo_preview" ||
            frame?.type === "undo_result" ||
            frame?.type === "task_reload",
        ),
    ).toBe(false);

    // See the "before" comment above re: the multi-second comparison window.
    expect(await visibleHistory(page)).toEqual(history);
    expect(codexRolloutRecords(tid).length).toBe(before);

    await sendMessage(page, 'Please reply with "compact-final"');
    await expect(assistantText(page, "compact-final")).toBeVisible({
      timeout,
    });
  },
);
