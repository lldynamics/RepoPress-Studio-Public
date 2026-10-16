import { describe, expect, it, vi } from "vitest";
import type { WorkspaceConfigBackupGateway, WorkspaceConfigBackupPlan, WorkspaceConfigBackupResult } from "../contracts/workspaceConfigBackup";
import { WORKSPACE_CONFIG_BACKUP_SOURCES, WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES } from "../contracts/workspaceConfigBackup";
import { WORKSPACE_BACKUP_EXCLUSIONS } from "../contracts/workspaceBackup";

const save = vi.fn();
vi.mock("@tauri-apps/plugin-dialog", () => ({ save }));
import { createRepositoryGateway } from "./repositoryGateway";

const plan: WorkspaceConfigBackupPlan = {
  planId: "11111111-1111-4111-8111-111111111111", scope: "applicationPrivateConfiguration", format: "repopress-workspace-config", schemaVersion: 1,
  destinationPath: "/tmp/repopress-workspace-config.json", selectedSources: [...WORKSPACE_CONFIG_BACKUP_SOURCES],
  sources: WORKSPACE_CONFIG_BACKUP_SOURCES.map((source) => ({ source, sourceByteSize: 100, itemCount: source === "workspace" ? 1 : 2, recoveryDraftCount: 0 as const })),
  excludedSources: [...WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES], exclusions: [...WORKSPACE_BACKUP_EXCLUSIONS], structureVerified: true, consistentSnapshot: false, includesCredentials: false,
  byteSize: 800, sha256: "a".repeat(64), createdAtEpochMs: Date.now(), expiresAtEpochMs: Date.now() + 300_000,
};
const result: WorkspaceConfigBackupResult = { planId: plan.planId, destinationPath: plan.destinationPath, selectedSources: plan.selectedSources, byteSize: plan.byteSize, sha256: plan.sha256 };

describe("workspace config backup gateway", () => {
  it("maps native destination selection and the exact three Tauri commands", async () => {
    save.mockResolvedValueOnce(plan.destinationPath);
    const invoke = vi.fn(async <T>(command: string): Promise<T> => command === "plan_workspace_config_backup" ? plan as T : command === "execute_workspace_config_backup" ? result as T : undefined as T);
    const gateway = createRepositoryGateway(invoke as unknown as <T>(command: string, args?: object) => Promise<T>) as WorkspaceConfigBackupGateway;
    await expect(gateway.selectWorkspaceConfigBackupDestination()).resolves.toBe(plan.destinationPath);
    await expect(gateway.planWorkspaceConfigBackup([...WORKSPACE_CONFIG_BACKUP_SOURCES], plan.destinationPath)).resolves.toEqual(plan);
    await expect(gateway.executeWorkspaceConfigBackup(plan.planId, true)).resolves.toEqual(result);
    await expect(gateway.discardWorkspaceConfigBackup(plan.planId)).resolves.toBeUndefined();
    expect(save).toHaveBeenCalledWith({ title: "导出已保存配置备份", defaultPath: "repopress-workspace-config.json", filters: [{ name: "JSON", extensions: ["json"] }] });
    expect(invoke).toHaveBeenNthCalledWith(1, "plan_workspace_config_backup", { sources: [...WORKSPACE_CONFIG_BACKUP_SOURCES], destinationPath: plan.destinationPath });
    expect(invoke).toHaveBeenNthCalledWith(2, "execute_workspace_config_backup", { planId: plan.planId, confirmSensitivePlaintext: true });
    expect(invoke).toHaveBeenNthCalledWith(3, "discard_workspace_config_backup", { planId: plan.planId });
  });

  it("fails closed for all four browser-demo actions", async () => {
    const invoke = vi.fn(); const gateway = createRepositoryGateway() as WorkspaceConfigBackupGateway;
    await expect(gateway.selectWorkspaceConfigBackupDestination()).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.planWorkspaceConfigBackup(["workspace"], plan.destinationPath)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.executeWorkspaceConfigBackup(plan.planId, true)).rejects.toMatchObject({ code: "read_only_demo" });
    await expect(gateway.discardWorkspaceConfigBackup(plan.planId)).rejects.toMatchObject({ code: "read_only_demo" });
    expect(invoke).not.toHaveBeenCalled();
  });
});
