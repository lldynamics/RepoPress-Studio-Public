import Combine
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchFeatureFacadeTests: XCTestCase {
  func testFeatureFacadesExposeStableEntrypoints() {
    let store = WorkbenchStore()

    XCTAssertTrue(store.ai === store.ai)
    XCTAssertTrue(store.repository === store.repository)
    XCTAssertTrue(store.publishing === store.publishing)
    XCTAssertTrue(store.activityStatus === store.activityStatus)
  }

  func testAIFacadeUsesNarrowActionsAndReadsAIWorkspaceState() {
    let store = WorkbenchStore()
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
    let store = WorkbenchStore()
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
    let store = WorkbenchStore()
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
    let store = WorkbenchStore()
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
    let store = WorkbenchStore()
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
    let store = WorkbenchStore()
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

  func testImageWorkbenchFacadeObservesOnlyItsAIImageState() {
    let store = WorkbenchStore()
    let imageWorkbench = store.imageWorkbench
    let draftID = UUID()
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
    store.setAIImageTextSuggestionDraftID(draftID)
    store.setAIImageTextSuggestions([suggestion])
    store.setAIImageTextRunning(true)

    XCTAssertTrue(imageWorkbench.aiTokenAvailability.hasToken)
    XCTAssertEqual(imageWorkbench.suggestionDraftID, draftID)
    XCTAssertEqual(imageWorkbench.suggestions, [suggestion])
    XCTAssertTrue(imageWorkbench.isGeneratingSuggestions)
    XCTAssertEqual(rootChanges, 0)
    XCTAssertGreaterThanOrEqual(imageChanges, 4)
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
}
