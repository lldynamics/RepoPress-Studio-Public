import { describe, expect, it, vi } from "vitest";
import type { KnowledgeCandidateCheckGateway, KnowledgeCandidateCheckReport, KnowledgeCandidateRecheck } from "../contracts/knowledgeCandidateCheck";

const open = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ open }));
import { createRepositoryGateway } from "./repositoryGateway";

const report = {
  reportId: "11111111-1111-4111-8111-111111111111",
  candidatePath: "/private/repopress-knowledge-stage-11111111-1111-4111-8111-111111111111",
  schemaVersion: 1,
  scope: "selectedKnowledgeCandidate",
  stagePlanId: "22222222-2222-4222-8222-222222222222",
  sourcePackageSha256: "a".repeat(64),
  manifestSha256: "b".repeat(64),
  candidateInventorySha256: "c".repeat(64),
  candidateFileCount: 3,
  candidateByteSize: 42,
  itemCount: 1,
  revisionCount: 1,
  folderCount: 0,
  currentLibrary: { state: "checked", manifestSha256: "d".repeat(64), itemCount: 1, revisionCount: 1, folderCount: 0 },
  conflicts: { candidateOnlyItems: 0, currentOnlyItems: 0, identicalItems: 1, changedItems: 0, candidateOnlyFolders: 0, currentOnlyFolders: 0, identicalFolders: 0, changedFolders: 0 },
  limits: {} as KnowledgeCandidateCheckReport["limits"],
  candidateStructureVerified: true,
  candidateContentsVerified: true,
  privatePermissionsVerified: true,
  sourcePackageHashVerified: false,
  candidateAuthenticityVerified: false,
  currentLibraryResourcesVerified: false,
  comparisonScope: "manifestIdentityAndMetadataOnly",
  consistentSnapshot: false,
  filesystemWrites: false,
  currentLibraryChanged: false,
  restoreReady: false,
  checkedAtEpochMs: 1,
  expiresAtEpochMs: 2,
} satisfies KnowledgeCandidateCheckReport;
const recheck = { report, comparison: "unchanged" } satisfies KnowledgeCandidateRecheck;

describe("knowledge candidate check gateway", () => {
  it("uses the private directory selector and exact inspect/recheck/discard IPC", async () => {
    open.mockResolvedValueOnce(report.candidatePath);
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      if (name === "inspect_knowledge_candidate") return report as T;
      if (name === "recheck_knowledge_candidate") return recheck as T;
      if (name === "discard_knowledge_candidate_check") return undefined as T;
      throw new Error(`unexpected command ${name}`);
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgeCandidateCheckGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).resolves.toBe(report.candidatePath);
    await expect(gateway.inspectKnowledgeCandidate(report.candidatePath)).resolves.toEqual(report);
    await expect(gateway.recheckKnowledgeCandidate(report.reportId)).resolves.toEqual(recheck);
    await expect(gateway.discardKnowledgeCandidateCheck(report.reportId)).resolves.toBeUndefined();
    expect(open).toHaveBeenCalledWith({ title: "选择私有资料候选目录", multiple: false, directory: true });
    expect(invoke).toHaveBeenNthCalledWith(1, "inspect_knowledge_candidate", { candidatePath: report.candidatePath });
    expect(invoke).toHaveBeenNthCalledWith(2, "recheck_knowledge_candidate", { reportId: report.reportId });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_knowledge_candidate_check", { reportId: report.reportId });
  });

  it("returns null when the native directory selector is cancelled", async () => {
    open.mockReset().mockResolvedValueOnce(null);
    const invoke = vi.fn();
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgeCandidateCheckGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).resolves.toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });

  it("fails closed for all four browser-demo actions without IPC", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway() as unknown as KnowledgeCandidateCheckGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.inspectKnowledgeCandidate(report.candidatePath)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.recheckKnowledgeCandidate(report.reportId)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeCandidateCheck(report.reportId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
