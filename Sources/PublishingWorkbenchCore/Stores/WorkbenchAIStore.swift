import Combine
import Foundation

public struct AIChatManualRetryState: Equatable, Sendable {
  public let draftID: UUID
  public let requiresDuplicateChargeConfirmation: Bool
  public let retryAfter: Date?

  public init(
    draftID: UUID,
    requiresDuplicateChargeConfirmation: Bool,
    retryAfter: Date? = nil
  ) {
    self.draftID = draftID
    self.requiresDuplicateChargeConfirmation = requiresDuplicateChargeConfirmation
    self.retryAfter = retryAfter
  }
}

@MainActor
public final class WorkbenchAIStore: ObservableObject {
  private unowned let store: WorkbenchStore
  private let workspace: AIWorkspaceStore
  private let aiPublishingAssistantService: AIPublishingAssistantService
  private let keychainTokenStore: KeychainTokenStore
  private let aiConnectionTestService: AIConnectionTestService
  private let imageWorkbenchService: SiteImageWorkbenchService
  private let seoAuditService: SEOAuditService
  private let seoSocialPreviewService: SEOSocialPreviewService
  /// Per-draft state exists only for the current process so a streaming reply
  /// can finish safely after the user selects another draft.
  private var transientAIChatSessionsByDraftID: [UUID: AIPublishingChatSessionState] = [:]
  private var transientAIChatSessionAccessOrder: [UUID: UInt64] = [:]
  private var transientAIChatSessionAccessSequence: UInt64 = 0
  private let maximumTransientAIChatSessions = 12
  private let maximumTransientAIChatImageBytes: Int64 = 48_000_000
  private var activeAIChatOperationID: UUID?
  private var isAIChatCancellationRequested = false
  private let aiChatStreamPublishInterval: Duration = .milliseconds(50)
  @Published public private(set) var aiChatManualRetryState: AIChatManualRetryState? = nil

  init(
    store: WorkbenchStore,
    workspace: AIWorkspaceStore,
    aiPublishingAssistantService: AIPublishingAssistantService = AIPublishingAssistantService(),
    keychainTokenStore: KeychainTokenStore = KeychainTokenStore(),
    aiConnectionTestService: AIConnectionTestService = AIConnectionTestService(),
    imageWorkbenchService: SiteImageWorkbenchService = SiteImageWorkbenchService(),
    seoAuditService: SEOAuditService = SEOAuditService(),
    seoSocialPreviewService: SEOSocialPreviewService = SEOSocialPreviewService()
  ) {
    self.store = store
    self.workspace = workspace
    self.aiPublishingAssistantService = aiPublishingAssistantService
    self.keychainTokenStore = keychainTokenStore
    self.aiConnectionTestService = aiConnectionTestService
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
    aiTokenAvailability = (try? keychainTokenStore.aiTokenAvailability(for: profile))
      ?? KeychainTokenAvailability(hasToken: false)
  }

