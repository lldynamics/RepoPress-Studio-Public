import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MacMarkdownComposerFrontMatterConflictTests: XCTestCase {
  func testInvalidFrontMatterRecoveryRejectsMetadataChangedInAnotherWindow() throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "MacMarkdownComposerFrontMatterConflict-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: rootURL.appendingPathComponent("workbench.json")),
      safeMode: true
    )
    let original = try XCTUnwrap(store.selectedDraft)
    let recoveryMetadataRevision = original.editorMetadataRevision

    var secondWindowDraft = original
    secondWindowDraft.tags = ["another-window"]
    XCTAssertTrue(store.updateDraftFromEditor(secondWindowDraft))

    let current = try XCTUnwrap(store.draft(for: original.id))
    XCTAssertNotEqual(current.editorMetadataRevision, recoveryMetadataRevision)
    XCTAssertFalse(
      MacMarkdownFrontMatterRecoveryConflictPolicy.hasMatchingMetadataRevision(
        baseline: recoveryMetadataRevision,
        current: current.editorMetadataRevision
      )
    )
    XCTAssertFalse(
      MacMarkdownFrontMatterRecoveryConflictPolicy.hasMatchingMetadataRevision(
        baseline: nil,
        current: current.editorMetadataRevision
      )
    )
  }
}
