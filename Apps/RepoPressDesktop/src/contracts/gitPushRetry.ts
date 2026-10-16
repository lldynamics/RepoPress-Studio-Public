/** A short-lived, one-use review of already-committed work awaiting a normal push. */
export interface GitPushRetryPlan {
  planId: string;
  branch: string;
  head: string;
  remote: string;
  remoteUrl: string;
  observedRemoteSha: string;
  pendingCommitCount: number;
  changedPaths: string[];
  summary: string;
  expiresAt: string;
  warnings: string[];
}

export interface PlanGitPushRetryRequest { sessionId: string; }
export interface ExecuteGitPushRetryRequest { sessionId: string; planId: string; }

/** `verified` is true only after a fresh remote `ls-remote` equals the frozen SHA. */
export interface GitPushRetryResult {
  branch: string;
  head: string;
  remoteSha: string;
  verified: boolean;
  summary: string;
}
