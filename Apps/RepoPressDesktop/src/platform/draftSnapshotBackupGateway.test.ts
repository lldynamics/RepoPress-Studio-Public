import { describe, expect, it, vi } from "vitest";
import type { DraftSnapshotBackupGateway, DraftSnapshotBackupPlan, DraftSnapshotBackupResult } from "../contracts/draftSnapshotBackup";

const save = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ save }));
import { createRepositoryGateway } from "./repositoryGateway";

const now = Date.now();
const plan: DraftSnapshotBackupPlan = {
  planId: "11111111-1111-4111-8111-111111111111", scope: "applicationDraftDatabase", format: "sqlite3", schemaVersion: 1,
  source: "generalDrafts", sourceSchema: "unversionedInstalledLayout", destinationPath: "/tmp/repopress-general-drafts.sqlite",
  tables: [{ table: "general_drafts", rowCount: 1 }], exclusions: ["credentialStores", "otherWorkspaceSources", "repositoryFiles", "externalAttachments", "runtimeTransferState"],
  structureVerified: true, contentVerified: true, consistentSnapshot: true, multiDatabaseSnapshot: false, includesCredentialStores: false,
  includesRecycledDrafts: false, compactedCopy: true, byteSize: 800, sha256: "a".repeat(64), createdAtEpochMs: now, expiresAtEpochMs: now + 300000,
};
const result: DraftSnapshotBackupResult = { planId: plan.planId, source: plan.source, destinationPath: plan.destinationPath, byteSize: plan.byteSize, sha256: plan.sha256 };

describe("draft snapshot backup gateway", () => {
  it("maps source-aware native selection and exact IPC payloads", async () => {
    save.mockResolvedValueOnce(plan.destinationPath).mockResolvedValueOnce("/tmp/repopress-draft-history.sqlite");
    const invoke = vi.fn(async <T>(command: string): Promise<T> => command === "plan_draft_snapshot_backup" ? plan as T : command === "execute_draft_snapshot_backup" ? result as T : undefined as T);
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as DraftSnapshotBackupGateway;
    await expect(gateway.selectDraftSnapshotBackupDestination("generalDrafts")).resolves.toBe(plan.destinationPath);
    await expect(gateway.selectDraftSnapshotBackupDestination("draftHistory")).resolves.toBe("/tmp/repopress-draft-history.sqlite");
    await expect(gateway.planDraftSnapshotBackup(plan.source, plan.destinationPath)).resolves.toEqual(plan);
    await expect(gateway.executeDraftSnapshotBackup(plan.planId, true)).resolves.toEqual(result);
    await expect(gateway.discardDraftSnapshotBackup(plan.planId)).resolves.toBeUndefined();
    expect(save).toHaveBeenNthCalledWith(1, { title: "导出草稿数据库快照", defaultPath: "repopress-general-drafts.sqlite", filters: [{ name: "SQLite", extensions: ["sqlite"] }] });
    expect(save).toHaveBeenNthCalledWith(2, { title: "导出草稿数据库快照", defaultPath: "repopress-draft-history.sqlite", filters: [{ name: "SQLite", extensions: ["sqlite"] }] });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_draft_snapshot_backup", { source: "generalDrafts", destinationPath: plan.destinationPath });
    expect(invoke).toHaveBeenNthCalledWith(2, "execute_draft_snapshot_backup", { planId: plan.planId, confirmSensitivePlaintext: true });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_draft_snapshot_backup", { planId: plan.planId });
  });

  it("fails closed for all four browser actions", async () => {
    const invoke = vi.fn(); const gateway = createRepositoryGateway() as DraftSnapshotBackupGateway;
    await expect(gateway.selectDraftSnapshotBackupDestination("generalDrafts")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planDraftSnapshotBackup("draftHistory", "/tmp/x.sqlite")).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeDraftSnapshotBackup(plan.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardDraftSnapshotBackup(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
