/** Saved-file package only. No atomic workspace snapshot, restore or macOS interchange authority. */
export const KNOWLEDGE_BACKUP_EXCLUSIONS = ["credentialStores", "otherWorkspaceSources", "repositoryFiles", "externalReferences", "unreferencedFiles", "completedOperations", "runtimeState", "sourcePdfFiles", "attachmentFiles"] as const;
export const KNOWLEDGE_BACKUP_LIMITS = { manifestBytes: 2 * 1024 * 1024, resourceFiles: 1024, resourceBytes: 32 * 1024 * 1024, packageBytes: 48 * 1024 * 1024, durationMs: 5000 } as const;
export interface KnowledgeBackupPlan {
  planId: string;
  scope: "applicationSavedKnowledge";
  format: "repopress-knowledge-saved-files";
  schemaVersion: 1;
  sourceManifestSchemaVersion: 4;
  destinationPath: string;
  itemCount: number;
  revisionCount: number;
  bodyFileCount: number;
  archiveFileCount: number;
  resourceByteSize: number;
  byteSize: number;
  sha256: string;
  exclusions: typeof KNOWLEDGE_BACKUP_EXCLUSIONS[number][];
  limits: typeof KNOWLEDGE_BACKUP_LIMITS;
  structureVerified: true;
  contentVerified: true;
  allSavedReferencesIncluded: true;
  consistentSnapshot: false;
  includesCredentialStores: false;
  includesCompletedOperations: false;
  externalReferencesIncluded: false;
  createdAtEpochMs: number;
  expiresAtEpochMs: number;
}
export interface KnowledgeBackupResult {
  planId: string;
  destinationPath: string;
  byteSize: number;
  sha256: string;
}
export interface KnowledgeBackupGateway {
  selectKnowledgeBackupDestination(): Promise<string | null>;
  planKnowledgeBackup(destinationPath: string): Promise<KnowledgeBackupPlan>;
  executeKnowledgeBackup(planId: string, confirmSensitivePlaintext: boolean): Promise<KnowledgeBackupResult>;
  discardKnowledgeBackup(planId: string): Promise<void>;
}
