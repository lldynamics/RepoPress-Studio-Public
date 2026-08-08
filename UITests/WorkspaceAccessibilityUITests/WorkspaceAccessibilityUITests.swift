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
      "workspace-sidebar-rss",
      "workspace-sidebar-sync",
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

  func testRSSReaderUsesTheMainWorkspaceFramework() throws {
    launchApplication(surface: "writing")
    let windowCountBeforeSelection = application.windows.count

    select(
      "workspace-sidebar-rss",
      revealing: "rss-reader-workspace"
    )

    for identifier in [
      "workspace-sidebar",
      "workspace-task-navigation",
      "workspace-sidebar-rss",
      "rss-reader-sidebar",
      "rss-reader-workspace",
      "rss-article-list",
      "rss-reader-detail",
    ] {
      assertUniqueIdentifier(identifier)
    }
    XCTAssertEqual(
      application.windows.count,
      windowCountBeforeSelection,
      "Selecting RSS must reuse the main workspace instead of opening another window."
    )
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
      "repository-action-open-images",
      "repository-action-open-publish",
      "repository-next-action",
      "repository-section-summary",
      "repository-section-information",
      "repository-section-git-management",
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

  func testRepeatedWritingAndRepositoryNavigationRemainsResponsive() throws {
    launchApplication(surface: "writing")

    for iteration in 1...3 {
      let repositoryButton = element(identifier: "workspace-sidebar-sync")
      XCTAssertTrue(
        repositoryButton.waitForExistence(timeout: 5),
        "The repository navigation button disappeared before pass \(iteration)."
      )
      repositoryButton
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        .tap()
      XCTAssertTrue(
        element(identifier: "repository-section-summary").waitForExistence(timeout: 5),
        "The repository overview did not remain responsive on pass \(iteration)."
      )

      let writingButton = element(identifier: "workspace-sidebar-writing")
      XCTAssertTrue(
        writingButton.waitForExistence(timeout: 5),
        "The writing navigation button disappeared after repository pass \(iteration)."
      )
      writingButton
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        .tap()
      XCTAssertTrue(
        element(identifier: "writing-draft-list").waitForExistence(timeout: 5),
        "Writing did not become responsive again after repository pass \(iteration)."
      )
    }
  }

  func testPublishDrawerKeepsDecisionChecksAndDiffOnly() throws {
    launchApplication(surface: "sync-api-publish")
    XCTAssertTrue(
      element(identifier: "repository-workspace").waitForExistence(timeout: 10),
      "The repository workspace did not appear for the publishing demo surface."
    )

    revealByScrolling("repository-action-open-publish")
    element(identifier: "repository-action-open-publish")
      .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .tap()

    for identifier in [
      "publish-drawer-header",
      "publish-drawer-action-save-local",
      "publish-drawer-action-publish-all",
      "publish-drawer-action-publish-current",
      "publish-drawer-review-disclosure",
    ] {
      assertUniqueIdentifier(identifier)
    }

    let drawer = application.sheets.firstMatch
    XCTAssertTrue(
      drawer.waitForExistence(timeout: 10),
      "The publish drawer sheet did not remain visible."
    )
    let showAllChecks = drawer.buttons["publish-drawer-review-disclosure"]
    XCTAssertTrue(
      showAllChecks.waitForExistence(timeout: 10),
      "The publish drawer did not expose the checks-and-diff disclosure button."
    )
    showAllChecks.click()
    assertUniqueIdentifier("publish-drawer-check-results")
    assertUniqueIdentifier("publish-drawer-diff")
    Thread.sleep(forTimeInterval: 0.3)

    let screenshot = XCTAttachment(screenshot: application.screenshot())
    screenshot.name = "publish-drawer-simplified"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    for removedSectionTitle in [
      "分支管理",
      "提交历史",
      "线上发布预览",
      "部署",
    ] {
      XCTAssertFalse(
        drawer.descendants(matching: .staticText)[removedSectionTitle].exists,
        "\(removedSectionTitle) must remain outside the publish drawer."
      )
    }
  }

  func testAppStoreEnglishMenusExposeFreeBYOKAIAndReopenMainWindow() throws {
    let appURL = try runtimeAppURL()
    let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
    let infoData = try Data(contentsOf: infoPlistURL)
    let info = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
    )
    guard info["PersonalSitePublisherDistributionChannel"] as? String == "AppStore" else {
      throw XCTSkip("This review regression test only applies to the App Store distribution.")
    }

    launchApplication(
      surface: "writing",
      additionalLaunchArguments: [
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
      ]
    )
    application.activate()

    XCTAssertTrue(
      application.menuBars.menuBarItems["RepoPress Studio"].waitForExistence(timeout: 15),
      "The App Store build must use RepoPress Studio as the visible app and menu name."
    )

    let goMenuItem = application.menuBars.menuBarItems["Go"]
    XCTAssertTrue(
      goMenuItem.waitForExistence(timeout: 15),
      "The English Go menu did not appear."
    )
    goMenuItem.click()
    XCTAssertTrue(
      application.menuItems["Command Palette and Quick Open"].waitForExistence(timeout: 5),
      "The Go menu command titles were not localized to English."
    )

    let goMenu = goMenuItem.menus.firstMatch
    XCTAssertTrue(
      goMenu.waitForExistence(timeout: 5),
      "The Go menu contents were unavailable."
    )
    let goMenuLabels = goMenu.menuItems.allElementsBoundByIndex
      .map(\.label)
      .filter { !$0.isEmpty }
    let mixedGoMenuLabels = goMenuLabels.filter(containsCJK)
    XCTAssertTrue(
      mixedGoMenuLabels.isEmpty,
      "The English Go menu contains Chinese labels: \(mixedGoMenuLabels.joined(separator: ", "))."
    )

    application.typeKey(.escape, modifierFlags: [])
    let publishMenuItem = application.menuBars.menuBarItems["Publish"]
    XCTAssertTrue(
      publishMenuItem.waitForExistence(timeout: 5),
      "The English Publish menu did not appear."
    )
    publishMenuItem.click()
    let publishMenuLabels = publishMenuItem.menus.firstMatch.menuItems.allElementsBoundByIndex
      .map(\.label)
      .filter { !$0.isEmpty }
    let mixedPublishMenuLabels = publishMenuLabels.filter(containsCJK)
    XCTAssertTrue(
      mixedPublishMenuLabels.isEmpty,
      "The English Publish menu contains Chinese labels: \(mixedPublishMenuLabels.joined(separator: ", "))."
    )

    application.typeKey(.escape, modifierFlags: [])
    let aiMenuItem = application.menuBars.menuBarItems["AI"]
    XCTAssertTrue(
      aiMenuItem.waitForExistence(timeout: 5),
      "The App Store build must expose the free BYOK AI menu."
    )
    aiMenuItem.click()
    let openAIChatItem = application.menuItems["Open AI Chat"]
    let closeAIChatItem = application.menuItems["Close AI Chat"]
    let aiChatDeadline = Date().addingTimeInterval(5)
    while !openAIChatItem.exists && !closeAIChatItem.exists && Date() < aiChatDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertTrue(
      openAIChatItem.exists || closeAIChatItem.exists,
      "The App Store AI menu must expose free BYOK AI chat."
    )
    let aiMenuLabels = aiMenuItem.menus.firstMatch.menuItems.allElementsBoundByIndex
      .map(\.label)
      .filter { !$0.isEmpty }
    let mixedAIMenuLabels = aiMenuLabels.filter(containsCJK)
    XCTAssertTrue(
      mixedAIMenuLabels.isEmpty,
      "The English AI menu contains Chinese labels: \(mixedAIMenuLabels.joined(separator: ", "))."
    )

    application.typeKey(.escape, modifierFlags: [])
    let mainWindow = application.windows.firstMatch
    let closeButton = mainWindow.buttons[XCUIIdentifierCloseWindow]
    XCTAssertTrue(
      closeButton.waitForExistence(timeout: 5),
      "The main workbench window close button was unavailable."
    )
    closeButton.click()

    let windowMenu = application.menuBars.menuBarItems["Window"]
    XCTAssertTrue(
      windowMenu.waitForExistence(timeout: 5),
      "The Window menu was unavailable after closing the main window."
    )
    windowMenu.click()
    let reopenItem = application.menuItems["Show RepoPress Studio"]
    XCTAssertTrue(
      reopenItem.waitForExistence(timeout: 5),
      "Window > Show RepoPress Studio is missing."
    )
    reopenItem.click()
    let reopenDeadline = Date().addingTimeInterval(10)
    while !application.windows.firstMatch.isHittable, Date() < reopenDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertTrue(
      application.windows.firstMatch.isHittable,
      "Window > Show RepoPress Studio did not reopen the main workbench window."
    )
  }

  func testImageWorkbenchIdentifiersRemainUniqueAndDoNotOverrideChildControls() throws {
    launchApplication(surface: "writing")
    select(
      "workspace-sidebar-sync",
      revealing: "repository-workspace"
    )
    select(
      "repository-action-open-images",
      revealing: "image-workbench-overview"
    )

    for identifier in [
      "workspace-quick-search",
      "workspace-quick-search-field",
      "image-sidebar-stage-navigation",
      "image-sidebar-stage-overview",
      "image-sidebar-stage-resources",
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
      "image-sidebar-stage-resources",
      revealing: "repository-image-browser"
    )
    for identifier in [
      "image-workbench",
      "image-workbench-resources",
      "image-resource-mode-picker",
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

  func testAICollaborationInspectorStaysInMainWindowAndPreservesDraft() throws {
    launchApplication(surface: "writing")

    let initialWindowCount = application.windows.count
    let toolbarButton = element(identifier: "ai-assistant-toolbar-button")
    XCTAssertTrue(toolbarButton.waitForExistence(timeout: 10))
    toggleAIInspectorForUITest(toolbarButton, shouldBePresented: true)

    assertUniqueIdentifier("ai-assistant-inspector")
    for identifier in [
      "ai-assistant-context-mode",
      "ai-assistant-conversation-picker",
      "ai-assistant-input",
      "ai-assistant-send-button",
      "ai-assistant-close",
    ] {
      assertUniqueIdentifier(identifier)
    }
    XCTAssertEqual(
      application.windows.count,
      initialWindowCount,
      "Opening AI collaboration must not create another window."
    )

    let contextMode = element(identifier: "ai-assistant-context-mode")
    let contextValue = try XCTUnwrap(contextMode.value as? String)
    XCTAssertTrue(
      ["当前文章", "Current Article"].contains(contextValue),
      "The collaboration workspace should open in the current-article context."
    )

    let sendButton = element(identifier: "ai-assistant-send-button")
    XCTAssertFalse(sendButton.isEnabled, "An empty composer must not be sendable.")

    let input = element(identifier: "ai-assistant-input")
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.click()
    input.typeText("offline accessibility check")
    XCTAssertFalse(
      sendButton.isEnabled,
      "The screenshot fixture has no API Key; drafting text must not make Send actionable."
    )
    application.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
    let unsentDraft = try XCTUnwrap(input.value as? String)
    XCTAssertFalse(unsentDraft.isEmpty, "Typing must leave a composer draft to preserve.")

    application.typeKey("l", modifierFlags: [.control, .command])
    let mainWindow = application.windows.firstMatch
    let quickHideOverlays = mainWindow.descendants(matching: .any)
      .matching(identifier: "quick-hide-overlay")
    XCTAssertTrue(
      quickHideOverlays.firstMatch.waitForExistence(timeout: 10),
      "Quick Hide must cover the AI collaboration workspace."
    )
    XCTAssertFalse(
      mainWindow.descendants(matching: .any)
        .matching(identifier: "ai-assistant-input")
        .firstMatch.exists,
      "Quick Hide must remove the AI composer from the accessibility tree."
    )

    application.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    let restoredInput = mainWindow.descendants(matching: .any)
      .matching(identifier: "ai-assistant-input")
      .firstMatch
    XCTAssertTrue(
      restoredInput.waitForExistence(timeout: 10),
      "Returning to the workbench must restore the AI composer."
    )
    XCTAssertEqual(
      restoredInput.value as? String,
      unsentDraft,
      "Quick Hide must preserve an unsent AI composer draft."
    )

    toggleAIInspectorForUITest(toolbarButton, shouldBePresented: false)
    XCTAssertFalse(
      element(identifier: "ai-assistant-inspector").waitForExistence(timeout: 2),
      "The AI collaboration workspace did not close in place."
    )

    toggleAIInspectorForUITest(toolbarButton, shouldBePresented: true)
    let reopenedInput = element(identifier: "ai-assistant-input")
    XCTAssertTrue(
      reopenedInput.waitForExistence(timeout: 10),
      "The AI collaboration workspace could not be reopened."
    )
    XCTAssertEqual(
      reopenedInput.value as? String,
      unsentDraft,
      "Closing and reopening the Inspector must preserve its unsent draft."
    )
    XCTAssertEqual(
      application.windows.count,
      initialWindowCount,
      "The AI collaboration flow must remain in the main window."
    )
  }

  private func launchApplication(
    surface: String,
    additionalLaunchArguments: [String] = []
  ) {
    application.terminate()
    application.launchArguments = [
      "-ApplePersistenceIgnoreState", "YES",
      "-NSQuitAlwaysKeepsWindows", "NO",
    ] + additionalLaunchArguments
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

  private func toggleAIInspectorForUITest(
    _ toolbarButton: XCUIElement,
    shouldBePresented: Bool
  ) {
    application.activate()
    application.typeKey("a", modifierFlags: [.option, .command])

    let inspector = element(identifier: "ai-assistant-inspector")
    let shortcutReachedExpectedState = inspector.waitForExistence(timeout: 2) == shouldBePresented
    if !shortcutReachedExpectedState {
      toolbarButton.click()
    }
  }

  private func containsCJK(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      (0x3400...0x4DBF).contains(scalar.value)
        || (0x4E00...0x9FFF).contains(scalar.value)
    }
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
