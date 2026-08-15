export type ProjectKey = string;
export type DraftId = string;

export const CREATE_DELAY_MS = 16 as const;
export const DRAFT_SAVE_DELAY_MS = 500 as const;
const MAX_TASK_ID = 2_147_483_647;
const PERSISTED_SNAPSHOT_FIELDS = [
  "tid",
  "text",
  "entryPoint",
  "agent",
  "active",
  "processing",
  "hasMessages",
] as const;

export interface ProjectIdentity {
  workspace: string;
  projectPath: string;
}

export interface FormDefaults {
  entryPoint: string | null;
  agent: string | null;
}

export interface DraftForm extends FormDefaults {
  text: string;
}

export interface ResolvedDraftForm extends DraftForm {
  entryPoint: string;
  agent: string;
}

export interface ImageAttachment {
  id: string;
  dataURL: string;
  base64: string;
  mediaType: string;
}

export interface DraftContent {
  text: string;
  images: readonly ImageAttachment[];
}

export type Desired =
  | { kind: "none" }
  | ({ kind: "editing"; uuid: DraftId } & DraftForm)
  | ({
      kind: "submitting";
      uuid: DraftId;
      images: readonly ImageAttachment[];
      delivery: "atomic-create" | "send-when-present";
    } & DraftForm);

export type Remote =
  | { kind: "absent" }
  | { kind: "creating"; correlationId: DraftId }
  | { kind: "present"; tid: number; generation: DraftId | null }
  | { kind: "deleting"; tid: number };

export interface SaveSchedule {
  tid: number;
  formVersion: number;
}

export interface UuidBinding {
  uuid: DraftId;
  projectKey: ProjectKey;
  tid: number | null;
}

export interface DraftSlotState {
  project: ProjectIdentity;
  defaults: FormDefaults;
  observed: DraftForm;
  desired: Desired;
  remote: Remote;
  formVersion: number;
  createSchedule: DraftId | null;
  saveSchedule: SaveSchedule | null;
}

export interface DraftState {
  slots: Readonly<Record<ProjectKey, DraftSlotState>>;
  uuidBindings: readonly UuidBinding[];
}

export interface SlotInit {
  project: ProjectIdentity;
  defaults: FormDefaults;
}

export interface TaskSnapshot extends ResolvedDraftForm {
  tid: number;
  active: boolean;
  processing: boolean;
  hasMessages: boolean;
}

export interface TaskObservation {
  tid: number;
  active?: boolean;
  processing?: boolean;
  hasMessages?: boolean;
  text?: string;
  entryPoint?: string;
  agent?: string;
}

export type DraftEffect =
  | {
      type: "schedule-create";
      projectKey: ProjectKey;
      generation: DraftId;
      delayMs: typeof CREATE_DELAY_MS;
    }
  | {
      type: "cancel-create-schedule";
      projectKey: ProjectKey;
      generation: DraftId;
    }
  | {
      type: "create-task";
      projectKey: ProjectKey;
      correlationId: DraftId;
      entryPoint: string;
      agent: string;
      content: DraftContent | null;
    }
  | {
      type: "ensure-draft-save";
      projectKey: ProjectKey;
      tid: number;
      formVersion: number;
      delayMs: typeof DRAFT_SAVE_DELAY_MS;
    }
  | {
      type: "cancel-draft-save";
      projectKey: ProjectKey;
      tid: number;
      formVersion: number;
    }
  | {
      type: "set-entry-point";
      projectKey: ProjectKey;
      tid: number;
      entryPoint: string;
    }
  | {
      type: "set-agent";
      projectKey: ProjectKey;
      tid: number;
      agent: string;
    }
  | {
      type: "set-draft";
      projectKey: ProjectKey;
      tid: number;
      text: string;
      formVersion: number;
    }
  | {
      type: "project-draft";
      projectKey: ProjectKey;
      tid: number;
      form: ResolvedDraftForm;
      formVersion: number;
    }
  | { type: "delete-task"; projectKey: ProjectKey; tid: number }
  | {
      type: "draft-ready";
      projectKey: ProjectKey;
      tid: number;
      generation: DraftId;
    }
  | {
      type: "send-first-message";
      projectKey: ProjectKey;
      tid: number;
      content: DraftContent;
    }
  | {
      type: "release-task";
      projectKey: ProjectKey;
      tid: number;
      resetComposer: boolean;
    };

export type DraftEvent =
  | {
      type: "initialize-slot";
      project: ProjectIdentity;
      defaults: FormDefaults;
    }
  | {
      type: "resolve-metadata";
      projectKey: ProjectKey;
      entryPoint: string;
      agent: string;
    }
  | {
      type: "edit-text";
      projectKey: ProjectKey;
      text: string;
      uuid?: DraftId;
    }
  | { type: "clear"; projectKey: ProjectKey }
  | {
      type: "change-entry-point";
      projectKey: ProjectKey;
      entryPoint: string;
    }
  | { type: "change-agent"; projectKey: ProjectKey; agent: string }
  | {
      type: "submit";
      projectKey: ProjectKey;
      images: readonly ImageAttachment[];
      uuid?: DraftId;
    }
  | { type: "flush"; projectKey: ProjectKey }
  | {
      type: "create-timer-due";
      projectKey: ProjectKey;
      generation: DraftId;
    }
  | {
      type: "save-timer-due";
      projectKey: ProjectKey;
      tid: number;
      formVersion: number;
    }
  | { type: "task-created"; correlationId: DraftId; tid: number }
  | { type: "task-deleted"; tid: number }
  | {
      type: "task-observed";
      projectKey: ProjectKey;
      observation: TaskObservation;
    }
  | {
      type: "adopt-persisted";
      projectKey: ProjectKey;
      uuid: DraftId;
      snapshot: TaskSnapshot;
    }
  | {
      type: "switch-persisted";
      projectKey: ProjectKey;
      uuid: DraftId;
      snapshot: TaskSnapshot;
    }
  | { type: "connection-reset" };

export interface DraftResult {
  state: DraftState;
  effects: readonly DraftEffect[];
}

