import type { KnowledgeCandidateCheckReport } from "./knowledgeCandidateCheck";
export type KnowledgeRestoreStrategy = "requireNoIdentityConflicts" | "keepCurrentIdentities";
export type KnowledgeResourceState = "notChecked" | "checked" | "missing" | "unsafe" | "unreadable" | "invalid" | "changed" | "overLimit" | "incomplete";
export interface KnowledgeRestoreQualificationPlan {
  schemaVersion: 1; scope: "knowledgeRestoreQualification"; planId: string;
  targetScope: "currentAppKnowledgeLibrary"; candidate: KnowledgeCandidateCheckReport;
  currentResources: { state: KnowledgeResourceState; fileCount: number | null; byteSize: number | null; inventorySha256: string | null; unreferencedFilesVerified: false; externalReferencesVerified: false };
  strategy: KnowledgeRestoreStrategy;
  qualification: { state: "evidenceReady" | "blocked"; reason: "none" | "currentManifestUnavailable" | "currentResourcesUnavailable" | "identityConflicts"; addItems: number | null; retainItems: number | null; skipCandidateItems: number | null; addFolders: number | null; retainFolders: number | null; skipCandidateFolders: number | null };
  currentOnlyPreserved: true; candidatePermissionsApplied: false; projectedManifestValidated: false;
  consistentSnapshot: false; filesystemWrites: false; restoreReady: false;
  checkedAtEpochMs: number; expiresAtEpochMs: number;
}
export interface KnowledgeRestoreQualificationRecheck {
  plan: KnowledgeRestoreQualificationPlan; comparison: "unchanged" | "changed" | "inconclusive";
}
export interface KnowledgeRestoreQualificationGateway {
  selectKnowledgeCandidateDirectory(): Promise<string | null>;
  planKnowledgeRestoreQualification(candidatePath: string, strategy: KnowledgeRestoreStrategy): Promise<KnowledgeRestoreQualificationPlan>;
  recheckKnowledgeRestoreQualification(planId: string): Promise<KnowledgeRestoreQualificationRecheck>;
  discardKnowledgeRestoreQualification(planId: string): Promise<void>;
}
