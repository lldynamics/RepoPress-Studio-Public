import type { SitePreviewPlanRequest, SitePreviewPlan, SitePreviewPageTarget, SitePreviewPageSnapshot } from "./sitePreview";
import type { KnowledgeRestoreHistoryExportGateway } from "./knowledgeRestoreHistoryExport";
import type { KnowledgeRestoreCleanupGateway } from "./knowledgeRestoreCleanup";
import type { KnowledgeRestoreArchiveGateway } from "./knowledgeRestoreArchive";
import type { KnowledgeRestoreInstallGateway } from "./knowledgeRestoreInstall";
import type { KnowledgeMergeProjectionGateway } from "./knowledgeMergeProjection";
import type { KnowledgeRestoreQualificationGateway } from "./knowledgeRestoreQualification";
import type { KnowledgeCandidateCheckGateway } from "./knowledgeCandidateCheck";
import type { KnowledgePackageStageGateway } from "./knowledgePackageStage";
import type { KnowledgePackageCheckGateway } from "./knowledgePackageCheck";
import type { KnowledgeBackupGateway } from "./knowledgeBackup";
import type { KnowledgeIntegrityGateway } from "./knowledgeIntegrity";
import type { DraftSnapshotBackupGateway } from "./draftSnapshotBackup";
import type { RssSnapshotBackupGateway } from "./rssSnapshotBackup";
import type { WorkspaceConfigBackupGateway } from "./workspaceConfigBackup";
import type { WorkspaceBackupGateway } from "./workspaceBackup";
import type { RollbackArchiveGateway } from "./rollbackArchive";
import type { RollbackTransactionGateway } from "./rollbackTransaction";
import type { RemoteReviewRecordsGateway } from "./remoteReviewLedger";
import type { ReleaseLedgerGateway } from "./releaseLedger";
import type { RollbackQualificationGateway } from "./rollbackQualification";
import type { RollbackChangePreviewGateway } from "./rollbackChangePreview";
import type { RollbackCandidateGateway } from "./rollbackCandidate";
import type { PublishRecord, PublishVerificationPlan } from "./publishLedger";
import type { AiConnectionRequest, ExecuteAiConnectionRequest, AiConnectionPlan, AiConnectionResult } from "./aiConnection";
import type { MetadataBatchRequest, MetadataBatchPlan, MetadataBatchResult } from "./metadataBatch";
import type { RegisterSiteProfileRequest, RenameSiteProfileRequest, RemoveSiteProfileRequest, SiteProfileSnapshot } from "./sites";
import type { RepositoryImageSnapshot, RepositoryImagePreview } from "./images";
import type { OperationLogSnapshot } from "./activity";
import type { GitPushRetryPlan, GitPushRetryResult } from "./gitPushRetry";

