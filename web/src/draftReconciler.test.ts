import { describe, expect, it } from "vitest";
import {
  CREATE_DELAY_MS,
  DRAFT_SAVE_DELAY_MS,
  createDraftState,
  createProjectKey,
  isTombstoned,
  reduceDraft,
  selectDraftForm,
  tombstonedTids,
  type DraftContent,
  type DraftEffect,
  type DraftEvent,
  type DraftForm,
  type DraftSlotState,
  type DraftState,
  type FormDefaults,
  type ImageAttachment,
  type ProjectIdentity,
  type ProjectKey,
  type TaskObservation,
  type TaskSnapshot,
  type UuidBinding,
} from "./draftReconciler";

const PROJECT_A: ProjectIdentity = {
  workspace: "workspace-alpha",
  projectPath: "/projects/alpha",
};
const PROJECT_B: ProjectIdentity = {
  workspace: "workspace-alpha",
  projectPath: "/projects/bravo",
};
const KEY_A = createProjectKey(PROJECT_A.workspace, PROJECT_A.projectPath);
const KEY_B = createProjectKey(PROJECT_B.workspace, PROJECT_B.projectPath);

const DEFAULTS_A: FormDefaults = {
  entryPoint: "entry-alpha",
  agent: "agent-alpha",
};
const DEFAULTS_B: FormDefaults = {
  entryPoint: "entry-bravo",
  agent: "agent-bravo",
};
const CUSTOM_DEFAULTS_A: FormDefaults = {
  entryPoint: "entry-alpha-custom",
  agent: "agent-alpha-custom",
};
const PERSISTED_DEFAULTS_A: FormDefaults = {
  entryPoint: "entry-persisted-alpha",
  agent: "agent-persisted-alpha",
};
const PERSISTED_DEFAULTS_B: FormDefaults = {
  entryPoint: "entry-persisted-bravo",
  agent: "agent-persisted-bravo",
};

const UUID_A = "11111111-1111-4111-8111-111111111111";
const UUID_B = "22222222-2222-4222-8222-222222222222";
const UUID_IMAGE = "33333333-3333-4333-8333-333333333333";
const UUID_PERSISTED_A = "44444444-4444-4444-8444-444444444444";
const UUID_PERSISTED_B = "55555555-5555-4555-8555-555555555555";
const UUID_PERSISTED_RETURN = "66666666-6666-4666-8666-666666666666";
const UUID_PEER = "77777777-7777-4777-8777-777777777777";
const UUID_ACTIVE = "88888888-8888-4888-8888-888888888888";
const UUID_WRONG = "99999999-9999-4999-8999-999999999999";

const IMAGE_ONE: ImageAttachment = {
  id: "image-one",
  dataURL: "data:image/png;base64,aW1hZ2Utb25l",
  base64: "aW1hZ2Utb25l",
  mediaType: "image/png",
};
const IMAGE_TWO: ImageAttachment = {
  id: "image-two",
  dataURL: "data:image/jpeg;base64,aW1hZ2UtdHdv",
  base64: "aW1hZ2UtdHdv",
  mediaType: "image/jpeg",
};

type Effect<T extends DraftEffect["type"]> = Extract<DraftEffect, { type: T }>;
type Editing = Extract<DraftSlotState["desired"], { kind: "editing" }>;
type Submitting = Extract<DraftSlotState["desired"], { kind: "submitting" }>;
type SlotOptions = Pick<
  DraftSlotState,
  | "observed"
  | "desired"
  | "remote"
  | "formVersion"
  | "createSchedule"
  | "saveSchedule"
> & { historicalGeneration?: string | null };

interface TraceStep {
  label: string;
  event: DraftEvent;
  state: DraftState;
  effects: readonly DraftEffect[];
  assert?: (state: DraftState, effects: readonly DraftEffect[]) => void;
}

function form(text: string, defaults: FormDefaults = DEFAULTS_A): DraftForm {
  return { text, ...defaults };
}

function editing(uuid: string, draft: DraftForm): Editing {
  return { kind: "editing", uuid, ...draft };
}

function submitting(
  uuid: string,
  draft: DraftForm,
  images: readonly ImageAttachment[],
  delivery: Submitting["delivery"],
): Submitting {
  return { kind: "submitting", uuid, ...draft, images, delivery };
}

function expectedSlot(
  project: ProjectIdentity,
  defaults: FormDefaults,
  options: Partial<SlotOptions> = {},
): DraftSlotState {
  const copiedDefaults = { ...defaults };
  return {
    project: { ...project },
    defaults: copiedDefaults,
    observed: options.observed ?? form("", copiedDefaults),
    desired: options.desired ?? { kind: "none" },
    remote: options.remote ?? { kind: "absent" },
    formVersion: options.formVersion ?? 0,
    createSchedule: options.createSchedule ?? null,
    saveSchedule: options.saveSchedule ?? null,
  };
}

function stateOf(
  entries: readonly (readonly [ProjectKey, DraftSlotState])[],
  uuidBindings: readonly UuidBinding[] = [],
): DraftState {
  const slots: Record<ProjectKey, DraftSlotState> = {};
  for (const [key, slot] of entries) slots[key] = slot;
  return { slots, uuidBindings };
}

function stateA(
  options: Partial<SlotOptions> = {},
  defaults: FormDefaults = DEFAULTS_A,
  uuidBindings?: readonly UuidBinding[],
): DraftState {
  const slot = expectedSlot(PROJECT_A, defaults, options);
  return stateOf(
    [[KEY_A, slot]],
    uuidBindings ?? inferredUuidBindings([[KEY_A, slot, options]]),
  );
}

function stateAB(
  alpha: Partial<SlotOptions> = {},
  bravo: Partial<SlotOptions> = {},
  uuidBindings?: readonly UuidBinding[],
): DraftState {
  const alphaSlot = expectedSlot(PROJECT_A, DEFAULTS_A, alpha);
  const bravoSlot = expectedSlot(PROJECT_B, DEFAULTS_B, bravo);
  return stateOf(
    [
      [KEY_A, alphaSlot],
      [KEY_B, bravoSlot],
    ],
    uuidBindings ??
      inferredUuidBindings([
        [KEY_A, alphaSlot, alpha],
        [KEY_B, bravoSlot, bravo],
      ]),
  );
}

function inferredUuidBindings(
  entries: readonly (readonly [
    ProjectKey,
    DraftSlotState,
    Partial<SlotOptions>,
  ])[],
): readonly UuidBinding[] {
  return entries.flatMap(([projectKey, slot, options]) => {
    const uuid = options.historicalGeneration;
    if (uuid === undefined || uuid === null) return [];
    const tid =
      slot.remote.kind === "present" &&
      (slot.remote.generation === null || slot.remote.generation === uuid)
        ? slot.remote.tid
        : null;
    return [{ uuid, projectKey, tid }];
  });
}

function initialA(): DraftState {
  return createDraftState([{ project: PROJECT_A, defaults: DEFAULTS_A }]);
}

function initialAB(): DraftState {
  return createDraftState([
    { project: PROJECT_A, defaults: DEFAULTS_A },
    { project: PROJECT_B, defaults: DEFAULTS_B },
  ]);
}

function pendingSnapshot(
  tid: number,
  draft: DraftForm,
  flags: Partial<
    Pick<TaskSnapshot, "active" | "processing" | "hasMessages">
  > = {},
): TaskSnapshot {
  return {
    tid,
    ...draft,
    active: false,
    processing: false,
    hasMessages: false,
    ...flags,
  };
}

function taskObservation(
  tid: number,
  fields: Omit<TaskObservation, "tid"> = {},
): TaskObservation {
  return { tid, ...fields };
}

function content(
  text: string,
  images: readonly ImageAttachment[] = [],
): DraftContent {
  return { text, images };
}

function scheduleCreate(
  projectKey: ProjectKey,
  generation: string,
): Effect<"schedule-create"> {
  return {
    type: "schedule-create",
    projectKey,
    generation,
    delayMs: CREATE_DELAY_MS,
  };
}

function cancelCreate(
  projectKey: ProjectKey,
  generation: string,
): Effect<"cancel-create-schedule"> {
  return { type: "cancel-create-schedule", projectKey, generation };
}

function createTask(
  projectKey: ProjectKey,
  correlationId: string,
  entryPoint: string,
  agent: string,
  taskContent: DraftContent | null,
): Effect<"create-task"> {
  return {
    type: "create-task",
    projectKey,
    correlationId,
    entryPoint,
    agent,
    content: taskContent,
  };
}

function ensureSave(
  projectKey: ProjectKey,
  tid: number,
  formVersion: number,
): Effect<"ensure-draft-save"> {
  return {
    type: "ensure-draft-save",
    projectKey,
    tid,
    formVersion,
    delayMs: DRAFT_SAVE_DELAY_MS,
  };
}

function cancelSave(
  projectKey: ProjectKey,
  tid: number,
  formVersion: number,
): Effect<"cancel-draft-save"> {
  return { type: "cancel-draft-save", projectKey, tid, formVersion };
}

function setEntryPoint(
  projectKey: ProjectKey,
  tid: number,
  entryPoint: string,
): Effect<"set-entry-point"> {
  return { type: "set-entry-point", projectKey, tid, entryPoint };
}

function setAgent(
  projectKey: ProjectKey,
  tid: number,
  agent: string,
): Effect<"set-agent"> {
  return { type: "set-agent", projectKey, tid, agent };
}

function setDraft(
  projectKey: ProjectKey,
  tid: number,
  text: string,
  formVersion: number,
): Effect<"set-draft"> {
  return { type: "set-draft", projectKey, tid, text, formVersion };
}

function projectDraft(
  projectKey: ProjectKey,
  tid: number,
  draft: DraftForm,
  formVersion: number,
): Effect<"project-draft"> {
  return { type: "project-draft", projectKey, tid, form: draft, formVersion };
}

function deleteTask(
  projectKey: ProjectKey,
  tid: number,
): Effect<"delete-task"> {
  return { type: "delete-task", projectKey, tid };
}

function draftReady(
  projectKey: ProjectKey,
  tid: number,
  generation: string,
): Effect<"draft-ready"> {
  return { type: "draft-ready", projectKey, tid, generation };
}

function sendFirstMessage(
  projectKey: ProjectKey,
  tid: number,
  message: DraftContent,
): Effect<"send-first-message"> {
  return { type: "send-first-message", projectKey, tid, content: message };
}

function releaseTask(
  projectKey: ProjectKey,
  tid: number,
): Effect<"release-task"> {
  return { type: "release-task", projectKey, tid };
}

function trace(initial: DraftState, steps: readonly TraceStep[]): DraftState {
  let state = initial;
  let uuidBindings = initial.uuidBindings;
  for (const step of steps) {
    const result = reduceDraft(state, step.event);
    uuidBindings =
      step.event.type === "connection-reset"
        ? []
        : mergeUuidBindings(uuidBindings, step.state.uuidBindings);
    expect(result.state, `${step.label}: state`).toEqual({
      ...step.state,
      uuidBindings,
    });
    expect(result.effects, `${step.label}: effects`).toEqual(step.effects);
    step.assert?.(result.state, result.effects);
    state = result.state;
  }
  return state;
}

function mergeUuidBindings(
  previous: readonly UuidBinding[],
  current: readonly UuidBinding[],
): readonly UuidBinding[] {
  const merged = [...previous];
  for (const binding of current) {
    const index = merged.findIndex(
      (candidate) => candidate.uuid === binding.uuid,
    );
    if (index === -1) {
      merged.push(binding);
      continue;
    }
    const previousBinding = merged[index]!;
    if (previousBinding.projectKey !== binding.projectKey) {
      throw new Error("Incompatible expected UUID binding");
    }
    if (binding.tid !== null) {
      merged[index] = binding;
    }
  }
  return merged;
}

function expectReductionFailure(
  state: DraftState,
  event: DraftEvent,
  message: string,
): void {
  const before = structuredClone(state);
  expect(() => reduceDraft(state, event)).toThrow(message);
  expect(state).toEqual(before);
}