  @discardableResult
  public func saveAIAPIKey(_ token: String) -> Bool {
    do {
      try keychainTokenStore.saveAIToken(token.trimmedForPublishing, for: store.activeProfile)
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
      try keychainTokenStore.deleteAIToken(for: store.activeProfile)
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
      let report = try await aiConnectionTestService.testConnection(config: store.activeProfile.aiProviderConfig, apiKey: token)
      refreshAIKeyAvailability()
      aiActionMessage = report.headline
      aiChatMessage = "AI 连接正常，可以发送消息。"
      return report
    } catch {
      aiActionMessage = "AI 连接测试失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func prepareAIChat(for draft: ArticleDraft) {
    if aiChatDraftID == draft.id {
      return
    }
    aiChatManualRetryState = nil
    if let currentDraftID = aiChatDraftID {
      cacheCurrentAIChatSessionForTransition(for: currentDraftID)
    }
    let state = transientAIChatSessionsByDraftID.removeValue(forKey: draft.id)
      ?? AIPublishingChatSessionState()
    transientAIChatSessionAccessOrder.removeValue(forKey: draft.id)
    aiChatDraftID = draft.id
    applyCurrentAIChatSession(state)
  }

  func aiChatSessionState(for draftID: UUID) -> AIPublishingChatSessionState? {
    if aiChatDraftID == draftID {
      return currentAIChatSessionState()
    }
    guard let state = transientAIChatSessionsByDraftID[draftID] else { return nil }
    markTransientAIChatSessionAccessed(draftID)
    return state
  }

  func setAIChatSessionState(_ state: AIPublishingChatSessionState, for draftID: UUID) {
    let prepared = state.prepared()
    if aiChatDraftID == draftID {
      applyCurrentAIChatSession(prepared)
      transientAIChatSessionsByDraftID.removeValue(forKey: draftID)
      transientAIChatSessionAccessOrder.removeValue(forKey: draftID)
    } else {
      cacheTransientAIChatSession(prepared, for: draftID)
    }
  }

  func removeAIChatSessionState(for draftID: UUID) {
    transientAIChatSessionsByDraftID.removeValue(forKey: draftID)
    transientAIChatSessionAccessOrder.removeValue(forKey: draftID)
    if aiChatDraftID == draftID {
      aiChatConversationTitle = nil
      aiChatMessages = []
      aiChatFocusedParagraphID = nil
    }
  }

  func cacheCurrentAIChatSessionForAIStore() {
    guard let draftID = aiChatDraftID else { return }
    let prepared = currentAIChatSessionState().prepared()
    applyCurrentAIChatSession(prepared)
    transientAIChatSessionsByDraftID.removeValue(forKey: draftID)
    transientAIChatSessionAccessOrder.removeValue(forKey: draftID)
  }

  private func cacheCurrentAIChatSessionForTransition(for draftID: UUID) {
    let state = currentAIChatSessionState().prepared()
    cacheTransientAIChatSession(state, for: draftID)
  }

  private func currentAIChatSessionState() -> AIPublishingChatSessionState {
    return AIPublishingChatSessionState(
      conversationTitle: aiChatConversationTitle,
      messages: aiChatMessages,
      contextMode: aiChatContextMode,
      knowledgePolicy: aiChatKnowledgePolicy,
      modelGrade: aiChatModelGrade,
      reasoningLevel: aiChatReasoningLevel,
      selectedModel: aiChatSelectedModel,
      focusedParagraphID: aiChatFocusedParagraphID
    )
  }

  private func applyCurrentAIChatSession(_ state: AIPublishingChatSessionState) {
    aiChatConversationTitle = state.conversationTitle
    aiChatMessages = state.messages
    aiChatContextMode = state.contextMode
    aiChatKnowledgePolicy = state.knowledgePolicy
    aiChatModelGrade = state.modelGrade
    aiChatReasoningLevel = state.reasoningLevel
    aiChatSelectedModel = state.selectedModel
    aiChatFocusedParagraphID = state.focusedParagraphID
  }

  private func cacheTransientAIChatSession(
    _ state: AIPublishingChatSessionState,
    for draftID: UUID
  ) {
    if state.shouldCache {
      transientAIChatSessionsByDraftID[draftID] = state
      markTransientAIChatSessionAccessed(draftID)
      pruneTransientAIChatSessions()
    } else {
      transientAIChatSessionsByDraftID.removeValue(forKey: draftID)
      transientAIChatSessionAccessOrder.removeValue(forKey: draftID)
    }
  }

  private func markTransientAIChatSessionAccessed(_ draftID: UUID) {
    transientAIChatSessionAccessSequence &+= 1
    transientAIChatSessionAccessOrder[draftID] = transientAIChatSessionAccessSequence
  }

  private func pruneTransientAIChatSessions() {
    while transientAIChatSessionsByDraftID.count > maximumTransientAIChatSessions,
          let oldestDraftID = oldestTransientAIChatSessionID() {
      transientAIChatSessionsByDraftID.removeValue(forKey: oldestDraftID)
      transientAIChatSessionAccessOrder.removeValue(forKey: oldestDraftID)
    }

    var totalImageBytes = transientAIChatSessionsByDraftID.values.reduce(Int64(0)) {
      $0 + $1.imageAttachmentByteCount
    }
    while totalImageBytes > maximumTransientAIChatImageBytes,
          let oldestDraftID = oldestTransientAIChatSessionID(containingImages: true),
          let state = transientAIChatSessionsByDraftID[oldestDraftID] {
      let trimmed = state.prepared(maxTotalImageBytes: -1)
      let removedBytes = state.imageAttachmentByteCount - trimmed.imageAttachmentByteCount
      guard removedBytes > 0 else { break }
      transientAIChatSessionsByDraftID[oldestDraftID] = trimmed
      totalImageBytes -= removedBytes
    }
  }

  private func oldestTransientAIChatSessionID(containingImages: Bool = false) -> UUID? {
    transientAIChatSessionsByDraftID.keys
      .filter { !containingImages || (transientAIChatSessionsByDraftID[$0]?.imageAttachmentByteCount ?? 0) > 0 }
      .min {
        (transientAIChatSessionAccessOrder[$0] ?? 0)
          < (transientAIChatSessionAccessOrder[$1] ?? 0)
      }
  }

  var transientAIChatSessionCount: Int {
    transientAIChatSessionsByDraftID.count
  }

  func updateAIChatSession(for draftID: UUID, update: (inout [AIPublishingChatMessage]) -> Void) {
    if aiChatDraftID == draftID {
      update(&aiChatMessages)
      cacheCurrentAIChatSessionForAIStore()
      return
    }
    var state = transientAIChatSessionsByDraftID[draftID] ?? AIPublishingChatSessionState()
    update(&state.messages)
    setAIChatSessionState(state, for: draftID)
  }

  func aiChatPrivacyLockedOperationMessage() -> String {
    store.privacyLockedOperationMessage
  }

  func aiChatCanStartFeatureUse(_ feature: PremiumFeature) -> FeatureAccessDecision {
    store.canStartFeatureUse(feature)
  }

  func aiChatConsumeFeatureUse(_ feature: PremiumFeature) -> FeatureAccessDecision {
    store.consumeFeatureUse(feature)
  }

  func aiChatAvailableAPIKey(for profile: SiteProfile) throws -> String? {
    guard profile.aiProviderConfig.requiresAPIKey else { return nil }
    guard let token = try keychainTokenStore.aiToken(for: profile)?.nilIfEmpty else {
      throw AIPublishingAssistantError.missingAPIKey
    }
    return token
  }

  func setAIChatCancellationRequested(_ value: Bool) {
    isAIChatCancellationRequested = value
  }

  func aiChatCancellationRequested() -> Bool {
    isAIChatCancellationRequested
  }

  @discardableResult func requestAIChatCancellation() -> Bool {
    guard isAIChatRunning, activeAIChatOperationID != nil else { return false }
    isAIChatCancellationRequested = true
    aiChatMessage = "正在停止 AI 回复..."
    return true
  }

  private func beginAIChatOperation(statusMessage: String) -> UUID? {
    guard activeAIChatOperationID == nil else {
      store.setAIChatMessage("AI 正在回复，请先停止当前回复后再试。")
      return nil
    }
    let operationID = UUID()
    aiChatManualRetryState = nil
    activeAIChatOperationID = operationID
    setAIChatCancellationRequested(false)
    store.setAIChatRunning(true)
    store.setAIChatMessage(statusMessage)
    return operationID
  }

  private func finishAIChatOperation(_ operationID: UUID) {
    guard activeAIChatOperationID == operationID else { return }
    activeAIChatOperationID = nil
    setAIChatCancellationRequested(false)
    store.setAIChatRunning(false)
    store.save()
  }

  private func checkAIChatOperation(_ operationID: UUID) throws {
    try Task.checkCancellation()
    guard activeAIChatOperationID == operationID,
          !aiChatCancellationRequested() else {
      throw CancellationError()
    }
  }

  func aiChatRequest(for draft: ArticleDraft) async -> AIPublishingChatRequest {
    let session = aiChatSessionState(for: draft.id) ?? AIPublishingChatSessionState()
    let artifacts = await store.aiPublishingRequestArtifacts(for: draft)
    let focusedParagraph = session.focusedParagraphID.flatMap { focusedID in
      AIPublishingChatDraftParagraphParser.extract(from: artifacts.draft.bodyMarkdown).first { $0.id == focusedID }
    }
    let latestQuestion = session.messages.last(where: { $0.role == .user })?.content
    let knowledgeContext = await store.knowledge.context(
      query: knowledgeQuery(
        draft: artifacts.draft,
        selectedText: focusedParagraph?.text,
        instruction: latestQuestion
      ),
      policy: session.knowledgePolicy
    )
    return AIPublishingChatRequest(
      draft: artifacts.draft,
      profile: artifacts.profile,
      messages: session.messages,
      contextMode: session.contextMode,
      knowledgePolicy: session.knowledgePolicy,
      knowledgeContext: knowledgeContext,
      modelGrade: session.modelGrade,
      reasoningLevel: session.reasoningLevel,
      selectedModel: session.selectedModel.nilIfEmpty,
      preflightIssues: artifacts.preflightIssues,
      publishPackage: artifacts.publishPackage,
      remoteReviewDraft: artifacts.remoteReviewDraft,
      workflowContext: artifacts.workflowContext,
      focusedParagraph: focusedParagraph,
      relatedSuggestions: store.relatedArticleSuggestions(for: artifacts.draft)
    )
  }

  private func knowledgeQuery(
    draft: ArticleDraft,
    selectedText: String? = nil,
    instruction: String? = nil
  ) -> String {
    [
      instruction?.trimmedForPublishing.nilIfEmpty,
      draft.title.trimmedForPublishing.nilIfEmpty,
      draft.summary.trimmedForPublishing.nilIfEmpty,
      selectedText?.trimmedForPublishing.nilIfEmpty.map { String($0.prefix(1_500)) },
      String(draft.bodyMarkdown.prefix(1_500)).trimmedForPublishing.nilIfEmpty,
    ]
    .compactMap { $0 }
    .joined(separator: "\n")
  }

  public func setAIChatKnowledgePolicy(_ policy: KnowledgeRetrievalPolicy) {
    aiChatKnowledgePolicy = policy
    cacheCurrentAIChatSessionForAIStore()
  }

  public func setAIChatModelGrade(_ grade: AIChatModelGrade) {
    let config = store.selectedDraft.map { store.profile(for: $0).aiProviderConfig } ?? store.activeProfile.aiProviderConfig
    aiChatModelGrade = grade
    aiChatSelectedModel = AIChatModelCatalog.model(
      for: grade,
      config: config,
      currentModel: aiChatSelectedModel
    )
    cacheCurrentAIChatSessionForAIStore()
  }

  public func setAIChatReasoningLevel(_ level: AIChatReasoningLevel) {
    aiChatReasoningLevel = level
    cacheCurrentAIChatSessionForAIStore()
  }

  public func setAIChatCustomModel(_ model: String) {
    aiChatModelGrade = .custom
    aiChatSelectedModel = model
    cacheCurrentAIChatSessionForAIStore()
  }

  public func resetAIChatModelToProfileDefault() {
    setAIChatModelGrade(.standard)
  }

  public func clearAIChat() {
    aiChatConversationTitle = nil
    aiChatMessages = []
    aiChatManualRetryState = nil
    cacheCurrentAIChatSessionForAIStore()
    aiChatMessage = "AI 讨论已清空。"
    store.save()
  }

  public func setAIChatConversationTitle(_ title: String?, draft: ArticleDraft? = nil) {
    if let draft {
      prepareAIChat(for: draft)
    }
    guard aiChatDraftID != nil else {
      aiChatMessage = "请先选择一篇文章。"
      return
    }

    aiChatConversationTitle = title?.trimmedForPublishing.nilIfEmpty
    cacheCurrentAIChatSessionForAIStore()
    aiChatMessage = aiChatConversationTitle == nil ? "已恢复自动对话标题。" : "已更新 AI 对话标题。"
    store.save()
  }

  public func setAIChatFocusedParagraph(_ paragraphID: String?, draft: ArticleDraft? = nil) {
    if let draft {
      prepareAIChat(for: draft)
    }
    guard aiChatDraftID != nil else {
      aiChatMessage = "请先选择一篇文章。"
      return
    }

    aiChatFocusedParagraphID = paragraphID?.nilIfEmpty
    cacheCurrentAIChatSessionForAIStore()
    aiChatMessage = aiChatFocusedParagraphID == nil ? "AI 已恢复整篇文章上下文。" : "AI 已聚焦引用段落。"
    store.save()
  }

  @discardableResult
  public func saveAIChatCustomPrompt(
    title: String,
    prompt: String
  ) -> AIPublishingCustomPrompt? {
    let trimmedPrompt = prompt.trimmedForPublishing
    guard !trimmedPrompt.isEmpty else {
      store.setAIChatMessage("提示内容为空，未保存。")
      return nil
    }

    let resolvedTitle = title.trimmedForPublishing.nilIfEmpty
      ?? trimmedPrompt.components(separatedBy: .newlines).first?.trimmedForPublishing.nilIfEmpty
      ?? "自定义提示"
    let customPrompt = AIPublishingCustomPrompt(
      title: String(resolvedTitle.prefix(40)),
      prompt: trimmedPrompt
    )
    var updatedPrompts = aiChatCustomPrompts
    updatedPrompts.removeAll {
      $0.prompt == customPrompt.prompt || $0.title == customPrompt.title
    }
    updatedPrompts.insert(customPrompt, at: 0)
    aiChatCustomPrompts = Array(updatedPrompts.prefix(80))
    store.setAIChatMessage("已保存自定义提示：\(customPrompt.title)")
    store.save()
    return customPrompt
  }

  public func deleteAIChatCustomPrompt(_ promptID: AIPublishingCustomPrompt.ID) {
    var updatedPrompts = aiChatCustomPrompts
    let originalCount = updatedPrompts.count
    updatedPrompts.removeAll { $0.id == promptID }
    guard updatedPrompts.count < originalCount else {
      store.setAIChatMessage("找不到要删除的自定义提示。")
      return
    }
    aiChatCustomPrompts = updatedPrompts
    store.setAIChatMessage("已删除自定义提示。")
    store.save()
  }

  public func startNewAIChatConversation(draft: ArticleDraft? = nil) {
    if let draft {
      prepareAIChat(for: draft)
    }
    guard aiChatDraftID != nil else {
      aiChatMessage = "请先选择一篇文章。"
      return
    }
    aiChatConversationTitle = nil
    aiChatMessages = []
    cacheCurrentAIChatSessionForAIStore()
    aiChatMessage = "已新建 AI 对话。"
    store.save()
  }

  public func deleteAIChatMessage(
    _ messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) {
    if let draft {
      prepareAIChat(for: draft)
    }

    guard let draftID = store.aiChatDraftID else {
      store.setAIChatMessage("请先选择一篇文章。")
      return
    }

    if store.aiChatDraftID == draftID {
      let originalCount = store.aiChatMessages.count
      let updatedMessages = store.aiChatMessages.filter { $0.id != messageID }
      guard updatedMessages.count < originalCount else {
        store.setAIChatMessage("找不到要删除的 AI 消息。")
        return
      }

      store.setAIChatMessages(updatedMessages)
      cacheCurrentAIChatSessionForAIStore()
      store.setAIChatMessage("已删除 1 条 AI 消息。")
      store.save()
      return
    }

    guard var state = aiChatSessionState(for: draftID) else {
      store.setAIChatMessage("找不到要删除的 AI 消息。")
      return
    }

    let originalCount = state.messages.count
    state.messages = state.messages.filter { $0.id != messageID }
    guard state.messages.count < originalCount else {
      store.setAIChatMessage("找不到要删除的 AI 消息。")
      return
    }

    if state.shouldCache {
      setAIChatSessionState(state, for: draftID)
    } else {
      removeAIChatSessionState(for: draftID)
    }

    store.setAIChatMessage("已删除 1 条 AI 消息。")
    store.save()
  }

  public func branchAIChatConversation(
    after messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) {
    if let draft {
      prepareAIChat(for: draft)
    }

    guard store.aiChatDraftID != nil else {
      store.setAIChatMessage("请先选择一篇文章。")
      return
    }
    guard let index = store.aiChatMessages.firstIndex(where: { $0.id == messageID }) else {
      store.setAIChatMessage("找不到要分支的 AI 消息。")
      return
    }

    let originalMessages = store.aiChatMessages
    let branchedMessages = Array(originalMessages.prefix(index + 1))
    guard branchedMessages.count < originalMessages.count else {
      store.setAIChatMessage("已在最新消息处，无需回退分支。")
      return
    }

    store.setAIChatMessages(branchedMessages)
    cacheCurrentAIChatSessionForAIStore()
    store.setAIChatMessage("已从所选消息创建分支。")
    store.save()
  }

  public func cancelAIChatReply() {
    _ = requestAIChatCancellation()
  }

  @discardableResult
  public func retryLastFailedAIChatReply(
    confirmingPossibleDuplicateCharge: Bool = false,
    draft: ArticleDraft? = nil
  ) async -> AIPublishingChatMessage? {
    guard let retryState = aiChatManualRetryState else {
      store.setAIChatMessage("当前没有可重试的 AI 请求。")
      return nil
    }
    guard let chatDraft = draft ?? store.selectedDraft,
          chatDraft.id == retryState.draftID else {
      store.setAIChatMessage("请先返回发生错误的文章，再重试 AI 回复。")
      return nil
    }
    if let retryAfter = retryState.retryAfter, retryAfter > Date() {
      let remainingSeconds = max(1, Int(ceil(retryAfter.timeIntervalSinceNow)))
      store.setAIChatMessage("服务器要求稍后重试，请等待约 \(remainingSeconds) 秒。")
      return nil
    }
    if retryState.requiresDuplicateChargeConfirmation,
       !confirmingPossibleDuplicateCharge {
      store.setAIChatMessage("已保留部分回复。再次生成可能产生重复内容和费用，请确认后手动重新生成。")
      return nil
    }

    aiChatManualRetryState = nil
    return await regenerateLastAIChatReply(draft: chatDraft)
  }

  @discardableResult
  public func regenerateLastAIChatReply(
    draft: ArticleDraft? = nil
  ) async -> AIPublishingChatMessage? {
    guard store.canUseProtectedWorkbench else {
      store.setAIChatMessage(aiChatPrivacyLockedOperationMessage())
      return nil
    }

    guard let chatDraft = draft ?? store.selectedDraft else {
      store.setAIChatMessage("请先选择一篇文章。")
      return nil
    }
    guard store.aiChatDraftID == chatDraft.id else {
      prepareAIChat(for: chatDraft)
      store.setAIChatMessage("当前文章还没有可重新生成的 AI 回复。")
      return nil
    }
    guard store.aiChatMessages.contains(where: { $0.role == .user }) else {
      store.setAIChatMessage("当前对话还没有用户消息。")
      return nil
    }
    let access = aiChatCanStartFeatureUse(.aiRequest)
    guard access.isAllowed else {
      store.setAIChatMessage(access.message)
      return nil
    }
    guard let operationID = beginAIChatOperation(
      statusMessage: "AI 正在重新生成回复..."
    ) else {
      return nil
    }

    let originalMessages = store.aiChatMessages
    var updatedMessages = aiChatMessages
    while updatedMessages.last?.role == .assistant {
      updatedMessages.removeLast()
    }
    aiChatMessages = updatedMessages
    cacheCurrentAIChatSessionForAIStore()

    let reply = await generateAIChatReply(for: chatDraft, operationID: operationID)
    if reply == nil {
      store.setAIChatMessages(originalMessages)
      cacheCurrentAIChatSessionForAIStore()
      store.save()
    }
    return reply
  }

  @discardableResult
  public func regenerateAIChatReply(
    messageID: AIPublishingChatMessage.ID,
    draft: ArticleDraft? = nil
  ) async -> AIPublishingChatMessage? {
    guard store.canUseProtectedWorkbench else {
      store.setAIChatMessage(aiChatPrivacyLockedOperationMessage())
      return nil
    }

    guard let chatDraft = draft ?? store.selectedDraft else {
      store.setAIChatMessage("请先选择一篇文章。")
      return nil
    }
    guard store.aiChatDraftID == chatDraft.id else {
      prepareAIChat(for: chatDraft)
      store.setAIChatMessage("当前文章还没有可重新生成的 AI 回复。")
      return nil
    }
    guard let assistantIndex = store.aiChatMessages.firstIndex(where: { $0.id == messageID && $0.role == .assistant }) else {
      store.setAIChatMessage("找不到可重新生成的 AI 回复。")
      return nil
    }
    guard let userIndex = store.aiChatMessages[..<assistantIndex].lastIndex(where: { $0.role == .user }) else {
      store.setAIChatMessage("找不到可重新生成的用户问题。")
      return nil
    }
    let access = aiChatCanStartFeatureUse(.aiRequest)
    guard access.isAllowed else {
      store.setAIChatMessage(access.message)
      return nil
    }
    guard let operationID = beginAIChatOperation(
      statusMessage: "AI 正在重新生成此回复..."
    ) else {
      return nil
    }

    let originalMessages = store.aiChatMessages
    store.setAIChatMessages(Array(store.aiChatMessages.prefix(userIndex + 1)))
    cacheCurrentAIChatSessionForAIStore()
    let reply = await generateAIChatReply(for: chatDraft, operationID: operationID)
    if reply == nil {
      store.setAIChatMessages(originalMessages)
      cacheCurrentAIChatSessionForAIStore()
      store.save()
    }
    return reply
  }

  @discardableResult
  public func sendAIChatMessage(
    _ text: String,
    draft: ArticleDraft? = nil,
    imageAttachments: [AIChatImageAttachment] = []
  ) async -> AIPublishingChatMessage? {
    guard store.canUseProtectedWorkbench else {
      store.setAIChatMessage(aiChatPrivacyLockedOperationMessage())
      return nil
    }

    let trimmed = text.trimmedForPublishing
    guard !trimmed.isEmpty || !imageAttachments.isEmpty else {
      store.setAIChatMessage("请先输入要发送给 AI 的内容。")
      return nil
    }
    let selectedImageAttachments = Array(
      imageAttachments.prefix(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount)
    )
    guard selectedImageAttachments.allSatisfy({ attachment in
      AIPublishingChatImageAttachmentPresentation.isSupportedAttachment(
        mimeType: attachment.mimeType,
        byteSize: Int64(attachment.data.count)
      )
    }) else {
      store.setAIChatMessage(
        "图片附件仅支持 PNG、JPEG、GIF 或 WebP，且每张不能超过 \(AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText())。"
      )
      return nil
    }
    guard let chatDraft = draft ?? store.selectedDraft else {
      store.setAIChatMessage("请先选择一篇文章。")
      return nil
    }

    let profile = store.profile(for: chatDraft)
    guard imageAttachments.isEmpty || profile.aiProviderConfig.supportsImageInput else {
      store.setAIChatMessage("\(profile.aiProviderConfig.normalizedDisplayName) 当前接口不支持图片输入，请切换到支持视觉输入的 OpenAI-compatible 模型。")
      return nil
    }

    let access = aiChatCanStartFeatureUse(.aiRequest)
    guard access.isAllowed else {
      store.setAIChatMessage(access.message)
      return nil
    }

    do {
      _ = try aiChatAvailableAPIKey(for: profile)
    } catch {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    }
    guard let operationID = beginAIChatOperation(
      statusMessage: "AI 正在结合当前文章回复..."
    ) else {
      return nil
    }

    prepareAIChat(for: chatDraft)

    let userMessage = AIPublishingChatMessage(
      role: .user,
      content: trimmed,
      contextMode: store.aiChatContextMode,
      imageAttachments: selectedImageAttachments
    )
    var updatedMessages = aiChatMessages
    updatedMessages.append(userMessage)
    aiChatMessages = updatedMessages
    cacheCurrentAIChatSessionForAIStore()

    return await generateAIChatReply(for: chatDraft, operationID: operationID)
  }

  @discardableResult
  func generateAIChatReply(
    for chatDraft: ArticleDraft,
    operationID: UUID
  ) async -> AIPublishingChatMessage? {
    defer { finishAIChatOperation(operationID) }
    let profile = store.profile(for: chatDraft)
    let token: String?
    do {
      token = try aiChatAvailableAPIKey(for: profile)
    } catch {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    }
    let request = await aiChatRequest(for: chatDraft)
    await store.refreshSiteMaintenanceSnapshot()
    do {
      try checkAIChatOperation(operationID)
    } catch {
      store.setAIChatMessage("AI 回复已停止。")
      return nil
    }
    let access = aiChatConsumeFeatureUse(.aiRequest)
    guard access.isAllowed else {
      store.setAIChatMessage(access.message)
      return nil
    }

    do {
      do {
        return try await generateStreamingAIChatReply(
          request: request,
          draftID: chatDraft.id,
          operationID: operationID,
          config: profile.aiProviderConfig,
          apiKey: token
        )
      } catch AIChatCompletionClientError.streamingUnsupported {
        return try await generateCompleteAIChatReply(
          request: request,
          draftID: chatDraft.id,
          operationID: operationID,
          config: profile.aiProviderConfig,
          apiKey: token
        )
      }
    } catch is CancellationError {
      store.setAIChatMessage("AI 回复已停止。")
      return aiChatSessionState(for: chatDraft.id)?.messages.last { $0.role == .assistant }
    } catch let error as AIChatCompletionClientError {
      configureManualRetry(for: error, draftID: chatDraft.id)
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      if error.didReceivePartialContent {
        return aiChatSessionState(for: chatDraft.id)?.messages.last { $0.role == .assistant }
      }
      return nil
    } catch {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    }
  }

  func generateStreamingAIChatReply(
    request: AIPublishingChatRequest,
    draftID: UUID,
    operationID: UUID,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let replyStream = try await aiPublishingAssistantService.streamReply(
      to: request,
      config: config,
      apiKey: apiKey
    )
    try checkAIChatOperation(operationID)
    var assistantMessage = replyStream.initialMessage
    updateAIChatSession(for: draftID) { messages in
      messages.append(assistantMessage)
    }
    let clock = ContinuousClock()
    var pendingContent = ""
    var pendingTokenUsage: AIChatTokenUsage?
    var nextPublishAt = clock.now.advanced(by: aiChatStreamPublishInterval)

    func flushPendingStreamUpdate(force: Bool = false) {
      guard !pendingContent.isEmpty || pendingTokenUsage != nil else { return }
      guard force || clock.now >= nextPublishAt else { return }

      assistantMessage.content += pendingContent
      pendingContent = ""
      if let tokenUsage = pendingTokenUsage {
        assistantMessage.tokenUsage = tokenUsage
        pendingTokenUsage = nil
      }
      updateAIChatSession(for: draftID) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      nextPublishAt = clock.now.advanced(by: aiChatStreamPublishInterval)
    }

    do {
      for try await update in replyStream.updates {
        try checkAIChatOperation(operationID)
        if !update.contentDelta.isEmpty {
          pendingContent += update.contentDelta
        }
        if let tokenUsage = update.tokenUsage {
          pendingTokenUsage = tokenUsage
        }
        flushPendingStreamUpdate(force: update.isFinished)
        if update.isFinished {
          break
        }
      }

      try checkAIChatOperation(operationID)

      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else {
        throw AIChatCompletionClientError.emptyContent
      }
      assistantMessage.content = finalContent
      updateAIChatSession(for: draftID) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      recordAIResponseBacklinks(message: assistantMessage, request: request)
      store.setAIChatMessage("AI 已回复。")
      return assistantMessage
    } catch is CancellationError {
      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else {
        updateAIChatSession(for: draftID) { messages in
          messages.removeAll { $0.id == assistantMessage.id }
        }
        throw CancellationError()
      }
      assistantMessage.content = finalContent
      updateAIChatSession(for: draftID) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      recordAIResponseBacklinks(message: assistantMessage, request: request)
      store.setAIChatMessage("AI 回复已停止。")
      return assistantMessage
    } catch let error as AIChatCompletionClientError where error.didReceivePartialContent {
      flushPendingStreamUpdate(force: true)
      let finalContent = assistantMessage.content.trimmedForPublishing
      guard !finalContent.isEmpty else {
        updateAIChatSession(for: draftID) { messages in
          messages.removeAll { $0.id == assistantMessage.id }
        }
        throw error
      }
      assistantMessage.content = finalContent
      updateAIChatSession(for: draftID) { messages in
        if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
          messages[index] = assistantMessage
        }
      }
      recordAIResponseBacklinks(message: assistantMessage, request: request)
      throw error
    } catch {
      updateAIChatSession(for: draftID) { messages in
        messages.removeAll { $0.id == assistantMessage.id }
      }
      throw error
    }
  }

