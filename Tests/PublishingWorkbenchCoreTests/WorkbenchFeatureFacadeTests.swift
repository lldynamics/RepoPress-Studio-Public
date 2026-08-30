import Combine
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchFeatureFacadeTests: XCTestCase {
  func testTaskQueueFilterResolvesLiveBodyFromListSnapshotIDs() {
    let store = makeIsolatedStore(safeMode: true)
    var initial = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "实时检查",
      slug: "live-check",
      bodyMarkdown: String(repeating: "安全正文 ", count: 20)
    )
    store.updateDraft(initial)
    let staleListSnapshot = initial

    initial.bodyMarkdown =
      "This body changed after the list snapshot. api_key = \"sk-12345678901234567890abcd\""
    store.updateDraft(initial)

    let states = store.draftTaskQueueStates(for: [staleListSnapshot])

    XCTAssertEqual(states[initial.id]?.hasPreflightErrors, true)
  }

  private func makeIsolatedStore(safeMode: Bool = false) -> WorkbenchStore {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("workbench-facade-\(UUID().uuidString).json")
    return WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: fileURL),
      safeMode: safeMode
    )
  }

  func testFeatureFacadesExposeStableEntrypoints() {
    let store = makeIsolatedStore()

    XCTAssertTrue(store.ai === store.ai)
    XCTAssertTrue(store.repository === store.repository)
    XCTAssertTrue(store.publishing === store.publishing)
    XCTAssertTrue(store.contentPresentation === store.contentPresentation)
    XCTAssertTrue(store.rootPresentation === store.rootPresentation)
    XCTAssertTrue(store.commandPresentation === store.commandPresentation)
    XCTAssertTrue(store.activityStatus === store.activityStatus)
    XCTAssertTrue(store.workspaceLayout === store.workspaceLayout)
    XCTAssertTrue(store.settings === store.settings)
    XCTAssertTrue(store.publishStatus === store.publishStatus)
    XCTAssertTrue(store.draftList === store.draftList)
    XCTAssertTrue(store.siteMaintenance === store.siteMaintenance)
  }

  func testDraftListStoreIgnoresBodyAutosaveButPublishesDelayedPreflightTaskState() async throws {
    // Keep startup refreshes out of the notification baseline; this test
    // exercises the explicitly scheduled post-autosave preflight below.
    let store = makeIsolatedStore(safeMode: true)
    let draft = try XCTUnwrap(store.selectedDraft)
    let draftList = store.draftList
    // Warm the unrelated site-link audit before observing body-only changes.
    _ = store.draftTaskQueueStates(for: store.drafts)
    if let siteLinkAuditRefreshTask = store.siteLinkAuditRefreshTask {
      _ = await siteLinkAuditRefreshTask.value
    }
    let initialPresentationRevision = draftList.presentationRevision
    let initialTaskQueueStateVersion = draftList.taskQueueStateVersion
    let initialEditorMetadataRevision = draft.editorMetadataRevision
    _ = draftList.searchIndex(for: .activeSite)
    XCTAssertEqual(draftList.searchIndexBuildCount, 1)
    var listChanges = 0
    let cancellable = draftList.objectWillChange.sink { listChanges += 1 }

    let body = "正文 autosave 不应触碰草稿列表缓存。"
    _ = store.stageDraftBody(body, for: draft.id, baseRevision: 0)
    store.flushDraftBodyEditorBuffer(for: draft.id)

    XCTAssertEqual(store.drafts.first(where: { $0.id == draft.id })?.bodyMarkdown, body)
    XCTAssertEqual(
      store.drafts.first(where: { $0.id == draft.id })?.editorMetadataRevision,
      initialEditorMetadataRevision
    )
    XCTAssertEqual(draftList.presentationRevision, initialPresentationRevision)
    XCTAssertEqual(draftList.taskQueueStateVersion, initialTaskQueueStateVersion)
    _ = draftList.searchIndex(for: .activeSite)
    XCTAssertEqual(draftList.searchIndexBuildCount, 1)

    // The normal automatic preflight is delayed by 600ms. It must refresh the
    // list's task-state badges once, without rebuilding presentation/search
    // projections that body autosave deliberately leaves untouched.
    try await Task.sleep(for: .milliseconds(900))
    XCTAssertEqual(draftList.presentationRevision, initialPresentationRevision)
    XCTAssertEqual(draftList.taskQueueStateVersion, initialTaskQueueStateVersion + 1)
    _ = draftList.searchIndex(for: .activeSite)
    XCTAssertEqual(draftList.searchIndexBuildCount, 1)
    XCTAssertEqual(listChanges, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testDraftSearchIndexCachesCorporaAndInvalidatesForMetadataAndPrivacy() throws {
    let store = makeIsolatedStore(safeMode: true)
    store.updatePrivacySettings(PrivacyProtectionSettings(masksPrivateContent: false))
    let draftList = store.draftList
    let privateDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Private title",
      slug: "secret-slug",
      visibility: .private,
      summary: "hidden summary",
      bodyMarkdown: "Body"
    )
    store.setDrafts([privateDraft])

    let activeIndex = draftList.searchIndex(for: .activeSite)
    _ = draftList.searchIndex(for: .activeSite)
    let allIndex = draftList.searchIndex(for: .allDrafts)
    _ = draftList.searchIndex(for: .allDrafts)
    XCTAssertEqual(draftList.searchIndexBuildCount, 2)
    XCTAssertEqual(activeIndex.sourceRevision, allIndex.sourceRevision)

    var changed = privateDraft
    changed.title = "Renamed private title"
    store.updateDraft(changed)
    XCTAssertEqual(
      draftList.searchIndex(for: .activeSite).matching(query: "Renamed").map(\.id),
      [privateDraft.id]
    )
    XCTAssertEqual(draftList.searchIndexBuildCount, 3)

    store.updatePrivacySettings(PrivacyProtectionSettings(masksPrivateContent: true))
    let maskedIndex = draftList.searchIndex(for: .activeSite)
    XCTAssertTrue(maskedIndex.matching(query: "secret-slug").isEmpty)
    XCTAssertEqual(maskedIndex.matching(query: "Private").map(\.id), [privateDraft.id])
    XCTAssertEqual(draftList.searchIndexBuildCount, 4)
  }

  func testAllDraftSearchIndexInvalidatesWhenInactiveProfilePathChanges() {
    let store = makeIsolatedStore(safeMode: true)
    var inactiveProfile = store.activeProfile
    inactiveProfile.id = UUID()
    inactiveProfile.name = "Inactive site"
    inactiveProfile.markdownPathPattern = "content/archive/{slug}.md"
    store.setProfiles([store.activeProfile, inactiveProfile])
    let draft = ArticleDraft(
      siteProfileID: inactiveProfile.id,
      title: "Inactive profile draft",
      slug: "cached-path"
    )
    store.setDrafts([draft])

    let draftList = store.draftList
    XCTAssertEqual(
      draftList.searchIndex(for: .allDrafts).matching(query: "content/archive").map(\.id),
      [draft.id]
    )
    let initialBuildCount = draftList.searchIndexBuildCount

    inactiveProfile.markdownPathPattern = "notes/{slug}.md"
    store.setProfiles([store.activeProfile, inactiveProfile])

    XCTAssertEqual(
      draftList.searchIndex(for: .allDrafts).matching(query: "notes/cached-path").map(\.id),
      [draft.id]
    )
    XCTAssertEqual(draftList.searchIndexBuildCount, initialBuildCount + 1)
  }

  func testDraftListPreflightNotificationKeepsMetadataRequestWhenBodyRequestFollows()
    async throws
  {
    let store = makeIsolatedStore(safeMode: true)
    let draft = try XCTUnwrap(store.selectedDraft)
    let draftList = store.draftList
    let initialTaskQueueStateVersion = draftList.taskQueueStateVersion

    store.schedulePreflightRefresh(for: draft.id, notifyingDraftList: true)
    // A body-only refresh can replace the delayed task, but must not weaken a
    // metadata request that was already queued for the same draft.
    store.schedulePreflightRefresh(for: draft.id, notifyingDraftList: false)
    if let preflightRefreshTask = store.preflightRefreshTask {
      await preflightRefreshTask.value
    }

    XCTAssertGreaterThan(draftList.taskQueueStateVersion, initialTaskQueueStateVersion)
  }

  func testDraftListMetadataEditPublishesAndRebuildsOnlyOnceAcrossDelayedPreflight()
    async throws
  {
    let store = makeIsolatedStore(safeMode: true)
    let draft = try XCTUnwrap(store.selectedDraft)
    let draftList = store.draftList
    // Seed the projection fingerprint outside the assertion window.
    store.setDrafts(store.drafts)
    _ = draftList.searchIndex(for: .activeSite)
    let initialRevision = draftList.presentationRevision
    let initialBuildCount = draftList.searchIndexBuildCount
    var changes = 0
    let cancellable = draftList.objectWillChange.sink { changes += 1 }

    var renamed = draft
    renamed.title = "一次元数据变更"
    store.updateDraft(renamed)

    XCTAssertEqual(draftList.presentationRevision, initialRevision + 1)
    _ = draftList.searchIndex(for: .activeSite)
    XCTAssertEqual(draftList.searchIndexBuildCount, initialBuildCount + 1)

    if let preflightRefreshTask = store.preflightRefreshTask {
      await preflightRefreshTask.value
    }

    XCTAssertEqual(draftList.presentationRevision, initialRevision + 1)
    XCTAssertEqual(changes, 1)
    _ = draftList.searchIndex(for: .activeSite)
    XCTAssertEqual(draftList.searchIndexBuildCount, initialBuildCount + 1)
    withExtendedLifetime(cancellable) {}
  }

  func testDraftListPrivacyMaskSettingsInvalidateItsOwnBoundary() {
    let store = makeIsolatedStore(safeMode: true)
    let draftList = store.draftList
    let initialPresentationRevision = draftList.presentationRevision
    var listChanges = 0
    let cancellable = draftList.objectWillChange.sink { listChanges += 1 }

    store.updatePrivacySettings(
      PrivacyProtectionSettings(
        masksPrivateContent: !store.privacySettings.masksPrivateContent
      )
    )

    XCTAssertGreaterThan(draftList.presentationRevision, initialPresentationRevision)
    XCTAssertGreaterThan(listChanges, 0)
    withExtendedLifetime(cancellable) {}
  }

  func testDraftListIgnoresRepositoryMaterializationAndCASOnlyChanges() throws {
    let store = makeIsolatedStore(safeMode: true)
    let draft = try XCTUnwrap(store.selectedDraft)
    let draftList = store.draftList
    let initialPresentationRevision = draftList.presentationRevision
    let initialTaskQueueStateVersion = draftList.taskQueueStateVersion
    var listChanges = 0
    let cancellable = draftList.objectWillChange.sink { listChanges += 1 }

    var repositoryOnly = draft
    repositoryOnly.repositoryPath = store.activeProfile.markdownPath(for: draft)
    repositoryOnly.repositorySHA = "remote-sha-only"
    repositoryOnly.repositoryImportFingerprint = "remote-fingerprint-only"
    store.updateDraft(repositoryOnly)

    XCTAssertEqual(draftList.presentationRevision, initialPresentationRevision)
    XCTAssertEqual(draftList.taskQueueStateVersion, initialTaskQueueStateVersion)
    XCTAssertEqual(listChanges, 0)
    withExtendedLifetime(cancellable) {}
  }

  func testDraftListAndEditorObserveOnlyTheirRelevantDraftMetadata() throws {
    let store = makeIsolatedStore()
    let trackedDraft = try XCTUnwrap(store.selectedDraft)
    var otherDraft = ArticleDraft.empty(profile: store.activeProfile)
    otherDraft.title = "另一篇文章"
    store.setDrafts([trackedDraft, otherDraft])

    let draftList = store.draftList
    let editor = WorkbenchMarkdownEditorFeatureFacade(
      store: store,
      draftID: trackedDraft.id
    )
    let initialPresentationRevision = draftList.presentationRevision
    var editorChanges = 0
    let editorCancellable = editor.objectWillChange.sink { editorChanges += 1 }

    otherDraft.title = "另一篇文章的新标题"
    otherDraft.categories = ["另一个分类"]
    otherDraft.date = otherDraft.date.addingTimeInterval(60)
    store.updateDraft(otherDraft)

    XCTAssertGreaterThan(draftList.presentationRevision, initialPresentationRevision)
    XCTAssertEqual(editorChanges, 0)

    var currentDraft = try XCTUnwrap(store.draft(for: trackedDraft.id))
    currentDraft.categories = ["当前文章分类"]
    store.updateDraft(currentDraft)
    XCTAssertGreaterThan(editorChanges, 0)
    withExtendedLifetime(editorCancellable) {}
  }

  func testCommandPresentationFacadeIgnoresPublishMessagesAndAIStreaming() async {
    let store = makeIsolatedStore()
    let presentation = store.commandPresentation
    var presentationChanges = 0
    let presentationChanged = expectation(description: "command presentation changed")
    let cancellable = presentation.objectWillChange.sink {
      presentationChanges += 1
      presentationChanged.fulfill()
    }

    store.setPublishActionMessage("菜单动作完成", status: .information)
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "流式回复")
    ])
    store.setAIChatMessage("AI 状态变化")

    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(presentationChanges, 0)

    store.setInspectorPresented(!presentation.isInspectorPresented)
    XCTAssertEqual(presentationChanges, 0)
    await fulfillment(of: [presentationChanged], timeout: 1)
    XCTAssertEqual(presentationChanges, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testCommandPresentationFacadeCoalescesMenuRelevantChanges() async {
    let store = makeIsolatedStore()
    let presentation = store.commandPresentation
    var presentationChanges = 0
    let presentationChanged = expectation(description: "coalesced command presentation change")
    let cancellable = presentation.objectWillChange.sink {
      presentationChanges += 1
      presentationChanged.fulfill()
    }

    store.selectSection(presentation.selectedSection == .sync ? .writing : .sync)
    store.setInspectorPresented(!presentation.isInspectorPresented)

    XCTAssertEqual(presentationChanges, 0)
    await fulfillment(of: [presentationChanged], timeout: 1)
    XCTAssertEqual(presentationChanges, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testSettingsFacadeIgnoresDraftBodyAndChatStreaming() throws {
    let store = makeIsolatedStore()
    let settings = store.settings
    var settingsChanges = 0
    let cancellable = settings.objectWillChange.sink { settingsChanges += 1 }
    let draft = try XCTUnwrap(store.selectedDraft)

    var bodyEdit = draft
    bodyEdit.bodyMarkdown = "body only"
    store.updateDraft(bodyEdit)
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "streamed")
    ])
    store.setAIChatMessage("stream status")

    XCTAssertEqual(settingsChanges, 0)

    store.setAIActionMessage("设置相关状态")
    XCTAssertEqual(settingsChanges, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testPublishStatusFacadeIgnoresBodyOnlyDraftChanges() throws {
    let store = makeIsolatedStore()
    let status = store.publishStatus
    var statusChanges = 0
    let cancellable = status.objectWillChange.sink { statusChanges += 1 }
    let draft = try XCTUnwrap(store.selectedDraft)

    var bodyEdit = draft
    bodyEdit.bodyMarkdown = "body only"
    store.updateDraft(bodyEdit)

    XCTAssertEqual(statusChanges, 0)

    var titleEdit = bodyEdit
    titleEdit.title = "标题发生变化-\(UUID().uuidString)"
    store.updateDraft(titleEdit)
    XCTAssertGreaterThan(statusChanges, 0)
    withExtendedLifetime(cancellable) {}
  }

  func testWorkspaceLayoutFacadeIgnoresUnrelatedChildStoreChanges() {
    let store = makeIsolatedStore()
    let layout = store.workspaceLayout
    var layoutChanges = 0
    let cancellable = layout.objectWillChange.sink { layoutChanges += 1 }

    store.setPublishActionMessage("正在生成发布预览…")
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "流式内容")
    ])
    store.setRepositoryReport(nil)
    XCTAssertEqual(layoutChanges, 0)

    let nextSection: WorkspaceSection = layout.selectedSection == .library ? .writing : .library
    store.selectSection(nextSection)
    XCTAssertEqual(layoutChanges, 1)
    XCTAssertEqual(layout.selectedSection, nextSection)
    withExtendedLifetime(cancellable) {}
  }

  func testRootPresentationFacadeIgnoresFeatureProgressAndPublishesLayoutState() async {
    let store = makeIsolatedStore()
    let presentation = store.rootPresentation
    var changes = 0
    var pendingExpectation: XCTestExpectation?
    var observedInspectorPresentation = presentation.isInspectorPresented
    let cancellable = presentation.objectWillChange.sink {
      changes += 1
      observedInspectorPresentation = presentation.isInspectorPresented
      pendingExpectation?.fulfill()
    }

    store.setPublishActionMessage("后台发布进度", status: .information)
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "流式内容")
    ])
    store.setAIChatMessage("流式状态")
    store.repositoryStore.repositoryScanState = .scanning()

    try? await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(changes, 0)

    let changed = expectation(description: "root presentation changed")
    pendingExpectation = changed
    store.setInspectorPresented(!presentation.isInspectorPresented)

    await fulfillment(of: [changed], timeout: 1)
    XCTAssertEqual(changes, 1)
    XCTAssertEqual(observedInspectorPresentation, store.isInspectorPresented)
    withExtendedLifetime(cancellable) {}
  }

  func testContentPresentationFacadeIgnoresTypingAndAIStreaming() async throws {
    let store = makeIsolatedStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let presentation = store.contentPresentation
    var presentationChanges = 0
    var observedAssistantPresentation = presentation.isAssistantPresented
    var pendingExpectation: XCTestExpectation?
    let cancellable = presentation.objectWillChange.sink {
      presentationChanges += 1
      observedAssistantPresentation = presentation.isAssistantPresented
      pendingExpectation?.fulfill()
    }

    store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: draft.id,
        bodyMarkdown: "正在输入的正文",
        revision: 1,
        isDirty: true
      ),
      for: draft.id
    )

    let assistantMessage = AIPublishingChatMessage(role: .assistant, content: "第一段")
    store.setAIChatMessages([assistantMessage])
    var streamedMessage = assistantMessage
    streamedMessage.content += "，逐字返回"
    store.setAIChatMessages([streamedMessage])

    XCTAssertEqual(presentationChanges, 0)
    XCTAssertFalse(presentation.isAssistantPresented)

    let assistantChange = expectation(description: "assistant presentation forwarded")
    pendingExpectation = assistantChange
    store.setAIPublishingAssistantPresented(true)
    await fulfillment(of: [assistantChange], timeout: 1)
    XCTAssertEqual(presentationChanges, 1)
    XCTAssertTrue(observedAssistantPresentation)

    pendingExpectation = nil
    store.setAIPublishingAssistantPresented(true)
    XCTAssertEqual(presentationChanges, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testDraftListAndContentHealthFacadesIgnoreAIStreaming() {
    let store = makeIsolatedStore()
    let draftList = WorkbenchDraftListFeatureFacade(store: store)
    let contentHealth = WorkbenchContentHealthFeatureFacade(store: store)
    var draftListChanges = 0
    var contentHealthChanges = 0
    let draftListCancellable = draftList.objectWillChange.sink { draftListChanges += 1 }
    let contentHealthCancellable = contentHealth.objectWillChange.sink { contentHealthChanges += 1 }

    store.setAIChatMessages([
      AIPublishingChatMessage(role: .assistant, content: "streamed")
    ])
    store.setAIChatMessage("stream status")

    XCTAssertEqual(draftListChanges, 0)
    XCTAssertEqual(contentHealthChanges, 0)

    store.invalidateDraftDerivedCaches()
    XCTAssertGreaterThan(draftListChanges, 0)
    XCTAssertGreaterThan(contentHealthChanges, 0)
    withExtendedLifetime([draftListCancellable, contentHealthCancellable]) {}
  }

  func testShellFacadeIgnoresEquivalentRootStateAssignments() async {
    let store = makeIsolatedStore()
    let shell = store.shell
    var shellChanges = 0
    var observedSection = shell.selectedSection
    let changed = expectation(description: "shell selection forwarded")
    let cancellable = shell.objectWillChange.sink {
      shellChanges += 1
      observedSection = shell.selectedSection
      changed.fulfill()
    }

    store.selectSection(shell.selectedSection)
    XCTAssertEqual(shellChanges, 0)

    let differentSection: WorkspaceSection = shell.selectedSection == .sync ? .writing : .sync
    store.selectSection(differentSection)
    XCTAssertEqual(shellChanges, 0)
    await fulfillment(of: [changed], timeout: 1)
    XCTAssertEqual(shellChanges, 1)
    XCTAssertEqual(observedSection, differentSection)

    store.selectSection(differentSection)
    XCTAssertEqual(shellChanges, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testShellFacadeRoutesNavigationWithoutObservingUnrelatedPublishingProgress() async {
    let store = makeIsolatedStore()
    let shell = store.shell
    var shellChanges = 0
    var observedSection = shell.selectedSection
    let changed = expectation(description: "shell navigation forwarded")
    let cancellable = shell.objectWillChange.sink {
      shellChanges += 1
      observedSection = shell.selectedSection
      changed.fulfill()
    }

    store.setPublishActionMessage("正在生成发布预览…")
    XCTAssertEqual(shellChanges, 0)

    let section: WorkspaceSection = shell.selectedSection == .sync ? .writing : .sync
    shell.selectSection(section)

    XCTAssertEqual(shell.selectedSection, section)
    XCTAssertEqual(shellChanges, 0)
    await fulfillment(of: [changed], timeout: 1)
    XCTAssertEqual(shellChanges, 1)
    XCTAssertEqual(observedSection, section)
    withExtendedLifetime(cancellable) {}
  }

  func testPublishingFacadeIgnoresUnrelatedPublishingStoreState() {
    let store = makeIsolatedStore()
    let publishing = store.publishing
    var publishingChanges = 0
    let cancellable = publishing.objectWillChange.sink { publishingChanges += 1 }

    store.setPublishActionMessage("发布进度变化", status: .inProgress)
    XCTAssertEqual(publishingChanges, 0)

    let nextSection: WorkspaceSection = publishing.selectedSection == .library ? .writing : .library
    publishing.selectSection(nextSection)
    XCTAssertEqual(publishing.selectedSection, nextSection)
    XCTAssertEqual(publishingChanges, 1)

    withExtendedLifetime(cancellable) {}
  }

  func testAIFacadeUsesNarrowActionsAndReadsAIWorkspaceState() {
    let store = makeIsolatedStore()
    let draft = ArticleDraft.empty(profile: store.activeProfile)

    store.ai.prepareChat(for: draft)
    store.ai.setChatContextMode(.site)
    store.ai.setChatModelGrade(.highQuality)
    store.ai.setChatCustomModel("custom-model")
    store.setAIChatMessages([
      AIPublishingChatMessage(role: .user, content: "Hello")
    ])

    XCTAssertEqual(store.aiChatDraftID, draft.id)
    XCTAssertEqual(store.aiChatContextMode, .site)
    XCTAssertEqual(store.ai.chatModelGrade, .custom)
    XCTAssertEqual(store.aiChatSelectedModel, "custom-model")
    XCTAssertEqual(store.aiChatMessages.map(\.content), ["Hello"])
  }

  func testAIFacadeExposesWorkspaceActions() {
    let store = makeIsolatedStore()
    let draft = ArticleDraft.empty(profile: store.publishing.activeProfile)

    store.setDrafts([draft])
    let didOpen = store.ai.openChatWorkspace(for: draft.id, quickPrompt: .frontMatterPack)
    store.ai.setActionResult(AIPublishingActionResult(kind: .privacyReview, content: "公开风险检查"))
    store.ai.setActionMessage("AI 动作已完成。")

    XCTAssertTrue(didOpen)
    XCTAssertEqual(store.ai.chatDraftID, draft.id)
    XCTAssertEqual(store.publishing.selectedSection, .writing)
    XCTAssertTrue(store.ai.isAssistantPresented)
    XCTAssertEqual(store.ai.consumePendingQuickPrompt()?.id, AIPublishingQuickPrompt.frontMatterPack.id)
    XCTAssertEqual(store.ai.actionResult?.content, "公开风险检查")
    XCTAssertEqual(store.ai.actionMessage, "AI 动作已完成。")
  }

  func testPublishingAndRepositoryFacadesUseExistingFeatureStores() {
    let store = makeIsolatedStore()
    let draft = ArticleDraft.empty(profile: store.activeProfile)
    let updatedAt = Date(timeIntervalSince1970: 1_234)

    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    store.setRepositoryTokenAvailability(KeychainTokenAvailability(hasToken: true, updatedAt: updatedAt))

    XCTAssertEqual(store.drafts.map(\.id), [draft.id])
    XCTAssertEqual(store.selectedDraft?.id, draft.id)
    XCTAssertTrue(store.repositoryTokenAvailability.hasToken)
    XCTAssertEqual(store.repositoryTokenAvailability.updatedAt, updatedAt)
  }

  func testShellFacadeIgnoresDraftBodyEditsButPublishingFacadeObservesThem() {
    let store = makeIsolatedStore()
    let draft = ArticleDraft.empty(profile: store.activeProfile)
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    var shellChanges = 0
    var publishingChanges = 0
    let shellCancellable = store.shell.objectWillChange.sink { shellChanges += 1 }
    let publishingCancellable = store.publishing.objectWillChange.sink { publishingChanges += 1 }

    var updated = draft
    updated.bodyMarkdown = "debounced editor body"
    store.updateDraft(updated)

    XCTAssertEqual(shellChanges, 0)
    XCTAssertGreaterThan(publishingChanges, 0)

    withExtendedLifetime([shellCancellable, publishingCancellable]) {}
  }

  func testAIWorkspaceChangesStayOnAIFacadeInsteadOfRebroadcastingRootStore() {
    let store = makeIsolatedStore()
    let ai = store.ai
    let activityStatus = store.activityStatus
    var rootChanges = 0
    var aiChanges = 0
    var activityChanges = 0
    let rootCancellable = store.objectWillChange.sink { rootChanges += 1 }
    let aiCancellable = ai.objectWillChange.sink { aiChanges += 1 }
    let activityCancellable = activityStatus.objectWillChange.sink { activityChanges += 1 }

    store.setAIChatMessages([AIPublishingChatMessage(role: .assistant, content: "streamed")])
    store.setAIChatMessage("stream status")

    XCTAssertEqual(rootChanges, 0)
    XCTAssertGreaterThan(aiChanges, 0)
    XCTAssertEqual(activityChanges, 0)

    withExtendedLifetime([rootCancellable, aiCancellable, activityCancellable]) {}
  }

  func testActivityStatusFacadeObservesAIWithoutRebroadcastingRootStore() {
    let store = makeIsolatedStore()
    let activityStatus = store.activityStatus
    var rootChanges = 0
    var activityChanges = 0
    let rootCancellable = store.objectWillChange.sink { rootChanges += 1 }
    let activityCancellable = activityStatus.objectWillChange.sink { activityChanges += 1 }

    store.setAIChatRunning(true)

    XCTAssertTrue(activityStatus.isAIChatRunning)
    XCTAssertEqual(rootChanges, 0)
    XCTAssertGreaterThan(activityChanges, 0)
    withExtendedLifetime([rootCancellable, activityCancellable]) {}
  }

  func testImageWorkbenchFacadeObservesOnlyItsSelectedDraftAIImageState() throws {
    let store = makeIsolatedStore()
    let imageWorkbench = store.imageWorkbench
    let draftID = try XCTUnwrap(store.selectedDraft?.id)
    let attachmentID = UUID()
    let suggestion = AIPublishingImageTextSuggestion(
      id: attachmentID.uuidString,
      draftID: draftID,
      attachmentID: attachmentID,
      filename: "hero.png",
      imagePath: "/images/hero.png",
      altText: "Hero",
      caption: "Caption",
      reason: "Context"
    )
    var rootChanges = 0
    var imageChanges = 0
    let rootCancellable = store.objectWillChange.sink { rootChanges += 1 }
    let imageCancellable = imageWorkbench.objectWillChange.sink { imageChanges += 1 }

    store.setAITokenAvailability(KeychainTokenAvailability(hasToken: true))
    let generation = store.aiStore.beginAIImageTextSuggestionOperation(for: draftID)
    XCTAssertTrue(
      store.aiStore.installAIImageTextSuggestions(
        [suggestion],
        for: draftID,
        generation: generation
      )
    )

    XCTAssertTrue(imageWorkbench.aiTokenAvailability.hasToken)
    XCTAssertEqual(imageWorkbench.suggestionDraftID, draftID)
    XCTAssertEqual(imageWorkbench.suggestions, [suggestion])
    XCTAssertTrue(imageWorkbench.isGeneratingSuggestions)
    XCTAssertEqual(rootChanges, 0)
    XCTAssertGreaterThanOrEqual(imageChanges, 3)
    store.aiStore.finishAIImageTextSuggestionOperation(
      for: draftID,
      generation: generation
    )
    withExtendedLifetime([rootCancellable, imageCancellable]) {}
  }

  func testRepeatedBodyBufferTypingOnlyInvalidatesPublishingFacade() async throws {
    let persistenceURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("WorkbenchFeatureFacadeTests-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: persistenceURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let preflightRefreshTask = store.preflightRefreshTask
    let publishPreviewRefreshTask = store.publishingStore.publishPreviewRefreshTask
    let siteMaintenanceRefreshScheduleTask = store.siteMaintenanceRefreshScheduleTask
    let siteMaintenanceRefreshTask = store.siteMaintenanceRefreshTask
    preflightRefreshTask?.cancel()
    publishPreviewRefreshTask?.cancel()
    siteMaintenanceRefreshScheduleTask?.cancel()
    siteMaintenanceRefreshTask?.cancel()
    if let preflightRefreshTask {
      await preflightRefreshTask.value
    }
    if let publishPreviewRefreshTask {
      await publishPreviewRefreshTask.value
    }
    if let siteMaintenanceRefreshScheduleTask {
      await siteMaintenanceRefreshScheduleTask.value
    }
    if let siteMaintenanceRefreshTask {
      _ = await siteMaintenanceRefreshTask.result
    }
    store.preflightRefreshTask = nil
    store.publishingStore.publishPreviewRefreshTask = nil
    store.siteMaintenanceRefreshScheduleTask = nil
    store.siteMaintenanceRefreshTask = nil
    let draft = try XCTUnwrap(store.selectedDraft)
    let initialRevision = store.draftBodyEditorBuffer(for: draft.id).revision
    let first = try XCTUnwrap(
      store.stageDraftBody("first keystroke", for: draft.id, baseRevision: initialRevision)
    )
    // Keep this notification test focused on the second staged edit. Startup
    // refreshes may update the shared status after the first edit has already
    // marked the workbench dirty.
    store.persistenceStore.markStatus("有未保存修改")
    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertEqual(store.lastSaveStatus, "有未保存修改")

    var rootChanges = 0
    var publishingChanges = 0
    let rootCancellable = store.objectWillChange.sink { rootChanges += 1 }
    let publishingCancellable = store.publishing.objectWillChange.sink { publishingChanges += 1 }

    _ = store.stageDraftBody(
      "second keystroke",
      for: draft.id,
      baseRevision: first.buffer.revision
    )

    XCTAssertEqual(rootChanges, 0)
    XCTAssertGreaterThan(publishingChanges, 0)
    store.discardDraftBodyEditorBuffer(for: draft.id)
    withExtendedLifetime([rootCancellable, publishingCancellable]) {}
  }

  func testEditorNavigationFacadeIgnoresPublishingProgressChanges() async {
    let store = makeIsolatedStore()
    let editorNavigation = WorkbenchEditorNavigationFeatureFacade(store: store)
    var editorChanges = 0
    var observedSection = editorNavigation.selectedSection
    let changed = expectation(description: "editor navigation forwarded")
    let cancellable = editorNavigation.objectWillChange.sink {
      editorChanges += 1
      observedSection = editorNavigation.selectedSection
      changed.fulfill()
    }

    store.setPublishActionMessage("正在生成发布预览…")
    XCTAssertEqual(editorChanges, 0)

    store.setSelectedSection(.images)
    XCTAssertEqual(editorChanges, 0)
    await fulfillment(of: [changed], timeout: 1)
    XCTAssertEqual(editorChanges, 1)
    XCTAssertEqual(observedSection, .images)
    withExtendedLifetime(cancellable) {}
  }

  func testEditorNavigationFacadeIgnoresSelectedDraftContentOnlyUpdates() async throws {
    let store = makeIsolatedStore()
    let selectedDraft = try XCTUnwrap(store.selectedDraft)
    let editorNavigation = WorkbenchEditorNavigationFeatureFacade(store: store)
    var editorChanges = 0
    let cancellable = editorNavigation.objectWillChange.sink {
      editorChanges += 1
    }

    var updatedDraft = selectedDraft
    updatedDraft.bodyMarkdown += "\n正文更新不应替换中央编辑器。"
    store.setDrafts(
      store.drafts.map { $0.id == updatedDraft.id ? updatedDraft : $0 }
    )

    try await Task.sleep(for: .milliseconds(80))
    XCTAssertEqual(editorChanges, 0)
    XCTAssertEqual(editorNavigation.selectedDraft?.bodyMarkdown, updatedDraft.bodyMarkdown)
    withExtendedLifetime(cancellable) {}
  }

  func testEditorNavigationFacadePublishesWhenSelectedDraftIdentityChanges() async throws {
    let store = makeIsolatedStore()
    let selectedDraft = try XCTUnwrap(store.selectedDraft)
    let otherDraft = ArticleDraft.empty(profile: store.activeProfile)
    store.setDrafts(store.drafts + [otherDraft])
    let editorNavigation = WorkbenchEditorNavigationFeatureFacade(store: store)
    let changed = expectation(description: "selected draft identity changed")
    var observedDraftID = editorNavigation.selectedDraft?.id
    let cancellable = editorNavigation.objectWillChange.sink {
      observedDraftID = editorNavigation.selectedDraft?.id
      changed.fulfill()
    }

    store.setSelectedDraftID(otherDraft.id)
    await fulfillment(of: [changed], timeout: 1)

    XCTAssertEqual(observedDraftID, otherDraft.id)
    XCTAssertNotEqual(observedDraftID, selectedDraft.id)
    withExtendedLifetime(cancellable) {}
  }

  func testRootPresentationFacadesRefreshWhileAppKitTracksInput() {
    let store = makeIsolatedStore()
    let shell = store.shell
    let editorNavigation = WorkbenchEditorNavigationFeatureFacade(store: store)
    let contentPresentation = store.contentPresentation
    let nextSection: WorkspaceSection = shell.selectedSection == .images ? .sync : .images

    var shellObservedSection = shell.selectedSection
    var editorObservedSection = editorNavigation.selectedSection
    var observedAssistantPresentation = contentPresentation.isAssistantPresented
    let shellCancellable = shell.objectWillChange.sink {
      shellObservedSection = shell.selectedSection
    }
    let editorCancellable = editorNavigation.objectWillChange.sink {
      editorObservedSection = editorNavigation.selectedSection
    }
    let presentationCancellable = contentPresentation.objectWillChange.sink {
      observedAssistantPresentation = contentPresentation.isAssistantPresented
    }

    store.setSelectedSection(nextSection)
    store.setAIPublishingAssistantPresented(true)

    let eventTrackingMode = RunLoop.Mode("NSEventTrackingRunLoopMode")
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
      _ = RunLoop.main.run(
        mode: eventTrackingMode,
        before: Date().addingTimeInterval(0.01)
      )
      if shellObservedSection == nextSection,
        editorObservedSection == nextSection,
        observedAssistantPresentation
      {
        break
      }
    }

    XCTAssertEqual(shellObservedSection, nextSection)
    XCTAssertEqual(editorObservedSection, nextSection)
    XCTAssertTrue(observedAssistantPresentation)
    withExtendedLifetime([
      shellCancellable,
      editorCancellable,
      presentationCancellable,
    ]) {}
  }

  func testMarkdownEditorFacadeIgnoresStreamingUpdatesForExistingAssistantMessage() throws {
    let store = makeIsolatedStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let editor = WorkbenchMarkdownEditorFeatureFacade(store: store, draftID: draft.id)
    var editorChanges = 0
    let cancellable = editor.objectWillChange.sink { editorChanges += 1 }

    store.setAIChatDraftID(draft.id)
    let assistantMessage = AIPublishingChatMessage(
      role: .assistant,
      content: "第一段"
    )
    store.setAIChatMessages([assistantMessage])
    editorChanges = 0

    var streamedMessage = assistantMessage
    streamedMessage.content += "，继续生成的内容"
    store.setAIChatMessages([streamedMessage])
    XCTAssertEqual(editorChanges, 0)

    let nextMessage = AIPublishingChatMessage(
      role: .assistant,
      content: "下一条回复"
    )
    store.setAIChatMessages([streamedMessage, nextMessage])
    XCTAssertEqual(editorChanges, 1)
    withExtendedLifetime(cancellable) {}
  }

  func testMarkdownEditorSaveStatusChangesStayOnToolbarScopedFacade() throws {
    let store = makeIsolatedStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let editor = WorkbenchMarkdownEditorFeatureFacade(store: store, draftID: draft.id)
    let saveStatus = WorkbenchMarkdownEditorSaveStatusFeatureFacade(
      store: store,
      draftID: draft.id
    )
    var editorChanges = 0
    var saveStatusChanges = 0
    let editorCancellable = editor.objectWillChange.sink { editorChanges += 1 }
    let saveStatusCancellable = saveStatus.objectWillChange.sink { saveStatusChanges += 1 }

    let updatedStatus = "toolbar-scoped-status-" + UUID().uuidString
    store.persistenceStore.markStatus(updatedStatus)

    XCTAssertEqual(editorChanges, 0)
    XCTAssertGreaterThan(saveStatusChanges, 0)
    XCTAssertEqual(store.lastSaveStatus, updatedStatus)
    withExtendedLifetime([editorCancellable, saveStatusCancellable]) {}
  }

  func testMarkdownEditorFacadeObservesOnlyTrackedDraftBodyBuffer() throws {
    let store = makeIsolatedStore()
    let trackedDraft = try XCTUnwrap(store.selectedDraft)
    let otherDraft = ArticleDraft.empty(profile: store.activeProfile)
    store.setDrafts([trackedDraft, otherDraft])
    let editor = WorkbenchMarkdownEditorFeatureFacade(
      store: store,
      draftID: trackedDraft.id
    )
    var editorChanges = 0
    let cancellable = editor.objectWillChange.sink { editorChanges += 1 }

    store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: otherDraft.id,
        bodyMarkdown: "另一篇文章",
        revision: 1,
        isDirty: true
      ),
      for: otherDraft.id
    )
    XCTAssertEqual(editorChanges, 0)

    store.publishingStore.setDraftBodyEditorBuffer(
      DraftBodyEditorBuffer(
        draftID: trackedDraft.id,
        bodyMarkdown: "当前文章",
        revision: 1,
        isDirty: true
      ),
      for: trackedDraft.id
    )
    XCTAssertEqual(editorChanges, 1)
    withExtendedLifetime(cancellable) {}
  }
}
