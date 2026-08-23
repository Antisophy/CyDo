/**
 * @vitest-environment jsdom
 * @vitest-environment-options { "pretendToBeVisual": true }
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { render } from "preact";
import { InputBox } from "./InputBox";
import {
  createOrdinaryDraftStore,
  type OrdinaryDraftStore,
} from "../ordinaryDraftStore";

vi.hoisted(() => {
  vi.stubGlobal("CSS", { supports: () => false });
});

const SESSION = "session-uuid";
const RECOVERED = 'Please reply with "CODEX_ROLLBACK_DEAD"';
const TYPED =
  "Reply exactly with CODEX_FALLBACK_RESPONSE. CODEX_FALLBACK_PROMPT";

const flushPaintEffects = () =>
  new Promise((resolve) => setTimeout(resolve, 80));
const flushRenderQueue = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

function fill(textarea: HTMLTextAreaElement, value: string) {
  textarea.value = value;
  textarea.dispatchEvent(new window.Event("input", { bubbles: true }));
}

interface MountOptions {
  sessionId?: string;
  serverDraft?: string;
  inputDraft?: string;
}

function ordinaryInput(
  store: OrdinaryDraftStore,
  sent: string[],
  options: MountOptions = {},
) {
  return (
    <InputBox
      onSend={(text) => {
        sent.push(text);
      }}
      onInterrupt={() => {}}
      isProcessing={false}
      disabled={false}
      sessionId={options.sessionId ?? SESSION}
      serverDraft={options.serverDraft}
      inputDraft={options.inputDraft}
      onInputDraftConsumed={() => {}}
      ordinaryDraftStore={store}
    />
  );
}

describe("recovered input draft vs. a concurrently typed message", () => {
  let container: HTMLDivElement;
  let sent: string[];
  let store: OrdinaryDraftStore;

  const mount = (inputDraft?: string) => {
    render(ordinaryInput(store, sent, { inputDraft }), container);
  };
  const textarea = () =>
    container.querySelector<HTMLTextAreaElement>("textarea")!;
  const sendButton = () =>
    container.querySelector<HTMLButtonElement>(".btn-send")!;

  beforeEach(() => {
    store = createOrdinaryDraftStore();
    sent = [];
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    render(null, container);
    container.remove();
  });

  it("keeps typed text when recovery and input arrive in the same frame", async () => {
    mount();
    await flushPaintEffects();
    mount(RECOVERED);
    fill(textarea(), TYPED);
    await flushRenderQueue();
    await flushPaintEffects();

    expect(textarea().value).toBe(TYPED);
    expect(store.read(SESSION)).toBe(TYPED);
    sendButton().click();
    await flushRenderQueue();
    expect(sent).toEqual([TYPED]);
  });
});

describe("ordinary draft scalar delivery", () => {
  let container: HTMLDivElement;
  let sent: string[];
  let store: OrdinaryDraftStore;

  const mount = (serverDraft?: string, sessionId = SESSION) => {
    render(ordinaryInput(store, sent, { serverDraft, sessionId }), container);
  };
  const textarea = () =>
    container.querySelector<HTMLTextAreaElement>("textarea")!;

  beforeEach(() => {
    store = createOrdinaryDraftStore();
    sent = [];
    container = document.createElement("div");
    document.body.appendChild(container);
  });

  afterEach(() => {
    render(null, container);
    container.remove();
  });

  it("applies same-frame A to B to C transitions in order", async () => {
    mount("A");
    store.applyRemote(SESSION, { old_draft: "A", new_draft: "B" });
    store.applyRemote(SESSION, { old_draft: "B", new_draft: "C" });
    await flushRenderQueue();

    expect(store.read(SESSION)).toBe("C");
    expect(textarea().value).toBe("C");
  });

  it("applies a same-frame clear after an accepted peer update", async () => {
    mount("A");
    store.applyRemote(SESSION, { old_draft: "A", new_draft: "B" });
    store.applyRemote(SESSION, { old_draft: "B", new_draft: "" });
    await flushRenderQueue();

    expect(store.read(SESSION)).toBe("");
    expect(textarea().value).toBe("");
  });

  it("accepts sender-excluded non-contiguous compare-and-swap updates", async () => {
    mount("A");
    store.write(SESSION, "A");
    store.applyRemote(SESSION, { old_draft: "A", new_draft: "B" });
    store.write(SESSION, "B");
    store.applyRemote(SESSION, { old_draft: "B", new_draft: "C" });
    await flushRenderQueue();

    expect(textarea().value).toBe("C");
  });

  it("preserves a locally divergent draft", async () => {
    mount("server text");
    fill(textarea(), "local text");
    await flushRenderQueue();
    store.applyRemote(SESSION, {
      old_draft: "server text",
      new_draft: "peer text",
    });
    await flushRenderQueue();

    expect(store.read(SESSION)).toBe("local text");
    expect(textarea().value).toBe("local text");
  });

  it("preserves absent-composer compare-and-swap results across remount", () => {
    store.ensure("blank", "");
    store.ensure("equal", "A");
    store.ensure("divergent", "local");
    store.applyRemote("blank", { old_draft: "A", new_draft: "B" });
    store.applyRemote("equal", { old_draft: "A", new_draft: "B" });
    store.applyRemote("divergent", { old_draft: "A", new_draft: "B" });

    mount(undefined, "blank");
    expect(textarea().value).toBe("B");
    render(null, container);
    mount(undefined, "equal");
    expect(textarea().value).toBe("B");
    render(null, container);
    mount(undefined, "divergent");
    expect(textarea().value).toBe("local");
  });

  it("reflects controls before render, between render and layout, and after registration", async () => {
    store.applyRemote("before", { old_draft: "A", new_draft: "B" });
    mount(undefined, "before");
    expect(textarea().value).toBe("B");

    render(null, container);
    const betweenStore = createOrdinaryDraftStore();
    render(
      <>
        {ordinaryInput(betweenStore, sent, {
          sessionId: "between",
          serverDraft: "A",
        })}
        <RemoteUpdate
          store={betweenStore}
          sessionId="between"
          oldDraft="A"
          newDraft="B"
        />
      </>,
      container,
    );
    await flushRenderQueue();
    expect(textarea().value).toBe("B");

    render(null, container);
    const afterStore = createOrdinaryDraftStore();
    render(
      ordinaryInput(afterStore, sent, { sessionId: "after", serverDraft: "A" }),
      container,
    );
    afterStore.applyRemote("after", { old_draft: "A", new_draft: "B" });
    await flushRenderQueue();
    expect(textarea().value).toBe("B");
  });
});

function RemoteUpdate({
  store,
  sessionId,
  oldDraft,
  newDraft,
}: {
  store: OrdinaryDraftStore;
  sessionId: string;
  oldDraft: string;
  newDraft: string;
}) {
  store.applyRemote(sessionId, { old_draft: oldDraft, new_draft: newDraft });
  return null;
}
