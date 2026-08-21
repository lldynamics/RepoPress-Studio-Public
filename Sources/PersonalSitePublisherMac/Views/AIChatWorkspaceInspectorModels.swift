import Foundation
import PublishingWorkbenchCore

struct AIChatContextInspectorState {
  let draft: AIChatInspectorDraftContext?
}

struct AIChatInspectorModelGradeCandidate: Equatable, Identifiable {
  let grade: AIChatModelGrade
  let title: String
  let model: String

  var id: String { grade.rawValue }
}

struct AIChatContextSummaryPresentation: Equatable {
  let title: String
  let detail: String
}

enum AIChatConnectionReadiness: Equatable {
  case ready
  case missingEndpoint
  case missingModel
  case missingAPIKey
  case noDraft

  var isReady: Bool {
    self == .ready
  }

  var title: String {
    switch self {
    case .ready:
      return String(localized: "连接配置已就绪")
    case .missingEndpoint:
      return String(localized: "未配置 Endpoint")
    case .missingModel:
      return String(localized: "未配置模型")
    case .missingAPIKey:
      return String(localized: "未配置 API Key")
    case .noDraft:
      return String(localized: "请先选择文章")
    }
  }

  var detail: String {
    switch self {
    case .ready:
      return String(localized: "连接配置已就绪，点击查看快捷切换")
    case .missingEndpoint:
      return String(localized: "未配置 Endpoint / Base URL")
    case .missingModel:
      return String(localized: "未配置模型")
    case .missingAPIKey:
      return String(localized: "未配置 API Key")
    case .noDraft:
      return String(localized: "请先选择一篇文章，再切换 AI 连接和模型。")
    }
  }
}

enum AIChatConnectionStatusPresentation {
  static func readiness(
    for config: AIProviderConfig,
    activeModel: String? = nil,
    hasToken: Bool,
    hasDraft: Bool
  ) -> AIChatConnectionReadiness {
    guard hasDraft else { return .noDraft }
    guard !config.normalizedBaseURL.isEmpty else { return .missingEndpoint }
    let model =
      activeModel?.trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty ?? config.normalizedModel
    guard !model.isEmpty else { return .missingModel }
    guard !config.requiresAPIKey || hasToken else { return .missingAPIKey }
    return .ready
  }

  static func shortProviderName(for config: AIProviderConfig) -> String {
    switch config.preset {
    case .codexAppServer:
      return "Codex"
    case .local:
      return "Local"
    case .custom:
      return "Custom"
    case .deepSeek:
      return "DeepSeek"
    case .anthropic:
      return "Claude"
    case .gemini:
      return "Gemini"
    case .siliconFlow:
      return "SiliconFlow"
    case .moonshot:
      return "Moonshot"
    case .zhipu:
      return "GLM"
    case .openRouter:
      return "OpenRouter"
    case .openAICompatible:
      return "OpenAI"
    }
  }

  static func summary(
    for config: AIProviderConfig,
    activeModel: String?,
    hasDraft: Bool
  ) -> String {
    guard hasDraft else { return String(localized: "选择模型") }
    let model = activeModel?.nilIfEmpty ?? String(localized: "未选择")
    return shortProviderName(for: config) + ": " + model
  }
}

enum AIChatInspectorHeaderPresentation {
  static func conversationTitle(_ title: String?) -> String {
    title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
      ?? String(localized: "新对话")
  }

  static func contextTitle(for mode: AIPublishingChatContextMode) -> String {
    switch mode {
    case .site:
      return String(localized: "当前文章")
    case .general:
      return String(localized: "通用聊天")
    }
  }

