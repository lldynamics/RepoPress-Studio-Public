export const KNOWLEDGE_CANDIDATE_CHECK_LIMITS = Object.freeze({
  manifestBytes: 2 * 1024 * 1024, resourceFiles: 1024, resourceBytes: 32 * 1024 * 1024,
  candidateFiles: 1026, candidateBytes: 34 * 1024 * 1024 + 4096, markerBytes: 4096,
  jsonNodes: 131072, durationMs: 5000,
});
export type KnowledgeCurrentManifestState = "checked" | "missing" | "unsafe" | "unreadable" | "invalid" | "changed";
export interface KnowledgeCandidateConflicts {
  candidateOnlyItems: number; currentOnlyItems: number; identicalItems: number; changedItems: number;
  candidateOnlyFolders: number; currentOnlyFolders: number; identicalFolders: number; changedFolders: number;
}
export interface KnowledgeCandidateCheckReport {
  reportId: string; candidatePath: string; schemaVersion: 1; scope: "selectedKnowledgeCandidate";
  stagePlanId: string; sourcePackageSha256: string; manifestSha256: string; candidateInventorySha256: string;
  candidateFileCount: number; candidateByteSize: number; itemCount: number; revisionCount: number; folderCount: number;
  currentLibrary: { state: KnowledgeCurrentManifestState; manifestSha256: string | null; itemCount: number | null; revisionCount: number | null; folderCount: number | null };
  conflicts: KnowledgeCandidateConflicts | null;
  limits: typeof KNOWLEDGE_CANDIDATE_CHECK_LIMITS;
  candidateStructureVerified: true; candidateContentsVerified: true; privatePermissionsVerified: true;
  sourcePackageHashVerified: false; candidateAuthenticityVerified: false; currentLibraryResourcesVerified: false;
  comparisonScope: "manifestIdentityAndMetadataOnly"; consistentSnapshot: false; filesystemWrites: false;
  currentLibraryChanged: false; restoreReady: false; checkedAtEpochMs: number; expiresAtEpochMs: number;
}
export interface KnowledgeCandidateRecheck {
  report: KnowledgeCandidateCheckReport; comparison: "unchanged" | "changed" | "inconclusive";
}
export interface KnowledgeCandidateCheckGateway {
  selectKnowledgeCandidateDirectory(): Promise<string | null>;
  inspectKnowledgeCandidate(candidatePath: string): Promise<KnowledgeCandidateCheckReport>;
  recheckKnowledgeCandidate(reportId: string): Promise<KnowledgeCandidateRecheck>;
  discardKnowledgeCandidateCheck(reportId: string): Promise<void>;
}
