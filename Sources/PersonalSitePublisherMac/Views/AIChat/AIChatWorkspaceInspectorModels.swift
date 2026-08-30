import Foundation
import PublishingWorkbenchCore

struct AIChatContextInspectorState {
  let draft: AIChatInspectorDraftContext?
}

@MainActor
enum AIChatInspectorDraftResolver {
  static func resolve(
    selectedDraftID: UUID?,
    usesWindowDraftSelection: Bool,
    ai: WorkbenchAIFeatureFacade
  ) -> ArticleDraft? {
    if let selectedDraftID {
      return ai.chatDraft(for: selectedDraftID)
    }
    return usesWindowDraftSelection ? nil : ai.selectedChatDraft
  }
}

/// Static inspector data is relatively expensive (profile/context relation
/// lookup and title derivation), while a stream changes only its final text
/// leaf. This cache is deliberately main-actor confined because it backs one
/// SwiftUI inspector instance.
@MainActor
final class AIChatInspectorStaticProjectionCache: ObservableObject {
  struct Key: Equatable {
    let draftID: UUID
    let draftUpdatedAt: Date
    let conversationID: UUID?
    let contextMode: AIPublishingChatContextMode
    let conversationTitle: String?
    let firstUserMessageID: UUID?
    let lifecycleRevision: UInt64
    let siteMaintenanceSnapshotVersion: Int
  }

  struct Projection {
    let draft: ArticleDraft
    let conversationID: UUID?
    let conversationTitle: String
    let relatedSuggestions: [AIChatRelatedSuggestionPresentation]
  }

  private var key: Key?
  private var projection: Projection?
  private(set) var buildCount = 0

  func resolve(
    key: Key,
    build: () -> Projection
  ) -> Projection {
    if self.key == key, let projection { return projection }
    let next = build()
    self.key = key
    projection = next
    buildCount &+= 1
    return next
  }
}

/// Keeps the inspector's scroll intent explicit: a user drag opts out of
/// streaming auto-scroll, and only an explicit return action opts back in.
enum AIChatScrollPinningPolicy {
  static func shouldShowReturnToLatest(
    isPinnedToLatest: Bool,
    hasLatestMessage: Bool
  ) -> Bool {
    !isPinnedToLatest && hasLatestMessage
  }

  static func isPinnedAfterUserDrag() -> Bool { false }

  static func isPinnedAfterReturnToLatest() -> Bool { true }

  static func shouldFollowScheduledScroll(
    isPinnedToLatest: Bool,
    scheduledGeneration: UInt64,
    currentGeneration: UInt64
  ) -> Bool {
    isPinnedToLatest && scheduledGeneration == currentGeneration
  }
}

enum AIChatAssistantMessagePresentationMode: Equatable {
  case streamingText
  case structured
}

/// Chooses the lightweight text surface only for the assistant message that
/// is currently receiving the active chat stream. The store already coalesces
/// streaming token publications into its 50 ms UI updates; this policy keeps
/// each such update from rebuilding Markdown/code-block views. Completed and
/// older messages keep their structured presentation.
enum AIChatAssistantMessagePresentationPolicy {
  static func mode(
    role: AIPublishingChatRole,
    messageID: UUID,
    latestMessageID: UUID?,
    isChatRunning: Bool
  ) -> AIChatAssistantMessagePresentationMode {
    guard role == .assistant,
      isChatRunning,
      messageID == latestMessageID
    else {
      return .structured
    }
    return .streamingText
  }
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

enum AIChatAgentToolAvailability: Equatable {
  case available
  case conversationTextOnly
  case connectionDisabled
  case draftCreationDenied
  case capabilityUnknown
  case capabilityUnsupported

  var message: String? {
    switch self {
    case .available:
      return nil
    case .conversationTextOnly:
      return String(localized: "本对话为仅问答模式；不会提供新建文章等应用工具。")
    case .connectionDisabled:
      return String(localized: "Agent 已在当前连接中关闭；AI 只能回答，不能新建文章。")
    case .draftCreationDenied:
      return String(localized: "当前连接未授权“新建文章草稿”权限。")
    case .capabilityUnknown:
      return String(localized: "当前模型尚未确认支持工具调用；新建文章功能暂不可用。")
    case .capabilityUnsupported:
      return String(localized: "当前模型不支持工具调用；新建文章功能不可用。")
    }
  }

  var actionTitle: String? {
    switch self {
    case .available:
      return nil
    case .conversationTextOnly:
      return String(localized: "改为跟随连接")
    case .connectionDisabled, .draftCreationDenied, .capabilityUnknown, .capabilityUnsupported:
      return String(localized: "打开 AI 设置")
    }
  }
}

enum AIChatAgentToolAvailabilityPresentation {
  static func availability(
    config: AIProviderConfig,
    conversationMode: AIConversationAgentMode
  ) -> AIChatAgentToolAvailability {
    guard conversationMode != .textOnly else {
      return .conversationTextOnly
    }
    let settings = config.resolvedAdvancedSettings
    guard settings.resolvedAllowsApplicationTools else {
      return .connectionDisabled
    }
    guard settings.resolvedAgentPermissionPolicy.allows(.draftCreation) else {
      return .draftCreationDenied
    }
    switch config.capabilitySupport(for: .toolCalling) {
    case .supported:
      return .available
    case .unknown:
      return .capabilityUnknown
    case .unsupported:
      return .capabilityUnsupported
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

/// Keeps the Inspector header's density decisions value-only so the default
/// surface cannot accidentally grow a second source/action chip band again.
/// The Composer remains responsible for showing the actual outbound payload.
enum AIChatInspectorDensityPresentation {
  enum SourcePresentation: Equatable {
    case compactSummary
    case fullChips
  }

  enum QuickActionPresentation: Equatable {
    case hidden
    case menu
  }

  struct Configuration: Equatable {
    let sourcePresentation: SourcePresentation
    let quickActionPresentation: QuickActionPresentation
    let accessibilityState: String
  }

  static func configuration(isExpanded: Bool) -> Configuration {
    isExpanded
      ? Configuration(
        sourcePresentation: .fullChips,
        quickActionPresentation: .menu,
        accessibilityState: "已展开"
      )
      : Configuration(
        sourcePresentation: .compactSummary,
        quickActionPresentation: .hidden,
        accessibilityState: "已折叠"
      )
  }

  static func compactContextSummary(
    mode: AIPublishingChatContextMode,
    draftTitle: String?,
    explicitReferenceCount: Int,
    knowledgeTitle: String,
    agentTitle: String
  ) -> String {
    let boundary: String
    switch mode {
    case .site:
      let articleTitle =
        draftTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? String(localized: "未选择文章")
      boundary = "当前文章：\(articleTitle)"
    case .general:
      boundary = "通用聊天：不读取当前文章"
    }

    let references = explicitReferenceCount > 0 ? "\(explicitReferenceCount) 项手动引用" : nil
    return ([boundary, references, "资料库：\(knowledgeTitle)", "Agent：\(agentTitle)"]
      .compactMap { $0 })
      .joined(separator: " · ")
  }

  static func disclosureAccessibilityValue(
    configuration: Configuration,
    compactSummary: String
  ) -> String {
    switch configuration.sourcePresentation {
    case .compactSummary:
      return "\(configuration.accessibilityState)。\(compactSummary)。展开可查看完整来源、设置和快捷提示。"
    case .fullChips:
      return "\(configuration.accessibilityState)。\(compactSummary)。正在显示完整来源、设置和快捷提示。"
    }
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