export function createProjectKey(
  workspace: string,
  projectPath: string,
): ProjectKey {
  if (workspace.includes("\0") || projectPath.includes("\0")) {
    throw new Error("Canonical project identity cannot contain NUL");
  }
  return workspace + "\0" + projectPath;
}

export function createDraftState(
  initial: readonly SlotInit[] = [],
): DraftState {
  const slots: Record<ProjectKey, DraftSlotState> = {};

  for (const { project, defaults } of initial) {
    const projectKey = createProjectKey(project.workspace, project.projectPath);
    if (slots[projectKey]) {
      throw new Error("Duplicate project slot: " + projectKey);
    }
    slots[projectKey] = createSlot(project, defaults);
  }

  return { slots, uuidBindings: [] };
}

function createSlot(
  project: ProjectIdentity,
  defaults: FormDefaults,
): DraftSlotState {
  const copiedDefaults = { ...defaults };
  return {
    project: { ...project },
    defaults: copiedDefaults,
    observed: { text: "", ...copiedDefaults },
    desired: { kind: "none" },
    remote: { kind: "absent" },
    formVersion: 0,
    createSchedule: null,
    saveSchedule: null,
  };
}

export function getSlot(
  state: DraftState,
  projectKey: ProjectKey,
): DraftSlotState {
  const slot = state.slots[projectKey];
  if (!slot) throw new Error("Unknown project slot: " + projectKey);
  return slot;
}

export function selectDraftForm(
  state: DraftState,
  projectKey: ProjectKey,
): DraftForm {
  const slot = getSlot(state, projectKey);
  if (slot.desired.kind === "none") {
    return { text: "", ...slot.defaults };
  }
  return formOf(slot.desired);
}

export function tombstonedTids(state: DraftState): readonly number[] {
  return Object.values(state.slots)
    .flatMap((slot) =>
      slot.remote.kind === "deleting" ? [slot.remote.tid] : [],
    )
    .sort((left, right) => left - right);
}

export function isTombstoned(state: DraftState, tid: number): boolean {
  return tombstonedTids(state).includes(tid);
}

export function reduceDraft(state: DraftState, event: DraftEvent): DraftResult {
  switch (event.type) {
    case "initialize-slot":
      return initializeSlot(state, event.project, event.defaults);

    case "resolve-metadata":
      return resolveMetadata(state, event);

    case "edit-text":
      return editText(state, event);

    case "clear":
      return clearSlot(state, event.projectKey);

    case "change-entry-point":
      return changeEntryPoint(state, event.projectKey, event.entryPoint);

    case "change-agent":
      return changeAgent(state, event.projectKey, event.agent);

    case "submit":
      return submit(state, event);

    case "flush":
      return flush(state, event.projectKey);

    case "create-timer-due":
      return createTimerDue(state, event);

    case "save-timer-due":
      return saveTimerDue(state, event);

    case "task-created":
      return taskCreated(state, event);

    case "task-deleted":
      return taskDeleted(state, event.tid);

    case "task-observed":
      return taskObserved(state, event);

    case "adopt-persisted":
      return adoptPersisted(state, event);

    case "switch-persisted":
      return switchPersisted(state, event);

    case "connection-reset":
      return { state: { slots: {}, uuidBindings: [] }, effects: [] };

    default:
      return assertNever(event);
  }
}

export function assertNever(value: never): never {
  throw new Error("Unexpected value: " + JSON.stringify(value));
}

export function assertResolvedDraftForm<T extends DraftForm>(
  form: T,
): asserts form is T & ResolvedDraftForm {
  if (form.entryPoint === null) {
    throw new Error("Draft create/sync requires a resolved entry point");
  }
  if (form.agent === null) {
    throw new Error("Draft create/sync requires a resolved agent");
  }
}

function initializeSlot(
  state: DraftState,
  project: ProjectIdentity,
  defaults: FormDefaults,
): DraftResult {
  const projectKey = createProjectKey(project.workspace, project.projectPath);
  if (state.slots[projectKey]) return { state, effects: [] };

  return {
    state: {
      ...state,
      slots: {
        ...state.slots,
        [projectKey]: createSlot(project, defaults),
      },
    },
    effects: [],
  };
}

function resolveMetadata(
  state: DraftState,
  event: Extract<DraftEvent, { type: "resolve-metadata" }>,
): DraftResult {
  const current = getSlot(state, event.projectKey);
  const defaults: FormDefaults = {
    entryPoint:
      current.defaults.entryPoint === null
        ? event.entryPoint
        : current.defaults.entryPoint,
    agent:
      current.defaults.agent === null ? event.agent : current.defaults.agent,
  };
  const observed: DraftForm = {
    ...current.observed,
    entryPoint:
      current.defaults.entryPoint === null
        ? event.entryPoint
        : current.observed.entryPoint,
    agent:
      current.defaults.agent === null ? event.agent : current.observed.agent,
  };

  if (current.desired.kind === "none") {
    return {
      state: replaceSlot(state, event.projectKey, {
        ...current,
        defaults,
        observed,
      }),
      effects: [],
    };
  }

  const next = replaceSlot(state, event.projectKey, {
    ...current,
    defaults,
    observed,
    desired: {
      ...current.desired,
      entryPoint:
        current.defaults.entryPoint === null
          ? acceptsObservedValue(
              current.desired.entryPoint,
              current.observed.entryPoint,
              event.entryPoint,
            )
          : current.desired.entryPoint,
      agent:
        current.defaults.agent === null
          ? acceptsObservedValue(
              current.desired.agent,
              current.observed.agent,
              event.agent,
            )
          : current.desired.agent,
    },
  });
  return reconcileCore(next, event.projectKey);
}

