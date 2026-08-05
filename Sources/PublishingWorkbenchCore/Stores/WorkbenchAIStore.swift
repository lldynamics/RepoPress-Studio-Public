import Combine
import Foundation

public struct AIChatManualRetryState: Equatable, Sendable {
  public let draftID: UUID
  public let conversationID: UUID
  public let requiresDuplicateChargeConfirmation: Bool
  public let retryAfter: Date?

  public init(
    draftID: UUID,
    conversationID: UUID,
    requiresDuplicateChargeConfirmation: Bool,
    retryAfter: Date? = nil
  ) {
    self.draftID = draftID
    self.conversationID = conversationID
    self.requiresDuplicateChargeConfirmation = requiresDuplicateChargeConfirmation
    self.retryAfter = retryAfter
  }
}

struct AIChatConversationIdentity: Equatable, Sendable {
  let draftID: UUID
  let conversationID: UUID
}

@MainActor
public final class WorkbenchAIStore: ObservableObject {
  unowned let store: WorkbenchStore
  private let workspace: AIWorkspaceStore
  let aiPublishingAssistantService: AIPublishingAssistantService
  let keychainTokenStore: KeychainTokenStore
  private let aiConnectionTestService: AIConnectionTestService
  let aiDataSharingConsentStore: AIDataSharingConsentStore
  let imageWorkbenchService: SiteImageWorkbenchService
  private let seoAuditService: SEOAuditService
  private let seoSocialPreviewService: SEOSocialPreviewService
  let aiChatOperationCoordinator = AIChatOperationCoordinator()
  /// Caps observable chat updates at about 20 FPS while network chunks are
  /// still consumed immediately and accumulated off-view. This keeps the
  /// typewriter effect smooth without scheduling a SwiftUI state publication
  /// for every SSE token.
  let aiChatStreamPublishInterval: Duration = .milliseconds(50)
  @Published public internal(set) var aiChatManualRetryState: AIChatManualRetryState? = nil

  init(
    store: WorkbenchStore,
    workspace: AIWorkspaceStore,
    aiPublishingAssistantService: AIPublishingAssistantService = AIPublishingAssistantService(),
    keychainTokenStore: KeychainTokenStore = KeychainTokenStore(),
    aiConnectionTestService: AIConnectionTestService = AIConnectionTestService(),
    aiDataSharingConsentStore: AIDataSharingConsentStore = AIDataSharingConsentStore(),
    imageWorkbenchService: SiteImageWorkbenchService = SiteImageWorkbenchService(),
    seoAuditService: SEOAuditService = SEOAuditService(),
    seoSocialPreviewService: SEOSocialPreviewService = SEOSocialPreviewService()
  ) {
    self.store = store
    self.workspace = workspace
    self.aiPublishingAssistantService = aiPublishingAssistantService
    self.keychainTokenStore = keychainTokenStore
    self.aiConnectionTestService = aiConnectionTestService
    self.aiDataSharingConsentStore = aiDataSharingConsentStore
    self.imageWorkbenchService = imageWorkbenchService
    self.seoAuditService = seoAuditService
    self.seoSocialPreviewService = seoSocialPreviewService
  }

  public var aiTokenAvailability: KeychainTokenAvailability {
    get { workspace.aiTokenAvailability }
    set { workspace.aiTokenAvailability = newValue }
  }

  public var aiActionResult: AIPublishingActionResult? {
    get { workspace.aiActionResult }
    set { workspace.aiActionResult = newValue }
  }

  public var aiActionMessage: String? {
    get { workspace.aiActionMessage }
    set { workspace.aiActionMessage = newValue }
  }

  public var isAIActionRunning: Bool {
    get { workspace.isAIActionRunning }
    set { workspace.isAIActionRunning = newValue }
  }

  public var aiMetadataApplicationRecords: [AIPublishingMetadataApplicationRecord] {
    get { workspace.aiMetadataApplicationRecords }
    set { workspace.aiMetadataApplicationRecords = newValue }
  }

  public var aiMetadataSuggestionDraftID: UUID? {
    get { workspace.aiMetadataSuggestionDraftID }
    set { workspace.aiMetadataSuggestionDraftID = newValue }
  }

