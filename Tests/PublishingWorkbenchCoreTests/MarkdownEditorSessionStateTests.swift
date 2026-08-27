import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class MarkdownEditorSessionStateTests: XCTestCase {
  func testNormalizationClampsSelectionAndScrollProgressToCurrentBody() {
    let state = MarkdownEditorSessionState(
      selectedRange: NSRange(location: 8, length: 12),
      editorScrollProgress: -0.4,
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

  func testLegacySessionIgnoresRemovedPreviewScrollProgress() throws {
    let data = Data(
      """
      {
        "selectionLocation": 2,
        "selectionLength": 1,
        "editorScrollProgress": 0.25,
        "previewScrollProgress": 0.75,
        "isFindReplacePresented": false,
        "findQuery": "",
        "replacementText": "",
        "isFindCaseSensitive": false,
        "isFindWholeWord": false,
        "isFindRegularExpression": false
      }
      """.utf8
    )

    let decoded = try JSONDecoder().decode(MarkdownEditorSessionState.self, from: data)

    XCTAssertEqual(decoded.editorScrollProgress, 0.25)
    XCTAssertEqual(decoded.selectedRange(bodyUTF16Count: 10), NSRange(location: 2, length: 1))
    XCTAssertNil(decoded.invalidFrontMatterDocument)
  }

  func testInvalidFrontMatterRecoveryDocumentRoundTrips() throws {
    let recoveredDocument = "---\ntitle broken\n---\n正文"
    let baseBody = "原正文"
    let state = MarkdownEditorSessionState(
      selectedRange: NSRange(location: 1, length: 0),
      invalidFrontMatterDocument: recoveredDocument,
      invalidFrontMatterBaseBodyMarkdown: baseBody,
      invalidFrontMatterBaseBodyRevision: 42
    )

    let decoded = try JSONDecoder().decode(
      MarkdownEditorSessionState.self,
      from: JSONEncoder().encode(state)
    )

    XCTAssertEqual(decoded.invalidFrontMatterDocument, recoveredDocument)
    XCTAssertEqual(decoded.invalidFrontMatterBaseBodyMarkdown, baseBody)
    XCTAssertEqual(decoded.invalidFrontMatterBaseBodyRevision, 42)
    XCTAssertEqual(
      decoded.normalized(bodyUTF16Count: 2).invalidFrontMatterDocument,
      recoveredDocument
    )
    XCTAssertEqual(
      decoded.normalized(bodyUTF16Count: 2).invalidFrontMatterBaseBodyMarkdown,
      baseBody
    )
  }

  func testInvalidFrontMatterRecoveryRebasesAfterEditorBufferRevisionResetsOnReload() throws {
    let persistenceURL = try temporaryPersistenceURL(prefix: "FrontMatterRecoveryRestart")
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Recovery restart",
      slug: "recovery-restart",
      bodyMarkdown: "初始正文"
    )
    store.setDrafts([draft])
    store.setSelectedDraftID(draft.id)

    let staged = try XCTUnwrap(
      store.stageDraftBody("恢复基线正文", for: draft.id, baseRevision: 0)
    )
    XCTAssertTrue(staged.wasAccepted)
    XCTAssertGreaterThan(staged.buffer.revision, 0)
    store.flushDraftBodyEditorBuffer(for: draft.id)
    let recoveryState = MarkdownEditorSessionState(
      invalidFrontMatterDocument: "---\ntitle broken\n---\n恢复后的正文",
      invalidFrontMatterBaseBodyMarkdown: staged.buffer.bodyMarkdown,
      invalidFrontMatterBaseBodyRevision: staged.buffer.revision
    )
    store.updateMarkdownEditorSessionState(
      recoveryState,
      for: draft.id,
      bodyUTF16Count: (staged.buffer.bodyMarkdown as NSString).length
    )
    XCTAssertTrue(store.flushPendingChanges())

    let reloaded = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let reloadedState = reloaded.markdownEditorSessionState(for: draft.id)
    let reloadedBuffer = reloaded.draftBodyEditorBuffer(for: draft.id)
    XCTAssertEqual(reloadedBuffer.revision, 0)
    XCTAssertEqual(
      reloadedBuffer.bodyMarkdown,
      reloadedState.invalidFrontMatterBaseBodyMarkdown
    )

    let recovered = try XCTUnwrap(
      reloaded.stageRecoveredDraftBody(
        "恢复后的正文",
        for: draft.id,
        matchingBaseBody: try XCTUnwrap(
          reloadedState.invalidFrontMatterBaseBodyMarkdown
        )
      )
    )
    XCTAssertTrue(recovered.wasAccepted)
    XCTAssertEqual(recovered.buffer.bodyMarkdown, "恢复后的正文")
    XCTAssertEqual(recovered.buffer.revision, 1)
  }

  func testInvalidFrontMatterRecoveryRejectsAConcurrentBodyChange() throws {
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: try temporaryPersistenceURL(prefix: "FrontMatterRecoveryConflict")
      )
    )
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Recovery conflict",
      slug: "recovery-conflict",
      bodyMarkdown: "恢复基线正文"
    )
    store.setDrafts([draft])
    let concurrent = try XCTUnwrap(
      store.stageDraftBody("另一窗口正文", for: draft.id, baseRevision: 0)
    )
    XCTAssertTrue(concurrent.wasAccepted)

    let recovered = try XCTUnwrap(
      store.stageRecoveredDraftBody(
        "恢复原文正文",
        for: draft.id,
        matchingBaseBody: "恢复基线正文"
      )
    )
    XCTAssertFalse(recovered.wasAccepted)
    XCTAssertEqual(recovered.buffer.bodyMarkdown, "另一窗口正文")
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
