import type { DeploymentCheckSnapshot } from "./repository";

export type ReleaseLedgerSource = "gitPush" | "remoteReview" | "rollback";
export type ReleaseLedgerStatus = "pushVerified" | "reviewVerified" | "unconfirmed" | "remoteDifferent" | "targetChanged" | "evidenceMismatch" | "rollbackCandidateObserved" | "rollbackOtherHeadObserved";

export interface RollbackHistoryDetail {
  sourceRecordId: string;
  sourceRevision: number;
  sourceSha: string;
  parentSha: string;
  sourceTreeSha: string;
  targetTreeSha: string;
  changedPaths: number;
  targetFiles: number;
  latestObservation: "unconfirmed" | "candidateObserved" | "otherHeadObserved";
  observedRemoteSha: string | null;
  candidateObservedAtEpochMs: number | null;
}
export interface RollbackLedgerDiagnostics {
  status: "available" | "unavailable";
  capacity: "available" | "limited" | "full" | "unavailable";
  globalRecords: number | null;
  payloadBytes: number | null;
  remainingPayloadBytes: number | null;
  localRecords: number | null;
  localUnresolved: number | null;
  maxRecords: 200;
  maxPayloadBytes: 4194304;
  maxRecordBytes: 65536;
  reservedObservationBytes: 51200;
  scopePartial: boolean;
  /** Only targets already visible in this repository. No foreign paths or IDs. */
  blockedTargets: { remoteUrl: string; branch: string; localUnresolved: number; pendingElsewhere: boolean }[];
  checkedAtEpochMs: number;
}

export interface ReleaseLedgerEntry {
  source: ReleaseLedgerSource;
  recordId: string;
  revision: number;
  operation: "push" | "pushRetry" | "githubReview" | "gitlabReview" | "rollbackAppend";
  branch: string;
  targetBranch: string | null;
  expectedSha: string;
  remoteUrl: string;
  startedAtEpochMs: number;
  checkedAtEpochMs: number | null;
  status: ReleaseLedgerStatus;
  /** Present only for the rollback source; absent on legacy P34 rows. */
  rollback?: RollbackHistoryDetail | null;
}

/** Read-only projection of the existing durable stores; never a deployment receipt. */
export interface ReleaseLedgerSnapshot {
  sessionId: string;
  entries: ReleaseLedgerEntry[];
  partialSources: ReleaseLedgerSource[];
  warnings: string[];
  summary: { total: number; verifiedPushes: number; verifiedReviews: number; needsAttention: number;
    rollbackTransactions?: number; historicalCandidateObservations?: number; unresolvedRollbackTransactions?: number };
  /** Optional for legacy clients; new native snapshots always supply it. */
  rollbackDiagnostics?: RollbackLedgerDiagnostics;
}

export interface ReleaseLedgerGateway {
  getReleaseLedger(sessionId: string): Promise<ReleaseLedgerSnapshot>;
}

/** Existing deployment queries lack a frozen commit identity, so remain unattributed. */
export interface UnattributedDeploymentObservation {
  sessionId: string;
  snapshot: DeploymentCheckSnapshot;
}