  func generateCompleteAIChatReply(
    request: AIPublishingChatRequest,
    draftID: UUID,
    operationID: UUID,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let assistantMessage = try await aiPublishingAssistantService.reply(
      to: request,
      config: config,
      apiKey: apiKey
    )
    try checkAIChatOperation(operationID)
    updateAIChatSession(for: draftID) { messages in
      messages.append(assistantMessage)
    }
    recordAIResponseBacklinks(message: assistantMessage, request: request)
    store.setAIChatMessage("AI 已回复。")
    return assistantMessage
  }

  private func recordAIResponseBacklinks(
    message: AIPublishingChatMessage,
    request: AIPublishingChatRequest
  ) {
    guard !message.knowledgeCitations.isEmpty else { return }
    store.knowledge.recordBacklinks(
      citations: message.knowledgeCitations,
      target: KnowledgeBacklinkTarget(
        kind: .aiResponse,
        id: message.id.uuidString,
        title: "AI 回复：\(request.draft.title)",
        location: message.createdAt.formatted(date: .abbreviated, time: .shortened)
      )
    )
  }

  private func configureManualRetry(
    for error: AIChatCompletionClientError,
    draftID: UUID
  ) {
    guard error.supportsManualRetry else {
      aiChatManualRetryState = nil
      return
    }
    aiChatManualRetryState = AIChatManualRetryState(
      draftID: draftID,
      requiresDuplicateChargeConfirmation: error.didReceivePartialContent,
      retryAfter: error.retryAfterSeconds.map { Date().addingTimeInterval($0) }
    )
  }

