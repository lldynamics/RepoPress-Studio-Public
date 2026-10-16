export interface PublishEvidence {
  repositoryPath: string;
  repositoryIdentity: string;
  operation: "push" | "pushRetry";
  remote: string;
  remoteUrl: string;
  branch: string;
  expectedSha: string;
  observedBeforeSha: string | null;
  changedPaths: string[];
}
export interface PublishRecord {
  recordId: string;
  revision: number;
  evidence: PublishEvidence;
  outcome: "unconfirmed" | "verified" | "different";
  observedRemoteSha: string | null;
  startedAtEpochMs: number;
  checkedAtEpochMs: number | null;
}
export interface PublishVerificationPlan {
  planId: string;
  recordId: string;
  remoteUrl: string;
  branch: string;
  expectedSha: string;
  expiresAt: string;
}
