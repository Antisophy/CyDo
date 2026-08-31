import {
  test,
  expect,
  enterSession,
  sendMessage,
  responseTimeout,
} from "./fixtures";
import { join } from "path";

test.use({
  backendEnv: {
    CYDO_CLAUDE_BIN: join(
      __dirname,
      "..",
      "title-switch-overlap-signal-wrapper.sh",
    ),
  },
});

test(
  "SwitchMode preserves overlapping title generation",
  { tag: "@claude-only" },
  async ({ page, agentType }) => {
    const titleFailureEvent = new Promise<string>((resolve) => {
      page.on("websocket", (ws) => {
        ws.on("framereceived", (event) => {
          try {
            const data = JSON.parse(event.payload.toString());
            if (
              data.event?.type === "process/stderr" &&
              data.event.text.startsWith("failed to generate title:")
            ) {
              resolve(data.event.text);
            }
          } catch {
            // Ignore non-JSON frames.
          }
        });
      });
    });

    await enterSession(page);
    await sendMessage(
      page,
      "call switchmode plan title-switch-overlap-fixture",
    );

    await expect(
      page.locator(".result-divider.system-user-message", {
        hasText: "Mode switch: plan",
      }),
    ).toBeVisible({ timeout: responseTimeout(agentType) });

    const generatedTitle = page.locator(
      ".sidebar-item.active .sidebar-label",
      { hasText: "Overlapping Title Survived" },
    );
    const timeout = responseTimeout(agentType);
    const outcome = await Promise.race([
      generatedTitle.waitFor({ state: "visible", timeout }).then(async () => ({
        kind: "title",
        text: await generatedTitle.innerText(),
      })),
      titleFailureEvent.then((text) => ({
        kind: "failure",
        text,
      })),
    ]);

    expect(outcome).toEqual({
      kind: "title",
      text: "Overlapping Title Survived",
    });
  },
);
