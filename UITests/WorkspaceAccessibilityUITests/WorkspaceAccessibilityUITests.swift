import Foundation
import XCTest
import XCUIAutomation

@MainActor
final class WorkspaceAccessibilityUITests: XCTestCase {
  private var application: XCUIApplication!
  private var knowledgeLibraryRootURL: URL!
  private var screenshotRuntimeRootURL: URL!

  override func setUpWithError() throws {
    continueAfterFailure = false

    let appURL = try runtimeAppURL()
    application = XCUIApplication(url: appURL)
    let temporaryTestDataRoot = testDataRoot()
    knowledgeLibraryRootURL =
      temporaryTestDataRoot
      .appendingPathComponent("PersonalSitePublisherMac-AccessibilityUITests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: knowledgeLibraryRootURL,
      withIntermediateDirectories: true
    )
    screenshotRuntimeRootURL =
      knowledgeLibraryRootURL
      .appendingPathComponent("runtime", isDirectory: true)
    try FileManager.default.createDirectory(
      at: screenshotRuntimeRootURL.appendingPathComponent("tmp", isDirectory: true),
      withIntermediateDirectories: true
    )
  }

  override func tearDownWithError() throws {
    application?.terminate()
    application = nil
    if let knowledgeLibraryRootURL {
      try? FileManager.default.removeItem(at: knowledgeLibraryRootURL)
    }
    knowledgeLibraryRootURL = nil
    screenshotRuntimeRootURL = nil
  }

  func testSidebarIdentifiersRemainUniqueAcrossWritingAndLibrary() throws {
    launchApplication(surface: "writing")

    let persistentIdentifiers = [
      "workspace-sidebar",
      "workspace-task-navigation",
      "workspace-sidebar-rss",
      "workspace-sidebar-library",
      "workspace-sidebar-sync",
      "workspace-sidebar-contentHealth",
      "workspace-sidebar-writing",
    ]
    let writingIdentifiers = [
      "writing-create-menu",
      "writing-draft-search",
      "writing-draft-list",
    ]

    for identifier in persistentIdentifiers + writingIdentifiers {
      assertUniqueIdentifier(identifier)
    }

    select("workspace-sidebar-library", revealing: "knowledge-source-list")

    for identifier in persistentIdentifiers + [
      "workspace-sidebar-library",
      "workspace-sidebar-rss",
      "knowledge-source-list",
      "knowledge-source-search",
    ] {
      assertUniqueIdentifier(identifier)
    }
  }

