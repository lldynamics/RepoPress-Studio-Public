export interface RemoteReviewEvidence {
  repositoryPath: string;
  repositoryIdentity: string;
  remote: string;
  remoteUrl: string;
  provider: "github" | "gitlab";
  owner: string;
  project: string;
  remoteProjectId: number;
  sourceBranch: string;
  targetBranch: string;
  sourceSha: string;
  titleSha256: string;
  bodySha256: string;
  marker: string;
}

export interface RemoteReviewRecord {
  recordId: string;
  revision: number;
  evidence: RemoteReviewEvidence;
  outcome: "unconfirmed" | "verified";
  verification: "notChecked" | "matched" | "noMatch" | "ambiguous" | "unavailable";
  reviewNumber: number | null;
  webUrl: string | null;
  startedAtEpochMs: number;
  checkedAtEpochMs: number | null;
}

export interface RemoteReviewVerificationPlan {
  planId: string;
  recordId: string;
  remoteUrl: string;
  provider: "github" | "gitlab";
  owner: string;
  project: string;
  sourceBranch: string;
  targetBranch: string;
  sourceSha: string;
  expiresAt: string;
}

export interface RemoteReviewRecordsGateway {
  listRemoteReviewRecords(sessionId: string): Promise<RemoteReviewRecord[]>;
  planRemoteReviewVerification(sessionId: string, recordId: string): Promise<RemoteReviewVerificationPlan>;
  executeRemoteReviewVerification(sessionId: string, planId: string): Promise<RemoteReviewRecord>;
  removeRemoteReviewRecord(sessionId: string, recordId: string, revision: number): Promise<RemoteReviewRecord[]>;
}
