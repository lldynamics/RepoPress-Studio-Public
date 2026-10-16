import { describe, expect, it, vi } from "vitest";
import type {
  KnowledgePackageStageGateway,
  KnowledgePackageStagePlan,
  KnowledgePackageStageResult,
} from "../contracts/knowledgePackageStage";

const open = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ open }));
import { createRepositoryGateway } from "./repositoryGateway";

const packageReport = {
  reportId: "11111111-1111-4111-8111-111111111111",
  sourcePath: "/private/source.json",
} as unknown as KnowledgePackageStagePlan["package"];
const plan = {
  planId: "22222222-2222-4222-8222-222222222222",
  sourcePath: "/private/source.json",
  parentPath: "/private/stage-parent",
  candidatePath: "/private/stage-parent/repopress-knowledge-stage-22222222-2222-4222-8222-222222222222",
  package: packageReport,
  candidateFileCount: 3,
  candidateByteSize: 12,
  candidateInventorySha256: "a".repeat(64),
  format: "repopress-knowledge-isolated-candidate",
  schemaVersion: 1,
  limits: { candidateFiles: 1026, candidateBytes: 34 * 1024 * 1024 + 4096, durationMs: 30000 },
  requiresSensitivePlaintextConsent: true,
  candidateOnly: true,
  currentLibraryChanged: false,
  restoreReady: false,
  createdAtEpochMs: 1,
  expiresAtEpochMs: 2,
} satisfies KnowledgePackageStagePlan;
const result = {
  planId: plan.planId,
  sourcePath: plan.sourcePath,
  candidatePath: plan.candidatePath,
  packageSha256: "b".repeat(64),
  manifestSha256: "c".repeat(64),
  candidateFileCount: plan.candidateFileCount,
  candidateByteSize: plan.candidateByteSize,
  candidateInventorySha256: plan.candidateInventorySha256,
  privatePermissionsVerified: true,
  contentsVerified: true,
  sourceRevalidated: true,
  candidateOnly: true,
  currentLibraryChanged: false,
  restoreReady: false,
} satisfies KnowledgePackageStageResult;

describe("knowledge package stage gateway", () => {
  it("uses exact selectors and IPC payloads for source, parent, plan, execute and discard", async () => {
    open.mockResolvedValueOnce(plan.sourcePath).mockResolvedValueOnce(plan.parentPath);
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      if (name === "plan_knowledge_package_stage") return plan as T;
      if (name === "execute_knowledge_package_stage") return result as T;
      if (name === "discard_knowledge_package_stage") return undefined as T;
      throw new Error(`unexpected command ${name}`);
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgePackageStageGateway;
    await expect(gateway.selectKnowledgePackageStageSource()).resolves.toBe(plan.sourcePath);
    await expect(gateway.selectKnowledgePackageStageParent()).resolves.toBe(plan.parentPath);
    await expect(gateway.planKnowledgePackageStage(plan.sourcePath, plan.parentPath)).resolves.toEqual(plan);
    await expect(gateway.executeKnowledgePackageStage(plan.planId, true)).resolves.toEqual(result);
    await expect(gateway.discardKnowledgePackageStage(plan.planId)).resolves.toBeUndefined();
    expect(open).toHaveBeenNthCalledWith(1, {
      title: "选择待暂存的资料 JSON 包",
      multiple: false,
      directory: false,
      filters: [{ name: "资料保存文件备份包", extensions: ["json"] }],
    });
    expect(open).toHaveBeenNthCalledWith(2, {
      title: "选择私有资料暂存目录的父目录",
      multiple: false,
      directory: true,
    });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_knowledge_package_stage", { sourcePath: plan.sourcePath, parentPath: plan.parentPath });
    expect(invoke).toHaveBeenNthCalledWith(2, "execute_knowledge_package_stage", { planId: plan.planId, confirmSensitivePlaintext: true });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_knowledge_package_stage", { planId: plan.planId });
  });

  it("returns null when either native selector is cancelled", async () => {
    open.mockReset().mockResolvedValueOnce(null).mockResolvedValueOnce(null);
    const invoke = vi.fn();
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgePackageStageGateway;
    await expect(gateway.selectKnowledgePackageStageSource()).resolves.toBeNull();
    await expect(gateway.selectKnowledgePackageStageParent()).resolves.toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });

  it("fails closed for every browser-demo action without IPC", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway() as unknown as KnowledgePackageStageGateway;
    await expect(gateway.selectKnowledgePackageStageSource()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.selectKnowledgePackageStageParent()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgePackageStage(plan.sourcePath, plan.parentPath)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeKnowledgePackageStage(plan.planId, false)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgePackageStage(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