function editText(
  state: DraftState,
  event: Extract<DraftEvent, { type: "edit-text" }>,
): DraftResult {
  const current = getSlot(state, event.projectKey);

  if (event.text.trim().length === 0) {
    if (event.uuid !== undefined) {
      throw new Error("A fresh UUID is only valid for a non-empty generation");
    }
    return clearSlot(state, event.projectKey);
  }

  switch (current.desired.kind) {
    case "none": {
      const uuid = requireUuid(event.uuid);
      assertFreshGeneration(state, uuid);
      const withUuid = recordFreshUuid(state, event.projectKey, uuid);
      const next = replaceSlot(withUuid, event.projectKey, {
        ...current,
        desired: {
          kind: "editing",
          uuid,
          text: event.text,
          entryPoint: current.defaults.entryPoint,
          agent: current.defaults.agent,
        },
        formVersion: current.formVersion + 1,
      });
      return reconcileCore(next, event.projectKey);
    }

    case "editing": {
      if (event.uuid !== undefined) {
        throw new Error(
          "Editing an existing generation must not supply a UUID",
        );
      }
      if (current.desired.text === event.text) return { state, effects: [] };
      const next = replaceSlot(state, event.projectKey, {
        ...current,
        desired: { ...current.desired, text: event.text },
        formVersion: current.formVersion + 1,
      });
      return afterLocalFormChange(next, event.projectKey, {
        entryPoint: false,
        agent: false,
      });
    }

    case "submitting":
      throw new Error("A submitting draft cannot be edited");

    default:
      return assertNever(current.desired);
  }
}

function clearSlot(state: DraftState, projectKey: ProjectKey): DraftResult {
  const current = getSlot(state, projectKey);
  if (current.desired.kind === "none") return { state, effects: [] };
  if (current.desired.kind === "submitting") {
    throw new Error("A submitting draft cannot be cleared");
  }

  const next = replaceSlot(state, projectKey, {
    ...current,
    defaults: defaultsOf(current.desired),
    desired: { kind: "none" },
    formVersion: current.formVersion + 1,
    createSchedule: null,
  });
  const effects: DraftEffect[] = [];
  if (current.createSchedule !== null) {
    effects.push({
      type: "cancel-create-schedule",
      projectKey,
      generation: current.createSchedule,
    });
  }

  const reconciled = reconcileCore(next, projectKey);
  return {
    state: reconciled.state,
    effects: [...effects, ...reconciled.effects],
  };
}

function changeEntryPoint(
  state: DraftState,
  projectKey: ProjectKey,
  entryPoint: string,
): DraftResult {
  const current = getSlot(state, projectKey);

  switch (current.desired.kind) {
    case "none":
      if (current.defaults.entryPoint === entryPoint) {
        return { state, effects: [] };
      }
      return {
        state: replaceSlot(state, projectKey, {
          ...current,
          defaults: { ...current.defaults, entryPoint },
        }),
        effects: [],
      };

    case "editing": {
      if (current.desired.entryPoint === entryPoint) {
        return { state, effects: [] };
      }
      const next = replaceSlot(state, projectKey, {
        ...current,
        defaults: { ...current.defaults, entryPoint },
        desired: { ...current.desired, entryPoint },
        formVersion: current.formVersion + 1,
      });
      return afterLocalFormChange(next, projectKey, {
        entryPoint: true,
        agent: false,
      });
    }

    case "submitting":
      throw new Error("A submitting draft cannot change entry point");

    default:
      return assertNever(current.desired);
  }
}

function changeAgent(
  state: DraftState,
  projectKey: ProjectKey,
  agent: string,
): DraftResult {
  const current = getSlot(state, projectKey);

  switch (current.desired.kind) {
    case "none":
      if (current.defaults.agent === agent) return { state, effects: [] };
      return {
        state: replaceSlot(state, projectKey, {
          ...current,
          defaults: { ...current.defaults, agent },
        }),
        effects: [],
      };

    case "editing": {
      if (current.desired.agent === agent) return { state, effects: [] };
      const next = replaceSlot(state, projectKey, {
        ...current,
        defaults: { ...current.defaults, agent },
        desired: { ...current.desired, agent },
        formVersion: current.formVersion + 1,
      });
      return afterLocalFormChange(next, projectKey, {
        entryPoint: false,
        agent: true,
      });
    }

    case "submitting":
      throw new Error("A submitting draft cannot change agent");

    default:
      return assertNever(current.desired);
  }
}

function submit(
  state: DraftState,
  event: Extract<DraftEvent, { type: "submit" }>,
): DraftResult {
  const current = getSlot(state, event.projectKey);
  const images = [...event.images];

  switch (current.desired.kind) {
    case "editing": {
      if (event.uuid !== undefined) {
        throw new Error("Submitting an editing draft must not supply a UUID");
      }
      if (current.desired.text.trim().length === 0 && images.length === 0) {
        throw new Error("Cannot submit an empty draft");
      }
      const next = replaceSlot(state, event.projectKey, {
        ...current,
        defaults: defaultsOf(current.desired),
        desired: {
          ...current.desired,
          kind: "submitting",
          images,
          delivery: deliveryFor(current.remote, current.desired.uuid),
        },
        createSchedule: null,
      });
      const effects = cancelCreateEffect(current, event.projectKey);
      const reconciled = reconcileCore(next, event.projectKey);
      return {
        state: reconciled.state,
        effects: [...effects, ...reconciled.effects],
      };
    }

    case "none": {
      if (images.length === 0) throw new Error("Cannot submit an empty draft");
      const uuid = requireUuid(event.uuid);
      assertFreshGeneration(state, uuid);
      const form: DraftForm = { text: "", ...current.defaults };
      const withUuid = recordFreshUuid(state, event.projectKey, uuid);
      const next = replaceSlot(withUuid, event.projectKey, {
        ...current,
        desired: {
          kind: "submitting",
          uuid,
          ...form,
          images,
          delivery: deliveryFor(current.remote, uuid),
        },
        formVersion: current.formVersion + 1,
      });
      return reconcileCore(next, event.projectKey);
    }

    case "submitting":
      throw new Error("A draft may only be submitted once");

    default:
      return assertNever(current.desired);
  }
}

function flush(state: DraftState, projectKey: ProjectKey): DraftResult {
  const current = getSlot(state, projectKey);
  if (!isCurrentPresentEditing(current)) return { state, effects: [] };

  const next = replaceSlot(state, projectKey, {
    ...current,
    saveSchedule: null,
  });
  return {
    state: next,
    effects: [
      ...cancelSaveEffect(current, projectKey),
      {
        type: "set-draft",
        projectKey,
        tid: current.remote.tid,
        text: current.desired.text,
        formVersion: current.formVersion,
      },
      projectEffect(projectKey, current.remote.tid, current),
    ],
  };
}

