/** A private plaintext copy of this repository's complete rollback evidence. */
export interface RollbackArchivePlan {
  planId: string;
  sessionId: string;
  repositoryPath: string;
  destinationPath: string;
  schemaVersion: 1;
  recordCount: number;
  unresolvedCount: number;
  historicalObservationCount: number;
  byteSize: number;
  sha256: string;
  createdAtEpochMs: number;
  expiresAtEpochMs: number;
}
export interface RollbackArchiveResult {
  planId: string;
  sessionId: string;
  destinationPath: string;
  recordCount: number;
  byteSize: number;
  sha256: string;
}
export interface RollbackArchiveGateway {
  selectRollbackArchiveDestination(): Promise<string | null>;
  planRollbackArchive(sessionId: string, destinationPath: string): Promise<RollbackArchivePlan>;
  executeRollbackArchive(sessionId: string, planId: string): Promise<RollbackArchiveResult>;
  discardRollbackArchive(sessionId: string, planId: string): Promise<void>;
}
