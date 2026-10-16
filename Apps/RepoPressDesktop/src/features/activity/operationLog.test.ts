import { describe, expect, it } from "vitest";
import { filterOperationLog, formatOperationDate, formatOperationDuration, operationCategory, operationKindLabel, OPERATION_KIND_LABELS } from "./operationLog";
import type { OperationKind, OperationLogEntry } from "../../contracts/activity";

const kinds = Object.keys(OPERATION_KIND_LABELS) as OperationKind[];
const entry = (kind: OperationKind, sequence: number, repositoryKey: string | null = "repo") => ({ sequence, occurredAtEpochMs: sequence * 1000, durationMs: 10, kind, outcome: "succeeded", repositoryKey }) as OperationLogEntry;

describe("operation log presentation", () => {
  it("classifies and labels every supported operation", () => {
    expect(kinds).toHaveLength(18);
    expect(new Set(kinds.map(operationKindLabel)).size).toBe(18);
    expect(operationKindLabel("metadataBatch")).toBe("批量标签与分类");
    expect(kinds.map(operationCategory)).toEqual(["writing", "writing", "writing", "writing", "draft", "draft", "draft", "draft", "draft", "draft", "image", "publish", "publish", "writing", "publish", "knowledge", "knowledge", "knowledge"]);
  });
  it("filters by category, outcome, repository and action label", () => {
    const entries = [entry("saveDocument", 1), entry("gitOperation", 2, null), { ...entry("knowledgeImport", 3), outcome: "failed" as const }];
    expect(filterOperationLog(entries, { category: "publish", outcome: "all", repository: "all", query: "" }, "repo")).toHaveLength(1);
    expect(filterOperationLog(entries, { category: "all", outcome: "failed", repository: "all", query: "导入" }, "repo")[0].kind).toBe("knowledgeImport");
    expect(filterOperationLog(entries, { category: "all", outcome: "all", repository: "unlinked", query: "" }, "repo")[0].kind).toBe("gitOperation");
  });
  it("handles invalid dates and durations without throwing", () => {
    expect(formatOperationDate(Number.NaN)).toBe("时间未知");
    expect(formatOperationDuration(Number.NaN)).toBe("耗时未知");
    expect(formatOperationDuration(1_500)).toContain("秒");
  });
});
