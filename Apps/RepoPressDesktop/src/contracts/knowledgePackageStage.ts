/** Explicit sensitive-plaintext disk candidate. Never installs or replaces the current library. */
import type { KnowledgePackageCheckReport } from "./knowledgePackageCheck";
export const KNOWLEDGE_PACKAGE_STAGE_LIMITS = { candidateFiles: 1026, candidateBytes: 34 * 1024 * 1024 + 4096, durationMs: 30000 } as const;
export interface KnowledgePackageStagePlan {
  planId: string;
  sourcePath: string;
  parentPath: string;
  candidatePath: string;
  format: "repopress-knowledge-isolated-candidate";
  schemaVersion: 1;
  package: KnowledgePackageCheckReport;
  candidateFileCount: number;
  candidateByteSize: number;
  candidateInventorySha256: string;
  limits: typeof KNOWLEDGE_PACKAGE_STAGE_LIMITS;
  requiresSensitivePlaintextConsent: true;
  candidateOnly: true;
  currentLibraryChanged: false;
  restoreReady: false;
  createdAtEpochMs: number;
  expiresAtEpochMs: number;
}
export interface KnowledgePackageStageResult {
  planId: string;
  sourcePath: string;
  candidatePath: string;
  packageSha256: string;
  manifestSha256: string;
  candidateFileCount: number;
  candidateByteSize: number;
  candidateInventorySha256: string;
  privatePermissionsVerified: true;
  contentsVerified: true;
  sourceRevalidated: true;
  candidateOnly: true;
  currentLibraryChanged: false;
  restoreReady: false;
}
export interface KnowledgePackageStageGateway {
  selectKnowledgePackageStageSource(): Promise<string | null>;
  selectKnowledgePackageStageParent(): Promise<string | null>;
  planKnowledgePackageStage(sourcePath: string, parentPath: string): Promise<KnowledgePackageStagePlan>;
  executeKnowledgePackageStage(planId: string, confirmSensitivePlaintext: boolean): Promise<KnowledgePackageStageResult>;
  discardKnowledgePackageStage(planId: string): Promise<void>;
}
