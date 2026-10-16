import { describe, expect, it, vi } from "vitest";
import type {
  KnowledgeMergeProjectionGateway,
  KnowledgeMergeProjectionPlan,
  KnowledgeMergeProjectionReceipt,
} from "../contracts/knowledgeMergeProjection";

const open = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ open }));
import { createRepositoryGateway } from "./repositoryGateway";

const candidatePath = "/private/repopress-knowledge-stage-candidate";
const plan = {
  schemaVersion: 1,
  scope: "knowledgeMergeProjection",
  planId: "44444444-4444-4444-8444-444444444444",
  source: {} as KnowledgeMergeProjectionPlan["source"],
  projection: {
    state: "validated",
    reason: "none",
    manifestSha256: "a".repeat(64),
    manifestByteSize: 123,
    itemCount: 2,
    revisionCount: 2,
    folderCount: 1,
    fileCount: 2,
    resourceByteSize: 20,
    bodyByteSize: 10,
    archiveByteSize: 10,
    importedItems: 1,
    importedFolders: 0,
    resetPermissionItems: 1,
    completedOperationsExcluded: true,
  },
  limits: {} as KnowledgeMergeProjectionPlan["limits"],
  privacyMode: "disableImportedPermissions",
  privacyResetAcknowledgementRequired: true,
  currentPermissionsPreserved: true,
  sourcePermissionsCopied: false,
  projectedManifestValidated: true,
  filesystemWrites: false,
  currentLibraryChanged: false,
  restoreReady: false,
  consistentSnapshot: false,
  checkedAtEpochMs: 1_700_000_000_000,
  expiresAtEpochMs: 1_700_000_005_000,
} satisfies KnowledgeMergeProjectionPlan;
const receipt = {
  planId: plan.planId,
  projectionManifestSha256: plan.projection.manifestSha256!,
  itemCount: 2,
  revisionCount: 2,
  folderCount: 1,
  importedItems: 1,
  importedFolders: 0,
  resetPermissionItems: 1,
  privacyResetAcknowledged: true,
  importedPermissionsDisabled: true,
  currentPermissionsPreserved: true,
  sourcePermissionsCopied: false,
  validatedInMemory: true,
  filesystemWrites: false,
  currentLibraryChanged: false,
  restoreReady: false,
  consistentSnapshot: false,
  completedAtEpochMs: 1_700_000_001_000,
} satisfies KnowledgeMergeProjectionReceipt;

describe("knowledge merge projection gateway", () => {
  it("selects a private candidate and passes exact plan/preflight/discard IPC", async () => {
    open.mockResolvedValueOnce(candidatePath);
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      if (name === "plan_knowledge_merge_projection") return plan as T;
      if (name === "preflight_knowledge_merge_projection") return receipt as T;
      if (name === "discard_knowledge_merge_projection") return undefined as T;
      throw new Error(`unexpected command ${name}`);
    });
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgeMergeProjectionGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).resolves.toBe(candidatePath);
    await expect(gateway.planKnowledgeMergeProjection(candidatePath, "keepCurrentIdentities")).resolves.toEqual(plan);
    await expect(gateway.preflightKnowledgeMergeProjection(plan.planId, true)).resolves.toEqual(receipt);
    await expect(gateway.discardKnowledgeMergeProjection(plan.planId)).resolves.toBeUndefined();
    expect(open).toHaveBeenCalledWith({ title: "选择私有资料候选目录", multiple: false, directory: true });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_knowledge_merge_projection", { candidatePath, strategy: "keepCurrentIdentities" });
    expect(invoke).toHaveBeenNthCalledWith(2, "preflight_knowledge_merge_projection", { planId: plan.planId, acknowledgePrivacyReset: true });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_knowledge_merge_projection", { planId: plan.planId });
  });

  it("returns null when selection is cancelled", async () => {
    open.mockReset().mockResolvedValueOnce(null);
    const invoke = vi.fn();
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as unknown as KnowledgeMergeProjectionGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).resolves.toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });

  it("fails closed for all merge projection actions in browser demo mode", async () => {
    const invoke = vi.fn();
    const gateway = createRepositoryGateway() as unknown as KnowledgeMergeProjectionGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgeMergeProjection(candidatePath, "requireNoIdentityConflicts")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.preflightKnowledgeMergeProjection(plan.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeMergeProjection(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
