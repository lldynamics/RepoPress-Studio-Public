import { describe, expect, it } from "vitest";
import { executeMarkdownDiagnosticsWorker } from "./markdownDiagnostics.worker";

describe("markdown diagnostics worker", () => {
  it("runs the real diagnostics engine with UTF-16 ranges while ignoring inline code and CRLF", () => {
    const source = "`https://ignored.test`\r\nhttps://real.test";
    const response = executeMarkdownDiagnosticsWorker({ requestId: 7, source, knownArticleTitles: [] });
    expect(response.error).toBeUndefined();
    expect(response.requestId).toBe(7);
    expect(response.diagnostics).toHaveLength(1);
    expect(response.diagnostics?.[0]).toMatchObject({
      id: `bare-url-${source.indexOf("https://real.test")}`,
      range: { from: source.indexOf("https://real.test"), to: source.length },
    });
    expect(response.truncated).toBe(false);
  });

  it("returns a bounded report and marks omitted diagnostics", () => {
    const source = Array.from({ length: 501 }, (_, index) => `https://example.test/${index}`).join("\n");
    const response = executeMarkdownDiagnosticsWorker({ requestId: 8, source });
    expect(response.diagnostics).toHaveLength(500);
    expect(response.truncated).toBe(true);
  });

  it("uses the supplied title context in the real rule set", () => {
    const accepted = executeMarkdownDiagnosticsWorker({ requestId: 9, source: "[[Known]]", knownArticleTitles: ["Known"] });
    const missing = executeMarkdownDiagnosticsWorker({ requestId: 10, source: "[[Missing]]", knownArticleTitles: ["Known"] });
    expect(accepted.diagnostics).toEqual([]);
    expect(missing.diagnostics?.[0]?.id).toMatch(/^missing-internal-link-/);
  });

  it("rejects malformed and over-budget snapshots without running diagnostics", () => {
    expect(executeMarkdownDiagnosticsWorker(null)).toMatchObject({ requestId: 0, error: expect.any(String) });
    expect(executeMarkdownDiagnosticsWorker({ requestId: 11, source: "a".repeat(512 * 1024 + 1) }).error).toBeTruthy();
    expect(executeMarkdownDiagnosticsWorker({ requestId: 12, source: "x", knownArticleTitles: Array(20_001).fill("a") }).error).toBeTruthy();
    expect(executeMarkdownDiagnosticsWorker({ requestId: 13, source: "x", knownArticleTitles: ["a".repeat(1024 * 1024 + 1)] }).error).toBeTruthy();
    expect(executeMarkdownDiagnosticsWorker({ requestId: 14, source: "x", knownArticleTitles: [1] }).error).toBeTruthy();
  });
});
