import { describe, expect, it, vi } from "vitest";
import type {
  KnowledgeRestoreCleanupGateway,
  KnowledgeRestoreCleanupPlan,
  KnowledgeRestoreCleanupReceipt,
  KnowledgeRestoreCleanupStatus,
} from "../contracts/knowledgeRestoreCleanup";
import type { KnowledgeRestoreArchiveEntry } from "../contracts/knowledgeRestoreArchive";
import { createRepositoryGateway } from "./repositoryGateway";

const selected = {
  transactionId: "tx-1",
  phase: "committed",
  previousManifestSha256: "a".repeat(64),
  projectedManifestSha256: "b".repeat(64),
  snapshotManifestSha256: "c".repeat(64),
  snapshotPresent: true,
  snapshotFileCount: 2,
  snapshotByteSize: 8,
  archivedAtEpochMs: 1700000000000,
} satisfies KnowledgeRestoreArchiveEntry;

const status = {
  schemaVersion: 1,
  scope: "knowledgeRestoreCleanupStatus",
  state: "eligible",
  cleanupId: null,
  selected,
  historyCount: 1,
  historyLimit: 4,
  receiptCount: 1,
  receiptLimit: 128,
  currentManifestSha256: "d".repeat(64),
  remainingFileCount: 2,
  remainingByteSize: 8,
  canDelete: true,
  canResume: false,
  historySlotReleased: false,
  libraryAccessBlocked: false,
  filesystemWrites: false,
} satisfies KnowledgeRestoreCleanupStatus;

const resumeStatus = {
  ...status,
  state: "cleaning",
  cleanupId: "cleanup-1",
  canDelete: false,
  canResume: true,
  libraryAccessBlocked: true,
} satisfies KnowledgeRestoreCleanupStatus;

const deletePlan = {
  schemaVersion: 1,
  scope: "knowledgeRestoreCleanupPlan",
  planId: "plan-delete",
  action: "delete",
  status,
  requiresAcknowledgement: true,
  irreversible: true,
  currentLibraryChanged: false,
  deletesSnapshot: true,
  deletesHistory: true,
  preservesAuditReceipt: true,
  reclaimsHistorySlot: true,
  physicalSpaceReclaimedUnknown: true,
  checkedAtEpochMs: 1700000001000,
  expiresAtEpochMs: 1700000005000,
} satisfies KnowledgeRestoreCleanupPlan;

const resumePlan = {
  ...deletePlan,
  planId: "plan-resume",
  action: "resume",
  status: resumeStatus,
  deletesSnapshot: false,
} satisfies KnowledgeRestoreCleanupPlan;

const receipt = {
  schemaVersion: 1,
  scope: "knowledgeRestoreCleanupReceipt",
  planId: deletePlan.planId,
  cleanupId: "cleanup-1",
  transactionId: "tx-1",
  action: "delete",
  state: "cleaned",
  selected,
  removedFileCount: 2,
  removedByteSize: 8,
  currentLibraryChanged: false,
  historySlotReleased: true,
  auditReceiptPersisted: true,
  physicalSpaceReclaimedUnknown: true,
  completedAtEpochMs: 1700000006000,
} satisfies KnowledgeRestoreCleanupReceipt;

describe("knowledge restore cleanup gateway", () => {
  it("delegates all cleanup operations with exact IPC arguments", async () => {
    const invoke = vi.fn(async <T>(name: string, args?: object): Promise<T> => {
      const values: Record<string, unknown> = {
        inspect_knowledge_restore_cleanup: status,
        plan_knowledge_restore_cleanup: args && "action" in args && args.action === "resume" ? resumePlan : deletePlan,
        execute_knowledge_restore_cleanup: receipt,
        discard_knowledge_restore_cleanup: undefined,
      };
      if (!(name in values)) throw new Error(`unexpected command ${name}`);
      return values[name] as T;
    });
    const gateway = createRepositoryGateway(invoke as never) as unknown as KnowledgeRestoreCleanupGateway;

    await expect(gateway.inspectKnowledgeRestoreCleanup()).resolves.toEqual(status);
    await expect(gateway.planKnowledgeRestoreCleanup("tx-1", "delete")).resolves.toEqual(deletePlan);
    await expect(gateway.planKnowledgeRestoreCleanup("tx-1", "resume")).resolves.toEqual(resumePlan);
    await expect(gateway.executeKnowledgeRestoreCleanup(deletePlan.planId, false)).resolves.toEqual(receipt);
    await expect(gateway.executeKnowledgeRestoreCleanup(resumePlan.planId, true)).resolves.toEqual(receipt);
    await expect(gateway.discardKnowledgeRestoreCleanup(deletePlan.planId)).resolves.toBeUndefined();

    expect(invoke).toHaveBeenNthCalledWith(1, "inspect_knowledge_restore_cleanup");
    expect(invoke).toHaveBeenNthCalledWith(2, "plan_knowledge_restore_cleanup", { transactionId: "tx-1", action: "delete" });
    expect(invoke).toHaveBeenNthCalledWith(3, "plan_knowledge_restore_cleanup", { transactionId: "tx-1", action: "resume" });
    expect(invoke).toHaveBeenNthCalledWith(4, "execute_knowledge_restore_cleanup", { planId: deletePlan.planId, acknowledgeDeletion: false });
    expect(invoke).toHaveBeenNthCalledWith(5, "execute_knowledge_restore_cleanup", { planId: resumePlan.planId, acknowledgeDeletion: true });
    expect(invoke).toHaveBeenNthCalledWith(6, "discard_knowledge_restore_cleanup", { planId: deletePlan.planId });
  });

  it("fails closed for every cleanup operation in browser demo mode", async () => {
    const gateway = createRepositoryGateway() as unknown as KnowledgeRestoreCleanupGateway;

    await expect(gateway.inspectKnowledgeRestoreCleanup()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgeRestoreCleanup("tx-1", "delete")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeKnowledgeRestoreCleanup(deletePlan.planId, false)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeRestoreCleanup(deletePlan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
  });
});