export interface CapabilitySnapshot {
  metadataBatch?: boolean;
  localEdit: boolean; markdownPreview: boolean; gitStatus: boolean; siteRuntime: boolean;
  gitCommit: boolean; gitPush: boolean; gitFetch: boolean; gitIndex: boolean; remoteAuth: boolean;
  aiEditing: boolean; semanticSearch: boolean; pdfTextExtraction: boolean; ocrReadiness: boolean;
  knowledgeLibrary: boolean; contentHealth: boolean; imageWorkbench: boolean; operationLog: boolean; siteProfiles: boolean;
}
export type KnowledgeSourceKind = "web" | "pdf" | "text";
export type KnowledgeArchiveFormat = "html" | "mhtml";
export interface KnowledgeArchiveMetadata {
  format: KnowledgeArchiveFormat;
  byteSize: number;
  embeddedResourceCount: number | null;
  missingResourceCount: number | null;
  wasTruncated: boolean;
}
export interface KnowledgeLibraryStatus { ready: boolean; persistent: boolean; itemCount: number; totalBytes: number; summary: string; warning: string | null; }
export interface KnowledgeFolder { folderId: string; name: string; createdAtEpochSeconds: number; }
export interface KnowledgeItemSummary { itemId: string; title: string; sourceKind: KnowledgeSourceKind; sourceName: string; sourceUrl: string | null; byteSize: number; createdAtEpochSeconds: number; updatedAtEpochSeconds: number; readingProgressPercent: number; allowsLocalSemanticIndex: boolean; /** Explicit per-item consent for sending its text to a remote AI provider. Missing legacy values must be treated as false. */ allowsRemoteAiUse?: boolean; archive: KnowledgeArchiveMetadata | null; folderId?: string | null; revisionNumber?: number; revisionCount?: number; }
export interface KnowledgeItem extends KnowledgeItemSummary { text: string; }
export interface KnowledgeItemSnapshot { items: KnowledgeItemSummary[]; total: number; truncated: boolean; }
export interface KnowledgeFolderSnapshot { folders: KnowledgeFolder[]; total: number; }
export interface KnowledgeRevisionSummary { revisionNumber: number; createdAtEpochSeconds: number; byteSize: number; contentSha256: string; archive: KnowledgeArchiveMetadata | null; }
export interface KnowledgeRevision extends KnowledgeRevisionSummary { text: string; }
export interface KnowledgeRevisionSnapshot { itemId: string; revisions: KnowledgeRevisionSummary[]; }
export interface KnowledgeImportRequest { sourceKind: KnowledgeSourceKind; title: string; sourceName: string; sourceUrl: string | null; text: string; allowsLocalSemanticIndex: boolean; /** Defaults to false; importing never grants remote AI permission implicitly. */ allowsRemoteAiUse?: boolean; }
export interface SetKnowledgeRemoteAiPermissionRequest { itemId: string; allowsRemoteAiUse: boolean; }
export interface KnowledgeImportResult { item: KnowledgeItem | KnowledgeItemSummary; deduplicated: boolean; summary: string; }
export interface KnowledgeSearchResult { item: KnowledgeItemSummary | KnowledgeItem; score: number; lexicalScore: number; semanticScore: number; snippet: string; reason: string; }
export interface KnowledgeSearchSnapshot { query: string; modelId: string; encodingVersion: number; results: KnowledgeSearchResult[]; truncated: boolean; }
export interface KnowledgeProgressRequest { itemId: string; progressPercent: number; }
export interface KnowledgeExportRequest { sessionId: string; itemId: string; relativePath: string; }
export interface KnowledgeExportPlan { planId: string; itemId: string; relativePath: string; title: string; contentSha256: string; expiresAtEpochSeconds: number; summary: string; warnings: string[]; }
export interface KnowledgeExportResult { itemId: string; relativePath: string; byteSize: number; summary: string; }
export interface KnowledgeArchiveExportRequest { sessionId: string; itemId: string; relativePath: string; }
export interface KnowledgeArchiveExportPlan { planId: string; itemId: string; relativePath: string; format: KnowledgeArchiveFormat; archiveSha256: string; byteSize: number; expiresAtEpochSeconds: number; summary: string; warnings: string[]; }
export interface KnowledgeArchiveExportResult { itemId: string; relativePath: string; format: KnowledgeArchiveFormat; byteSize: number; summary: string; }
export interface BrowserCaptureStatus { running: boolean; endpoint: string | null; connectionToken: string | null; tokenExpiresAt: number | null; allowedOrigins: string[]; maximumInputBytes: number; summary: string; warning: string | null; }
export type WorkspaceTheme = "system" | "light" | "dark";
export type WritingToolbarItemId =
  | "bold" | "italic" | "strike" | "code" | "link"
  | "heading" | "quote" | "unorderedList" | "orderedList"
  | "taskList" | "codeBlock" | "horizontalRule";
export type WorkspaceUiLanguage = "system" | "zh-CN" | "en-US";

