export function applyRecoveredInputDraft(
  recovered: string,
  current: string,
): string {
  return current.length > 0 ? current : recovered;
}
