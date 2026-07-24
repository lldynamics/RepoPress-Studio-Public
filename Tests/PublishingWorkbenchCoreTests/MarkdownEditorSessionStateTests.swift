import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class MarkdownEditorSessionStateTests: XCTestCase {
  func testNormalizationClampsSelectionAndScrollProgressToCurrentBody() {
    let state = MarkdownEditorSessionState(
      selectedRange: NSRange(location: 8, length: 12),
      editorScrollProgress: -0.4,
      previewScrollProgress: 1.8,
      isFindReplacePresented: true,
      findQuery: "Swift",
      replacementText: "Markdown",
      isFindCaseSensitive: true,
      isFindWholeWord: true,
      isFindRegularExpression: true
    )

    let normalized = state.normalized(bodyUTF16Count: 10)

    XCTAssertEqual(normalized.selectionLocation, 8)
    XCTAssertEqual(normalized.selectionLength, 2)
    XCTAssertEqual(normalized.editorScrollProgress, 0)
    XCTAssertEqual(normalized.previewScrollProgress, 1)
    XCTAssertEqual(normalized.findQuery, "Swift")
    XCTAssertEqual(normalized.replacementText, "Markdown")
    XCTAssertTrue(normalized.isFindReplacePresented)
    XCTAssertTrue(normalized.isFindCaseSensitive)
    XCTAssertTrue(normalized.isFindWholeWord)
    XCTAssertTrue(normalized.isFindRegularExpression)
  }

  func testSnapshotRoundTripKeepsOnlyLiveArticleWritingSessions() throws {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Writing session",
      slug: "writing-session",
      bodyMarkdown: "0123456789"
    )
    let state = MarkdownEditorSessionState(
      selectedRange: NSRange(location: 3, length: 4),
      editorScrollProgress: 0.25,
      previewScrollProgress: 0.75,
      isFindReplacePresented: true,
      findQuery: "3456",
      replacementText: "replacement",
      isFindCaseSensitive: true,
      isFindWholeWord: false,
      isFindRegularExpression: true
    )
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [draft],
      markdownEditorSessionStates: [
        draft.id: state,
        UUID(): .empty,
      ],
      releaseRecords: []
    )

    XCTAssertEqual(snapshot.markdownEditorSessionStates, [draft.id: state])

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: JSONEncoder.workbench.encode(snapshot)
    )

    XCTAssertEqual(decoded.markdownEditorSessionStates, [draft.id: state])
  }

  func testLegacySnapshotWithoutWritingSessionsDecodesWithEmptyState() throws {
    let profile = SiteProfile.defaultProfile
    let snapshot = WorkbenchSnapshot(
      profiles: [profile],
      activeProfileID: profile.id,
      drafts: [ArticleDraft.empty(profile: profile)],
      releaseRecords: []
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder.workbench.encode(snapshot)) as? [String: Any]
    )
    object.removeValue(forKey: "markdownEditorSessionStates")

    let decoded = try JSONDecoder.workbench.decode(
      WorkbenchSnapshot.self,
      from: JSONSerialization.data(withJSONObject: object)
    )

    XCTAssertTrue(decoded.markdownEditorSessionStates.isEmpty)
  }

  func testStorePersistsWritingSessionPerArticleAndRemovesItAfterPermanentDeletion() throws {
    let persistenceURL = try temporaryPersistenceURL(prefix: "MarkdownEditorSessionState")
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(persistence: persistence)
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Persistent session",
      slug: "persistent-session",
      bodyMarkdown: "0123456789"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)
    let state = MarkdownEditorSessionState(
      selectedRange: NSRange(location: 2, length: 5),
      editorScrollProgress: 0.3,
      previewScrollProgress: 0.6,
      isFindReplacePresented: true,
      findQuery: "23456",
      replacementText: "saved",
      isFindCaseSensitive: true,
      isFindWholeWord: true
    )

    store.updateMarkdownEditorSessionState(state, for: draft.id, bodyUTF16Count: 10)
    XCTAssertTrue(store.flushPendingChanges())

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: persistenceURL))
    XCTAssertEqual(reloaded.markdownEditorSessionState(for: draft.id), state)

    reloaded.deleteDraft(id: draft.id)
    XCTAssertEqual(reloaded.markdownEditorSessionState(for: draft.id), state)
    XCTAssertTrue(reloaded.permanentlyDeleteRecycledDraft(draft.id))
    XCTAssertEqual(reloaded.markdownEditorSessionState(for: draft.id), .empty)
  }
}
