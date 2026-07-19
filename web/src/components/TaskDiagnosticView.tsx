import { Markdown } from "./Markdown";

export function TaskDiagnosticView({
  severity,
  subject,
  body,
}: {
  severity: "info" | "warning" | "error";
  subject: string;
  body: string;
}) {
  if (severity === "info")
    return (
      <div class="message system-message diagnostic-message diagnostic-info">
        <div class="system-message-label">{subject}</div>
        <Markdown text={body} />
      </div>
    );
  const blockClass = severity === "error" ? "error-block" : "warning-block";
  const labelClass =
    severity === "error" ? "error-block-label" : "warning-block-label";
  return (
    <div class={`diagnostic-message diagnostic-${severity}`}>
      <div class={blockClass}>
        <div class={labelClass}>{subject}</div>
        <Markdown text={body} />
      </div>
    </div>
  );
}
