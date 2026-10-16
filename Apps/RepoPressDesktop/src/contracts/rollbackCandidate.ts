import type { RollbackQualificationIdentity, RollbackBlocker } from "./rollbackQualification";

export type RollbackCandidateBlocker = Exclude<RollbackBlocker, "remoteDifferent" | "remoteUnavailable"> | "previewIncomplete" | "targetSnapshotUnsupported" | "targetSnapshotUnsafe" | "snapshotLimit" | "noChanges";
export interface RollbackCandidatePlan extends RollbackQualificationIdentity {
  status: "ready" | "blocked";
  planId: string | null;
  sourceTreeSha: string | null;
  targetTreeSha: string | null;
  changedPaths: number;
  targetFiles: number;
  blockers: RollbackCandidateBlocker[];
  checkedAtEpochMs: number;
  expiresAtEpochMs: number | null;
}
/** A temporary, cleaned-up local candidate. No remote evidence or execution authority. */
export interface RollbackCandidateReport extends RollbackQualificationIdentity {
  planId: string;
  sourceTreeSha: string;
  targetTreeSha: string;
  candidateSha: string;
  changedPaths: number;
  targetFiles: number;
  generatedAtEpochMs: number;
  temporaryObjectsRemoved: true;
}
export interface RollbackCandidateGateway {
  planRollbackCandidate(sessionId: string, recordId: string, revision: number): Promise<RollbackCandidatePlan>;
  generateRollbackCandidate(sessionId: string, planId: string): Promise<RollbackCandidateReport>;
  discardRollbackCandidate(sessionId: string, planId: string): Promise<void>;
}
