import type { KnowledgeRestoreQualificationPlan, KnowledgeRestoreStrategy } from "./knowledgeRestoreQualification";
export const KNOWLEDGE_MERGE_PROJECTION_LIMITS = Object.freeze({ manifestBytes: 2 * 1024 * 1024, items: 2000, folders: 128, resourceFiles: 2048, resourceBytes: 64 * 1024 * 1024, bodyBytes: 64 * 1024 * 1024, archiveBytes: 512 * 1024 * 1024, jsonNodes: 131072, durationMs: 5000 });
export interface KnowledgeMergeProjectionPlan {
  schemaVersion: 1; scope: "knowledgeMergeProjection"; planId: string; source: KnowledgeRestoreQualificationPlan;
  projection: { state: "validated" | "blocked"; reason: "none" | "qualificationBlocked" | "folderNameCollision" | "capacityExceeded" | "manifestInvalid" | "referenceMismatch"; manifestSha256: string | null; manifestByteSize: number | null; itemCount: number | null; revisionCount: number | null; folderCount: number | null; fileCount: number | null; resourceByteSize: number | null; bodyByteSize: number | null; archiveByteSize: number | null; importedItems: number | null; importedFolders: number | null; resetPermissionItems: number | null; completedOperationsExcluded: true };
  limits: typeof KNOWLEDGE_MERGE_PROJECTION_LIMITS; privacyMode: "disableImportedPermissions";
  privacyResetAcknowledgementRequired: true; currentPermissionsPreserved: true; sourcePermissionsCopied: false;
  projectedManifestValidated: boolean; filesystemWrites: false; currentLibraryChanged: false; restoreReady: false; consistentSnapshot: false;
  checkedAtEpochMs: number; expiresAtEpochMs: number;
}
export interface KnowledgeMergeProjectionReceipt {
  planId: string; projectionManifestSha256: string; itemCount: number; revisionCount: number; folderCount: number;
  importedItems: number; importedFolders: number; resetPermissionItems: number;
  privacyResetAcknowledged: true; importedPermissionsDisabled: true; currentPermissionsPreserved: true; sourcePermissionsCopied: false;
  validatedInMemory: true; filesystemWrites: false; currentLibraryChanged: false; restoreReady: false; consistentSnapshot: false;
  completedAtEpochMs: number;
}
export interface KnowledgeMergeProjectionGateway {
  selectKnowledgeCandidateDirectory(): Promise<string | null>;
  planKnowledgeMergeProjection(candidatePath: string, strategy: KnowledgeRestoreStrategy): Promise<KnowledgeMergeProjectionPlan>;
  preflightKnowledgeMergeProjection(planId: string, acknowledgePrivacyReset: boolean): Promise<KnowledgeMergeProjectionReceipt>;
  discardKnowledgeMergeProjection(planId: string): Promise<void>;
}
