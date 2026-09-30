import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

@MainActor
final class AIChatComposerAvailabilityTests: XCTestCase {
  func testMissingAPIKeyAllowsComposingButBlocksSendingInBothContexts() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("composer-availability-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workspace.json")),
      safeMode: true,
      keychainTokenStore: KeychainTokenStore(
        service: "composer-availability-\(UUID().uuidString)",
        accountPrefix: "test",
        inMemory: true
      )
    )
    var connection = store.activeAIConnectionProfile
    connection.config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.invalid/v1",
      model: "test-model",
      requiresAPIKey: true
    )
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
    store.setAITokenAvailability(KeychainTokenAvailability(hasToken: false))
    let draftID = try XCTUnwrap(store.selectedDraftID)

    for mode in [AIPublishingChatContextMode.site, .general] {
      store.setAIChatContextMode(mode)
      let conversation = AIConversation(
        scope: mode == .general ? .general : .draft(draftID),
        connectionProfileID: connection.id
      )
      store.aiStore.aiConversations = [conversation]
      let inspector = AIChatContextInspectorView(
        store: store,
        selectedDraftID: mode == .site ? draftID : nil,
        usesWindowDraftSelection: true,
        surfaceState: .constant(
          AIChatSurfaceState(
            surface: .inspector,
            selectedConversationID: conversation.id,
            composerTextByConversation: [conversation.id: "Keep this question until a key is ready"]
          )
        ),
        operationSession: AIChatSurfaceOperationSession()
      )

      XCTAssertTrue(inspector.isAIKeyMissing)
      XCTAssertFalse(inspector.isComposerInputUnavailable)
      XCTAssertFalse(inspector.trimmedInput.isEmpty)
      XCTAssertFalse(inspector.canSubmitMessage)
      inspector.submitMessage()
      XCTAssertTrue(store.aiStore.aiConversations[0].messages.isEmpty)
      XCTAssertFalse(inspector.inputText.isEmpty)
    }
  }
}

final class AIChatQuickPromptDeliveryPolicyTests: XCTestCase {
  func testNewArticleComposerUsesDraftFallbackWhilePassingNilConversation() {
    let draftID = UUID()
    XCTAssertTrue(
      AIChatQuickPromptDeliveryPolicy.isArticleComposerReady(
        contextMode: .site,
        draftID: draftID,
        conversationID: nil,
        surfaceConversationID: draftID
      )
    )
    XCTAssertFalse(
      AIChatQuickPromptDeliveryPolicy.isArticleComposerReady(
        contextMode: .site,
        draftID: draftID,
        conversationID: nil,
        surfaceConversationID: UUID()
      )
    )
  }

  func testExistingArticleConversationRequiresMatchingComposer() {
    let draftID = UUID()
    let conversationID = UUID()
    XCTAssertTrue(
      AIChatQuickPromptDeliveryPolicy.isArticleComposerReady(
        contextMode: .site,
        draftID: draftID,
        conversationID: conversationID,
        surfaceConversationID: conversationID
      )
    )
    XCTAssertFalse(
      AIChatQuickPromptDeliveryPolicy.isArticleComposerReady(
        contextMode: .site,
        draftID: draftID,
        conversationID: conversationID,
        surfaceConversationID: draftID
      )
    )
    XCTAssertFalse(
      AIChatQuickPromptDeliveryPolicy.isArticleComposerReady(
        contextMode: .general,
        draftID: draftID,
        conversationID: conversationID,
        surfaceConversationID: conversationID
      )
    )
  }
}
