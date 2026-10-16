/** Read-only storage-reference inspection; never export, cleanup or restore authority. */
export const KNOWLEDGE_INTEGRITY_ISSUES = ["manifestMissing", "manifestUnsafe", "manifestUnreadable", "manifestTooLarge", "manifestInvalid", "unsupportedVersion", "unsafeDirectory", "missingFile", "unsafeFile", "readFailed", "invalidContent", "changedDuringRead", "fileLimit", "byteLimit", "timeLimit", "incompleteArchive", "unknownArchiveCompleteness"] as const;
export type KnowledgeIntegrityIssue = typeof KNOWLEDGE_INTEGRITY_ISSUES[number];
export const KNOWLEDGE_INTEGRITY_EXCLUSIONS = ["credentials", "otherWorkspaceSources", "repositoryFiles", "externalReferences", "unreferencedFiles", "runtimeState"] as const;
export const KNOWLEDGE_INTEGRITY_LIMITS = { manifestBytes: 2 * 1024 * 1024, resourceFiles: 1024, resourceBytes: 64 * 1024 * 1024, durationMs: 5000 } as const;
export interface KnowledgeIntegrityResourceSummary {
  kind: "body" | "archive";
  referenceCount: number;
  uniqueFiles: number;
  verified: number;
  missing: number;
  unsafe: number;
  unreadable: number;
  invalid: number;
  changed: number;
  omitted: number;
  verifiedBytes: number;
}
export interface KnowledgeIntegrityReport {
  reportId: string;
  schemaVersion: 1;
  scope: "applicationKnowledgeReferences";
  checkedAtEpochMs: number;
  expiresAtEpochMs: number;
  status: "checked" | "partial" | "unavailable";
  manifestState: "verified" | "missing" | "unsafe" | "unreadable" | "tooLarge" | "invalid" | "unsupported" | "changed";
  manifestSchemaVersion: number | null;
  manifestSha256: string | null;
  itemCount: number | null;
  revisionCount: number | null;
  resources: KnowledgeIntegrityResourceSummary[];
  archiveMissingResources: number;
  archiveTruncated: number;
  archiveUnknownCompleteness: number;
  issues: KnowledgeIntegrityIssue[];
  exclusions: typeof KNOWLEDGE_INTEGRITY_EXCLUSIONS[number][];
  limits: typeof KNOWLEDGE_INTEGRITY_LIMITS;
  allReferencedFilesVerified: boolean;
  consistentSnapshot: false;
  backupReady: false;
}
export interface KnowledgeIntegrityRecheck {
  report: KnowledgeIntegrityReport;
  comparison: "unchanged" | "changed" | "inconclusive";
}
export interface KnowledgeIntegrityGateway {
  inspectKnowledgeIntegrity(): Promise<KnowledgeIntegrityReport>;
  recheckKnowledgeIntegrity(reportId: string): Promise<KnowledgeIntegrityRecheck>;
  discardKnowledgeIntegrity(reportId: string): Promise<void>;
}
