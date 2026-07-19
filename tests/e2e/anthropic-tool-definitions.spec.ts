import { existsSync, readFileSync } from "fs";
import {
  test,
  expect,
  enterSession,
  sendMessage,
  assistantText,
  responseTimeout,
} from "./fixtures";

type AnthropicCaptureSchema = {
  type?: string;
  description?: string;
  items?: AnthropicCaptureSchema;
  properties?: Record<string, AnthropicCaptureSchema>;
};

type AnthropicCaptureTool = {
  name: string | null;
  description: string | null;
  input_schema: AnthropicCaptureSchema | null;
};

type AnthropicCaptureRecord = {
  path: string;
  model: string;
  userText: string | null;
  isToolResult: boolean;
  tools: AnthropicCaptureTool[];
};

test("Claude forwards compact CyDo MCP descriptions to the Anthropic boundary", { tag: "@claude-only" }, async ({
  page,
  agentType,
}) => {
  const probeText = "anthropic tool definitions boundary check";
  const capturePath = process.env.MOCK_ANTHROPIC_CAPTURE;
  if (!capturePath) {
    throw new Error("MOCK_ANTHROPIC_CAPTURE is unset");
  }

  const readCaptureRecords = (startLine = 0): AnthropicCaptureRecord[] => {
    if (!existsSync(capturePath)) {
      return [];
    }
    return readFileSync(capturePath, "utf8")
      .split("\n")
      .filter((line) => line.trim().length > 0)
      .slice(startLine)
      .map((line) => JSON.parse(line) as AnthropicCaptureRecord);
  };
  const initialCaptureLineCount = readCaptureRecords().length;

  await enterSession(page);
  await sendMessage(page, probeText);
  await expect(
    assistantText(page, probeText),
  ).toBeVisible({ timeout: responseTimeout(agentType) });

  await expect
    .poll(() => {
      return readCaptureRecords(initialCaptureLineCount).find((record) =>
        !record.isToolResult &&
        record.tools.some(
          (tool) =>
            typeof tool.name === "string" &&
            tool.name.startsWith("mcp__cydo__"),
        ),
      )
        ? "found"
        : "missing";
    }, { timeout: responseTimeout(agentType) })
    .toBe("found");

  const cydoRecord = readCaptureRecords(initialCaptureLineCount)
    .filter((record) =>
      !record.isToolResult &&
      record.tools.some(
        (tool) =>
          typeof tool.name === "string" && tool.name.startsWith("mcp__cydo__"),
      ),
    )
    .at(-1);

  expect(cydoRecord, `No CyDo MCP tools captured in ${capturePath}`).toBeDefined();

  const cydoTools = cydoRecord!.tools.filter(
    (tool): tool is AnthropicCaptureTool & { name: string } =>
      typeof tool.name === "string" && tool.name.startsWith("mcp__cydo__"),
  );
  expect(cydoTools.length).toBeGreaterThan(0);

  for (const tool of cydoTools) {
    expect(tool.description, `${tool.name} description should be present`).not.toBeNull();
    expect(tool.description!.trim(), `${tool.name} description should not be empty`).not.toBe("");
    expect(tool.description!).not.toContain("[truncated]");
    expect(tool.description!).not.toContain("...[truncated]");
    expect(tool.description!.length).toBeLessThanOrEqual(2000);
  }

  const taskTool = cydoTools.find((tool) => tool.name === "mcp__cydo__Task");
  expect(taskTool, "Expected mcp__cydo__Task in captured CyDo tool list").toBeDefined();
  expect(taskTool!.description).toMatch(/follow-up|ask|qid|answer/i);
  expect(taskTool!.description).toContain(
    "Each created child appears in the CyDo task tree; the returned `tid` opens that child session.",
  );
  expect(taskTool!.description).toContain(
    "If the backend restarts, CyDo resumes in-flight child tasks and later delivers recovered results to the parent as a system message rather than through the interrupted Task call.",
  );
  expect(taskTool!.description).toContain(
    "Accepted multi-task batches launch every child before waiting, so the children run concurrently.",
  );
  expect(taskTool!.description).toContain(
    "a live batch returns after every child settles with one result item per requested task in request order, regardless of completion order.",
  );
  expect(taskTool!.input_schema?.properties?.tasks?.items?.properties?.prompt?.description).toBe(
    "The child task prompt; see the session's Create Sub-Tasks guidance for context requirements",
  );
});
