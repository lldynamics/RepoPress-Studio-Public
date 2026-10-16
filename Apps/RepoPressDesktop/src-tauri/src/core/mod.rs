pub(crate) use knowledge_candidate_check::normal_library_access;
pub use knowledge_candidate_check::{
    KnowledgeRestoreArchiveAction, KnowledgeRestoreArchivePlan, KnowledgeRestoreArchiveReceipt,
    KnowledgeRestoreArchiveStatus, KnowledgeRestoreArchiveStore, KnowledgeRestoreCleanupAction,
    KnowledgeRestoreCleanupPlan, KnowledgeRestoreCleanupReceipt, KnowledgeRestoreCleanupStatus,
    KnowledgeRestoreCleanupStore, KnowledgeRestoreDiagnosis, KnowledgeRestoreHistoryExportPlan,
    KnowledgeRestoreHistoryExportReceipt, KnowledgeRestoreHistoryExportStatus,
    KnowledgeRestoreHistoryExportStore, KnowledgeRestoreInstallPlan, KnowledgeRestoreInstallStore,
    KnowledgeRestoreReceipt, KnowledgeRestoreRecoveryAction, KnowledgeRestoreRecoveryPlan,
};
pub(crate) mod knowledge_restore_gate;
#[cfg(test)]
mod shared_front_matter_fixture_tests;
pub use knowledge_candidate_check::{
    KnowledgeMergeProjectionPlan, KnowledgeMergeProjectionReceipt, KnowledgeMergeProjectionStore,
};
pub use knowledge_candidate_check::{
    KnowledgeRestoreQualificationPlan, KnowledgeRestoreQualificationRecheck,
    KnowledgeRestoreQualificationStore, KnowledgeRestoreStrategy,
};
mod knowledge_candidate_check;
pub use knowledge_candidate_check::{
    KnowledgeCandidateCheckReport, KnowledgeCandidateCheckStore, KnowledgeCandidateRecheck,
};
mod knowledge_package_stage;
pub use knowledge_package_stage::{
    KnowledgePackageStagePlan, KnowledgePackageStageResult, KnowledgePackageStageStore,
};
mod knowledge_package_check;
pub use knowledge_package_check::{
    KnowledgePackageCheckReport, KnowledgePackageCheckStore, KnowledgePackageMemoryPreflight,
};
mod knowledge_backup;
pub use knowledge_backup::{KnowledgeBackupPlan, KnowledgeBackupResult, KnowledgeBackupStore};
mod knowledge_integrity;
pub use knowledge_integrity::{
    KnowledgeIntegrityRecheck, KnowledgeIntegrityReport, KnowledgeIntegrityStore,
};
mod draft_snapshot_backup;
pub use draft_snapshot_backup::{
    DraftSnapshotBackupPlan, DraftSnapshotBackupResult, DraftSnapshotBackupStore,
    DraftSnapshotSource,
};
mod rss_snapshot_backup;
mod sqlite_snapshot;
pub use rss_snapshot_backup::{
    RssSnapshotBackupPlan, RssSnapshotBackupResult, RssSnapshotBackupStore,
};
mod workspace_config_backup;
pub use workspace_config_backup::{
    ConfigBackupSource, WorkspaceConfigBackupPlan, WorkspaceConfigBackupResult,
    WorkspaceConfigBackupStore,
};
mod workspace_backup;
pub use workspace_backup::{
    BackupSource, WorkspaceBackupRecheck, WorkspaceBackupReport, WorkspaceBackupStore,
};
mod rollback_archive;
pub use rollback_archive::{RollbackArchivePlan, RollbackArchiveResult, RollbackArchiveStore};
mod durable_ledger;
mod rollback_ledger;
mod rollback_transaction;
pub(crate) use git_publish::push_rollback_candidate;
pub use rollback_ledger::RollbackRecord;
pub use rollback_transaction::{RollbackTransactionPlan, RollbackTransactionStore};
mod rollback_candidate;
pub use rollback_candidate::{
    RollbackCandidatePlan, RollbackCandidateReport, RollbackCandidateStore,
};
mod rollback_change_preview;
pub use rollback_change_preview::{inspect_rollback_changes, RollbackChangePreview};
mod rollback_qualification;
pub use rollback_qualification::{
    RollbackQualificationPlan, RollbackQualificationReport, RollbackQualificationStore,
};
mod release_ledger;
pub use release_ledger::{read_release_ledger, ReleaseLedgerSnapshot};
mod remote_review_ledger;
pub use git_publish::capture_review_target;
pub use git_publish::{observe_recorded_push, validate_recorded_push_target};
pub use remote_publish::validate_review_repository;
pub use remote_review_ledger::{
    RemoteReviewEvidence, RemoteReviewLedgerStore, RemoteReviewRecord, ReviewVerification,
};
mod publish_ledger;
pub use publish_ledger::{PublishEvidence, PublishLedgerStore, PublishRecord, PushOperation};
mod editor_exit;
pub use editor_exit::{EditorExitPlan, EditorExitStore};
pub(crate) use workspace_state::RecoveryDraftSnapshot;
mod ai_chat;
mod ai_chat_vault;
mod ai_connection;
mod ai_credentials;
mod ai_edit;
mod ai_provider;
mod ai_provider_profiles;
mod browser_capture;
mod browser_protocol;
mod content_health;
mod credentials;
mod document_capabilities;
mod document_export;
mod document_runner;
mod draft_history;
mod error;
mod general_drafts;
mod git;
mod git_boundary;
mod git_index;
mod git_publish;
mod image_workbench;
mod knowledge_library;
mod metadata_batch;
mod metadata_field;
mod models;
mod ocr_extract;
mod operation_log;
mod pdf_extract;
mod remote_publish;
mod repository;
mod rss;
mod search;
mod semantic_index;
mod semantic_search;
mod site_preview;
mod site_preview_http;
mod site_preview_plan;
mod site_profiles;
mod translation;
mod update_client;
mod update_readiness;
mod workspace_state;