  static func contextSummary(
    mode: AIPublishingChatContextMode,
    draftTitle: String?,
    selectedReferences: [AIContextReference]
  ) -> AIChatContextSummaryPresentation {
    let referencesSummary = AIChatContextReferencePresentation.summary(
      for: selectedReferences
    )

    switch mode {
    case .site:
      let articleTitle =
        draftTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? String(localized: "未选择文章")
      let detail =
        selectedReferences.isEmpty
        ? String(
          format: String(localized: "正在使用：%@；默认包含站点和发布工作台上下文。"),
          articleTitle
        )
        : String(
          format: String(localized: "正在使用：%@；%@"),
          articleTitle,
          referencesSummary
        )
      return AIChatContextSummaryPresentation(
        title: String(localized: "当前文章"),
        detail: detail
      )

    case .general:
      let detail =
        selectedReferences.isEmpty
        ? String(localized: "不读取当前文章正文、仓库状态或发布检查。")
        : String(
          format: String(localized: "不读取当前文章正文；%@"),
          referencesSummary
        )
      return AIChatContextSummaryPresentation(
        title: String(localized: "通用聊天"),
        detail: detail
      )
    }
  }

  static func providerTitle(for config: AIProviderConfig) -> String {
    switch config.preset {
    case .codexAppServer, .openAICompatible, .deepSeek, .anthropic, .gemini, .siliconFlow,
      .moonshot, .zhipu, .openRouter, .local:
      return config.preset.localizedDisplayName
    case .custom:
      return String(localized: "自定义 API")
    }
  }

  static func modelSummary(
    for config: AIProviderConfig,
    activeModel: String?
  ) -> String {
    let provider = providerTitle(for: config)
    if config.usesCodexAppServer {
      // App Server uses the sentinel only when the account chooses the model.
      // A concrete model returned by model/list is the active model and should
      // remain visible in the compact header.
      guard
        let activeModel = activeModel?.trimmingCharacters(in: .whitespacesAndNewlines)
          .nilIfEmpty
      else {
        return provider
      }
      if activeModel == AIProviderPreset.codexDefaultModel {
        return provider + " · " + String(localized: "账户默认模型")
      }
      return "\(provider) · \(activeModel)"
    }
    guard let activeModel = activeModel?.nilIfEmpty else { return provider }
    return "\(provider) · \(activeModel)"
  }

  static func supportsSelectableReasoningLevel(
    config: AIProviderConfig,
    hasDraft: Bool
  ) -> Bool {
    hasDraft && config.usesDeepSeekAPI
  }

  static func modelGradeCandidates(
    for config: AIProviderConfig,
    currentModel: String
  ) -> [AIChatInspectorModelGradeCandidate] {
    [
      (.fast, String(localized: "快速")),
      (.standard, String(localized: "标准")),
      (.highQuality, String(localized: "高质量")),
    ].map { grade, title in
      AIChatInspectorModelGradeCandidate(
        grade: grade,
        title: title,
        model: AIChatModelCatalog.model(
          for: grade,
          config: config,
          currentModel: currentModel
        )
      )
    }
  }

  static func showsCustomModelInput(
    selection: AIChatModelSelectionPresentation?
  ) -> Bool {
    selection?.canEditCustomModel == true
  }
}

/// Presentation policy for the human review surface used by Agent content
/// changes. Keeping this as a value-only policy makes the keyboard and
/// accessibility contract testable without constructing a SwiftUI sheet.
enum AIChatAgentReviewPresentation {
  static let sheetAccessibilityIdentifier = "ai-agent-review-sheet"
  static let laterAccessibilityIdentifier = "ai-agent-review-later"
  static let rejectAccessibilityIdentifier = "ai-agent-review-reject"
  static let acceptAccessibilityIdentifier = "ai-agent-review-accept"
  static let deliveryUncertainAccessibilityIdentifier = "ai-agent-delivery-uncertain"
  static let deliveryUncertainAbandonAccessibilityIdentifier =
    "ai-agent-delivery-uncertain-abandon"
  static let deliveryUncertainBranchAccessibilityIdentifier =
    "ai-agent-delivery-uncertain-branch"

  static let deliveryUncertainWarning = String(localized: "续跑结果不确定，系统没有自动重试")
  static let deliveryUncertainDetail =
    String(localized: "请结束续跑并保留记录，或从这里新建对话。")
  static let deliveryUncertainAbandonTitle = String(localized: "结束续跑并保留记录")
  static let deliveryUncertainBranchTitle = String(localized: "从这里新建对话")
  static let deliveryUncertainEndedTitle = String(localized: "已结束，记录保留")

