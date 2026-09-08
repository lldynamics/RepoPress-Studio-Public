import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class UIOptimizationWindowPresentationTests: XCTestCase {
  func testOpeningAnotherWindowDoesNotResetExplicitAssistantVisibility() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("UIOptimizationWindow-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: directory.appendingPathComponent("workspace.json"))
    )
    let presentation = store.rootPresentation
    presentation.prepareInitialWindowPresentation()
    let draft = try XCTUnwrap(store.selectedDraft)
    XCTAssertTrue(store.ai.openChatWorkspace(for: draft.id))
    XCTAssertTrue(presentation.isAssistantPresented)
    presentation.prepareInitialWindowPresentation()
    XCTAssertTrue(presentation.isAssistantPresented)
  }
}
