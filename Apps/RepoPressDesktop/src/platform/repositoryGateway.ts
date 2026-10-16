import type { SitePreviewPlanRequest, SitePreviewPlan, SitePreviewPageTarget, SitePreviewPageSnapshot } from "../contracts/sitePreview";
import type { KnowledgeRestoreHistoryExportStatus, KnowledgeRestoreHistoryExportPlan, KnowledgeRestoreHistoryExportReceipt } from "../contracts/knowledgeRestoreHistoryExport";
import type { KnowledgeRestoreCleanupAction, KnowledgeRestoreCleanupPlan, KnowledgeRestoreCleanupReceipt, KnowledgeRestoreCleanupStatus } from "../contracts/knowledgeRestoreCleanup";
import type { KnowledgeRestoreArchiveAction, KnowledgeRestoreArchivePlan, KnowledgeRestoreArchiveReceipt, KnowledgeRestoreArchiveStatus } from "../contracts/knowledgeRestoreArchive";
import type { KnowledgeRestoreInstallPlan, KnowledgeRestoreDiagnosis, KnowledgeRestoreRecoveryPlan, KnowledgeRestoreReceipt, KnowledgeRestoreRecoveryAction } from "../contracts/knowledgeRestoreInstall";
import type { KnowledgeMergeProjectionPlan, KnowledgeMergeProjectionReceipt } from "../contracts/knowledgeMergeProjection";
import type { KnowledgeRestoreQualificationPlan, KnowledgeRestoreQualificationRecheck, KnowledgeRestoreStrategy } from "../contracts/knowledgeRestoreQualification";
import type { KnowledgeCandidateCheckReport, KnowledgeCandidateRecheck } from "../contracts/knowledgeCandidateCheck";
import type { KnowledgePackageStagePlan, KnowledgePackageStageResult } from "../contracts/knowledgePackageStage";
import type { KnowledgePackageCheckReport, KnowledgePackageMemoryPreflight } from "../contracts/knowledgePackageCheck";
import type { KnowledgeBackupPlan, KnowledgeBackupResult } from "../contracts/knowledgeBackup";
import type { KnowledgeIntegrityReport, KnowledgeIntegrityRecheck } from "../contracts/knowledgeIntegrity";
import type { DraftSnapshotBackupPlan, DraftSnapshotBackupResult, DraftSnapshotSource } from "../contracts/draftSnapshotBackup";
import type { RssSnapshotBackupPlan, RssSnapshotBackupResult } from "../contracts/rssSnapshotBackup";
import type { WorkspaceConfigBackupPlan, WorkspaceConfigBackupResult, WorkspaceConfigBackupSource } from "../contracts/workspaceConfigBackup";
import type { WorkspaceBackupReport, WorkspaceBackupRecheck, WorkspaceBackupSource } from "../contracts/workspaceBackup";
import type { RollbackArchivePlan, RollbackArchiveResult } from "../contracts/rollbackArchive";
import type { RollbackTransactionPlan, RollbackRecord } from "../contracts/rollbackTransaction";
import type { RemoteReviewRecord, RemoteReviewVerificationPlan } from "../contracts/remoteReviewLedger";
import type { ReleaseLedgerSnapshot } from "../contracts/releaseLedger";
import type { RollbackQualificationPlan, RollbackQualificationReport } from "../contracts/rollbackQualification";
import type { RollbackChangePreview } from "../contracts/rollbackChangePreview";
import type { RollbackCandidatePlan, RollbackCandidateReport } from "../contracts/rollbackCandidate";
import type { PublishRecord, PublishVerificationPlan } from "../contracts/publishLedger";
import { exitActivity } from "./exitActivity";
import type { AiConnectionRequest, ExecuteAiConnectionRequest, AiConnectionPlan, AiConnectionResult } from "../contracts/aiConnection";
import type { MetadataBatchRequest, MetadataBatchPlan, MetadataBatchResult } from "../contracts/metadataBatch";
import type { RegisterSiteProfileRequest, RenameSiteProfileRequest, RemoveSiteProfileRequest, SiteProfileSnapshot } from "../contracts/sites";
import type { OperationLogSnapshot } from "../contracts/activity";
import type { RepositoryImageSnapshot, RepositoryImagePreview } from "../contracts/images";
import { invoke } from "@tauri-apps/api/core";
import type { BrowserCaptureStatus, KnowledgeArchiveExportPlan, KnowledgeArchiveExportRequest, KnowledgeArchiveExportResult, KnowledgeExportPlan, KnowledgeExportRequest, KnowledgeExportResult, KnowledgeFolder, KnowledgeFolderSnapshot, KnowledgeImportRequest, KnowledgeImportResult, KnowledgeItem, KnowledgeItemSnapshot, KnowledgeItemSummary, KnowledgeLibraryStatus, KnowledgeProgressRequest, KnowledgeRevision, KnowledgeRevisionSnapshot, KnowledgeSearchSnapshot, SetKnowledgeRemoteAiPermissionRequest } from "../contracts/repository";
import type { ExecuteGeneralDraftTransferRequest, GeneralDraft, GeneralDraftSnapshot, GeneralDraftTransferPlan, GeneralDraftTransferResult, PlanGeneralDraftTransferRequest, SaveGeneralDraftRequest, UndoGeneralDraftTransferRequest, UndoGeneralDraftTransferResult } from "../contracts/repository";
import type { AiAppliedEdit, AiChatExecutionResult, AiChatPlan, AiChatStreamSnapshot, AiChatVaultStatus, AiConversation, AiConversationDeleteResult, AiCredentialStatusSnapshot, AiEditPlan, AiEditResponse, AiProviderProfile, AiProviderProfileDeleteResult, AiProviderRequest, ApplyAiEditsRequest, AppUpdateCheck, AppUpdateInstallResult, CapabilitySnapshot, ContentHealthSourceSnapshot, CreateAiConversationRequest, CredentialStatusSnapshot, DeleteMarkdownDocumentResult, DeleteRepositoryCredentialRequest, DeploymentCheckSnapshot, DocumentCapabilities, DocumentSnapshot, DraftVersion, DraftVersionSnapshot, ExecuteAiChatRequest, ExecuteAiEditRequest, ExecuteGitIndexUpdateRequest, ExecuteGitOperationRequest, ExecuteRemoteReviewRequest, ExecuteStructuredTextTranslationRequest, ExecuteTextTranslationRequest, GitDiffSnapshot, GitIndexUpdatePlan, GitIndexUpdateResult, GitOperationPlan, GitOperationResult, GitStatusSnapshot, MarkdownFileEntry, MarkdownLinkMetadata, MarkdownSearchSnapshot, PdfOcrExtraction, PdfOcrLanguage, PdfSelection, PdfTextExtraction, PlanAiChatRequest, PlanAiEditRequest, PlanGitIndexUpdateRequest, PlanGitOperationRequest, PlanRemoteReviewRequest, PlanStructuredTextTranslationRequest, PlanTextTranslationRequest, ReadinessSnapshot, RecycledDraft, RecycledDraftSnapshot, RemoteReviewPlan, RemoteReviewResult, RepositoryGateway, RepositorySessionSnapshot, SaveAiProviderProfileRequest, SaveDocumentRequest, SaveDocumentResult, SaveRecoveryDraftRequest, SemanticIndexStatus, SemanticSearchSnapshot, SitePreviewReadiness, SitePreviewSnapshot, StoreAiCredentialRequest, StoreRepositoryCredentialRequest, StructuredTextTranslationPlan, StructuredTextTranslationResult, TextTranslationPlan, TextTranslationResult, WorkspacePreferences, WorkspaceStateSnapshot, WritingImageImportResult } from "../contracts/repository";

