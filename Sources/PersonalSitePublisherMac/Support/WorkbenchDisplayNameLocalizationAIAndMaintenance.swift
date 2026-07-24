import PublishingWorkbenchCore

extension AIPublishingDefaultCapability {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .continueWriting: "display.ai-publishing-default-capability.continue-writing"
    case .rewrite: "display.ai-publishing-default-capability.rewrite"
    case .condense: "display.ai-publishing-default-capability.condense"
    case .translate: "display.ai-publishing-default-capability.translate"
    case .generateMetadata: "display.ai-publishing-default-capability.generate-metadata"
    case .publishingCheck: "display.ai-publishing-default-capability.publishing-check"
    case .citeKnowledge: "display.ai-publishing-default-capability.cite-knowledge"
    case .askAnything: "display.ai-publishing-default-capability.ask-anything"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension AIPublishingPromptLibraryScope {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .all: "display.ai-publishing-prompt-library-scope.all"
    case .writing: "display.ai-publishing-prompt-library-scope.writing"
    case .editing: "display.ai-publishing-prompt-library-scope.editing"
    case .publishing: "display.ai-publishing-prompt-library-scope.publishing"
    case .distribution: "display.ai-publishing-prompt-library-scope.distribution"
    case .maintenance: "display.ai-publishing-prompt-library-scope.maintenance"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension AIPublishingCapabilityCenterMode {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .featured: "display.ai-publishing-capability-center-mode.featured"
    case .all: "display.ai-publishing-capability-center-mode.all"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension AIPublishingQuickPromptGroup {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .writing: "display.ai-publishing-quick-prompt-group.writing"
    case .editing: "display.ai-publishing-quick-prompt-group.editing"
    case .publishing: "display.ai-publishing-quick-prompt-group.publishing"
    case .distribution: "display.ai-publishing-quick-prompt-group.distribution"
    case .maintenance: "display.ai-publishing-quick-prompt-group.maintenance"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension AIPublishingQuickPrompt {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .continueWriting: "display.ai-publishing-quick-prompt.continue-writing"
    case .outline: "display.ai-publishing-quick-prompt.outline"
    case .titleIdeas: "display.ai-publishing-quick-prompt.title-ideas"
    case .slugIdeas: "display.ai-publishing-quick-prompt.slug-ideas"
    case .tagIdeas: "display.ai-publishing-quick-prompt.tag-ideas"
    case .frontMatterPack: "display.ai-publishing-quick-prompt.front-matter-pack"
    case .bilingualMetadata: "display.ai-publishing-quick-prompt.bilingual-metadata"
    case .summary: "display.ai-publishing-quick-prompt.summary"
    case .contentGap: "display.ai-publishing-quick-prompt.content-gap"
    case .angleCompare: "display.ai-publishing-quick-prompt.angle-compare"
    case .translateChinese: "display.ai-publishing-quick-prompt.translate-chinese"
    case .translateEnglish: "display.ai-publishing-quick-prompt.translate-english"
    case .grammar: "display.ai-publishing-quick-prompt.grammar"
    case .tone: "display.ai-publishing-quick-prompt.tone"
    case .localizationDraft: "display.ai-publishing-quick-prompt.localization-draft"
    case .seo: "display.ai-publishing-quick-prompt.seo"
    case .publishReview: "display.ai-publishing-quick-prompt.publish-review"
    case .privacyCheck: "display.ai-publishing-quick-prompt.privacy-check"
    case .readerReview: "display.ai-publishing-quick-prompt.reader-review"
    case .factBoundary: "display.ai-publishing-quick-prompt.fact-boundary"
    case .sourceChecklist: "display.ai-publishing-quick-prompt.source-checklist"
    case .internalLinks: "display.ai-publishing-quick-prompt.internal-links"
    case .linkAudit: "display.ai-publishing-quick-prompt.link-audit"
    case .imagePrivacy: "display.ai-publishing-quick-prompt.image-privacy"
    case .ssgChecklist: "display.ai-publishing-quick-prompt.ssg-checklist"
    case .publishRecoveryPlan: "display.ai-publishing-quick-prompt.publish-recovery-plan"
    case .imageCaptions: "display.ai-publishing-quick-prompt.image-captions"
    case .coverPrompt: "display.ai-publishing-quick-prompt.cover-prompt"
    case .socialShare: "display.ai-publishing-quick-prompt.social-share"
    case .publishAssetPack: "display.ai-publishing-quick-prompt.publish-asset-pack"
    case .pullQuotes: "display.ai-publishing-quick-prompt.pull-quotes"
    case .publishNote: "display.ai-publishing-quick-prompt.publish-note"
    case .crossPlatformAnnouncement: "display.ai-publishing-quick-prompt.cross-platform-announcement"
    case .shortVideoScript: "display.ai-publishing-quick-prompt.short-video-script"
    case .tldr: "display.ai-publishing-quick-prompt.tldr"
    case .faq: "display.ai-publishing-quick-prompt.faq"
    case .readerQuestions: "display.ai-publishing-quick-prompt.reader-questions"
    case .stepGuide: "display.ai-publishing-quick-prompt.step-guide"
    case .checklist: "display.ai-publishing-quick-prompt.checklist"
    case .structurePlan: "display.ai-publishing-quick-prompt.structure-plan"
    case .counterpoint: "display.ai-publishing-quick-prompt.counterpoint"
    case .caseStudy: "display.ai-publishing-quick-prompt.case-study"
    case .oldArticleRefresh: "display.ai-publishing-quick-prompt.old-article-refresh"
    case .mermaid: "display.ai-publishing-quick-prompt.mermaid"
    case .glossary: "display.ai-publishing-quick-prompt.glossary"
    case .releaseSummary: "display.ai-publishing-quick-prompt.release-summary"
    case .seriesPlan: "display.ai-publishing-quick-prompt.series-plan"
    case .updateNote: "display.ai-publishing-quick-prompt.update-note"
    case .commentReply: "display.ai-publishing-quick-prompt.comment-reply"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension AIPublishingChatRole {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .user: "display.ai-publishing-chat-role.user"
    case .assistant: "display.ai-publishing-chat-role.assistant"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension AIPublishingChatContextMode {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .site: "display.ai-publishing-chat-context-mode.site"
    case .general: "display.ai-publishing-chat-context-mode.general"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension AIPublishingChatDraftApplicationMode {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .replaceSelection: "display.ai-publishing-chat-draft-application-mode.replace-selection"
    case .replaceBody: "display.ai-publishing-chat-draft-application-mode.replace-body"
    case .appendToBody: "display.ai-publishing-chat-draft-application-mode.append-to-body"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension AIPublishingSelectionEditApplication {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .replaceRange: "display.ai-publishing-selection-edit-application.replace-range"
    case .insertAfterRange: "display.ai-publishing-selection-edit-application.insert-after-range"
    case .insertAtRange: "display.ai-publishing-selection-edit-application.insert-at-range"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension SiteMaintenanceHealthLevel {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .stable: "display.site-maintenance-health-level.stable"
    case .watch: "display.site-maintenance-health-level.watch"
    case .needsWork: "display.site-maintenance-health-level.needs-work"
    case .urgent: "display.site-maintenance-health-level.urgent"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension MaintenanceActionPriority {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .high: "display.maintenance-action-priority.high"
    case .medium: "display.maintenance-action-priority.medium"
    case .low: "display.maintenance-action-priority.low"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension MaintenanceActionKind {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .staleArticle: "display.maintenance-action-kind.stale-article"
    case .linkAudit: "display.maintenance-action-kind.link-audit"
    case .taxonomy: "display.maintenance-action-kind.taxonomy"
    case .relationSuggestion: "display.maintenance-action-kind.relation-suggestion"
    }
  }

  var fallbackDisplayName: String { displayName }
}

extension WorkbenchAutomationRisk {
  var workbenchDisplayNameSemanticKey: String {
    switch self {
    case .readOnly: "display.workbench-automation-risk.read-only"
    case .reversible: "display.workbench-automation-risk.reversible"
    case .contentChange: "display.workbench-automation-risk.content-change"
    case .externalEffect: "display.workbench-automation-risk.external-effect"
    }
  }

  var fallbackDisplayName: String { displayName }
}
