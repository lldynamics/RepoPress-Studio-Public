import type { PublishRecord } from "./publishLedger";
import type { RollbackCandidatePlan, RollbackCandidateBlocker } from "./rollbackCandidate";

export interface RollbackTransactionPlan extends Omit<RollbackCandidatePlan, "blockers"> {
  blockers: (RollbackCandidateBlocker | "remoteDifferent" | "remoteUnavailable" | "priorTransaction")[];
  candidateSha: string | null;
  observedRemoteSha: string | null;
}
/** Historical evidence. An observation does not prove who wrote the branch. */
export interface RollbackRecord {
  recordId: string;
  planId: string;
  sessionId: string;
  revision: number;
  source: PublishRecord;
  parentSha: string;
  sourceTreeSha: string;
  targetTreeSha: string;
  candidateSha: string;
  changedPaths: number;
  targetFiles: number;
  outcome: "unconfirmed" | "candidateObserved" | "otherHeadObserved";
  observedRemoteSha: string | null;
  startedAtEpochMs: number;
  checkedAtEpochMs: number | null;
  /** First exact candidate observation is retained even when the branch advances. */
  candidateObservedAtEpochMs: number | null;
}
export interface RollbackTransactionGateway {
  planRollbackTransaction(sessionId: string, recordId: string, revision: number): Promise<RollbackTransactionPlan>;
  executeRollbackTransaction(sessionId: string, planId: string): Promise<RollbackRecord>;
  discardRollbackTransaction(sessionId: string, planId: string): Promise<void>;
  listRollbackRecords(sessionId: string): Promise<RollbackRecord[]>;
  verifyRollbackRecord(sessionId: string, recordId: string, revision: number): Promise<RollbackRecord>;
}
