import { describe, expect, it, vi } from "vitest";
import type { KnowledgeRestoreArchiveEntry } from "../contracts/knowledgeRestoreArchive";
import type {
  KnowledgeRestoreHistoryExportGateway,
  KnowledgeRestoreHistoryExportPlan,
  KnowledgeRestoreHistoryExportReceipt,
  KnowledgeRestoreHistoryExportStatus,
} from "../contracts/knowledgeRestoreHistoryExport";

const save = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ save }));
import { createRepositoryGateway } from "./repositoryGateway";

const selected = {
  transactionId: "tx-history-1",
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
  scope: "knowledgeRestoreHistoryExportStatus",
  state: "ready",
  history: [selected],
  historyLimit: 4,
  libraryAccessBlocked: false,
  filesystemWrites: false,
} satisfies KnowledgeRestoreHistoryExportStatus;

const destinationPath = "/tmp/repopress-knowledge-history.json";
const plan = {
  schemaVersion: 1,
  scope: "knowledgeRestoreHistoryExportPlan",
  planId: "history-plan-1",
  selected,
  destinationPath,
  byteSize: 1024,
  sha256: "d".repeat(64),
  manifestSha256: "e".repeat(64),
  sourceManifestSha256: "f".repeat(64),
  itemCount: 2,
  revisionCount: 3,
  bodyFileCount: 2,
  archiveFileCount: 1,
  resourceByteSize: 128,
  exclusions: ["credentialStores", "completedOperations", "externalReferences"],
  requiresSensitivePlaintextConsent: true,
  currentLibraryChanged: false,
  sourceHistoryChanged: false,
  restoreReady: false,
  includesCredentialStores: false,
  includesCompletedOperations: false,
  externalReferencesIncluded: false,
  consistentSnapshot: false,
  checkedAtEpochMs: 1700000001000,
  expiresAtEpochMs: 1700000301000,
} satisfies KnowledgeRestoreHistoryExportPlan;

const receipt = {
  schemaVersion: 1,
  scope: "knowledgeRestoreHistoryExportReceipt",
  planId: plan.planId,
  selected,
  destinationPath,
  byteSize: plan.byteSize,
  sha256: plan.sha256,
  manifestSha256: plan.manifestSha256,
  sourceManifestSha256: plan.sourceManifestSha256,
  sourceRevalidated: true,
  contentsVerified: true,
  privatePermissionsVerified: true,
  currentLibraryChanged: false,
  sourceHistoryChanged: false,
  restoreReady: false,
  completedAtEpochMs: 1700000002000,
} satisfies KnowledgeRestoreHistoryExportReceipt;

describe("knowledge restore history export gateway", () => {
  it("selects a native destination and delegates all four IPC commands exactly", async () => {
    save.mockReset().mockResolvedValueOnce(destinationPath);
    const invoke = vi.fn(async <T>(name: string): Promise<T> => {
      const values: Record<string, unknown> = {
        inspect_knowledge_restore_history_export: status,
        plan_knowledge_restore_history_export: plan,
        execute_knowledge_restore_history_export: receipt,
        discard_knowledge_restore_history_export: undefined,
      };
      if (!(name in values)) throw new Error(`unexpected command ${name}`);
      return values[name] as T;
    });
    const gateway = createRepositoryGateway(invoke as never) as unknown as KnowledgeRestoreHistoryExportGateway;

    await expect(gateway.selectKnowledgeRestoreHistoryExportDestination()).resolves.toBe(destinationPath);
    await expect(gateway.inspectKnowledgeRestoreHistoryExport()).resolves.toEqual(status);
    await expect(gateway.planKnowledgeRestoreHistoryExport(selected.transactionId, destinationPath)).resolves.toEqual(plan);
    await expect(gateway.executeKnowledgeRestoreHistoryExport(plan.planId, true)).resolves.toEqual(receipt);
    await expect(gateway.discardKnowledgeRestoreHistoryExport(plan.planId)).resolves.toBeUndefined();

    expect(save).toHaveBeenCalledWith({
      title: "选择新的恢复历史 JSON 文件路径",
      defaultPath: "repopress-knowledge-history-saved-files.json",
      filters: [{ name: "资料保存文件备份包", extensions: ["json"] }],
    });
    expect(invoke).toHaveBeenNthCalledWith(1, "inspect_knowledge_restore_history_export");
    expect(invoke).toHaveBeenNthCalledWith(2, "plan_knowledge_restore_history_export", { transactionId: selected.transactionId, destinationPath });
    expect(invoke).toHaveBeenNthCalledWith(3, "execute_knowledge_restore_history_export", { planId: plan.planId, confirmSensitivePlaintext: true });
    expect(invoke).toHaveBeenNthCalledWith(4, "discard_knowledge_restore_history_export", { planId: plan.planId });
  });

  it("returns null when the native destination selector is cancelled", async () => {
    save.mockReset().mockResolvedValueOnce(null);
    const invoke = vi.fn();
    const gateway = createRepositoryGateway(invoke as never) as unknown as KnowledgeRestoreHistoryExportGateway;

    await expect(gateway.selectKnowledgeRestoreHistoryExportDestination()).resolves.toBeNull();
    expect(invoke).not.toHaveBeenCalled();
  });

  it("fails closed for all five browser actions without native calls", async () => {
    save.mockReset();
    const invoke = vi.fn();
    const gateway = createRepositoryGateway() as unknown as KnowledgeRestoreHistoryExportGateway;

    await expect(gateway.inspectKnowledgeRestoreHistoryExport()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.selectKnowledgeRestoreHistoryExportDestination()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planKnowledgeRestoreHistoryExport(selected.transactionId, destinationPath)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeKnowledgeRestoreHistoryExport(plan.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardKnowledgeRestoreHistoryExport(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(save).not.toHaveBeenCalled();
    expect(invoke).not.toHaveBeenCalled();
  });
});
