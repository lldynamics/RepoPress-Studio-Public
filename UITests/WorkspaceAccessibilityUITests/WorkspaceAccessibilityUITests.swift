import Foundation
import XCTest
import XCUIAutomation

@MainActor
final class WorkspaceAccessibilityUITests: XCTestCase {
  private var application: XCUIApplication!
  private var knowledgeLibraryRootURL: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false

    let appURL = try runtimeAppURL()
    application = XCUIApplication(url: appURL)
    knowledgeLibraryRootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMac-AccessibilityUITests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: knowledgeLibraryRootURL, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    application?.terminate()
    application = nil
    if let knowledgeLibraryRootURL {
      try? FileManager.default.removeItem(at: knowledgeLibraryRootURL)
    }
    knowledgeLibraryRootURL = nil
  }

  func testSidebarIdentifiersRemainUniqueAcrossWritingAndLibrary() throws {
    launchApplication(surface: "writing")

    let persistentIdentifiers = [
      "workspace-sidebar",
      "workspace-task-navigation",
      "workspace-sidebar-writing",
      "workspace-sidebar-library",
      "workspace-sidebar-sync",
      "workspace-sidebar-images",
      "workspace-sidebar-contentHealth",
    ]
    let writingIdentifiers = [
      "writing-create-menu",
      "writing-draft-search",
      "writing-draft-list",
    ]

    for identifier in persistentIdentifiers + writingIdentifiers {
      assertUniqueIdentifier(identifier)
    }

    let libraryButton = element(identifier: "workspace-sidebar-library")
    libraryButton.tap()

    for identifier in persistentIdentifiers + [
      "knowledge-source-list",
      "knowledge-source-search",
    ] {
      assertUniqueIdentifier(identifier)
    }
  }

  func testKnowledgeDetailIdentifiersRemainUniqueAndActionSpecific() throws {
    launchApplication(surface: "knowledge-library")

    let detailIdentifiers = [
      "knowledge-library-detail",
      "knowledge-library-detail-title",
      "knowledge-library-reader",
      "knowledge-library-inspector-toggle",
      "knowledge-library-pin-toggle",
      "knowledge-library-actions-menu",
      "knowledge-library-import-button",
    ]
    for identifier in detailIdentifiers {
      assertUniqueIdentifier(identifier)
    }

    XCTAssertEqual(
      element(identifier: "knowledge-library-detail-title").label,
      "资料库辅助功能演示",
      "The detail title identifier must remain attached to the selected document title."
    )
  }

  private func launchApplication(surface: String) {
    application.terminate()
    application.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES",
      "-NSQuitAlwaysKeepsWindows", "NO",
    ]
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO"] = "1"
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE"] = surface
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_KNOWLEDGE_ROOT"] = knowledgeLibraryRootURL.path
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_DISABLE_CAPTURE_WINDOW_BRIDGE"] = "1"
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST"] = "1"
    application.launch()

    XCTAssertTrue(
      application.windows.firstMatch.waitForExistence(timeout: 15),
      "The main workbench window did not appear for the \(surface) surface."
    )
  }

  private func assertUniqueIdentifier(
    _ identifier: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let matches = application.descendants(matching: .any).matching(identifier: identifier)
    XCTAssertTrue(
      matches.firstMatch.waitForExistence(timeout: 10),
      "No runtime accessibility element was found for \(identifier).",
      file: file,
      line: line
    )
    XCTAssertEqual(
      matches.count,
      1,
      "Expected exactly one runtime accessibility element for \(identifier), but found \(matches.count).",
      file: file,
      line: line
    )
  }

  private func element(identifier: String) -> XCUIElement {
    application.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func runtimeAppURL() throws -> URL {
    let configuredPath = ProcessInfo.processInfo.environment["WORKBENCH_XCUI_APP_PATH"]
    let appURL: URL
    if let configuredPath, !configuredPath.isEmpty {
      appURL = URL(fileURLWithPath: configuredPath, isDirectory: true).standardizedFileURL
    } else {
      appURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("dist/PersonalSitePublisherMac.app", isDirectory: true)
        .standardizedFileURL
    }
    guard FileManager.default.fileExists(atPath: appURL.path) else {
      XCTFail("Packaged workbench app does not exist: \(appURL.path)")
      throw CocoaError(.fileNoSuchFile)
    }
    return appURL
  }
}
