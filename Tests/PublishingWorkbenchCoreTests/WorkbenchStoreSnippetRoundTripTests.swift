import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class WorkbenchStoreSnippetRoundTripTests: XCTestCase {
  func testStoreSaveAndReloadPreservesSnippetShortcutAndPresentationMetadata() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("snippet-round-trip-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("state.json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    let snippet = MarkdownSnippet(
      id: "custom-round-trip",
      title: "提示",
      detail: "详情",
      systemImage: "text.badge.plus",
      kind: .snippet,
      markdown: "> 内容",
      siteProfileID: store.activeProfileID,
      shortcut: "callout",
      previewKind: .callout,
      selectionToken: "selected-text"
    )

    store.saveCustomMarkdownSnippet(snippet)
    store.save()
    await store.waitForPendingSave()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: fileURL))
    let saved = try XCTUnwrap(reloaded.customMarkdownSnippets.first)
    XCTAssertEqual(saved.shortcut, "callout")
    XCTAssertEqual(saved.previewKind, .callout)
    XCTAssertEqual(saved.selectionToken, "selected-text")
  }
}