  public var aiMetadataSuggestion: AIPublishingMetadataSuggestion? {
    get { workspace.aiMetadataSuggestion }
    set { workspace.aiMetadataSuggestion = newValue }
  }

  public var isAIMetadataSuggestionRunning: Bool {
    get { workspace.isAIMetadataSuggestionRunning }
    set { workspace.isAIMetadataSuggestionRunning = newValue }
  }

  public var aiChatDraftID: UUID? {
    get { workspace.aiChatDraftID }
    set { workspace.aiChatDraftID = newValue }
  }

  public var aiChatConversationTitle: String? {
    get { workspace.aiChatConversationTitle }
    set { workspace.aiChatConversationTitle = newValue }
  }

  public var aiChatMessages: [AIPublishingChatMessage] {
    get { workspace.aiChatMessages }
    set { workspace.aiChatMessages = newValue }
  }

  public var aiChatContextMode: AIPublishingChatContextMode {
    get { workspace.aiChatContextMode }
    set { workspace.aiChatContextMode = newValue }
  }

  public var aiChatKnowledgePolicy: KnowledgeRetrievalPolicy {
    get { workspace.aiChatKnowledgePolicy }
    set { workspace.aiChatKnowledgePolicy = newValue }
  }

  public var aiChatModelGrade: AIChatModelGrade {
    get { workspace.aiChatModelGrade }
    set { workspace.aiChatModelGrade = newValue }
  }

  public var aiChatReasoningLevel: AIChatReasoningLevel {
    get { workspace.aiChatReasoningLevel }
    set { workspace.aiChatReasoningLevel = newValue }
  }

  public var aiChatSelectedModel: String {
    get { workspace.aiChatSelectedModel }
    set { workspace.aiChatSelectedModel = newValue }
  }

  public var aiChatFocusedParagraphID: String? {
    get { workspace.aiChatFocusedParagraphID }
    set { workspace.aiChatFocusedParagraphID = newValue }
  }

  public var aiChatCustomPrompts: [AIPublishingCustomPrompt] {
    get { workspace.aiChatCustomPrompts }
    set { workspace.aiChatCustomPrompts = newValue }
  }

  public var aiConversations: [AIConversation] {
    get { workspace.aiConversations }
    set {
      let limitedConversations = AIConversationRetentionPolicy.limited(
        newValue,
        preserving: Set(workspace.activeAIConversationIDsByDraftID.values)
      )
      workspace.aiConversations = limitedConversations
      workspace.activeAIConversationIDsByDraftID =
        AIConversationRetentionPolicy.validActiveConversationIDs(
          workspace.activeAIConversationIDsByDraftID,
          conversations: limitedConversations
        )
    }
  }

  public var activeAIConversationIDsByDraftID: [UUID: UUID] {
    get { workspace.activeAIConversationIDsByDraftID }
    set { workspace.activeAIConversationIDsByDraftID = newValue }
  }

  public var pendingAIQuickPrompt: AIPublishingQuickPrompt? {
    get { workspace.pendingAIQuickPrompt }
    set { workspace.pendingAIQuickPrompt = newValue }
  }

  public var aiChatMessage: String? {
    get { workspace.aiChatMessage }
    set { workspace.aiChatMessage = newValue }
  }

  public var isAIChatRunning: Bool {
    get { workspace.isAIChatRunning }
    set { workspace.isAIChatRunning = newValue }
  }

  public var aiImageTextSuggestionDraftID: UUID? {
    get { workspace.aiImageTextSuggestionDraftID }
    set { workspace.aiImageTextSuggestionDraftID = newValue }
  }

  public var aiImageTextSuggestions: [AIPublishingImageTextSuggestion] {
    get { workspace.aiImageTextSuggestions }
    set { workspace.aiImageTextSuggestions = newValue }
  }

  public var isAIImageTextRunning: Bool {
    get { workspace.isAIImageTextRunning }
    set { workspace.isAIImageTextRunning = newValue }
  }

  public var seoSocialPreviewSnapshots: [UUID: SEOSocialPreviewSnapshot] {
    get { workspace.seoSocialPreviewSnapshots }
    set { workspace.seoSocialPreviewSnapshots = newValue }
  }