describe("draft reconciler slot initialization", () => {
  it("lazily initializes B without disturbing A's UUID-bound lifecycle", () => {
    const draft = form("A lifecycle draft");
    const afterA = trace(createDraftState(), [
      {
        label: "lazy initialize A",
        event: {
          type: "initialize-slot",
          project: PROJECT_A,
          defaults: DEFAULTS_A,
        },
        state: initialA(),
        effects: [],
      },
      {
        label: "start A generation",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: draft.text,
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, draft),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "start A creation",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, draft),
          remote: { kind: "creating", correlationId: UUID_A },
          formVersion: 1,
          historicalGeneration: UUID_A,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
      {
        label: "acknowledge A",
        event: { type: "task-created", correlationId: UUID_A, tid: 801 },
        state: stateA({
          desired: editing(UUID_A, draft),
          remote: { kind: "present", tid: 801, generation: UUID_A },
          formVersion: 1,
          historicalGeneration: UUID_A,
        }),
        effects: [
          setEntryPoint(KEY_A, 801, DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 801, DEFAULTS_A.agent),
          setDraft(KEY_A, 801, draft.text, 1),
          projectDraft(KEY_A, 801, draft, 1),
          draftReady(KEY_A, 801, UUID_A),
        ],
      },
    ]);

    trace(afterA, [
      {
        label: "lazy initialize B while A is present",
        event: {
          type: "initialize-slot",
          project: PROJECT_B,
          defaults: DEFAULTS_B,
        },
        state: stateAB({
          desired: editing(UUID_A, draft),
          remote: { kind: "present", tid: 801, generation: UUID_A },
          formVersion: 1,
          historicalGeneration: UUID_A,
        }),
        effects: [],
        assert: (state) => {
          expect(state.slots[KEY_A]).toBe(afterA.slots[KEY_A]);
          expect(state.uuidBindings).toBe(afterA.uuidBindings);
          expect(state.slots[KEY_B]).toEqual(
            expectedSlot(PROJECT_B, DEFAULTS_B),
          );
        },
      },
    ]);
  });

  it("leaves an initialized slot unchanged when defaults change", () => {
    const before = initialA();

    trace(before, [
      {
        label: "repeat A initialization with changed defaults",
        event: {
          type: "initialize-slot",
          project: PROJECT_A,
          defaults: CUSTOM_DEFAULTS_A,
        },
        state: before,
        effects: [],
        assert: (state) => {
          expect(state).toBe(before);
        },
      },
    ]);
  });

  it("reinitializes a fresh idle slot after connection reset", () => {
    const prior = form("pre-reset draft", CUSTOM_DEFAULTS_A);

    trace(
      stateA(
        {
          observed: prior,
          desired: editing(UUID_A, prior),
          remote: { kind: "present", tid: 802, generation: UUID_A },
          formVersion: 6,
          saveSchedule: { tid: 802, formVersion: 6 },
          historicalGeneration: UUID_A,
        },
        CUSTOM_DEFAULTS_A,
      ),
      [
        {
          label: "connection reset clears initialized slots and UUID history",
          event: { type: "connection-reset" },
          state: { slots: {}, uuidBindings: [] },
          effects: [],
        },
        {
          label: "reinitialize A after reset",
          event: {
            type: "initialize-slot",
            project: PROJECT_A,
            defaults: DEFAULTS_A,
          },
          state: initialA(),
          effects: [],
        },
      ],
    );
  });
});

