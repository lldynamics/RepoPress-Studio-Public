import Combine
import Foundation

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
  private var aiChatSessionsByDraftID: [UUID: AIPublishingChatSessionState] = [:]
  private var isAIChatCancellationRequested = false

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

  public var aiChatModelGrade: AIChatModelGrade {
    get { workspace.aiChatModelGrade }
    set { workspace.aiChatModelGrade = newValue }
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
    aiTokenAvailability = (try? keychainTokenStore.availability(for: store.activeProfile)) ?? KeychainTokenAvailability(hasToken: false)
  }

  public func saveAIAPIKey(_ token: String) {
    do {
      try keychainTokenStore.saveToken(token.trimmedForPublishing, for: store.activeProfile)
      refreshAIKeyAvailability()
      aiActionMessage = "AI API Key 已保存到 Keychain。"
    } catch {
      aiActionMessage = "AI API Key 保存失败：\(error.localizedDescription)"
    }
  }

  public func deleteAIAPIKey() {
    do {
      try keychainTokenStore.deleteToken(for: store.activeProfile)
      refreshAIKeyAvailability()
      aiActionMessage = "AI API Key 已删除。"
    } catch {
      aiActionMessage = "AI API Key 删除失败：\(error.localizedDescription)"
    }
  }

  public func testAIConnection() async -> AIConnectionTestReport? {
    isAIActionRunning = true
    defer { isAIActionRunning = false }
    do {
      let token = try aiChatAvailableAPIKey(for: store.activeProfile)
      let report = try await aiConnectionTestService.testConnection(config: store.activeProfile.aiProviderConfig, apiKey: token)
      aiActionMessage = report.headline
      return report
    } catch {
      aiActionMessage = "AI 连接测试失败：\(error.localizedDescription)"
      return nil
    }
  }

  func replaceAIChatSessions(_ sessions: [UUID: AIPublishingChatSessionState]) {
    aiChatSessionsByDraftID = sessions
  }

  func aiChatSessionsForPersistence() -> [UUID: AIPublishingChatSessionState] {
    if let draftID = aiChatDraftID {
      persistCurrentAIChatSession(for: draftID)
    }
    return aiChatSessionsByDraftID
  }

  public func prepareAIChat(for draft: ArticleDraft) {
    if aiChatDraftID == draft.id {
      return
    }
    if let currentDraftID = aiChatDraftID {
      persistCurrentAIChatSession(for: currentDraftID)
    }
    let state = aiChatSessionsByDraftID[draft.id] ?? AIPublishingChatSessionState()
    aiChatDraftID = draft.id
    aiChatConversationTitle = state.conversationTitle
    aiChatMessages = state.messages
    aiChatContextMode = state.contextMode
    aiChatModelGrade = state.modelGrade
    aiChatSelectedModel = state.selectedModel
    aiChatFocusedParagraphID = state.focusedParagraphID
  }

  func aiChatSessionState(for draftID: UUID) -> AIPublishingChatSessionState? {
    if aiChatDraftID == draftID {
      return currentAIChatSessionState()
    }
    return aiChatSessionsByDraftID[draftID]
  }

  func setAIChatSessionState(_ state: AIPublishingChatSessionState, for draftID: UUID) {
    let prepared = state.prepared()
    if prepared.shouldPersist {
      aiChatSessionsByDraftID[draftID] = prepared
    } else {
      aiChatSessionsByDraftID.removeValue(forKey: draftID)
    }
    if aiChatDraftID == draftID {
      aiChatConversationTitle = prepared.conversationTitle
      aiChatMessages = prepared.messages
      aiChatContextMode = prepared.contextMode
      aiChatModelGrade = prepared.modelGrade
      aiChatSelectedModel = prepared.selectedModel
      aiChatFocusedParagraphID = prepared.focusedParagraphID
    }
  }

  func removeAIChatSessionState(for draftID: UUID) {
    aiChatSessionsByDraftID.removeValue(forKey: draftID)
    if aiChatDraftID == draftID {
      aiChatConversationTitle = nil
      aiChatMessages = []
      aiChatFocusedParagraphID = nil
    }
  }

  func persistCurrentAIChatSessionForAIStore() {
    guard let draftID = aiChatDraftID else { return }
    persistCurrentAIChatSession(for: draftID)
  }

  private func persistCurrentAIChatSession(for draftID: UUID) {
    let state = currentAIChatSessionState().prepared()
    if state.shouldPersist {
      aiChatSessionsByDraftID[draftID] = state
    } else {
      aiChatSessionsByDraftID.removeValue(forKey: draftID)
    }
  }

  private func currentAIChatSessionState() -> AIPublishingChatSessionState {
    let archived = aiChatDraftID.flatMap { aiChatSessionsByDraftID[$0]?.archivedConversations } ?? []
    return AIPublishingChatSessionState(
      conversationTitle: aiChatConversationTitle,
      messages: aiChatMessages,
      contextMode: aiChatContextMode,
      modelGrade: aiChatModelGrade,
      selectedModel: aiChatSelectedModel,
      focusedParagraphID: aiChatFocusedParagraphID,
      archivedConversations: archived
    )
  }

  func archivedAIChatConversations(for draftID: UUID) -> [AIPublishingChatArchivedConversation] {
    aiChatSessionState(for: draftID)?.archivedConversations ?? []
  }

  func archiveCurrentAIChatConversationIfNeeded(for draftID: UUID) {
    let state = currentAIChatSessionState().prepared()
    guard !state.messages.isEmpty else { return }
    let title = state.conversationTitle?.nilIfEmpty
      ?? state.messages.first(where: { $0.role == .user })?.content.trimmedForPublishing.nilIfEmpty.map { String($0.prefix(48)) }
      ?? state.messages.first(where: { $0.role == .user })?.imageAttachments.first.map { "已附加图片：\($0.filename)" }
      ?? "未命名对话"
    let archived = AIPublishingChatArchivedConversation(
      title: title,
      messages: state.messages,
      contextMode: state.contextMode,
      modelGrade: state.modelGrade,
      selectedModel: state.selectedModel,
      focusedParagraphID: state.focusedParagraphID
    )
    var stored = aiChatSessionsByDraftID[draftID] ?? AIPublishingChatSessionState()
    stored.archivedConversations.insert(archived, at: 0)
    stored.archivedConversations = Array(stored.archivedConversations.prefix(20))
    aiChatSessionsByDraftID[draftID] = stored.prepared()
  }

  func updateAIChatSession(for draftID: UUID, update: (inout [AIPublishingChatMessage]) -> Void) {
    if aiChatDraftID == draftID {
      update(&aiChatMessages)
      persistCurrentAIChatSession(for: draftID)
      return
    }
    var state = aiChatSessionsByDraftID[draftID] ?? AIPublishingChatSessionState()
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
    guard let token = try keychainTokenStore.token(for: profile)?.nilIfEmpty else {
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
    guard isAIChatRunning else { return false }
    isAIChatCancellationRequested = true
    aiChatMessage = "正在停止 AI 回复..."
    return true
  }

  func aiChatRequest(for draft: ArticleDraft) -> AIPublishingChatRequest {
    let profile = store.profile(for: draft)
    let focusedParagraph = aiChatFocusedParagraphID.flatMap { focusedID in
      AIPublishingChatDraftParagraphParser.extract(from: draft.bodyMarkdown).first { $0.id == focusedID }
    }
    return AIPublishingChatRequest(
      draft: draft,
      profile: profile,
      messages: aiChatMessages,
      contextMode: aiChatContextMode,
      modelGrade: aiChatModelGrade,
      selectedModel: aiChatSelectedModel.nilIfEmpty,
      preflightIssues: store.preflightIssues(for: draft),
      publishPackage: store.publishingPackage(for: draft),
      remoteReviewDraft: store.remoteReviewDraft(for: draft),
      workflowContext: AIPublishingWorkflowContext(
        publishPreview: store.localPublishPreview(for: draft),
        localSitePreviewPlan: store.localSitePreviewPlan(for: draft),
        imageReport: store.imageWorkbenchReport(for: draft)
      ),
      focusedParagraph: focusedParagraph,
      relatedSuggestions: store.relatedArticleSuggestions(for: draft)
    )
  }

  public func setAIChatModelGrade(_ grade: AIChatModelGrade) {
    let config = store.selectedDraft.map { store.profile(for: $0).aiProviderConfig } ?? store.activeProfile.aiProviderConfig
    aiChatModelGrade = grade
    aiChatSelectedModel = AIChatModelCatalog.model(
      for: grade,
      config: config,
      currentModel: aiChatSelectedModel
    )
    persistCurrentAIChatSessionForAIStore()
  }

  public func setAIChatCustomModel(_ model: String) {
    aiChatModelGrade = .custom
    aiChatSelectedModel = model
    persistCurrentAIChatSessionForAIStore()
  }

  public func resetAIChatModelToProfileDefault() {
    setAIChatModelGrade(.standard)
  }

  public var aiChatArchivedConversations: [AIPublishingChatArchivedConversation] {
    guard let draftID = aiChatDraftID else {
      return []
    }
    return archivedAIChatConversations(for: draftID)
  }

  public func clearAIChat() {
    aiChatConversationTitle = nil
    aiChatMessages = []
    persistCurrentAIChatSessionForAIStore()
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
    persistCurrentAIChatSessionForAIStore()
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
    persistCurrentAIChatSessionForAIStore()
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
    guard let draftID = aiChatDraftID else {
      aiChatMessage = "请先选择一篇文章。"
      return
    }
    archiveCurrentAIChatConversationIfNeeded(for: draftID)
    aiChatConversationTitle = nil
    aiChatMessages = []
    persistCurrentAIChatSessionForAIStore()
    aiChatMessage = "已新建 AI 对话。"
    store.save()
  }

  public func restoreArchivedAIChatConversation(
    _ conversationID: AIPublishingChatArchivedConversation.ID,
    draft: ArticleDraft? = nil
  ) {
    if let draft {
      prepareAIChat(for: draft)
    }
    guard let draftID = aiChatDraftID else {
      aiChatMessage = "请先选择一篇文章。"
      return
    }
    guard var state = aiChatSessionState(for: draftID),
          let index = state.archivedConversations.firstIndex(where: { $0.id == conversationID })
    else {
      aiChatMessage = "找不到要恢复的历史对话。"
      return
    }

    let archivedConversation = state.archivedConversations.remove(at: index)
    setAIChatSessionState(state, for: draftID)
    archiveCurrentAIChatConversationIfNeeded(for: draftID)
    aiChatConversationTitle = archivedConversation.title.nilIfEmpty
    aiChatMessages = archivedConversation.messages
    aiChatContextMode = archivedConversation.contextMode
    aiChatModelGrade = archivedConversation.modelGrade
    aiChatSelectedModel = archivedConversation.selectedModel
    aiChatFocusedParagraphID = archivedConversation.focusedParagraphID
    persistCurrentAIChatSessionForAIStore()
    aiChatMessage = "已恢复历史对话：\(archivedConversation.title)"
    store.save()
  }

  public func deleteArchivedAIChatConversation(
    _ conversationID: AIPublishingChatArchivedConversation.ID,
    draft: ArticleDraft? = nil
  ) {
    if let draft {
      prepareAIChat(for: draft)
    }
    guard let draftID = aiChatDraftID else {
      aiChatMessage = "请先选择一篇文章。"
      return
    }
    guard var state = aiChatSessionState(for: draftID),
          let index = state.archivedConversations.firstIndex(where: { $0.id == conversationID })
    else {
      aiChatMessage = "找不到要删除的历史对话。"
      return
    }

    let title = state.archivedConversations[index].title
    state.archivedConversations.remove(at: index)
    if state.shouldPersist {
      setAIChatSessionState(state, for: draftID)
    } else {
      removeAIChatSessionState(for: draftID)
    }
    aiChatMessage = "已删除历史对话：\(title)"
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
      persistCurrentAIChatSessionForAIStore()
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

    if state.shouldPersist {
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

    guard let draftID = store.aiChatDraftID else {
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

    archiveCurrentAIChatConversationIfNeeded(for: draftID)
    store.setAIChatMessages(branchedMessages)
    persistCurrentAIChatSessionForAIStore()
    store.setAIChatMessage("已从所选消息创建分支，原对话已存入历史。")
    store.save()
  }

  public func cancelAIChatReply() {
    _ = requestAIChatCancellation()
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

    let originalMessages = store.aiChatMessages
    var updatedMessages = aiChatMessages
    while updatedMessages.last?.role == .assistant {
      updatedMessages.removeLast()
    }
    aiChatMessages = updatedMessages
    persistCurrentAIChatSessionForAIStore()

    let reply = await generateAIChatReply(for: chatDraft, statusMessage: "AI 正在重新生成回复...")
    if reply == nil {
      store.setAIChatMessages(originalMessages)
      persistCurrentAIChatSessionForAIStore()
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

    let originalMessages = store.aiChatMessages
    store.setAIChatMessages(Array(store.aiChatMessages.prefix(userIndex + 1)))
    persistCurrentAIChatSessionForAIStore()
    let reply = await generateAIChatReply(for: chatDraft, statusMessage: "AI 正在重新生成此回复...")
    if reply == nil {
      store.setAIChatMessages(originalMessages)
      persistCurrentAIChatSessionForAIStore()
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

    prepareAIChat(for: chatDraft)

    let userMessage = AIPublishingChatMessage(
      role: .user,
      content: trimmed,
      contextMode: store.aiChatContextMode,
      imageAttachments: Array(imageAttachments.prefix(4))
    )
    var updatedMessages = aiChatMessages
    updatedMessages.append(userMessage)
    aiChatMessages = updatedMessages
    persistCurrentAIChatSessionForAIStore()

    return await generateAIChatReply(for: chatDraft, statusMessage: "AI 正在结合当前文章回复...")
  }

  @discardableResult
  func generateAIChatReply(
    for chatDraft: ArticleDraft,
    statusMessage: String
  ) async -> AIPublishingChatMessage? {
    let profile = store.profile(for: chatDraft)
    let token: String?
    do {
      token = try aiChatAvailableAPIKey(for: profile)
    } catch {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    }
    let access = aiChatConsumeFeatureUse(.aiRequest)
    guard access.isAllowed else {
      store.setAIChatMessage(access.message)
      return nil
    }

    store.setAIChatRunning(true)
    setAIChatCancellationRequested(false)
    store.setAIChatMessage(statusMessage)
    defer {
      store.setAIChatRunning(false)
      setAIChatCancellationRequested(false)
      store.save()
    }

    do {
      let request = aiChatRequest(for: chatDraft)
      do {
        return try await generateStreamingAIChatReply(
          request: request,
          draftID: chatDraft.id,
          config: profile.aiProviderConfig,
          apiKey: token
        )
      } catch AIChatCompletionClientError.streamingUnsupported {
        return try await generateCompleteAIChatReply(
          request: request,
          draftID: chatDraft.id,
          config: profile.aiProviderConfig,
          apiKey: token
        )
      }
    } catch is CancellationError {
      store.setAIChatMessage("AI 回复已停止。")
      return store.aiChatMessages.last { $0.role == .assistant }
    } catch {
      store.setAIChatMessage("AI 讨论失败：\(error.localizedDescription)")
      return nil
    }
  }

  func generateStreamingAIChatReply(
    request: AIPublishingChatRequest,
    draftID: UUID,
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let replyStream = try await aiPublishingAssistantService.streamReply(
      to: request,
      config: config,
      apiKey: apiKey
    )
    var assistantMessage = replyStream.initialMessage
    updateAIChatSession(for: draftID) { messages in
      messages.append(assistantMessage)
    }

    do {
      for try await update in replyStream.updates {
        try Task.checkCancellation()
        if aiChatCancellationRequested() {
          throw CancellationError()
        }
        if !update.contentDelta.isEmpty {
          assistantMessage.content += update.contentDelta
        }
        if let tokenUsage = update.tokenUsage {
          assistantMessage.tokenUsage = tokenUsage
        }
        updateAIChatSession(for: draftID) { messages in
          if let index = messages.firstIndex(where: { $0.id == assistantMessage.id }) {
            messages[index] = assistantMessage
          }
        }
        if update.isFinished {
          break
        }
      }

      if aiChatCancellationRequested() {
        throw CancellationError()
      }

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
      store.setAIChatMessage("AI 已回复。")
      return assistantMessage
    } catch is CancellationError {
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
      store.setAIChatMessage("AI 回复已停止。")
      return assistantMessage
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
    config: AIProviderConfig,
    apiKey: String?
  ) async throws -> AIPublishingChatMessage {
    let assistantMessage = try await aiPublishingAssistantService.reply(
      to: request,
      config: config,
      apiKey: apiKey
    )
    updateAIChatSession(for: draftID) { messages in
      messages.append(assistantMessage)
    }
    store.setAIChatMessage("AI 已回复。")
    return assistantMessage
  }

  @discardableResult
  public func openAIChatWorkspace(
    for draftID: UUID? = nil,
    quickPrompt: AIPublishingQuickPrompt? = nil
  ) -> Bool {
    if let draftID {
      guard store.focusDraft(draftID, section: .ai) else {
        return false
      }
    } else if store.selectedDraftID == nil {
      _ = store.ensureEditableDraftSelected()
    }

    store.selectSection(.ai)
    store.setInspectorPresented(true)
    isAIPublishingAssistantPresented = false

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
      let request = AIPublishingActionRequest(
        kind: kind,
        draft: draft,
        profile: profile,
        selectedText: selectedText,
        preflightIssues: store.preflightIssues(for: draft),
        publishPackage: store.publishingPackage(for: draft),
        remoteReviewDraft: store.remoteReviewDraft(for: draft),
        workflowContext: AIPublishingWorkflowContext(
          publishPreview: store.localPublishPreview(for: draft),
          localSitePreviewPlan: store.localSitePreviewPlan(for: draft),
          imageReport: store.imageWorkbenchReport(for: draft)
        )
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
      let request = AIPublishingActionRequest(
        kind: .draftFrontMatterPack,
        draft: draft,
        profile: profile,
        preflightIssues: store.preflightIssues(for: draft),
        publishPackage: store.publishingPackage(for: draft),
        remoteReviewDraft: store.remoteReviewDraft(for: draft),
        workflowContext: AIPublishingWorkflowContext(
          publishPreview: store.localPublishPreview(for: draft),
          localSitePreviewPlan: store.localSitePreviewPlan(for: draft),
          imageReport: store.imageWorkbenchReport(for: draft)
        )
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

  public func aiChatImageAttachments(for draft: ArticleDraft, attachmentIDs: Set<UUID>) -> [AIChatImageAttachment] {
    let selectedAttachments = Array(
      draft.attachments
      .filter { attachmentIDs.contains($0.id) }
      .prefix(AIPublishingChatImageAttachmentPresentation.maxSelectedImageCount)
    )
    let images: [AIChatImageAttachment] = selectedAttachments.compactMap { attachment in
        guard let path = attachment.sourceFilePath?.nilIfEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              AIPublishingChatImageAttachmentPresentation.isWithinAttachmentSizeLimit(Int64(data.count)) else {
          return nil
        }
        return AIChatImageAttachment(filename: attachment.originalFilename, mimeType: Self.mimeType(for: url), data: data)
      }
    let skippedCount = selectedAttachments.count - images.count
    if skippedCount > 0 {
      aiChatMessage = "已跳过 \(skippedCount) 个无法读取、格式不支持或超过 \(AIPublishingChatImageAttachmentPresentation.attachmentSizeLimitText()) 的图片附件。"
    }
    return images
  }

  private static func mimeType(for url: URL) -> String {
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
