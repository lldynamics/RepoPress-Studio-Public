import AppKit
import XCTest

@testable import PersonalSitePublisherMac

final class WorkbenchShortcutRequestTests: XCTestCase {
  func testRoutesOnlyRecognizedNonPublishingURLs() throws {
    XCTAssertEqual(WorkbenchShortcutRequest(url: try url("repopress://new-article")), .newArticle)
    XCTAssertEqual(
      WorkbenchShortcutRequest(url: try url("repopress://publish-current")), .publishCurrentArticle)
    XCTAssertEqual(WorkbenchShortcutRequest(url: try url("repopress://site-checks")), .siteChecks)
    let id = UUID()
    XCTAssertEqual(
      WorkbenchShortcutRequest(url: try url("repopress://open-article?id=\(id)")), .openArticle(id))
    for input in [
      "https://new-article", "repopress://user@new-article", "repopress://new-article:9",
      "repopress://publish-current?confirm=true", "repopress://publish-current/now",
      "repopress://site-checks#extra", "repopress://open-article?id=bad",
      "repopress://open-article?id=\(id)&id=\(id)", "repopress://push",
    ] {
      XCTAssertNil(WorkbenchShortcutRequest(url: try url(input)), input)
    }
  }

  @MainActor
  func testColdLaunchWaitsForReadyKeyWindowAndRunsExactlyOnce() {
    let coordinator = WorkbenchShortcutCoordinator()
    let background = UUID()
    let foreground = UUID()
    var delivered: [WorkbenchShortcutRequest] = []
    coordinator.enqueue(.newArticle)
    coordinator.register(windowID: background, isKeyWindow: false) { _ in
      XCTFail("Background window consumed a shortcut")
    }
    XCTAssertEqual(coordinator.pendingCount, 1)
    coordinator.register(windowID: foreground, isKeyWindow: true) { delivered.append($0) }
    XCTAssertEqual(delivered, [.newArticle])
    XCTAssertEqual(coordinator.pendingCount, 0)
    coordinator.register(windowID: foreground, isKeyWindow: true) { delivered.append($0) }
    XCTAssertEqual(delivered.count, 1)
    coordinator.unregister(windowID: foreground)
    coordinator.enqueue(.siteChecks)
    XCTAssertEqual(coordinator.pendingCount, 1)
  }

  private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

  @MainActor
  func testActivationRestoresLastWorkbenchWindowAndDropsClosedWindow() {
    let selection = WorkbenchShortcutWindowSelection()
    let first = NSWindow()
    let current = NSWindow()
    selection.record(current)
    XCTAssertTrue(selection.preferredWindow(in: [first, current]) === current)
    XCTAssertTrue(selection.preferredWindow(in: [first]) === first)
    XCTAssertNil(selection.preferredWindow(in: []))
  }

  @MainActor
  func testTranslationCreatedInSheetKeepsItsOwningWindowSelection() {
    let session = WorkspaceWindowSession(selectedSection: .writing)
    let translatedID = UUID()
    var sharedSelection: UUID?
    session.selectContext(section: .writing, draftID: translatedID) { _, id in
      sharedSelection = id
    }
    XCTAssertEqual(session.selectedDraftID, translatedID)
    XCTAssertNil(sharedSelection)
    session.setKeyWindow(true) { _, id in sharedSelection = id }
    XCTAssertEqual(session.selectedDraftID, translatedID)
    XCTAssertEqual(sharedSelection, translatedID)
  }
}
