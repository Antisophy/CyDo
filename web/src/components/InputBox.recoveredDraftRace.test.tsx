/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 *
 * SPIKE 34492 — deterministic reproduction of the recovered-draft race behind
 * the intermittent `e2e-codex-undo-codex-alive-L331` failure.
 *
 * Preact flushes a component's pending `useEffect` callbacks synchronously at
 * the START of its next render (preact/hooks `options._render`, the
 * `previousComponent !== currentComponent` branch), i.e. BEFORE the component
 * function body runs and therefore before `textRef.current = text`
 * (InputBox.tsx:85-86) is re-assigned.
 *
 * So a recovery effect scheduled by render N, but not yet flushed by
 * `afterPaint`, runs at the top of render N+1 — the very render that carries
 * the text the user just typed — and reads render N's (empty) `textRef`.
 * `applyRecoveredInputDraft` therefore sees an empty composer and overwrites
 * the freshly typed text with the recovered (just-undone) prompt.
 */
import { beforeEach, describe, expect, it, vi } from "vitest";
import { render } from "preact";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
});

import { InputBox, drafts } from "./InputBox";

const SESSION = "session-uuid";
const RECOVERED = 'Please reply with "CODEX_ROLLBACK_DEAD"';
const TYPED =
  "Reply exactly with CODEX_FALLBACK_RESPONSE. CODEX_FALLBACK_PROMPT";

/** Let preact's `afterPaint` (rAF + setTimeout) flush pending useEffects. */
const flushPaintEffects = () => new Promise((r) => setTimeout(r, 80));
/** Let preact's `debounceRendering` (microtask) process the re-render queue. */
const flushRenderQueue = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

describe("recovered input draft vs. a concurrently typed message", () => {
  let container: HTMLDivElement;
  let sent: string[];

  const mount = (inputDraft?: string) => {
    render(
      <InputBox
        onSend={(text) => {
          sent.push(text);
        }}
        onInterrupt={() => {}}
        isProcessing={false}
        disabled={false}
        sessionId={SESSION}
        inputDraft={inputDraft}
        onInputDraftConsumed={() => {}}
      />,
      container,
    );
  };

  const textarea = () => container.querySelector("textarea")!;
  const sendButton = () =>
    container.querySelector<HTMLButtonElement>(".btn-send")!;

  /** What Playwright's `locator.fill()` does: set value, fire one input event. */
  const fill = (value: string) => {
    const ta = textarea();
    ta.value = value;
    ta.dispatchEvent(new window.Event("input", { bubbles: true }));
  };

  beforeEach(() => {
    drafts.clear();
    sent = [];
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  it("keeps the typed text when the recovery effect flushes before typing", async () => {
    mount(undefined);
    await flushPaintEffects();

    // task_history_end delivers the undone prompt as a recovered draft…
    mount(RECOVERED);
    // …and the browser gets a frame, so the effect flushes normally.
    await flushPaintEffects();
    expect(textarea().value).toBe(RECOVERED);

    // The user (Playwright) now types over it.
    fill(TYPED);
    await flushRenderQueue();
    await flushPaintEffects();

    expect(textarea().value).toBe(TYPED);
    sendButton().click();
    await flushRenderQueue();
    expect(sent).toEqual([TYPED]);
  });

  it("REPRO: recovered draft overwrites text typed in the same frame", async () => {
    mount(undefined);
    await flushPaintEffects();
    expect(textarea().value).toBe("");

    // task_history_end delivers the undone prompt. The recovery effect is now
    // PENDING — `afterPaint` has not fired yet.
    mount(RECOVERED);
    expect(textarea().value).toBe(""); // effect not flushed yet

    // Within the same frame, the user types the new message.
    fill(TYPED);
    await flushRenderQueue();
    const afterTyping = textarea().value;

    await flushPaintEffects();
    const afterPaint = textarea().value;
    const draftsAfterPaint = drafts.get(SESSION);

    // The send button is enabled (the composer is non-empty), so the test/user
    // clicks it and the wrong text goes out.
    expect(sendButton().disabled).toBe(false);
    sendButton().click();
    await flushRenderQueue();

    expect({ afterTyping, afterPaint, draftsAfterPaint, sent }).toEqual({
      afterTyping: TYPED,
      afterPaint: TYPED,
      draftsAfterPaint: TYPED,
      sent: [TYPED],
    });
  });
});

/**
 * The `serverDraft` effect (InputBox.tsx, "Apply incoming draft_updated from
 * other clients") has the identical shape as the `inputDraft` recovery
 * effect above — it decides whether to overwrite `text` by reading
 * `textRef.current`, gated on the same render/effect-flush timing. Same
 * cause, same fix (`applyText` as sole writer): this describe block adapts
 * the repro above to a cross-client `draft_updated` push instead of a
 * post-reload recovery, to prove that path is covered too, not just
 * "fixed for free" by assertion.
 */
describe("serverDraft push vs. a concurrently typed message", () => {
  let container: HTMLDivElement;
  let sent: string[];

  const mount = (serverDraft?: string) => {
    render(
      <InputBox
        onSend={(text) => {
          sent.push(text);
        }}
        onInterrupt={() => {}}
        isProcessing={false}
        disabled={false}
        sessionId={SESSION}
        serverDraft={serverDraft}
      />,
      container,
    );
  };

  const textarea = () => container.querySelector("textarea")!;
  const sendButton = () =>
    container.querySelector<HTMLButtonElement>(".btn-send")!;

  const fill = (value: string) => {
    const ta = textarea();
    ta.value = value;
    ta.dispatchEvent(new window.Event("input", { bubbles: true }));
  };

  beforeEach(() => {
    drafts.clear();
    sent = [];
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  it("keeps the typed text when the serverDraft effect flushes before typing", async () => {
    mount(undefined);
    await flushPaintEffects();

    mount(RECOVERED);
    await flushPaintEffects();
    expect(textarea().value).toBe(RECOVERED);

    fill(TYPED);
    await flushRenderQueue();
    await flushPaintEffects();

    expect(textarea().value).toBe(TYPED);
    sendButton().click();
    await flushRenderQueue();
    expect(sent).toEqual([TYPED]);
  });

  it("REPRO(serverDraft): a same-frame draft_updated push must not overwrite text typed in the same frame", async () => {
    mount(undefined);
    await flushPaintEffects();
    expect(textarea().value).toBe("");

    // A draft_updated arrives from another client. The serverDraft effect is
    // now PENDING — afterPaint has not fired yet.
    mount(RECOVERED);
    expect(textarea().value).toBe(""); // effect not flushed yet

    // Within the same frame, the user types locally.
    fill(TYPED);
    await flushRenderQueue();
    const afterTyping = textarea().value;

    await flushPaintEffects();
    const afterPaint = textarea().value;
    const draftsAfterPaint = drafts.get(SESSION);

    expect(sendButton().disabled).toBe(false);
    sendButton().click();
    await flushRenderQueue();

    expect({ afterTyping, afterPaint, draftsAfterPaint, sent }).toEqual({
      afterTyping: TYPED,
      afterPaint: TYPED,
      draftsAfterPaint: TYPED,
      sent: [TYPED],
    });
  });
});