  public var seoSocialPreviewSnapshot: SEOSocialPreviewSnapshot? {
    get { workspace.seoSocialPreviewSnapshot }
    set { workspace.seoSocialPreviewSnapshot = newValue }
  }

  public var seoSocialPreviewMessage: String? {
    get { workspace.seoSocialPreviewMessage }
    set { workspace.seoSocialPreviewMessage = newValue }
  }

  public var isAIPublishingAssistantPresented: Bool {
    get { workspace.isAIPublishingAssistantPresented }
    set { workspace.isAIPublishingAssistantPresented = newValue }
  }

  public func aiActionStateChanged() {
    refreshAIKeyAvailability()
  }

  public func restoreSEOSocialPreviewSnapshotForCurrentSelection() {
    seoSocialPreviewSnapshot = store.selectedDraft.flatMap { seoSocialPreviewSnapshots[$0.id] }
  }

  public func prepareSEOSocialPreview(for draft: ArticleDraft) {
    if let snapshot = seoSocialPreviewSnapshots[draft.id] {
      seoSocialPreviewSnapshot = snapshot
    } else {
      refreshSEOSocialPreview(for: draft, message: nil)
    }
  }

  public func refreshSEOSocialPreview(for draft: ArticleDraft, message: String? = "SEO / 社交预览已刷新。") {
    let snapshot = seoSocialPreviewService.snapshot(draft: draft, profile: store.profile(for: draft))
    seoSocialPreviewSnapshots[draft.id] = snapshot
    seoSocialPreviewSnapshot = snapshot
    seoSocialPreviewMessage = message
    store.save()
  }

  public func isSEOSocialPreviewStale(for draft: ArticleDraft) -> Bool {
    guard let snapshot = seoSocialPreviewSnapshots[draft.id] else { return true }
    let current = seoSocialPreviewService.snapshot(draft: draft, profile: store.profile(for: draft))
    return snapshot.signature != current.signature
  }

  public func seoSocialPreviewSnapshot(for draft: ArticleDraft) -> SEOSocialPreviewSnapshot? {
    seoSocialPreviewSnapshots[draft.id]
  }

  public func seoSocialPreviewCachePresentation(for draft: ArticleDraft) -> SEOSocialPreviewCachePresentation {
    SEOSocialPreviewCachePresentation(
      snapshot: seoSocialPreviewSnapshot(for: draft),
      isStale: isSEOSocialPreviewStale(for: draft)
    )
  }

  public func seoReport(for draft: ArticleDraft) -> SEOAuditReport {
    seoAuditService.report(draft: draft, profile: store.profile(for: draft))
  }

  public func seoSitemapPreview(for draft: ArticleDraft) -> SEOSitemapPreview {
    seoSocialPreviewService.sitemapPreview(
      drafts: store.drafts,
      selectedDraft: draft,
      profile: store.profile(for: draft)
    )
  }

  public func seoSocialPublishPackageMarkdown(for draft: ArticleDraft) -> String? {
    if store.privateContentDisplay(for: draft).isMasked {
      return """
      # SEO / Social 发布包已遮挡

      - 文章：私密文章
      - 状态：私密内容遮挡已开启
      - 提示：打开文章或关闭私密遮挡后再生成发布包。
      """
    }
    let snapshot = seoSocialPreviewSnapshots[draft.id] ?? seoSocialPreviewService.snapshot(draft: draft, profile: store.profile(for: draft))
    return snapshot.publishPackageMarkdown(
      relatedSuggestions: store.relatedArticleSuggestions(for: draft)
    )
  }

  public func refreshAIKeyAvailability() {
    refreshAIKeyAvailability(for: store.activeProfile)
  }