  func testFivePrimaryRoutesRevealTheirDestinationsDirectly() throws {
    launchApplication(
      surface: "sync-api-publish",
      screenshotContentSize: CGSize(width: 1080, height: 720)
    )
    let window = application.windows.firstMatch
    XCTAssertGreaterThanOrEqual(window.frame.width, 960)
    XCTAssertLessThan(window.frame.width, 1180, "Expected compact Inspector band: \(window.frame)")

    let routes = [
      (
        section: "workspace-sidebar-rss",
        destination: "rss-reader-workspace"
      ),
      (
        section: "workspace-sidebar-library",
        destination: "knowledge-source-list"
      ),
      (
        section: "workspace-sidebar-sync",
        destination: "repository-workspace"
      ),
      (
        section: "workspace-sidebar-contentHealth",
        destination: "content-health-workspace"
      ),
      (
        section: "workspace-sidebar-writing",
        destination: "writing-draft-list"
      ),
    ]

    for route in routes {
      select(route.section, revealing: route.destination, in: window)
    }

    // At 1080pt the Inspector can be revealed on demand. The full sidebar is
    // replaced by the compact rail, whose five icon buttons must keep routing
    // inside this same workbench window.
    let compactWindow = window
    let compactWindowIdentifier = compactWindow.identifier
    XCTAssertFalse(compactWindowIdentifier.isEmpty)
    let editor = compactWindow.descendants(matching: .any)
      .matching(identifier: "markdown-document-editor")
      .firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    let draftBody = try XCTUnwrap(editor.value as? String)

    let inspectorToggle = compactWindow.descendants(matching: .any)
      .matching(identifier: "workspace-inspector-toggle")
      .firstMatch
    XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 10))
    XCTAssertTrue(inspectorToggle.isEnabled)
    inspectorToggle.click()

    let compactRail = compactWindow.descendants(matching: .any)
      .matching(identifier: "workspace-compact-navigation-rail")
      .firstMatch
    XCTAssertTrue(compactRail.waitForExistence(timeout: 10))
    for section in ["rss", "library", "sync", "contentHealth", "writing"] {
      let button = compactWindow.buttons
        .matching(identifier: "workspace-compact-rail-\(section)")
        .firstMatch
      XCTAssertTrue(button.waitForExistence(timeout: 5))
      XCTAssertTrue(button.isHittable, "Compact \(section) route must be directly hittable.")
    }

    let rssButton = compactWindow.buttons
      .matching(identifier: "workspace-compact-rail-rss")
      .firstMatch
    rssButton.click()
    XCTAssertTrue(
      compactWindow.descendants(matching: .any)
        .matching(identifier: "rss-reader-workspace")
        .firstMatch
        .waitForExistence(timeout: 10)
    )
    XCTAssertEqual(application.windows.count, 1)
    XCTAssertEqual(application.windows.firstMatch.identifier, compactWindowIdentifier)

    let writingButton = compactWindow.buttons
      .matching(identifier: "workspace-compact-rail-writing")
      .firstMatch
    writingButton.click()
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    XCTAssertEqual(editor.value as? String, draftBody)
  }

  func testFirstRunRepositoryWithArticleOpensRecentArticleForWriting() throws {
    let repositoryRoot = try makeFirstRunRepository(withArticle: true)
    launchFirstRunApplication()
    openFirstRunSetupWizard()
    completeFirstRunRepositorySetup(at: repositoryRoot)

    let handoff = element(identifier: "first-run-writing-handoff")
    XCTAssertTrue(handoff.waitForExistence(timeout: 15))
    XCTAssertTrue(
      element(identifier: "first-run-writing-summary").waitForExistence(timeout: 45),
      application.windows.firstMatch.debugDescription)
    let openRecent = element(identifier: "first-run-open-recent-article")
    XCTAssertTrue(openRecent.waitForExistence(timeout: 5))
    openRecent.click()

    XCTAssertTrue(element(identifier: "writing-draft-list").waitForExistence(timeout: 15))
    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(editor.waitForExistence(timeout: 15))
    XCTAssertTrue((editor.value as? String)?.contains("这是首次设置导入文章。") == true)
  }

  func testFirstRunEmptyRepositoryCreatesFirstArticleForWriting() throws {
    let repositoryRoot = try makeFirstRunRepository(withArticle: false)
    launchFirstRunApplication()
    openFirstRunSetupWizard()
    completeFirstRunRepositorySetup(at: repositoryRoot)

    let handoff = element(identifier: "first-run-writing-handoff")
    XCTAssertTrue(handoff.waitForExistence(timeout: 15))
    XCTAssertTrue(
      element(identifier: "first-run-writing-summary").waitForExistence(timeout: 45),
      application.windows.firstMatch.debugDescription)
    let createArticle = element(identifier: "first-run-create-article")
    XCTAssertTrue(createArticle.waitForExistence(timeout: 5))
    createArticle.click()

    XCTAssertTrue(element(identifier: "writing-draft-list").waitForExistence(timeout: 15))
    XCTAssertTrue(element(identifier: "markdown-document-editor").waitForExistence(timeout: 15))
  }

  func testMarkdownSlashCommandMenuSupportsKeyboardAndAccessibleCommands() throws {
    launchApplication(surface: "writing")

    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(
      editor.waitForExistence(timeout: 10),
      "The writing demo must expose the Markdown editor to accessibility."
    )
    editor.click()
    application.typeKey(.downArrow, modifierFlags: [.command])
    application.typeKey(.return, modifierFlags: [])
    application.typeText("/")
    XCTAssertTrue(
      (editor.value as? String)?.hasSuffix("\n/") == true,
      "Slash must be entered on the new final line: \(String((editor.value as? String ?? "").suffix(100)))"
    )

    let menu = element(identifier: "markdown-slash-command-menu")
    let heading1 = element(identifier: "markdown-slash-command-h1")
    let slashMenuAppeared = menu.waitForExistence(timeout: 3)
    if !slashMenuAppeared {
      let diagnostic = XCTAttachment(string: application.debugDescription)
      diagnostic.name = "Slash command hierarchy after typing"
      diagnostic.lifetime = .keepAlways
      add(diagnostic)
    }
    XCTAssertTrue(
      slashMenuAppeared,
      "The slash command menu must appear after both body and caret updates settle."
    )
    XCTAssertTrue(heading1.waitForExistence(timeout: 3))
    XCTAssertEqual(heading1.label, "一级标题")
    XCTAssertEqual(heading1.value as? String, "# 大标题")

    application.typeKey(.downArrow, modifierFlags: [])
    application.typeKey(.return, modifierFlags: [])
    XCTAssertFalse(
      menu.waitForExistence(timeout: 2),
      "Return must choose the keyboard-selected slash command and close the menu."
    )
    XCTAssertTrue(
      (editor.value as? String)?.hasSuffix("\n## ") == true,
      "Down then Return must apply the second slash command without inserting a newline."
    )

    application.typeKey(.return, modifierFlags: [])
    application.typeText("/")
    XCTAssertTrue(
      (editor.value as? String)?.hasSuffix("\n## \n/") == true,
      "The next slash must follow the newly inserted empty heading."
    )
    XCTAssertTrue(menu.waitForExistence(timeout: 3))
    application.typeKey(.escape, modifierFlags: [])
    XCTAssertFalse(
      menu.waitForExistence(timeout: 2),
      "Escape must dismiss the slash command menu."
    )
  }

  func testSheetNavigationKeepsThePresentingWindowDraftAfterDismissal() throws {
    launchApplication(surface: "sync-api-publish")
    let window = application.windows.firstMatch
    select("workspace-sidebar-writing", revealing: "writing-draft-list", in: window)

    let firstArticle = window.staticTexts["RepoPress Studio 发布流程"]
    XCTAssertTrue(firstArticle.waitForExistence(timeout: 10))
    firstArticle.click()
    let editor = window.descendants(matching: .any)
      .matching(identifier: "markdown-document-editor")
      .firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    let originalBody = try XCTUnwrap(editor.value as? String)

    application.typeKey("p", modifierFlags: [.command])
    let palette = element(identifier: "workspace-command-palette")
    XCTAssertTrue(palette.waitForExistence(timeout: 10))
    let paletteQueryField = palette.textFields.firstMatch
    XCTAssertTrue(paletteQueryField.waitForExistence(timeout: 5))
    paletteQueryField.click()
    paletteQueryField.typeText("新建文章")
    let createDraft = palette.descendants(matching: .any)
      .matching(identifier: "workspace-command-palette-result-command:automation:createDraft")
      .firstMatch
    XCTAssertTrue(createDraft.waitForExistence(timeout: 10))
    createDraft.click()
    assertDisappears(palette)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", originalBody),
            object: editor
          )
        ],
        timeout: 10
      ),
      .completed,
      "A draft created in the palette sheet must remain selected after its parent window regains focus."
    )

    // Start over with a known article, then exercise the sheet result path.
    firstArticle.click()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", originalBody),
            object: editor
          )
        ],
        timeout: 10
      ),
      .completed
    )
    application.typeKey("f", modifierFlags: [.option, .command])
    // macOS exposes the NavigationStack as a native sheet; its outer SwiftUI
    // identifier is not necessarily represented in the accessibility tree.
    let search = window.sheets.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    let queryField = search.textFields["搜索文章或输入结构化条件"]
    XCTAssertTrue(queryField.waitForExistence(timeout: 5))
    queryField.click()
    queryField.typeText("客户复盘")
    let open = search.buttons["打开所选结果"]
    XCTAssertTrue(open.waitForExistence(timeout: 10))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: open
          )
        ],
        timeout: 10
      ),
      .completed,
      "The filtered fixture result must finish its asynchronous search before opening."
    )
    open.click()
    assertDisappears(search)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", originalBody),
            object: editor
          )
        ],
        timeout: 10
      ),
      .completed,
      "Opening a full-text result must update the presenting window before the sheet closes."
    )
  }

  /// Focused responsive/accessibility smoke: this deliberately uses the
  /// smallest supported window and a large Dynamic Type size, then exercises
  /// the existing editor keyboard path. It is not a substitute for a manual
  /// VoiceOver run.
  func testWritingMinimumWindowAndAccessibilityTypeKeepsEditorAndToolbarsAccessible() throws {
    launchApplication(
      surface: "writing",
      screenshotContentSize: CGSize(width: 900, height: 620),
      dynamicTypeSize: "accessibility3"
    )

    let window = application.windows.firstMatch
    XCTAssertGreaterThanOrEqual(window.frame.width, 900)
    XCTAssertGreaterThanOrEqual(window.frame.height, 620)

    let requiredIdentifiers = [
      "workspace-sidebar",
      "writing-draft-list",
      "markdown-document-editor",
      "markdown-editor-toolbar",
      "markdown-formatting-toolbar",
      "markdown-zen-mode-toggle",
      "markdown-outline-button",
    ]
    for identifier in requiredIdentifiers {
      assertUniqueIdentifier(identifier)
      let control = element(identifier: identifier)
      XCTAssertFalse(
        control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "Accessibility label must not be empty for \(identifier)."
      )
      XCTAssertFalse(control.frame.isEmpty, "Accessibility frame must exist for \(identifier).")
    }

    let editor = element(identifier: "markdown-document-editor")
    editor.click()
    application.typeKey(XCUIKeyboardKey.tab.rawValue, modifierFlags: [])
    XCTAssertTrue(
      element(identifier: "markdown-formatting-toolbar").waitForExistence(timeout: 3),
      "Tab navigation must keep the formatting toolbar in the accessibility tree."
    )
    application.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(editor.exists, "Escape must not remove the editor from the workspace.")
  }

  func testRSSReaderUsesTheMainWorkspaceFramework() throws {
    launchApplication(surface: "writing")
    let windowCountBeforeSelection = application.windows.count
    let inspectorToggle = element(identifier: "workspace-inspector-toggle")
    XCTAssertTrue(
      inspectorToggle.waitForExistence(timeout: 10),
      "The shared Inspector toggle was unavailable before opening RSS."
    )
    if !element(identifier: "workspace-inspector").exists {
      inspectorToggle.click()
      XCTAssertTrue(
        element(identifier: "workspace-inspector").waitForExistence(timeout: 10),
        "The shared Inspector did not open before the RSS route change."
      )
    }

    select(
      "workspace-sidebar-rss",
      revealing: "rss-article-list"
    )

    for identifier in [
      "workspace-sidebar",
      "workspace-task-navigation",
      "workspace-sidebar-rss",
      "rss-reader-sidebar",
      "rss-reader-workspace",
      "rss-article-list",
    ] {
      assertUniqueIdentifier(identifier)
    }
    XCTAssertTrue(
      element(identifier: "rss-library-inspector-panel").waitForExistence(timeout: 10),
      "Selecting RSS must keep the shared Inspector open and route it to RSS content."
    )

    let articleRow = application.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "rss-article-row-"))
      .firstMatch
    XCTAssertTrue(
      articleRow.waitForExistence(timeout: 10),
      "The RSS fixture article was unavailable."
    )
    articleRow
      .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .tap()
    assertUniqueIdentifier("rss-reader-detail")

    XCTAssertEqual(
      application.windows.count,
      windowCountBeforeSelection,
      "Selecting RSS must reuse the main workspace instead of opening another window."
    )
  }

  func testReleaseBundleLaunchesWithoutScreenshotFixture() throws {
    let appURL = try runtimeAppURL()
    let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
    let infoData = try Data(contentsOf: infoPlistURL)
    let info = try XCTUnwrap(
      try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any]
    )
    let isScreenshotCaptureBuild = try XCTUnwrap(
      info["PersonalSitePublisherScreenshotCaptureBuild"] as? Bool
    )
    guard !isScreenshotCaptureBuild else {
      throw XCTSkip("This regression test only applies to a normal packaged build.")
    }

    launchApplication(surface: nil)

    let dataRootSetup = element(identifier: "workbench-data-root-setup")
    let workspace = element(identifier: "workspace-sidebar")
    let deadline = Date().addingTimeInterval(15)
    while !dataRootSetup.exists && !workspace.exists && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertTrue(
      dataRootSetup.exists || workspace.exists,
      "A normal packaged build must expose either first-run setup or the ready workspace without screenshot fixtures."
    )
    XCTAssertEqual(
      application.windows.count,
      1,
      "The non-screenshot launch regression must keep one main application window."
    )
  }

  /// The PR lane deliberately keeps this to one isolated fixture: it proves
  /// that article navigation remains local to each WindowGroup instance while
  /// the privacy-wide Quick Hide masks both, then stops at final confirmation.
  func testPRSmokeKeepsWindowsIsolatedAndCancelsPublishConfirmation() throws {
    launchApplication(surface: "sync-api-publish")

    let initialWindow = application.windows.firstMatch
    XCTAssertTrue(initialWindow.waitForExistence(timeout: 10))
    let firstWindowIdentifier = initialWindow.identifier
    XCTAssertTrue(
      firstWindowIdentifier.hasPrefix("workbench-capture-"),
      "The fixture must expose a window instance identity.")
    let firstWindow = application.windows.matching(identifier: firstWindowIdentifier).firstMatch
    select("workspace-sidebar-writing", revealing: "writing-draft-list", in: firstWindow)
    let firstArticle = firstWindow.staticTexts["RepoPress Studio 发布流程"]
    XCTAssertTrue(firstArticle.waitForExistence(timeout: 10))
    firstArticle.click()
    let firstEditor = firstWindow.descendants(matching: .any)
      .matching(identifier: "markdown-document-editor")
      .firstMatch
    XCTAssertTrue(firstEditor.waitForExistence(timeout: 10))
    let firstEditorValue = try XCTUnwrap(firstEditor.value as? String)

    application.typeKey("n", modifierFlags: [.command, .shift])
    let secondWindowDeadline = Date().addingTimeInterval(10)
    while application.windows.count < 2 && Date() < secondWindowDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertEqual(
      application.windows.count, 2, "Shift-Command-N must create one additional workbench window.")
    let secondWindowIdentifier = try XCTUnwrap(
      application.windows.allElementsBoundByIndex.map(\.identifier).first(where: {
        !$0.isEmpty && $0 != firstWindowIdentifier
      }),
      "The second workbench window did not retain a distinct identity."
    )
    let secondWindow = application.windows.matching(identifier: secondWindowIdentifier).firstMatch
    XCTAssertTrue(secondWindow.waitForExistence(timeout: 10))
    secondWindow.click()
    select("workspace-sidebar-writing", revealing: "writing-draft-list", in: secondWindow)
    let secondArticle = secondWindow.staticTexts["私密客户复盘草稿"]
    XCTAssertTrue(secondArticle.waitForExistence(timeout: 10))
    secondArticle.click()
    let secondEditor = secondWindow.descendants(matching: .any)
      .matching(identifier: "markdown-document-editor")
      .firstMatch
    XCTAssertTrue(secondEditor.waitForExistence(timeout: 10))
    XCTAssertNotEqual(
      secondEditor.value as? String,
      firstEditorValue,
      "Selecting an article in the second window must not replace the first window's document."
    )
    XCTAssertEqual(
      firstEditor.value as? String,
      firstEditorValue,
      "The first window must keep its article after the second window changes selection."
    )

    secondWindow.click()
    application.typeKey("l", modifierFlags: [.control, .command])
    let secondQuickHide = secondWindow.descendants(matching: .any)
      .matching(identifier: "quick-hide-overlay")
      .firstMatch
    XCTAssertTrue(secondQuickHide.waitForExistence(timeout: 10))
    XCTAssertTrue(
      firstWindow.descendants(matching: .any)
        .matching(identifier: "quick-hide-overlay")
        .firstMatch.waitForExistence(timeout: 10),
      "Quick Hide must mask every workbench window because privacy state is shared."
    )
    application.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    assertDisappears(secondQuickHide)
    assertDisappears(
      firstWindow.descendants(matching: .any)
        .matching(identifier: "quick-hide-overlay")
        .firstMatch
    )

    // Capture fixtures use identical window frames. A coordinate click on the
    // first window would hit the frontmost second window instead. With exactly
    // two windows, the system's cycle-window command raises the first one.
    application.typeKey("`", modifierFlags: [.command])
    select("workspace-sidebar-sync", revealing: "repository-workspace", in: firstWindow)
    let preparePublish = firstWindow.descendants(matching: .any)
      .matching(identifier: "workspace-prepare-publish")
      .firstMatch
    XCTAssertTrue(preparePublish.waitForExistence(timeout: 10))
    preparePublish.click()
    let scopePicker = firstWindow.descendants(matching: .any)
      .matching(identifier: "publish-drawer-scope")
      .firstMatch
    XCTAssertTrue(scopePicker.waitForExistence(timeout: 10))
    selectPublishScope("当前文章", in: scopePicker)
    let publishCurrent = firstWindow.descendants(matching: .any)
      .matching(identifier: "publish-drawer-action-publish-current")
      .firstMatch
    XCTAssertTrue(publishCurrent.waitForExistence(timeout: 10))
    XCTAssertTrue(
      publishCurrent.isEnabled, "The fixture must reach a review-only publish confirmation.")
    clickVisibleDrawerControl(publishCurrent)

    let confirmation = application.sheets.firstMatch
    XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
    let cancel = confirmation.buttons["取消"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    cancel.click()
    assertDisappears(
      confirmation,
      "Cancelling the publish confirmation must close it before any publish is started.")

    let screenshot = XCTAttachment(screenshot: application.screenshot())
    screenshot.name = "pr-isolated-window-smoke"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testKnowledgeDetailIdentifiersRemainUniqueAndActionSpecific() throws {
    launchApplication(surface: "knowledge-library")

    let source = element(identifier: "knowledge-source-list")
      .staticTexts
      .matching(
        NSPredicate(
          format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
          "资料库辅助功能演示", "资料库辅助功能演示"
        )
      )
      .firstMatch
    let seedStatusURL = knowledgeLibraryRootURL.appendingPathComponent("fixture-seed-status.txt")
    let sourceAppeared = source.waitForExistence(timeout: 15)
    XCTAssertTrue(
      sourceAppeared,
      "Knowledge fixture: \((try? String(contentsOf: seedStatusURL, encoding: .utf8)) ?? "not started")"
    )
    source.click()

    let detailIdentifiers = [
      "knowledge-library-detail",
      "knowledge-library-detail-title",
      "knowledge-library-reader",
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

    let inspectorToggle = element(identifier: "workspace-inspector-toggle")
    XCTAssertTrue(
      inspectorToggle.waitForExistence(timeout: 10),
      "The knowledge workspace must use the shared Inspector toolbar toggle."
    )
    if inspectorToggle.value as? String == "已隐藏" {
      XCTAssertTrue(inspectorToggle.isEnabled)
      application.activate()
      inspectorToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }
    XCTAssertTrue(
      element(identifier: "knowledge-library-inspector").waitForExistence(timeout: 10),
      "The shared Inspector must route to the selected knowledge document. "
        + "Workspace inspector: \(element(identifier: "workspace-inspector").exists); "
        + "empty selection: \(application.staticTexts["没有选中的资料"].exists); "
        + "toggle: \(String(describing: inspectorToggle.value))."
    )
    assertUniqueIdentifier("knowledge-library-inspector")
  }

  func testKnowledgeWritingTargetSearchAndSelectionPreserveLibraryRoute() throws {
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_PERSISTENCE_ROOT"] =
      knowledgeLibraryRootURL.appendingPathComponent("workbench", isDirectory: true).path
    launchApplication(surface: "knowledge-library")

    let picker = element(identifier: "knowledge-writing-target-picker")
    XCTAssertTrue(picker.waitForExistence(timeout: 15))
    picker.click()
    let search = element(identifier: "knowledge-writing-target-search")
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    let list = element(identifier: "knowledge-writing-target-list")
    let rows = list.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "knowledge-writing-target-")
    )
    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
    let initialCount = rows.count
    XCTAssertGreaterThan(initialCount, 1)

    search.click()
    search.typeText("98765432109876543210")
    XCTAssertTrue(application.staticTexts["没有匹配的文章"].waitForExistence(timeout: 5))
    XCTAssertEqual(rows.count, 0)
    application.typeKey("a", modifierFlags: .command)
    application.typeKey(.delete, modifierFlags: [])
    XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
    XCTAssertEqual(rows.count, initialCount)

    let target = try XCTUnwrap(rows.allElementsBoundByIndex.first(where: { $0.isEnabled }))
    let targetID = target.identifier
    target.click()
    assertIdentifierDisappears("knowledge-writing-target-search")
    XCTAssertTrue(element(identifier: "knowledge-source-list").exists)

    picker.click()
    let selectedTarget = element(identifier: targetID)
    XCTAssertTrue(selectedTarget.waitForExistence(timeout: 5))
    XCTAssertFalse(selectedTarget.isEnabled)
    element(identifier: "knowledge-return-to-writing").click()
    XCTAssertTrue(element(identifier: "writing-draft-list").waitForExistence(timeout: 5))
    assertIdentifierDisappears("knowledge-writing-target-search")
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
      "repository-action-data-management",
      "repository-action-open-images",
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
    revealByScrolling("repository-section-more-tools")
    let moreTools = application.disclosureTriangles["repository-section-more-tools"]
    clickScrollableControl(moreTools, in: element(identifier: "repository-workspace"))
    XCTAssertEqual(String(describing: moreTools.value ?? ""), "1")
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
      select("workspace-sidebar-sync", revealing: "repository-workspace")
      assertUniqueIdentifier("workspace-sidebar-sync")
      XCTAssertTrue(
        element(identifier: "repository-section-summary").waitForExistence(timeout: 5),
        "The repository overview did not remain responsive on pass \(iteration)."
      )

      select("workspace-sidebar-writing", revealing: "writing-draft-list")
      assertUniqueIdentifier("workspace-sidebar-writing")
      XCTAssertTrue(
        element(identifier: "writing-draft-list").waitForExistence(timeout: 5),
        "Writing did not become responsive again after repository pass \(iteration)."
      )
    }
  }

  func testArticleRepairReturnsToTheSameArticlePublishScope() throws {
    launchApplication(surface: "writing")
    let windowID = application.windows.firstMatch.identifier
    let window = application.windows.matching(identifier: windowID).firstMatch
    let editor = window.descendants(matching: .any)
      .matching(identifier: "markdown-document-editor").firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    let originalBody = try XCTUnwrap(editor.value as? String)

    let prepare = window.buttons.matching(identifier: "workspace-prepare-publish").firstMatch
    XCTAssertTrue(prepare.isEnabled)
    prepare.click()
    let scope = element(identifier: "publish-drawer-scope")
    XCTAssertTrue(scope.waitForExistence(timeout: 10))
    XCTAssertEqual(String(describing: scope.radioButtons["当前文章"].value ?? ""), "1")
    let metadataIssue = window.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
        "publish-readiness-action-", "编辑元数据"
      )
    ).firstMatch
    XCTAssertTrue(metadataIssue.waitForExistence(timeout: 10))
    clickVisibleDrawerControl(metadataIssue)
    XCTAssertTrue(element(identifier: "article-publish-repair-bar").waitForExistence(timeout: 10))
    XCTAssertEqual(editor.value as? String, originalBody)
    XCTAssertFalse(application.sheets.firstMatch.exists)

    application.typeKey("r", modifierFlags: [.option, .command])
    XCTAssertTrue(scope.waitForExistence(timeout: 10))
    XCTAssertEqual(String(describing: scope.radioButtons["当前文章"].value ?? ""), "1")
    assertIdentifierDisappears("article-publish-repair-bar")
    XCTAssertEqual(editor.value as? String, originalBody)
    XCTAssertFalse(application.sheets.firstMatch.exists, "Returning must never start a publish.")
  }

  func testPublishDrawerKeepsDecisionChecksAndDiffOnly() throws {
    launchApplication(surface: "sync-api-publish")
    XCTAssertTrue(
      element(identifier: "repository-workspace").waitForExistence(timeout: 10),
      "The repository workspace did not appear for the publishing demo surface."
    )
    assertUniqueIdentifier("workspace-prepare-publish")

    let preparePublish = element(identifier: "workspace-prepare-publish")
    XCTAssertTrue(preparePublish.isEnabled)
    preparePublish.click()
    assertUniqueIdentifier("publish-drawer-header")
    assertUniqueIdentifier("publish-drawer-action-publish-all")

    let scope = element(identifier: "publish-drawer-scope")
    selectPublishScope("应用文章", in: scope)
    assertUniqueIdentifier("publish-drawer-unified-summary")
    selectPublishScope("当前文章", in: scope)
    for identifier in [
      "publish-drawer-readiness-checklist",
      "publish-drawer-action-publish-current",
      "publish-drawer-review-disclosure",
    ] {
      assertUniqueIdentifier(identifier)
    }
    let localActions = application.disclosureTriangles["publish-drawer-local-actions"]
    XCTAssertTrue(localActions.waitForExistence(timeout: 5))
    clickVisibleDrawerControl(localActions)
    XCTAssertEqual(String(describing: localActions.value ?? ""), "1")
    assertUniqueIdentifier("publish-drawer-action-save-local")

    XCTAssertFalse(
      application.sheets.firstMatch.exists,
      "The publish drawer should use the trailing workspace inspector, not a modal sheet."
    )
    let showAllChecks = element(identifier: "publish-drawer-review-disclosure")
    XCTAssertTrue(
      showAllChecks.waitForExistence(timeout: 10),
      "The publish drawer did not expose the checks-and-diff disclosure button."
    )
    clickVisibleDrawerControl(showAllChecks)
    assertUniqueIdentifier("publish-drawer-diff")
    Thread.sleep(forTimeInterval: 0.3)

    let screenshot = XCTAttachment(screenshot: application.screenshot())
    screenshot.name = "publish-drawer-simplified"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    let drawer = element(identifier: "workspace-publish-drawer-overlay")
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

  func testMenuMutationsAndMainWindowRecoveryRemainStable() throws {
    launchApplication(
      surface: "writing",
      additionalLaunchArguments: [
        "-AppleLanguages", "(en)",
        "-AppleLocale", "en_US",
      ]
    )
    application.activate()

    for iteration in 0..<12 {
      application.typeKey(.escape, modifierFlags: [])
      guard
        let fileMenuItem = waitForHittableElement(
          timeout: 15,
          query: {
            application.menuBars.menuBarItems.matching(identifier: "File")
          })
      else {
        XCTFail("File was unavailable during menu stress iteration \(iteration).")
        return
      }
      fileMenuItem.click()
      let fileMenu = fileMenuItem.menus.firstMatch
      guard fileMenu.waitForExistence(timeout: 5) else {
        XCTFail("File did not open during menu stress iteration \(iteration).")
        return
      }
      guard
        let siteRepositoryItem = waitForHittableElement(
          timeout: 5,
          query: {
            application.menuItems.matching(identifier: "Site Repository")
          })
      else {
        XCTFail("Site Repository was unavailable during menu stress iteration \(iteration).")
        return
      }
      siteRepositoryItem.click()

      let siteRepositoryMenu = siteRepositoryItem.menus.firstMatch
      guard siteRepositoryMenu.waitForExistence(timeout: 5) else {
        XCTFail("Site Repository did not open during iteration \(iteration).")
        return
      }
      guard
        let copyCommand = waitForHittableElement(
          timeout: 5,
          query: {
            application.menuItems.matching(identifier: "Copy Suggested Sync Commands")
          })
      else {
        XCTFail("Copy Suggested Sync Commands was unavailable during iteration \(iteration).")
        return
      }
      copyCommand.click()
      XCTAssertNotEqual(
        application.state,
        .notRunning,
        "The app terminated during menu mutation iteration \(iteration)."
      )
    }

    for iteration in 0..<3 {
      let mainWindow = application.windows.firstMatch
      XCTAssertTrue(
        mainWindow.waitForExistence(timeout: 10),
        "The main window was unavailable before recovery iteration \(iteration)."
      )
      let closeButton = mainWindow.buttons[XCUIIdentifierCloseWindow]
      XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
      closeButton.click()

      application.typeKey(.escape, modifierFlags: [])
      guard
        let windowMenuItem = waitForHittableElement(
          timeout: 5,
          query: {
            application.menuBars.menuBarItems.matching(identifier: "Window")
          })
      else {
        XCTFail("Window was unavailable during recovery iteration \(iteration).")
        return
      }
      windowMenuItem.click()
      let windowMenu = windowMenuItem.menus.firstMatch
      guard windowMenu.waitForExistence(timeout: 5) else {
        XCTFail("Window did not open during recovery iteration \(iteration).")
        return
      }
      guard
        let reopenItem = waitForHittableElement(
          timeout: 5,
          query: {
            application.menuItems.matching(identifier: "Show RepoPress Studio")
          })
      else {
        XCTFail("Show RepoPress Studio was unavailable during recovery iteration \(iteration).")
        return
      }
      XCTAssertEqual(
        windowMenu.menuItems.matching(identifier: "Show RepoPress Studio").count,
        1,
        "The recovery command must remain unique."
      )
      reopenItem.click()

      let reopenDeadline = Date().addingTimeInterval(10)
      while !application.windows.firstMatch.isHittable, Date() < reopenDeadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      }
      XCTAssertTrue(
        application.windows.firstMatch.isHittable,
        "The main window did not recover during iteration \(iteration)."
      )
      XCTAssertNotEqual(application.state, .notRunning)
    }
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
    XCTAssertFalse(
      element(identifier: "workspace-quick-search-field").exists,
      "The image workspace must not expose an article search field that cannot return image results."
    )

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

  func testImageWorkbenchReturnsToWritingInThePresentingWindow() throws {
    launchApplication(surface: "sync-api-publish")
    let firstWindowIdentifier = application.windows.firstMatch.identifier
    // firstMatch is a live query: opening B can reorder it to point at B.
    // Keep A's identity fixed throughout this two-window interaction.
    let firstWindow = application.windows.matching(identifier: firstWindowIdentifier).firstMatch
    XCTAssertTrue(firstWindowIdentifier.hasPrefix("workbench-capture-"))

    select("workspace-sidebar-writing", revealing: "writing-draft-list", in: firstWindow)
    let firstArticle = firstWindow.staticTexts["RepoPress Studio 发布流程"]
    XCTAssertTrue(firstArticle.waitForExistence(timeout: 10))
    firstArticle.click()
    let firstEditor = firstWindow.descendants(matching: .any)
      .matching(identifier: "markdown-document-editor")
      .firstMatch
    XCTAssertTrue(firstEditor.waitForExistence(timeout: 10))
    let firstEditorValue = try XCTUnwrap(firstEditor.value as? String)

    select("workspace-sidebar-sync", revealing: "repository-workspace", in: firstWindow)
    select("repository-action-open-images", revealing: "image-workbench-overview", in: firstWindow)
    let imageWorkbench = firstWindow.descendants(matching: .any)
      .matching(identifier: "image-workbench")
      .firstMatch
    XCTAssertTrue(imageWorkbench.waitForExistence(timeout: 10))

    application.typeKey("n", modifierFlags: [.command, .shift])
    let twoWindows = XCTNSPredicateExpectation(
      predicate: NSPredicate { object, _ in
        (object as? XCUIApplication)?.windows.count == 2
      }, object: application)
    XCTAssertEqual(XCTWaiter.wait(for: [twoWindows], timeout: 10), .completed)
    let secondWindowIdentifier = try XCTUnwrap(
      application.windows.allElementsBoundByIndex.map(\.identifier).first(where: {
        !$0.isEmpty && $0 != firstWindowIdentifier
      })
    )
    let secondWindow = application.windows.matching(identifier: secondWindowIdentifier).firstMatch
    XCTAssertTrue(secondWindow.waitForExistence(timeout: 10))
    secondWindow.click()
    select("workspace-sidebar-writing", revealing: "writing-draft-list", in: secondWindow)
    let secondArticle = secondWindow.staticTexts["私密客户复盘草稿"]
    XCTAssertTrue(secondArticle.waitForExistence(timeout: 10))
    secondArticle.click()
    let secondEditor = secondWindow.descendants(matching: .any)
      .matching(identifier: "markdown-document-editor")
      .firstMatch
    XCTAssertTrue(secondEditor.waitForExistence(timeout: 10))
    let secondEditorValue = try XCTUnwrap(secondEditor.value as? String)

    // Capture fixtures place both windows at the same coordinates, so clicking
    // A's center would hit B. Use the native window cycle to bring A forward.
    application.activate()
    if application.windows.firstMatch.identifier != firstWindowIdentifier {
      application.typeKey("`", modifierFlags: [.command])
    }
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
              self.application.windows.firstMatch.identifier == firstWindowIdentifier
            },
            object: application
          )
        ],
        timeout: 5
      ),
      .completed,
      "The presenting window must be frontmost before its handoff control is clicked."
    )
    // A's control must route through A's WindowGroup and keep B's article intact.
    let openWriting = try XCTUnwrap(
      waitForHittableElement(timeout: 10) {
        firstWindow.buttons.matching(identifier: "image-workbench-open-writing")
      },
      "The presenting window must expose a hittable writing handoff action."
    )
    XCTAssertTrue(openWriting.isEnabled, "The writing handoff must be actionable in the fixture.")
    openWriting.click()

    XCTAssertTrue(
      firstWindow.descendants(matching: .any)
        .matching(identifier: "writing-draft-list")
        .firstMatch.waitForExistence(timeout: 10),
      "Opening writing from Images must return to the writing section."
    )
    assertDisappears(
      imageWorkbench,
      "Opening writing from Images must dismiss the image workbench in place."
    )
    XCTAssertEqual(
      firstWindow.descendants(matching: .any)
        .matching(identifier: "markdown-document-editor")
        .firstMatch.value as? String,
      firstEditorValue,
      "Returning to Writing must restore the article selected in the presenting window."
    )
    XCTAssertTrue(
      secondWindow.descendants(matching: .any)
        .matching(identifier: "writing-draft-list")
        .firstMatch.waitForExistence(timeout: 10),
      "The other workbench window must remain in its Writing section."
    )
    XCTAssertEqual(
      secondWindow.descendants(matching: .any)
        .matching(identifier: "markdown-document-editor")
        .firstMatch.value as? String,
      secondEditorValue,
      "Returning to Writing in A must not replace the article still selected in B."
    )
    XCTAssertEqual(
      application.windows.count,
      2,
      "The image-to-writing handoff must preserve both existing workbench windows."
    )
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

    let generateReport = application.buttons["生成维护报告"]
    XCTAssertTrue(generateReport.waitForExistence(timeout: 10))
    generateReport.click()

    for identifier in [
      "site-maintenance-refresh",
      "site-maintenance-copy-sprint-plan",
      "site-maintenance-copy-checklist",
    ] {
      assertUniqueIdentifier(identifier)
    }
  }

  func testAIComposerUsesReturnForNewlineAndKeepsCommandReturnOutOfText() throws {
    launchApplication(surface: "writing")

    let mainWindow = application.windows.firstMatch
    guard
      let writingAIEntry = waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "ai-assistant-toolbar-button")
        })
    else {
      XCTFail("The writing toolbar must expose the AI collaboration entry.")
      return
    }
    writingAIEntry.click()

    let input = mainWindow.descendants(matching: .any)
      .matching(identifier: "ai-assistant-input")
      .firstMatch
    XCTAssertTrue(input.waitForExistence(timeout: 10))
    input.click()
    input.typeText("123")
    application.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    input.typeText("456")

    let multilineDraft = try XCTUnwrap(input.value as? String)
    XCTAssertEqual(
      multilineDraft,
      "123\n456",
      "Plain Return must insert a newline instead of submitting or swallowing the key."
    )
    application.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [.command])
    XCTAssertEqual(
      input.value as? String,
      multilineDraft,
      "Command-Return must stay out of the text system instead of inserting another newline."
    )
  }

  func testAIInspectorKeyboardShortcutTogglesInMainWindow() {
    launchApplication(surface: "writing")

    let mainWindow = application.windows.firstMatch
    guard
      waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "ai-assistant-toolbar-button")
        }) != nil
    else {
      XCTFail("The writing toolbar must be ready before exercising its keyboard command.")
      return
    }
    let initialWindowCount = application.windows.count
    let inspector = mainWindow.descendants(matching: .any)
      .matching(identifier: "ai-assistant-inspector")
      .firstMatch
    XCTAssertFalse(inspector.exists, "The AI Inspector must start hidden.")

    application.typeKey("a", modifierFlags: [.option, .command])
    guard inspector.waitForExistence(timeout: 10) else {
      XCTFail("Option-Command-A must open the AI Inspector in the current window.")
      return
    }
    XCTAssertTrue(mainWindow.exists)
    XCTAssertEqual(application.windows.count, initialWindowCount)

    application.typeKey("a", modifierFlags: [.option, .command])
    let dismissed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: inspector
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [dismissed], timeout: 5),
      .completed,
      "Option-Command-A must close the AI Inspector without a pointer fallback."
    )
    XCTAssertTrue(mainWindow.exists)
    XCTAssertEqual(application.windows.count, initialWindowCount)
  }

  func testAICollaborationInspectorStaysInMainWindowAndPreservesDraft() throws {
    launchApplication(surface: "writing")

    let initialWindowCount = application.windows.count
    let mainWindow = application.windows.firstMatch
    guard
      let writingAIEntry = waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "ai-assistant-toolbar-button")
        })
    else {
      XCTFail("The writing toolbar must expose a directly clickable AI collaboration entry.")
      return
    }
    let mainWindowAIInspector = mainWindow.descendants(matching: .any)
      .matching(identifier: "ai-assistant-inspector")
      .firstMatch
    XCTAssertFalse(
      mainWindowAIInspector.exists,
      "The AI Inspector must be absent before the writing-page entry is clicked."
    )
    guard
      let toolbarButton = waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "ai-assistant-toolbar-button")
        })
    else {
      XCTFail("The main toolbar must keep its AI collaboration entry visible and clickable.")
      return
    }
    guard
      let inspectorToolbarButton = waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "workspace-inspector-toggle")
        })
    else {
      XCTFail(
        "The main toolbar must keep the original workspace Inspector entry visible and clickable.")
      return
    }
    XCTAssertFalse(
      toolbarButton.frame.intersects(inspectorToolbarButton.frame),
      "The AI and workspace Inspector toolbar entries must remain separate controls."
    )
    XCTAssertGreaterThan(
      inspectorToolbarButton.frame.midX,
      toolbarButton.frame.midX,
      "The workspace Inspector entry must remain immediately after the AI collaboration entry."
    )
    writingAIEntry.click()
    XCTAssertTrue(
      mainWindowAIInspector.waitForExistence(timeout: 10),
      "Clicking the writing-page AI entry must open the Inspector in the main window."
    )
    XCTAssertGreaterThan(
      mainWindowAIInspector.frame.midX,
      mainWindow.frame.midX,
      "The AI collaboration Inspector must occupy the right side of the writing window."
    )

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

  func testPublishDrawerYieldsToToolbarInspectorDestinations() throws {
    launchApplication(surface: "writing")

    let mainWindow = application.windows.firstMatch
    guard
      let publishButton = waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "workspace-prepare-publish")
        }),
      let aiButton = waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "ai-assistant-toolbar-button")
        }),
      let inspectorButton = waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "workspace-inspector-toggle")
        }),
      let settingsButton = waitForHittableElement(
        timeout: 10,
        query: {
          mainWindow.descendants(matching: .any)
            .matching(identifier: "workspace-open-settings")
        })
    else {
      XCTFail("The primary toolbar actions must all remain directly clickable.")
      return
    }

    let taskCenterButton = mainWindow.descendants(matching: .any)
      .matching(identifier: "workspace-task-center-toggle")
      .firstMatch
    let sidebarButton = mainWindow.descendants(matching: .any)
      .matching(identifier: "workspace-sidebar-toggle")
      .firstMatch
    let profileMenu = mainWindow.descendants(matching: .any)
      .matching(identifier: "workspace-profile-menu")
      .firstMatch
    let commandSearch = mainWindow.descendants(matching: .any)
      .matching(identifier: "workspace-command-search")
      .firstMatch
    let previewButton = mainWindow.descendants(matching: .any)
      .matching(identifier: "workspace-preview")
      .firstMatch
    XCTAssertTrue(
      sidebarButton.waitForExistence(timeout: 10),
      "The sidebar toggle must lead the native toolbar."
    )
    XCTAssertTrue(
      taskCenterButton.waitForExistence(timeout: 10),
      "The task center must stay directly available in the trailing toolbar group."
    )
    XCTAssertTrue(
      commandSearch.waitForExistence(timeout: 10),
      "The command search must remain between the workspace context and action groups."
    )
    XCTAssertTrue(
      profileMenu.waitForExistence(timeout: 10),
      "The active site selector must remain in the leading toolbar group."
    )
    XCTAssertTrue(
      previewButton.waitForExistence(timeout: 10),
      "The combined preview control must remain visible even when browser preview is unavailable."
    )
    XCTAssertLessThan(sidebarButton.frame.midX, profileMenu.frame.midX)
    XCTAssertLessThan(profileMenu.frame.midX, commandSearch.frame.midX)
    XCTAssertLessThan(commandSearch.frame.midX, previewButton.frame.midX)
    XCTAssertLessThan(previewButton.frame.midX, taskCenterButton.frame.midX)
    XCTAssertLessThan(taskCenterButton.frame.midX, aiButton.frame.midX)
    XCTAssertLessThan(aiButton.frame.midX, inspectorButton.frame.midX)
    XCTAssertLessThan(inspectorButton.frame.midX, settingsButton.frame.midX)
    XCTAssertLessThan(settingsButton.frame.midX, publishButton.frame.midX)

    publishButton.click()
    XCTAssertTrue(
      element(identifier: "workspace-publish-drawer-overlay").waitForExistence(timeout: 10),
      "Prepare Publish must open the publish drawer."
    )

    aiButton.click()
    assertIdentifierDisappears("workspace-publish-drawer-overlay")
    XCTAssertTrue(
      element(identifier: "ai-assistant-inspector").waitForExistence(timeout: 10),
      "The AI toolbar action must replace, rather than sit behind, the publish drawer."
    )

    publishButton.click()
    XCTAssertTrue(
      element(identifier: "workspace-publish-drawer-overlay").waitForExistence(timeout: 10),
      "Prepare Publish must remain available after leaving the AI Inspector."
    )

    inspectorButton.click()
    assertIdentifierDisappears("workspace-publish-drawer-overlay")
    XCTAssertTrue(
      element(identifier: "article-inspector").waitForExistence(timeout: 10),
      "The article Inspector toolbar action must replace, rather than sit behind, the publish drawer."
    )

    publishButton.click()
    XCTAssertTrue(
      element(identifier: "workspace-publish-drawer-overlay").waitForExistence(timeout: 10),
      "Prepare Publish must remain available after leaving the article Inspector."
    )

    settingsButton.click()
    assertIdentifierDisappears("workspace-publish-drawer-overlay")
    XCTAssertTrue(
      element(identifier: "settings-content").waitForExistence(timeout: 10),
      "The Settings toolbar action must replace the publish drawer in the main window."
    )
  }

  func testNativeToolbarControlsKeepTheirOwnAccessibilityNames() throws {
    launchApplication(surface: "writing")

    let expectedNames: [(identifier: String, labels: Set<String>)] = [
      ("workspace-sidebar-toggle", ["隐藏侧栏", "显示侧栏"]),
      ("workspace-publishing-status", ["文章状态"]),
      ("workspace-command-search", ["全局搜索"]),
      ("workspace-preview", ["预览"]),
      ("workspace-task-center-toggle", ["任务", "统一任务中心"]),
    ]

    for (identifier, labels) in expectedNames {
      let control = element(identifier: identifier)
      XCTAssertTrue(
        control.waitForExistence(timeout: 10),
        "The native toolbar must expose \(identifier)."
      )
      XCTAssertTrue(
        labels.contains(control.label),
        "\(identifier) must retain one of \(labels) instead of inheriting an adjacent toolbar control; found \(control.label)."
      )
    }
    let screenshot = XCTAttachment(screenshot: application.screenshot())
    screenshot.name = "native-toolbar-independent-controls"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testCommandPaletteNavigationRestoresThePresentingWindowSection() throws {
    launchApplication(surface: "writing")

    let commandSearch = element(identifier: "workspace-command-search")
    XCTAssertTrue(commandSearch.waitForExistence(timeout: 10))

    commandSearch.click()
    let palette = element(identifier: "workspace-command-palette")
    XCTAssertTrue(
      palette.waitForExistence(timeout: 10),
      "The command palette must be presented as a native sheet before navigation."
    )

    let images = element(
      identifier: "workspace-command-palette-result-command:workspace:images"
    )
    XCTAssertTrue(images.waitForExistence(timeout: 10))
    images.click()
    XCTAssertFalse(
      palette.waitForExistence(timeout: 2),
      "Selecting a command palette workspace result must dismiss its sheet."
    )
    XCTAssertTrue(
      element(identifier: "image-workbench").waitForExistence(timeout: 10),
      "The presenting window must restore as the Images workspace after the sheet resigns key status."
    )

    commandSearch.click()
    XCTAssertTrue(palette.waitForExistence(timeout: 10))
    let library = element(
      identifier: "workspace-command-palette-result-command:workspace:library"
    )
    XCTAssertTrue(library.waitForExistence(timeout: 10))
    library.click()
    XCTAssertTrue(
      element(identifier: "knowledge-source-list").waitForExistence(timeout: 10),
      "The same non-key-sheet path must retain a pending Library section for the presenting window."
    )
  }

  func testSettingsSidebarVisitsEveryPageWithOneContentRoot() throws {
    openSettings()
    let settingsWindow = currentSettingsWindow()

    let pages = [
      (tab: "configurationStatus", content: "configuration-status-settings"),
      (tab: "defaultRules", content: "default-rule-settings"),
      (tab: "token", content: "token-settings"),
      (tab: "ai", content: "ai-settings"),
      (tab: "siteAI", content: "site-ai-settings"),
      (tab: "dataManagement", content: "data-management-settings"),
      (tab: "appearance", content: "appearance-settings"),
      (tab: "editor", content: "editor-settings"),
      (tab: "rss", content: "rss-maintenance-settings"),
      (tab: "privacy", content: "privacy-settings"),
    ]
    let contentIdentifiers = pages.map { $0.content }

    for page in pages {
      assertUniqueIdentifier("settings-tab-\(page.tab)")
    }
    assertSettingsWindowBaseline()

    for page in pages {
      select(
        "settings-tab-\(page.tab)",
        revealing: page.content
      )
      assertUniqueIdentifier("settings-content")
      assertUniqueIdentifier(page.content)
      XCTAssertEqual(
        identifierExists("settings-profile-bar", in: settingsWindow),
        ["configurationStatus", "defaultRules", "token", "siteAI"].contains(page.tab),
        "Only site-scoped pages should expose a site switcher."
      )
      if page.tab == "editor" {
        XCTAssertTrue(
          settingsWindow.sliders["字号"].waitForExistence(timeout: 10),
          "The editor preferences slider must retain its accessible name."
        )
      }

      let visibleContentRoots = contentIdentifiers.filter {
        identifierExists($0, in: settingsWindow)
      }
      XCTAssertEqual(
        visibleContentRoots,
        [page.content],
        "Selecting \(page.tab) must expose exactly one settings page root."
      )
    }
  }

  func testSettingsSharedConnectionAndMovedSearchKeepTheirScopes() throws {
    openSettings()
    let settingsWindow = currentSettingsWindow()
    select("settings-tab-siteAI", revealing: "site-ai-settings")
    let picker = element(identifier: "settings-site-ai-connection-picker")
    XCTAssertTrue(picker.waitForExistence(timeout: 10))
    let originalSelection = picker.value as? String
    XCTAssertNotNil(originalSelection)

    element(identifier: "settings-site-ai-edit-shared-connection").click()
    assertIdentifierExists("ai-settings", in: settingsWindow)
    XCTAssertFalse(identifierExists("settings-site-ai-connection-picker", in: settingsWindow))
    element(identifier: "settings-ai-open-site-connection").click()
    assertIdentifierExists("site-ai-settings", in: settingsWindow)
    XCTAssertEqual(picker.value as? String, originalSelection)

    let search = element(identifier: "settings-search-field")
    search.click()
    search.typeText("全局预设")
    let result = element(identifier: "settings-search-result-appearance.defaults")
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    result.click()
    assertIdentifierExists("editor-settings", in: settingsWindow)
    assertIdentifierExists("settings-global-front-matter-preset", in: settingsWindow)
    let presetVisible = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "hittable == true"),
      object: element(identifier: "settings-global-front-matter-preset")
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [presetVisible], timeout: 5), .completed,
      "The moved search result must scroll the global preset into the visible viewport."
    )
    XCTAssertFalse(identifierExists("settings-profile-bar", in: settingsWindow))
  }

  func testDataManagementSheetsOpenAndCloseWithoutRunningTheirActions() throws {
    openSettings()
    select(
      "settings-tab-dataManagement",
      revealing: "data-management-settings"
    )

    let settingsWindow = currentSettingsWindow()
    forceAccessibilityTraversal(in: settingsWindow)

    let tasks = [
      (
        button: "data-management-task-drafts",
        root: "data-management-drafts-task",
        close: "data-management-drafts-task-close"
      ),
      (
        button: "data-management-task-storage",
        root: "data-management-storage-task",
        close: "data-management-storage-task-close"
      ),
      (
        button: "data-management-task-backup",
        root: "data-management-backup-task",
        close: "data-management-backup-task-close"
      ),
      (
        button: "data-management-task-migration",
        root: "data-management-migration-task",
        close: "data-management-migration-task-cancel"
      ),
    ]

    for task in tasks {
      revealSettingsElement(
        task.button,
        scrollContainerIdentifier: "data-management-settings"
      )
      assertUniqueIdentifier(task.button)

      // Deliberately open only the task container and use its dedicated close
      // control. Never touch backup, restore, cleanup, or migration actions.
      element(identifier: task.button)
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        .tap()

      XCTAssertTrue(
        application.sheets.firstMatch.waitForExistence(timeout: 10),
        "Opening \(task.button) did not present a Settings sheet."
      )
      assertUniqueIdentifier(task.root)
      assertUniqueIdentifier(task.close)

      element(identifier: task.close)
        .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        .tap()
      assertIdentifierDisappears(task.root)
      assertIdentifierExists("data-management-settings", in: settingsWindow)
      forceAccessibilityTraversal(in: settingsWindow)
    }
  }

  func testSettingsRestoresLastTopLevelPageAfterWindowReopens() throws {
    openSettings()
    select(
      "settings-tab-configurationStatus",
      revealing: "configuration-status-settings"
    )
    select(
      "settings-tab-privacy",
      revealing: "privacy-settings"
    )

    let settingsWindow = currentSettingsWindow()
    let closeButton = settingsWindow.buttons[XCUIIdentifierCloseWindow]
    XCTAssertTrue(
      closeButton.waitForExistence(timeout: 5),
      "The Settings window close button was unavailable."
    )
    closeButton.click()
    assertIdentifierDisappears("settings-content")

    application.terminate()
    application.launch()
    XCTAssertTrue(
      application.windows.firstMatch.waitForExistence(timeout: 15),
      "The main workbench window did not return after relaunch."
    )
    showSettingsWindow()
    let reopenedSettingsWindow = currentSettingsWindow()
    assertIdentifierExists("settings-content", in: reopenedSettingsWindow)
    assertUniqueIdentifier("settings-tab-privacy")
    assertIdentifierExists("privacy-settings", in: reopenedSettingsWindow)
    XCTAssertFalse(
      identifierExists("configuration-status-settings", in: reopenedSettingsWindow),
      "Reopening Settings must not replace the restored top-level page."
    )
    assertSettingsWindowBaseline()
  }

  private func openSettings() {
    // Foundation may keep its system temporary directory despite a launch
    // TMPDIR override. Give this settings run an explicit fresh workspace so
    // a stale screenshot fixture cannot open a recovery sheet over the UI.
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_PERSISTENCE_ROOT"] =
      knowledgeLibraryRootURL.appendingPathComponent("settings-workbench", isDirectory: true).path
    launchApplication(surface: "writing")
    showSettingsWindow()

    let settingsWindow = currentSettingsWindow()
    assertIdentifierExists("settings-sidebar", in: settingsWindow)
    assertIdentifierExists("settings-content", in: settingsWindow)
  }

  private func showSettingsWindow(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    application.activate()
    let applicationMenu = application.menuBars.menuBarItems["RepoPress Studio"]
    guard applicationMenu.waitForExistence(timeout: 5) else {
      XCTFail(
        "The RepoPress Studio application menu was unavailable.",
        file: file,
        line: line
      )
      return
    }
    applicationMenu.click()

    let menu = applicationMenu.menus.firstMatch
    guard menu.waitForExistence(timeout: 5) else {
      XCTFail(
        "The RepoPress Studio application menu did not open.",
        file: file,
        line: line
      )
      return
    }
    let settingsMenuItems = menu.menuItems.matching(
      NSPredicate(
        format: "title IN %@",
        ["设置…", "Settings…", "设置...", "Settings..."]
      )
    )
    let settingsMenuItem = settingsMenuItems.firstMatch
    guard settingsMenuItem.waitForExistence(timeout: 5) else {
      XCTFail(
        "The application menu did not expose its Settings action.",
        file: file,
        line: line
      )
      application.typeKey(.escape, modifierFlags: [])
      return
    }
    XCTAssertEqual(
      settingsMenuItems.count,
      1,
      "The application menu must expose exactly one Settings action.",
      file: file,
      line: line
    )
    // Inspect the menu, then use its keyboard equivalent. XCTest can retain
    // an invalid menu hit point while resolving macOS accessibility queries.
    application.typeKey(.escape, modifierFlags: [])
    application.typeKey(",", modifierFlags: [.command])
  }

  private func currentSettingsWindow(
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> XCUIElement {
    let settingsWindow = application.windows
      .containing(.any, identifier: "settings-content")
      .firstMatch
    XCTAssertTrue(
      settingsWindow.waitForExistence(timeout: 10),
      "The Settings window containing settings-content was unavailable.",
      file: file,
      line: line
    )
    return settingsWindow
  }

  private func assertSettingsWindowBaseline(
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let settingsWindow = currentSettingsWindow(file: file, line: line)
    XCTAssertGreaterThanOrEqual(
      settingsWindow.frame.width,
      820,
      "The Settings window is narrower than its supported minimum.",
      file: file,
      line: line
    )
    XCTAssertGreaterThanOrEqual(
      settingsWindow.frame.height,
      560,
      "The Settings window is shorter than its supported minimum.",
      file: file,
      line: line
    )
    assertUniqueIdentifier("settings-content", file: file, line: line)
    XCTAssertFalse(
      identifierExists("settings-save-status", in: settingsWindow),
      "Clean Settings must not show an unsaved, failed-save, or recovery status bar.",
      file: file,
      line: line
    )
  }

  private func assertIdentifierExists(
    _ identifier: String,
    in root: XCUIElement? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let matches: XCUIElementQuery
    if let root {
      matches = root.descendants(matching: .any).matching(identifier: identifier)
    } else {
      matches = application.descendants(matching: .any).matching(identifier: identifier)
    }
    XCTAssertTrue(
      matches.firstMatch.waitForExistence(timeout: 10),
      "No runtime accessibility element was found for \(identifier).",
      file: file,
      line: line
    )
  }

  private func identifierExists(
    _ identifier: String,
    in root: XCUIElement
  ) -> Bool {
    root.descendants(matching: .any)
      .matching(identifier: identifier)
      .firstMatch
      .exists
  }

  private func forceAccessibilityTraversal(
    in root: XCUIElement,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      // Freeze the tree before traversing; live index queries become stale
      // when scrolling or dismissing a sheet changes the visible elements.
      var descendants = try root.snapshot().children
      XCTAssertFalse(
        descendants.isEmpty,
        "The Settings accessibility tree was empty.",
        file: file,
        line: line
      )
      while let descendant = descendants.popLast() {
        _ = descendant.identifier
        _ = descendant.label
        descendants.append(contentsOf: descendant.children)
      }
    } catch {
      XCTFail(
        "Could not snapshot the Settings accessibility tree: \(error)", file: file, line: line)
    }
  }

  private func revealSettingsElement(
    _ identifier: String,
    scrollContainerIdentifier: String,
    maxScrolls: Int = 16,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let destination = element(identifier: identifier)
    if destination.exists && destination.isHittable {
      return
    }

    let scrollContainer = element(identifier: scrollContainerIdentifier)
    guard scrollContainer.waitForExistence(timeout: 5) else {
      XCTFail(
        "The Settings scroll container was unavailable while revealing \(identifier).",
        file: file,
        line: line
      )
      return
    }

    for _ in 0..<maxScrolls {
      application.activate()
      // Use bounded macOS wheel events so a fast swipe cannot skip a task card.
      scrollContainer.scroll(byDeltaX: 0, deltaY: -240)
      if destination.exists && destination.isHittable {
        return
      }
    }
    XCTFail(
      "Scrolling Settings did not reveal \(identifier).",
      file: file,
      line: line
    )
  }

  private func assertIdentifierDisappears(
    _ identifier: String,
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let destination = element(identifier: identifier)
    let deadline = Date().addingTimeInterval(timeout)
    while destination.exists && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTAssertFalse(
      destination.exists,
      "The accessibility element \(identifier) did not disappear.",
      file: file,
      line: line
    )
  }

  private func assertDisappears(
    _ element: XCUIElement,
    _ message: String = "The accessibility element did not disappear.",
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"), object: element)
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, message, file: file,
      line: line)
  }

  private func launchApplication(
    surface: String?,
    additionalLaunchArguments: [String] = [],
    screenshotContentSize: CGSize? = nil,
    dynamicTypeSize: String? = nil
  ) {
    application.terminate()
    application.launchArguments =
      [
        "-ApplePersistenceIgnoreState", "YES",
        "-NSQuitAlwaysKeepsWindows", "NO",
      ] + additionalLaunchArguments
    if let surface {
      application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO"] = "1"
      application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE"] = surface
      application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_KNOWLEDGE_ROOT"] =
        knowledgeLibraryRootURL.path
      application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST"] = "1"
      application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST_REPOSITORY_ROOT"] =
        knowledgeLibraryRootURL
        .appendingPathComponent("repository-fixture", isDirectory: true)
        .path
    } else {
      for key in [
        "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO",
        "PERSONAL_SITE_PUBLISHER_SCREENSHOT_SURFACE",
        "PERSONAL_SITE_PUBLISHER_SCREENSHOT_KNOWLEDGE_ROOT",
        "PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST",
        "PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST_REPOSITORY_ROOT",
      ] {
        application.launchEnvironment.removeValue(forKey: key)
      }
    }
    if let screenshotContentSize {
      application.launchEnvironment[
        "PERSONAL_SITE_PUBLISHER_SCREENSHOT_CONTENT_WIDTH"
      ] = String(Double(screenshotContentSize.width))
      application.launchEnvironment[
        "PERSONAL_SITE_PUBLISHER_SCREENSHOT_CONTENT_HEIGHT"
      ] = String(Double(screenshotContentSize.height))
    } else {
      application.launchEnvironment.removeValue(
        forKey: "PERSONAL_SITE_PUBLISHER_SCREENSHOT_CONTENT_WIDTH"
      )
      application.launchEnvironment.removeValue(
        forKey: "PERSONAL_SITE_PUBLISHER_SCREENSHOT_CONTENT_HEIGHT"
      )
    }
    if let dynamicTypeSize {
      application.launchEnvironment[
        "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DYNAMIC_TYPE_SIZE"
      ] = dynamicTypeSize
    } else {
      application.launchEnvironment.removeValue(
        forKey: "PERSONAL_SITE_PUBLISHER_SCREENSHOT_DYNAMIC_TYPE_SIZE"
      )
    }
    // Settings task sheets may refresh or prune automatic backup fixtures on
    // appearance. Keep all Foundation preferences and temporary demo data in
    // this test-owned directory so opening a sheet cannot touch user data.
    application.launchEnvironment["CFFIXED_USER_HOME"] = screenshotRuntimeRootURL.path
    application.launchEnvironment["HOME"] = screenshotRuntimeRootURL.path
    application.launchEnvironment["TMPDIR"] =
      screenshotRuntimeRootURL
      .appendingPathComponent("tmp", isDirectory: true)
      .path
    application.launch()
    application.activate()

    XCTAssertTrue(
      application.windows.firstMatch.waitForExistence(timeout: 15),
      "The main workbench window did not appear for the \(surface ?? "non-screenshot") surface."
    )
  }

  private func launchFirstRunApplication() {
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_PERSISTENCE_ROOT"] =
      knowledgeLibraryRootURL.appendingPathComponent("workbench", isDirectory: true).path
    launchApplication(surface: "writing")
  }

  private func openFirstRunSetupWizard() {
    application.activate()
    let goMenu = application.menuBars.menuBarItems["前往"]
    XCTAssertTrue(goMenu.waitForExistence(timeout: 10))
    goMenu.click()
    let wizard = application.menuItems["打开设置向导…"]
    XCTAssertTrue(wizard.waitForExistence(timeout: 5))
    wizard.click()
    XCTAssertTrue(application.buttons["连接已有仓库"].waitForExistence(timeout: 10))
  }

  private func completeFirstRunRepositorySetup(at repositoryRoot: URL) {
    let connect = application.buttons["连接已有仓库"]
    XCTAssertTrue(connect.isHittable)
    connect.click()
    let continueButton = application.buttons["继续"]
    XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
    continueButton.click()

    let chooseRepository = application.buttons["更换本地仓库"]
    XCTAssertTrue(chooseRepository.waitForExistence(timeout: 5))
    chooseRepository.click()
    let panel = application.dialogs.firstMatch
    XCTAssertTrue(panel.waitForExistence(timeout: 10))
    application.typeKey("g", modifierFlags: [.command, .shift])
    let locationField = panel.textFields.firstMatch
    XCTAssertTrue(locationField.waitForExistence(timeout: 5))
    locationField.typeText(repositoryRoot.path)
    application.typeKey(.return, modifierFlags: [])

    let selectButton = firstExistingButton(
      in: panel,
      labels: ["选择", "打开", "Choose", "Open"]
    )
    XCTAssertNotNil(selectButton, "The native folder picker did not expose a selection button.")
    selectButton?.click()

    let next = application.buttons["下一步"]
    XCTAssertTrue(next.waitForExistence(timeout: 10))
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: next
          )
        ],
        timeout: 30
      ),
      .completed,
      "Repository detection must enable the real rules step before continuing."
    )
    next.click()
    XCTAssertTrue(application.staticTexts["开启 AI 辅助（可选）"].waitForExistence(timeout: 10))
    let finish = application.buttons["完成并开始写作"]
    XCTAssertTrue(finish.waitForExistence(timeout: 10))
    finish.click()

    let alert = application.alerts.firstMatch
    let apply: XCUIElement
    if alert.waitForExistence(timeout: 3) {
      apply = alert.buttons["应用并开始写作"]
    } else {
      let sheet = application.sheets.firstMatch
      XCTAssertTrue(sheet.waitForExistence(timeout: 10))
      apply = sheet.buttons["应用并开始写作"]
    }
    XCTAssertTrue(
      apply.waitForExistence(timeout: 10),
      "The confirmation surface must contain one scoped apply button."
    )
    apply.click()
  }

  private func firstExistingButton(in container: XCUIElement, labels: [String]) -> XCUIElement? {
    labels.lazy.map { container.buttons[$0] }.first(where: { $0.exists })
  }

  private func makeFirstRunRepository(withArticle: Bool) throws -> URL {
    let root = knowledgeLibraryRootURL.appendingPathComponent(
      withArticle ? "first-run-zola-article" : "first-run-zola-empty",
      isDirectory: true
    )
    let content = root.appendingPathComponent("content", isDirectory: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    try "base_url = \"https://example.com\"\ntitle = \"首次设置站点\"\n".write(
      to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
    )
    if withArticle {
      let yearDirectory = content.appendingPathComponent("2026", isDirectory: true)
      try FileManager.default.createDirectory(at: yearDirectory, withIntermediateDirectories: true)
      try "+++\ntitle = \"首次设置文章\"\ndate = 2026-09-21\n+++\n\n这是首次设置导入文章。\n".write(
        to: yearDirectory.appendingPathComponent("first.md"), atomically: true, encoding: .utf8
      )
      // Demo articles use a fixed 2030 timestamp. Keep this fixture newer so
      // "open recent" exercises the article imported by this test.
      try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
        ofItemAtPath: yearDirectory.appendingPathComponent("first.md").path)
    }
    return root
  }

  private func toggleAIInspectorForUITest(
    _ toolbarButton: XCUIElement,
    shouldBePresented: Bool
  ) {
    application.activate()
    // Exercise the toolbar itself. A system-wide shortcut registered by another
    // application can intercept the key event and cover the tested window.
    toolbarButton.click()

    let inspector = element(identifier: "ai-assistant-inspector")
    let expectedState = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == %@", NSNumber(value: shouldBePresented)),
      object: inspector
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectedState], timeout: 5),
      .completed,
      "The AI toolbar click must change the Inspector to the requested presentation state."
    )
  }

  private func selectPublishScope(_ title: String, in picker: XCUIElement) {
    let option = picker.radioButtons[title]
    XCTAssertTrue(option.waitForExistence(timeout: 5))
    // SwiftUI exposes the segmented picker inside the drawer's scroll view.
    // Click its observed frame directly to avoid XCTest trying to scroll the
    // already visible segment before sending the event.
    clickVisibleDrawerControl(option)
    XCTAssertEqual(String(describing: option.value ?? ""), "1")
  }

  private func clickVisibleDrawerControl(_ control: XCUIElement) {
    clickScrollableControl(control, in: element(identifier: "publish-drawer-scroll-content"))
  }

  private func clickScrollableControl(_ control: XCUIElement, in scrollView: XCUIElement) {
    application.activate()
    XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
    XCTAssertFalse(control.frame.isEmpty)
    let window = application.windows.firstMatch
    let viewport = window.frame.intersection(scrollView.frame).insetBy(dx: 8, dy: 8)
    for _ in 0..<16 {
      let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
      if viewport.contains(center) { break }
      let direction: CGFloat = center.y > viewport.maxY ? -250 : 250
      scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        .scroll(byDeltaX: 0, deltaY: direction)
    }
    XCTAssertTrue(viewport.contains(CGPoint(x: control.frame.midX, y: control.frame.midY)))
    // The disclosure style makes the complete label row clickable. Use the
    // visible point in window coordinates so XCTest does not attempt another
    // automatic scroll using the disclosure's virtualized parent.
    let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
    window.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(dx: center.x - window.frame.minX, dy: center.y - window.frame.minY)
    ).click()
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
      control.click()
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

  private func select(
    _ controlIdentifier: String,
    revealing destinationIdentifier: String,
    in window: XCUIElement,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let destination = window.descendants(matching: .any)
      .matching(identifier: destinationIdentifier)
      .firstMatch
    let control = window.descendants(matching: .any)
      .matching(identifier: controlIdentifier)
      .firstMatch
    XCTAssertTrue(
      control.waitForExistence(timeout: 5),
      "No window-local control exists for \(controlIdentifier).", file: file, line: line)
    control.click()
    XCTAssertTrue(
      destination.waitForExistence(timeout: 5),
      "Selecting \(controlIdentifier) did not reveal \(destinationIdentifier) in its own window.",
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
    let window = application.windows.firstMatch
    guard window.waitForExistence(timeout: 5) else {
      XCTFail(
        "The app window was unavailable while revealing \(identifier).",
        file: file,
        line: line
      )
      return
    }
    // Offscreen SwiftUI sections may briefly remain in the AX snapshot while
    // their lazy child controls are being discarded. Bring the requested
    // section into the viewport before asserting its descendants.
    let scrollContainer = repositoryScrollContainer(in: window)
    if scrollToReveal(
      [destination], in: scrollContainer, window: window, maxSteps: maxSwipes
    ) != nil {
      return
    }
    let diagnostic = XCTAttachment(
      string:
        "Target: \(identifier) frame=\(destination.frame) exists=\(destination.exists)\nWindow: \(window.frame)\nViewport: \(scrollContainer.frame)\n\(application.debugDescription)"
    )
    diagnostic.name = "Scroll lookup failure - \(identifier)"
    diagnostic.lifetime = .keepAlways
    add(diagnostic)
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
    let window = application.windows.firstMatch
    guard window.waitForExistence(timeout: 5) else {
      XCTFail(
        "The app window was unavailable while revealing one of \(identifiers).",
        file: file,
        line: line
      )
      return nil
    }
    let candidates = identifiers.map(element(identifier:))
    let scrollContainer = repositoryScrollContainer(in: window)
    if let revealed = scrollToReveal(
      candidates, in: scrollContainer, window: window, maxSteps: maxSwipes),
      let index = candidates.firstIndex(where: { $0 == revealed })
    {
      return identifiers[index]
    }
    let candidateState = zip(identifiers, candidates).map { identifier, candidate in
      "\(identifier) frame=\(candidate.frame) exists=\(candidate.exists)"
    }.joined(separator: "\n")
    let diagnostic = XCTAttachment(
      string:
        "Targets:\n\(candidateState)\nWindow: \(window.frame)\nViewport: \(scrollContainer.frame)\n\(application.debugDescription)"
    )
    diagnostic.name = "Scroll lookup failure - any target"
    diagnostic.lifetime = .keepAlways
    add(diagnostic)
    XCTFail(
      "Scrolling did not reveal any of \(identifiers).",
      file: file,
      line: line
    )
    return nil
  }

  private func repositoryScrollContainer(in window: XCUIElement) -> XCUIElement {
    let repositoryScroll = window.descendants(matching: .scrollView)
      .matching(identifier: "repository-workspace")
      .firstMatch
    return repositoryScroll.exists ? repositoryScroll : window
  }

  private func scrollToReveal(
    _ candidates: [XCUIElement],
    in scrollContainer: XCUIElement,
    window: XCUIElement,
    maxSteps: Int
  ) -> XCUIElement? {
    func viewport() -> CGRect {
      window.frame.intersection(scrollContainer.frame).insetBy(dx: 4, dy: 4)
    }

    func visibleCandidate() -> XCUIElement? {
      let currentViewport = viewport()
      return candidates.first { candidate in
        candidate.exists
          && !candidate.frame.isEmpty
          && currentViewport.intersects(candidate.frame)
      }
    }

    func scrollDeltaTowardCandidate() -> CGFloat? {
      let currentViewport = viewport()
      guard !currentViewport.isEmpty else { return nil }
      let offscreenCandidates = candidates.compactMap { candidate -> (XCUIElement, CGRect)? in
        guard candidate.exists, !candidate.frame.isEmpty else { return nil }
        return (candidate, candidate.frame)
      }
      guard
        let candidate = offscreenCandidates.min(by: {
          abs($0.1.midY - currentViewport.midY) < abs($1.1.midY - currentViewport.midY)
        })?.1
      else {
        return nil
      }
      if candidate.maxY <= currentViewport.minY {
        return min(220, max(40, currentViewport.minY - candidate.maxY + 4))
      }
      if candidate.minY >= currentViewport.maxY {
        return -min(220, max(40, candidate.minY - currentViewport.maxY + 4))
      }
      return nil
    }

    if let visible = visibleCandidate() { return visible }
    let initialDelta = scrollDeltaTowardCandidate() ?? -220
    let initialDirection: CGFloat = initialDelta < 0 ? -1 : 1
    // Try the observed direction first. A lazy section can disappear from AX
    // while it is remounted, so make only one bounded return pass if that
    // direction did not expose it.
    for direction in [initialDirection, -initialDirection] {
      for _ in 0..<maxSteps {
        if let visible = visibleCandidate() { return visible }
        let delta = scrollDeltaTowardCandidate() ?? direction * 220
        guard delta * direction > 0 else { break }
        application.activate()
        scrollContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
          .scroll(byDeltaX: 0, deltaY: delta)
      }
    }
    return visibleCandidate()
  }

  private func elementCount(identifier: String) -> Int {
    application.descendants(matching: .any).matching(identifier: identifier).count
  }

  private func element(identifier: String) -> XCUIElement {
    application.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  private func waitForHittableElement(
    timeout: TimeInterval,
    query: () -> XCUIElementQuery
  ) -> XCUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if let element = query().allElementsBoundByIndex.first(where: {
        $0.exists && $0.isHittable
      }) {
        return element
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return query().allElementsBoundByIndex.first(where: {
      $0.exists && $0.isHittable
    })
  }

  private func runtimeAppURL() throws -> URL {
    let configuredPath =
      ProcessInfo.processInfo.environment["WORKBENCH_XCUI_APP_PATH"]
      ?? Bundle(for: Self.self).object(forInfoDictionaryKey: "WorkbenchXCUIAppPath") as? String
    let appURL: URL
    if let configuredPath, !configuredPath.isEmpty {
      appURL = URL(fileURLWithPath: configuredPath, isDirectory: true).standardizedFileURL
    } else {
      appURL =
        URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("dist/RepoPress Studio.app", isDirectory: true)
        .standardizedFileURL
    }
    guard FileManager.default.fileExists(atPath: appURL.path) else {
      XCTFail("Packaged workbench app does not exist: \(appURL.path)")
      throw CocoaError(.fileNoSuchFile)
    }
    return appURL
  }

  private func testDataRoot() -> URL {
    FileManager.default.temporaryDirectory
  }
}