export interface WorkspacePreferences {
  uiLanguage?: WorkspaceUiLanguage;
  theme: WorkspaceTheme;
  editorFontSize: number;
  editorLineSpacing: number;
  editorBodyWidth: number;
  spellCheckEnabled: boolean;
  typewriterModeEnabled: boolean;
  currentParagraphHighlightEnabled: boolean;
  warmPaperBackgroundEnabled: boolean;
  automaticPairingEnabled: boolean;
  paragraphSpotlightEnabled: boolean;
  writingToolDensity: "basic" | "professional";
  writingToolbarItemIds: WritingToolbarItemId[];
  restoreLastWorkspace: boolean;
  recoveryEnabled: boolean;
}
export interface RecentRepositorySnapshot {
  path: string;
  displayName: string;
  lastOpenedAtEpochSeconds: number;
}
export interface RecoveryDraftSnapshot {
  recoveryId: string;
  repositoryPath: string;
  relativePath: string;
  text: string;
  baselineSha256: string;
  savedAtEpochSeconds: number;
}
export interface WorkspaceStateSnapshot {
  schemaVersion: 1;
  preferences: WorkspacePreferences;
  recentRepositories: RecentRepositorySnapshot[];
  lastRepositoryPath: string | null;
  lastDocumentPath: string | null;
  recoveryDraft: RecoveryDraftSnapshot | null;
  warning: string | null;
}
export interface SaveRecoveryDraftRequest {
  sessionId: string;
  documentId: string;
  text: string;
  expectedSha256: string;
}
export type CredentialProvider = "github" | "gitlab";
export type CredentialStorage = "secret_service" | "session_only" | "unavailable";
export interface RepositoryCredentialSnapshot {
  credentialId: string; provider: CredentialProvider; host: string; account: string | null;
  username: string | null; storage: CredentialStorage;
}
export interface CredentialStatusSnapshot {
  storage: CredentialStorage; secretServiceAvailable: boolean; credentials: RepositoryCredentialSnapshot[]; warning: string | null;
}
export interface StoreRepositoryCredentialRequest {
  sessionId: string; provider: CredentialProvider; host: string; account: string | null; username: string | null; token: string;
}
export interface DeleteRepositoryCredentialRequest { sessionId: string; credentialId: string; }
export type GitOperationKind = "commit" | "fetch" | "push";
export interface PlanGitOperationRequest { sessionId: string; operation: GitOperationKind; commitMessage: string | null; }
export interface GitOperationPlan {
  planId: string; operation: GitOperationKind; branch: string | null; head: string | null;
  stagedFiles: string[]; remote: string | null; remoteUrl: string | null; summary: string; expiresAt: string; warnings: string[];
}
export interface ExecuteGitOperationRequest { sessionId: string; planId: string; }
export interface GitOperationResult { operation: GitOperationKind; summary: string; branch: string | null; head: string | null; }
export type GitIndexAction = "stage" | "unstage";
export interface PlanGitIndexUpdateRequest { sessionId: string; action: GitIndexAction; paths: string[]; }
export interface GitIndexUpdatePlan { planId: string; action: GitIndexAction; paths: string[]; summary: string; expiresAt: string; warnings: string[]; }
export interface ExecuteGitIndexUpdateRequest { sessionId: string; planId: string; }
export interface GitIndexUpdateResult { action: GitIndexAction; paths: string[]; summary: string; }
export interface PlanRemoteReviewRequest {
  sessionId: string; provider: CredentialProvider; host: string; title: string; body: string | null;
  baseBranch: string | null; headBranch: string | null;
}
export interface RemoteReviewPlan {
  planId: string; provider: CredentialProvider; host: string; title: string; baseBranch: string | null;
  headBranch: string | null; summary: string; expiresAt: string; warnings: string[];
  sourceSha: string; requestMarker: string; bodyPreview: string;
}
export interface ExecuteRemoteReviewRequest { sessionId: string; planId: string; }
export interface RemoteReviewResult { provider: CredentialProvider; url: string | null; summary: string; }
export interface DeploymentCheckSnapshot { configured: boolean; provider: string | null; status: string; url: string | null; summary: string; checkedAt: string | null; warning: string | null; }
export interface ReadinessSnapshot { configured: boolean; ready: boolean; summary: string; warning: string | null; }
export interface AppUpdatePlan { planId: string; currentVersion: string; version: string; publishedAt: string | null; notes: string | null; downloadHost: string; artifactName: string; expiresAt: string; warnings: string[]; }
export interface AppUpdateCheck { supported: boolean; configured: boolean; available: boolean; summary: string; plan: AppUpdatePlan | null; }
export interface AppUpdateInstallResult { version: string; installed: boolean; requiresRestart: boolean; summary: string; }
export type AiProviderKind = "openai_compatible" | "ollama_local";
export type AiCredentialStorage = "secret_service" | "session_memory" | "unavailable" | "not_required";
export interface AiProviderRequest { provider: AiProviderKind; endpoint: string; model: string; }
export interface AiCredentialStatusSnapshot {
  configured: boolean; storage: AiCredentialStorage; sessionOnly: boolean;
  secretServiceAvailable: boolean; warning: string | null;
}
export interface StoreAiCredentialRequest extends AiProviderRequest { token: string; }
export interface PlanAiEditRequest extends AiProviderRequest {
  sessionId: string; documentId: string; documentRevision: number;
  selectionStart: number; selectionEnd: number; sourceText: string; instruction: string;
}
export interface AiEditPlan {
  planId: string; provider: AiProviderKind; endpoint: string; model: string;
  selectionBytes: number; instructionBytes: number; expiresAt: string;
  summary: string; warnings: string[];
}
export interface ExecuteAiEditRequest extends PlanAiEditRequest { planId: string; }
export interface Utf16Range { start: number; end: number; }
export interface AiEditProposal {
  id: number; range: Utf16Range; originalText: string; replacementText: string;
}
export interface AiEditResponse { proposals: AiEditProposal[]; }
export interface ApplyAiEditsRequest {
  sessionId: string; documentId: string; documentRevision: number;
  selectionStart: number; selectionEnd: number; sourceText: string;
  proposals: AiEditProposal[]; acceptedIds: number[];
}
export interface AiAppliedEdit { text: string; appliedProposalIds: number[]; }
export type AiChatRole = "user" | "assistant";
export interface AiChatMessage { messageId: string; role: AiChatRole; content: string; createdAtEpochSeconds: number; }
export interface AiConversation { conversationId: string; title: string; messages: AiChatMessage[]; messageCount: number; totalMessageBytes: number; createdAtEpochSeconds: number; updatedAtEpochSeconds: number; sessionOnly: boolean; persistenceWarning: string | null; }
export interface AiConversationDeleteResult { conversationId: string; deleted: boolean; sessionOnly: boolean; persistenceWarning: string | null; }
export interface CreateAiConversationRequest { title?: string | null; }
export interface AiChatKnowledgeItem { itemId: string; title: string; revisionNumber: number; byteSize: number; contentSha256: string; }
export interface PlanAiChatRequest extends AiProviderRequest { conversationId: string; message: string; knowledgeItemIds: string[]; streaming: boolean; }
export interface AiChatPlan { planId: string; conversationId: string; conversationVersion: number; provider: AiProviderKind; endpoint: string; model: string; historyMessageCount: number; userMessageBytes: number; knowledgeItems: AiChatKnowledgeItem[]; knowledgeTotalBytes: number; totalSendBytes: number; expiresAtEpochSeconds: number; warnings: string[]; streaming: boolean; sessionOnly: boolean; }
export interface ExecuteAiChatRequest extends PlanAiChatRequest { planId: string; }
export interface AiChatExecutionResult { assistantMessage: AiChatMessage; conversation: AiConversation; persistenceWarning: string | null; }
export type AiChatStreamState = "running" | "completed" | "cancelled" | "failed";
export interface AiChatStreamSnapshot {
  operationId: string; conversationId: string; state: AiChatStreamState; cursor: number; delta: string;
  accumulatedBytes: number; conversation: AiConversation | null; errorCode: string | null;
  errorMessage: string | null; persistenceWarning: string | null;
}
export type AiChatVaultState = "disabled" | "locked" | "unlocked";
export interface AiChatVaultStatus {
  state: AiChatVaultState; hasVault: boolean; persistentConversationCount: number; summary: string; warning: string | null;
}
export interface AiProviderProfile {
  profileId: string; name: string; provider: AiProviderKind; endpoint: string; model: string; streaming: boolean;
  createdAtEpochSeconds: number; updatedAtEpochSeconds: number;
}
export interface SaveAiProviderProfileRequest extends AiProviderRequest { profileId?: string | null; name: string; streaming: boolean; }
export interface AiProviderProfileDeleteResult { profileId: string; deleted: boolean; }
export type TextTranslationProvider = "libretranslate_local" | "ollama_local" | "openai_compatible";
export interface TextTranslationGlossaryEntry { source: string; target: string; }
export interface PlanTextTranslationRequest {
  provider: TextTranslationProvider;
  endpoint: string;
  model: string;
  sourceLanguage: string;
  targetLanguage: string;
  text: string;
  /** Optional preferred source-to-target mappings reviewed with the translation plan. */
  glossary?: TextTranslationGlossaryEntry[];
}
export interface TextTranslationPlan {
  planId: string;
  provider: TextTranslationProvider;
  endpoint: string;
  model: string;
  sourceLanguage: string;
  targetLanguage: string;
  textBytes: number;
  glossaryCount: number;
  expiresAt: string;
  summary: string;
  warnings: string[];
}
export interface ExecuteTextTranslationRequest extends PlanTextTranslationRequest { planId: string; }
export interface TextTranslationResult {
  translatedText: string;
  detectedSourceLanguage: string | null;
  provider: TextTranslationProvider;
  model: string;
  targetLanguage: string;
}
export interface StructuredTextTranslationSegment { id: string; text: string; }
export interface StructuredTextTranslationConfig {
  provider: TextTranslationProvider;
  endpoint: string;
  model: string;
  sourceLanguage: string;
  targetLanguage: string;
  glossary?: TextTranslationGlossaryEntry[];
  segments: StructuredTextTranslationSegment[];
}
export type PlanStructuredTextTranslationRequest = StructuredTextTranslationConfig;
export interface StructuredTextTranslationPlan extends TextTranslationPlan { segmentCount: number; }
export interface ExecuteStructuredTextTranslationRequest extends StructuredTextTranslationConfig { planId: string; }
export interface StructuredTextTranslationResult {
  translations: Array<{ id: string; translatedText: string }>;
  detectedSourceLanguage: string | null;
  provider: TextTranslationProvider;
  model: string;
  targetLanguage: string;
}
export interface SemanticIndexStatus {
  ready: boolean; sessionOnly: boolean; modelId: string; encodingVersion: number;
  indexedFiles: number; indexedChunks: number; indexedBytes: number; reusedChunks: number; summary: string;
}
export interface SemanticSearchResult {
  chunkId: string; path: string; line: number; endLine: number; heading: string | null;
  score: number; lexicalScore: number; semanticScore: number; snippet: string;
  reason: string; modelId: string; encodingVersion: number;
}
export interface SemanticSearchSnapshot {
  query: string; modelId: string; encodingVersion: number; results: SemanticSearchResult[]; truncated: boolean;
}
export interface ToolReadiness { available: boolean; path: string | null; reason: string | null; }
export interface OcrReadiness {
  ready: boolean; enabled: boolean; tesseract: ToolReadiness; pdftoppm: ToolReadiness;
  englishData: ToolReadiness; chineseSimplifiedData: ToolReadiness; pdfInfo: ToolReadiness; warning: string;
}
export interface DocumentCapabilities {
  pdfTextReady: boolean; sandbox: ToolReadiness; pdftotext: ToolReadiness;
  ocr: OcrReadiness; warnings: string[];
}
export interface PdfSelection {
  token: string; fileName: string; byteSize: number; expiresAtEpochSeconds: number; warnings: string[];
}
export interface PdfTextExtraction { text: string; byteSize: number; warnings: string[]; }
export type PdfOcrLanguage = "eng" | "chi_sim" | "eng+chi_sim";
export interface PdfOcrExtraction { text: string; byteSize: number; pageCount: number; language: PdfOcrLanguage; warnings: string[]; }
export interface RepositorySessionSnapshot {
  sessionId: string; rootPath: string; displayName: string; siteKind: string;
  contentRoot: string | null; isGitRepository: boolean; warnings: string[];
}
export interface MarkdownFileEntry { relativePath: string; displayName: string; directory: string; byteSize: number; }
export interface ContentHealthSourceDocument {
  relativePath: string; displayName: string; text: string; byteSize: number; sha256: string;
}
export interface ContentHealthSourceOmission {
  relativePath: string | null; code: string; message: string;
}
export interface ContentHealthSourceSnapshot {
  documents: ContentHealthSourceDocument[];
  totalFiles: number; scannedFiles: number; scannedBytes: number; omittedFiles: number;
  truncated: boolean; omissions: ContentHealthSourceOmission[]; warnings: string[];
}
export interface DocumentSnapshot {
  documentId: string; relativePath: string; text: string; encoding: string;
  lineEnding: "none" | "lf" | "crlf" | "mixed"; byteSize: number; baselineSha256: string;
  revision: number; writable: boolean; readOnlyReason: string | null;
}
export interface MarkdownLinkMetadata { relativePath: string; title: string | null; slug: string | null; permalink: string | null; }
export interface SaveDocumentRequest { sessionId: string; documentId: string; text: string; expectedSha256: string; }
export type SaveDocumentResult = DocumentSnapshot;
export interface DeleteMarkdownDocumentResult { relativePath: string; recycleId: string; }
export type DraftVersionReason = "beforeSave" | "beforeRestore" | "deleted";
export interface DraftVersionSummary {
  versionId: string; relativePath: string; reason: DraftVersionReason;
  createdAtEpochSeconds: number; byteSize: number; contentSha256: string;
}
export interface DraftVersion extends DraftVersionSummary { text: string; }
export interface DraftVersionSnapshot { documentId: string; relativePath: string; versions: DraftVersionSummary[]; }
export interface RecycledDraftSummary {
  recycleId: string; relativePath: string; deletedAtEpochSeconds: number;
  byteSize: number; contentSha256: string;
}
export interface RecycledDraft extends RecycledDraftSummary { text: string; }
export interface RecycledDraftSnapshot { entries: RecycledDraftSummary[]; total: number; truncated: boolean; }
export interface GeneralDraftSummary {
  draftId: string; title: string; sourceRepositoryName: string | null; sourceRelativePath: string | null;
  createdAtEpochSeconds: number; updatedAtEpochSeconds: number; byteSize: number; contentSha256: string; revision: number;
}
export interface GeneralDraft extends GeneralDraftSummary { text: string; }
export interface GeneralDraftSnapshot { entries: GeneralDraftSummary[]; total: number; truncated: boolean; }
export type SaveGeneralDraftRequest = { draftId: string; text: string; expectedRevision: number; expectedSha256: string }
  | { draftId: null; text: string; expectedRevision: null; expectedSha256: null };