  static func isDeliveryUncertain(
    phase: AIPublishingChatAgentContinuationPhase
  ) -> Bool {
    phase == .deliveryUncertain
  }

  static func isDeliveryUncertainTerminal(
    phase: AIPublishingChatAgentContinuationPhase
  ) -> Bool {
    phase == .abandonedAfterDeliveryUncertain
  }

  static func canResolveDeliveryUncertain(
    phase: AIPublishingChatAgentContinuationPhase,
    isBusy: Bool,
    conversationID: UUID?
  ) -> Bool {
    !isBusy && conversationID != nil && isDeliveryUncertain(phase: phase)
  }

  static func allowsRollbackAction(
    phase: AIPublishingChatAgentContinuationPhase?
  ) -> Bool {
    guard let phase else { return true }
    return !isDeliveryUncertain(phase: phase)
      && !isDeliveryUncertainTerminal(phase: phase)
  }

  static func isContentChangeReview(
    plan: WorkbenchAutomationPlan,
    step: WorkbenchAutomationStep
  ) -> Bool {
    plan.source == .agentLoop
      && WorkbenchAutomationRegistry.descriptor(for: step.command)?.risk == .contentChange
  }
}

struct AIChatInspectorDraftContext {
  let draft: ArticleDraft
  let conversationID: UUID?
  let conversationTitle: String
  let messages: [AIPublishingChatMessage]
  let totalMessageCount: Int
  let relatedSuggestions: [AIChatRelatedSuggestionPresentation]
  let isChatRunning: Bool
  let isAutomationRunning: Bool
  let automationRunRecords: [WorkbenchAutomationRunRecord]
}

struct AIChatRelatedSuggestionPresentation: Identifiable {
  let id: String
  let targetTitle: String
  let reason: String
  let targetPath: String
  let targetDraftID: UUID
  let prompt: String
}

struct AIChatContextInspectorActions {
  let sendMessage: (String, ArticleDraft) -> Void
  let selectDraft: (UUID) -> Void
  let appendReply: (AIPublishingChatMessage, ArticleDraft) -> Void
  let applyCodeBlock: (AIChatCodeBlock, ArticleDraft) -> Void
  let insertCodeBlockAtCursor: (AIChatCodeBlock, ArticleDraft) -> Void
  let copyCodeBlock: (AIChatCodeBlock) -> Void
  let copyReply: (AIPublishingChatMessage) -> Void
  let branchConversation: (AIPublishingChatMessage.ID, ArticleDraft) -> Void
  let loadEarlierMessages: () -> Void
  let openCitation: (KnowledgeCitation) -> Void
  let previewStructuredEdits:
    (AIPublishingChatMessage, AIStructuredEditReview, ArticleDraft) -> Void
  let recordStructuredEditFeedback:
    (AILocalEditFeedbackDecision, AIStructuredEditProposal, String?) -> Void
  let createTranslationDraft: (AITranslationDraftPlan) -> Void
  let localFeedbackDecision: (AIPublishingChatMessage) -> AILocalEditFeedbackDecision?
  let recordLocalFeedback: (AILocalEditFeedbackDecision, AIPublishingChatMessage) -> Void
  let executeAutomationPlan: (UUID, AIPublishingChatMessage.ID) -> Void
  let executeAutomationStep: (UUID, AIPublishingChatMessage.ID, UUID) -> Void
  let acceptAutomationStep: (UUID, AIPublishingChatMessage.ID, UUID, String) -> Void
  let rejectAutomationStep: (UUID, AIPublishingChatMessage.ID, UUID, String?) -> Void
  let previewAutomationStep:
    (UUID, AIPublishingChatMessage.ID, UUID) -> WorkbenchAutomationDraftPreview?
  let cancelAutomationPlan: (UUID, AIPublishingChatMessage.ID) -> Void
  let rollbackAutomationRun: (UUID) -> Void
  let abandonAgentContinuation: (UUID, UUID, UUID, UUID, Int) -> Bool
}
