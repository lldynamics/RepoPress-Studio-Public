import { describe, expect, it, vi } from "vitest";
import type { KnowledgeIntegrityGateway, KnowledgeIntegrityRecheck, KnowledgeIntegrityReport } from "../contracts/knowledgeIntegrity";
import { createRepositoryGateway } from "./repositoryGateway";

const report = { reportId: "11111111-1111-4111-8111-111111111111" } as KnowledgeIntegrityReport;
const recheck = { report, comparison: "unchanged" } as KnowledgeIntegrityRecheck;

describe("knowledge integrity gateway", () => {
  it("uses exact native command names and payloads", async () => {
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      if (name === "inspect_knowledge_integrity") return report as T;
      if (name === "recheck_knowledge_integrity") return recheck as T;
      if (name === "discard_knowledge_integrity") return undefined as T;
      throw new Error(`unexpected command ${name}`);
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgeIntegrityGateway;
    await expect(gateway.inspectKnowledgeIntegrity()).resolves.toEqual(report);
    await expect(gateway.recheckKnowledgeIntegrity(report.reportId)).resolves.toEqual(recheck);
    await expect(gateway.discardKnowledgeIntegrity(report.reportId)).resolves.toBeUndefined();
    expect(invoke).toHaveBeenNthCalledWith(1, "inspect_knowledge_integrity", {});
    expect(invoke).toHaveBeenNthCalledWith(2, "recheck_knowledge_integrity", { reportId: report.reportId });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_knowledge_integrity", { reportId: report.reportId });
  });

  it("fails closed for every browser-demo action", async () => {
    const gateway = createRepositoryGateway() as unknown as KnowledgeIntegrityGateway;
    await expect(gateway.inspectKnowledgeIntegrity()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.recheckKnowledgeIntegrity(report.reportId)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeIntegrity(report.reportId)).rejects.toMatchObject({ code: "read_only_demo" });
  });
});