function createTimerDue(
  state: DraftState,
  event: Extract<DraftEvent, { type: "create-timer-due" }>,
): DraftResult {
  const current = getSlot(state, event.projectKey);
  if (
    current.createSchedule !== event.generation ||
    current.remote.kind !== "absent" ||
    current.desired.kind !== "editing" ||
    current.desired.uuid !== event.generation
  ) {
    return { state, effects: [] };
  }
  assertResolvedDraftForm(current.desired);

  const next = replaceSlot(state, event.projectKey, {
    ...current,
    observed: {
      text: "",
      entryPoint: current.desired.entryPoint,
      agent: current.desired.agent,
    },
    remote: { kind: "creating", correlationId: event.generation },
    createSchedule: null,
  });
  return {
    state: next,
    effects: [
      {
        type: "create-task",
        projectKey: event.projectKey,
        correlationId: event.generation,
        entryPoint: current.desired.entryPoint,
        agent: current.desired.agent,
        content: null,
      },
    ],
  };
}

function saveTimerDue(
  state: DraftState,
  event: Extract<DraftEvent, { type: "save-timer-due" }>,
): DraftResult {
  const current = getSlot(state, event.projectKey);
  if (
    !isCurrentPresentEditing(current) ||
    current.saveSchedule === null ||
    current.saveSchedule.tid !== event.tid ||
    current.saveSchedule.formVersion !== event.formVersion
  ) {
    return { state, effects: [] };
  }

  const next = replaceSlot(state, event.projectKey, {
    ...current,
    saveSchedule: null,
  });
  return {
    state: next,
    effects: [
      {
        type: "set-draft",
        projectKey: event.projectKey,
        tid: event.tid,
        text: current.desired.text,
        formVersion: event.formVersion,
      },
    ],
  };
}

function taskCreated(
  state: DraftState,
  event: Extract<DraftEvent, { type: "task-created" }>,
): DraftResult {
  const projectKey = findCreatingProject(state, event.correlationId);
  assertTaskId(event.tid);
  const current = getSlot(state, projectKey);
  assertTidUnowned(state, projectKey, event.tid);
  const withAcknowledgedUuid =
    current.desired.kind === "editing" &&
    current.desired.uuid === event.correlationId
      ? bindAcknowledgedUuid(state, projectKey, event.correlationId, event.tid)
      : state;

  const next = replaceSlot(withAcknowledgedUuid, projectKey, {
    ...current,
    remote: {
      kind: "present",
      tid: event.tid,
      generation: event.correlationId,
    },
    createSchedule: null,
  });
  const reconciled = reconcileCore(next, projectKey);
  const slot = getSlot(reconciled.state, projectKey);

  if (
    isCurrentPresentEditing(slot) &&
    slot.remote.generation === event.correlationId &&
    slot.desired.uuid === event.correlationId
  ) {
    assertResolvedDraftForm(slot.desired);
    return {
      state: reconciled.state,
      effects: [
        ...reconciled.effects,
        {
          type: "set-entry-point",
          projectKey,
          tid: event.tid,
          entryPoint: slot.desired.entryPoint,
        },
        {
          type: "set-agent",
          projectKey,
          tid: event.tid,
          agent: slot.desired.agent,
        },
        {
          type: "set-draft",
          projectKey,
          tid: event.tid,
          text: slot.desired.text,
          formVersion: slot.formVersion,
        },
        projectEffect(projectKey, event.tid, slot),
        {
          type: "draft-ready",
          projectKey,
          tid: event.tid,
          generation: event.correlationId,
        },
      ],
    };
  }

  return reconciled;
}

function taskDeleted(state: DraftState, tid: number): DraftResult {
  const projectKey = findOwnedTid(state, tid);
  const current = getSlot(state, projectKey);

  switch (current.remote.kind) {
    case "deleting": {
      const next = replaceSlot(state, projectKey, {
        ...current,
        remote: { kind: "absent" },
        createSchedule: null,
        saveSchedule: null,
      });
      return reconcileCore(next, projectKey);
    }

    case "present": {
      const next = replaceSlot(state, projectKey, {
        ...current,
        remote: { kind: "absent" },
        createSchedule: null,
        saveSchedule: null,
      });
      const reconciled = reconcileCore(next, projectKey);
      return {
        state: reconciled.state,
        effects: [
          ...cancelSaveEffect(current, projectKey),
          ...reconciled.effects,
        ],
      };
    }

    case "absent":
    case "creating":
      throw new Error("Only an owned task may be deleted");

    default:
      return assertNever(current.remote);
  }
}

