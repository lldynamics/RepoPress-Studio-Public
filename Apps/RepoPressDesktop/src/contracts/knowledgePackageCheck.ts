/** Selected saved-file package validation and ephemeral memory staging; no restore authority. */
import { KNOWLEDGE_BACKUP_EXCLUSIONS, KNOWLEDGE_BACKUP_LIMITS } from "./knowledgeBackup";
export const KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS = KNOWLEDGE_BACKUP_EXCLUSIONS;
export const KNOWLEDGE_PACKAGE_CHECK_LIMITS = { ...KNOWLEDGE_BACKUP_LIMITS, jsonNodes: 131072 } as const;
export interface KnowledgePackageCheckReport {
  reportId: string;
  sourcePath: string;
  format: "repopress-knowledge-saved-files";
  schemaVersion: 1;
  sourceManifestSchemaVersion: 4;
  scope: "selectedKnowledgePackage";
  itemCount: number;
  revisionCount: number;
  bodyFileCount: number;
  archiveFileCount: number;
  resourceByteSize: number;
  byteSize: number;
  sha256: string;
  manifestSha256: string;
  exclusions: typeof KNOWLEDGE_PACKAGE_CHECK_EXCLUSIONS[number][];
  limits: typeof KNOWLEDGE_PACKAGE_CHECK_LIMITS;
  structureVerified: true;
  contentVerified: true;
  allSavedReferencesIncluded: true;
  sourceManifestHashVerified: false;
  consistentSnapshot: false;
  includesCredentialStores: false;
  includesCompletedOperations: false;
  externalReferencesIncluded: false;
  filesystemWrites: false;
  currentLibraryChanged: false;
  restoreReady: false;
  checkedAtEpochMs: number;
  expiresAtEpochMs: number;
}
export interface KnowledgePackageMemoryPreflight {
  reportId: string;
  sourcePath: string;
  byteSize: number;
  sha256: string;
  manifestSha256: string;
  stagedFileCount: number;
  stagedByteSize: number;
  staging: "ephemeralMemory";
  sourceRevalidated: true;
  filesystemWrites: false;
  currentLibraryChanged: false;
  restoreReady: false;
}
export interface KnowledgePackageCheckGateway {
  selectKnowledgePackageSource(): Promise<string | null>;
  inspectKnowledgePackage(sourcePath: string): Promise<KnowledgePackageCheckReport>;
  preflightKnowledgePackage(reportId: string): Promise<KnowledgePackageMemoryPreflight>;
  discardKnowledgePackageCheck(reportId: string): Promise<void>;
}
