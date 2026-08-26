import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class MarkdownEditorMultiWindowPersistenceAcceptanceTests: XCTestCase {
  func testStaleWindowWritesFlushAndReloadLatestBodyMetadataAndSessionState() throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "MarkdownEditorMultiWindowPersistence"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let persistenceURL = rootURL.appendingPathComponent("workbench.json")
    let persistence = WorkbenchPersistence(fileURL: persistenceURL)
    let store = WorkbenchStore(persistence: persistence)
    let initialDraft = try XCTUnwrap(store.selectedDraft)
    let firstWindowDraft = initialDraft
    let staleWindowDraft = initialDraft
    let initialBuffer = store.draftBodyEditorBuffer(for: initialDraft.id)
    let latestBody = "主窗口的最新正文，包含中文与 Markdown。"
    let staleBody = "陈旧窗口不应覆盖的正文。"

    let firstBodyWrite = try XCTUnwrap(
      store.stageDraftBody(
        latestBody,
        for: initialDraft.id,
        baseRevision: initialBuffer.revision
      )
    )
    let staleBodyWrite = try XCTUnwrap(
      store.stageDraftBody(
        staleBody,
        for: initialDraft.id,
        baseRevision: initialBuffer.revision
      )
    )

    XCTAssertTrue(firstBodyWrite.wasAccepted)
    XCTAssertFalse(staleBodyWrite.wasAccepted)
    XCTAssertEqual(
      store.draftBodyEditorBuffer(for: initialDraft.id).bodyMarkdown,
      latestBody
    )

    var latestMetadata = firstWindowDraft
    latestMetadata.title = "主窗口的最新标题"
    latestMetadata.summary = "主窗口的最新摘要"
    XCTAssertTrue(store.updateDraftFromEditor(latestMetadata))

    var staleMetadata = staleWindowDraft
    staleMetadata.title = "陈旧窗口的标题"
    staleMetadata.summary = "陈旧窗口的摘要"
    XCTAssertFalse(store.updateDraftFromEditor(staleMetadata))

    let currentDraftBeforeFlush = try XCTUnwrap(
      store.drafts.first(where: { $0.id == initialDraft.id })
    )
    XCTAssertEqual(currentDraftBeforeFlush.title, latestMetadata.title)
    XCTAssertEqual(currentDraftBeforeFlush.summary, latestMetadata.summary)

    let sessionState = MarkdownEditorSessionState(
      selectedRange: NSRange(location: 3, length: 7),
      editorScrollProgress: 0.42,
      isFindReplacePresented: true,
      findQuery: "最新正文",
      replacementText: "替换内容",
      isFindCaseSensitive: true,
      isFindWholeWord: true,
      isFindRegularExpression: false
    )
    store.updateMarkdownEditorSessionState(
      sessionState,
      for: initialDraft.id,
      bodyUTF16Count: latestBody.utf16.count
    )

    XCTAssertTrue(store.hasUnsavedChanges)
    XCTAssertTrue(store.flushPendingChanges())

    let reloadedStore = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: persistenceURL)
    )
    let restoredDraft = try XCTUnwrap(
      reloadedStore.drafts.first(where: { $0.id == initialDraft.id })
    )

    XCTAssertEqual(restoredDraft.bodyMarkdown, latestBody)
    XCTAssertEqual(restoredDraft.title, latestMetadata.title)
    XCTAssertEqual(restoredDraft.summary, latestMetadata.summary)
    XCTAssertEqual(
      reloadedStore.markdownEditorSessionState(for: initialDraft.id),
      sessionState
    )
  }
}