function taskObserved(
  state: DraftState,
  event: Extract<DraftEvent, { type: "task-observed" }>,
): DraftResult {
  const { projectKey, observation } = event;
  const current = getSlot(state, projectKey);
  if (
    (current.remote.kind !== "present" && current.remote.kind !== "deleting") ||
    current.remote.tid !== observation.tid
  ) {
    throw new Error("Observation does not match an owned task");
  }
  assertObservedFormFieldTypes(observation);
  assertObservedActivityFactTypes(observation);

  if (isActiveObservation(observation)) {
    if (current.remote.kind === "deleting") {
      const next = replaceSlot(state, projectKey, {
        ...current,
        remote: { kind: "absent" },
      });
      const reconciled = reconcileCore(next, projectKey);
      return {
        state: reconciled.state,
        effects: [
          {
            type: "release-task",
            projectKey,
            tid: observation.tid,
            resetComposer: false,
          },
          ...reconciled.effects,
        ],
      };
    }

    const next = releaseOwnership(current);
    return {
      state: replaceSlot(state, projectKey, next),
      effects: [
        ...cancelSaveEffect(current, projectKey),
        {
          type: "release-task",
          projectKey,
          tid: observation.tid,
          resetComposer: true,
        },
      ],
    };
  }

  if (current.remote.kind !== "present") {
    throw new Error("Only a present task accepts a pending observation");
  }
  if (current.desired.kind !== "editing") {
    throw new Error("Only an editing draft accepts a task observation");
  }

  if (!hasObservedFormFields(observation)) {
    return {
      state,
      effects: [projectEffect(projectKey, observation.tid, current)],
    };
  }

  const form = mergeObservedForm(
    current.desired,
    current.observed,
    observation,
  );
  const changed =
    form.text !== current.desired.text ||
    form.entryPoint !== current.desired.entryPoint ||
    form.agent !== current.desired.agent;
  const formVersion = changed ? current.formVersion + 1 : current.formVersion;
  const saveSchedule =
    changed && current.saveSchedule !== null
      ? { tid: observation.tid, formVersion }
      : current.saveSchedule;
  const next = replaceSlot(state, projectKey, {
    ...current,
    defaults: mergeObservedDefaults(current.defaults, form, observation),
    observed: mergeObservedBaseline(current.observed, observation),
    desired: changed ? { ...current.desired, ...form } : current.desired,
    formVersion,
    saveSchedule,
  });
  const effects: DraftEffect[] = [
    projectEffect(projectKey, observation.tid, getSlot(next, projectKey)),
  ];
  if (changed && saveSchedule !== null) {
    effects.push({
      type: "ensure-draft-save",
      projectKey,
      tid: saveSchedule.tid,
      formVersion: saveSchedule.formVersion,
      delayMs: DRAFT_SAVE_DELAY_MS,
    });
  }
  return { state: next, effects };
}

function adoptPersisted(
  state: DraftState,
  event: Extract<DraftEvent, { type: "adopt-persisted" }>,
): DraftResult {
  const current = getSlot(state, event.projectKey);
  const uuid = requireUuid(event.uuid);
  assertPersistedSnapshot(event.snapshot);
  if (
    current.desired.kind !== "none" ||
    current.remote.kind !== "absent" ||
    current.createSchedule !== null ||
    current.saveSchedule !== null
  ) {
    throw new Error("Only an idle slot can adopt a persisted draft");
  }
  assertTidUnowned(state, event.projectKey, event.snapshot.tid);
  const withPersistedUuid = bindPersistedUuid(
    state,
    event.projectKey,
    uuid,
    event.snapshot.tid,
  );

  const form = formOf(event.snapshot);
  return {
    state: replaceSlot(withPersistedUuid, event.projectKey, {
      ...current,
      defaults: defaultsOf(form),
      observed: form,
      desired: { kind: "editing", uuid, ...form },
      remote: { kind: "present", tid: event.snapshot.tid, generation: null },
      formVersion: current.formVersion + 1,
    }),
    effects: [],
  };
}

function switchPersisted(
  state: DraftState,
  event: Extract<DraftEvent, { type: "switch-persisted" }>,
): DraftResult {
  const current = getSlot(state, event.projectKey);
  const uuid = requireUuid(event.uuid);
  assertPersistedSnapshot(event.snapshot);
  if (
    current.desired.kind !== "editing" ||
    current.remote.kind !== "present" ||
    !belongsToCurrentGeneration(current)
  ) {
    throw new Error("Only a stable present draft can switch persisted tasks");
  }
  if (current.remote.tid === event.snapshot.tid) {
    throw new Error("A persisted draft cannot switch to itself");
  }
  assertResolvedDraftForm(current.desired);
  assertTidUnowned(state, event.projectKey, event.snapshot.tid);
  const withPersistedUuid = bindPersistedUuid(
    state,
    event.projectKey,
    uuid,
    event.snapshot.tid,
  );

  const form = formOf(event.snapshot);
  const next = replaceSlot(withPersistedUuid, event.projectKey, {
    ...current,
    defaults: defaultsOf(form),
    observed: form,
    desired: { kind: "editing", uuid, ...form },
    remote: { kind: "present", tid: event.snapshot.tid, generation: null },
    formVersion: current.formVersion + 1,
    createSchedule: null,
    saveSchedule: null,
  });
  return {
    state: next,
    effects: [
      ...cancelSaveEffect(current, event.projectKey),
      {
        type: "set-entry-point",
        projectKey: event.projectKey,
        tid: current.remote.tid,
        entryPoint: current.desired.entryPoint,
      },
      {
        type: "set-agent",
        projectKey: event.projectKey,
        tid: current.remote.tid,
        agent: current.desired.agent,
      },
      {
        type: "set-draft",
        projectKey: event.projectKey,
        tid: current.remote.tid,
        text: current.desired.text,
        formVersion: current.formVersion,
      },
      projectEffect(event.projectKey, current.remote.tid, current),
      {
        type: "release-task",
        projectKey: event.projectKey,
        tid: current.remote.tid,
        resetComposer: true,
      },
    ],
  };
}

function afterLocalFormChange(
  state: DraftState,
  projectKey: ProjectKey,
  changed: { entryPoint: boolean; agent: boolean },
): DraftResult {
  const reconciled = reconcileCore(state, projectKey);
  const current = getSlot(reconciled.state, projectKey);
  if (!isCurrentPresentEditing(current)) return reconciled;
  assertResolvedDraftForm(current.desired);

  const effects: DraftEffect[] = [...reconciled.effects];
  if (changed.entryPoint) {
    effects.push({
      type: "set-entry-point",
      projectKey,
      tid: current.remote.tid,
      entryPoint: current.desired.entryPoint,
    });
  }
  if (changed.agent) {
    effects.push({
      type: "set-agent",
      projectKey,
      tid: current.remote.tid,
      agent: current.desired.agent,
    });
  }
  effects.push(projectEffect(projectKey, current.remote.tid, current));

  const scheduled = ensureDraftSave(reconciled.state, projectKey);
  return {
    state: scheduled.state,
    effects: [...effects, ...scheduled.effects],
  };
}

