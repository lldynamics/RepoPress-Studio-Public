import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class AIWritingStyleIntegrationTests: XCTestCase {
  private func makeStore() throws -> (WorkbenchStore, RecordingAIChatTransport) {
    let response = #"{"tone":"清楚克制","audience":"写作者","preferredTerminology":["RepoPress"]}"#
    let transport = RecordingAIChatTransport(
      data: try JSONSerialization.data(withJSONObject: [
        "choices": [["message": ["role": "assistant", "content": response]]]
      ]), statusCode: 200)
    let store = WorkbenchStore(
      persistence: try TestWorkbenchFactory.persistence(),
      keychainTokenStore: KeychainTokenStore(
        service: "AIWritingStyleIntegrationTests.\(UUID().uuidString)",
        accountPrefix: "test",
        inMemory: true
      ),
      aiPublishingAssistantService: AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)))
    var connection = store.activeAIConnectionProfile
    connection.config = AIProviderConfig(
      preset: .local, baseURL: "http://localhost:11434/v1", model: "style-test-model",
      requiresAPIKey: false)
    XCTAssertTrue(store.updateAIConnectionProfile(connection))
    return (store, transport)
  }

  func testSelectedExamplesReachTransportAndStyleChangesOnlyAfterApply() async throws {
    let (store, transport) = try makeStore()
    let baseline = store.activeProfile.resolvedAIWritingStyle
    let selected = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Selected style example",
      bodyMarkdown: "Example selected by the user. It is clear and direct.")
    let unrelated = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Unselected unique title",
      bodyMarkdown: "This article was not selected and must not be sent.")
    store.setDrafts([selected, unrelated])
    let generated = await store.generateAIWritingStyleProfile(exemplarArticleIDs: [selected.id])
    let preview = try XCTUnwrap(generated, store.aiStore.aiActionMessage ?? "")
    XCTAssertEqual(store.activeProfile.resolvedAIWritingStyle, baseline)
    let request = await transport.capturedRequest()
    let body = try XCTUnwrap(request?.httpBody)
    let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(sent["messages"] as? [[String: Any]])
    let text = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
    XCTAssertTrue(text.contains("Selected style example"))
    XCTAssertFalse(text.contains("Unselected unique title"))
    XCTAssertEqual(sent["model"] as? String, "style-test-model")
    XCTAssertTrue(store.applyAIWritingStyleProfile(preview))
    XCTAssertEqual(store.activeProfile.resolvedAIWritingStyle.tone, "清楚克制")
    XCTAssertEqual(store.activeProfile.resolvedAIWritingStyle.preferredTerminology, ["RepoPress"])
  }

  func testPrivateExampleIsRejectedBeforeTransport() async throws {
    let (store, transport) = try makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Private example",
      visibility: .private, bodyMarkdown: "Do not send")
    store.setDrafts([draft])
    let preview = await store.generateAIWritingStyleProfile(exemplarArticleIDs: [draft.id])
    XCTAssertNil(preview)
    let count = await transport.capturedRequestCount()
    XCTAssertEqual(count, 0)
  }

  func testStyleEditedAfterExtractionIsNotOverwrittenByOldPreview() async throws {
    let (store, _) = try makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Example", bodyMarkdown: "Example prose.")
    store.setDrafts([draft])
    let generated = await store.generateAIWritingStyleProfile(exemplarArticleIDs: [draft.id])
    let preview = try XCTUnwrap(generated)
    var profile = store.activeProfile
    var style = profile.resolvedAIWritingStyle
    style.tone = "用户刚刚修改的语气"
    profile.resolvedAIWritingStyle = style
    XCTAssertTrue(store.commitActiveProfileSynchronously(profile))
    XCTAssertFalse(store.applyAIWritingStyleProfile(preview))
    XCTAssertEqual(store.activeProfile.resolvedAIWritingStyle.tone, "用户刚刚修改的语气")
  }

  func testUnsavedExampleEditsInvalidatePreviewAtApply() async throws {
    let (store, _) = try makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID, title: "Example", bodyMarkdown: "Original prose.")
    store.setDrafts([draft])
    let generated = await store.generateAIWritingStyleProfile(exemplarArticleIDs: [draft.id])
    let preview = try XCTUnwrap(generated)
    let buffer = store.draftBodyEditorBuffer(for: draft.id)
    _ = store.stageDraftBody("New unsaved wording", for: draft.id, baseRevision: buffer.revision)
    XCTAssertFalse(store.applyAIWritingStyleProfile(preview))
  }
}