pub(crate) use ai_connection::AiConnectionExecution;

pub use ai_chat::{
    AiChatExecutionResult, AiChatKnowledgeInput, AiChatPlan, AiChatStore, AiChatStreamSnapshot,
    AiChatStreamState, AiConversationDeleteResult, AiConversationSnapshot, AiPersistedConversation,
};
pub use ai_chat_vault::{AiChatVault, AiChatVaultState};
pub use ai_connection::{
    AiConnectionOperation, AiConnectionPlan, AiConnectionRequest, AiConnectionResult,
    AiConnectionStore,
};
pub use ai_credentials::{
    ai_secret_service_available, AiCredential, AiCredentialScope, AiCredentialStatus,
    AiCredentialStorage, AiCredentialStore,
};
pub use ai_edit::{
    apply_accepted_proposals, AiEditResponse, AiEditStore, EditProposal, Utf16Range,
};
pub use ai_provider::{
    AiError, AiProviderConfig, AiProviderKind, ReqwestAiTransport, SharedAiTransport,
};
pub use ai_provider_profiles::{
    AiProviderProfile, AiProviderProfileDeleteResult, AiProviderProfileStore,
};
#[cfg(test)]
pub use browser_capture::BrowserCaptureArchive;
pub use browser_capture::{
    BrowserCapture, BrowserCaptureConflict, BrowserCaptureDuplicateResolution,
    BrowserCaptureFolder, BrowserCaptureService, BrowserCaptureSink, BrowserCaptureSinkReceipt,
    BrowserCaptureStatus,
};
pub use browser_protocol::BrowserProtocol;
pub use content_health::{read_content_health_sources, ContentHealthSourceSnapshot};
pub use credentials::{
    secret_service_available, CredentialScope, CredentialStorage, RepositoryCredential,
    RepositoryCredentialStore,
};
pub use document_capabilities::{inspect_document_capabilities, DocumentCapabilities};
pub use document_export::{export_document, DocumentExportResult};
pub use draft_history::{
    DraftHistoryStore, DraftVersion, DraftVersionReason, DraftVersionSnapshot, RecycledDraft,
    RecycledDraftSnapshot,
};
pub use error::{CommandError, CommandResult};
pub use general_drafts::{
    GeneralDraft, GeneralDraftSnapshot, GeneralDraftStore, GeneralDraftTransferPlan,
    GeneralDraftTransferResult, GeneralDraftTransferTarget, GeneralDraftTransferUndoResult,
    TransferOperation,
};
pub use git::{git_is_available, read_git_diff, read_git_status, GitDiffSnapshot};
pub use git_index::{GitIndexAction, GitIndexPlan, GitIndexStore, GitIndexUpdateResult};
pub use git_publish::{
    git_askpass_response_from_environment, read_publish_remote_default_branch,
    read_publish_remote_url, read_push_retry_remote_url, GitPublishOperation, GitPublishStore,
    GitPushRetryPlan, GitPushRetryResult,
};
pub use image_workbench::{
    inspect_repository_images, read_repository_image, RepositoryImagePreview,
    RepositoryImageSnapshot,
};
pub use knowledge_library::{
    BrowserKnowledgeImportOutcome, BrowserKnowledgeImportRequest, KnowledgeArchiveExportPlan,
    KnowledgeArchiveExportResult, KnowledgeExportPlan, KnowledgeExportResult, KnowledgeFolder,
    KnowledgeImportRequest, KnowledgeImportResult, KnowledgeItem, KnowledgeItemSummary,
    KnowledgeLibrarySnapshot, KnowledgeLibraryStatus, KnowledgeLibraryStore, KnowledgeRevision,
    KnowledgeRevisionSummary, KnowledgeSearchSnapshot,
};
pub use models::{
    CapabilitySnapshot, DeleteMarkdownDocumentResult, DocumentSnapshot, GitChangedFile,
    GitStatusSnapshot, LineEnding, MarkdownFileEntry, MarkdownLinkMetadata,
    RepositorySessionSnapshot, WritingImageImportResult,
};
pub use operation_log::{
    operation_repository_key, OperationKind, OperationLogSnapshot, OperationLogStore,
    OperationOutcome,
};
pub use pdf_extract::{PdfAnalysisStore, PdfOcrExtraction, PdfSelection, PdfTextExtraction};
pub use remote_publish::{
    DeploymentSnapshot, RemoteProvider, RemotePublishError, RemotePublishStore, ReviewRequestDraft,
};
pub use repository::RepositoryStore;
pub use rss::{
    RssArticle, RssArticlePage, RssArticleQuery, RssArticleState, RssBackupSummary, RssFeed,
    RssHistoryCheckpointSummary, RssHistoryDiscoverInput, RssHistoryJob, RssHistoryResumeInput,
    RssHistoryRetryInput, RssHistoryStepInput, RssIssue, RssOfflineTranslationCacheStatus,
    RssOfflineTranslationCleanup, RssOfflineTranslationRecord, RssOfflineTranslationRequest,
    RssOfflineTranslationResult, RssOpmlExecution, RssOpmlImportResult, RssOpmlReview,
    RssPreferences, RssReaderStore, RssRefreshResult,
};
pub use search::{search_markdown_files, MarkdownSearchSnapshot};
pub use semantic_index::{SemanticIndexSnapshot, SemanticIndexStore};
pub use semantic_search::SemanticSearchSnapshot;
pub use site_preview::{
    inspect_site_preview, SitePreviewPageSnapshot, SitePreviewPageTarget, SitePreviewPlan,
    SitePreviewPlanRequest, SitePreviewReadiness, SitePreviewSnapshot, SitePreviewStore,
};
pub use translation::{
    TextTranslationPlan, TextTranslationResponse, TranslationConfig, TranslationGlossaryEntry,
    TranslationProviderKind, TranslationStore,
};
pub use update_client::{
    check as check_app_update_impl, install as install_app_update_impl, AppUpdateCheck,
    AppUpdateInstallResult, UpdateStore,
};
pub use update_readiness::{inspect_update_readiness, LinuxPackageKind, UpdaterConfiguration};
pub use workspace_state::{WorkspacePreferences, WorkspaceStateSnapshot, WorkspaceStateStore};

pub use site_profiles::{SiteProfileSnapshot, SiteProfileStore};

pub use metadata_batch::{MetadataBatchPlan, MetadataBatchResult, MetadataBatchStore};
pub use metadata_field::{MetadataBatchField, MetadataBatchOperation};

#[cfg(test)]
pub(crate) use site_preview_plan::SitePreviewDocumentBinding;