function reconcileCore(state: DraftState, projectKey: ProjectKey): DraftResult {
  const current = getSlot(state, projectKey);

  switch (current.remote.kind) {
    case "absent":
      switch (current.desired.kind) {
        case "none":
          return { state, effects: [] };

        case "editing":
          if (current.desired.entryPoint === null) {
            return { state, effects: [] };
          }
          if (current.createSchedule === current.desired.uuid) {
            return { state, effects: [] };
          }
          if (current.createSchedule !== null) {
            throw new Error(
              "A different create generation is already scheduled",
            );
          }
          return {
            state: replaceSlot(state, projectKey, {
              ...current,
              createSchedule: current.desired.uuid,
            }),
            effects: [
              {
                type: "schedule-create",
                projectKey,
                generation: current.desired.uuid,
                delayMs: CREATE_DELAY_MS,
              },
            ],
          };

        case "submitting": {
          assertResolvedDraftForm(current.desired);
          if (current.desired.delivery !== "atomic-create") {
            throw new Error("send-when-present cannot target an absent task");
          }
          if (current.createSchedule !== null) {
            throw new Error(
              "Atomic submission must cancel its create schedule",
            );
          }
          const next = replaceSlot(state, projectKey, {
            ...current,
            remote: {
              kind: "creating",
              correlationId: current.desired.uuid,
            },
          });
          return {
            state: next,
            effects: [
              {
                type: "create-task",
                projectKey,
                correlationId: current.desired.uuid,
                entryPoint: current.desired.entryPoint,
                agent: current.desired.agent,
                content: contentOf(current.desired),
              },
            ],
          };
        }

        default:
          return assertNever(current.desired);
      }

    case "creating":
    case "deleting":
      return { state, effects: [] };

    case "present":
      if (!belongsToCurrentGeneration(current)) {
        return beginDeletion(state, projectKey);
      }
      switch (current.desired.kind) {
        case "editing":
          return { state, effects: [] };

        case "submitting":
          return submitPresent(
            state,
            projectKey,
            current as DraftSlotState & {
              desired: Extract<Desired, { kind: "submitting" }>;
              remote: Extract<Remote, { kind: "present" }>;
            },
          );

        case "none":
          return beginDeletion(state, projectKey);

        default:
          return assertNever(current.desired);
      }

    default:
      return assertNever(current.remote);
  }
}

function beginDeletion(state: DraftState, projectKey: ProjectKey): DraftResult {
  const current = getSlot(state, projectKey);
  if (current.remote.kind !== "present") {
    throw new Error("Only a present task can begin deletion");
  }

  const next = replaceSlot(state, projectKey, {
    ...current,
    remote: { kind: "deleting", tid: current.remote.tid },
    createSchedule: null,
    saveSchedule: null,
  });
  return {
    state: next,
    effects: [
      ...cancelCreateEffect(current, projectKey),
      ...cancelSaveEffect(current, projectKey),
      { type: "delete-task", projectKey, tid: current.remote.tid },
    ],
  };
}

function submitPresent(
  state: DraftState,
  projectKey: ProjectKey,
  current: DraftSlotState & {
    desired: Extract<Desired, { kind: "submitting" }>;
    remote: Extract<Remote, { kind: "present" }>;
  },
): DraftResult {
  const next = replaceSlot(state, projectKey, releaseOwnership(current));

  if (current.desired.delivery === "atomic-create") {
    return {
      state: next,
      effects: [
        {
          type: "release-task",
          projectKey,
          tid: current.remote.tid,
          resetComposer: true,
        },
      ],
    };
  }

  assertResolvedDraftForm(current.desired);

  const clearedForm: ResolvedDraftForm = {
    text: "",
    entryPoint: current.desired.entryPoint,
    agent: current.desired.agent,
  };
  return {
    state: next,
    effects: [
      ...cancelSaveEffect(current, projectKey),
      {
        type: "set-entry-point",
        projectKey,
        tid: current.remote.tid,
        entryPoint: current.desired.entryPoint,
      },
      {
        type: "set-agent",
        projectKey,
        tid: current.remote.tid,
        agent: current.desired.agent,
      },
      {
        type: "project-draft",
        projectKey,
        tid: current.remote.tid,
        form: clearedForm,
        formVersion: current.formVersion,
      },
      {
        type: "set-draft",
        projectKey,
        tid: current.remote.tid,
        text: "",
        formVersion: current.formVersion,
      },
      {
        type: "send-first-message",
        projectKey,
        tid: current.remote.tid,
        content: contentOf(current.desired),
      },
      {
        type: "release-task",
        projectKey,
        tid: current.remote.tid,
        resetComposer: true,
      },
    ],
  };
}

function ensureDraftSave(
  state: DraftState,
  projectKey: ProjectKey,
): DraftResult {
  const current = getSlot(state, projectKey);
  if (!isCurrentPresentEditing(current)) {
    throw new Error("Only a current present draft can save");
  }
  const schedule: SaveSchedule = {
    tid: current.remote.tid,
    formVersion: current.formVersion,
  };
  if (
    current.saveSchedule !== null &&
    current.saveSchedule.tid === schedule.tid &&
    current.saveSchedule.formVersion === schedule.formVersion
  ) {
    return { state, effects: [] };
  }
  return {
    state: replaceSlot(state, projectKey, {
      ...current,
      saveSchedule: schedule,
    }),
    effects: [
      {
        type: "ensure-draft-save",
        projectKey,
        tid: schedule.tid,
        formVersion: schedule.formVersion,
        delayMs: DRAFT_SAVE_DELAY_MS,
      },
    ],
  };
}

function releaseOwnership(current: DraftSlotState): DraftSlotState {
  const defaults =
    current.desired.kind === "none"
      ? current.defaults
      : defaultsOf(current.desired);
  return {
    ...current,
    defaults,
    observed: { text: "", ...defaults },
    desired: { kind: "none" },
    remote: { kind: "absent" },
    formVersion: current.formVersion + 1,
    createSchedule: null,
    saveSchedule: null,
  };
}

function cancelCreateEffect(
  current: DraftSlotState,
  projectKey: ProjectKey,
): DraftEffect[] {
  if (current.createSchedule === null) return [];
  return [
    {
      type: "cancel-create-schedule",
      projectKey,
      generation: current.createSchedule,
    },
  ];
}

