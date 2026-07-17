import { describe, expect, it } from "vitest";
import { applyRecoveredInputDraft } from "./inputDraft";

describe("applyRecoveredInputDraft", () => {
  it("does not coalesce a post-reload submission with removed messages", () => {
    expect(
      applyRecoveredInputDraft(
        'Please reply with "second-reply"\n\nstall session',
        'Please reply with "third-reply"',
      ),
    ).toBe('Please reply with "third-reply"');
  });

  it("restores a removed submitted message into an empty input", () => {
    expect(applyRecoveredInputDraft("restored", "")).toBe("restored");
  });
});
