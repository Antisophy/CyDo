// URL construction/decoding for the `/<workspace>/<project>/...` route family.

export function encodeProjectName(projectName: string): string {
  return projectName.replace(/\//g, ":");
}

export function decodeProjectSegment(segment: string): string {
  return segment.replace(/:/g, "/");
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
