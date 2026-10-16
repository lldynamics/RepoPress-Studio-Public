export const DRAFT_SNAPSHOT_SOURCES = ["generalDrafts", "draftHistory"] as const;
export type DraftSnapshotSource = typeof DRAFT_SNAPSHOT_SOURCES[number];
export const DRAFT_SNAPSHOT_TABLES = { generalDrafts: ["general_drafts"], draftHistory: ["drafts", "versions", "recycled_drafts"] } as const;
export const DRAFT_SNAPSHOT_EXCLUSIONS = ["credentialStores", "otherWorkspaceSources", "repositoryFiles", "externalAttachments", "runtimeTransferState"] as const;
export const DRAFT_SNAPSHOT_MAX_BYTES = 32 * 1024 * 1024;
/** Protocol v1 validates the installed unversioned layout; it adds no source DB version. */
export interface DraftSnapshotBackupPlan {
  planId: string;
  scope: "applicationDraftDatabase";
  format: "sqlite3";
  schemaVersion: 1;
  source: DraftSnapshotSource;
  sourceSchema: "unversionedInstalledLayout";
  destinationPath: string;
  tables: { table: typeof DRAFT_SNAPSHOT_TABLES[DraftSnapshotSource][number]; rowCount: number }[];
  exclusions: typeof DRAFT_SNAPSHOT_EXCLUSIONS[number][];
  structureVerified: true;
  contentVerified: true;
  consistentSnapshot: true;
  multiDatabaseSnapshot: false;
  includesCredentialStores: false;
  includesRecycledDrafts: boolean;
  compactedCopy: true;
  byteSize: number;
  sha256: string;
  createdAtEpochMs: number;
  expiresAtEpochMs: number;
}
export interface DraftSnapshotBackupResult {
  planId: string;
  source: DraftSnapshotSource;
  destinationPath: string;
  byteSize: number;
  sha256: string;
}
export interface DraftSnapshotBackupGateway {
  selectDraftSnapshotBackupDestination(source: DraftSnapshotSource): Promise<string | null>;
  planDraftSnapshotBackup(source: DraftSnapshotSource, destinationPath: string): Promise<DraftSnapshotBackupPlan>;
  executeDraftSnapshotBackup(planId: string, confirmSensitivePlaintext: boolean): Promise<DraftSnapshotBackupResult>;
  discardDraftSnapshotBackup(planId: string): Promise<void>;
}
