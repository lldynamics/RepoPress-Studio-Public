export type OperationKind =
  | "metadataBatch" | "saveDocument" | "createDocument" | "renameDocument" | "deleteDocument"
  | "restoreDraftVersion" | "restoreRecycledDraft" | "deleteRecycledDraft"
  | "saveGeneralDraft" | "transferGeneralDraft" | "undoGeneralDraftTransfer"
  | "importWritingImage" | "gitIndexUpdate" | "gitOperation" | "remoteReview"
  | "knowledgeImport" | "knowledgeExport" | "knowledgeArchiveExport";

export type OperationOutcome = "succeeded" | "failed";

export interface OperationLogEntry {
  sequence: number;
  occurredAtEpochMs: number;
  kind: OperationKind;
  outcome: OperationOutcome;
  repositoryKey: string | null;
  durationMs: number;
}

export interface OperationLogSnapshot {
  entries: OperationLogEntry[];
  latestSequence: number;
  persistent: boolean;
  warning: string | null;
  currentRepositoryKey: string | null;
}
