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
    XCTAssertEqual(store.publishing.selectedSection, .ai)
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
    var rootChanges = 0
    var aiChanges = 0
    let rootCancellable = store.objectWillChange.sink { rootChanges += 1 }
    let aiCancellable = ai.objectWillChange.sink { aiChanges += 1 }

    store.setAIChatMessages([AIPublishingChatMessage(role: .assistant, content: "streamed")])

    XCTAssertEqual(rootChanges, 0)
    XCTAssertGreaterThan(aiChanges, 0)

    withExtendedLifetime([rootCancellable, aiCancellable]) {}
  }

  func testRepeatedBodyBufferTypingOnlyInvalidatesPublishingFacade() throws {
    let store = WorkbenchStore()
    let draft = try XCTUnwrap(store.selectedDraft)
    let initialRevision = store.draftBodyEditorBuffer(for: draft.id).revision
    let first = try XCTUnwrap(
      store.stageDraftBody("first keystroke", for: draft.id, baseRevision: initialRevision)
    )

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
