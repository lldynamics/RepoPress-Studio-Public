import type { RollbackBlocker, RollbackQualificationIdentity } from "./rollbackQualification";

export type RollbackPreviewWarning = "entryLimit" | "treeLimit" | "timeLimit" | "byteLimit" | "unsafePathsOmitted" | "objectsUnavailable" | "unsupportedTypes";
export type RollbackFileIssue = "unsupportedType" | "objectMissing" | "objectTooLarge" | "objectHashMismatch" | "budgetLimit";
export interface RollbackObjectSide {
  mode: string;
  objectId: string;
  byteSize: number | null;
}
export interface RollbackFileChange {
  path: string;
  action: "delete" | "restore" | "replace" | "unsupported";
  published: RollbackObjectSide | null;
  restore: RollbackObjectSide | null;
  verification: "verified" | "unavailable" | "unsupported";
  issues: RollbackFileIssue[];
}
/** Local objects only, no text payload, live remote check or mutation authority. */
export interface RollbackChangePreview extends RollbackQualificationIdentity {
  status: "complete" | "partial" | "blocked";
  changes: RollbackFileChange[];
  omittedPaths: number | null;
  blockers: RollbackBlocker[];
  warnings: RollbackPreviewWarning[];
  summary: { visible: number; deleteFiles: number; restoreFiles: number; replaceFiles: number; unsupportedFiles: number; verifiedFiles: number };
  checkedAtEpochMs: number;
}
export interface RollbackChangePreviewGateway {
  inspectRollbackChanges(sessionId: string, recordId: string, revision: number): Promise<RollbackChangePreview>;
}
