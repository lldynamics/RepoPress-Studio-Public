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
}
