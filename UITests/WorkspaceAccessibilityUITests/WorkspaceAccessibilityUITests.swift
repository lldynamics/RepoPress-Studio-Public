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
    let testDataRoot = try testDataRoot(for: appURL)
    knowledgeLibraryRootURL = testDataRoot.url
      .appendingPathComponent("PersonalSitePublisherMac-AccessibilityUITests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    if !testDataRoot.isTargetAppContainer {
      try FileManager.default.createDirectory(at: knowledgeLibraryRootURL, withIntermediateDirectories: true)
    }
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

    select(
      "workspace-sidebar-library",
      revealing: "knowledge-source-list"
    )

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
      "knowledge-library-content-presentation-picker",
      "knowledge-library-reclean-button",
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

  func testOperationalSidebarQuickSearchIdentifiersRemainUnique() throws {
    launchApplication(surface: "writing")
    select(
      "workspace-sidebar-sync",
      revealing: "repository-workspace"
    )

    for identifier in [
      "workspace-quick-search",
      "workspace-quick-search-field",
      "repository-sidebar-stage-navigation",
      "repository-sidebar-stage-overview",
      "repository-sidebar-stage-changes",
      "repository-sidebar-stage-history",
      "workspace-quick-search-results",
    ] {
      assertUniqueIdentifier(identifier)
    }

    let searchField = element(identifier: "workspace-quick-search-field")
    searchField.click()
    // Use digits so the test remains independent of the user's active input method.
    // Latin text can stay in an uncommitted Pinyin composition and never update
    // SwiftUI's binding, which makes the conditional clear button look missing.
    searchField.typeText("404")
    assertUniqueIdentifier("workspace-quick-search-clear")

    element(identifier: "workspace-quick-search-clear").tap()
    assertUniqueIdentifier("workspace-quick-search-results")
  }

  func testRepositoryWorkspaceIdentifiersRemainUniqueAcrossAllStages() throws {
    launchApplication(surface: "writing")
    select(
      "workspace-sidebar-sync",
      revealing: "repository-workspace"
    )

    let overviewIdentifiers = [
      "repository-workspace",
      "repository-primary-actions",
      "repository-action-select-folder",
      "repository-action-scan",
      "repository-action-import",
      "repository-action-migrate",
      "repository-action-open-publish",
      "repository-next-action",
      "repository-section-summary",
      "repository-section-information",
      "repository-section-online-publish",
      "repository-section-auto-sync",
      "repository-section-local-preview",
      "repository-section-sync-plan",
      "repository-section-path-rules",
    ]
    for identifier in overviewIdentifiers {
      revealByScrolling(identifier)
      assertUniqueIdentifier(identifier)
    }

    select(
      "repository-sidebar-stage-changes",
      revealing: "repository-section-remote-changes"
    )
    for identifier in [
      "repository-workspace",
      "repository-section-remote-changes",
      "repository-section-local-changes",
    ] {
      assertUniqueIdentifier(identifier)
    }

    select(
      "repository-sidebar-stage-history",
      revealing: "repository-section-release-history"
    )
    let historyIdentifiers = [
      "repository-section-release-history",
      "release-history-header",
      "release-history-primary-metrics",
      "release-history-action-queue",
      "release-history-records",
      "release-history-deployment-overview",
      "release-history-deployment-polling",
      "release-history-deployment-status",
      "release-history-deployment-debug",
    ]
    let releaseHistoryLayoutIdentifier = revealAnyByScrolling([
      "release-history-main-column",
      "release-history-narrow-content",
    ])
    if releaseHistoryLayoutIdentifier == "release-history-main-column" {
      assertUniqueIdentifier("release-history-main-column")
      revealByScrolling("release-history-deployment-column")
      assertUniqueIdentifier("release-history-deployment-column")
      XCTAssertEqual(elementCount(identifier: "release-history-narrow-content"), 0)
    } else if releaseHistoryLayoutIdentifier == "release-history-narrow-content" {
      assertUniqueIdentifier("release-history-narrow-content")
      XCTAssertEqual(elementCount(identifier: "release-history-main-column"), 0)
      XCTAssertEqual(elementCount(identifier: "release-history-deployment-column"), 0)
    }
    for identifier in historyIdentifiers {
      revealByScrolling(identifier)
      assertUniqueIdentifier(identifier)
    }
  }

  func testImageWorkbenchIdentifiersRemainUniqueAndDoNotOverrideChildControls() throws {
    launchApplication(surface: "writing")
    select(
      "workspace-sidebar-images",
      revealing: "image-workbench-overview"
    )

    for identifier in [
      "workspace-quick-search",
      "workspace-quick-search-field",
      "image-sidebar-stage-navigation",
      "image-sidebar-stage-overview",
      "image-sidebar-stage-issues",
      "image-sidebar-stage-repository",
      "image-workbench",
      "image-workbench-open-folder",
      "image-workbench-open-writing",
      "image-workbench-refresh",
      "image-workbench-overview",
      "image-workbench-actions",
      "image-action-fill-metadata",
      "image-action-optimize-jpeg",
      "image-action-convert-webp",
      "image-action-optimize-svg",
      "image-action-resize-large-images",
    ] {
      assertUniqueIdentifier(identifier)
    }

    select(
      "image-sidebar-stage-issues",
      revealing: "image-issue-workspace"
    )
    for identifier in [
      "image-workbench",
      "image-issue-workspace",
      "image-issue-search",
      "image-issue-filter",
    ] {
      assertUniqueIdentifier(identifier)
    }

    select(
      "image-sidebar-stage-repository",
      revealing: "repository-image-browser"
    )
    for identifier in [
      "image-workbench",
      "repository-image-browser",
    ] {
      assertUniqueIdentifier(identifier)
    }
  }

  func testContentHealthIdentifiersRemainUniqueAcrossAllStages() throws {
    launchApplication(surface: "writing")
    select(
      "workspace-sidebar-contentHealth",
      revealing: "content-health-stage-overview"
    )

    for identifier in [
      "workspace-quick-search",
      "workspace-quick-search-field",
      "content-health-sidebar-stage-navigation",
      "content-health-sidebar-stage-overview",
      "content-health-sidebar-stage-publicRisks",
      "content-health-sidebar-stage-aiFixes",
      "content-health-sidebar-stage-siteIssues",
      "content-health-sidebar-stage-maintenance",
      "content-health-workspace",
      "content-health-stage-overview",
    ] {
      assertUniqueIdentifier(identifier)
    }

    for stage in ["publicRisks", "aiFixes", "siteIssues", "maintenance"] {
      select(
        "content-health-sidebar-stage-\(stage)",
        revealing: "content-health-stage-\(stage)"
      )
      assertUniqueIdentifier("content-health-workspace")
      assertUniqueIdentifier("content-health-stage-\(stage)")
    }

    for identifier in [
      "site-maintenance-refresh",
      "site-maintenance-copy-sprint-plan",
      "site-maintenance-copy-checklist",
    ] {
      assertUniqueIdentifier(identifier)
    }
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
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST"] = "1"
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST_REPOSITORY_ROOT"] = knowledgeLibraryRootURL
      .appendingPathComponent("repository-fixture", isDirectory: true)
      .path
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

  private func select(
    _ controlIdentifier: String,
    revealing destinationIdentifier: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let destination = element(identifier: destinationIdentifier)
    for _ in 0..<3 {
      application.activate()
      let control = element(identifier: controlIdentifier)
      guard control.waitForExistence(timeout: 5) else {
        continue
      }
      control
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        .tap()
      if destination.waitForExistence(timeout: 5) {
        return
      }
    }
    XCTFail(
      "Selecting \(controlIdentifier) did not reveal \(destinationIdentifier).",
      file: file,
      line: line
    )
  }

  private func revealByScrolling(
    _ identifier: String,
    maxSwipes: Int = 8,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let destination = element(identifier: identifier)
    if destination.exists {
      return
    }

    let window = application.windows.firstMatch
    guard window.waitForExistence(timeout: 5) else {
      XCTFail(
        "The app window was unavailable while revealing \(identifier).",
        file: file,
        line: line
      )
      return
    }
    for _ in 0..<maxSwipes {
      application.activate()
      window.swipeUp()
      if destination.waitForExistence(timeout: 2) {
        return
      }
    }
    for _ in 0..<maxSwipes {
      application.activate()
      window.swipeDown()
      if destination.waitForExistence(timeout: 2) {
        return
      }
    }
    XCTFail(
      "Scrolling did not reveal \(identifier).",
      file: file,
      line: line
    )
  }

  private func revealAnyByScrolling(
    _ identifiers: [String],
    maxSwipes: Int = 8,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> String? {
    if let identifier = identifiers.first(where: { element(identifier: $0).exists }) {
      return identifier
    }

    let window = application.windows.firstMatch
    guard window.waitForExistence(timeout: 5) else {
      XCTFail(
        "The app window was unavailable while revealing one of \(identifiers).",
        file: file,
        line: line
      )
      return nil
    }
    for _ in 0..<maxSwipes {
      application.activate()
      window.swipeUp()
      if let identifier = identifiers.first(where: { element(identifier: $0).exists }) {
        return identifier
      }
    }
    XCTFail(
      "Scrolling did not reveal any of \(identifiers).",
      file: file,
      line: line
    )
    return nil
  }

  private func elementCount(identifier: String) -> Int {
    application.descendants(matching: .any).matching(identifier: identifier).count
  }

  private func element(identifier: String) -> XCUIElement {
    application.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func runtimeAppURL() throws -> URL {
    let configuredPath = ProcessInfo.processInfo.environment["WORKBENCH_XCUI_APP_PATH"]
      ?? Bundle(for: Self.self).object(forInfoDictionaryKey: "WorkbenchXCUIAppPath") as? String
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

  private func testDataRoot(for appURL: URL) throws -> (url: URL, isTargetAppContainer: Bool) {
    let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
    let data = try Data(contentsOf: infoPlistURL)
    guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
      throw CocoaError(.propertyListReadCorrupt)
    }
    guard info["PersonalSitePublisherDistributionChannel"] as? String == "AppStore" else {
      return (FileManager.default.temporaryDirectory, false)
    }

    let runtimeHome = (
      ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_RUNTIME_HOME"]
        ?? Bundle(for: Self.self).object(
          forInfoDictionaryKey: "PersonalSitePublisherRuntimeHome"
        ) as? String
    )
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
    return (
      runtimeHome
        .appendingPathComponent("Library/Containers", isDirectory: true)
        .appendingPathComponent(bundleIdentifier, isDirectory: true)
        .appendingPathComponent("Data/tmp", isDirectory: true),
      true
    )
  }
}
