import PublishingWorkbenchCore

extension CodexAppServerModel {
  /// App Server owns this dynamic, account-specific model name. It is already
  /// presentation content rather than one of RepoPress Studio's catalog keys.
  var localizedDisplayName: String { displayName }
}

extension AIPublishingActionKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .publishingReadiness: "display.ai-publishing-action-kind.publishing-readiness"
    case .continueArticle: "display.ai-publishing-action-kind.continue-article"
    case .draftOpening: "display.ai-publishing-action-kind.draft-opening"
    case .sharpenOpeningSelection: "display.ai-publishing-action-kind.sharpen-opening-selection"
    case .draftOpeningHooks: "display.ai-publishing-action-kind.draft-opening-hooks"
    case .draftFullArticle: "display.ai-publishing-action-kind.draft-full-article"
    case .suggestArticleOutline: "display.ai-publishing-action-kind.suggest-article-outline"
    case .compareWritingAngles: "display.ai-publishing-action-kind.compare-writing-angles"
    case .expandOutlineToDraft: "display.ai-publishing-action-kind.expand-outline-to-draft"
    case .draftConclusion: "display.ai-publishing-action-kind.draft-conclusion"
    case .draftArticleTLDR: "display.ai-publishing-action-kind.draft-article-tldr"
    case .draftArticleFAQ: "display.ai-publishing-action-kind.draft-article-faq"
    case .draftReaderQuestions: "display.ai-publishing-action-kind.draft-reader-questions"
    case .draftTransitionSection: "display.ai-publishing-action-kind.draft-transition-section"
    case .draftExampleSection: "display.ai-publishing-action-kind.draft-example-section"
    case .draftStepByStepGuide: "display.ai-publishing-action-kind.draft-step-by-step-guide"
    case .draftTutorialVersion: "display.ai-publishing-action-kind.draft-tutorial-version"
    case .draftChecklistSection: "display.ai-publishing-action-kind.draft-checklist-section"
    case .draftTroubleshootingSection: "display.ai-publishing-action-kind.draft-troubleshooting-section"
    case .draftCodeExample: "display.ai-publishing-action-kind.draft-code-example"
    case .draftMermaidDiagram: "display.ai-publishing-action-kind.draft-mermaid-diagram"
    case .draftGlossary: "display.ai-publishing-action-kind.draft-glossary"
    case .draftReferencesSection: "display.ai-publishing-action-kind.draft-references-section"
    case .draftInterviewQA: "display.ai-publishing-action-kind.draft-interview-qa"
    case .reorganizeStructure: "display.ai-publishing-action-kind.reorganize-structure"
    case .draftCounterpointSection: "display.ai-publishing-action-kind.draft-counterpoint-section"
    case .draftCaseStudySection: "display.ai-publishing-action-kind.draft-case-study-section"
    case .extractArticleKeyPoints: "display.ai-publishing-action-kind.extract-article-key-points"
    case .extractArticleActionItems: "display.ai-publishing-action-kind.extract-article-action-items"
    case .rewriteSelection: "display.ai-publishing-action-kind.rewrite-selection"
    case .polishSelection: "display.ai-publishing-action-kind.polish-selection"
    case .expandSelection: "display.ai-publishing-action-kind.expand-selection"
    case .continueAfterSelection: "display.ai-publishing-action-kind.continue-after-selection"
    case .condenseSelection: "display.ai-publishing-action-kind.condense-selection"
    case .removeRedundancySelection: "display.ai-publishing-action-kind.remove-redundancy-selection"
    case .checklistSelection: "display.ai-publishing-action-kind.checklist-selection"
    case .comparisonTableSelection: "display.ai-publishing-action-kind.comparison-table-selection"
    case .explainSelection: "display.ai-publishing-action-kind.explain-selection"
    case .simplifySelection: "display.ai-publishing-action-kind.simplify-selection"
    case .summarizeSelection: "display.ai-publishing-action-kind.summarize-selection"
    case .translateSelectionToChinese: "display.ai-publishing-action-kind.translate-selection-to-chinese"
    case .translateSelectionToEnglish: "display.ai-publishing-action-kind.translate-selection-to-english"
    case .draftBilingualRewrite: "display.ai-publishing-action-kind.draft-bilingual-rewrite"
    case .fixSelectionGrammar: "display.ai-publishing-action-kind.fix-selection-grammar"
    case .rewriteSelectionReaderFriendly: "display.ai-publishing-action-kind.rewrite-selection-reader-friendly"
    case .rewriteSelectionFormal: "display.ai-publishing-action-kind.rewrite-selection-formal"
    case .rewriteSelectionCasual: "display.ai-publishing-action-kind.rewrite-selection-casual"
    case .rewriteSelectionTechnical: "display.ai-publishing-action-kind.rewrite-selection-technical"
    case .titleSummaryTags: "display.ai-publishing-action-kind.title-summary-tags"
    case .suggestTitles: "display.ai-publishing-action-kind.suggest-titles"
    case .suggestSlug: "display.ai-publishing-action-kind.suggest-slug"
    case .suggestSummary: "display.ai-publishing-action-kind.suggest-summary"
    case .suggestTags: "display.ai-publishing-action-kind.suggest-tags"
    case .draftFrontMatterPack: "display.ai-publishing-action-kind.draft-front-matter-pack"
    case .draftBilingualMetadata: "display.ai-publishing-action-kind.draft-bilingual-metadata"
    case .privacyReview: "display.ai-publishing-action-kind.privacy-review"
    case .reviewContentGaps: "display.ai-publishing-action-kind.review-content-gaps"
    case .flagUnsupportedClaims: "display.ai-publishing-action-kind.flag-unsupported-claims"
    case .draftSourceChecklist: "display.ai-publishing-action-kind.draft-source-checklist"
    case .suggestInternalLinks: "display.ai-publishing-action-kind.suggest-internal-links"
    case .auditLinkQuality: "display.ai-publishing-action-kind.audit-link-quality"
    case .auditImagePrivacy: "display.ai-publishing-action-kind.audit-image-privacy"
    case .reviewSSGCompatibility: "display.ai-publishing-action-kind.review-ssg-compatibility"
    case .reviewSEOReadability: "display.ai-publishing-action-kind.review-seo-readability"
    case .reviewReaderClarity: "display.ai-publishing-action-kind.review-reader-clarity"
    case .reviewTechnicalAccuracy: "display.ai-publishing-action-kind.review-technical-accuracy"
    case .draftImageAltCaptions: "display.ai-publishing-action-kind.draft-image-alt-captions"
    case .draftSocialShare: "display.ai-publishing-action-kind.draft-social-share"
    case .draftPublishAssetPack: "display.ai-publishing-action-kind.draft-publish-asset-pack"
    case .draftPullQuotes: "display.ai-publishing-action-kind.draft-pull-quotes"
    case .draftPublishNote: "display.ai-publishing-action-kind.draft-publish-note"
    case .draftNewsletterSummary: "display.ai-publishing-action-kind.draft-newsletter-summary"
    case .draftCoverImagePrompt: "display.ai-publishing-action-kind.draft-cover-image-prompt"
    case .draftCrossPlatformAnnouncement: "display.ai-publishing-action-kind.draft-cross-platform-announcement"
    case .draftShortVideoScript: "display.ai-publishing-action-kind.draft-short-video-script"
    case .suggestSeriesPlan: "display.ai-publishing-action-kind.suggest-series-plan"
    case .draftContentRefreshPlan: "display.ai-publishing-action-kind.draft-content-refresh-plan"
    case .draftUpdateNote: "display.ai-publishing-action-kind.draft-update-note"
    case .draftCommentReply: "display.ai-publishing-action-kind.draft-comment-reply"
    case .pullRequestDescription: "display.ai-publishing-action-kind.pull-request-description"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension BatchPublishReadiness {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .ready: "display.batch-publish-readiness.ready"
    case .needsReview: "display.batch-publish-readiness.needs-review"
    case .blocked: "display.batch-publish-readiness.blocked"
    case .unchanged: "display.batch-publish-readiness.unchanged"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension ContentMigrationSourceKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .wordpressWXR: "display.content-migration-source-kind.wordpress-wxr"
    case .rss: "display.content-migration-source-kind.rss"
    case .markdownFolder: "display.content-migration-source-kind.markdown-folder"
    case .genericJSON: "display.content-migration-source-kind.generic-json"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension DeploymentPollingStatus {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .idle: "display.deployment-polling-status.idle"
    case .disabled: "display.deployment-polling-status.disabled"
    case .noEligibleRecords: "display.deployment-polling-status.no-eligible-records"
    case .checked: "display.deployment-polling-status.checked"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension GeneralDraftReuseRiskLevel {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .ready: "display.general-draft-reuse-risk-level.ready"
    case .review: "display.general-draft-reuse-risk-level.review"
    case .high: "display.general-draft-reuse-risk-level.high"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension ImageCoverPublishState {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .ready: "display.image-cover-publish-state.ready"
    case .disabled: "display.image-cover-publish-state.disabled"
    case .privateSuppressed: "display.image-cover-publish-state.private-suppressed"
    case .missingCover: "display.image-cover-publish-state.missing-cover"
    case .missingAttachment: "display.image-cover-publish-state.missing-attachment"
    case .missingPublishPath: "display.image-cover-publish-state.missing-publish-path"
    case .missingSource: "display.image-cover-publish-state.missing-source"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension LocalGitPublishMode {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .directCommit: "display.local-git-publish-mode.direct-commit"
    case .reviewBranch: "display.local-git-publish-mode.review-branch"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension PrivacyProtectionEventKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .lockedOnLaunch: "display.privacy-protection-event-kind.locked-on-launch"
    case .manualLock: "display.privacy-protection-event-kind.manual-lock"
    case .unlocked: "display.privacy-protection-event-kind.unlocked"
    case .settingsUpdated: "display.privacy-protection-event-kind.settings-updated"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension RemoteRepositoryPublishProgressStage {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .preparing: "display.remote-repository-publish-progress-stage.preparing"
    case .validatingTarget: "display.remote-repository-publish-progress-stage.validating-target"
    case .creatingBranch: "display.remote-repository-publish-progress-stage.creating-branch"
    case .uploadingFiles: "display.remote-repository-publish-progress-stage.uploading-files"
    case .creatingReview: "display.remote-repository-publish-progress-stage.creating-review"
    case .completed: "display.remote-repository-publish-progress-stage.completed"
    case .failed: "display.remote-repository-publish-progress-stage.failed"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension RemoteRepositoryPublishReadiness {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .ready: "display.remote-repository-publish-readiness.ready"
    case .needsToken: "display.remote-repository-publish-readiness.needs-token"
    case .needsPermissionCheck: "display.remote-repository-publish-readiness.needs-permission-check"
    case .needsRemoteCheck: "display.remote-repository-publish-readiness.needs-remote-check"
    case .blocked: "display.remote-repository-publish-readiness.blocked"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension RepositoryChangedFileRole {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .article: "display.repository-changed-file-role.article"
    case .image: "display.repository-changed-file-role.image"
    case .configuration: "display.repository-changed-file-role.configuration"
    case .other: "display.repository-changed-file-role.other"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension RepositoryAutoSyncStatus {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .idle: "display.repository-auto-sync-status.idle"
    case .disabled: "display.repository-auto-sync-status.disabled"
    case .waitingForRepository: "display.repository-auto-sync-status.waiting-for-repository"
    case .fetchFailed: "display.repository-auto-sync-status.fetch-failed"
    case .scanned: "display.repository-auto-sync-status.scanned"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension RepositoryChangeKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .added: "display.repository-change-kind.added"
    case .modified: "display.repository-change-kind.modified"
    case .deleted: "display.repository-change-kind.deleted"
    case .renamed: "display.repository-change-kind.renamed"
    case .untracked: "display.repository-change-kind.untracked"
    case .other: "display.repository-change-kind.other"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension SEOSocialPreviewCacheState {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .missing: "display.seo-social-preview-cache-state.missing"
    case .fresh: "display.seo-social-preview-cache-state.fresh"
    case .stale: "display.seo-social-preview-cache-state.stale"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension SEOSocialPreviewCardKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .search: "display.seo-social-preview-card-kind.search"
    case .openGraph: "display.seo-social-preview-card-kind.open-graph"
    case .twitter: "display.seo-social-preview-card-kind.twitter"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension SEOSocialPreviewReadinessStatus {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .ready: "display.seo-social-preview-readiness-status.ready"
    case .warning: "display.seo-social-preview-readiness-status.warning"
    case .missing: "display.seo-social-preview-readiness-status.missing"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension DraftListFilter {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .all: "display.draft-list-filter.all"
    case .draft: "display.draft-list-filter.draft"
    case .checkFailed: "display.draft-list-filter.check-failed"
    case .ready: "display.draft-list-filter.ready"
    case .published: "display.draft-list-filter.published"
    case .privateArticles: "display.draft-list-filter.private-articles"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension WritingDraftSortOrder {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .updatedNewest: "display.writing-draft-sort-order.updated-newest"
    case .updatedOldest: "display.writing-draft-sort-order.updated-oldest"
    case .articleDateNewest: "display.writing-draft-sort-order.article-date-newest"
    case .articleDateOldest: "display.writing-draft-sort-order.article-date-oldest"
    case .titleAscending: "display.writing-draft-sort-order.title-ascending"
    case .titleDescending: "display.writing-draft-sort-order.title-descending"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension KnowledgeDocumentKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .article: "display.knowledge-document-kind.article"
    case .book: "display.knowledge-document-kind.book"
    case .image: "display.knowledge-document-kind.image"
    case .webpage: "display.knowledge-document-kind.webpage"
    case .pdf: "display.knowledge-document-kind.pdf"
    case .markdown: "display.knowledge-document-kind.markdown"
    case .text: "display.knowledge-document-kind.text"
    case .note: "display.knowledge-document-kind.note"
    case .other: "display.knowledge-document-kind.other"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension KnowledgeImportDisposition {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .new: "display.knowledge-import-disposition.new"
    case .update: "display.knowledge-import-disposition.update"
    case .duplicate: "display.knowledge-import-disposition.duplicate"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension KnowledgeDocumentSortField {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .title: "display.knowledge-document-sort-field.title"
    case .kind: "display.knowledge-document-sort-field.kind"
    case .fileSize: "display.knowledge-document-sort-field.file-size"
    case .addedAt: "display.knowledge-document-sort-field.added-at"
    case .updatedAt: "display.knowledge-document-sort-field.updated-at"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension KnowledgeSortDirection {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .ascending: "display.knowledge-sort-direction.ascending"
    case .descending: "display.knowledge-sort-direction.descending"
    }
  }

  var fallbackDisplayName: String { displayName }
}