  @discardableResult
  public func openAIChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    if let draftID {
      guard store.focusDraft(draftID, section: .writing) else {
        return false
      }
    } else if store.selectedDraftID == nil {
      _ = store.ensureEditableDraftSelected()
    }

    store.selectSection(.writing)
    store.setInspectorPresented(true)
    isAIPublishingAssistantPresented = true

    if let draft = store.selectedDraft {
      pendingAIQuickPrompt = quickPrompt
      prepareAIChat(for: draft)
      return true
    }
    pendingAIQuickPrompt = nil
    return false
  }

  public func consumePendingAIQuickPrompt() -> AIPublishingQuickPrompt? {
    let prompt = pendingAIQuickPrompt
    pendingAIQuickPrompt = nil
    return prompt
  }

  public func focusedAIChatParagraph(for draft: ArticleDraft) -> AIPublishingChatDraftParagraph? {
    guard let focusedID = aiChatFocusedParagraphID?.nilIfEmpty else { return nil }
    return AIPublishingChatDraftParagraphParser.extract(from: draft.bodyMarkdown).first { $0.id == focusedID }
  }

  public func showAIPublishingAssistant(for draftID: UUID? = nil) {
    _ = openAIChatWorkspace(for: draftID)
  }

  public func hideAIPublishingAssistant() {
    isAIPublishingAssistantPresented = false
  }

  @discardableResult
  public func applyAIMetadataSuggestion(
    field: AIPublishingMetadataField,
    value: String,
    draft: ArticleDraft
  ) -> ArticleDraft? {
    let suggestion: AIPublishingMetadataSuggestion
    switch field {
    case .title:
      suggestion = AIPublishingMetadataSuggestion(titles: [value])
    case .slug:
      suggestion = AIPublishingMetadataSuggestion(slugs: [value])
    case .summary:
      suggestion = AIPublishingMetadataSuggestion(summary: value)
    case .tags:
      suggestion = AIPublishingMetadataSuggestion(tags: AIPublishingMetadataSuggestionParser.parseTagCandidates(value))
    }
    guard let updated = applyAIMetadataSuggestion(suggestion, draft: draft) else {
      if value.trimmedForPublishing.isEmpty {
        aiActionMessage = "AI \(field.displayName)建议为空，未应用。"
      }
      return nil
    }
    aiActionMessage = "已应用 AI \(field.displayName)建议。"
    return updated
  }

  @discardableResult
  public func applyAIMetadataSuggestion(
    _ suggestion: AIPublishingMetadataSuggestion,
    draft: ArticleDraft
  ) -> ArticleDraft? {
    var updated = draft
    var fields: [AIPublishingMetadataField] = []
    var previousTitle: String?
    var newTitle: String?
    var previousSlug: String?
    var newSlug: String?
    var previousSummary: String?
    var newSummary: String?
    var previousTags: [String]?
    var newTags: [String]?

    if let title = suggestion.titles.first?.trimmedForPublishing.nilIfEmpty,
       title != updated.title {
      previousTitle = updated.title
      newTitle = title
      updated.title = title
      fields.append(.title)
    }
    if let rawSlug = suggestion.slugs.first?.trimmedForPublishing.nilIfEmpty {
      let slug = SlugService.slug(
        from: rawSlug
          .replacingOccurrences(of: ".markdown", with: "")
          .replacingOccurrences(of: ".md", with: "")
      )
      if !slug.isEmpty, slug != updated.slug {
        previousSlug = updated.slug
        newSlug = slug
        updated.slug = slug
        fields.append(.slug)
      }
    }
    if let rawSummary = suggestion.summary {
      let summary = rawSummary.trimmedForPublishing
      if !summary.isEmpty, summary != updated.summary {
        previousSummary = updated.summary
        newSummary = summary
        updated.summary = summary
        fields.append(.summary)
      }
    }
    let tags = suggestion.tags.isEmpty
      ? []
      : AIPublishingMetadataSuggestionParser.parseTagCandidates(suggestion.tags.joined(separator: "\n"))
    if !tags.isEmpty, tags != updated.tags {
      previousTags = updated.tags
      newTags = tags
      updated.tags = tags
      fields.append(.tags)
    }

    guard !fields.isEmpty else {
      if suggestion.summary?.trimmedForPublishing.isEmpty == true,
         suggestion.titles.isEmpty,
         suggestion.slugs.isEmpty,
         suggestion.tags.isEmpty {
        aiActionMessage = "AI 摘要建议为空，未应用。"
      } else {
        aiActionMessage = "AI 元数据建议没有可应用的新内容。"
      }
      return nil
    }

    updated.updatedAt = Date()
    store.updateDraft(updated)
    aiMetadataSuggestionDraftID = updated.id
    aiMetadataSuggestion = nil
    aiMetadataApplicationRecords.insert(
      AIPublishingMetadataApplicationRecord(
        siteProfileID: updated.siteProfileID,
        draftID: updated.id,
        draftTitle: updated.title,
        fields: fields,
        previousTitle: previousTitle,
        newTitle: newTitle,
        previousSlug: previousSlug,
        newSlug: newSlug,
        previousSummary: previousSummary,
        newSummary: newSummary,
        previousTags: previousTags,
        newTags: newTags
      ),
      at: 0
    )
    aiActionMessage = "已应用 AI 元数据建议：\(fields.map(\.displayName).joined(separator: "、"))。"
    refreshSEOSocialPreview(
      for: updated,
      message: "AI 元数据变更后，SEO 社交预览已同步刷新。"
    )
    store.save()
    return updated
  }

  public func recentAIMetadataApplicationRecords(
    for draft: ArticleDraft,
    limit: Int = 10
  ) -> [AIPublishingMetadataApplicationRecord] {
    Array(
      aiMetadataApplicationRecords
        .filter { $0.draftID == draft.id }
        .sorted { $0.createdAt > $1.createdAt }
        .prefix(max(0, limit))
    )
  }

  @discardableResult
  public func rollbackAIMetadataApplicationRecord(
    _ record: AIPublishingMetadataApplicationRecord
  ) -> ArticleDraft? {
    guard var draft = store.drafts.first(where: { $0.id == record.draftID }) else {
      aiActionMessage = "找不到要回滚的文章。"
      return nil
    }
    guard canRollbackAIMetadataApplicationRecord(record, draft: draft) else {
      aiActionMessage = "AI 元数据应用记录已不匹配，跳过回滚。"
      return nil
    }
    if record.fields.contains(.title), let previousTitle = record.previousTitle {
      draft.title = previousTitle
    }
    if record.fields.contains(.slug), let previousSlug = record.previousSlug {
      draft.slug = previousSlug
    }
    if record.fields.contains(.summary), let previousSummary = record.previousSummary {
      draft.summary = previousSummary
    }
    if record.fields.contains(.tags), let previousTags = record.previousTags {
      draft.tags = previousTags
    }
    draft.updatedAt = Date()
    store.updateDraft(draft)
    refreshSEOSocialPreview(
      for: draft,
      message: "AI 元数据回滚后，SEO 社交预览已同步刷新。"
    )
    aiActionMessage = "已回滚 AI 元数据应用：\(record.fields.map(\.displayName).joined(separator: "、"))。"
    store.save()
    return draft
  }

  @discardableResult
  public func rollbackAIMetadataApplicationRecords(
    _ records: [AIPublishingMetadataApplicationRecord]
  ) -> AIPublishingMetadataApplicationBatchRollbackResult {
    var restoredCount = 0
    var skippedCount = 0
    var failures: [AIPublishingMetadataApplicationRollbackFailure] = []
    for record in records {
      if rollbackAIMetadataApplicationRecord(record) != nil {
        restoredCount += 1
      } else if store.drafts.contains(where: { $0.id == record.draftID }) {
        skippedCount += 1
      } else {
        failures.append(
          AIPublishingMetadataApplicationRollbackFailure(
            recordID: record.id,
            draftTitle: record.draftTitle,
            message: "找不到要回滚的文章。"
          )
        )
      }
    }
    let result = AIPublishingMetadataApplicationBatchRollbackResult(
      requestedCount: records.count,
      restoredCount: restoredCount,
      skippedCount: skippedCount,
      failures: failures
    )
    aiActionMessage = "AI 元数据批量回滚完成：恢复 \(restoredCount) 条，跳过 \(skippedCount) 条，失败 \(failures.count) 条。"
    store.save()
    return result
  }

  public func clearAIMetadataApplicationRecords(for draft: ArticleDraft) {
    aiMetadataApplicationRecords.removeAll { $0.draftID == draft.id }
    aiActionMessage = "已清空当前文章的 AI 应用记录。"
    store.save()
  }

  private func canRollbackAIMetadataApplicationRecord(
    _ record: AIPublishingMetadataApplicationRecord,
    draft: ArticleDraft
  ) -> Bool {
    if record.fields.contains(.title), record.newTitle != draft.title { return false }
    if record.fields.contains(.slug), record.newSlug != draft.slug { return false }
    if record.fields.contains(.summary), record.newSummary != draft.summary { return false }
    if record.fields.contains(.tags), record.newTags != draft.tags { return false }
    return true
  }

  @discardableResult
  public func performAIAction(
    _ kind: AIPublishingActionKind,
    draft: ArticleDraft,
    selectedText: String? = nil
  ) async -> AIPublishingActionResult? {
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.privacyLockedOperationMessage
      return nil
    }
    let profile = store.profile(for: draft)
    do {
      let token = try aiChatAvailableAPIKey(for: profile)
      let access = store.consumeFeatureUse(.aiRequest)
      guard access.isAllowed else {
        aiActionMessage = access.message
        return nil
      }
      isAIActionRunning = true
      defer { isAIActionRunning = false }
      let artifacts = await store.aiPublishingRequestArtifacts(for: draft)
      let knowledgeContext = await store.knowledge.context(
        query: knowledgeQuery(
          draft: artifacts.draft,
          selectedText: selectedText,
          instruction: kind.displayName
        ),
        policy: aiChatKnowledgePolicy
      )
      let request = AIPublishingActionRequest(
        kind: kind,
        draft: artifacts.draft,
        profile: artifacts.profile,
        selectedText: selectedText,
        preflightIssues: artifacts.preflightIssues,
        publishPackage: artifacts.publishPackage,
        remoteReviewDraft: artifacts.remoteReviewDraft,
        workflowContext: artifacts.workflowContext,
        knowledgeContext: knowledgeContext
      )
      let result = try await aiPublishingAssistantService.perform(
        request,
        config: profile.aiProviderConfig,
        apiKey: token
      )
      aiActionResult = result
      if let suggestion = AIPublishingMetadataActionSuggestionFactory.suggestion(from: result) {
        aiMetadataSuggestionDraftID = draft.id
        aiMetadataSuggestion = suggestion
      }
      aiActionMessage = "\(kind.displayName)完成。"
      return result
    } catch {
      aiActionMessage = "\(kind.displayName)失败：\(error.localizedDescription)"
      return nil
    }
  }

  @discardableResult
  public func generateAIMetadataSuggestions(
    draft: ArticleDraft
  ) async -> AIPublishingMetadataSuggestion? {
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.privacyLockedOperationMessage
      return nil
    }
    let profile = store.profile(for: draft)
    do {
      let token = try aiChatAvailableAPIKey(for: profile)
      let access = store.consumeFeatureUse(.aiRequest)
      guard access.isAllowed else {
        aiActionMessage = access.message
        return nil
      }
      isAIMetadataSuggestionRunning = true
      defer { isAIMetadataSuggestionRunning = false }
      let artifacts = await store.aiPublishingRequestArtifacts(for: draft)
      let knowledgeContext = await store.knowledge.context(
        query: knowledgeQuery(draft: artifacts.draft, instruction: "标题 摘要 标签 元数据"),
        policy: aiChatKnowledgePolicy
      )
      let request = AIPublishingActionRequest(
        kind: .draftFrontMatterPack,
        draft: artifacts.draft,
        profile: artifacts.profile,
        preflightIssues: artifacts.preflightIssues,
        publishPackage: artifacts.publishPackage,
        remoteReviewDraft: artifacts.remoteReviewDraft,
        workflowContext: artifacts.workflowContext,
        knowledgeContext: knowledgeContext
      )
      let suggestion = try await aiPublishingAssistantService.suggestMetadata(
        for: request,
        config: profile.aiProviderConfig,
        apiKey: token
      )
      aiMetadataSuggestionDraftID = draft.id
      aiMetadataSuggestion = suggestion
      aiActionMessage = "AI 元数据建议已生成。"
      return suggestion
    } catch {
      aiActionMessage = "AI 元数据建议生成失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func prepareAIImageTextSuggestions(for draft: ArticleDraft) {
    if aiImageTextSuggestionDraftID != draft.id {
      aiImageTextSuggestionDraftID = draft.id
      aiImageTextSuggestions = []
    }
  }

  @discardableResult
  public func generateAIImageTextSuggestions(draft: ArticleDraft) async -> [AIPublishingImageTextSuggestion] {
    guard store.canUseProtectedWorkbench else {
      aiActionMessage = store.privacyLockedOperationMessage
      store.setImageActionMessage(store.privacyLockedOperationMessage)
      return []
    }
    let profile = store.profile(for: draft)
    let report = store.imageWorkbenchReport(for: draft)
    let targets = imageWorkbenchService.imageTextTargets(draft: draft, profile: profile, report: report)
    guard !targets.isEmpty else {
      aiActionMessage = "当前文章没有需要补全 alt/caption 的图片。"
      store.setImageActionMessage(aiActionMessage)
      return []
    }
    do {
      let token = try aiChatAvailableAPIKey(for: profile)
      isAIImageTextRunning = true
      defer { isAIImageTextRunning = false }
      let suggestions = try await aiPublishingAssistantService.suggestImageText(
        for: targets,
        profile: profile,
        config: profile.aiProviderConfig,
        apiKey: token
      )
      aiImageTextSuggestionDraftID = draft.id
      aiImageTextSuggestions = suggestions
      aiActionMessage = "已生成 \(suggestions.count) 条图片文案建议。"
      store.setImageActionMessage(aiActionMessage)
      return suggestions
    } catch {
      aiActionMessage = "图片文案生成失败：\(error.localizedDescription)"
      store.setImageActionMessage(aiActionMessage)
      return []
    }
  }

  public func applyAIImageTextSuggestion(_ suggestion: AIPublishingImageTextSuggestion) {
    applyAIImageTextSuggestions([suggestion])
  }

  public func applyAIImageTextSuggestions(_ suggestions: [AIPublishingImageTextSuggestion]) {
    guard let draftID = suggestions.first?.draftID,
          let draft = store.drafts.first(where: { $0.id == draftID }) else {
      aiActionMessage = "找不到要应用图片文案的文章。"
      return
    }
    let result = imageWorkbenchService.applyImageTextSuggestions(suggestions, to: draft)
    store.updateDraft(result.draft)
    aiImageTextSuggestions.removeAll { suggestion in
      suggestions.contains { $0.id == suggestion.id }
    }
    aiActionMessage = "已应用图片文案：alt \(result.appliedAltTextCount) 条，caption \(result.appliedCaptionCount) 条。"
  }

  public func clearAIImageTextSuggestions() {
    aiImageTextSuggestionDraftID = nil
    aiImageTextSuggestions = []
    aiActionMessage = "已清空图片文案建议。"
  }

  @discardableResult
  public func sendMaintenanceActionToAI(_ item: MaintenanceActionItem) async -> AIPublishingChatMessage? {
    guard let draft = item.draftID.flatMap({ id in store.drafts.first(where: { $0.id == id }) }) ?? store.selectedDraft else {
      aiChatMessage = "找不到维护行动对应的文章。"
      return nil
    }
    guard openAIChatWorkspace(for: draft.id) else { return nil }
    let prompt = AIPublishingChatPromptTemplateService.maintenanceActionPrompt(
      for: item,
      draft: draft,
      profile: store.profile(for: draft)
    )
    return await sendAIChatMessage(prompt, draft: draft)
  }

  @discardableResult
  public func sendReleaseRecoveryPackageToAI(for entry: ReleaseLedgerEntry) async -> AIPublishingChatMessage? {
    guard let draft = entry.record.draftID.flatMap({ id in store.drafts.first(where: { $0.id == id }) }) ?? store.selectedDraft else {
      aiChatMessage = "找不到发布恢复记录对应的文章。"
      return nil
    }
    guard openAIChatWorkspace(for: draft.id) else { return nil }
    let prompt = AIPublishingChatPromptTemplateService.releaseRecoveryPrompt(
      for: entry,
      package: entry.recoveryPackage,
      draft: draft,
      profile: store.profile(for: draft)
    )
    return await sendAIChatMessage(prompt, draft: draft)
  }

  @discardableResult
  public func sendSEOSocialPreviewToAI(for draft: ArticleDraft? = nil) async -> AIPublishingChatMessage? {
    guard let draft = draft ?? store.selectedDraft else {
      aiChatMessage = "请先选择一篇文章。"
      return nil
    }
    await store.refreshSiteMaintenanceSnapshot()
    prepareSEOSocialPreview(for: draft)
    guard let snapshot = seoSocialPreviewSnapshot(for: draft),
          openAIChatWorkspace(for: draft.id) else {
      return nil
    }
    let prompt = AIPublishingChatPromptTemplateService.seoSocialPreviewPrompt(
      snapshot: snapshot,
      draft: draft,
      profile: store.profile(for: draft),
      relatedSuggestions: store.relatedArticleSuggestions(for: draft)
    )
    return await sendAIChatMessage(prompt, draft: draft)
  }

  public func aiChatImageAttachments(
    for draft: ArticleDraft,
    attachmentIDs: Set<UUID>
  ) async -> [AIChatImageAttachment] {
    let selectedAttachments = Array(
      draft.attachments
      .filter { attachmentIDs.contains($0.id) && $0.mediaKind == .image }
      .prefix(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount)
    )
    let result = await Task.detached(priority: .userInitiated) {
      Self.loadAIChatImageAttachments(selectedAttachments)
    }.value
    guard !Task.isCancelled else { return [] }
    if result.skippedCount > 0 {
      aiChatMessage = "已跳过 \(result.skippedCount) 个无法读取、格式不支持或超过 \(AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText()) 的图片附件。"
    }
    return result.images
  }

  private nonisolated static func loadAIChatImageAttachments(
    _ attachments: [DraftAttachment]
  ) -> (images: [AIChatImageAttachment], skippedCount: Int) {
    var images: [AIChatImageAttachment] = []
    images.reserveCapacity(attachments.count)
    for attachment in attachments {
      guard let path = attachment.sourceFilePath?.nilIfEmpty else { continue }
      let url = URL(fileURLWithPath: path)
      let mimeType = mimeType(for: url)
      guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
            values.isRegularFile == true,
            let fileSize = values.fileSize,
            AIPublishingChatImageAttachmentPresentation.isSupportedAttachment(
              mimeType: mimeType,
              byteSize: Int64(fileSize)
            ),
            let data = try? Data(contentsOf: url, options: .mappedIfSafe),
            AIPublishingChatImageAttachmentPresentation.isSupportedAttachment(
              mimeType: mimeType,
              byteSize: Int64(data.count)
            ) else {
        continue
      }
      images.append(
        AIChatImageAttachment(
          filename: attachment.originalFilename,
          mimeType: mimeType,
          data: data
        )
      )
    }
    return (images, attachments.count - images.count)
  }

  private nonisolated static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "webp": return "image/webp"
    case "gif": return "image/gif"
    case "svg": return "image/svg+xml"
    case "avif": return "image/avif"
    case "heic": return "image/heic"
    case "tif", "tiff": return "image/tiff"
    default: return "application/octet-stream"
    }
  }
}