type Invoke = <T>(command: string, args?: object) => Promise<T>;
const command = { planAiConnection: "plan_ai_connection", executeAiConnection: "execute_ai_connection", capabilities: "get_capabilities", getOperationLog: "get_operation_log", clearOperationLog: "clear_operation_log", getWorkspaceState: "get_workspace_state", updateWorkspacePreferences: "update_workspace_preferences", saveRecoveryDraft: "save_recovery_draft", clearRecoveryDraft: "clear_recovery_draft", openRepository: "open_repository", listMarkdownFiles: "list_markdown_files", inspectContentHealthSources: "inspect_content_health_sources", inspectRepositoryImages: "inspect_repository_images", readRepositoryImage: "read_repository_image", openDocument: "open_document", inspectMarkdownLinkMetadata: "inspect_markdown_link_metadata", saveDocument: "save_document", createMarkdownDocument: "create_markdown_document", renameMarkdownDocument: "rename_markdown_document", deleteMarkdownDocument: "delete_markdown_document", listDraftVersions: "list_draft_versions", getDraftVersion: "get_draft_version", restoreDraftVersion: "restore_draft_version", listRecycledDrafts: "list_recycled_drafts", getRecycledDraft: "get_recycled_draft", restoreRecycledDraft: "restore_recycled_draft", deleteRecycledDraft: "delete_recycled_draft", listGeneralDrafts: "list_general_drafts", getGeneralDraft: "get_general_draft", saveGeneralDraft: "save_general_draft", planGeneralDraftTransfer: "plan_general_draft_transfer", executeGeneralDraftTransfer: "execute_general_draft_transfer", undoGeneralDraftTransfer: "undo_general_draft_transfer", importWritingImage: "import_writing_image", gitStatus: "git_status", searchMarkdownFiles: "search_markdown_files", gitFileDiff: "git_file_diff", inspectSitePreview: "inspect_site_preview", planSitePreview: "plan_site_preview", startSitePreview: "start_site_preview", checkSitePreviewPage: "check_site_preview_page", stopSitePreview: "stop_site_preview", credentialStatus: "credential_status", storeRepositoryCredential: "store_repository_credential", deleteRepositoryCredential: "delete_repository_credential", planGitOperation: "plan_git_operation", executeGitOperation: "execute_git_operation", planGitIndexUpdate: "plan_git_index_update", executeGitIndexUpdate: "execute_git_index_update", planRemoteReview: "plan_remote_review", executeRemoteReview: "execute_remote_review", checkDeployment: "check_deployment", browserProtocolStatus: "browser_protocol_status", updateReadiness: "update_readiness", checkAppUpdate: "check_app_update", installAppUpdate: "install_app_update", aiCredentialStatus: "ai_credential_status", storeAiCredential: "store_ai_credential", deleteAiCredential: "delete_ai_credential", planAiEdit: "plan_ai_edit", executeAiEdit: "execute_ai_edit", applyAiEdits: "apply_ai_edits", listAiConversations: "list_ai_conversations", createAiConversation: "create_ai_conversation", deleteAiConversation: "delete_ai_conversation", planAiChat: "plan_ai_chat", executeAiChat: "execute_ai_chat", startAiChatStream: "start_ai_chat_stream", pollAiChatStream: "poll_ai_chat_stream", cancelAiChatStream: "cancel_ai_chat_stream", aiChatVaultStatus: "get_ai_chat_vault_status", initializeAiChatVault: "initialize_ai_chat_vault", unlockAiChatVault: "unlock_ai_chat_vault", lockAiChatVault: "lock_ai_chat_vault", deleteAiChatVault: "delete_ai_chat_vault", listAiProviderProfiles: "list_ai_provider_profiles", saveAiProviderProfile: "save_ai_provider_profile", deleteAiProviderProfile: "delete_ai_provider_profile", planTextTranslation: "plan_text_translation", executeTextTranslation: "execute_text_translation", planStructuredTextTranslation: "plan_structured_text_translation", executeStructuredTextTranslation: "execute_structured_text_translation", semanticIndexStatus: "semantic_index_status", rebuildSemanticIndex: "rebuild_semantic_index", semanticSearch: "semantic_search", documentCapabilities: "document_capabilities", selectPdf: "select_pdf", extractPdfText: "extract_pdf_text", extractPdfOcr: "extract_pdf_ocr" } as const;
const siteCommand = { list: "get_site_profiles", register: "register_site_profile", rename: "rename_site_profile", remove: "remove_site_profile", open: "open_site_profile" } as const;
const knowledgeCommand = { status: "knowledge_library_status", list: "list_knowledge_items", get: "get_knowledge_item", import: "import_knowledge_text", setRemoteAiPermission: "set_knowledge_remote_ai_permission", search: "search_knowledge_items", progress: "update_knowledge_progress", remove: "delete_knowledge_item", plan: "plan_knowledge_export", execute: "execute_knowledge_export", archivePlan: "plan_knowledge_archive_export", archiveExecute: "execute_knowledge_archive_export", folders: "list_knowledge_folders", createFolder: "create_knowledge_folder", move: "move_knowledge_item", revisions: "list_knowledge_revisions", revision: "get_knowledge_revision", openRequest: "take_knowledge_open_request", browser: "browser_capture_status", rotate: "rotate_browser_capture_token" } as const;
export function createRepositoryGateway(tauriInvoke?: Invoke): RepositoryGateway {
  const defaultInvoke: Invoke = (name, args) => exitActivity.run(() => invoke(name, args as never));
  return tauriInvoke || isTauriRuntime() ? new TauriRepositoryGateway(tauriInvoke ?? defaultInvoke) : new BrowserDemoRepositoryGateway();
}
class TauriRepositoryGateway implements RepositoryGateway {
  inspectKnowledgeRestoreHistoryExport() { return this.call<KnowledgeRestoreHistoryExportStatus>("inspect_knowledge_restore_history_export"); }
  async selectKnowledgeRestoreHistoryExportDestination(): Promise<string | null> {
    const { save } = await import("@tauri-apps/plugin-dialog");
    return save({ title: "选择新的恢复历史 JSON 文件路径", defaultPath: "repopress-knowledge-history-saved-files.json", filters: [{ name: "资料保存文件备份包", extensions: ["json"] }] });
  }
  planKnowledgeRestoreHistoryExport(transactionId: string, destinationPath: string) { return this.call<KnowledgeRestoreHistoryExportPlan>("plan_knowledge_restore_history_export", { transactionId, destinationPath }); }
  executeKnowledgeRestoreHistoryExport(planId: string, confirmSensitivePlaintext: boolean) { return this.call<KnowledgeRestoreHistoryExportReceipt>("execute_knowledge_restore_history_export", { planId, confirmSensitivePlaintext }); }
  discardKnowledgeRestoreHistoryExport(planId: string) { return this.call<void>("discard_knowledge_restore_history_export", { planId }); }
  inspectKnowledgeRestoreCleanup() { return this.call<KnowledgeRestoreCleanupStatus>("inspect_knowledge_restore_cleanup"); }
  planKnowledgeRestoreCleanup(transactionId: string, action: KnowledgeRestoreCleanupAction) { return this.call<KnowledgeRestoreCleanupPlan>("plan_knowledge_restore_cleanup", { transactionId, action }); }
  executeKnowledgeRestoreCleanup(planId: string, acknowledgeDeletion: boolean) { return this.call<KnowledgeRestoreCleanupReceipt>("execute_knowledge_restore_cleanup", { planId, acknowledgeDeletion }); }
  discardKnowledgeRestoreCleanup(planId: string) { return this.call<void>("discard_knowledge_restore_cleanup", { planId }); }
  inspectKnowledgeRestoreArchive() { return this.call<KnowledgeRestoreArchiveStatus>("inspect_knowledge_restore_archive"); }
  planKnowledgeRestoreArchive(transactionId: string, action: KnowledgeRestoreArchiveAction) { return this.call<KnowledgeRestoreArchivePlan>("plan_knowledge_restore_archive", { transactionId, action }); }
  executeKnowledgeRestoreArchive(planId: string, acknowledgeArchive: boolean) { return this.call<KnowledgeRestoreArchiveReceipt>("execute_knowledge_restore_archive", { planId, acknowledgeArchive }); }
  discardKnowledgeRestoreArchive(planId: string) { return this.call<void>("discard_knowledge_restore_archive", { planId }); }
  planKnowledgeRestoreInstall(candidatePath: string, strategy: KnowledgeRestoreStrategy) { return this.call<KnowledgeRestoreInstallPlan>("plan_knowledge_restore_install", { candidatePath, strategy }); }
  executeKnowledgeRestoreInstall(planId: string, acknowledgeInstall: boolean) { return this.call<KnowledgeRestoreReceipt>("execute_knowledge_restore_install", { planId, acknowledgeInstall }); }
  inspectKnowledgeRestore() { return this.call<KnowledgeRestoreDiagnosis>("inspect_knowledge_restore"); }
  planKnowledgeRestoreRecovery(transactionId: string, action: KnowledgeRestoreRecoveryAction) { return this.call<KnowledgeRestoreRecoveryPlan>("plan_knowledge_restore_recovery", { transactionId, action }); }
  executeKnowledgeRestoreRecovery(planId: string, acknowledgeRecovery: boolean) { return this.call<KnowledgeRestoreReceipt>("execute_knowledge_restore_recovery", { planId, acknowledgeRecovery }); }
  discardKnowledgeRestoreInstall(planId: string) { return this.call<void>("discard_knowledge_restore_install", { planId }); }
  planKnowledgeMergeProjection(candidatePath: string, strategy: KnowledgeRestoreStrategy) { return this.call<KnowledgeMergeProjectionPlan>("plan_knowledge_merge_projection", { candidatePath, strategy }); }
  preflightKnowledgeMergeProjection(planId: string, acknowledgePrivacyReset: boolean) { return this.call<KnowledgeMergeProjectionReceipt>("preflight_knowledge_merge_projection", { planId, acknowledgePrivacyReset }); }
  discardKnowledgeMergeProjection(planId: string) { return this.call<void>("discard_knowledge_merge_projection", { planId }); }
  planKnowledgeRestoreQualification(candidatePath: string, strategy: KnowledgeRestoreStrategy) { return this.call<KnowledgeRestoreQualificationPlan>("plan_knowledge_restore_qualification", { candidatePath, strategy }); }
  recheckKnowledgeRestoreQualification(planId: string) { return this.call<KnowledgeRestoreQualificationRecheck>("recheck_knowledge_restore_qualification", { planId }); }
  discardKnowledgeRestoreQualification(planId: string) { return this.call<void>("discard_knowledge_restore_qualification", { planId }); }
  async selectKnowledgeCandidateDirectory(): Promise<string | null> {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({ title: "选择私有资料候选目录", multiple: false, directory: true });
    return typeof selected === "string" ? selected : null;
  }
  inspectKnowledgeCandidate(candidatePath: string) { return this.call<KnowledgeCandidateCheckReport>("inspect_knowledge_candidate", { candidatePath }); }
  recheckKnowledgeCandidate(reportId: string) { return this.call<KnowledgeCandidateRecheck>("recheck_knowledge_candidate", { reportId }); }
  discardKnowledgeCandidateCheck(reportId: string) { return this.call<void>("discard_knowledge_candidate_check", { reportId }); }