describe("draft reconciler creation and replacement", () => {
  it("schedules one empty creation and dispatches it only when its timer is due", () => {
    trace(initialA(), [
      {
        label: "first edit",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "first",
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("first")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "edit while creation remains scheduled",
        event: { type: "edit-text", projectKey: KEY_A, text: "second" },
        state: stateA({
          desired: editing(UUID_A, form("second")),
          formVersion: 2,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [],
      },
      {
        label: "matching create timer",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("second")),
          remote: { kind: "creating", correlationId: UUID_A },
          formVersion: 2,
          historicalGeneration: UUID_A,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
      {
        label: "repeated create timer",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("second")),
          remote: { kind: "creating", correlationId: UUID_A },
          formVersion: 2,
          historicalGeneration: UUID_A,
        }),
        effects: [],
      },
    ]);
  });

  it("cancels a cleared generation, ignores its stale timer, and preserves defaults for B", () => {
    const originalObserved = form("");

    const state = trace(initialA(), [
      {
        label: "change entry point while blank",
        event: {
          type: "change-entry-point",
          projectKey: KEY_A,
          entryPoint: CUSTOM_DEFAULTS_A.entryPoint,
        },
        state: stateA(
          { observed: originalObserved },
          { entryPoint: CUSTOM_DEFAULTS_A.entryPoint, agent: DEFAULTS_A.agent },
        ),
        effects: [],
      },
      {
        label: "change agent while blank",
        event: {
          type: "change-agent",
          projectKey: KEY_A,
          agent: CUSTOM_DEFAULTS_A.agent,
        },
        state: stateA({ observed: originalObserved }, CUSTOM_DEFAULTS_A),
        effects: [],
      },
      {
        label: "edit A",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "draft A",
          uuid: UUID_A,
        },
        state: stateA(
          {
            observed: originalObserved,
            desired: editing(UUID_A, form("draft A", CUSTOM_DEFAULTS_A)),
            formVersion: 1,
            createSchedule: UUID_A,
            historicalGeneration: UUID_A,
          },
          CUSTOM_DEFAULTS_A,
        ),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "clear A before its timer",
        event: { type: "clear", projectKey: KEY_A },
        state: stateA(
          {
            observed: originalObserved,
            formVersion: 2,
            historicalGeneration: UUID_A,
          },
          CUSTOM_DEFAULTS_A,
        ),
        effects: [cancelCreate(KEY_A, UUID_A)],
      },
      {
        label: "stale A timer",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA(
          {
            observed: originalObserved,
            formVersion: 2,
            historicalGeneration: UUID_A,
          },
          CUSTOM_DEFAULTS_A,
        ),
        effects: [],
      },
      {
        label: "retype with fresh B",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "draft B",
          uuid: UUID_B,
        },
        state: stateA(
          {
            observed: originalObserved,
            desired: editing(UUID_B, form("draft B", CUSTOM_DEFAULTS_A)),
            formVersion: 3,
            createSchedule: UUID_B,
            historicalGeneration: UUID_B,
          },
          CUSTOM_DEFAULTS_A,
        ),
        effects: [scheduleCreate(KEY_A, UUID_B)],
      },
    ]);

    expect(selectDraftForm(state, KEY_A)).toEqual(
      form("draft B", CUSTOM_DEFAULTS_A),
    );
  });

  it("tombstones an acknowledged A while B waits for A deletion", () => {
    trace(initialA(), [
      {
        label: "edit A",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "draft A",
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("draft A")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "start empty A creation",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("draft A")),
          remote: { kind: "creating", correlationId: UUID_A },
          formVersion: 1,
          historicalGeneration: UUID_A,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
      {
        label: "clear A while it is creating",
        event: { type: "clear", projectKey: KEY_A },
        state: stateA({
          formVersion: 2,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [],
      },
      {
        label: "edit B while A is creating",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "draft B",
          uuid: UUID_B,
        },
        state: stateA({
          desired: editing(UUID_B, form("draft B")),
          formVersion: 3,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_B,
        }),
        effects: [],
      },
      {
        label: "A creation acknowledgement",
        event: { type: "task-created", correlationId: UUID_A, tid: 101 },
        state: stateA({
          desired: editing(UUID_B, form("draft B")),
          formVersion: 3,
          remote: { kind: "deleting", tid: 101 },
          historicalGeneration: UUID_B,
        }),
        effects: [deleteTask(KEY_A, 101)],
        assert: (state, effects) => {
          expect(tombstonedTids(state)).toEqual([101]);
          expect(isTombstoned(state, 101)).toBe(true);
          expect(
            effects.filter((effect) => effect.type === "delete-task"),
          ).toHaveLength(1);
        },
      },
      {
        label: "premature B timer",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_B,
        },
        state: stateA({
          desired: editing(UUID_B, form("draft B")),
          formVersion: 3,
          remote: { kind: "deleting", tid: 101 },
          historicalGeneration: UUID_B,
        }),
        effects: [],
      },
      {
        label: "A deletion acknowledgement",
        event: { type: "task-deleted", tid: 101 },
        state: stateA({
          desired: editing(UUID_B, form("draft B")),
          formVersion: 3,
          createSchedule: UUID_B,
          historicalGeneration: UUID_B,
        }),
        effects: [scheduleCreate(KEY_A, UUID_B)],
      },
    ]);
  });

  it("deletes a late-created A after clear and leaves an absent blank slot", () => {
    const state = trace(initialA(), [
      {
        label: "edit A",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "draft A",
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("draft A")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "start A creation",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("draft A")),
          formVersion: 1,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
      {
        label: "clear while creating",
        event: { type: "clear", projectKey: KEY_A },
        state: stateA({
          formVersion: 2,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [],
      },
      {
        label: "late A acknowledgement",
        event: { type: "task-created", correlationId: UUID_A, tid: 102 },
        state: stateA({
          formVersion: 2,
          remote: { kind: "deleting", tid: 102 },
          historicalGeneration: UUID_A,
        }),
        effects: [deleteTask(KEY_A, 102)],
      },
      {
        label: "A deletion acknowledgement",
        event: { type: "task-deleted", tid: 102 },
        state: stateA({ formVersion: 2, historicalGeneration: UUID_A }),
        effects: [],
      },
    ]);

    expect(selectDraftForm(state, KEY_A)).toEqual(form(""));
    expect(tombstonedTids(state)).toEqual([]);
  });

  it("deletes a present A before it can create B", () => {
    trace(initialA(), [
      {
        label: "edit A",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "draft A",
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("draft A")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "start A creation",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("draft A")),
          formVersion: 1,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
      {
        label: "current A acknowledgement",
        event: { type: "task-created", correlationId: UUID_A, tid: 103 },
        state: stateA({
          desired: editing(UUID_A, form("draft A")),
          formVersion: 1,
          remote: { kind: "present", tid: 103, generation: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [
          setEntryPoint(KEY_A, 103, DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 103, DEFAULTS_A.agent),
          setDraft(KEY_A, 103, "draft A", 1),
          projectDraft(KEY_A, 103, form("draft A"), 1),
          draftReady(KEY_A, 103, UUID_A),
        ],
      },
      {
        label: "clear present A",
        event: { type: "clear", projectKey: KEY_A },
        state: stateA({
          formVersion: 2,
          remote: { kind: "deleting", tid: 103 },
          historicalGeneration: UUID_A,
        }),
        effects: [deleteTask(KEY_A, 103)],
      },
      {
        label: "edit B while A is tombstoned",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "draft B",
          uuid: UUID_B,
        },
        state: stateA({
          desired: editing(UUID_B, form("draft B")),
          formVersion: 3,
          remote: { kind: "deleting", tid: 103 },
          historicalGeneration: UUID_B,
        }),
        effects: [],
      },
      {
        label: "B timer before A deletion",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_B,
        },
        state: stateA({
          desired: editing(UUID_B, form("draft B")),
          formVersion: 3,
          remote: { kind: "deleting", tid: 103 },
          historicalGeneration: UUID_B,
        }),
        effects: [],
      },
      {
        label: "A deletion acknowledgement",
        event: { type: "task-deleted", tid: 103 },
        state: stateA({
          desired: editing(UUID_B, form("draft B")),
          formVersion: 3,
          createSchedule: UUID_B,
          historicalGeneration: UUID_B,
        }),
        effects: [scheduleCreate(KEY_A, UUID_B)],
      },
      {
        label: "B timer after A deletion",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_B,
        },
        state: stateA({
          desired: editing(UUID_B, form("draft B")),
          formVersion: 3,
          remote: { kind: "creating", correlationId: UUID_B },
          historicalGeneration: UUID_B,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_B,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
    ]);
  });
});

describe("draft reconciler submission", () => {
  it("atomically creates a submitted text draft before its create timer", () => {
    trace(initialA(), [
      {
        label: "edit draft",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "send this",
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("send this")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "submit before create timer",
        event: { type: "submit", projectKey: KEY_A, images: [] },
        state: stateA({
          desired: submitting(UUID_A, form("send this"), [], "atomic-create"),
          formVersion: 1,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [
          cancelCreate(KEY_A, UUID_A),
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            content("send this"),
          ),
        ],
        assert: (_state, effects) => {
          expect(
            effects.filter((effect) => effect.type === "create-task"),
          ).toEqual([
            createTask(
              KEY_A,
              UUID_A,
              DEFAULTS_A.entryPoint,
              DEFAULTS_A.agent,
              content("send this"),
            ),
          ]);
          expect(
            effects.filter((effect) => effect.type === "send-first-message"),
          ).toEqual([]);
          expect(
            effects.filter(
              (effect) =>
                effect.type === "set-draft" && effect.text.trim().length > 0,
            ),
          ).toEqual([]);
        },
      },
      {
        label: "stale create timer after atomic submit",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: submitting(UUID_A, form("send this"), [], "atomic-create"),
          formVersion: 1,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [],
      },
      {
        label:
          "atomic creation acknowledgement hands off without draft persistence",
        event: { type: "task-created", correlationId: UUID_A, tid: 106 },
        state: stateA({ formVersion: 2, historicalGeneration: UUID_A }),
        effects: [releaseTask(KEY_A, 106)],
        assert: (state, effects) => {
          expect(state.slots[KEY_A]?.desired).toEqual({ kind: "none" });
          expect(state.slots[KEY_A]?.remote).toEqual({ kind: "absent" });
          expect(
            effects.filter(
              (effect) =>
                effect.type === "set-draft" && effect.text.trim().length > 0,
            ),
          ).toEqual([]);
          expect(
            effects.filter((effect) => effect.type === "send-first-message"),
          ).toEqual([]);
        },
      },
    ]);
  });

  it("atomically creates an image-only submission with its exact attachments", () => {
    trace(initialA(), [
      {
        label: "submit image-only draft",
        event: {
          type: "submit",
          projectKey: KEY_A,
          images: [IMAGE_ONE, IMAGE_TWO],
          uuid: UUID_IMAGE,
        },
        state: stateA({
          desired: submitting(
            UUID_IMAGE,
            form(""),
            [IMAGE_ONE, IMAGE_TWO],
            "atomic-create",
          ),
          formVersion: 1,
          remote: { kind: "creating", correlationId: UUID_IMAGE },
          historicalGeneration: UUID_IMAGE,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_IMAGE,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            content("", [IMAGE_ONE, IMAGE_TWO]),
          ),
        ],
      },
    ]);
  });

  it("waits for the empty creation acknowledgement before sending a submitted draft", () => {
    trace(initialA(), [
      {
        label: "edit draft",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "queued message",
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("queued message")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "start empty task creation",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("queued message")),
          formVersion: 1,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
      {
        label: "submit while empty creation is in flight",
        event: { type: "submit", projectKey: KEY_A, images: [IMAGE_ONE] },
        state: stateA({
          desired: submitting(
            UUID_A,
            form("queued message"),
            [IMAGE_ONE],
            "send-when-present",
          ),
          formVersion: 1,
          remote: { kind: "creating", correlationId: UUID_A },
          historicalGeneration: UUID_A,
        }),
        effects: [],
      },
      {
        label: "matching creation acknowledgement",
        event: { type: "task-created", correlationId: UUID_A, tid: 104 },
        state: stateA({ formVersion: 2, historicalGeneration: UUID_A }),
        effects: [
          setEntryPoint(KEY_A, 104, DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 104, DEFAULTS_A.agent),
          projectDraft(KEY_A, 104, form(""), 1),
          setDraft(KEY_A, 104, "", 1),
          sendFirstMessage(KEY_A, 104, content("queued message", [IMAGE_ONE])),
          releaseTask(KEY_A, 104),
        ],
        assert: (state, effects) => {
          expect(state.slots[KEY_A]?.desired).toEqual({ kind: "none" });
          expect(state.slots[KEY_A]?.remote).toEqual({ kind: "absent" });
          expect(
            effects.filter((effect) => effect.type === "send-first-message"),
          ).toHaveLength(1);
          expect(
            effects.filter((effect) => effect.type === "set-draft"),
          ).toEqual([setDraft(KEY_A, 104, "", 1)]);
        },
      },
    ]);
  });

  it("submits an adopted pending task without creating another task", () => {
    const persisted = form("persisted message", PERSISTED_DEFAULTS_A);

    trace(initialA(), [
      {
        label: "adopt persisted task",
        event: {
          type: "adopt-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_A,
          snapshot: pendingSnapshot(105, persisted),
        },
        state: stateA(
          {
            observed: persisted,
            desired: editing(UUID_PERSISTED_A, persisted),
            formVersion: 1,
            remote: { kind: "present", tid: 105, generation: null },
            historicalGeneration: UUID_PERSISTED_A,
          },
          PERSISTED_DEFAULTS_A,
        ),
        effects: [],
      },
      {
        label: "submit adopted task",
        event: { type: "submit", projectKey: KEY_A, images: [] },
        state: stateA(
          { formVersion: 2, historicalGeneration: UUID_PERSISTED_A },
          PERSISTED_DEFAULTS_A,
        ),
        effects: [
          setEntryPoint(KEY_A, 105, PERSISTED_DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 105, PERSISTED_DEFAULTS_A.agent),
          projectDraft(KEY_A, 105, form("", PERSISTED_DEFAULTS_A), 1),
          setDraft(KEY_A, 105, "", 1),
          sendFirstMessage(KEY_A, 105, content("persisted message")),
          releaseTask(KEY_A, 105),
        ],
        assert: (_state, effects) => {
          expect(
            effects.filter((effect) => effect.type === "create-task"),
          ).toEqual([]);
        },
      },
    ]);
  });
});

describe("draft reconciler acknowledgement, synchronization, and saves", () => {
  it("synchronizes a current acknowledgement and deletes a stale acknowledgement without projecting it", () => {
    trace(
      stateA({
        desired: editing(UUID_A, form("current acknowledgement")),
        remote: { kind: "creating", correlationId: UUID_A },
        formVersion: 7,
        historicalGeneration: UUID_A,
      }),
      [
        {
          label: "current creation acknowledgement",
          event: { type: "task-created", correlationId: UUID_A, tid: 200 },
          state: stateA({
            desired: editing(UUID_A, form("current acknowledgement")),
            remote: { kind: "present", tid: 200, generation: UUID_A },
            formVersion: 7,
            historicalGeneration: UUID_A,
          }),
          effects: [
            setEntryPoint(KEY_A, 200, DEFAULTS_A.entryPoint),
            setAgent(KEY_A, 200, DEFAULTS_A.agent),
            setDraft(KEY_A, 200, "current acknowledgement", 7),
            projectDraft(KEY_A, 200, form("current acknowledgement"), 7),
            draftReady(KEY_A, 200, UUID_A),
          ],
        },
      ],
    );

    trace(
      stateA({
        desired: editing(UUID_B, form("desired B")),
        remote: { kind: "creating", correlationId: UUID_A },
        formVersion: 8,
        historicalGeneration: UUID_B,
      }),
      [
        {
          label: "stale A creation acknowledgement",
          event: { type: "task-created", correlationId: UUID_A, tid: 201 },
          state: stateA({
            desired: editing(UUID_B, form("desired B")),
            remote: { kind: "deleting", tid: 201 },
            formVersion: 8,
            historicalGeneration: UUID_B,
          }),
          effects: [deleteTask(KEY_A, 201)],
          assert: (_state, effects) => {
            expect(
              effects.some(
                (effect) =>
                  effect.type === "project-draft" ||
                  effect.type === "draft-ready",
              ),
            ).toBe(false);
          },
        },
      ],
    );
  });

  it("merges peer observations field-wise, advances their baseline, and saves the resulting form", () => {
    const priorObserved: DraftForm = {
      text: "baseline text",
      entryPoint: "entry-observed",
      agent: "agent-observed",
    };
    const locallyDiverged: DraftForm = {
      text: "baseline text",
      entryPoint: "entry-observed",
      agent: "agent-local",
    };
    const peerSnapshot: DraftForm = {
      text: "peer text",
      entryPoint: "entry-peer",
      agent: "agent-peer",
    };
    const merged: DraftForm = {
      text: "peer text",
      entryPoint: "entry-peer",
      agent: "agent-local",
    };
    const mergedDefaults: FormDefaults = {
      entryPoint: "entry-peer",
      agent: "agent-local",
    };
    const finalDefaults: FormDefaults = {
      entryPoint: "entry-peer",
      agent: "agent-final",
    };
    const afterLocalConfig: DraftForm = {
      text: "peer text",
      ...finalDefaults,
    };
    const afterLocalText: DraftForm = {
      text: "local final text",
      ...finalDefaults,
    };

    trace(
      stateA(
        {
          observed: priorObserved,
          desired: editing(UUID_PEER, locallyDiverged),
          remote: { kind: "present", tid: 202, generation: UUID_PEER },
          formVersion: 4,
          saveSchedule: { tid: 202, formVersion: 4 },
          historicalGeneration: UUID_PEER,
        },
        { entryPoint: "entry-observed", agent: "agent-local" },
      ),
      [
        {
          label: "peer observation merges pristine text and entry point",
          event: {
            type: "task-observed",
            projectKey: KEY_A,
            observation: taskObservation(202, peerSnapshot),
          },
          state: stateA(
            {
              observed: peerSnapshot,
              desired: editing(UUID_PEER, merged),
              remote: { kind: "present", tid: 202, generation: UUID_PEER },
              formVersion: 5,
              saveSchedule: { tid: 202, formVersion: 5 },
              historicalGeneration: UUID_PEER,
            },
            mergedDefaults,
          ),
          effects: [
            projectDraft(KEY_A, 202, merged, 5),
            ensureSave(KEY_A, 202, 5),
          ],
        },
        {
          label: "local config change starts a new versioned save",
          event: {
            type: "change-agent",
            projectKey: KEY_A,
            agent: finalDefaults.agent,
          },
          state: stateA(
            {
              observed: peerSnapshot,
              desired: editing(UUID_PEER, afterLocalConfig),
              remote: { kind: "present", tid: 202, generation: UUID_PEER },
              formVersion: 6,
              saveSchedule: { tid: 202, formVersion: 6 },
              historicalGeneration: UUID_PEER,
            },
            finalDefaults,
          ),
          effects: [
            setAgent(KEY_A, 202, finalDefaults.agent),
            projectDraft(KEY_A, 202, afterLocalConfig, 6),
            ensureSave(KEY_A, 202, 6),
          ],
        },
        {
          label: "flush writes the reconciled current form immediately",
          event: { type: "flush", projectKey: KEY_A },
          state: stateA(
            {
              observed: peerSnapshot,
              desired: editing(UUID_PEER, afterLocalConfig),
              remote: { kind: "present", tid: 202, generation: UUID_PEER },
              formVersion: 6,
              historicalGeneration: UUID_PEER,
            },
            finalDefaults,
          ),
          effects: [
            cancelSave(KEY_A, 202, 6),
            setDraft(KEY_A, 202, "peer text", 6),
            projectDraft(KEY_A, 202, afterLocalConfig, 6),
          ],
        },
        {
          label: "ordinary local edit schedules version 7",
          event: {
            type: "edit-text",
            projectKey: KEY_A,
            text: "local final text",
          },
          state: stateA(
            {
              observed: peerSnapshot,
              desired: editing(UUID_PEER, afterLocalText),
              remote: { kind: "present", tid: 202, generation: UUID_PEER },
              formVersion: 7,
              saveSchedule: { tid: 202, formVersion: 7 },
              historicalGeneration: UUID_PEER,
            },
            finalDefaults,
          ),
          effects: [
            projectDraft(KEY_A, 202, afterLocalText, 7),
            ensureSave(KEY_A, 202, 7),
          ],
        },
        {
          label: "stale save timer",
          event: {
            type: "save-timer-due",
            projectKey: KEY_A,
            tid: 202,
            formVersion: 6,
          },
          state: stateA(
            {
              observed: peerSnapshot,
              desired: editing(UUID_PEER, afterLocalText),
              remote: { kind: "present", tid: 202, generation: UUID_PEER },
              formVersion: 7,
              saveSchedule: { tid: 202, formVersion: 7 },
              historicalGeneration: UUID_PEER,
            },
            finalDefaults,
          ),
          effects: [],
        },
        {
          label: "matching save timer",
          event: {
            type: "save-timer-due",
            projectKey: KEY_A,
            tid: 202,
            formVersion: 7,
          },
          state: stateA(
            {
              observed: peerSnapshot,
              desired: editing(UUID_PEER, afterLocalText),
              remote: { kind: "present", tid: 202, generation: UUID_PEER },
              formVersion: 7,
              historicalGeneration: UUID_PEER,
            },
            finalDefaults,
          ),
          effects: [setDraft(KEY_A, 202, "local final text", 7)],
        },
      ],
    );
  });

  it("merges explicitly empty observed fields without changing omitted fields", () => {
    const baseline: DraftForm = {
      text: "baseline text",
      entryPoint: "entry-observed",
      agent: "agent-observed",
    };
    const cases: readonly {
      label: string;
      defaults: FormDefaults;
      desired: DraftForm;
      observation: Omit<TaskObservation, "tid">;
      expectedDefaults: FormDefaults;
      expectedObserved: DraftForm;
      expectedDesired: DraftForm;
    }[] = [
      {
        label: "text",
        defaults: { entryPoint: "entry-local", agent: "agent-local" },
        desired: {
          text: "baseline text",
          entryPoint: "entry-local",
          agent: "agent-local",
        },
        observation: { text: "" },
        expectedDefaults: { entryPoint: "entry-local", agent: "agent-local" },
        expectedObserved: { ...baseline, text: "" },
        expectedDesired: {
          text: "",
          entryPoint: "entry-local",
          agent: "agent-local",
        },
      },
      {
        label: "entry point",
        defaults: {
          entryPoint: "entry-observed",
          agent: "agent-local",
        },
        desired: {
          text: "text-local",
          entryPoint: "entry-observed",
          agent: "agent-local",
        },
        observation: { entryPoint: "" },
        expectedDefaults: { entryPoint: "", agent: "agent-local" },
        expectedObserved: { ...baseline, entryPoint: "" },
        expectedDesired: {
          text: "text-local",
          entryPoint: "",
          agent: "agent-local",
        },
      },
      {
        label: "agent",
        defaults: {
          entryPoint: "entry-local",
          agent: "agent-observed",
        },
        desired: {
          text: "text-local",
          entryPoint: "entry-local",
          agent: "agent-observed",
        },
        observation: { agent: "" },
        expectedDefaults: { entryPoint: "entry-local", agent: "" },
        expectedObserved: { ...baseline, agent: "" },
        expectedDesired: {
          text: "text-local",
          entryPoint: "entry-local",
          agent: "",
        },
      },
    ];

    for (const testCase of cases) {
      trace(
        stateA(
          {
            observed: baseline,
            desired: editing(UUID_PEER, testCase.desired),
            remote: { kind: "present", tid: 207, generation: UUID_PEER },
            formVersion: 4,
            historicalGeneration: UUID_PEER,
          },
          testCase.defaults,
        ),
        [
          {
            label: `explicit empty ${testCase.label} observation`,
            event: {
              type: "task-observed",
              projectKey: KEY_A,
              observation: taskObservation(207, testCase.observation),
            },
            state: stateA(
              {
                observed: testCase.expectedObserved,
                desired: editing(UUID_PEER, testCase.expectedDesired),
                remote: {
                  kind: "present",
                  tid: 207,
                  generation: UUID_PEER,
                },
                formVersion: 5,
                historicalGeneration: UUID_PEER,
              },
              testCase.expectedDefaults,
            ),
            effects: [projectDraft(KEY_A, 207, testCase.expectedDesired, 5)],
          },
        ],
      );
    }
  });

  it("advances a diverged baseline before comparing a later observation", () => {
    const defaults: FormDefaults = {
      entryPoint: "entry-baseline",
      agent: "agent-baseline",
    };
    const originalObserved: DraftForm = {
      text: "baseline text",
      ...defaults,
    };
    const locallyDiverged: DraftForm = {
      text: "local text",
      ...defaults,
    };
    const firstPeerBaseline: DraftForm = {
      text: "peer baseline",
      ...defaults,
    };
    const secondPeerBaseline: DraftForm = {
      text: "peer follow-up",
      ...defaults,
    };

    trace(
      stateA(
        {
          observed: originalObserved,
          desired: editing(UUID_PEER, locallyDiverged),
          remote: { kind: "present", tid: 208, generation: UUID_PEER },
          formVersion: 4,
          historicalGeneration: UUID_PEER,
        },
        defaults,
      ),
      [
        {
          label: "first peer text advances the baseline but keeps local text",
          event: {
            type: "task-observed",
            projectKey: KEY_A,
            observation: taskObservation(208, {
              text: firstPeerBaseline.text,
            }),
          },
          state: stateA(
            {
              observed: firstPeerBaseline,
              desired: editing(UUID_PEER, locallyDiverged),
              remote: { kind: "present", tid: 208, generation: UUID_PEER },
              formVersion: 4,
              historicalGeneration: UUID_PEER,
            },
            defaults,
          ),
          effects: [projectDraft(KEY_A, 208, locallyDiverged, 4)],
        },
        {
          label: "local text catches up to the advanced baseline",
          event: {
            type: "edit-text",
            projectKey: KEY_A,
            text: firstPeerBaseline.text,
          },
          state: stateA(
            {
              observed: firstPeerBaseline,
              desired: editing(UUID_PEER, firstPeerBaseline),
              remote: { kind: "present", tid: 208, generation: UUID_PEER },
              formVersion: 5,
              saveSchedule: { tid: 208, formVersion: 5 },
              historicalGeneration: UUID_PEER,
            },
            defaults,
          ),
          effects: [
            projectDraft(KEY_A, 208, firstPeerBaseline, 5),
            ensureSave(KEY_A, 208, 5),
          ],
        },
        {
          label: "later peer text compares against the advanced baseline",
          event: {
            type: "task-observed",
            projectKey: KEY_A,
            observation: taskObservation(208, {
              text: secondPeerBaseline.text,
            }),
          },
          state: stateA(
            {
              observed: secondPeerBaseline,
              desired: editing(UUID_PEER, secondPeerBaseline),
              remote: { kind: "present", tid: 208, generation: UUID_PEER },
              formVersion: 6,
              saveSchedule: { tid: 208, formVersion: 6 },
              historicalGeneration: UUID_PEER,
            },
            defaults,
          ),
          effects: [
            projectDraft(KEY_A, 208, secondPeerBaseline, 6),
            ensureSave(KEY_A, 208, 6),
          ],
        },
      ],
    );
  });

  it("projects a pending observation without form fields without changing state", () => {
    const defaults: FormDefaults = {
      entryPoint: "entry-default",
      agent: "agent-default",
    };
    const observed: DraftForm = {
      text: "observed text",
      entryPoint: "entry-observed",
      agent: "agent-observed",
    };
    const desired: DraftForm = {
      text: "local text",
      entryPoint: "entry-local",
      agent: "agent-local",
    };
    const before = stateA(
      {
        observed,
        desired: editing(UUID_PEER, desired),
        remote: { kind: "present", tid: 209, generation: UUID_PEER },
        formVersion: 9,
        saveSchedule: { tid: 209, formVersion: 9 },
        historicalGeneration: UUID_PEER,
      },
      defaults,
    );

    trace(before, [
      {
        label: "pending activity flags without form fields",
        event: {
          type: "task-observed",
          projectKey: KEY_A,
          observation: taskObservation(209, {
            active: false,
            processing: false,
            hasMessages: false,
          }),
        },
        state: before,
        effects: [projectDraft(KEY_A, 209, desired, 9)],
        assert: (state) => {
          expect(state).toBe(before);
        },
      },
    ]);
  });

  it("accepts each pristine-empty field from a peer observation", () => {
    const observed: DraftForm = {
      text: "observed text",
      entryPoint: "entry-observed",
      agent: "agent-observed",
    };
    const peer: DraftForm = {
      text: "peer text",
      entryPoint: "entry-peer",
      agent: "agent-peer",
    };
    const cases: readonly {
      label: string;
      desired: DraftForm;
      merged: DraftForm;
    }[] = [
      {
        label: "text",
        desired: {
          text: "",
          entryPoint: "entry-local",
          agent: "agent-local",
        },
        merged: {
          text: peer.text,
          entryPoint: "entry-local",
          agent: "agent-local",
        },
      },
      {
        label: "entry point",
        desired: {
          text: "text-local",
          entryPoint: "",
          agent: "agent-local",
        },
        merged: {
          text: "text-local",
          entryPoint: peer.entryPoint,
          agent: "agent-local",
        },
      },
      {
        label: "agent",
        desired: {
          text: "text-local",
          entryPoint: "entry-local",
          agent: "",
        },
        merged: {
          text: "text-local",
          entryPoint: "entry-local",
          agent: peer.agent,
        },
      },
    ];

    for (const { label, desired, merged } of cases) {
      trace(
        stateA(
          {
            observed,
            desired: editing(UUID_PEER, desired),
            remote: { kind: "present", tid: 206, generation: UUID_PEER },
            formVersion: 4,
            historicalGeneration: UUID_PEER,
          },
          { entryPoint: desired.entryPoint, agent: desired.agent },
        ),
        [
          {
            label: `peer observation merges pristine empty ${label}`,
            event: {
              type: "task-observed",
              projectKey: KEY_A,
              observation: taskObservation(206, peer),
            },
            state: stateA(
              {
                observed: peer,
                desired: editing(UUID_PEER, merged),
                remote: {
                  kind: "present",
                  tid: 206,
                  generation: UUID_PEER,
                },
                formVersion: 5,
                historicalGeneration: UUID_PEER,
              },
              { entryPoint: merged.entryPoint, agent: merged.agent },
            ),
            effects: [projectDraft(KEY_A, 206, merged, 5)],
          },
        ],
      );
    }
  });

  it("cancels a scheduled save when a present draft is cleared", () => {
    const draft = form("clear me", CUSTOM_DEFAULTS_A);

    trace(
      stateA(
        {
          observed: draft,
          desired: editing(UUID_A, draft),
          remote: { kind: "present", tid: 203, generation: UUID_A },
          formVersion: 8,
          saveSchedule: { tid: 203, formVersion: 8 },
          historicalGeneration: UUID_A,
        },
        CUSTOM_DEFAULTS_A,
      ),
      [
        {
          label: "clear present draft",
          event: { type: "clear", projectKey: KEY_A },
          state: stateA(
            {
              observed: draft,
              remote: { kind: "deleting", tid: 203 },
              formVersion: 9,
              historicalGeneration: UUID_A,
            },
            CUSTOM_DEFAULTS_A,
          ),
          effects: [cancelSave(KEY_A, 203, 8), deleteTask(KEY_A, 203)],
        },
        {
          label: "stale save after clear",
          event: {
            type: "save-timer-due",
            projectKey: KEY_A,
            tid: 203,
            formVersion: 8,
          },
          state: stateA(
            {
              observed: draft,
              remote: { kind: "deleting", tid: 203 },
              formVersion: 9,
              historicalGeneration: UUID_A,
            },
            CUSTOM_DEFAULTS_A,
          ),
          effects: [],
        },
      ],
    );
  });

  it("retains desired intent and recreates after an externally deleted present draft", () => {
    const draft = form("recreate me");

    trace(
      stateA({
        observed: draft,
        desired: editing(UUID_A, draft),
        remote: { kind: "present", tid: 204, generation: UUID_A },
        formVersion: 5,
        saveSchedule: { tid: 204, formVersion: 5 },
        historicalGeneration: UUID_A,
      }),
      [
        {
          label: "external deletion acknowledgement",
          event: { type: "task-deleted", tid: 204 },
          state: stateA({
            observed: draft,
            desired: editing(UUID_A, draft),
            formVersion: 5,
            createSchedule: UUID_A,
            historicalGeneration: UUID_A,
          }),
          effects: [cancelSave(KEY_A, 204, 5), scheduleCreate(KEY_A, UUID_A)],
        },
        {
          label: "stale save after external deletion",
          event: {
            type: "save-timer-due",
            projectKey: KEY_A,
            tid: 204,
            formVersion: 5,
          },
          state: stateA({
            observed: draft,
            desired: editing(UUID_A, draft),
            formVersion: 5,
            createSchedule: UUID_A,
            historicalGeneration: UUID_A,
          }),
          effects: [],
        },
        {
          label: "recreation timer",
          event: {
            type: "create-timer-due",
            projectKey: KEY_A,
            generation: UUID_A,
          },
          state: stateA({
            observed: form(""),
            desired: editing(UUID_A, draft),
            remote: { kind: "creating", correlationId: UUID_A },
            formVersion: 5,
            historicalGeneration: UUID_A,
          }),
          effects: [
            createTask(
              KEY_A,
              UUID_A,
              DEFAULTS_A.entryPoint,
              DEFAULTS_A.agent,
              null,
            ),
          ],
        },
        {
          label: "recreated task acknowledgement rebinds its UUID",
          event: { type: "task-created", correlationId: UUID_A, tid: 206 },
          state: stateA({
            observed: form(""),
            desired: editing(UUID_A, draft),
            remote: { kind: "present", tid: 206, generation: UUID_A },
            formVersion: 5,
            historicalGeneration: UUID_A,
          }),
          effects: [
            setEntryPoint(KEY_A, 206, DEFAULTS_A.entryPoint),
            setAgent(KEY_A, 206, DEFAULTS_A.agent),
            setDraft(KEY_A, 206, draft.text, 5),
            projectDraft(KEY_A, 206, draft, 5),
            draftReady(KEY_A, 206, UUID_A),
          ],
          assert: (state) => {
            expect(state.uuidBindings).toEqual([
              { uuid: UUID_A, projectKey: KEY_A, tid: 206 },
            ]);
          },
        },
      ],
    );
  });

  it("cancels a scheduled save before submitting an owned present draft", () => {
    const draft = form("send and cancel save");

    trace(
      stateA({
        observed: draft,
        desired: editing(UUID_A, draft),
        remote: { kind: "present", tid: 205, generation: UUID_A },
        formVersion: 6,
        saveSchedule: { tid: 205, formVersion: 6 },
        historicalGeneration: UUID_A,
      }),
      [
        {
          label: "submit present draft",
          event: { type: "submit", projectKey: KEY_A, images: [] },
          state: stateA({ formVersion: 7, historicalGeneration: UUID_A }),
          effects: [
            cancelSave(KEY_A, 205, 6),
            setEntryPoint(KEY_A, 205, DEFAULTS_A.entryPoint),
            setAgent(KEY_A, 205, DEFAULTS_A.agent),
            projectDraft(KEY_A, 205, form(""), 6),
            setDraft(KEY_A, 205, "", 6),
            sendFirstMessage(KEY_A, 205, content("send and cancel save")),
            releaseTask(KEY_A, 205),
          ],
        },
        {
          label: "stale save after submit",
          event: {
            type: "save-timer-due",
            projectKey: KEY_A,
            tid: 205,
            formVersion: 6,
          },
          state: stateA({ formVersion: 7, historicalGeneration: UUID_A }),
          effects: [],
        },
      ],
    );
  });
});

describe("draft reconciler ownership boundaries", () => {
  it("releases ownership for activity-only observations", () => {
    const variants: readonly [
      string,
      number,
      Pick<TaskObservation, "active" | "processing" | "hasMessages">,
    ][] = [
      ["active", 300, { active: true }],
      ["processing", 301, { processing: true }],
      ["message-bearing", 302, { hasMessages: true }],
    ];
    const draft = form("owned draft");

    for (const [label, tid, flags] of variants) {
      trace(
        stateA({
          observed: draft,
          desired: editing(UUID_ACTIVE, draft),
          remote: { kind: "present", tid, generation: UUID_ACTIVE },
          formVersion: 7,
          saveSchedule: { tid, formVersion: 7 },
          historicalGeneration: UUID_ACTIVE,
        }),
        [
          {
            label: `${label} observation releases ownership`,
            event: {
              type: "task-observed",
              projectKey: KEY_A,
              observation: taskObservation(tid, flags),
            },
            state: stateA({
              formVersion: 8,
              historicalGeneration: UUID_ACTIVE,
            }),
            effects: [cancelSave(KEY_A, tid, 7), releaseTask(KEY_A, tid)],
            assert: (_state, effects) => {
              expect(
                effects.some(
                  (effect) =>
                    effect.type === "set-draft" ||
                    effect.type === "delete-task",
                ),
              ).toBe(false);
            },
          },
          {
            label: `${label} stale save cannot write after release`,
            event: {
              type: "save-timer-due",
              projectKey: KEY_A,
              tid,
              formVersion: 7,
            },
            state: stateA({
              formVersion: 8,
              historicalGeneration: UUID_ACTIVE,
            }),
            effects: [],
          },
          {
            label: `${label} flush cannot write or delete after release`,
            event: { type: "flush", projectKey: KEY_A },
            state: stateA({
              formVersion: 8,
              historicalGeneration: UUID_ACTIVE,
            }),
            effects: [],
          },
          {
            label: `${label} clear cannot delete after release`,
            event: { type: "clear", projectKey: KEY_A },
            state: stateA({
              formVersion: 8,
              historicalGeneration: UUID_ACTIVE,
            }),
            effects: [],
          },
        ],
      );
    }
  });

  it("releases an active tombstoned A and schedules B without discarding B", () => {
    const replacement = form("replacement while deleting");
    const bindings: readonly UuidBinding[] = [
      { uuid: UUID_A, projectKey: KEY_A, tid: 303 },
      { uuid: UUID_B, projectKey: KEY_A, tid: null },
    ];

    const afterActiveObservation = trace(
      stateA(
        {
          desired: editing(UUID_B, replacement),
          remote: { kind: "deleting", tid: 303 },
          formVersion: 4,
          historicalGeneration: UUID_B,
        },
        DEFAULTS_A,
        bindings,
      ),
      [
        {
          label: "active observation releases tombstoned A and schedules B",
          event: {
            type: "task-observed",
            projectKey: KEY_A,
            observation: taskObservation(303, { active: true }),
          },
          state: stateA(
            {
              desired: editing(UUID_B, replacement),
              formVersion: 4,
              createSchedule: UUID_B,
              historicalGeneration: UUID_B,
            },
            DEFAULTS_A,
            bindings,
          ),
          effects: [releaseTask(KEY_A, 303), scheduleCreate(KEY_A, UUID_B)],
        },
      ],
    );

    expect(selectDraftForm(afterActiveObservation, KEY_A)).toEqual(replacement);
    expectReductionFailure(
      afterActiveObservation,
      { type: "task-deleted", tid: 303 },
      "Task deletion does not match one owned task",
    );
    expectReductionFailure(
      afterActiveObservation,
      {
        type: "task-observed",
        projectKey: KEY_A,
        observation: taskObservation(303, { active: true }),
      },
      "Observation does not match an owned task",
    );
  });

  it("recreates an atomic image submission after releasing tombstoned A", () => {
    const submission = submitting(
      UUID_B,
      form("replacement message"),
      [IMAGE_ONE],
      "atomic-create",
    );
    const bindings: readonly UuidBinding[] = [
      { uuid: UUID_A, projectKey: KEY_A, tid: 304 },
      { uuid: UUID_B, projectKey: KEY_A, tid: null },
    ];

    const afterActiveObservation = trace(
      stateA(
        {
          desired: submission,
          remote: { kind: "deleting", tid: 304 },
          formVersion: 4,
          historicalGeneration: UUID_B,
        },
        DEFAULTS_A,
        bindings,
      ),
      [
        {
          label:
            "active observation releases tombstoned A and atomically creates B",
          event: {
            type: "task-observed",
            projectKey: KEY_A,
            observation: taskObservation(304, { active: true }),
          },
          state: stateA(
            {
              desired: submission,
              remote: { kind: "creating", correlationId: UUID_B },
              formVersion: 4,
              historicalGeneration: UUID_B,
            },
            DEFAULTS_A,
            bindings,
          ),
          effects: [
            releaseTask(KEY_A, 304),
            createTask(
              KEY_A,
              UUID_B,
              DEFAULTS_A.entryPoint,
              DEFAULTS_A.agent,
              content("replacement message", [IMAGE_ONE]),
            ),
          ],
          assert: (_state, effects) => {
            expect(
              effects.filter((effect) => effect.type === "create-task"),
            ).toEqual([
              createTask(
                KEY_A,
                UUID_B,
                DEFAULTS_A.entryPoint,
                DEFAULTS_A.agent,
                content("replacement message", [IMAGE_ONE]),
              ),
            ]);
            expect(
              effects.filter((effect) => effect.type === "send-first-message"),
            ).toEqual([]);
          },
        },
      ],
    );

    expectReductionFailure(
      afterActiveObservation,
      { type: "task-deleted", tid: 304 },
      "Task deletion does not match one owned task",
    );
    expectReductionFailure(
      afterActiveObservation,
      {
        type: "task-observed",
        projectKey: KEY_A,
        observation: taskObservation(304, { active: true }),
      },
      "Observation does not match an owned task",
    );

    trace(afterActiveObservation, [
      {
        label: "atomic B acknowledgement hands off without another delivery",
        event: { type: "task-created", correlationId: UUID_B, tid: 305 },
        state: stateA(
          { formVersion: 5, historicalGeneration: UUID_B },
          DEFAULTS_A,
          bindings,
        ),
        effects: [releaseTask(KEY_A, 305)],
        assert: (state, effects) => {
          expect(state.slots[KEY_A]?.desired).toEqual({ kind: "none" });
          expect(state.slots[KEY_A]?.remote).toEqual({ kind: "absent" });
          expect(
            effects.filter((effect) => effect.type === "create-task"),
          ).toEqual([]);
          expect(
            effects.filter((effect) => effect.type === "send-first-message"),
          ).toEqual([]);
        },
      },
    ]);
  });

  it("keeps two canonical project slots independent through creation and deletion", () => {
    expect(KEY_A).not.toBe(KEY_B);
    expect(createProjectKey(PROJECT_A.workspace, PROJECT_A.projectPath)).toBe(
      KEY_A,
    );

    trace(initialAB(), [
      {
        label: "edit alpha",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "alpha",
          uuid: UUID_A,
        },
        state: stateAB({
          desired: editing(UUID_A, form("alpha")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "edit bravo",
        event: {
          type: "edit-text",
          projectKey: KEY_B,
          text: "bravo",
          uuid: UUID_B,
        },
        state: stateAB(
          {
            desired: editing(UUID_A, form("alpha")),
            formVersion: 1,
            createSchedule: UUID_A,
            historicalGeneration: UUID_A,
          },
          {
            desired: editing(UUID_B, form("bravo", DEFAULTS_B)),
            formVersion: 1,
            createSchedule: UUID_B,
            historicalGeneration: UUID_B,
          },
        ),
        effects: [scheduleCreate(KEY_B, UUID_B)],
      },
      {
        label: "alpha creation timer",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateAB(
          {
            desired: editing(UUID_A, form("alpha")),
            remote: { kind: "creating", correlationId: UUID_A },
            formVersion: 1,
            historicalGeneration: UUID_A,
          },
          {
            desired: editing(UUID_B, form("bravo", DEFAULTS_B)),
            formVersion: 1,
            createSchedule: UUID_B,
            historicalGeneration: UUID_B,
          },
        ),
        effects: [
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
      {
        label: "bravo creation timer",
        event: {
          type: "create-timer-due",
          projectKey: KEY_B,
          generation: UUID_B,
        },
        state: stateAB(
          {
            desired: editing(UUID_A, form("alpha")),
            remote: { kind: "creating", correlationId: UUID_A },
            formVersion: 1,
            historicalGeneration: UUID_A,
          },
          {
            desired: editing(UUID_B, form("bravo", DEFAULTS_B)),
            remote: { kind: "creating", correlationId: UUID_B },
            formVersion: 1,
            historicalGeneration: UUID_B,
          },
        ),
        effects: [
          createTask(
            KEY_B,
            UUID_B,
            DEFAULTS_B.entryPoint,
            DEFAULTS_B.agent,
            null,
          ),
        ],
      },
      {
        label: "alpha acknowledgement",
        event: { type: "task-created", correlationId: UUID_A, tid: 401 },
        state: stateAB(
          {
            desired: editing(UUID_A, form("alpha")),
            remote: { kind: "present", tid: 401, generation: UUID_A },
            formVersion: 1,
            historicalGeneration: UUID_A,
          },
          {
            desired: editing(UUID_B, form("bravo", DEFAULTS_B)),
            remote: { kind: "creating", correlationId: UUID_B },
            formVersion: 1,
            historicalGeneration: UUID_B,
          },
        ),
        effects: [
          setEntryPoint(KEY_A, 401, DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 401, DEFAULTS_A.agent),
          setDraft(KEY_A, 401, "alpha", 1),
          projectDraft(KEY_A, 401, form("alpha"), 1),
          draftReady(KEY_A, 401, UUID_A),
        ],
      },
      {
        label: "clear alpha",
        event: { type: "clear", projectKey: KEY_A },
        state: stateAB(
          {
            remote: { kind: "deleting", tid: 401 },
            formVersion: 2,
            historicalGeneration: UUID_A,
          },
          {
            desired: editing(UUID_B, form("bravo", DEFAULTS_B)),
            remote: { kind: "creating", correlationId: UUID_B },
            formVersion: 1,
            historicalGeneration: UUID_B,
          },
        ),
        effects: [deleteTask(KEY_A, 401)],
        assert: (state) => {
          expect(tombstonedTids(state)).toEqual([401]);
          expect(isTombstoned(state, 401)).toBe(true);
          expect(isTombstoned(state, 402)).toBe(false);
        },
      },
      {
        label: "bravo acknowledgement",
        event: { type: "task-created", correlationId: UUID_B, tid: 402 },
        state: stateAB(
          {
            remote: { kind: "deleting", tid: 401 },
            formVersion: 2,
            historicalGeneration: UUID_A,
          },
          {
            desired: editing(UUID_B, form("bravo", DEFAULTS_B)),
            remote: { kind: "present", tid: 402, generation: UUID_B },
            formVersion: 1,
            historicalGeneration: UUID_B,
          },
        ),
        effects: [
          setEntryPoint(KEY_B, 402, DEFAULTS_B.entryPoint),
          setAgent(KEY_B, 402, DEFAULTS_B.agent),
          setDraft(KEY_B, 402, "bravo", 1),
          projectDraft(KEY_B, 402, form("bravo", DEFAULTS_B), 1),
          draftReady(KEY_B, 402, UUID_B),
        ],
      },
      {
        label: "clear bravo",
        event: { type: "clear", projectKey: KEY_B },
        state: stateAB(
          {
            remote: { kind: "deleting", tid: 401 },
            formVersion: 2,
            historicalGeneration: UUID_A,
          },
          {
            remote: { kind: "deleting", tid: 402 },
            formVersion: 2,
            historicalGeneration: UUID_B,
          },
        ),
        effects: [deleteTask(KEY_B, 402)],
        assert: (state) => {
          expect(tombstonedTids(state)).toEqual([401, 402]);
        },
      },
      {
        label: "alpha deletion acknowledgement",
        event: { type: "task-deleted", tid: 401 },
        state: stateAB(
          { formVersion: 2, historicalGeneration: UUID_A },
          {
            remote: { kind: "deleting", tid: 402 },
            formVersion: 2,
            historicalGeneration: UUID_B,
          },
        ),
        effects: [],
        assert: (state) => {
          expect(tombstonedTids(state)).toEqual([402]);
          expect(isTombstoned(state, 401)).toBe(false);
          expect(isTombstoned(state, 402)).toBe(true);
        },
      },
      {
        label: "bravo deletion acknowledgement",
        event: { type: "task-deleted", tid: 402 },
        state: stateAB(
          { formVersion: 2, historicalGeneration: UUID_A },
          { formVersion: 2, historicalGeneration: UUID_B },
        ),
        effects: [],
        assert: (state) => {
          expect(tombstonedTids(state)).toEqual([]);
        },
      },
    ]);
  });

  it("keeps the same display name and canonical path in different workspaces separate", () => {
    const projectInOtherWorkspace: ProjectIdentity = {
      workspace: "workspace-bravo",
      projectPath: PROJECT_A.projectPath,
    };
    const otherKey = createProjectKey(
      projectInOtherWorkspace.workspace,
      projectInOtherWorkspace.projectPath,
    );
    const otherDefaults: FormDefaults = {
      entryPoint: "entry-other-workspace",
      agent: "agent-other-workspace",
    };

    expect(otherKey).not.toBe(KEY_A);
    expect(
      createProjectKey(
        projectInOtherWorkspace.workspace,
        projectInOtherWorkspace.projectPath,
      ),
    ).toBe(otherKey);

    trace(
      createDraftState([
        { project: PROJECT_A, defaults: DEFAULTS_A },
        { project: projectInOtherWorkspace, defaults: otherDefaults },
      ]),
      [
        {
          label: "edit alpha in the first workspace",
          event: {
            type: "edit-text",
            projectKey: KEY_A,
            text: "first workspace alpha",
            uuid: UUID_A,
          },
          state: stateOf(
            [
              [
                KEY_A,
                expectedSlot(PROJECT_A, DEFAULTS_A, {
                  desired: editing(UUID_A, form("first workspace alpha")),
                  formVersion: 1,
                  createSchedule: UUID_A,
                }),
              ],
              [otherKey, expectedSlot(projectInOtherWorkspace, otherDefaults)],
            ],
            [{ uuid: UUID_A, projectKey: KEY_A, tid: null }],
          ),
          effects: [scheduleCreate(KEY_A, UUID_A)],
        },
        {
          label: "edit the identically named path in the other workspace",
          event: {
            type: "edit-text",
            projectKey: otherKey,
            text: "other workspace alpha",
            uuid: UUID_B,
          },
          state: stateOf(
            [
              [
                KEY_A,
                expectedSlot(PROJECT_A, DEFAULTS_A, {
                  desired: editing(UUID_A, form("first workspace alpha")),
                  formVersion: 1,
                  createSchedule: UUID_A,
                }),
              ],
              [
                otherKey,
                expectedSlot(projectInOtherWorkspace, otherDefaults, {
                  desired: editing(
                    UUID_B,
                    form("other workspace alpha", otherDefaults),
                  ),
                  formVersion: 1,
                  createSchedule: UUID_B,
                }),
              ],
            ],
            [
              { uuid: UUID_A, projectKey: KEY_A, tid: null },
              { uuid: UUID_B, projectKey: otherKey, tid: null },
            ],
          ),
          effects: [scheduleCreate(otherKey, UUID_B)],
        },
      ],
    );
  });
});

describe("draft reconciler persisted ownership", () => {
  it("switches stable persisted tasks by flushing and releasing A, then permits a switch back", () => {
    const persistedA = form("persisted A", PERSISTED_DEFAULTS_A);
    const editedA = form("persisted A local", PERSISTED_DEFAULTS_A);
    const persistedB = form("persisted B", PERSISTED_DEFAULTS_B);
    const returnedA = form("persisted A returned", PERSISTED_DEFAULTS_A);

    trace(initialA(), [
      {
        label: "adopt persisted A",
        event: {
          type: "adopt-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_A,
          snapshot: pendingSnapshot(501, persistedA),
        },
        state: stateA(
          {
            observed: persistedA,
            desired: editing(UUID_PERSISTED_A, persistedA),
            remote: { kind: "present", tid: 501, generation: null },
            formVersion: 1,
            historicalGeneration: UUID_PERSISTED_A,
          },
          PERSISTED_DEFAULTS_A,
        ),
        effects: [],
      },
      {
        label: "edit adopted A",
        event: { type: "edit-text", projectKey: KEY_A, text: editedA.text },
        state: stateA(
          {
            observed: persistedA,
            desired: editing(UUID_PERSISTED_A, editedA),
            remote: { kind: "present", tid: 501, generation: null },
            formVersion: 2,
            saveSchedule: { tid: 501, formVersion: 2 },
            historicalGeneration: UUID_PERSISTED_A,
          },
          PERSISTED_DEFAULTS_A,
        ),
        effects: [
          projectDraft(KEY_A, 501, editedA, 2),
          ensureSave(KEY_A, 501, 2),
        ],
      },
      {
        label: "switch from persisted A to persisted B",
        event: {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_B,
          snapshot: pendingSnapshot(502, persistedB),
        },
        state: stateA(
          {
            observed: persistedB,
            desired: editing(UUID_PERSISTED_B, persistedB),
            remote: { kind: "present", tid: 502, generation: null },
            formVersion: 3,
            historicalGeneration: UUID_PERSISTED_B,
          },
          PERSISTED_DEFAULTS_B,
        ),
        effects: [
          cancelSave(KEY_A, 501, 2),
          setEntryPoint(KEY_A, 501, PERSISTED_DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 501, PERSISTED_DEFAULTS_A.agent),
          setDraft(KEY_A, 501, editedA.text, 2),
          projectDraft(KEY_A, 501, editedA, 2),
          releaseTask(KEY_A, 501),
        ],
        assert: (_state, effects) => {
          expect(
            effects.filter(
              (effect) =>
                effect.type === "create-task" || effect.type === "delete-task",
            ),
          ).toEqual([]);
        },
      },
      {
        label: "switch back from persisted B to persisted A",
        event: {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_RETURN,
          snapshot: pendingSnapshot(501, returnedA),
        },
        state: stateA(
          {
            observed: returnedA,
            desired: editing(UUID_PERSISTED_RETURN, returnedA),
            remote: { kind: "present", tid: 501, generation: null },
            formVersion: 4,
            historicalGeneration: UUID_PERSISTED_RETURN,
          },
          PERSISTED_DEFAULTS_A,
        ),
        effects: [
          setEntryPoint(KEY_A, 502, PERSISTED_DEFAULTS_B.entryPoint),
          setAgent(KEY_A, 502, PERSISTED_DEFAULTS_B.agent),
          setDraft(KEY_A, 502, persistedB.text, 3),
          projectDraft(KEY_A, 502, persistedB, 3),
          releaseTask(KEY_A, 502),
        ],
        assert: (_state, effects) => {
          expect(
            effects.filter(
              (effect) =>
                effect.type === "create-task" || effect.type === "delete-task",
            ),
          ).toEqual([]);
        },
      },
    ]);
  });

  it("switches an acknowledged locally-created A to B and re-adopts A", () => {
    const createdA = form("locally-created A");
    const editedA = form("locally-created A local");
    const persistedB = form("persisted B", PERSISTED_DEFAULTS_B);
    const returnedA = form("persisted A returned", PERSISTED_DEFAULTS_A);

    trace(initialA(), [
      {
        label: "start locally-created A",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: createdA.text,
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, createdA),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "create locally-created A",
        event: {
          type: "create-timer-due",
          projectKey: KEY_A,
          generation: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, createdA),
          remote: { kind: "creating", correlationId: UUID_A },
          formVersion: 1,
          historicalGeneration: UUID_A,
        }),
        effects: [
          createTask(
            KEY_A,
            UUID_A,
            DEFAULTS_A.entryPoint,
            DEFAULTS_A.agent,
            null,
          ),
        ],
      },
      {
        label: "acknowledge locally-created A",
        event: { type: "task-created", correlationId: UUID_A, tid: 503 },
        state: stateA({
          desired: editing(UUID_A, createdA),
          remote: { kind: "present", tid: 503, generation: UUID_A },
          formVersion: 1,
          historicalGeneration: UUID_A,
        }),
        effects: [
          setEntryPoint(KEY_A, 503, DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 503, DEFAULTS_A.agent),
          setDraft(KEY_A, 503, createdA.text, 1),
          projectDraft(KEY_A, 503, createdA, 1),
          draftReady(KEY_A, 503, UUID_A),
        ],
      },
      {
        label: "edit acknowledged locally-created A",
        event: { type: "edit-text", projectKey: KEY_A, text: editedA.text },
        state: stateA({
          desired: editing(UUID_A, editedA),
          remote: { kind: "present", tid: 503, generation: UUID_A },
          formVersion: 2,
          saveSchedule: { tid: 503, formVersion: 2 },
          historicalGeneration: UUID_A,
        }),
        effects: [
          projectDraft(KEY_A, 503, editedA, 2),
          ensureSave(KEY_A, 503, 2),
        ],
      },
      {
        label: "flush, project, and release locally-created A for persisted B",
        event: {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_B,
          snapshot: pendingSnapshot(504, persistedB),
        },
        state: stateA(
          {
            observed: persistedB,
            desired: editing(UUID_PERSISTED_B, persistedB),
            remote: { kind: "present", tid: 504, generation: null },
            formVersion: 3,
            historicalGeneration: UUID_PERSISTED_B,
          },
          PERSISTED_DEFAULTS_B,
        ),
        effects: [
          cancelSave(KEY_A, 503, 2),
          setEntryPoint(KEY_A, 503, DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 503, DEFAULTS_A.agent),
          setDraft(KEY_A, 503, editedA.text, 2),
          projectDraft(KEY_A, 503, editedA, 2),
          releaseTask(KEY_A, 503),
        ],
        assert: (state, effects) => {
          expect(state.uuidBindings).toEqual([
            { uuid: UUID_A, projectKey: KEY_A, tid: 503 },
            { uuid: UUID_PERSISTED_B, projectKey: KEY_A, tid: 504 },
          ]);
          expect(
            effects.filter(
              (effect) =>
                effect.type === "create-task" || effect.type === "delete-task",
            ),
          ).toEqual([]);
        },
      },
      {
        label: "re-adopt locally-created A with its original UUID",
        event: {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_A,
          snapshot: pendingSnapshot(503, returnedA),
        },
        state: stateA(
          {
            observed: returnedA,
            desired: editing(UUID_A, returnedA),
            remote: { kind: "present", tid: 503, generation: null },
            formVersion: 4,
            historicalGeneration: UUID_A,
          },
          PERSISTED_DEFAULTS_A,
        ),
        effects: [
          setEntryPoint(KEY_A, 504, PERSISTED_DEFAULTS_B.entryPoint),
          setAgent(KEY_A, 504, PERSISTED_DEFAULTS_B.agent),
          setDraft(KEY_A, 504, persistedB.text, 3),
          projectDraft(KEY_A, 504, persistedB, 3),
          releaseTask(KEY_A, 504),
        ],
        assert: (state, effects) => {
          expect(state.uuidBindings).toEqual([
            { uuid: UUID_A, projectKey: KEY_A, tid: 503 },
            { uuid: UUID_PERSISTED_B, projectKey: KEY_A, tid: 504 },
          ]);
          expect(
            effects.filter(
              (effect) =>
                effect.type === "create-task" || effect.type === "delete-task",
            ),
          ).toEqual([]);
        },
      },
    ]);
  });
});

describe("draft reconciler failure boundaries", () => {
  it("clears all slots without effects on connection reset", () => {
    trace(
      stateAB(
        {
          desired: editing(UUID_A, form("alpha")),
          remote: { kind: "present", tid: 701, generation: UUID_A },
          formVersion: 2,
          saveSchedule: { tid: 701, formVersion: 2 },
          historicalGeneration: UUID_A,
        },
        {
          desired: editing(UUID_B, form("bravo", DEFAULTS_B)),
          remote: { kind: "deleting", tid: 702 },
          formVersion: 3,
          historicalGeneration: UUID_B,
        },
      ),
      [
        {
          label: "connection reset",
          event: { type: "connection-reset" },
          state: { slots: {}, uuidBindings: [] },
          effects: [],
        },
      ],
    );
  });

  it("rejects mismatched and pending observations without mutating state", () => {
    const ownedDraft = form("owned observation");
    const owned = stateAB({
      observed: ownedDraft,
      desired: editing(UUID_A, ownedDraft),
      remote: { kind: "present", tid: 810, generation: UUID_A },
      formVersion: 3,
      historicalGeneration: UUID_A,
    });

    expectReductionFailure(
      owned,
      {
        type: "task-observed",
        projectKey: KEY_B,
        observation: taskObservation(810, { active: true }),
      },
      "Observation does not match an owned task",
    );
    expectReductionFailure(
      owned,
      {
        type: "task-observed",
        projectKey: KEY_A,
        observation: taskObservation(811),
      },
      "Observation does not match an owned task",
    );

    const deleting = stateA({
      desired: editing(UUID_B, form("replacement while deleting")),
      remote: { kind: "deleting", tid: 812 },
      formVersion: 4,
      historicalGeneration: UUID_B,
    });
    expectReductionFailure(
      deleting,
      {
        type: "task-observed",
        projectKey: KEY_A,
        observation: taskObservation(812),
      },
      "Only a present task accepts a pending observation",
    );
  });

  it("rejects malformed observed form fields before state changes", () => {
    const observed = form("observed draft", CUSTOM_DEFAULTS_A);
    const owned = stateA(
      {
        observed,
        desired: editing(UUID_A, observed),
        remote: { kind: "present", tid: 811, generation: UUID_A },
        formVersion: 3,
        saveSchedule: { tid: 811, formVersion: 3 },
        historicalGeneration: UUID_A,
      },
      CUSTOM_DEFAULTS_A,
    );
    const malformedObservations: readonly TaskObservation[] = [
      { tid: 811, text: undefined } as never,
      { tid: 811, entryPoint: undefined } as never,
      { tid: 811, agent: undefined } as never,
      { tid: 811, text: 1 } as never,
      { tid: 811, entryPoint: null } as never,
      { tid: 811, agent: false } as never,
    ];

    for (const observation of malformedObservations) {
      expectReductionFailure(
        owned,
        {
          type: "task-observed",
          projectKey: KEY_A,
          observation,
        },
        "Observed form field",
      );
    }
  });

  it("validates own-present activity facts before preserving or handing off a draft", () => {
    const draft = form("owned activity draft", CUSTOM_DEFAULTS_A);
    const pending = stateA(
      {
        observed: draft,
        desired: editing(UUID_ACTIVE, draft),
        remote: { kind: "present", tid: 813, generation: UUID_ACTIVE },
        formVersion: 7,
        saveSchedule: { tid: 813, formVersion: 7 },
        historicalGeneration: UUID_ACTIVE,
      },
      CUSTOM_DEFAULTS_A,
    );
    const pendingEffects = [projectDraft(KEY_A, 813, draft, 7)];

    trace(pending, [
      {
        label: "omitted activity facts keep an owned draft pending",
        event: {
          type: "task-observed",
          projectKey: KEY_A,
          observation: taskObservation(813),
        },
        state: pending,
        effects: pendingEffects,
        assert: (state) => {
          expect(state).toBe(pending);
        },
      },
    ]);

    const inactiveVariants: readonly [
      string,
      Pick<TaskObservation, "active" | "processing" | "hasMessages">,
    ][] = [
      ["active false", { active: false }],
      ["processing false", { processing: false }],
      ["has-messages false", { hasMessages: false }],
    ];
    for (const [label, activity] of inactiveVariants) {
      trace(pending, [
        {
          label: `${label} keeps an owned draft pending`,
          event: {
            type: "task-observed",
            projectKey: KEY_A,
            observation: taskObservation(813, activity),
          },
          state: pending,
          effects: pendingEffects,
          assert: (state) => {
            expect(state).toBe(pending);
          },
        },
      ]);
    }

    const handoffVariants: readonly [
      string,
      number,
      Pick<TaskObservation, "active" | "processing" | "hasMessages">,
    ][] = [
      ["active true", 814, { active: true }],
      ["processing true", 815, { processing: true }],
      ["has-messages true", 816, { hasMessages: true }],
    ];
    for (const [label, tid, activity] of handoffVariants) {
      trace(
        stateA(
          {
            observed: draft,
            desired: editing(UUID_ACTIVE, draft),
            remote: { kind: "present", tid, generation: UUID_ACTIVE },
            formVersion: 7,
            saveSchedule: { tid, formVersion: 7 },
            historicalGeneration: UUID_ACTIVE,
          },
          CUSTOM_DEFAULTS_A,
        ),
        [
          {
            label: `${label} hands off the owned task`,
            event: {
              type: "task-observed",
              projectKey: KEY_A,
              observation: taskObservation(tid, activity),
            },
            state: stateA(
              { formVersion: 8, historicalGeneration: UUID_ACTIVE },
              CUSTOM_DEFAULTS_A,
            ),
            effects: [cancelSave(KEY_A, tid, 7), releaseTask(KEY_A, tid)],
            assert: (state) => {
              expect(state.uuidBindings).toEqual([
                { uuid: UUID_ACTIVE, projectKey: KEY_A, tid },
              ]);
            },
          },
        ],
      );
    }

    const malformedValues: readonly unknown[] = [undefined, null, 0, "true"];
    for (const field of ["active", "processing", "hasMessages"] as const) {
      for (const value of malformedValues) {
        expectReductionFailure(
          pending,
          {
            type: "task-observed",
            projectKey: KEY_A,
            observation: { tid: 813, [field]: value } as never,
          },
          `Observed activity field ${field} must be a boolean`,
        );
      }
    }
  });

  it("treats inherited activity facts as omitted for an owned draft", () => {
    const draft = form("owned activity draft", CUSTOM_DEFAULTS_A);
    const pending = stateA(
      {
        observed: draft,
        desired: editing(UUID_ACTIVE, draft),
        remote: { kind: "present", tid: 818, generation: UUID_ACTIVE },
        formVersion: 7,
        saveSchedule: { tid: 818, formVersion: 7 },
        historicalGeneration: UUID_ACTIVE,
      },
      CUSTOM_DEFAULTS_A,
    );
    const pendingEffects = [projectDraft(KEY_A, 818, draft, 7)];
    const inheritedActivityFields: readonly (
      | "active"
      | "processing"
      | "hasMessages"
    )[] = ["active", "processing", "hasMessages"];

    for (const field of inheritedActivityFields) {
      const observation = Object.assign(Object.create({ [field]: true }), {
        tid: 818,
      }) as TaskObservation;
      expect(Object.prototype.hasOwnProperty.call(observation, "tid")).toBe(
        true,
      );
      expect(Object.prototype.hasOwnProperty.call(observation, field)).toBe(
        false,
      );

      trace(pending, [
        {
          label: `inherited ${field} true keeps an owned draft pending`,
          event: {
            type: "task-observed",
            projectKey: KEY_A,
            observation,
          },
          state: pending,
          effects: pendingEffects,
          assert: (state) => {
            expect(state).toBe(pending);
          },
        },
      ]);
    }
  });

  it("rejects incomplete and mistyped persisted snapshots before state changes", () => {
    const idle = initialA();
    const stable = stateA({
      desired: editing(UUID_A, form("stable local A")),
      remote: { kind: "present", tid: 91, generation: UUID_A },
      formVersion: 1,
      historicalGeneration: UUID_A,
    });
    const incompleteAdoption = { tid: 92, text: "persisted" } as never;
    const incompleteSwitch = { tid: 93, text: "persisted" } as never;
    const malformedSnapshots: readonly TaskSnapshot[] = [
      {
        ...pendingSnapshot(94, form("persisted", PERSISTED_DEFAULTS_A)),
        text: 1,
      } as never,
      {
        ...pendingSnapshot(95, form("persisted", PERSISTED_DEFAULTS_A)),
        entryPoint: null,
      } as never,
      {
        ...pendingSnapshot(96, form("persisted", PERSISTED_DEFAULTS_A)),
        agent: false,
      } as never,
      {
        ...pendingSnapshot(97, form("persisted", PERSISTED_DEFAULTS_A)),
        active: "false",
      } as never,
      {
        ...pendingSnapshot(98, form("persisted", PERSISTED_DEFAULTS_A)),
        processing: 0,
      } as never,
      {
        ...pendingSnapshot(99, form("persisted", PERSISTED_DEFAULTS_A)),
        hasMessages: null,
      } as never,
    ];

    expectReductionFailure(
      idle,
      {
        type: "adopt-persisted",
        projectKey: KEY_A,
        uuid: UUID_PERSISTED_A,
        snapshot: incompleteAdoption,
      },
      "Persisted task snapshot must be complete",
    );
    expectReductionFailure(
      stable,
      {
        type: "switch-persisted",
        projectKey: KEY_A,
        uuid: UUID_PERSISTED_B,
        snapshot: incompleteSwitch,
      },
      "Persisted task snapshot must be complete",
    );

    for (const snapshot of malformedSnapshots) {
      expectReductionFailure(
        idle,
        {
          type: "adopt-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_A,
          snapshot,
        },
        "Persisted task snapshot must be complete",
      );
      expectReductionFailure(
        stable,
        {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_B,
          snapshot,
        },
        "Persisted task snapshot must be complete",
      );
    }
  });

  it("rejects persisted snapshots with inherited required fields", () => {
    const idle = initialA();
    const stable = stateA({
      desired: editing(UUID_A, form("stable local A")),
      remote: { kind: "present", tid: 91, generation: UUID_A },
      formVersion: 1,
      historicalGeneration: UUID_A,
    });
    const requiredFields: readonly (keyof TaskSnapshot)[] = [
      "tid",
      "text",
      "entryPoint",
      "agent",
      "active",
      "processing",
      "hasMessages",
    ];

    for (const field of requiredFields) {
      const complete = pendingSnapshot(
        819,
        form("persisted inherited field", PERSISTED_DEFAULTS_A),
      );
      const { [field]: _omitted, ...ownFields } = complete;
      const snapshot = Object.assign(
        Object.create({ [field]: complete[field] }),
        ownFields,
      ) as TaskSnapshot;
      expect(Object.prototype.hasOwnProperty.call(snapshot, field)).toBe(false);

      expectReductionFailure(
        idle,
        {
          type: "adopt-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_A,
          snapshot,
        },
        "Persisted task snapshot must be complete",
      );
      expectReductionFailure(
        stable,
        {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_B,
          snapshot,
        },
        "Persisted task snapshot must be complete",
      );
    }
  });

  it("rejects malformed task IDs before bindings or effects can be introduced", () => {
    const persisted = form("persisted task", PERSISTED_DEFAULTS_A);
    const creatingDraft = form("creating task");
    const idle = stateA({ historicalGeneration: UUID_A });
    const stable = stateA({
      observed: persisted,
      desired: editing(UUID_A, persisted),
      remote: { kind: "present", tid: 817, generation: UUID_A },
      formVersion: 4,
      saveSchedule: { tid: 817, formVersion: 4 },
      historicalGeneration: UUID_A,
    });
    const creating = stateA({
      observed: creatingDraft,
      desired: editing(UUID_B, creatingDraft),
      remote: { kind: "creating", correlationId: UUID_B },
      formVersion: 5,
      historicalGeneration: UUID_B,
    });
    const malformedTids: readonly unknown[] = [
      Number.NaN,
      Number.POSITIVE_INFINITY,
      Number.NEGATIVE_INFINITY,
      817.5,
      0,
      -817,
      2_147_483_648,
      undefined,
      null,
      "818",
      false,
      {},
      [],
    ];

    for (const tid of malformedTids) {
      const snapshot = pendingSnapshot(tid as number, persisted);
      expectReductionFailure(
        idle,
        {
          type: "adopt-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_A,
          snapshot,
        },
        "Task ID",
      );
      expectReductionFailure(
        stable,
        {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_B,
          snapshot,
        },
        "Task ID",
      );
      expectReductionFailure(
        creating,
        { type: "task-created", correlationId: UUID_B, tid } as never,
        "Task ID",
      );
    }
  });

  it("fails fast for malformed generation, correlation, ownership, adoption, and switch events", () => {
    expect(() =>
      reduceDraft(initialA(), {
        type: "edit-text",
        projectKey: KEY_A,
        text: "missing generation",
      }),
    ).toThrow("A browser UUID is required");

    expect(() =>
      reduceDraft(stateA({ historicalGeneration: UUID_A }), {
        type: "edit-text",
        projectKey: KEY_A,
        text: "reused generation",
        uuid: UUID_A,
      }),
    ).toThrow("A fresh generation UUID must not reuse a prior UUID");

    expect(() =>
      reduceDraft(stateAB({ historicalGeneration: UUID_A }), {
        type: "edit-text",
        projectKey: KEY_B,
        text: "cross-slot reused generation",
        uuid: UUID_A,
      }),
    ).toThrow("A fresh generation UUID must not reuse a prior UUID");

    expect(() =>
      reduceDraft(
        stateA({
          desired: editing(UUID_A, form("creating A")),
          remote: { kind: "creating", correlationId: UUID_A },
          formVersion: 1,
          historicalGeneration: UUID_A,
        }),
        { type: "task-created", correlationId: UUID_WRONG, tid: 703 },
      ),
    ).toThrow("Create acknowledgement does not match one owned generation");

    expect(() =>
      reduceDraft(
        stateAB(
          {
            desired: editing(UUID_A, form("owned A")),
            remote: { kind: "present", tid: 704, generation: UUID_A },
            formVersion: 1,
            historicalGeneration: UUID_A,
          },
          {
            desired: editing(UUID_B, form("creating B", DEFAULTS_B)),
            remote: { kind: "creating", correlationId: UUID_B },
            formVersion: 1,
            historicalGeneration: UUID_B,
          },
        ),
        { type: "task-created", correlationId: UUID_B, tid: 704 },
      ),
    ).toThrow("Task ID is already owned by another slot: 704");

    expect(() =>
      reduceDraft(
        stateA({
          desired: editing(UUID_A, form("not idle")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        {
          type: "adopt-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_A,
          snapshot: pendingSnapshot(
            705,
            form("persisted", PERSISTED_DEFAULTS_A),
          ),
        },
      ),
    ).toThrow("Only an idle slot can adopt a persisted draft");

    expect(() =>
      reduceDraft(
        stateA({
          desired: editing(UUID_A, form("generated task")),
          remote: { kind: "creating", correlationId: UUID_A },
          formVersion: 1,
          historicalGeneration: UUID_A,
        }),
        {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_B,
          snapshot: pendingSnapshot(
            707,
            form("persisted B", PERSISTED_DEFAULTS_B),
          ),
        },
      ),
    ).toThrow("Only a stable present draft can switch persisted tasks");
  });

  it("rejects a persisted UUID rebound to a distinct task without mutating state", () => {
    const persistedA = form("persisted A", PERSISTED_DEFAULTS_A);
    const persistedB = form("persisted B", PERSISTED_DEFAULTS_B);
    const persistedC = form("persisted C", PERSISTED_DEFAULTS_A);

    const afterSwitch = trace(initialA(), [
      {
        label: "adopt persisted A and bind its UUID",
        event: {
          type: "adopt-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_A,
          snapshot: pendingSnapshot(716, persistedA),
        },
        state: stateA(
          {
            observed: persistedA,
            desired: editing(UUID_PERSISTED_A, persistedA),
            remote: { kind: "present", tid: 716, generation: null },
            formVersion: 1,
            historicalGeneration: UUID_PERSISTED_A,
          },
          PERSISTED_DEFAULTS_A,
        ),
        effects: [],
      },
      {
        label: "switch to persisted B and bind its UUID",
        event: {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid: UUID_PERSISTED_B,
          snapshot: pendingSnapshot(717, persistedB),
        },
        state: stateA(
          {
            observed: persistedB,
            desired: editing(UUID_PERSISTED_B, persistedB),
            remote: { kind: "present", tid: 717, generation: null },
            formVersion: 2,
            historicalGeneration: UUID_PERSISTED_B,
          },
          PERSISTED_DEFAULTS_B,
        ),
        effects: [
          setEntryPoint(KEY_A, 716, PERSISTED_DEFAULTS_A.entryPoint),
          setAgent(KEY_A, 716, PERSISTED_DEFAULTS_A.agent),
          setDraft(KEY_A, 716, persistedA.text, 1),
          projectDraft(KEY_A, 716, persistedA, 1),
          releaseTask(KEY_A, 716),
        ],
        assert: (state) => {
          expect(state.uuidBindings).toEqual([
            { uuid: UUID_PERSISTED_A, projectKey: KEY_A, tid: 716 },
            { uuid: UUID_PERSISTED_B, projectKey: KEY_A, tid: 717 },
          ]);
        },
      },
    ]);

    expectReductionFailure(
      afterSwitch,
      {
        type: "switch-persisted",
        projectKey: KEY_A,
        uuid: UUID_PERSISTED_A,
        snapshot: pendingSnapshot(718, persistedC),
      },
      "Browser UUID is already bound to another task",
    );
  });

  it("retains UUID history across non-adjacent same-slot and cross-slot reuse", () => {
    const afterTwoClears = trace(initialA(), [
      {
        label: "start generation A",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "generation A",
          uuid: UUID_A,
        },
        state: stateA({
          desired: editing(UUID_A, form("generation A")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "clear generation A",
        event: { type: "clear", projectKey: KEY_A },
        state: stateA({ formVersion: 2, historicalGeneration: UUID_A }),
        effects: [cancelCreate(KEY_A, UUID_A)],
      },
      {
        label: "start non-adjacent generation B",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "generation B",
          uuid: UUID_B,
        },
        state: stateA({
          desired: editing(UUID_B, form("generation B")),
          formVersion: 3,
          createSchedule: UUID_B,
          historicalGeneration: UUID_B,
        }),
        effects: [scheduleCreate(KEY_A, UUID_B)],
      },
      {
        label: "clear generation B",
        event: { type: "clear", projectKey: KEY_A },
        state: stateA({ formVersion: 4, historicalGeneration: UUID_B }),
        effects: [cancelCreate(KEY_A, UUID_B)],
      },
    ]);

    expectReductionFailure(
      afterTwoClears,
      {
        type: "edit-text",
        projectKey: KEY_A,
        text: "reused generation A",
        uuid: UUID_A,
      },
      "A fresh generation UUID must not reuse a prior UUID",
    );

    const afterAlphaClear = trace(initialAB(), [
      {
        label: "start alpha generation A",
        event: {
          type: "edit-text",
          projectKey: KEY_A,
          text: "alpha generation A",
          uuid: UUID_A,
        },
        state: stateAB({
          desired: editing(UUID_A, form("alpha generation A")),
          formVersion: 1,
          createSchedule: UUID_A,
          historicalGeneration: UUID_A,
        }),
        effects: [scheduleCreate(KEY_A, UUID_A)],
      },
      {
        label: "clear alpha generation A",
        event: { type: "clear", projectKey: KEY_A },
        state: stateAB({ formVersion: 2, historicalGeneration: UUID_A }),
        effects: [cancelCreate(KEY_A, UUID_A)],
      },
    ]);

    expectReductionFailure(
      afterAlphaClear,
      {
        type: "edit-text",
        projectKey: KEY_B,
        text: "bravo reuses alpha generation A",
        uuid: UUID_A,
      },
      "A fresh generation UUID must not reuse a prior UUID",
    );
  });

  it("rejects blank or missing persisted UUIDs and blank snapshots before state changes", () => {
    const persisted = pendingSnapshot(
      708,
      form("persisted", PERSISTED_DEFAULTS_A),
    );
    const blankPersisted = pendingSnapshot(
      709,
      form(" \t\n ", PERSISTED_DEFAULTS_A),
    );
    const idle = initialA();
    const stable = stateA({
      desired: editing(UUID_A, form("stable local A")),
      remote: { kind: "present", tid: 710, generation: UUID_A },
      formVersion: 1,
      historicalGeneration: UUID_A,
    });

    for (const uuid of ["", " \t "] as const) {
      expectReductionFailure(
        idle,
        {
          type: "adopt-persisted",
          projectKey: KEY_A,
          uuid,
          snapshot: persisted,
        },
        "A browser UUID is required",
      );
      expectReductionFailure(
        stable,
        {
          type: "switch-persisted",
          projectKey: KEY_A,
          uuid,
          snapshot: persisted,
        },
        "A browser UUID is required",
      );
    }

    expectReductionFailure(
      idle,
      {
        type: "adopt-persisted",
        projectKey: KEY_A,
        snapshot: persisted,
      } as unknown as DraftEvent,
      "A browser UUID is required",
    );
    expectReductionFailure(
      stable,
      {
        type: "switch-persisted",
        projectKey: KEY_A,
        snapshot: persisted,
      } as unknown as DraftEvent,
      "A browser UUID is required",
    );

    expectReductionFailure(
      idle,
      {
        type: "adopt-persisted",
        projectKey: KEY_A,
        uuid: UUID_PERSISTED_A,
        snapshot: blankPersisted,
      },
      "A persisted draft must have non-empty text",
    );
    expectReductionFailure(
      stable,
      {
        type: "switch-persisted",
        projectKey: KEY_A,
        uuid: UUID_PERSISTED_B,
        snapshot: blankPersisted,
      },
      "A persisted draft must have non-empty text",
    );
  });

  it("rejects mismatched deletion acknowledgements and duplicate persisted task IDs", () => {
    const deleting = stateA(
      {
        remote: { kind: "deleting", tid: 711 },
        formVersion: 2,
      },
      DEFAULTS_A,
      [{ uuid: UUID_A, projectKey: KEY_A, tid: 711 }],
    );
    expectReductionFailure(
      deleting,
      { type: "task-deleted", tid: 712 },
      "Task deletion does not match one owned task",
    );

    const adoptionState = stateAB({
      desired: editing(UUID_A, form("owned alpha")),
      remote: { kind: "present", tid: 713, generation: UUID_A },
      formVersion: 1,
      historicalGeneration: UUID_A,
    });
    expectReductionFailure(
      adoptionState,
      {
        type: "adopt-persisted",
        projectKey: KEY_B,
        uuid: UUID_PERSISTED_B,
        snapshot: pendingSnapshot(
          713,
          form("duplicate alpha", PERSISTED_DEFAULTS_B),
        ),
      },
      "Task ID is already owned by another slot: 713",
    );

    const switchState = stateAB(
      {
        desired: editing(UUID_A, form("owned alpha")),
        remote: { kind: "present", tid: 714, generation: UUID_A },
        formVersion: 1,
        historicalGeneration: UUID_A,
      },
      {
        desired: editing(UUID_B, form("owned bravo", DEFAULTS_B)),
        remote: { kind: "present", tid: 715, generation: UUID_B },
        formVersion: 1,
        historicalGeneration: UUID_B,
      },
    );
    expectReductionFailure(
      switchState,
      {
        type: "switch-persisted",
        projectKey: KEY_B,
        uuid: UUID_PERSISTED_B,
        snapshot: pendingSnapshot(
          714,
          form("duplicate alpha", PERSISTED_DEFAULTS_B),
        ),
      },
      "Task ID is already owned by another slot: 714",
    );
  });
});
