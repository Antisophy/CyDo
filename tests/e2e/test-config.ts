import { readFileSync, writeFileSync } from "fs";
import { join } from "path";

const agentSandboxEnvPath = join(__dirname, "agent-sandbox-env.yaml");

/**
 * Prepend the common explicit child environment to a complete CyDo config.
 *
 * Agent launch clears its environment by default. Every e2e config replacement
 * must retain this fragment instead of relying on the backend's parent env.
 */
export function withTestAgentEnvironment(config: string): string {
  const agentEnvironment = readFileSync(agentSandboxEnvPath, "utf8").trimEnd();
  return agentEnvironment + "\n" + config.trim() + "\n";
}

export function writeTestConfig(path: string, config: string): void {
  writeFileSync(path, withTestAgentEnvironment(config));
}