  async selectKnowledgePackageStageSource(): Promise<string | null> {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({ title: "选择待暂存的资料 JSON 包", multiple: false, directory: false, filters: [{ name: "资料保存文件备份包", extensions: ["json"] }] });
    return typeof selected === "string" ? selected : null;
  }
  async selectKnowledgePackageStageParent(): Promise<string | null> {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({ title: "选择私有资料暂存目录的父目录", multiple: false, directory: true });
    return typeof selected === "string" ? selected : null;
  }
  planKnowledgePackageStage(sourcePath: string, parentPath: string) { return this.call<KnowledgePackageStagePlan>("plan_knowledge_package_stage", { sourcePath, parentPath }); }
  executeKnowledgePackageStage(planId: string, confirmSensitivePlaintext: boolean) { return this.call<KnowledgePackageStageResult>("execute_knowledge_package_stage", { planId, confirmSensitivePlaintext }); }
  discardKnowledgePackageStage(planId: string) { return this.call<void>("discard_knowledge_package_stage", { planId }); }
  async selectKnowledgePackageSource(): Promise<string | null> {
    const { open } = await import("@tauri-apps/plugin-dialog");
    const selected = await open({ title: "选择资料保存文件 JSON 包", multiple: false, directory: false, filters: [{ name: "资料保存文件备份包", extensions: ["json"] }] });
    return typeof selected === "string" ? selected : null;
  }
  inspectKnowledgePackage(sourcePath: string) { return this.call<KnowledgePackageCheckReport>("inspect_knowledge_package", { sourcePath }); }
  preflightKnowledgePackage(reportId: string) { return this.call<KnowledgePackageMemoryPreflight>("preflight_knowledge_package", { reportId }); }
  discardKnowledgePackageCheck(reportId: string) { return this.call<void>("discard_knowledge_package_check", { reportId }); }
  async selectKnowledgeBackupDestination() {
    const { save } = await import("@tauri-apps/plugin-dialog");
    return save({ title: "选择新的资料 JSON 文件路径", defaultPath: "repopress-knowledge-saved-files.json", filters: [{ name: "资料保存文件备份包", extensions: ["json"] }] });
  }
  planKnowledgeBackup(destinationPath: string) { return this.call<KnowledgeBackupPlan>("plan_knowledge_backup", { destinationPath }); }
  executeKnowledgeBackup(planId: string, confirmSensitivePlaintext: boolean) { return this.call<KnowledgeBackupResult>("execute_knowledge_backup", { planId, confirmSensitivePlaintext }); }
  discardKnowledgeBackup(planId: string) { return this.call<void>("discard_knowledge_backup", { planId }); }
  inspectKnowledgeIntegrity() { return this.call<KnowledgeIntegrityReport>("inspect_knowledge_integrity", {}); }
  recheckKnowledgeIntegrity(reportId: string) { return this.call<KnowledgeIntegrityRecheck>("recheck_knowledge_integrity", { reportId }); }
  discardKnowledgeIntegrity(reportId: string) { return this.call<void>("discard_knowledge_integrity", { reportId }); }
  inspectWorkspaceBackup(sources: WorkspaceBackupSource[]) { return this.call<WorkspaceBackupReport>("inspect_workspace_backup", { sources }); }
  async selectDraftSnapshotBackupDestination(source: DraftSnapshotSource) {
    const { save } = await import("@tauri-apps/plugin-dialog");
    return save({ title: "导出草稿数据库快照", defaultPath: source === "generalDrafts" ? "repopress-general-drafts.sqlite" : "repopress-draft-history.sqlite", filters: [{ name: "SQLite", extensions: ["sqlite"] }] });
  }
  planDraftSnapshotBackup(source: DraftSnapshotSource, destinationPath: string) { return this.call<DraftSnapshotBackupPlan>("plan_draft_snapshot_backup", { source, destinationPath }); }
  executeDraftSnapshotBackup(planId: string, confirmSensitivePlaintext: boolean) { return this.call<DraftSnapshotBackupResult>("execute_draft_snapshot_backup", { planId, confirmSensitivePlaintext }); }
  discardDraftSnapshotBackup(planId: string) { return this.call<void>("discard_draft_snapshot_backup", { planId }); }

  async selectRssSnapshotBackupDestination() {
    const { save } = await import("@tauri-apps/plugin-dialog");
    return save({ title: "导出 RSS 数据库快照", defaultPath: "repopress-rss-snapshot.sqlite", filters: [{ name: "SQLite", extensions: ["sqlite"] }] });
  }
  planRssSnapshotBackup(destinationPath: string) { return this.call<RssSnapshotBackupPlan>("plan_rss_snapshot_backup", { destinationPath }); }
  executeRssSnapshotBackup(planId: string, confirmSensitivePlaintext: boolean) { return this.call<RssSnapshotBackupResult>("execute_rss_snapshot_backup", { planId, confirmSensitivePlaintext }); }
  discardRssSnapshotBackup(planId: string) { return this.call<void>("discard_rss_snapshot_backup", { planId }); }

  async selectWorkspaceConfigBackupDestination() {
    const { save } = await import("@tauri-apps/plugin-dialog");
    return save({ title: "导出已保存配置备份", defaultPath: "repopress-workspace-config.json", filters: [{ name: "JSON", extensions: ["json"] }] });
  }
  planWorkspaceConfigBackup(sources: WorkspaceConfigBackupSource[], destinationPath: string) { return this.call<WorkspaceConfigBackupPlan>("plan_workspace_config_backup", { sources, destinationPath }); }
  executeWorkspaceConfigBackup(planId: string, confirmSensitivePlaintext: boolean) { return this.call<WorkspaceConfigBackupResult>("execute_workspace_config_backup", { planId, confirmSensitivePlaintext }); }
  discardWorkspaceConfigBackup(planId: string) { return this.call<void>("discard_workspace_config_backup", { planId }); }
  recheckWorkspaceBackup(reportId: string) { return this.call<WorkspaceBackupRecheck>("recheck_workspace_backup", { reportId }); }
  discardWorkspaceBackup(reportId: string) { return this.call<void>("discard_workspace_backup", { reportId }); }

  async selectRollbackArchiveDestination() {
    const { save } = await import("@tauri-apps/plugin-dialog");
    return save({ title: "导出恢复证据", defaultPath: "repopress-rollback-evidence.json", filters: [{ name: "JSON", extensions: ["json"] }] });
  }
  planRollbackArchive(sessionId: string, destinationPath: string) { return this.call<RollbackArchivePlan>("plan_rollback_archive", { sessionId, destinationPath }); }
  executeRollbackArchive(sessionId: string, planId: string) { return this.call<RollbackArchiveResult>("execute_rollback_archive", { sessionId, planId }); }
  discardRollbackArchive(sessionId: string, planId: string) { return this.call<void>("discard_rollback_archive", { sessionId, planId }); }