export type GeneralDraftTransferOperation = "copyCurrentToGeneral" | "moveCurrentToGeneral" | "copyGeneralToRepository" | "moveGeneralToRepository";
export interface GeneralDraftTransferTarget { draftId: string; relativePath: string; }
export interface PlanGeneralDraftTransferRequest {
  sessionId: string; operation: GeneralDraftTransferOperation; documentId?: string | null; expectedSha256?: string | null;
  targetItems?: GeneralDraftTransferTarget[];
}
export type GeneralDraftConflictKind = "unavailableSource" | "targetPathOccupied" | "duplicateTargetPath" | "sourceChanged" | "sameDestination" | "unavailableTarget";
export interface GeneralDraftTransferConflict { id: string; kind: GeneralDraftConflictKind; draftId: string | null; title: string; message: string; }
export interface GeneralDraftTransferPlanItem {
  draftId: string | null; title: string; sourceLabel: string; sourceRelativePath: string | null;
  targetLabel: string; targetRelativePath: string | null; contentSha256: string; revision: number | null;
  conflicts: GeneralDraftTransferConflict[];
}
export interface GeneralDraftTransferPlan {
  planId: string; operation: GeneralDraftTransferOperation; items: GeneralDraftTransferPlanItem[];
  conflicts: GeneralDraftTransferConflict[]; canApply: boolean; expiresAtEpochSeconds: number; warnings: string[];
}
export interface ExecuteGeneralDraftTransferRequest { sessionId: string; planId: string; }
export interface GeneralDraftTransferResult {
  operation: GeneralDraftTransferOperation; affectedGeneralDraftIds: string[]; affectedRelativePaths: string[];
  undoId: string; summary: string;
}
export interface UndoGeneralDraftTransferRequest { sessionId: string; undoId: string; }
export interface UndoGeneralDraftTransferResult {
  restoredGeneralDraftIds: string[]; restoredRelativePaths: string[]; summary: string;
}
export interface WritingImageImportResult {
  relativePath: string; markdownPath: string; fileName: string; byteSize: number; mimeType: string;
}
export interface GitChangedFile { status: string; relativePath: string; sourcePath: string | null; }
export interface GitStatusSnapshot {
  available: boolean; branch: string | null; upstream: string | null; ahead: number; behind: number;
  detached: boolean; changedFiles: GitChangedFile[]; warnings: string[];
}
export type MarkdownSearchMatchKind = "path" | "content";
export interface MarkdownSearchResult {
  relativePath: string; displayName: string; directory: string;
  matchKind: MarkdownSearchMatchKind; lineNumber: number | null; snippet: string;
}
export interface MarkdownSearchSnapshot { query: string; results: MarkdownSearchResult[]; truncated: boolean; }
export interface GitDiffSnapshot {
  relativePath: string; stagedPatch: string; workingTreePatch: string;
  binary: boolean; truncated: boolean; warnings: string[];
}
export interface SitePreviewReadiness {
  siteKind: string; supported: boolean; runtimeAvailable: boolean;
  executable: string | null; version: string | null; reason: string | null; warning: string | null;
}
export interface SitePreviewSnapshot { previewId: string | null; running: boolean; url: string | null; siteKind: string; message: string; }
export interface GatewayError { code: string; message: string; }
export interface RepositoryGateway extends KnowledgeRestoreHistoryExportGateway, KnowledgeRestoreCleanupGateway, KnowledgeRestoreArchiveGateway, KnowledgeRestoreInstallGateway, KnowledgeMergeProjectionGateway, KnowledgeRestoreQualificationGateway, KnowledgeCandidateCheckGateway, KnowledgePackageStageGateway, KnowledgePackageCheckGateway, KnowledgeBackupGateway, KnowledgeIntegrityGateway, DraftSnapshotBackupGateway, RssSnapshotBackupGateway, WorkspaceConfigBackupGateway, WorkspaceBackupGateway, RollbackArchiveGateway, RollbackTransactionGateway, RemoteReviewRecordsGateway, ReleaseLedgerGateway, RollbackQualificationGateway, RollbackChangePreviewGateway, RollbackCandidateGateway {
  removePublishRecord(sessionId: string, recordId: string, revision: number): Promise<PublishRecord[]>;
  listPublishRecords(sessionId: string): Promise<PublishRecord[]>;
  planPublishVerification(sessionId: string, recordId: string): Promise<PublishVerificationPlan>;
  executePublishVerification(sessionId: string, planId: string): Promise<PublishRecord>;
  planMetadataBatch(request: MetadataBatchRequest): Promise<MetadataBatchPlan>;
  executeMetadataBatch(sessionId: string, planId: string): Promise<MetadataBatchResult>;
  getSiteProfiles(): Promise<SiteProfileSnapshot>;
  registerSiteProfile(request: RegisterSiteProfileRequest): Promise<SiteProfileSnapshot>;
  renameSiteProfile(request: RenameSiteProfileRequest): Promise<SiteProfileSnapshot>;
  removeSiteProfile(request: RemoveSiteProfileRequest): Promise<SiteProfileSnapshot>;
  openSiteProfile(profileId: string): Promise<RepositorySessionSnapshot>;
  getCapabilities(): Promise<CapabilitySnapshot>;
  getOperationLog(sessionId?: string): Promise<OperationLogSnapshot>;
  clearOperationLog(throughSequence: number, sessionId?: string): Promise<OperationLogSnapshot>;
  getWorkspaceState(): Promise<WorkspaceStateSnapshot>;
  updateWorkspacePreferences(preferences: WorkspacePreferences): Promise<WorkspaceStateSnapshot>;
  saveRecoveryDraft(request: SaveRecoveryDraftRequest): Promise<WorkspaceStateSnapshot>;
  clearRecoveryDraft(recoveryId: string): Promise<WorkspaceStateSnapshot>;
  openRepository(path: string): Promise<RepositorySessionSnapshot>;
  listMarkdownFiles(sessionId: string): Promise<MarkdownFileEntry[]>;
  inspectContentHealthSources(sessionId: string): Promise<ContentHealthSourceSnapshot>;
  inspectRepositoryImages(sessionId: string): Promise<RepositoryImageSnapshot>;
  readRepositoryImage(sessionId: string, relativePath: string, expectedSha256: string): Promise<RepositoryImagePreview>;
  openDocument(sessionId: string, relativePath: string): Promise<DocumentSnapshot>;
  inspectMarkdownLinkMetadata(sessionId: string, relativePath: string): Promise<MarkdownLinkMetadata>;
  saveDocument(request: SaveDocumentRequest): Promise<SaveDocumentResult>;
  createMarkdownDocument(sessionId: string, relativePath: string, initialText: string): Promise<DocumentSnapshot>;
  renameMarkdownDocument(sessionId: string, documentId: string, newRelativePath: string, expectedSha256: string): Promise<DocumentSnapshot>;
  deleteMarkdownDocument(sessionId: string, documentId: string, expectedSha256: string): Promise<DeleteMarkdownDocumentResult>;
  listDraftVersions(sessionId: string, documentId: string): Promise<DraftVersionSnapshot>;
  getDraftVersion(sessionId: string, documentId: string, versionId: string): Promise<DraftVersion>;
  restoreDraftVersion(sessionId: string, documentId: string, versionId: string, expectedSha256: string): Promise<DocumentSnapshot>;
  listRecycledDrafts(sessionId: string): Promise<RecycledDraftSnapshot>;
  getRecycledDraft(sessionId: string, recycleId: string): Promise<RecycledDraft>;
  restoreRecycledDraft(sessionId: string, recycleId: string, relativePath: string): Promise<DocumentSnapshot>;
  deleteRecycledDraft(sessionId: string, recycleId: string): Promise<RecycledDraftSnapshot>;
  listGeneralDrafts(): Promise<GeneralDraftSnapshot>;
  getGeneralDraft(draftId: string): Promise<GeneralDraft>;
  saveGeneralDraft(request: SaveGeneralDraftRequest): Promise<GeneralDraft>;
  planGeneralDraftTransfer(request: PlanGeneralDraftTransferRequest): Promise<GeneralDraftTransferPlan>;
  executeGeneralDraftTransfer(request: ExecuteGeneralDraftTransferRequest): Promise<GeneralDraftTransferResult>;
  undoGeneralDraftTransfer(request: UndoGeneralDraftTransferRequest): Promise<UndoGeneralDraftTransferResult>;
  importWritingImage(sessionId: string, sourcePath: string, documentId: string): Promise<WritingImageImportResult>;
  gitStatus(sessionId: string): Promise<GitStatusSnapshot>;
  searchMarkdownFiles(sessionId: string, query: string, limit?: number): Promise<MarkdownSearchSnapshot>;
  gitFileDiff(sessionId: string, relativePath: string): Promise<GitDiffSnapshot>;
  inspectSitePreview(sessionId: string): Promise<SitePreviewReadiness>;
  planSitePreview(sessionId: string, request: SitePreviewPlanRequest): Promise<SitePreviewPlan>;
  startSitePreview(sessionId: string, planId: string, confirmedTrustedRepository: boolean): Promise<SitePreviewSnapshot>;
  checkSitePreviewPage(sessionId: string, previewId: string, target: SitePreviewPageTarget): Promise<SitePreviewPageSnapshot>;
  stopSitePreview(sessionId: string, previewId: string): Promise<SitePreviewSnapshot>;
  credentialStatus(sessionId: string): Promise<CredentialStatusSnapshot>;
  storeRepositoryCredential(request: StoreRepositoryCredentialRequest): Promise<CredentialStatusSnapshot>;
  deleteRepositoryCredential(request: DeleteRepositoryCredentialRequest): Promise<CredentialStatusSnapshot>;
  planGitOperation(request: PlanGitOperationRequest): Promise<GitOperationPlan>;
  planGitPushRetry(sessionId: string): Promise<GitPushRetryPlan>;
  executeGitPushRetry(sessionId: string, planId: string): Promise<GitPushRetryResult>;
  executeGitOperation(request: ExecuteGitOperationRequest): Promise<GitOperationResult>;
  planGitIndexUpdate(request: PlanGitIndexUpdateRequest): Promise<GitIndexUpdatePlan>;
  executeGitIndexUpdate(request: ExecuteGitIndexUpdateRequest): Promise<GitIndexUpdateResult>;
  planRemoteReview(request: PlanRemoteReviewRequest): Promise<RemoteReviewPlan>;
  executeRemoteReview(request: ExecuteRemoteReviewRequest): Promise<RemoteReviewResult>;
  checkDeployment(sessionId: string): Promise<DeploymentCheckSnapshot>;
  browserProtocolStatus(sessionId: string): Promise<ReadinessSnapshot>;
  updateReadiness(): Promise<ReadinessSnapshot>;
  checkAppUpdate(): Promise<AppUpdateCheck>;
  installAppUpdate(planId: string): Promise<AppUpdateInstallResult>;
  planAiConnection(request: AiConnectionRequest): Promise<AiConnectionPlan>;
  executeAiConnection(request: ExecuteAiConnectionRequest): Promise<AiConnectionResult>;
  aiCredentialStatus(request: AiProviderRequest): Promise<AiCredentialStatusSnapshot>;
  storeAiCredential(request: StoreAiCredentialRequest): Promise<AiCredentialStatusSnapshot>;
  deleteAiCredential(request: AiProviderRequest): Promise<AiCredentialStatusSnapshot>;
  planAiEdit(request: PlanAiEditRequest): Promise<AiEditPlan>;
  executeAiEdit(request: ExecuteAiEditRequest): Promise<AiEditResponse>;
  planTextTranslation(request: PlanTextTranslationRequest): Promise<TextTranslationPlan>;
  executeTextTranslation(request: ExecuteTextTranslationRequest): Promise<TextTranslationResult>;
  planStructuredTextTranslation(request: PlanStructuredTextTranslationRequest): Promise<StructuredTextTranslationPlan>;
  executeStructuredTextTranslation(request: ExecuteStructuredTextTranslationRequest): Promise<StructuredTextTranslationResult>;
  applyAiEdits(request: ApplyAiEditsRequest): Promise<AiAppliedEdit>;
  listAiConversations(): Promise<AiConversation[]>;
  createAiConversation(request?: CreateAiConversationRequest): Promise<AiConversation>;
  deleteAiConversation(conversationId: string): Promise<AiConversationDeleteResult>;
  planAiChat(request: PlanAiChatRequest): Promise<AiChatPlan>;
  executeAiChat(request: ExecuteAiChatRequest): Promise<AiChatExecutionResult>;
  startAiChatStream(request: ExecuteAiChatRequest): Promise<AiChatStreamSnapshot>;
  pollAiChatStream(operationId: string, afterCursor: number): Promise<AiChatStreamSnapshot>;
  cancelAiChatStream(operationId: string): Promise<AiChatStreamSnapshot>;
  getAiChatVaultStatus(): Promise<AiChatVaultStatus>;
  initializeAiChatVault(passphrase: string): Promise<AiChatVaultStatus>;
  unlockAiChatVault(passphrase: string): Promise<AiChatVaultStatus>;
  lockAiChatVault(): Promise<AiChatVaultStatus>;
  deleteAiChatVault(): Promise<AiChatVaultStatus>;
  listAiProviderProfiles(): Promise<AiProviderProfile[]>;
  saveAiProviderProfile(request: SaveAiProviderProfileRequest): Promise<AiProviderProfile>;
  deleteAiProviderProfile(profileId: string): Promise<AiProviderProfileDeleteResult>;
  semanticIndexStatus(sessionId: string): Promise<SemanticIndexStatus>;
  rebuildSemanticIndex(sessionId: string): Promise<SemanticIndexStatus>;
  semanticSearch(sessionId: string, query: string, limit?: number): Promise<SemanticSearchSnapshot>;
  documentCapabilities(): Promise<DocumentCapabilities>;
  selectPdf(path: string): Promise<PdfSelection>;
  extractPdfText(token: string): Promise<PdfTextExtraction>;
  extractPdfOcr(token: string, language: PdfOcrLanguage): Promise<PdfOcrExtraction>;
  knowledgeLibraryStatus(): Promise<KnowledgeLibraryStatus>;
  listKnowledgeFolders(): Promise<KnowledgeFolderSnapshot>;
  createKnowledgeFolder(name: string): Promise<KnowledgeFolder>;
  moveKnowledgeItem(itemId: string, folderId: string | null): Promise<KnowledgeItemSummary>;
  listKnowledgeRevisions(itemId: string): Promise<KnowledgeRevisionSnapshot>;
  getKnowledgeRevision(itemId: string, revisionNumber: number): Promise<KnowledgeRevision>;
  takeKnowledgeOpenRequest(): Promise<string | null>;
  listKnowledgeItems(limit?: number): Promise<KnowledgeItemSnapshot>;
  getKnowledgeItem(itemId: string): Promise<KnowledgeItem>;
  importKnowledgeText(request: KnowledgeImportRequest): Promise<KnowledgeImportResult>;
  setKnowledgeRemoteAiPermission(request: SetKnowledgeRemoteAiPermissionRequest): Promise<KnowledgeItemSummary>;
  searchKnowledgeItems(query: string, limit?: number): Promise<KnowledgeSearchSnapshot>;
  updateKnowledgeProgress(request: KnowledgeProgressRequest): Promise<KnowledgeItemSummary>;
  deleteKnowledgeItem(itemId: string): Promise<KnowledgeLibraryStatus>;
  planKnowledgeExport(request: KnowledgeExportRequest): Promise<KnowledgeExportPlan>;
  executeKnowledgeExport(sessionId: string, planId: string): Promise<KnowledgeExportResult>;
  planKnowledgeArchiveExport(request: KnowledgeArchiveExportRequest): Promise<KnowledgeArchiveExportPlan>;
  executeKnowledgeArchiveExport(request: { sessionId: string; planId: string }): Promise<KnowledgeArchiveExportResult>;
  browserCaptureStatus(): Promise<BrowserCaptureStatus>;
  rotateBrowserCaptureToken(): Promise<BrowserCaptureStatus>;
}
