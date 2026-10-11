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

final class MarkdownEditorAIWritingOperationsTests: XCTestCase {
  func testMissingAPIKeyOpensCredentialsWhileConfiguredAPIConnectionStaysAvailable() {
    let config = AIProviderConfig(preset: .openAICompatible, requiresAPIKey: true)

    XCTAssertEqual(
      MarkdownEditorAIConfigurationPresentation.destination(
        for: config, isAIEnabled: false, hasAuthenticatedChatGPTAccount: false
      ),
      .ai(.credentials)
    )
    XCTAssertNil(
      MarkdownEditorAIConfigurationPresentation.destination(
        for: config, isAIEnabled: true, hasAuthenticatedChatGPTAccount: false
      )
    )
  }

  func testChatGPTRequiresLoginButNeverRequiresAnAPIKey() {
    let config = AIProviderConfig(preset: .codexAppServer, requiresAPIKey: false)

    XCTAssertEqual(
      MarkdownEditorAIConfigurationPresentation.destination(
        for: config, isAIEnabled: true, hasAuthenticatedChatGPTAccount: false
      ),
      .ai(.connection)
    )
    XCTAssertNil(
      MarkdownEditorAIConfigurationPresentation.destination(
        for: config, isAIEnabled: true, hasAuthenticatedChatGPTAccount: true
      )
    )
  }

  func testLocalAIKeepsItsKeylessConfiguration() {
    XCTAssertNil(
      MarkdownEditorAIConfigurationPresentation.destination(
        for: AIProviderConfig(preset: .local, requiresAPIKey: false),
        isAIEnabled: true,
        hasAuthenticatedChatGPTAccount: false
      )
    )
  }

  func testFrontMatterSelectionCannotReuseTheLastBodySelection() {
    var actions = toolbarActions(selectionAvailability: .init(isEnabled: true))
    actions.isBodySelectionActive = false

    for kind: AIPublishingActionKind in [
      .rewriteSelection, .translateSelectionToChinese, .translateSelectionToEnglish,
    ] {
      XCTAssertFalse(actions.selectionAvailability(for: kind).isEnabled)
    }

    actions.isBodySelectionActive = true
    XCTAssertTrue(actions.selectionAvailability(for: .rewriteSelection).isEnabled)
  }

  func testSelectionMenuPreservesExistingRunningActionRestrictions() {
    let busy = AIPublishingActionAvailabilityPresentation(
      isEnabled: false, unavailableReason: "AI 正在处理"
    )
    let actions = toolbarActions(selectionAvailability: busy)

    XCTAssertEqual(actions.selectionAvailability(for: .rewriteSelection), busy)
    XCTAssertEqual(actions.selectionAvailability(for: .translateSelectionToEnglish), busy)
  }

  private func toolbarActions(
    selectionAvailability: AIPublishingActionAvailabilityPresentation
  ) -> MarkdownEditorToolbarActions {
    MarkdownEditorToolbarActions(
      onShowFindReplace: {},
      onShowOutline: {},
      onShowShortcutHelp: {},
      onOpenAIContextInspector: {},
      onOpenAITemplateLibrary: {},
      onRequestInlineAICompletion: {},
      onExportDocument: { _ in },
      selectionAIActionAvailability: { _ in selectionAvailability },
      articleAIActionAvailability: { _ in .init(isEnabled: true) },
      onPerformSelectionAIAction: { _ in },
      onPerformArticleAIAction: { _ in },
      onPerformConvergedSelectionAIAction: { _ in },
      onPerformConvergedArticleAIAction: { _ in },
      onPasteAIPromptToClipboard: {}
    )
  }
}
