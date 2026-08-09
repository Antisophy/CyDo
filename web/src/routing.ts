// URL construction/decoding for the `/<workspace>/<project>/...` route family.

export function encodeProjectName(projectName: string): string {
  return projectName.replace(/\//g, ":");
}

export function decodeProjectSegment(segment: string): string {
  return segment.replace(/:/g, "/");
}

export function parseRoute(
  path: string,
  params: Record<string, string>,
): { workspace: string | null; project: string | null; tid: string | null } {
  const segments = path.split("/").filter(Boolean);
  const kind = segments[params.workspace !== undefined ? 2 : 0];
  const tid =
    kind === "archive"
      ? params.parentTid
        ? `archive:${params.parentTid}`
        : "archive"
      : kind === "import"
        ? "import"
        : (params.tid ?? params.sid ?? null);
  return {
    workspace: params.workspace ?? null,
    project: params.project ? decodeProjectSegment(params.project) : null,
    tid,
  };
}

export function buildProjectHref(
  workspace: string,
  projectName: string,
): string {
  return `/${workspace}/${encodeProjectName(projectName)}`;
}

export function buildScopedHref(
  workspace: string | null,
  projectName: string | null,
  suffix: string,
): string {
  if (workspace && projectName) {
    return `${buildProjectHref(workspace, projectName)}${suffix}`;
  }
  return suffix;
}

export function taskPath(
  workspace: string,
  projectName: string,
  tid: number | string,
): string {
  return `${buildProjectHref(workspace, projectName)}/task/${tid}`;
}

/**
 * The path a task URL should be rewritten to, or null when the URL is already
 * canonical or the task's project cannot be resolved.
 *
 * The comparison is against the round-trip of our own encoding, so it is a fixed
 * point of encode∘parse: a project name containing ':' cannot cause a redirect loop.
 */
export function canonicalTaskRedirect(args: {
  tid: number;
  taskWorkspace: string | null;
  taskProject: string | null;
  urlWorkspace: string | null;
  urlProject: string | null;
}): string | null {
  const { tid, taskWorkspace, taskProject, urlWorkspace, urlProject } = args;
  if (taskWorkspace === null || taskProject === null) return null;
  const canonicalProject = decodeProjectSegment(encodeProjectName(taskProject));
  if (urlWorkspace === taskWorkspace && urlProject === canonicalProject) {
    return null;
  }
  return taskPath(taskWorkspace, taskProject, tid);
}
