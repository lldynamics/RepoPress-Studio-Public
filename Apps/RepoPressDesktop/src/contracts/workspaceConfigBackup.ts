import type { WorkspaceBackupExclusion } from "./workspaceBackup";

export const WORKSPACE_CONFIG_BACKUP_SOURCES = ["workspace", "siteProfiles", "aiProfiles"] as const;
export type WorkspaceConfigBackupSource = typeof WORKSPACE_CONFIG_BACKUP_SOURCES[number];
export const WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES = ["knowledge", "rss", "generalDrafts", "draftHistory"] as const;
export interface WorkspaceConfigBackupSummary {
  source: WorkspaceConfigBackupSource;
  sourceByteSize: number;
  itemCount: number;
  recoveryDraftCount: 0 | 1;
}
/** Explicit local plaintext export; not a complete workspace or coherent database snapshot. */
export interface WorkspaceConfigBackupPlan {
  planId: string;
  scope: "applicationPrivateConfiguration";
  format: "repopress-workspace-config";
  schemaVersion: 1;
  destinationPath: string;
  selectedSources: WorkspaceConfigBackupSource[];
  sources: WorkspaceConfigBackupSummary[];
  excludedSources: typeof WORKSPACE_CONFIG_BACKUP_EXCLUDED_SOURCES[number][];
  exclusions: WorkspaceBackupExclusion[];
  structureVerified: true;
  consistentSnapshot: false;
  includesCredentials: false;
  byteSize: number;
  sha256: string;
  createdAtEpochMs: number;
  expiresAtEpochMs: number;
}
export interface WorkspaceConfigBackupResult {
  planId: string;
  destinationPath: string;
  selectedSources: WorkspaceConfigBackupSource[];
  byteSize: number;
  sha256: string;
}
export interface WorkspaceConfigBackupGateway {
  selectWorkspaceConfigBackupDestination(): Promise<string | null>;
  planWorkspaceConfigBackup(sources: WorkspaceConfigBackupSource[], destinationPath: string): Promise<WorkspaceConfigBackupPlan>;
  executeWorkspaceConfigBackup(planId: string, confirmSensitivePlaintext: boolean): Promise<WorkspaceConfigBackupResult>;
  discardWorkspaceConfigBackup(planId: string): Promise<void>;
}
