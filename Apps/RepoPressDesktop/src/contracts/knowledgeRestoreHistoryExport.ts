import type { KnowledgeRestoreArchiveEntry } from "./knowledgeRestoreArchive";

export interface KnowledgeRestoreHistoryExportStatus {
  schemaVersion: 1; scope: "knowledgeRestoreHistoryExportStatus";
  state: "none" | "ready" | "blocked" | "unavailable";
  history: KnowledgeRestoreArchiveEntry[]; historyLimit: 4;
  libraryAccessBlocked: boolean; filesystemWrites: false;
}
export interface KnowledgeRestoreHistoryExportPlan {
  schemaVersion: 1; scope: "knowledgeRestoreHistoryExportPlan"; planId: string;
  selected: KnowledgeRestoreArchiveEntry; destinationPath: string;
  byteSize: number; sha256: string; manifestSha256: string; sourceManifestSha256: string;
  itemCount: number; revisionCount: number; bodyFileCount: number; archiveFileCount: number; resourceByteSize: number;
  exclusions: string[]; requiresSensitivePlaintextConsent: true;
  currentLibraryChanged: false; sourceHistoryChanged: false; restoreReady: false;
  includesCredentialStores: false; includesCompletedOperations: false; externalReferencesIncluded: false; consistentSnapshot: false;
  checkedAtEpochMs: number; expiresAtEpochMs: number;
}
export interface KnowledgeRestoreHistoryExportReceipt {
  schemaVersion: 1; scope: "knowledgeRestoreHistoryExportReceipt"; planId: string;
  selected: KnowledgeRestoreArchiveEntry; destinationPath: string; byteSize: number;
  sha256: string; manifestSha256: string; sourceManifestSha256: string;
  sourceRevalidated: true; contentsVerified: true; privatePermissionsVerified: true;
  currentLibraryChanged: false; sourceHistoryChanged: false; restoreReady: false;
  completedAtEpochMs: number;
}
export interface KnowledgeRestoreHistoryExportGateway {
  inspectKnowledgeRestoreHistoryExport(): Promise<KnowledgeRestoreHistoryExportStatus>;
  selectKnowledgeRestoreHistoryExportDestination(): Promise<string | null>;
  planKnowledgeRestoreHistoryExport(transactionId: string, destinationPath: string): Promise<KnowledgeRestoreHistoryExportPlan>;
  executeKnowledgeRestoreHistoryExport(planId: string, confirmSensitivePlaintext: boolean): Promise<KnowledgeRestoreHistoryExportReceipt>;
  discardKnowledgeRestoreHistoryExport(planId: string): Promise<void>;
}
