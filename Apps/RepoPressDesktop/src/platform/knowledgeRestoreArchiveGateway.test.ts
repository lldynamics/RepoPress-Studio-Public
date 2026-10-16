import { describe, expect, it, vi } from "vitest";
import type {
  KnowledgeRestoreArchiveGateway,
  KnowledgeRestoreArchivePlan,
  KnowledgeRestoreArchiveReceipt,
  KnowledgeRestoreArchiveStatus,
} from "../contracts/knowledgeRestoreArchive";
import { createRepositoryGateway } from "./repositoryGateway";

const status = {
  schemaVersion: 1,
  scope: "knowledgeRestoreArchiveStatus",
  state: "eligible",
  transactionId: "tx-1",
  phase: "committed",
  currentManifestSha256: "a".repeat(64),
  transactionJournalSha256: "b".repeat(64),
  snapshotManifestSha256: "c".repeat(64),
  snapshotPresent: true,
  snapshotFileCount: 2,
  snapshotByteSize: 8,
  history: [],
  historyLimit: 4,
  canArchive: true,
  canResume: false,
  transactionSlotReleased: false,
  libraryAccessBlocked: false,
  filesystemWrites: false,
} satisfies KnowledgeRestoreArchiveStatus;

const plan = {
  schemaVersion: 1,
  scope: "knowledgeRestoreArchivePlan",
  planId: "plan-1",
  action: "archive",
  status,
  requiresAcknowledgement: true,
  preservesSnapshot: true,
  currentLibraryChanged: false,
  disablesDirectRollback: true,
  releasesTransactionSlot: true,
  checkedAtEpochMs: 1700000000000,
  expiresAtEpochMs: 1700000005000,
} satisfies KnowledgeRestoreArchivePlan;

const receipt = {
  schemaVersion: 1,
  scope: "knowledgeRestoreArchiveReceipt",
  planId: plan.planId,
  transactionId: "tx-1",
  action: "archive",
  state: "archived",
  entry: {
    transactionId: "tx-1",
    phase: "committed",
    previousManifestSha256: "a".repeat(64),
    projectedManifestSha256: "d".repeat(64),
    snapshotManifestSha256: "c".repeat(64),
    snapshotPresent: true,
    snapshotFileCount: 2,
    snapshotByteSize: 8,
    archivedAtEpochMs: 1700000006000,
  },
  snapshotRetained: true,
  currentLibraryChanged: false,
  transactionSlotReleased: true,
  journalArchived: true,
  libraryAccessBlocked: false,
  completedAtEpochMs: 1700000006000,
} satisfies KnowledgeRestoreArchiveReceipt;

describe("knowledge restore archive gateway", () => {
  it("forwards inspect, plan, execute, and discard IPC contracts", async () => {
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      const values: Record<string, unknown> = {
        inspect_knowledge_restore_archive: status,
        plan_knowledge_restore_archive: plan,
        execute_knowledge_restore_archive: receipt,
        discard_knowledge_restore_archive: undefined,
      };
      if (!(name in values)) throw new Error(`unexpected command ${name}`);
      return values[name] as T;
    });
    const gateway = createRepositoryGateway(invoke as never) as unknown as KnowledgeRestoreArchiveGateway;

    await expect(gateway.inspectKnowledgeRestoreArchive()).resolves.toEqual(status);
    await expect(gateway.planKnowledgeRestoreArchive("tx-1", "archive")).resolves.toEqual(plan);
    await expect(gateway.executeKnowledgeRestoreArchive(plan.planId, true)).resolves.toEqual(receipt);
    await expect(gateway.discardKnowledgeRestoreArchive(plan.planId)).resolves.toBeUndefined();

    expect(invoke).toHaveBeenNthCalledWith(1, "inspect_knowledge_restore_archive");
    expect(invoke).toHaveBeenNthCalledWith(2, "plan_knowledge_restore_archive", { transactionId: "tx-1", action: "archive" });
    expect(invoke).toHaveBeenNthCalledWith(3, "execute_knowledge_restore_archive", { planId: plan.planId, acknowledgeArchive: true });
    expect(invoke).toHaveBeenNthCalledWith(4, "discard_knowledge_restore_archive", { planId: plan.planId });
  });

  it("fails closed in browser mode for every archive operation", async () => {
    const gateway = createRepositoryGateway() as unknown as KnowledgeRestoreArchiveGateway;
    await expect(gateway.inspectKnowledgeRestoreArchive()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgeRestoreArchive("tx-1", "resume")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeKnowledgeRestoreArchive(plan.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeRestoreArchive(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
  });
});
