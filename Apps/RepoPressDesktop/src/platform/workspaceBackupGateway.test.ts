import { describe, expect, it, vi } from "vitest";
import type { WorkspaceBackupGateway, WorkspaceBackupRecheck, WorkspaceBackupReport } from "../contracts/workspaceBackup";
import { WORKSPACE_BACKUP_EXCLUSIONS, WORKSPACE_BACKUP_SOURCES } from "../contracts/workspaceBackup";
import { createRepositoryGateway } from "./repositoryGateway";

const report: WorkspaceBackupReport = {
  reportId: "11111111-1111-4111-8111-111111111111", schemaVersion: 1, scope: "applicationPrivateData", checkedAtEpochMs: 1_700_000_000_000,
  expiresAtEpochMs: 1_700_000_300_000, selectedSources: [...WORKSPACE_BACKUP_SOURCES],
  sources: WORKSPACE_BACKUP_SOURCES.map((source) => ({ source, status: "metadataOnly" as const, fileCount: 1, byteCount: 10, omittedEntries: 0, issues: [], requiresDatabaseSnapshot: ["rss", "generalDrafts", "draftHistory"].includes(source) })),
  exclusions: [...WORKSPACE_BACKUP_EXCLUSIONS], contentVerified: false, consistentSnapshot: false,
};
const recheck: WorkspaceBackupRecheck = { report: { ...report, reportId: "22222222-2222-4222-8222-222222222222", checkedAtEpochMs: 1_700_000_100_000, expiresAtEpochMs: 1_700_000_400_000 }, comparison: "changed" };

describe("workspace backup gateway", () => {
  it("maps the exact selected source scope and recheck/discard IPC calls", async () => {
    const invoke = vi.fn(async <T>(command: string): Promise<T> => command === "inspect_workspace_backup" ? report as T : command === "recheck_workspace_backup" ? recheck as T : undefined as T);
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as WorkspaceBackupGateway;
    await expect(gateway.inspectWorkspaceBackup([...WORKSPACE_BACKUP_SOURCES])).resolves.toEqual(report);
    await expect(gateway.recheckWorkspaceBackup(report.reportId)).resolves.toEqual(recheck);
    await expect(gateway.discardWorkspaceBackup(report.reportId)).resolves.toBeUndefined();
    expect(invoke).toHaveBeenNthCalledWith(1, "inspect_workspace_backup", { sources: [...WORKSPACE_BACKUP_SOURCES] });
    expect(invoke).toHaveBeenNthCalledWith(2, "recheck_workspace_backup", { reportId: report.reportId });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_workspace_backup", { reportId: report.reportId });
  });

  it("fails closed for all three browser-demo actions", async () => {
    const invoke = vi.fn(); const gateway = createRepositoryGateway() as WorkspaceBackupGateway;
    await expect(gateway.inspectWorkspaceBackup(["knowledge"])).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.recheckWorkspaceBackup(report.reportId)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardWorkspaceBackup(report.reportId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