  listRemoteReviewRecords(sessionId: string) { return this.call<RemoteReviewRecord[]>("list_remote_review_records", { sessionId }); }
  planRemoteReviewVerification(sessionId: string, recordId: string) { return this.call<RemoteReviewVerificationPlan>("plan_remote_review_verification", { sessionId, recordId }); }
  executeRemoteReviewVerification(sessionId: string, planId: string) { return this.call<RemoteReviewRecord>("execute_remote_review_verification", { sessionId, planId }); }
  removeRemoteReviewRecord(sessionId: string, recordId: string, revision: number) { return this.call<RemoteReviewRecord[]>("remove_remote_review_record", { sessionId, recordId, revision }); }
  removePublishRecord(sessionId: string, recordId: string, revision: number) { return this.call<PublishRecord[]>("remove_publish_record", { sessionId, recordId, revision }); }
  listPublishRecords(sessionId: string) { return this.call<PublishRecord[]>("list_publish_records", { sessionId }); }
  getReleaseLedger(sessionId: string) { return this.call<ReleaseLedgerSnapshot>("get_release_ledger", { sessionId }); }
  planRollbackTransaction(sessionId: string, recordId: string, revision: number) { return this.call<RollbackTransactionPlan>("plan_rollback_transaction", { sessionId, recordId, revision }); }
  executeRollbackTransaction(sessionId: string, planId: string) { return this.call<RollbackRecord>("execute_rollback_transaction", { sessionId, planId }); }
  discardRollbackTransaction(sessionId: string, planId: string) { return this.call<void>("discard_rollback_transaction", { sessionId, planId }); }
  listRollbackRecords(sessionId: string) { return this.call<RollbackRecord[]>("list_rollback_records", { sessionId }); }
  verifyRollbackRecord(sessionId: string, recordId: string, revision: number) { return this.call<RollbackRecord>("verify_rollback_record", { sessionId, recordId, revision }); }
  planRollbackCandidate(sessionId: string, recordId: string, revision: number) { return this.call<RollbackCandidatePlan>("plan_rollback_candidate", { sessionId, recordId, revision }); }
  generateRollbackCandidate(sessionId: string, planId: string) { return this.call<RollbackCandidateReport>("generate_rollback_candidate", { sessionId, planId }); }
  discardRollbackCandidate(sessionId: string, planId: string) { return this.call<void>("discard_rollback_candidate", { sessionId, planId }); }
  inspectRollbackChanges(sessionId: string, recordId: string, revision: number) { return this.call<RollbackChangePreview>("inspect_rollback_changes", { sessionId, recordId, revision }); }
  planRollbackQualification(sessionId: string, recordId: string, revision: number) { return this.call<RollbackQualificationPlan>("plan_rollback_qualification", { sessionId, recordId, revision }); }
  checkRollbackQualification(sessionId: string, planId: string) { return this.call<RollbackQualificationReport>("check_rollback_qualification", { sessionId, planId }); }
  planPublishVerification(sessionId: string, recordId: string) { return this.call<PublishVerificationPlan>("plan_publish_verification", { sessionId, recordId }); }
  executePublishVerification(sessionId: string, planId: string) { return this.call<PublishRecord>("execute_publish_verification", { sessionId, planId }); }
  planAiConnection(request: AiConnectionRequest) { return this.call<AiConnectionPlan>(command.planAiConnection, { ...request }); }
  executeAiConnection(request: ExecuteAiConnectionRequest) { return this.call<AiConnectionResult>(command.executeAiConnection, { ...request }); }
  planGitPushRetry(sessionId: string) { return this.call<import("../contracts/gitPushRetry").GitPushRetryPlan>("plan_git_push_retry", { sessionId }); }
  executeGitPushRetry(sessionId: string, planId: string) { return this.call<import("../contracts/gitPushRetry").GitPushRetryResult>("execute_git_push_retry", { sessionId, planId }); }
  planMetadataBatch(request: MetadataBatchRequest) { return this.call<MetadataBatchPlan>("plan_metadata_batch", { ...request }); }
  executeMetadataBatch(sessionId: string, planId: string) { return this.call<MetadataBatchResult>("execute_metadata_batch", { sessionId, planId }); }
  constructor(private readonly call: Invoke) {}
  getSiteProfiles() { return this.call<SiteProfileSnapshot>(siteCommand.list); }
  registerSiteProfile(request: RegisterSiteProfileRequest) { return this.call<SiteProfileSnapshot>(siteCommand.register, { ...request }); }
  renameSiteProfile(request: RenameSiteProfileRequest) { return this.call<SiteProfileSnapshot>(siteCommand.rename, { ...request }); }
  removeSiteProfile(request: RemoveSiteProfileRequest) { return this.call<SiteProfileSnapshot>(siteCommand.remove, { ...request }); }
  openSiteProfile(profileId: string) { return this.call<RepositorySessionSnapshot>(siteCommand.open, { profileId }); }
  getOperationLog(sessionId?: string) { return this.call<OperationLogSnapshot>(command.getOperationLog, { sessionId: sessionId ?? null }); }
  clearOperationLog(throughSequence: number, sessionId?: string) { return this.call<OperationLogSnapshot>(command.clearOperationLog, { throughSequence, sessionId: sessionId ?? null }); }
  getCapabilities() { return this.call<CapabilitySnapshot>(command.capabilities); }
  getWorkspaceState() { return this.call<WorkspaceStateSnapshot>(command.getWorkspaceState); }
  updateWorkspacePreferences(preferences: WorkspacePreferences) { return this.call<WorkspaceStateSnapshot>(command.updateWorkspacePreferences, { preferences }); }
  saveRecoveryDraft(request: SaveRecoveryDraftRequest) { return this.call<WorkspaceStateSnapshot>(command.saveRecoveryDraft, request); }
  clearRecoveryDraft(recoveryId: string) { return this.call<WorkspaceStateSnapshot>(command.clearRecoveryDraft, { recoveryId }); }
  openRepository(path: string) { return this.call<RepositorySessionSnapshot>(command.openRepository, { path }); }
  listMarkdownFiles(sessionId: string) { return this.call<MarkdownFileEntry[]>(command.listMarkdownFiles, { sessionId }); }
  inspectRepositoryImages(sessionId: string) { return this.call<RepositoryImageSnapshot>(command.inspectRepositoryImages, { sessionId }); }
  readRepositoryImage(sessionId: string, relativePath: string, expectedSha256: string) { return this.call<RepositoryImagePreview>(command.readRepositoryImage, { sessionId, relativePath, expectedSha256 }); }
  inspectContentHealthSources(sessionId: string) { return this.call<ContentHealthSourceSnapshot>(command.inspectContentHealthSources, { sessionId }); }
  openDocument(sessionId: string, relativePath: string) { return this.call<DocumentSnapshot>(command.openDocument, { sessionId, relativePath }); }
  inspectMarkdownLinkMetadata(sessionId: string, relativePath: string) { return this.call<MarkdownLinkMetadata>(command.inspectMarkdownLinkMetadata, { sessionId, relativePath }); }
  saveDocument(request: SaveDocumentRequest) { return this.call<SaveDocumentResult>(command.saveDocument, request); }
  createMarkdownDocument(sessionId: string, relativePath: string, initialText: string) { return this.call<DocumentSnapshot>(command.createMarkdownDocument, { sessionId, relativePath, initialText }); }
  renameMarkdownDocument(sessionId: string, documentId: string, newRelativePath: string, expectedSha256: string) { return this.call<DocumentSnapshot>(command.renameMarkdownDocument, { sessionId, documentId, newRelativePath, expectedSha256 }); }
  deleteMarkdownDocument(sessionId: string, documentId: string, expectedSha256: string) { return this.call<DeleteMarkdownDocumentResult>(command.deleteMarkdownDocument, { sessionId, documentId, expectedSha256 }); }
  listDraftVersions(sessionId: string, documentId: string) { return this.call<DraftVersionSnapshot>(command.listDraftVersions, { sessionId, documentId }); }
  getDraftVersion(sessionId: string, documentId: string, versionId: string) { return this.call<DraftVersion>(command.getDraftVersion, { sessionId, documentId, versionId }); }
  restoreDraftVersion(sessionId: string, documentId: string, versionId: string, expectedSha256: string) { return this.call<DocumentSnapshot>(command.restoreDraftVersion, { sessionId, documentId, versionId, expectedSha256 }); }
  listRecycledDrafts(sessionId: string) { return this.call<RecycledDraftSnapshot>(command.listRecycledDrafts, { sessionId }); }
  getRecycledDraft(sessionId: string, recycleId: string) { return this.call<RecycledDraft>(command.getRecycledDraft, { sessionId, recycleId }); }
  restoreRecycledDraft(sessionId: string, recycleId: string, relativePath: string) { return this.call<DocumentSnapshot>(command.restoreRecycledDraft, { sessionId, recycleId, relativePath }); }
  deleteRecycledDraft(sessionId: string, recycleId: string) { return this.call<RecycledDraftSnapshot>(command.deleteRecycledDraft, { sessionId, recycleId }); }
  listGeneralDrafts() { return this.call<GeneralDraftSnapshot>(command.listGeneralDrafts); }
  getGeneralDraft(draftId: string) { return this.call<GeneralDraft>(command.getGeneralDraft, { draftId }); }
  saveGeneralDraft(request: SaveGeneralDraftRequest) { return this.call<GeneralDraft>(command.saveGeneralDraft, request); }
  planGeneralDraftTransfer(request: PlanGeneralDraftTransferRequest) { return this.call<GeneralDraftTransferPlan>(command.planGeneralDraftTransfer, request); }
  executeGeneralDraftTransfer(request: ExecuteGeneralDraftTransferRequest) { return this.call<GeneralDraftTransferResult>(command.executeGeneralDraftTransfer, request); }
  undoGeneralDraftTransfer(request: UndoGeneralDraftTransferRequest) { return this.call<UndoGeneralDraftTransferResult>(command.undoGeneralDraftTransfer, request); }
  importWritingImage(sessionId: string, sourcePath: string, documentId: string) { return this.call<WritingImageImportResult>(command.importWritingImage, { sessionId, sourcePath, documentId }); }
  gitStatus(sessionId: string) { return this.call<GitStatusSnapshot>(command.gitStatus, { sessionId }); }
  searchMarkdownFiles(sessionId: string, query: string, limit = 100) { return this.call<MarkdownSearchSnapshot>(command.searchMarkdownFiles, { sessionId, query, limit }); }
  gitFileDiff(sessionId: string, relativePath: string) { return this.call<GitDiffSnapshot>(command.gitFileDiff, { sessionId, relativePath }); }
  inspectSitePreview(sessionId: string) { return this.call<SitePreviewReadiness>(command.inspectSitePreview, { sessionId }); }
  planSitePreview(sessionId: string, request: SitePreviewPlanRequest) { return this.call<SitePreviewPlan>(command.planSitePreview, { sessionId, request }); }
  startSitePreview(sessionId: string, planId: string, confirmedTrustedRepository: boolean) { return this.call<SitePreviewSnapshot>(command.startSitePreview, { sessionId, planId, confirmedTrustedRepository }); }
  checkSitePreviewPage(sessionId: string, previewId: string, target: SitePreviewPageTarget) { return this.call<SitePreviewPageSnapshot>(command.checkSitePreviewPage, { sessionId, previewId, target }); }
  stopSitePreview(sessionId: string, previewId: string) { return this.call<SitePreviewSnapshot>(command.stopSitePreview, { sessionId, previewId }); }
  credentialStatus(sessionId: string) { return this.call<CredentialStatusSnapshot>(command.credentialStatus, { sessionId }); }
  storeRepositoryCredential(request: StoreRepositoryCredentialRequest) { return this.call<CredentialStatusSnapshot>(command.storeRepositoryCredential, request); }
  deleteRepositoryCredential(request: DeleteRepositoryCredentialRequest) { return this.call<CredentialStatusSnapshot>(command.deleteRepositoryCredential, request); }
  planGitOperation(request: PlanGitOperationRequest) { return this.call<GitOperationPlan>(command.planGitOperation, request); }
  executeGitOperation(request: ExecuteGitOperationRequest) { return this.call<GitOperationResult>(command.executeGitOperation, request); }
  planGitIndexUpdate(request: PlanGitIndexUpdateRequest) { return this.call<GitIndexUpdatePlan>(command.planGitIndexUpdate, request); }
  executeGitIndexUpdate(request: ExecuteGitIndexUpdateRequest) { return this.call<GitIndexUpdateResult>(command.executeGitIndexUpdate, request); }
  planRemoteReview(request: PlanRemoteReviewRequest) { return this.call<RemoteReviewPlan>(command.planRemoteReview, request); }
  executeRemoteReview(request: ExecuteRemoteReviewRequest) { return this.call<RemoteReviewResult>(command.executeRemoteReview, request); }
  checkDeployment(sessionId: string) { return this.call<DeploymentCheckSnapshot>(command.checkDeployment, { sessionId }); }
  browserProtocolStatus(sessionId: string) { return this.call<ReadinessSnapshot>(command.browserProtocolStatus, { sessionId }); }
  updateReadiness() { return this.call<ReadinessSnapshot>(command.updateReadiness); }
  checkAppUpdate() { return this.call<AppUpdateCheck>(command.checkAppUpdate); }
  installAppUpdate(planId: string) { return this.call<AppUpdateInstallResult>(command.installAppUpdate, { planId }); }
  aiCredentialStatus(request: AiProviderRequest) { return this.call<AiCredentialStatusSnapshot>(command.aiCredentialStatus, request); }
  storeAiCredential(request: StoreAiCredentialRequest) { return this.call<AiCredentialStatusSnapshot>(command.storeAiCredential, request); }
  deleteAiCredential(request: AiProviderRequest) { return this.call<AiCredentialStatusSnapshot>(command.deleteAiCredential, request); }
  planAiEdit(request: PlanAiEditRequest) { return this.call<AiEditPlan>(command.planAiEdit, request); }
  executeAiEdit(request: ExecuteAiEditRequest) { return this.call<AiEditResponse>(command.executeAiEdit, request); }
  applyAiEdits(request: ApplyAiEditsRequest) { return this.call<AiAppliedEdit>(command.applyAiEdits, request); }
  listAiConversations() { return this.call<AiConversation[]>(command.listAiConversations); }
  createAiConversation(request: CreateAiConversationRequest = {}) { return this.call<AiConversation>(command.createAiConversation, { title: request.title ?? null }); }
  deleteAiConversation(conversationId: string) { return this.call<AiConversationDeleteResult>(command.deleteAiConversation, { conversationId }); }
  planAiChat(request: PlanAiChatRequest) { return this.call<AiChatPlan>(command.planAiChat, request); }
  executeAiChat(request: ExecuteAiChatRequest) { return this.call<AiChatExecutionResult>(command.executeAiChat, request); }
  startAiChatStream(request: ExecuteAiChatRequest) { return this.call<AiChatStreamSnapshot>(command.startAiChatStream, request); }
  pollAiChatStream(operationId: string, afterCursor: number) { return this.call<AiChatStreamSnapshot>(command.pollAiChatStream, { operationId, afterCursor }); }
  cancelAiChatStream(operationId: string) { return this.call<AiChatStreamSnapshot>(command.cancelAiChatStream, { operationId }); }
  getAiChatVaultStatus() { return this.call<AiChatVaultStatus>(command.aiChatVaultStatus); }
  initializeAiChatVault(passphrase: string) { return this.call<AiChatVaultStatus>(command.initializeAiChatVault, { passphrase }); }
  unlockAiChatVault(passphrase: string) { return this.call<AiChatVaultStatus>(command.unlockAiChatVault, { passphrase }); }
  lockAiChatVault() { return this.call<AiChatVaultStatus>(command.lockAiChatVault); }
  deleteAiChatVault() { return this.call<AiChatVaultStatus>(command.deleteAiChatVault); }
  listAiProviderProfiles() { return this.call<AiProviderProfile[]>(command.listAiProviderProfiles); }
  saveAiProviderProfile(request: SaveAiProviderProfileRequest) { return this.call<AiProviderProfile>(command.saveAiProviderProfile, request); }
  deleteAiProviderProfile(profileId: string) { return this.call<AiProviderProfileDeleteResult>(command.deleteAiProviderProfile, { profileId }); }
  planTextTranslation(request: PlanTextTranslationRequest) { return this.call<TextTranslationPlan>(command.planTextTranslation, request); }
  executeTextTranslation(request: ExecuteTextTranslationRequest) { return this.call<TextTranslationResult>(command.executeTextTranslation, request); }
  planStructuredTextTranslation(request: PlanStructuredTextTranslationRequest) { return this.call<StructuredTextTranslationPlan>(command.planStructuredTextTranslation, request); }
  executeStructuredTextTranslation(request: ExecuteStructuredTextTranslationRequest) { return this.call<StructuredTextTranslationResult>(command.executeStructuredTextTranslation, request); }
  semanticIndexStatus(sessionId: string) { return this.call<SemanticIndexStatus>(command.semanticIndexStatus, { sessionId }); }
  rebuildSemanticIndex(sessionId: string) { return this.call<SemanticIndexStatus>(command.rebuildSemanticIndex, { sessionId }); }
  semanticSearch(sessionId: string, query: string, limit = 20) { return this.call<SemanticSearchSnapshot>(command.semanticSearch, { sessionId, query, limit }); }
  documentCapabilities() { return this.call<DocumentCapabilities>(command.documentCapabilities); }
  selectPdf(path: string) { return this.call<PdfSelection>(command.selectPdf, { path }); }
  extractPdfText(token: string) { return this.call<PdfTextExtraction>(command.extractPdfText, { token }); }
  extractPdfOcr(token: string, language: PdfOcrLanguage) { return this.call<PdfOcrExtraction>(command.extractPdfOcr, { token, language }); }
  knowledgeLibraryStatus() { return this.call<KnowledgeLibraryStatus>(knowledgeCommand.status); }
  listKnowledgeFolders() { return this.call<KnowledgeFolderSnapshot>(knowledgeCommand.folders); }
  createKnowledgeFolder(name: string) { return this.call<KnowledgeFolder>(knowledgeCommand.createFolder, { name }); }
  moveKnowledgeItem(itemId: string, folderId: string | null) { return this.call<KnowledgeItemSummary>(knowledgeCommand.move, { itemId, folderId }); }
  listKnowledgeRevisions(itemId: string) { return this.call<KnowledgeRevisionSnapshot>(knowledgeCommand.revisions, { itemId }); }
  getKnowledgeRevision(itemId: string, revisionNumber: number) { return this.call<KnowledgeRevision>(knowledgeCommand.revision, { itemId, revisionNumber }); }
  takeKnowledgeOpenRequest() { return this.call<string | null>(knowledgeCommand.openRequest); }
  listKnowledgeItems(limit = 100) { return this.call<KnowledgeItemSnapshot>(knowledgeCommand.list, { limit }); }
  getKnowledgeItem(itemId: string) { return this.call<KnowledgeItem>(knowledgeCommand.get, { itemId }); }
  importKnowledgeText(request: KnowledgeImportRequest) { return this.call<KnowledgeImportResult>(knowledgeCommand.import, { request }); }
  setKnowledgeRemoteAiPermission(request: SetKnowledgeRemoteAiPermissionRequest) { return this.call<KnowledgeItemSummary>(knowledgeCommand.setRemoteAiPermission, request); }
  searchKnowledgeItems(query: string, limit = 20) { return this.call<KnowledgeSearchSnapshot>(knowledgeCommand.search, { query, limit }); }
  updateKnowledgeProgress(request: KnowledgeProgressRequest) { return this.call<KnowledgeItemSummary>(knowledgeCommand.progress, request); }
  deleteKnowledgeItem(itemId: string) { return this.call<KnowledgeLibraryStatus>(knowledgeCommand.remove, { itemId }); }
  planKnowledgeExport(request: KnowledgeExportRequest) { return this.call<KnowledgeExportPlan>(knowledgeCommand.plan, { request }); }
  executeKnowledgeExport(sessionId: string, planId: string) { return this.call<KnowledgeExportResult>(knowledgeCommand.execute, { request: { sessionId, planId } }); }
  planKnowledgeArchiveExport(request: KnowledgeArchiveExportRequest) { return this.call<KnowledgeArchiveExportPlan>(knowledgeCommand.archivePlan, { request }); }
  executeKnowledgeArchiveExport(request: { sessionId: string; planId: string }) { return this.call<KnowledgeArchiveExportResult>(knowledgeCommand.archiveExecute, { request }); }
  browserCaptureStatus() { return this.call<BrowserCaptureStatus>(knowledgeCommand.browser); }
  rotateBrowserCaptureToken() { return this.call<BrowserCaptureStatus>(knowledgeCommand.rotate); }
}
class BrowserDemoRepositoryGateway implements RepositoryGateway {
  async inspectKnowledgeRestoreHistoryExport(): Promise<KnowledgeRestoreHistoryExportStatus> { throw { code: "read_only_demo", message: "浏览器演示无法检查恢复历史导出。" }; }
  async selectKnowledgeRestoreHistoryExportDestination(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择恢复历史导出路径。" }; }
  async planKnowledgeRestoreHistoryExport(): Promise<KnowledgeRestoreHistoryExportPlan> { throw { code: "read_only_demo", message: "浏览器演示无法准备恢复历史导出。" }; }
  async executeKnowledgeRestoreHistoryExport(): Promise<KnowledgeRestoreHistoryExportReceipt> { throw { code: "read_only_demo", message: "浏览器演示无法导出恢复历史。" }; }
  async discardKnowledgeRestoreHistoryExport(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法操作恢复历史导出计划。" }; }
  async inspectKnowledgeRestoreCleanup(): Promise<KnowledgeRestoreCleanupStatus> { throw { code: "read_only_demo", message: "浏览器演示无法检查恢复历史清理。" }; }
  async planKnowledgeRestoreCleanup(): Promise<KnowledgeRestoreCleanupPlan> { throw { code: "read_only_demo", message: "浏览器演示无法准备恢复历史清理。" }; }
  async executeKnowledgeRestoreCleanup(): Promise<KnowledgeRestoreCleanupReceipt> { throw { code: "read_only_demo", message: "浏览器演示无法执行恢复历史删除。" }; }
  async discardKnowledgeRestoreCleanup(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法操作恢复历史清理计划。" }; }
  async inspectKnowledgeRestoreArchive(): Promise<KnowledgeRestoreArchiveStatus> { throw { code: "read_only_demo", message: "浏览器演示无法检查恢复归档。" }; }
  async planKnowledgeRestoreArchive(): Promise<KnowledgeRestoreArchivePlan> { throw { code: "read_only_demo", message: "浏览器演示无法规划恢复归档。" }; }
  async executeKnowledgeRestoreArchive(): Promise<KnowledgeRestoreArchiveReceipt> { throw { code: "read_only_demo", message: "浏览器演示无法执行恢复归档。" }; }
  async discardKnowledgeRestoreArchive(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法操作恢复归档计划。" }; }
  async planKnowledgeRestoreInstall(): Promise<KnowledgeRestoreInstallPlan> { throw { code: "read_only_demo", message: "浏览器演示无法安装资料库。" }; }
  async executeKnowledgeRestoreInstall(): Promise<KnowledgeRestoreReceipt> { throw { code: "read_only_demo", message: "浏览器演示无法安装资料库。" }; }
  async inspectKnowledgeRestore(): Promise<KnowledgeRestoreDiagnosis> { throw { code: "read_only_demo", message: "浏览器演示无法诊断磁盘恢复事务。" }; }
  async planKnowledgeRestoreRecovery(): Promise<KnowledgeRestoreRecoveryPlan> { throw { code: "read_only_demo", message: "浏览器演示无法准备恢复操作。" }; }
  async executeKnowledgeRestoreRecovery(): Promise<KnowledgeRestoreReceipt> { throw { code: "read_only_demo", message: "浏览器演示无法执行恢复操作。" }; }
  async discardKnowledgeRestoreInstall(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法操作恢复计划。" }; }
  async planKnowledgeMergeProjection(): Promise<KnowledgeMergeProjectionPlan> { throw { code: "read_only_demo", message: "浏览器演示无法校验合并清单投影。" }; }
  async preflightKnowledgeMergeProjection(): Promise<KnowledgeMergeProjectionReceipt> { throw { code: "read_only_demo", message: "浏览器演示无法确认内存复验。" }; }
  async discardKnowledgeMergeProjection(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法取消合并投影。" }; }
  async planKnowledgeRestoreQualification(): Promise<KnowledgeRestoreQualificationPlan> { throw { code: "read_only_demo", message: "浏览器演示无法核验恢复资格。" }; }
  async recheckKnowledgeRestoreQualification(): Promise<KnowledgeRestoreQualificationRecheck> { throw { code: "read_only_demo", message: "浏览器演示无法复验恢复资格。" }; }
  async discardKnowledgeRestoreQualification(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法取消恢复资格计划。" }; }
  async selectKnowledgeCandidateDirectory(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择资料候选目录。" }; }
  async inspectKnowledgeCandidate(): Promise<KnowledgeCandidateCheckReport> { throw { code: "read_only_demo", message: "浏览器演示无法独立核验资料候选。" }; }
  async recheckKnowledgeCandidate(): Promise<KnowledgeCandidateRecheck> { throw { code: "read_only_demo", message: "浏览器演示无法重新核对资料候选。" }; }
  async discardKnowledgeCandidateCheck(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法取消资料候选报告。" }; }

  async selectKnowledgePackageStageSource(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择待暂存资料包。" }; }
  async selectKnowledgePackageStageParent(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择资料暂存目录。" }; }
  async planKnowledgePackageStage(): Promise<KnowledgePackageStagePlan> { throw { code: "read_only_demo", message: "浏览器演示无法准备磁盘暂存。" }; }
  async executeKnowledgePackageStage(): Promise<KnowledgePackageStageResult> { throw { code: "read_only_demo", message: "浏览器演示无法执行磁盘暂存。" }; }
  async discardKnowledgePackageStage(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法丢弃磁盘暂存计划。" }; }
  async selectKnowledgePackageSource(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择本地资料包。" }; }
  async inspectKnowledgePackage(): Promise<KnowledgePackageCheckReport> { throw { code: "read_only_demo", message: "浏览器演示无法检查本地资料包。" }; }
  async preflightKnowledgePackage(): Promise<KnowledgePackageMemoryPreflight> { throw { code: "read_only_demo", message: "浏览器演示无法预检本地资料包。" }; }
  async discardKnowledgePackageCheck(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法丢弃资料包检查报告。" }; }
  async selectKnowledgeBackupDestination(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择资料备份包路径。" }; }
  async planKnowledgeBackup(): Promise<KnowledgeBackupPlan> { throw { code: "read_only_demo", message: "浏览器演示无法预览资料备份包。" }; }
  async executeKnowledgeBackup(): Promise<KnowledgeBackupResult> { throw { code: "read_only_demo", message: "浏览器演示无法导出资料备份包。" }; }
  async discardKnowledgeBackup(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法丢弃资料备份计划。" }; }
  async inspectKnowledgeIntegrity(): Promise<KnowledgeIntegrityReport> { throw { code: "read_only_demo", message: "浏览器演示无法读取资料引用。" }; }
  async recheckKnowledgeIntegrity(): Promise<KnowledgeIntegrityRecheck> { throw { code: "read_only_demo", message: "浏览器演示无法重新核对资料引用。" }; }
  async discardKnowledgeIntegrity(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法丢弃资料预检报告。" }; }
  async inspectWorkspaceBackup(): Promise<WorkspaceBackupReport> { throw { code: "read_only_demo", message: "浏览器演示无法检查私有工作区备份范围。" }; }
  async selectDraftSnapshotBackupDestination(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择草稿快照位置。" }; }
  async planDraftSnapshotBackup(): Promise<DraftSnapshotBackupPlan> { throw { code: "read_only_demo", message: "浏览器演示无法读取草稿数据库。" }; }
  async executeDraftSnapshotBackup(): Promise<DraftSnapshotBackupResult> { throw { code: "read_only_demo", message: "浏览器演示无法导出草稿快照。" }; }
  async discardDraftSnapshotBackup(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法丢弃草稿快照计划。" }; }
  async selectRssSnapshotBackupDestination(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择 RSS 快照位置。" }; }
  async planRssSnapshotBackup(): Promise<RssSnapshotBackupPlan> { throw { code: "read_only_demo", message: "浏览器演示无法读取 RSS 数据库。" }; }
  async executeRssSnapshotBackup(): Promise<RssSnapshotBackupResult> { throw { code: "read_only_demo", message: "浏览器演示无法导出 RSS 快照。" }; }
  async discardRssSnapshotBackup(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示无法丢弃 RSS 快照计划。" }; }
  async selectWorkspaceConfigBackupDestination(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法选择私有配置备份位置。" }; }
  async planWorkspaceConfigBackup(): Promise<WorkspaceConfigBackupPlan> { throw { code: "read_only_demo", message: "浏览器演示无法读取已保存的私有配置。" }; }
  async executeWorkspaceConfigBackup(): Promise<WorkspaceConfigBackupResult> { throw { code: "read_only_demo", message: "浏览器演示不能导出配置备份。" }; }
  async discardWorkspaceConfigBackup(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示没有配置备份计划。" }; }
  async recheckWorkspaceBackup(): Promise<WorkspaceBackupRecheck> { throw { code: "read_only_demo", message: "浏览器演示无法重新核对私有清单。" }; }
  async discardWorkspaceBackup(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示没有私有备份清单。" }; }

  async selectRollbackArchiveDestination(): Promise<string | null> { throw { code: "read_only_demo", message: "浏览器演示无法导出恢复证据。" }; }
  async planRollbackArchive(): Promise<RollbackArchivePlan> { throw { code: "read_only_demo", message: "浏览器演示无法准备恢复证据归档。" }; }
  async executeRollbackArchive(): Promise<RollbackArchiveResult> { throw { code: "read_only_demo", message: "浏览器演示无法导出恢复证据。" }; }
  async discardRollbackArchive(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示没有恢复证据归档计划。" }; }

  async planRollbackTransaction(): Promise<RollbackTransactionPlan> { throw { code: "read_only_demo", message: "浏览器演示无法准备远端回滚。" }; }
  async executeRollbackTransaction(): Promise<RollbackRecord> { throw { code: "read_only_demo", message: "浏览器演示无法执行远端回滚。" }; }
  async discardRollbackTransaction(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示没有远端回滚计划。" }; }
  async listRollbackRecords(): Promise<RollbackRecord[]> { throw { code: "read_only_demo", message: "浏览器演示无法读取回滚证据。" }; }
  async verifyRollbackRecord(): Promise<RollbackRecord> { throw { code: "read_only_demo", message: "浏览器演示无法核实远端回滚。" }; }
  async planRollbackCandidate(): Promise<RollbackCandidatePlan> { throw { code: "read_only_demo", message: "浏览器演示无法准备逆向候选。" }; }
  async generateRollbackCandidate(): Promise<RollbackCandidateReport> { throw { code: "read_only_demo", message: "浏览器演示无法生成逆向候选。" }; }
  async discardRollbackCandidate(): Promise<void> { throw { code: "read_only_demo", message: "浏览器演示没有逆向候选计划。" }; }
  async inspectRollbackChanges(): Promise<RollbackChangePreview> { throw { code: "read_only_demo", message: "浏览器演示无法预览逆向变更。" }; }
  async planRollbackQualification(): Promise<RollbackQualificationPlan> { throw { code: "read_only_demo", message: "浏览器演示无法审阅回滚条件。" }; }
  async checkRollbackQualification(): Promise<RollbackQualificationReport> { throw { code: "read_only_demo", message: "浏览器演示无法查询回滚条件。" }; }
  async removePublishRecord(): Promise<PublishRecord[]> { throw { code: "read_only_demo", message: "浏览器演示无法清理发布记录。" }; }
  async listPublishRecords(): Promise<PublishRecord[]> { return []; }
  async getReleaseLedger(sessionId: string): Promise<ReleaseLedgerSnapshot> {
    return { sessionId, entries: [], partialSources: ["gitPush", "remoteReview", "rollback"], warnings: ["浏览器演示不读取本地发布台账。"],
      summary: { total: 0, verifiedPushes: 0, verifiedReviews: 0, needsAttention: 0, rollbackTransactions: 0, historicalCandidateObservations: 0, unresolvedRollbackTransactions: 0 },
      rollbackDiagnostics: { status: "unavailable", capacity: "unavailable", globalRecords: null, payloadBytes: null, remainingPayloadBytes: null,
        localRecords: null, localUnresolved: null, maxRecords: 200, maxPayloadBytes: 4194304, maxRecordBytes: 65536,
        reservedObservationBytes: 51200, scopePartial: true, blockedTargets: [], checkedAtEpochMs: Date.now() } };
  }
  async planPublishVerification(): Promise<PublishVerificationPlan> { throw { code: "read_only_demo", message: "浏览器演示无法核实远端发布结果。" }; }
  async executePublishVerification(): Promise<PublishRecord> { throw { code: "read_only_demo", message: "浏览器演示无法核实远端发布结果。" }; }
  async planAiConnection(): Promise<AiConnectionPlan> { throw demoError("检查 AI 连接"); }
  async executeAiConnection(): Promise<AiConnectionResult> { throw demoError("请求 AI 服务"); }
  async planGitPushRetry(): Promise<import("../contracts/gitPushRetry").GitPushRetryPlan> { throw demoError("检查待重试推送"); }
  async executeGitPushRetry(): Promise<import("../contracts/gitPushRetry").GitPushRetryResult> { throw demoError("重试推送已有提交"); }
  async planMetadataBatch(): Promise<MetadataBatchPlan> { throw demoError("预览批量标签与分类维护"); }
  async executeMetadataBatch(): Promise<MetadataBatchResult> { throw demoError("执行批量标签与分类维护"); }
  async getSiteProfiles(): Promise<SiteProfileSnapshot> { throw demoError("查看已保存站点"); }
  async registerSiteProfile(): Promise<SiteProfileSnapshot> { throw demoError("登记站点"); }
  async renameSiteProfile(): Promise<SiteProfileSnapshot> { throw demoError("重命名站点"); }
  async removeSiteProfile(): Promise<SiteProfileSnapshot> { throw demoError("移除站点登记"); }
  async openSiteProfile(): Promise<RepositorySessionSnapshot> { throw demoError("切换已保存站点"); }
  private workspaceState: WorkspaceStateSnapshot = defaultWorkspaceState();
  async getOperationLog(): Promise<OperationLogSnapshot> { throw demoError("查看操作日志"); }
  async clearOperationLog(): Promise<OperationLogSnapshot> { throw demoError("清空操作日志"); }
  async getCapabilities(): Promise<CapabilitySnapshot> { return { metadataBatch: false, localEdit: false, markdownPreview: true, gitStatus: false, siteRuntime: false, gitCommit: false, gitPush: false, gitFetch: false, gitIndex: false, remoteAuth: false, aiEditing: false, semanticSearch: false, pdfTextExtraction: false, ocrReadiness: false, knowledgeLibrary: false, contentHealth: false, imageWorkbench: false, operationLog: false, siteProfiles: false }; }
  async getWorkspaceState(): Promise<WorkspaceStateSnapshot> { return this.workspaceState; }
  async updateWorkspacePreferences(preferences: WorkspacePreferences): Promise<WorkspaceStateSnapshot> { this.workspaceState = { ...this.workspaceState, preferences }; return this.workspaceState; }
  async saveRecoveryDraft(_: SaveRecoveryDraftRequest): Promise<WorkspaceStateSnapshot> { throw demoError("保存崩溃恢复草稿"); }
  async clearRecoveryDraft(_: string): Promise<WorkspaceStateSnapshot> { throw demoError("清除崩溃恢复草稿"); }
  async openRepository(_: string): Promise<RepositorySessionSnapshot> { return { sessionId: "demo-session", rootPath: "/演示/RepoPress", displayName: "RepoPress 演示仓库", siteKind: "演示", contentRoot: "content", isGitRepository: false, warnings: ["浏览器演示不访问本地磁盘。"] }; }
  async listMarkdownFiles(): Promise<MarkdownFileEntry[]> { return [{ relativePath: "content/欢迎.md", displayName: "欢迎.md", directory: "content", byteSize: 240 }, { relativePath: "content/编辑说明.md", displayName: "编辑说明.md", directory: "content", byteSize: 180 }]; }
  async inspectRepositoryImages(): Promise<RepositoryImageSnapshot> { throw demoError("扫描仓库图片"); }
  async readRepositoryImage(): Promise<RepositoryImagePreview> { throw demoError("预览仓库图片"); }
  async inspectContentHealthSources(): Promise<ContentHealthSourceSnapshot> { throw demoError("扫描本地仓库内容健康"); }
  async openDocument(_: string, relativePath: string): Promise<DocumentSnapshot> { return { documentId: "demo-document", relativePath, text: "# RepoPress 桌面版\n\n这是**只读浏览器演示**。请在 Tauri 桌面应用中选择真实仓库后编辑。\n\n- 支持中文和 Emoji ✨\n- 预览会移除脚本、事件和外部资源\n- 此处不是站点构建结果\n\n[文档链接](https://example.com)", encoding: "utf-8", lineEnding: "lf", byteSize: 240, baselineSha256: "demo-read-only", revision: 1, writable: false, readOnlyReason: "浏览器演示不会写入文件。" }; }
  async inspectMarkdownLinkMetadata(_: string, relativePath: string): Promise<MarkdownLinkMetadata> { return { relativePath, title: null, slug: null, permalink: null }; }
  async saveDocument(): Promise<SaveDocumentResult> { throw { code: "read_only_demo", message: "浏览器演示不会写入文件。请在桌面应用中保存。" }; }
  async createMarkdownDocument(): Promise<DocumentSnapshot> { throw demoError("新建 Markdown 文档"); }
  async renameMarkdownDocument(): Promise<DocumentSnapshot> { throw demoError("重命名 Markdown 文档"); }
  async deleteMarkdownDocument(): Promise<DeleteMarkdownDocumentResult> { throw demoError("删除 Markdown 文档"); }
  async listDraftVersions(): Promise<DraftVersionSnapshot> { return { documentId: "demo-document", relativePath: "", versions: [] }; }
  async getDraftVersion(): Promise<DraftVersion> { throw demoError("读取草稿版本"); }
  async restoreDraftVersion(): Promise<DocumentSnapshot> { throw demoError("恢复草稿版本"); }
  async listRecycledDrafts(): Promise<RecycledDraftSnapshot> { return { entries: [], total: 0, truncated: false }; }
  async getRecycledDraft(): Promise<RecycledDraft> { throw demoError("读取回收站草稿"); }
  async restoreRecycledDraft(): Promise<DocumentSnapshot> { throw demoError("恢复回收站草稿"); }
  async deleteRecycledDraft(): Promise<RecycledDraftSnapshot> { throw demoError("删除回收站草稿"); }
  async listGeneralDrafts(): Promise<GeneralDraftSnapshot> { return { entries: [], total: 0, truncated: false }; }
  async getGeneralDraft(): Promise<GeneralDraft> { throw demoError("读取通用草稿"); }
  async saveGeneralDraft(): Promise<GeneralDraft> { throw demoError("保存通用草稿"); }
  async planGeneralDraftTransfer(): Promise<GeneralDraftTransferPlan> { throw demoError("生成通用草稿转移计划"); }
  async executeGeneralDraftTransfer(): Promise<GeneralDraftTransferResult> { throw demoError("执行通用草稿转移"); }
  async undoGeneralDraftTransfer(): Promise<UndoGeneralDraftTransferResult> { throw demoError("撤销通用草稿转移"); }
  async importWritingImage(): Promise<WritingImageImportResult> { throw demoError("导入本地图片"); }
  async gitStatus(): Promise<GitStatusSnapshot> { return { available: false, branch: null, upstream: null, ahead: 0, behind: 0, detached: false, changedFiles: [], warnings: ["演示模式未读取 Git。"] }; }
  async searchMarkdownFiles(_: string, query: string): Promise<MarkdownSearchSnapshot> {
    const files = await this.listMarkdownFiles(); const normalized = query.trim().toLocaleLowerCase();
    return { query, truncated: false, results: normalized ? files.filter((file) => file.relativePath.toLocaleLowerCase().includes(normalized)).map((file) => ({ ...file, matchKind: "path" as const, lineNumber: null, snippet: "浏览器演示仅按路径检索，不读取真实文件内容。" })) : [] };
  }
  async gitFileDiff(_: string, relativePath: string): Promise<GitDiffSnapshot> { return { relativePath, stagedPatch: "", workingTreePatch: "", binary: false, truncated: false, warnings: ["浏览器演示不读取 Git diff。"] }; }
  async inspectSitePreview(): Promise<SitePreviewReadiness> { return { siteKind: "演示", supported: false, runtimeAvailable: false, executable: null, version: null, reason: "浏览器演示不会检查或启动本机站点构建器。", warning: null }; }
  async planSitePreview(): Promise<SitePreviewPlan> { throw { code: "read_only_demo", message: "浏览器演示不会启动站点构建器。" }; }
  async checkSitePreviewPage(): Promise<SitePreviewPageSnapshot> { throw { code: "read_only_demo", message: "浏览器演示不会验证本机页面。" }; }
  async startSitePreview(): Promise<SitePreviewSnapshot> { throw { code: "read_only_demo", message: "浏览器演示不会启动站点构建器。" }; }
  async stopSitePreview(): Promise<SitePreviewSnapshot> { return { previewId: null, running: false, url: null, siteKind: "演示", message: "浏览器演示没有运行中的站点。" }; }
  async credentialStatus(): Promise<CredentialStatusSnapshot> { return { storage: "unavailable", secretServiceAvailable: false, credentials: [], warning: "浏览器演示不读取或保存凭据。" }; }
  async storeRepositoryCredential(): Promise<CredentialStatusSnapshot> { throw demoError("保存凭据"); }
  async deleteRepositoryCredential(): Promise<CredentialStatusSnapshot> { throw demoError("删除凭据"); }
  async planGitOperation(): Promise<GitOperationPlan> { throw demoError("生成 Git 发布计划"); }
  async executeGitOperation(): Promise<GitOperationResult> { throw demoError("执行 Git 发布操作"); }
  async planGitIndexUpdate(): Promise<GitIndexUpdatePlan> { throw demoError("生成 Git 暂存计划"); }
  async executeGitIndexUpdate(): Promise<GitIndexUpdateResult> { throw demoError("执行 Git 暂存计划"); }
  async listRemoteReviewRecords(): Promise<RemoteReviewRecord[]> { return []; }
  async planRemoteReviewVerification(): Promise<RemoteReviewVerificationPlan> { throw demoError("生成 PR/MR 核实计划"); }
  async executeRemoteReviewVerification(): Promise<RemoteReviewRecord> { throw demoError("核实 PR/MR 结果"); }
  async removeRemoteReviewRecord(): Promise<RemoteReviewRecord[]> { throw demoError("删除 PR/MR 本地记录"); }
  async planRemoteReview(): Promise<RemoteReviewPlan> { throw demoError("生成 PR/MR 计划"); }
  async executeRemoteReview(): Promise<RemoteReviewResult> { throw demoError("创建 PR/MR"); }
  async checkDeployment(): Promise<DeploymentCheckSnapshot> { return { configured: false, provider: null, status: "unavailable", url: null, summary: "浏览器演示未配置部署检查。", checkedAt: null, warning: "演示模式不会访问远端。" }; }
  async browserProtocolStatus(): Promise<ReadinessSnapshot> { return { configured: false, ready: false, summary: "浏览器协议未配置", warning: "浏览器演示仅展示状态。" }; }
  async updateReadiness(): Promise<ReadinessSnapshot> { return { configured: false, ready: false, summary: "更新器未配置", warning: "浏览器演示仅展示状态。" }; }
  async checkAppUpdate(): Promise<AppUpdateCheck> { throw demoError("检查 AppImage 更新"); }
  async installAppUpdate(): Promise<AppUpdateInstallResult> { throw demoError("安装 AppImage 更新"); }
  async aiCredentialStatus(): Promise<AiCredentialStatusSnapshot> { return { configured: false, storage: "unavailable", sessionOnly: true, secretServiceAvailable: false, warning: "浏览器演示不读取 AI 凭据。" }; }
  async storeAiCredential(): Promise<AiCredentialStatusSnapshot> { throw demoError("保存 AI 凭据"); }
  async deleteAiCredential(): Promise<AiCredentialStatusSnapshot> { throw demoError("删除 AI 凭据"); }
  async planAiEdit(): Promise<AiEditPlan> { throw demoError("生成 AI 编辑计划"); }
  async executeAiEdit(): Promise<AiEditResponse> { throw demoError("执行 AI 编辑"); }
  async applyAiEdits(): Promise<AiAppliedEdit> { throw demoError("应用 AI 编辑"); }
  async listAiConversations(): Promise<AiConversation[]> { return []; }
  async createAiConversation(): Promise<AiConversation> { throw demoError("创建 AI 对话"); }
  async deleteAiConversation(): Promise<AiConversationDeleteResult> { throw demoError("删除 AI 对话"); }
  async planAiChat(): Promise<AiChatPlan> { throw demoError("生成 AI 对话发送计划"); }
  async executeAiChat(): Promise<AiChatExecutionResult> { throw demoError("发送 AI 对话"); }
  async startAiChatStream(): Promise<AiChatStreamSnapshot> { throw demoError("开始 AI 流式对话"); }
  async pollAiChatStream(): Promise<AiChatStreamSnapshot> { throw demoError("读取 AI 流式对话"); }
  async cancelAiChatStream(): Promise<AiChatStreamSnapshot> { throw demoError("停止 AI 流式对话"); }
  async getAiChatVaultStatus(): Promise<AiChatVaultStatus> { throw demoError("读取加密对话状态"); }
  async initializeAiChatVault(): Promise<AiChatVaultStatus> { throw demoError("创建加密对话库"); }
  async unlockAiChatVault(): Promise<AiChatVaultStatus> { throw demoError("解锁加密对话库"); }
  async lockAiChatVault(): Promise<AiChatVaultStatus> { throw demoError("锁定加密对话库"); }
  async deleteAiChatVault(): Promise<AiChatVaultStatus> { throw demoError("删除加密对话库"); }
  async listAiProviderProfiles(): Promise<AiProviderProfile[]> { throw demoError("读取 AI 服务档案"); }
  async saveAiProviderProfile(): Promise<AiProviderProfile> { throw demoError("保存 AI 服务档案"); }
  async deleteAiProviderProfile(): Promise<AiProviderProfileDeleteResult> { throw demoError("删除 AI 服务档案"); }
  async planTextTranslation(): Promise<TextTranslationPlan> { throw demoError("生成文本翻译计划"); }
  async executeTextTranslation(): Promise<TextTranslationResult> { throw demoError("执行文本翻译"); }
  async planStructuredTextTranslation(): Promise<StructuredTextTranslationPlan> { throw demoError("生成结构化翻译计划"); }
  async executeStructuredTextTranslation(): Promise<StructuredTextTranslationResult> { throw demoError("执行结构化翻译"); }
  async semanticIndexStatus(): Promise<SemanticIndexStatus> { return { ready: false, sessionOnly: true, modelId: "browser-demo", encodingVersion: 0, indexedFiles: 0, indexedChunks: 0, indexedBytes: 0, reusedChunks: 0, summary: "浏览器演示不读取本地仓库。" }; }
  async rebuildSemanticIndex(): Promise<SemanticIndexStatus> { throw demoError("建立语义索引"); }
  async semanticSearch(): Promise<SemanticSearchSnapshot> { throw demoError("执行语义检索"); }
  async documentCapabilities(): Promise<DocumentCapabilities> { return { pdfTextReady: false, sandbox: unavailableTool(), pdftotext: unavailableTool(), ocr: { ready: false, enabled: false, tesseract: unavailableTool(), pdftoppm: unavailableTool(), englishData: unavailableTool(), chineseSimplifiedData: unavailableTool(), pdfInfo: unavailableTool(), warning: "浏览器演示不检查本机 OCR。" }, warnings: ["浏览器演示不运行文档工具。"] }; }
  async selectPdf(): Promise<PdfSelection> { throw demoError("选择 PDF"); }
  async extractPdfText(): Promise<PdfTextExtraction> { throw demoError("提取 PDF 文本"); }
  async extractPdfOcr(): Promise<PdfOcrExtraction> { throw demoError("执行 PDF 本地 OCR"); }
  async knowledgeLibraryStatus(): Promise<KnowledgeLibraryStatus> { return { ready: false, persistent: false, itemCount: 0, totalBytes: 0, summary: "浏览器演示未启用资料库。", warning: "演示模式不访问磁盘。" }; }
  async listKnowledgeFolders(): Promise<KnowledgeFolderSnapshot> { return { folders: [], total: 0 }; }
  async createKnowledgeFolder(): Promise<KnowledgeFolder> { throw demoError("创建资料分类"); }
  async moveKnowledgeItem(): Promise<KnowledgeItemSummary> { throw demoError("移动资料分类"); }
  async listKnowledgeRevisions(itemId: string): Promise<KnowledgeRevisionSnapshot> { return { itemId, revisions: [] }; }
  async getKnowledgeRevision(): Promise<KnowledgeRevision> { throw demoError("读取资料历史版本"); }
  async takeKnowledgeOpenRequest(): Promise<string | null> { return null; }
  async listKnowledgeItems(): Promise<KnowledgeItemSnapshot> { return { items: [], total: 0, truncated: false }; }
  async getKnowledgeItem(): Promise<KnowledgeItem> { throw demoError("读取资料"); }
  async importKnowledgeText(): Promise<KnowledgeImportResult> { throw demoError("导入资料库"); }
  async setKnowledgeRemoteAiPermission(): Promise<KnowledgeItemSummary> { throw demoError("更新资料的远程 AI 授权"); }
  async searchKnowledgeItems(query: string): Promise<KnowledgeSearchSnapshot> { return { query, modelId: "browser-demo", encodingVersion: 0, results: [], truncated: false }; }
  async updateKnowledgeProgress(): Promise<KnowledgeItemSummary> { throw demoError("保存阅读进度"); }
  async deleteKnowledgeItem(): Promise<KnowledgeLibraryStatus> { throw demoError("删除资料"); }
  async planKnowledgeExport(): Promise<KnowledgeExportPlan> { throw demoError("生成资料导出计划"); }
  async executeKnowledgeExport(): Promise<KnowledgeExportResult> { throw demoError("执行资料导出"); }
  async planKnowledgeArchiveExport(): Promise<KnowledgeArchiveExportPlan> { throw demoError("生成离线归档导出计划"); }
  async executeKnowledgeArchiveExport(): Promise<KnowledgeArchiveExportResult> { throw demoError("执行离线归档导出"); }
  async browserCaptureStatus(): Promise<BrowserCaptureStatus> { return { running: false, endpoint: null, connectionToken: null, tokenExpiresAt: null, allowedOrigins: [], maximumInputBytes: 0, summary: "浏览器演示未启用扩展配对。", warning: "演示模式不访问本机服务。" }; }
  async rotateBrowserCaptureToken(): Promise<BrowserCaptureStatus> { throw demoError("轮换浏览器令牌"); }
}
function isTauriRuntime(): boolean { return "__TAURI_INTERNALS__" in window; }
function demoError(action: string) { return { code: "read_only_demo", message: `浏览器演示不会${action}。请在桌面应用中继续。` }; }
function unavailableTool() { return { available: false, path: null, reason: "browser_demo" }; }
function defaultWorkspaceState(): WorkspaceStateSnapshot {
  return { schemaVersion: 1, preferences: { theme: "system", editorFontSize: 15, editorLineSpacing: 4, editorBodyWidth: 820, spellCheckEnabled: false, typewriterModeEnabled: false, currentParagraphHighlightEnabled: true, warmPaperBackgroundEnabled: false, automaticPairingEnabled: true, paragraphSpotlightEnabled: false, writingToolDensity: "basic", writingToolbarItemIds: ["bold", "italic", "strike", "code", "link", "heading", "quote", "unorderedList", "orderedList", "taskList", "codeBlock", "horizontalRule"], restoreLastWorkspace: true, recoveryEnabled: true }, recentRepositories: [], lastRepositoryPath: null, lastDocumentPath: null, recoveryDraft: null, warning: "浏览器演示只在内存中保留设置，不访问本地磁盘。" };
}
