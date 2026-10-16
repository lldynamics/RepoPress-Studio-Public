import { describe, expect, it, vi } from "vitest";
import type { RssSnapshotBackupGateway, RssSnapshotBackupPlan, RssSnapshotBackupResult } from "../contracts/rssSnapshotBackup";
import { RSS_SNAPSHOT_EXCLUSIONS, RSS_SNAPSHOT_TABLES } from "../contracts/rssSnapshotBackup";

const save = vi.fn(); vi.mock("@tauri-apps/plugin-dialog", () => ({ save }));
import { createRepositoryGateway } from "./repositoryGateway";

const plan: RssSnapshotBackupPlan = {
  planId: "11111111-1111-4111-8111-111111111111", scope: "applicationRssDatabase", format: "sqlite3", schemaVersion: 1, databaseSchemaVersion: 4,
  destinationPath: "/tmp/repopress-rss-snapshot.sqlite", tables: RSS_SNAPSHOT_TABLES.map((table, index) => ({ table, rowCount: index })),
  exclusions: [...RSS_SNAPSHOT_EXCLUSIONS], structureVerified: true, consistentSnapshot: true, includesCredentialStores: false, includesUndoActions: true, compactedCopy: true,
  byteSize: 4096, sha256: "a".repeat(64), createdAtEpochMs: Date.now(), expiresAtEpochMs: Date.now() + 300_000,
};
const result: RssSnapshotBackupResult = { planId: plan.planId, destinationPath: plan.destinationPath, byteSize: plan.byteSize, sha256: plan.sha256 };

describe("RSS snapshot backup gateway", () => {
  it("maps native save selection and the exact three IPC commands", async () => {
    save.mockResolvedValueOnce(plan.destinationPath);
    const invoke = vi.fn(async <T>(command: string): Promise<T> => command === "plan_rss_snapshot_backup" ? plan as T : command === "execute_rss_snapshot_backup" ? result as T : undefined as T);
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as RssSnapshotBackupGateway;
    await expect(gateway.selectRssSnapshotBackupDestination()).resolves.toBe(plan.destinationPath);
    await expect(gateway.planRssSnapshotBackup(plan.destinationPath)).resolves.toEqual(plan);
    await expect(gateway.executeRssSnapshotBackup(plan.planId, true)).resolves.toEqual(result);
    await expect(gateway.discardRssSnapshotBackup(plan.planId)).resolves.toBeUndefined();
    expect(save).toHaveBeenCalledWith({ title: "导出 RSS 数据库快照", defaultPath: "repopress-rss-snapshot.sqlite", filters: [{ name: "SQLite", extensions: ["sqlite"] }] });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_rss_snapshot_backup", { destinationPath: plan.destinationPath });
    expect(invoke).toHaveBeenNthCalledWith(2, "execute_rss_snapshot_backup", { planId: plan.planId, confirmSensitivePlaintext: true });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_rss_snapshot_backup", { planId: plan.planId });
  });

  it("fails closed for selection, planning, execution, and discard in browser demo", async () => {
    const invoke = vi.fn(); const gateway = createRepositoryGateway() as RssSnapshotBackupGateway;
    await expect(gateway.selectRssSnapshotBackupDestination()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planRssSnapshotBackup(plan.destinationPath)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeRssSnapshotBackup(plan.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardRssSnapshotBackup(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
