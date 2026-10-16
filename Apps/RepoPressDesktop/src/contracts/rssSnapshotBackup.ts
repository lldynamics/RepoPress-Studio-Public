export const RSS_SNAPSHOT_TABLES = ["meta", "feeds", "articles", "highlights", "reading_progress", "undo_actions", "full_text_cache", "offline_translation_cache", "history_jobs", "history_failures"] as const;
export const RSS_SNAPSHOT_EXCLUSIONS = ["credentialStores", "otherWorkspaceSources", "externalAttachments"] as const;
export const RSS_SNAPSHOT_MAX_BYTES = 32 * 1024 * 1024;
export interface RssSnapshotTableSummary {
  table: typeof RSS_SNAPSHOT_TABLES[number];
  rowCount: number;
}
/** Plan protocol v1; the exported file is SQLite3 with RSS meta schema_version=4. */
export interface RssSnapshotBackupPlan {
  planId: string;
  scope: "applicationRssDatabase";
  format: "sqlite3";
  schemaVersion: 1;
  databaseSchemaVersion: 4;
  destinationPath: string;
  tables: RssSnapshotTableSummary[];
  exclusions: typeof RSS_SNAPSHOT_EXCLUSIONS[number][];
  structureVerified: true;
  consistentSnapshot: true;
  includesCredentialStores: false;
  includesUndoActions: true;
  compactedCopy: true;
  byteSize: number;
  sha256: string;
  createdAtEpochMs: number;
  expiresAtEpochMs: number;
}
export interface RssSnapshotBackupResult {
  planId: string;
  destinationPath: string;
  byteSize: number;
  sha256: string;
}
export interface RssSnapshotBackupGateway {
  selectRssSnapshotBackupDestination(): Promise<string | null>;
  planRssSnapshotBackup(destinationPath: string): Promise<RssSnapshotBackupPlan>;
  executeRssSnapshotBackup(planId: string, confirmSensitivePlaintext: boolean): Promise<RssSnapshotBackupResult>;
  discardRssSnapshotBackup(planId: string): Promise<void>;
}
