import { describe, expect, it, vi } from "vitest";
import type {
  KnowledgeRestoreInstallGateway,
  KnowledgeRestoreInstallPlan,
  KnowledgeRestoreDiagnosis,
  KnowledgeRestoreReceipt,
  KnowledgeRestoreRecoveryPlan,
} from "../contracts/knowledgeRestoreInstall";

const open = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ open }));
import { createRepositoryGateway } from "./repositoryGateway";

const candidate = "/private/repopress-knowledge-candidate";
const plan = {
  schemaVersion: 1, scope: "knowledgeRestoreInstall", planId: "11111111-1111-4111-8111-111111111111",
  projection: {} as KnowledgeRestoreInstallPlan["projection"], requiresAcknowledgement: true,
  writesCurrentLibrary: true, preservesRollbackSnapshot: true, importedPermissionsDisabled: true,
  currentOnlyPreserved: true, completedOperationsExcluded: true, transactionLimit: 1,
  checkedAtEpochMs: 1700000000000, expiresAtEpochMs: 1700000005000,
} satisfies KnowledgeRestoreInstallPlan;
const diagnosis = {
  schemaVersion: 1, scope: "knowledgeRestoreDiagnosis", state: "none", transactionId: null, phase: null,
  previousManifestSha256: null, projectedManifestSha256: null, canFinalize: false, canRollback: false,
  canCancel: false, libraryAccessBlocked: false, snapshotRetained: false, filesystemWrites: false,
} satisfies KnowledgeRestoreDiagnosis;
const recovery = {
  schemaVersion: 1, scope: "knowledgeRestoreRecovery", planId: "22222222-2222-4222-8222-222222222222",
  transactionId: "33333333-3333-4333-8333-333333333333", action: "cancel", diagnosis,
  requiresAcknowledgement: true, preservesSnapshot: true, checkedAtEpochMs: 1700000000000,
  expiresAtEpochMs: 1700000005000,
} satisfies KnowledgeRestoreRecoveryPlan;
const receipt = {
  schemaVersion: 1, scope: "knowledgeRestoreReceipt", planId: plan.planId,
  transactionId: "33333333-3333-4333-8333-333333333333", state: "committed", action: "install",
  previousManifestSha256: "a".repeat(64), projectedManifestSha256: "b".repeat(64),
  importedPermissionsDisabled: true, snapshotRetained: true, journalPersisted: true,
  libraryAccessBlocked: false, completedAtEpochMs: 1700000001000,
} satisfies KnowledgeRestoreReceipt;

describe("knowledge restore install gateway", () => {
  it("selects a candidate and forwards install and recovery IPC contracts", async () => {
    open.mockResolvedValueOnce(candidate);
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      const values: Record<string, unknown> = {
        plan_knowledge_restore_install: plan,
        execute_knowledge_restore_install: receipt,
        inspect_knowledge_restore: diagnosis,
        plan_knowledge_restore_recovery: recovery,
        execute_knowledge_restore_recovery: receipt,
        discard_knowledge_restore_install: undefined,
      };
      if (!(name in values)) throw new Error(`unexpected command ${name}`);
      return values[name] as T;
    });
    const gateway = createRepositoryGateway(invoke as never) as unknown as KnowledgeRestoreInstallGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).resolves.toBe(candidate);
    await expect(gateway.planKnowledgeRestoreInstall(candidate, "keepCurrentIdentities")).resolves.toEqual(plan);
    await expect(gateway.executeKnowledgeRestoreInstall(plan.planId, true)).resolves.toEqual(receipt);
    await expect(gateway.inspectKnowledgeRestore()).resolves.toEqual(diagnosis);
    await expect(gateway.planKnowledgeRestoreRecovery(recovery.transactionId, "cancel")).resolves.toEqual(recovery);
    await expect(gateway.executeKnowledgeRestoreRecovery(recovery.planId, true)).resolves.toEqual(receipt);
    await expect(gateway.discardKnowledgeRestoreInstall(plan.planId)).resolves.toBeUndefined();
    expect(open).toHaveBeenCalledWith({ title: "选择私有资料候选目录", multiple: false, directory: true });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_knowledge_restore_install", { candidatePath: candidate, strategy: "keepCurrentIdentities" });
    expect(invoke).toHaveBeenNthCalledWith(2, "execute_knowledge_restore_install", { planId: plan.planId, acknowledgeInstall: true });
    expect(invoke).toHaveBeenNthCalledWith(3, "inspect_knowledge_restore");
    expect(invoke).toHaveBeenNthCalledWith(4, "plan_knowledge_restore_recovery", { transactionId: recovery.transactionId, action: "cancel" });
  });

  it("returns null on cancellation and fails closed in browser mode", async () => {
    open.mockReset().mockResolvedValueOnce(null);
    const gateway = createRepositoryGateway() as unknown as KnowledgeRestoreInstallGateway;
    await expect(gateway.selectKnowledgeCandidateDirectory()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgeRestoreInstall(candidate, "keepCurrentIdentities")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeKnowledgeRestoreInstall(plan.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.inspectKnowledgeRestore()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgeRestoreRecovery(recovery.transactionId, "cancel")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeKnowledgeRestoreRecovery(recovery.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeRestoreInstall(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    const invoke = vi.fn();
    const tauri = createRepositoryGateway(invoke as never) as unknown as KnowledgeRestoreInstallGateway;
    await expect(tauri.selectKnowledgeCandidateDirectory()).resolves.toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });
});
