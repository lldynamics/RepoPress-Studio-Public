import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class P3LifecycleAcceptanceTests: XCTestCase {
  func testManagedAttachmentSurvivesPersistenceReloadAfterOriginalIsRemoved() async throws {
    let rootURL = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "P3ManagedAttachmentRestart"
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let persistence = WorkbenchPersistence(
      fileURL: rootURL.appendingPathComponent("workbench.json")
    )
    let sourceURL = rootURL.appendingPathComponent("external-cover.png")
    let expectedData = Data("persisted-managed-attachment".utf8)
    try expectedData.write(to: sourceURL)
    let fileStore = ManagedAttachmentFileStore(
      rootDirectoryURL: rootURL.appendingPathComponent(
        "ManagedAttachments",
        isDirectory: true
      )
    )
    let firstLaunchStore = WorkbenchStore(persistence: persistence)
    var draft = try XCTUnwrap(firstLaunchStore.selectedDraft)

    let attachment = try await firstLaunchStore.makeAttachment(
      from: sourceURL,
      draft: draft,
      fileStore: fileStore
    )
    draft.attachments.append(attachment)
    firstLaunchStore.updateDraft(draft)
    XCTAssertTrue(firstLaunchStore.flushPendingChanges())
    try FileManager.default.removeItem(at: sourceURL)

    let relaunchedStore = WorkbenchStore(persistence: persistence)
    let restoredDraft = try XCTUnwrap(
      relaunchedStore.drafts.first(where: { $0.id == draft.id })
    )
    let restoredAttachment = try XCTUnwrap(
      restoredDraft.attachments.first(where: { $0.id == attachment.id })
    )
    let managedPath = try XCTUnwrap(restoredAttachment.sourceFilePath)

    XCTAssertNotEqual(managedPath, sourceURL.path)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: managedPath)),
      expectedData
    )
  }
}