function cancelSaveEffect(
  current: DraftSlotState,
  projectKey: ProjectKey,
): DraftEffect[] {
  if (current.saveSchedule === null) return [];
  return [
    {
      type: "cancel-draft-save",
      projectKey,
      tid: current.saveSchedule.tid,
      formVersion: current.saveSchedule.formVersion,
    },
  ];
}

function projectEffect(
  projectKey: ProjectKey,
  tid: number,
  current: DraftSlotState,
): DraftEffect {
  const form = selectDraftForm(
    { slots: { [projectKey]: current }, uuidBindings: [] },
    projectKey,
  );
  assertResolvedDraftForm(form);
  return {
    type: "project-draft",
    projectKey,
    tid,
    form,
    formVersion: current.formVersion,
  };
}

function deliveryFor(
  remote: Remote,
  uuid: DraftId,
): "atomic-create" | "send-when-present" {
  switch (remote.kind) {
    case "absent":
    case "deleting":
      return "atomic-create";

    case "creating":
      return remote.correlationId === uuid
        ? "send-when-present"
        : "atomic-create";

    case "present":
      return remote.generation === null || remote.generation === uuid
        ? "send-when-present"
        : "atomic-create";

    default:
      return assertNever(remote);
  }
}

function belongsToCurrentGeneration(slot: DraftSlotState): boolean {
  if (slot.remote.kind !== "present" || slot.desired.kind === "none") {
    return false;
  }
  return (
    slot.remote.generation === null ||
    slot.remote.generation === slot.desired.uuid
  );
}

function isCurrentPresentEditing(
  slot: DraftSlotState,
): slot is DraftSlotState & {
  desired: Extract<Desired, { kind: "editing" }>;
  remote: Extract<Remote, { kind: "present" }>;
} {
  return slot.desired.kind === "editing" && belongsToCurrentGeneration(slot);
}

function mergeObservedForm(
  desired: Extract<Desired, { kind: "editing" }>,
  observed: DraftForm,
  observation: TaskObservation,
): DraftForm {
  return {
    text: hasOwnProperty(observation, "text")
      ? acceptsObservedValue(desired.text, observed.text, observation.text!)
      : desired.text,
    entryPoint: hasOwnProperty(observation, "entryPoint")
      ? acceptsObservedValue(
          desired.entryPoint,
          observed.entryPoint,
          observation.entryPoint!,
        )
      : desired.entryPoint,
    agent: hasOwnProperty(observation, "agent")
      ? acceptsObservedValue(desired.agent, observed.agent, observation.agent!)
      : desired.agent,
  };
}

function mergeObservedDefaults(
  defaults: FormDefaults,
  form: DraftForm,
  observation: TaskObservation,
): FormDefaults {
  return {
    entryPoint: hasOwnProperty(observation, "entryPoint")
      ? form.entryPoint
      : defaults.entryPoint,
    agent: hasOwnProperty(observation, "agent") ? form.agent : defaults.agent,
  };
}

function mergeObservedBaseline(
  observed: DraftForm,
  observation: TaskObservation,
): DraftForm {
  return {
    text: hasOwnProperty(observation, "text")
      ? observation.text!
      : observed.text,
    entryPoint: hasOwnProperty(observation, "entryPoint")
      ? observation.entryPoint!
      : observed.entryPoint,
    agent: hasOwnProperty(observation, "agent")
      ? observation.agent!
      : observed.agent,
  };
}

function hasObservedFormFields(observation: TaskObservation): boolean {
  return (
    hasOwnProperty(observation, "text") ||
    hasOwnProperty(observation, "entryPoint") ||
    hasOwnProperty(observation, "agent")
  );
}

function assertObservedFormFieldTypes(observation: TaskObservation): void {
  assertObservedFormFieldType(observation, "text");
  assertObservedFormFieldType(observation, "entryPoint");
  assertObservedFormFieldType(observation, "agent");
}

function assertObservedFormFieldType(
  observation: TaskObservation,
  field: keyof DraftForm,
): void {
  if (
    hasOwnProperty(observation, field) &&
    typeof observation[field] !== "string"
  ) {
    throw new Error("Observed form field " + field + " must be a string");
  }
}

function assertObservedActivityFactTypes(observation: TaskObservation): void {
  assertObservedActivityFactType(observation, "active");
  assertObservedActivityFactType(observation, "processing");
  assertObservedActivityFactType(observation, "hasMessages");
}

function assertObservedActivityFactType(
  observation: TaskObservation,
  field: "active" | "processing" | "hasMessages",
): void {
  if (
    hasOwnProperty(observation, field) &&
    typeof observation[field] !== "boolean"
  ) {
    throw new Error("Observed activity field " + field + " must be a boolean");
  }
}

function hasOwnProperty(value: object, field: PropertyKey): boolean {
  return Object.prototype.hasOwnProperty.call(value, field);
}

function acceptsObservedValue<T extends string | null>(
  local: T,
  observed: T,
  incoming: string,
): T | string {
  return local === "" || local === observed ? incoming : local;
}

function isActiveSnapshot(snapshot: TaskSnapshot): boolean {
  return snapshot.active || snapshot.processing || snapshot.hasMessages;
}

function isActiveObservation(observation: TaskObservation): boolean {
  return (
    (hasOwnProperty(observation, "active") && observation.active === true) ||
    (hasOwnProperty(observation, "processing") &&
      observation.processing === true) ||
    (hasOwnProperty(observation, "hasMessages") &&
      observation.hasMessages === true)
  );
}

function assertPersistedSnapshot(
  snapshot: unknown,
): asserts snapshot is TaskSnapshot {
  if (typeof snapshot !== "object" || snapshot === null) {
    throw new Error("Persisted task snapshot must be complete");
  }

  const candidate = snapshot as Partial<TaskSnapshot>;
  assertPersistedSnapshotOwnProperties(candidate);
  assertTaskId(candidate.tid);
  if (
    typeof candidate.text !== "string" ||
    typeof candidate.entryPoint !== "string" ||
    typeof candidate.agent !== "string" ||
    typeof candidate.active !== "boolean" ||
    typeof candidate.processing !== "boolean" ||
    typeof candidate.hasMessages !== "boolean"
  ) {
    throw new Error("Persisted task snapshot must be complete");
  }

  assertPendingSnapshot(candidate as TaskSnapshot);
  assertNonEmptyPersistedSnapshot(candidate as TaskSnapshot);
}

