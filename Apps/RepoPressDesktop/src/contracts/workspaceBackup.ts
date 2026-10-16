export const WORKSPACE_BACKUP_SOURCES = ["knowledge", "rss", "generalDrafts", "draftHistory", "workspace", "siteProfiles", "aiProfiles"] as const;
export type WorkspaceBackupSource = typeof WORKSPACE_BACKUP_SOURCES[number];
export const WORKSPACE_BACKUP_EXCLUSIONS = ["credentials", "encryptedChat", "releaseLedgers", "operationLogs", "repositoryFiles", "externalAttachments", "runtimeState", "unknownLocations"] as const;
export type WorkspaceBackupExclusion = typeof WORKSPACE_BACKUP_EXCLUSIONS[number];
export type WorkspaceBackupIssue = "unsafeEntry" | "readFailed" | "entryLimit" | "byteLimit" | "timeLimit" | "unknownEntries" | "primaryMissing" | "changedDuringRead" | "storageUnavailable";
export interface WorkspaceBackupSourceInventory {
  source: WorkspaceBackupSource;
  status: "metadataOnly" | "notFound" | "unavailable" | "limited";
  fileCount: number | null;
  byteCount: number | null;
  omittedEntries: number | null;
  issues: WorkspaceBackupIssue[];
  requiresDatabaseSnapshot: boolean;
}
/** Metadata only. No content validation, coherent database copy, or export authority. */
export interface WorkspaceBackupReport {
  reportId: string;
  schemaVersion: 1;
  scope: "applicationPrivateData";
  checkedAtEpochMs: number;
  expiresAtEpochMs: number;
  selectedSources: WorkspaceBackupSource[];
  sources: WorkspaceBackupSourceInventory[];
  exclusions: WorkspaceBackupExclusion[];
  contentVerified: false;
  consistentSnapshot: false;
}
export interface WorkspaceBackupRecheck {
  report: WorkspaceBackupReport;
  comparison: "unchanged" | "changed" | "inconclusive";
}
export interface WorkspaceBackupGateway {
  inspectWorkspaceBackup(sources: WorkspaceBackupSource[]): Promise<WorkspaceBackupReport>;
  recheckWorkspaceBackup(reportId: string): Promise<WorkspaceBackupRecheck>;
  discardWorkspaceBackup(reportId: string): Promise<void>;
}
