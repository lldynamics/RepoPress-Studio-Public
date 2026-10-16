/** P35 checks basic historical push conditions; it never authorizes a rollback. */
export type RollbackBlocker = "recordUnconfirmed" | "objectsUnavailable" | "rootCommit" | "mergeCommit" | "targetChanged" | "evidenceMismatch" | "remoteDifferent" | "remoteUnavailable";

export interface RollbackQualificationIdentity {
  sessionId: string;
  recordId: string;
  revision: number;
  branch: string;
  remoteUrl: string;
  expectedSha: string;
  parentSha: string | null;
}

export interface RollbackQualificationPlan extends RollbackQualificationIdentity {
  localStatus: "candidate" | "blocked";
  blockers: RollbackBlocker[];
  planId: string | null;
  expiresAtEpochMs: number | null;
}

export interface RollbackQualificationReport extends RollbackQualificationIdentity {
  status: "qualified" | "blocked" | "unknown";
  blockers: RollbackBlocker[];
  remoteSha: string | null;
  checkedAtEpochMs: number;
}

export interface RollbackQualificationGateway {
  planRollbackQualification(sessionId: string, recordId: string, revision: number): Promise<RollbackQualificationPlan>;
  checkRollbackQualification(sessionId: string, planId: string): Promise<RollbackQualificationReport>;
}