function assertPersistedSnapshotOwnProperties(snapshot: object): void {
  for (const field of PERSISTED_SNAPSHOT_FIELDS) {
    if (!hasOwnProperty(snapshot, field)) {
      throw new Error("Persisted task snapshot must be complete");
    }
  }
}

function assertTaskId(tid: unknown): asserts tid is number {
  if (
    typeof tid !== "number" ||
    !Number.isInteger(tid) ||
    tid <= 0 ||
    tid > MAX_TASK_ID
  ) {
    throw new Error("Task ID must be a positive signed 32-bit integer");
  }
}

function assertPendingSnapshot(snapshot: TaskSnapshot): void {
  if (isActiveSnapshot(snapshot)) {
    throw new Error("Only a pending task can be adopted as a draft");
  }
}

function requireUuid(uuid: DraftId | undefined): DraftId {
  if (uuid === undefined || uuid.trim().length === 0) {
    throw new Error("A browser UUID is required");
  }
  return uuid;
}

function assertNonEmptyPersistedSnapshot(snapshot: TaskSnapshot): void {
  if (snapshot.text.trim().length === 0) {
    throw new Error("A persisted draft must have non-empty text");
  }
}

function assertFreshGeneration(state: DraftState, uuid: DraftId): void {
  if (state.uuidBindings.some((binding) => binding.uuid === uuid)) {
    throw new Error("A fresh generation UUID must not reuse a prior UUID");
  }

  assertUuidNotActive(state, uuid);
}

function assertUuidNotActive(state: DraftState, uuid: DraftId): void {
  for (const [, slot] of Object.entries(state.slots)) {
    if (slot.desired.kind !== "none" && slot.desired.uuid === uuid) {
      throw new Error("Draft UUID is already in use: " + uuid);
    }
    if (slot.remote.kind === "creating" && slot.remote.correlationId === uuid) {
      throw new Error("Draft UUID is already in flight: " + uuid);
    }
    if (slot.remote.kind === "present" && slot.remote.generation === uuid) {
      throw new Error("Draft UUID is already bound: " + uuid);
    }
  }
}

function recordFreshUuid(
  state: DraftState,
  projectKey: ProjectKey,
  uuid: DraftId,
): DraftState {
  return {
    ...state,
    uuidBindings: [...state.uuidBindings, { uuid, projectKey, tid: null }],
  };
}

function bindAcknowledgedUuid(
  state: DraftState,
  projectKey: ProjectKey,
  uuid: DraftId,
  tid: number,
): DraftState {
  const index = state.uuidBindings.findIndex(
    (binding) => binding.uuid === uuid,
  );
  if (index === -1) {
    throw new Error("Create acknowledgement has no fresh UUID binding");
  }
  const binding = state.uuidBindings[index]!;
  if (
    binding.projectKey !== projectKey ||
    (binding.tid !== null && isTidOwned(state, binding.tid))
  ) {
    throw new Error("Create acknowledgement UUID binding is incompatible");
  }
  return {
    ...state,
    uuidBindings: state.uuidBindings.map((candidate, candidateIndex) =>
      candidateIndex === index ? { ...candidate, tid } : candidate,
    ),
  };
}

function bindPersistedUuid(
  state: DraftState,
  projectKey: ProjectKey,
  uuid: DraftId,
  tid: number,
): DraftState {
  const binding = state.uuidBindings.find(
    (candidate) => candidate.uuid === uuid,
  );
  if (binding !== undefined) {
    if (binding.projectKey === projectKey && binding.tid === tid) {
      return state;
    }
    throw new Error("Browser UUID is already bound to another task");
  }
  assertUuidNotActive(state, uuid);
  return {
    ...state,
    uuidBindings: [...state.uuidBindings, { uuid, projectKey, tid }],
  };
}

function assertTidUnowned(
  state: DraftState,
  target: ProjectKey,
  tid: number,
): void {
  for (const [projectKey, slot] of Object.entries(state.slots)) {
    if (projectKey === target) continue;
    if (
      (slot.remote.kind === "present" || slot.remote.kind === "deleting") &&
      slot.remote.tid === tid
    ) {
      throw new Error(
        "Task ID is already owned by another slot: " + String(tid),
      );
    }
  }
}

function isTidOwned(state: DraftState, tid: number): boolean {
  return Object.values(state.slots).some(
    (slot) =>
      (slot.remote.kind === "present" || slot.remote.kind === "deleting") &&
      slot.remote.tid === tid,
  );
}

function findCreatingProject(
  state: DraftState,
  correlationId: DraftId,
): ProjectKey {
  const matches = Object.entries(state.slots).filter(
    ([, slot]) =>
      slot.remote.kind === "creating" &&
      slot.remote.correlationId === correlationId,
  );
  if (matches.length !== 1) {
    throw new Error(
      "Create acknowledgement does not match one owned generation",
    );
  }
  return matches[0]![0];
}

function findOwnedTid(state: DraftState, tid: number): ProjectKey {
  const matches = Object.entries(state.slots).filter(
    ([, slot]) =>
      (slot.remote.kind === "present" || slot.remote.kind === "deleting") &&
      slot.remote.tid === tid,
  );
  if (matches.length !== 1) {
    throw new Error("Task deletion does not match one owned task");
  }
  return matches[0]![0];
}

function replaceSlot(
  state: DraftState,
  projectKey: ProjectKey,
  value: DraftSlotState,
): DraftState {
  getSlot(state, projectKey);
  return { ...state, slots: { ...state.slots, [projectKey]: value } };
}

function defaultsOf(form: FormDefaults): FormDefaults {
  return { entryPoint: form.entryPoint, agent: form.agent };
}

function formOf(form: DraftForm): DraftForm {
  return {
    text: form.text,
    entryPoint: form.entryPoint,
    agent: form.agent,
  };
}

function contentOf(
  desired: Extract<Desired, { kind: "submitting" }>,
): DraftContent {
  return { text: desired.text, images: desired.images };
}
