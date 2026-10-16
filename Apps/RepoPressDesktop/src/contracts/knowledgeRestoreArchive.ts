export type KnowledgeRestoreArchiveAction = "archive" | "resume";
export type KnowledgeRestoreTerminalPhase = "committed" | "rolledBack" | "cancelled";
export interface KnowledgeRestoreArchiveEntry {
  transactionId: string; phase: KnowledgeRestoreTerminalPhase;
  previousManifestSha256: string; projectedManifestSha256: string;
  snapshotManifestSha256: string | null; snapshotPresent: boolean;
  snapshotFileCount: number; snapshotByteSize: number; archivedAtEpochMs: number;
}
export interface KnowledgeRestoreArchiveStatus {
  schemaVersion: 1; scope: "knowledgeRestoreArchiveStatus";
  state: "none" | "eligible" | "archiving" | "archived" | "blocked" | "unavailable";
  transactionId: string | null; phase: KnowledgeRestoreTerminalPhase | null;
  currentManifestSha256: string | null; transactionJournalSha256: string | null;
  snapshotManifestSha256: string | null; snapshotPresent: boolean;
  snapshotFileCount: number | null; snapshotByteSize: number | null;
  history: KnowledgeRestoreArchiveEntry[]; historyLimit: 4;
  canArchive: boolean; canResume: boolean; transactionSlotReleased: boolean;
  libraryAccessBlocked: boolean; filesystemWrites: false;
}
export interface KnowledgeRestoreArchivePlan {
  schemaVersion: 1; scope: "knowledgeRestoreArchivePlan"; planId: string;
  action: KnowledgeRestoreArchiveAction; status: KnowledgeRestoreArchiveStatus;
  requiresAcknowledgement: true; preservesSnapshot: true; currentLibraryChanged: false;
  disablesDirectRollback: true; releasesTransactionSlot: true;
  checkedAtEpochMs: number; expiresAtEpochMs: number;
}
export interface KnowledgeRestoreArchiveReceipt {
  schemaVersion: 1; scope: "knowledgeRestoreArchiveReceipt"; planId: string;
  transactionId: string; action: KnowledgeRestoreArchiveAction; state: "archived";
  entry: KnowledgeRestoreArchiveEntry; snapshotRetained: boolean;
  currentLibraryChanged: false; transactionSlotReleased: true; journalArchived: true;
  libraryAccessBlocked: false; completedAtEpochMs: number;
}
export interface KnowledgeRestoreArchiveGateway {
  inspectKnowledgeRestoreArchive(): Promise<KnowledgeRestoreArchiveStatus>;
  planKnowledgeRestoreArchive(transactionId: string, action: KnowledgeRestoreArchiveAction): Promise<KnowledgeRestoreArchivePlan>;
  executeKnowledgeRestoreArchive(planId: string, acknowledgeArchive: boolean): Promise<KnowledgeRestoreArchiveReceipt>;
  discardKnowledgeRestoreArchive(planId: string): Promise<void>;
}
