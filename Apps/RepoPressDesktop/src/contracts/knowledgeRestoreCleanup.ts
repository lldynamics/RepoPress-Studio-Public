import type { KnowledgeRestoreArchiveEntry } from "./knowledgeRestoreArchive";
export type KnowledgeRestoreCleanupAction = "delete" | "resume";
export interface KnowledgeRestoreCleanupStatus {
  schemaVersion: 1; scope: "knowledgeRestoreCleanupStatus";
  state: "none" | "eligible" | "cleaning" | "cleaned" | "blocked" | "unavailable";
  cleanupId: string | null; selected: KnowledgeRestoreArchiveEntry | null;
  historyCount: number | null; historyLimit: 4; receiptCount: number | null; receiptLimit: 128;
  currentManifestSha256: string | null; remainingFileCount: number | null; remainingByteSize: number | null;
  canDelete: boolean; canResume: boolean; historySlotReleased: boolean;
  libraryAccessBlocked: boolean; filesystemWrites: false;
}
export interface KnowledgeRestoreCleanupPlan {
  schemaVersion: 1; scope: "knowledgeRestoreCleanupPlan"; planId: string;
  action: KnowledgeRestoreCleanupAction; status: KnowledgeRestoreCleanupStatus;
  requiresAcknowledgement: true; irreversible: true; currentLibraryChanged: false;
  deletesSnapshot: boolean; deletesHistory: true; preservesAuditReceipt: true;
  reclaimsHistorySlot: true; physicalSpaceReclaimedUnknown: true;
  checkedAtEpochMs: number; expiresAtEpochMs: number;
}
export interface KnowledgeRestoreCleanupReceipt {
  schemaVersion: 1; scope: "knowledgeRestoreCleanupReceipt"; planId: string;
  cleanupId: string; transactionId: string; action: KnowledgeRestoreCleanupAction; state: "cleaned";
  selected: KnowledgeRestoreArchiveEntry; removedFileCount: number; removedByteSize: number;
  currentLibraryChanged: false; historySlotReleased: true; auditReceiptPersisted: true;
  physicalSpaceReclaimedUnknown: true; completedAtEpochMs: number;
}
export interface KnowledgeRestoreCleanupGateway {
  inspectKnowledgeRestoreCleanup(): Promise<KnowledgeRestoreCleanupStatus>;
  planKnowledgeRestoreCleanup(transactionId: string, action: KnowledgeRestoreCleanupAction): Promise<KnowledgeRestoreCleanupPlan>;
  executeKnowledgeRestoreCleanup(planId: string, acknowledgeDeletion: boolean): Promise<KnowledgeRestoreCleanupReceipt>;
  discardKnowledgeRestoreCleanup(planId: string): Promise<void>;
}