  func refreshAIKeyAvailability(for profile: SiteProfile) {
    let connection = store.aiConnectionProfile(for: profile)
    guard connection.config.requiresAPIKey else {
      aiTokenAvailability = KeychainTokenAvailability(hasToken: false)
      return
    }
    guard !connection.config.normalizedBaseURL.isEmpty else {
      aiTokenAvailability = KeychainTokenAvailability(hasToken: false)
      return
    }
    do {
      let sharedAvailability = try keychainTokenStore.aiTokenAvailability(
        forConnectionProfileID: connection.id
      )
      if sharedAvailability.hasToken || sharedAvailability.accessFailureMessage != nil {
        aiTokenAvailability = sharedAvailability
      } else {
        // Read credentials created by older releases once the site has been
        // migrated to a reusable connection profile.
        aiTokenAvailability = try keychainTokenStore.aiTokenAvailability(for: profile)
      }
    } catch {
      aiTokenAvailability = KeychainTokenAvailability(accessFailure: error)
    }
  }

  @discardableResult
  public func saveAIAPIKey(_ token: String) -> Bool {
    let connection = store.activeAIConnectionProfile
    guard !connection.config.normalizedBaseURL.isEmpty else {
      aiActionMessage = CoreL10n.text("API Base URL 尚未配置。")
      return false
    }
    do {
      try keychainTokenStore.saveAIToken(
        token.trimmedForPublishing,
        forConnectionProfileID: connection.id
      )
      _ = try? keychainTokenStore.deleteLegacyAIToken(for: store.activeProfile)
      refreshAIKeyAvailability()
      aiActionMessage = "AI API Key 已保存到 Keychain。"
      aiChatMessage = "AI API Key 已就绪，可以发送消息。"
      return true
    } catch {
      aiActionMessage = aiKeychainFailureMessage(action: "保存", error: error)
      return false
    }
  }

  public func deleteAIAPIKey() {
    do {
      let connection = store.activeAIConnectionProfile
      try keychainTokenStore.deleteAIToken(forConnectionProfileID: connection.id)
      // Best-effort cleanup of the old per-site item is kept separate from the
      // shared credential so a legacy ACL cannot make deletion look failed.
      _ = try? keychainTokenStore.deleteLegacyAIToken(for: store.activeProfile)
      refreshAIKeyAvailability()
      aiActionMessage = "AI API Key 已删除。"
      aiChatMessage = "AI API Key 已删除，请重新配置后再发送消息。"
    } catch {
      aiActionMessage = aiKeychainFailureMessage(action: "删除", error: error)
    }
  }

  private func aiKeychainFailureMessage(action: String, error: Error) -> String {
    var message = "AI API Key \(action)失败：\(error.localizedDescription)"
    if let keychainError = error as? KeychainTokenStoreError,
       let recoveryHint = keychainError.recoveryHint {
      message += " \(recoveryHint)"
    }
    return message
  }

  public func testAIConnection() async -> AIConnectionTestReport? {
    isAIActionRunning = true
    defer { isAIActionRunning = false }
    do {
      let token = try aiChatAvailableAPIKey(for: store.activeProfile)
      let report = try await aiConnectionTestService.testConnection(
        config: store.aiProviderConfig(for: store.activeProfile),
        apiKey: token
      )
      refreshAIKeyAvailability()
      aiActionMessage = report.headline
      aiChatMessage = "AI 连接正常，可以发送消息。"
      return report
    } catch {
      aiActionMessage = "AI 连接测试失败：\(error.localizedDescription)"
      return nil
    }
  }

  public var aiDataSharingConsentPresentation: AIDataSharingConsentPresentation {
    aiDataSharingConsentStore.presentation(
      for: store.aiProviderConfig(for: store.activeProfile)
    )
  }

  public func grantAIDataSharingConsent() {
    let config = store.aiProviderConfig(for: store.activeProfile)
    aiDataSharingConsentStore.grant(for: config)
    if config.isLocalEndpoint {
      aiActionMessage = "当前为本地 AI 服务，内容不会发送给第三方服务商。"
    } else if config.dataSharingDestination.isEmpty {
      aiActionMessage = "尚未配置 API 基础地址，授权暂不生效。"
    } else {
      aiActionMessage = "已允许向 \(config.normalizedDisplayName)（\(config.dataSharingDestination)）发送内容。"
    }
  }

  public func revokeAIDataSharingConsent() {
    let config = store.aiProviderConfig(for: store.activeProfile)
    aiDataSharingConsentStore.revoke(for: config)
    aiActionMessage = "已撤销 \(config.normalizedDisplayName) 的内容发送授权。"
  }
}
