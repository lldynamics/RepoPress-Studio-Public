import AppKit
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
      "workspace-primary-navigation-rail",
      "workspace-sidebar-rss",
      "workspace-sidebar-library",
      "workspace-sidebar-sync",
      "workspace-sidebar-writing",
      "workspace-sidebar-images",
    ]
    let writingIdentifiers = [
      "writing-create-article",
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

    // Compact workspaces start rail-only. Reveal the context sidebar explicitly
    // before checking destinations that live in that on-demand column.
    let sidebarToggle = window.descendants(matching: .any)
      .matching(identifier: "workspace-sidebar-toggle")
      .firstMatch
    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 10))
    XCTAssertTrue(sidebarToggle.isEnabled)
    sidebarToggle.click()
    XCTAssertTrue(
      window.descendants(matching: .any)
        .matching(identifier: "workspace-sidebar")
        .firstMatch
        .waitForExistence(timeout: 10)
    )

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
        section: "workspace-sidebar-writing",
        destination: "writing-draft-list"
      ),
      (
        section: "workspace-sidebar-images",
        destination: "image-workbench"
      ),
    ]

    for route in routes {
      select(route.section, revealing: route.destination, in: window)
    }
    // Images is its own page; return to the article before capturing its body.
    select("workspace-sidebar-writing", revealing: "writing-draft-list", in: window)

    // At 1080pt the Inspector can be revealed on demand. The context sidebar
    // yields, while the same five-route rail keeps routing in this window.
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

    let primaryRail = compactWindow.descendants(matching: .any)
      .matching(identifier: "workspace-primary-navigation-rail")
      .firstMatch
    XCTAssertTrue(primaryRail.waitForExistence(timeout: 10))
    // Like select(_:revealing:), bring the app forward before hit-testing: a
    // window from another app covering this one makes the rail unhittable and
    // turns the next click into window activation only.
    application.activate()
    for section in ["rss", "library", "sync", "writing", "images"] {
      let button = compactWindow.buttons
        .matching(identifier: "workspace-sidebar-\(section)")
        .firstMatch
      XCTAssertTrue(button.waitForExistence(timeout: 5))
      XCTAssertTrue(
        button.isHittable,
        "Primary \(section) route must be directly hittable. Button \(button.frame), window \(compactWindow.frame)."
      )
    }

    let rssButton = compactWindow.buttons
      .matching(identifier: "workspace-sidebar-rss")
      .firstMatch
    application.activate()
    rssButton.click()
    XCTAssertTrue(
      compactWindow.descendants(matching: .any)
        .matching(identifier: "rss-reader-workspace")
        .firstMatch
        .waitForExistence(timeout: 10),
      "The RSS rail route must open RSS. Rail RSS value \(String(describing: rssButton.value)); window \(compactWindow.debugDescription)"
    )
    XCTAssertEqual(application.windows.count, 1)
    XCTAssertEqual(application.windows.firstMatch.identifier, compactWindowIdentifier)

    let writingButton = compactWindow.buttons
      .matching(identifier: "workspace-sidebar-writing")
      .firstMatch
    application.activate()
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

    application.typeKey("k", modifierFlags: [.shift, .command])
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
    let search = element(identifier: "workspace-command-palette")
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    XCTAssertTrue(element(identifier: "workspace-command-palette-article-scope").exists)
    let queryField = search.textFields["workspace-command-palette-query"]
    XCTAssertTrue(queryField.waitForExistence(timeout: 5))
    queryField.click()
    queryField.typeText("客户复盘")
    let open = search.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "workspace-command-palette-result-article:")
    ).firstMatch
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

  func testArticlePaletteFindsLiveBodyAndKeepsBatchReplacementSeparate() throws {
    launchApplication(surface: "writing")
    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.click()
    application.typeKey(.downArrow, modifierFlags: [.command])
    application.typeText("\nPaletteBodyOnlyMatch")

    application.typeKey("f", modifierFlags: [.option, .command])
    let palette = element(identifier: "workspace-command-palette")
    XCTAssertTrue(palette.waitForExistence(timeout: 10))
    let query = palette.textFields["workspace-command-palette-query"]
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    query.click()
    query.typeText("PaletteBodyOnlyMatch")
    let bodyHit = palette.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND identifier CONTAINS %@",
        "workspace-command-palette-result-article:", ":body:"
      )
    ).firstMatch
    XCTAssertTrue(bodyHit.waitForExistence(timeout: 10))
    application.typeKey(.return, modifierFlags: [])
    assertDisappears(palette)

    application.typeKey("f", modifierFlags: [.option, .command])
    XCTAssertTrue(palette.waitForExistence(timeout: 10))
    element(identifier: "workspace-command-palette-batch-replace").click()
    let batchQuery = element(identifier: "markdown-batch-find-query")
    XCTAssertTrue(batchQuery.waitForExistence(timeout: 10))
    XCTAssertTrue(element(identifier: "markdown-batch-preview-button").exists)
    application.typeKey(.escape, modifierFlags: [])
    assertDisappears(batchQuery)
    XCTAssertTrue(palette.exists)
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

    // Compact workspaces begin with the navigation rail. Exercise the same
    // explicit context-sidebar toggle used by the primary-route regression.
    let sidebarToggle = window.descendants(matching: .any)
      .matching(identifier: "workspace-sidebar-toggle").firstMatch
    XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 10))
    XCTAssertTrue(sidebarToggle.isEnabled)
    if !element(identifier: "workspace-sidebar").exists {
      sidebarToggle.click()
    }
    XCTAssertTrue(element(identifier: "workspace-sidebar").waitForExistence(timeout: 10))

    let requiredIdentifiers = [
      "workspace-sidebar",
      "writing-draft-list",
      "markdown-document-editor",
      "markdown-editor-toolbar",
      "markdown-formatting-toolbar",
      "markdown-editor-floating-toolbar",
      "markdown-article-title",
      "markdown-article-status",
      "markdown-editor-status-bar",
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

    // A SwiftUI Menu also tags its internal menu element with the identifier,
    // so uniqueness is checked on the menu button that users actually click.
    let menuIdentifiers = [
      "markdown-insert-menu",
      "markdown-format-menu",
      "markdown-article-path-menu",
    ]
    for identifier in menuIdentifiers {
      XCTAssertTrue(
        element(identifier: identifier).waitForExistence(timeout: 10),
        "The \(identifier) menu must be reachable."
      )
      let clickable = [application.menuButtons, application.popUpButtons, application.buttons]
        .map { $0.matching(identifier: identifier) }
      XCTAssertEqual(
        clickable.map(\.count).reduce(0, +), 1,
        "Expected one clickable \(identifier) control."
      )
      let control = clickable.first { $0.count > 0 }?.firstMatch
      // macOS exposes a menu button's name as its title rather than its label.
      let name = [control?.label, control?.title].compactMap { $0 }.joined()
      XCTAssertFalse(
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "Accessibility name must not be empty for \(identifier)."
      )
      XCTAssertFalse(control?.frame.isEmpty ?? true)
    }

    let hasInlineWritingToolIdentifiers = [
      "markdown-outline-button",
      "markdown-editor-more-actions-menu",
    ].allSatisfy { element(identifier: $0).exists }
    let hasInlineWritingToolNames =
      application.buttons["文章大纲"].exists
      && application.menuButtons["更多操作"].exists
    let hasCollapsedWritingTools =
      element(identifier: "markdown-writing-tools-menu").exists
      || application.menuButtons["写作工具"].exists
    XCTAssertTrue(
      hasCollapsedWritingTools || hasInlineWritingToolIdentifiers || hasInlineWritingToolNames,
      "Writing tools must remain accessible inline when they fit or through overflow otherwise."
    )

    if hasCollapsedWritingTools {
      let clickable = [application.menuButtons, application.popUpButtons, application.buttons]
        .map { $0.matching(identifier: "markdown-writing-tools-menu") }
      XCTAssertEqual(
        clickable.map(\.count).reduce(0, +), 1,
        "Expected one clickable collapsed writing-tools menu."
      )
      let writingTools =
        clickable.first { $0.count > 0 }?.firstMatch
        ?? application.menuButtons["写作工具"]
      application.activate()
      writingTools.click()
      XCTAssertTrue(application.menuItems["文章大纲"].waitForExistence(timeout: 3))
      application.typeKey(.escape, modifierFlags: [])
    } else {
      for (identifier, expectedItem) in [
        ("markdown-editor-ai-actions-menu", "续写"),
        ("markdown-editor-more-actions-menu", "专注模式"),
      ] {
        let clickable = [application.menuButtons, application.popUpButtons, application.buttons]
          .map { $0.matching(identifier: identifier) }
        XCTAssertEqual(
          clickable.map(\.count).reduce(0, +), 1,
          "Expected one clickable \(identifier) control."
        )
        guard let menu = clickable.first(where: { $0.count > 0 })?.firstMatch else {
          XCTFail("The \(identifier) menu is missing from the inline writing tools.")
          continue
        }
        application.activate()
        menu.click()
        XCTAssertTrue(
          application.menuItems[expectedItem].waitForExistence(timeout: 3), expectedItem)
        application.typeKey(.escape, modifierFlags: [])
      }
    }

    let title = element(identifier: "markdown-article-title")
    let metadata = element(identifier: "markdown-article-path-menu")
    let floatingToolbar = element(identifier: "markdown-editor-floating-toolbar")
    XCTAssertLessThanOrEqual(floatingToolbar.frame.maxY, title.frame.minY)
    XCTAssertLessThanOrEqual(title.frame.maxY, metadata.frame.minY)
    XCTAssertTrue(window.frame.contains(floatingToolbar.frame))
    metadata.click()
    XCTAssertTrue(application.menuItems["复制相对路径"].waitForExistence(timeout: 3))
    XCTAssertTrue(application.menuItems["复制文件名"].exists)
    XCTAssertTrue(application.menuItems["在 Finder 中显示"].exists)
    application.typeKey(.escape, modifierFlags: [])

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

  func testLargestInterfaceTextScaleKeepsLongTitleToolbarAccessibleInLightAppearance() throws {
    try assertLargestInterfaceTextScaleLayout(appearance: "light", screenshotName: "light")
  }

  func testLargestInterfaceTextScaleKeepsLongTitleToolbarAccessibleInDarkAppearance() throws {
    try assertLargestInterfaceTextScaleLayout(appearance: "dark", screenshotName: "dark")
  }

  func testInterfaceTextScaleCanChangeLiveFromSettingsWithoutReplacingEditorContent() throws {
    try prepareTextScaleRepository()
    launchApplication(
      surface: "writing",
      additionalLaunchArguments: [
        "-workbenchAppearanceModeV1", "light",
      ],
      screenshotContentSize: CGSize(width: 900, height: 620)
    )

    showSettingsWindow()
    let initialSettings = currentSettingsWindow()
    select("settings-tab-appearance", revealing: "appearance-settings", in: initialSettings)
    revealSettingsElement(
      "settings-interface-text-scale-picker", scrollContainerIdentifier: "appearance-settings"
    )
    let initialPicker = element(identifier: "settings-interface-text-scale-picker")
    initialPicker.click()
    application.menuItems["100%"].click()
    initialSettings.buttons[XCUIIdentifierCloseWindow].click()
    assertIdentifierDisappears("settings-content")

    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    editor.click()
    application.typeKey(.downArrow, modifierFlags: [.command])
    let originalBody = try XCTUnwrap(editor.value as? String)
    let marker = "LiveScale-\(UUID().uuidString)"
    let restorePasteboard = try preservePasteboard(with: marker)
    defer { restorePasteboard() }
    application.typeKey(.return, modifierFlags: [])
    application.typeKey("v", modifierFlags: [.command])
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", marker),
            object: editor
          )
        ],
        timeout: 10
      ),
      .completed,
      "The live scale case must append and read back its body marker before opening Settings."
    )
    let bodyBeforeScale = try XCTUnwrap(editor.value as? String)
    XCTAssertTrue(
      bodyBeforeScale.contains(originalBody),
      "The live scale case must preserve the original body while appending its marker."
    )
    let title = element(identifier: "markdown-article-title")
    XCTAssertTrue(title.waitForExistence(timeout: 10))
    let originalTitleHeight = title.frame.height
    XCTAssertGreaterThan(originalTitleHeight, 0)

    showSettingsWindow()
    let settings = currentSettingsWindow()
    select("settings-tab-appearance", revealing: "appearance-settings", in: settings)
    let scalePicker = settings.descendants(matching: .any)
      .matching(identifier: "settings-interface-text-scale-picker")
      .firstMatch
    XCTAssertTrue(scalePicker.waitForExistence(timeout: 10))
    revealSettingsElement(
      "settings-interface-text-scale-picker", scrollContainerIdentifier: "appearance-settings"
    )
    XCTAssertTrue(scalePicker.isHittable)
    scalePicker.click()
    let largest = application.menuItems["150%"]
    XCTAssertTrue(largest.waitForExistence(timeout: 5))
    largest.click()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "150%", "150%"),
            object: scalePicker
          )
        ],
        timeout: 10
      ),
      .completed,
      "Settings must commit the largest interface text scale selection."
    )

    settings.buttons[XCUIIdentifierCloseWindow].click()
    assertIdentifierDisappears("settings-content")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in title.frame.height > originalTitleHeight + 1 },
            object: title
          )
        ],
        timeout: 10
      ),
      .completed,
      "The workbench title must reflect the live 150% interface text scale."
    )
    XCTAssertEqual(
      editor.value as? String,
      bodyBeforeScale,
      "Changing interface text scale must preserve the complete editor content, including its body marker."
    )
    let liveScreenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    liveScreenshot.name = "live-interface-text-scale-preserved-editor"
    liveScreenshot.lifetime = .keepAlways
    add(liveScreenshot)

    // Reuse the isolated preferences without a launch-argument override.
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 900, height: 620))
    let restoredTitle = element(identifier: "markdown-article-title")
    XCTAssertTrue(restoredTitle.waitForExistence(timeout: 10))
    XCTAssertGreaterThan(restoredTitle.frame.height, originalTitleHeight + 1)
    showSettingsWindow()
    let restoredSettings = currentSettingsWindow()
    select("settings-tab-appearance", revealing: "appearance-settings", in: restoredSettings)
    let restoredPicker = restoredSettings.descendants(matching: .any)
      .matching(identifier: "settings-interface-text-scale-picker").firstMatch
    XCTAssertTrue(restoredPicker.waitForExistence(timeout: 10))
    XCTAssertEqual(restoredPicker.value as? String, "150%")
    let settingsScreenshot = XCTAttachment(screenshot: restoredSettings.screenshot())
    settingsScreenshot.name = "persisted-interface-text-scale-settings"
    settingsScreenshot.lifetime = .keepAlways
    add(settingsScreenshot)
  }

  private func preservePasteboard(with value: String) throws -> () -> Void {
    let pasteboard = NSPasteboard.general
    let originalItems = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      }
    }
    pasteboard.clearContents()
    guard pasteboard.setString(value, forType: .string) else {
      throw NSError(
        domain: "WorkspaceAccessibilityUITests",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Could not prepare the test pasteboard."]
      )
    }
    let fixtureChangeCount = pasteboard.changeCount
    return {
      guard pasteboard.changeCount == fixtureChangeCount else { return }
      pasteboard.clearContents()
      let restored = originalItems.map { values in
        let item = NSPasteboardItem()
        for (type, data) in values {
          item.setData(data, forType: type)
        }
        return item
      }
      if !restored.isEmpty {
        pasteboard.writeObjects(restored)
      }
    }
  }

  @discardableResult
  private func acceptanceGit(_ arguments: [String], at root: URL) throws -> String {
    guard root.path.hasPrefix(knowledgeLibraryRootURL.path + "/") else {
      throw NSError(domain: "RepoPressAcceptanceGit", code: 1)
    }
    let gitPath = try XCTUnwrap(
      Bundle(for: Self.self).object(forInfoDictionaryKey: "WorkbenchXCUIGitPath") as? String)
    let git = Process()
    git.executableURL = URL(fileURLWithPath: gitPath)
    git.currentDirectoryURL = root
    git.arguments = [
      "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false",
      "-c", "user.name=RepoPress Acceptance", "-c", "user.email=acceptance@example.invalid",
    ] + arguments
    var environment = ProcessInfo.processInfo.environment
    for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_CONFIG_COUNT"] {
      environment.removeValue(forKey: key)
    }
    environment.merge([
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
      "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
    ]) { _, fixtureValue in fixtureValue }
    git.environment = environment
    let output = Pipe()
    git.standardOutput = output
    git.standardError = output
    try git.run()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    git.waitUntilExit()
    XCTAssertEqual(git.terminationStatus, 0, "Fixture Git \(arguments): \(text)")
    guard git.terminationStatus == 0 else {
      throw NSError(domain: "RepoPressAcceptanceGit", code: Int(git.terminationStatus))
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func initializeAcceptanceRepository(at root: URL) throws {
    try acceptanceGit(["init", "--quiet", "--initial-branch=main"], at: root)
    XCTAssertEqual(try acceptanceGit(["rev-parse", "--show-toplevel"], at: root), root.path)
    XCTAssertTrue(try acceptanceGit(["remote"], at: root).isEmpty)
    try acceptanceGit(["add", "--all"], at: root)
    try acceptanceGit(["commit", "--quiet", "-m", "Acceptance baseline"], at: root)
    XCTAssertTrue(try acceptanceGit(["status", "--porcelain"], at: root).isEmpty)
  }

  private func commitAcceptanceRepository(at root: URL, evidenceName: String) throws {
    let beforeHead = try acceptanceGit(["rev-parse", "HEAD"], at: root)
    let beforeStatus = try acceptanceGit(["status", "--porcelain"], at: root)
    XCTAssertFalse(beforeStatus.isEmpty)
    XCTAssertTrue(try acceptanceGit(["remote"], at: root).isEmpty)
    try acceptanceGit(["add", "--all"], at: root)
    try acceptanceGit(["commit", "--quiet", "-m", "Acceptance saved article"], at: root)
    let afterHead = try acceptanceGit(["rev-parse", "HEAD"], at: root)
    let afterStatus = try acceptanceGit(["status", "--porcelain"], at: root)
    XCTAssertNotEqual(beforeHead, afterHead)
    XCTAssertTrue(afterStatus.isEmpty)
    let evidence = XCTAttachment(string: """
      Test-owned repository: \(root.path)
      Remotes: none
      Baseline HEAD: \(beforeHead)
      Saved file status before fixture commit: \(beforeStatus)
      HEAD after explicit fixture CLI commit: \(afterHead)
      Status after fixture commit: \(afterStatus)
      This verifies local saved-file and Git state, not the product's remote publish action.
      """)
    evidence.name = evidenceName
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  private func prepareTextScaleRepository() throws {
    let root = knowledgeLibraryRootURL.appendingPathComponent("repository-fixture", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let gitPath = try XCTUnwrap(
      Bundle(for: Self.self).object(forInfoDictionaryKey: "WorkbenchXCUIGitPath") as? String)
    let git = Process()
    git.executableURL = URL(fileURLWithPath: gitPath)
    git.arguments = ["init", "--quiet", root.path]
    git.environment = ProcessInfo.processInfo.environment.merging([
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    ]) { _, fixtureValue in fixtureValue }
    try git.run()
    git.waitUntilExit()
    XCTAssertEqual(git.terminationStatus, 0)
  }

  private func assertLargestInterfaceTextScaleLayout(
    appearance: String,
    screenshotName: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    try prepareTextScaleRepository()
    launchApplication(
      surface: "writing",
      additionalLaunchArguments: [
        "-workbenchTextScaleV1", "largest",
        "-workbenchAppearanceModeV1", appearance,
      ],
      screenshotContentSize: CGSize(width: 900, height: 620)
    )

    let window = application.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10), file: file, line: line)
    let titleText = "窄窗口与大字号验收：很长的文章标题需要完整保留，同时检查深浅色与 VoiceOver 的标题导航和工具栏操作"
    let title = element(identifier: "markdown-article-title")
    XCTAssertTrue(title.waitForExistence(timeout: 10), file: file, line: line)
    // Paste through the real field, independent of the current input method.
    // Restore the clipboard only if this test still owns its contents.
    let pasteboard = NSPasteboard.general
    let originalItems = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString(titleText, forType: .string))
    let fixtureChangeCount = pasteboard.changeCount
    defer {
      if pasteboard.changeCount == fixtureChangeCount {
        pasteboard.clearContents()
        let restored = originalItems.map { values in
          let item = NSPasteboardItem()
          for (type, data) in values { item.setData(data, forType: type) }
          return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
      }
    }
    // A newly activated macOS window can move during the initial layout pass.
    // Retry only the idempotent replacement if the first click lost focus.
    for _ in 0..<3 {
      application.activate()
      title.doubleClick()
      application.typeKey("a", modifierFlags: [.command])
      application.typeKey("v", modifierFlags: [.command])
      let updated = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "value == %@", titleText), object: title
      )
      if XCTWaiter.wait(for: [updated], timeout: 2) == .completed { break }
    }
    XCTAssertEqual(
      title.value as? String,
      titleText,
      "The complete long article title must remain accessible.",
      file: file,
      line: line
    )

    let toolbarIdentifiers = [
      "markdown-editor-toolbar",
      "markdown-formatting-toolbar",
      "markdown-editor-floating-toolbar",
      "markdown-editor-status-bar",
    ]
    let toolbarElements = toolbarIdentifiers.map { identifier -> XCUIElement in
      let control = element(identifier: identifier)
      XCTAssertTrue(control.waitForExistence(timeout: 10), identifier, file: file, line: line)
      XCTAssertFalse(
        control.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        identifier,
        file: file,
        line: line
      )
      XCTAssertFalse(control.frame.isEmpty, identifier, file: file, line: line)
      XCTAssertTrue(
        window.frame.contains(control.frame),
        "\(identifier) must stay inside the workbench window.",
        file: file,
        line: line
      )
      return control
    }
    XCTAssertEqual(toolbarElements.count, toolbarIdentifiers.count, file: file, line: line)
    let path = element(identifier: "markdown-article-path-menu")
    XCTAssertTrue(path.waitForExistence(timeout: 10), file: file, line: line)
    let floatingToolbar = element(identifier: "markdown-editor-floating-toolbar")
    XCTAssertLessThanOrEqual(floatingToolbar.frame.maxY, title.frame.minY, file: file, line: line)
    XCTAssertLessThanOrEqual(title.frame.maxY, path.frame.minY, file: file, line: line)
    XCTAssertTrue(
      window.frame.contains(title.frame),
      "The long title field must remain inside the workbench window.",
      file: file,
      line: line
    )

    let screenshot = XCTAttachment(screenshot: window.screenshot())
    screenshot.name = "largest-interface-text-scale-\(screenshotName)-900x620"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testWritingArticleStateCanSwitchBetweenDraftAndReady() throws {
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 1440, height: 900))
    let tabs = element(identifier: "workspace-inspector-tabs")
    if !tabs.exists {
      element(identifier: "workspace-inspector-toggle").click()
    }
    XCTAssertTrue(tabs.waitForExistence(timeout: 5))
    tabs.radioButtons["信息"].click()
    let inspector = element(identifier: "article-inspector")
    XCTAssertTrue(inspector.waitForExistence(timeout: 5))
    let picker = element(identifier: "article-state-picker")

    for title in ["草稿", "待发布", "草稿"] {
      clickScrollableControl(picker, in: inspector)
      let option = application.menuItems[title].firstMatch
      XCTAssertTrue(option.waitForExistence(timeout: 5))
      XCTAssertTrue(option.isEnabled, "The article state must be selectable: \(title)")
      option.click()
      XCTAssertEqual(
        XCTWaiter.wait(
          for: [
            XCTNSPredicateExpectation(
              predicate: NSPredicate(format: "value == %@", title), object: picker)
          ], timeout: 5),
        .completed
      )
      assertDisappears(option)
    }
    let screenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    screenshot.name = "Article state after draft-ready-draft transitions"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testWritingSecondaryControlsKeepKeyboardAccessAndAdvancedMetadataCollapsed() throws {
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 1440, height: 900))

    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    // Park the pointer in the editor: no status-bar hover or overflow menu
    // opening may be needed to install either keyboard command.
    editor.click()
    assertDisappears(element(identifier: "markdown-cursor-position-button"))
    XCTAssertFalse(element(identifier: "markdown-version-history-button").exists)

    application.typeKey("l", modifierFlags: [.command])
    let lineField = element(identifier: "markdown-go-to-line-field")
    XCTAssertTrue(
      lineField.waitForExistence(timeout: 5),
      "Command-L must open Go to Line before the first status-bar hover."
    )
    XCTAssertTrue(lineField.isHittable, "The hidden anchor must still present a usable popover.")
    lineField.click()
    application.typeKey("a", modifierFlags: [.command])
    lineField.typeText("2")
    application.typeKey(.return, modifierFlags: [])
    assertDisappears(lineField)

    application.typeKey("l", modifierFlags: [.command])
    XCTAssertTrue(lineField.waitForExistence(timeout: 5))
    XCTAssertEqual(
      lineField.value as? String, "2",
      "Reopening Go to Line must reflect the submitted cursor position."
    )
    application.buttons["取消"].click()
    assertDisappears(lineField)

    let statusBar = element(identifier: "markdown-editor-status-bar")
    let writingWindow = application.windows.firstMatch
    let statusFrame = statusBar.frame
    let windowFrame = writingWindow.frame
    let statusCenter = CGPoint(x: statusFrame.midX, y: statusFrame.midY)
    XCTAssertFalse(statusFrame.isEmpty)
    XCTAssertTrue(windowFrame.insetBy(dx: 1, dy: 1).contains(statusCenter))
    for stage in ["before", "after"] {
      if stage == "after" {
        writingWindow.coordinate(withNormalizedOffset: .zero).withOffset(
          CGVector(dx: statusCenter.x - windowFrame.minX, dy: statusCenter.y - windowFrame.minY)
        ).hover()
      }
      let screenshot = XCTAttachment(screenshot: application.screenshot())
      screenshot.name = "Status bar \(stage) coordinate hover"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      let hierarchy = XCTAttachment(
        string: "Status frame: \(statusFrame); window frame: \(windowFrame)\n"
          + "Mouse location (AppKit screen coordinates): \(NSEvent.mouseLocation)\n"
          + "Screen frames (AppKit screen coordinates): \(NSScreen.screens.map(\.frame))\n"
          + "Frontmost bundle: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "<nil>"); "
          + "PID: \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)\n"
          + "Status isHittable: \(statusBar.isHittable)\n"
          + application.debugDescription
      )
      hierarchy.name = "Status hierarchy \(stage) coordinate hover"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    let cursor = element(identifier: "markdown-cursor-position-button")
    XCTAssertTrue(cursor.waitForExistence(timeout: 5))
    XCTAssertEqual(cursor.value as? String, "行 2，列 1")
    editor.hover()
    assertDisappears(cursor)

    let title = try XCTUnwrap(element(identifier: "markdown-article-title").value as? String)
    let originalBody = try XCTUnwrap(editor.value as? String)
    let duplicateHeading = "# \(title)\n"
    // The native editor exposes its complete source, including folded Front
    // Matter. Preserve that prefix while removing only the first body H1.
    let headingRange = try XCTUnwrap(originalBody.range(of: duplicateHeading))
    let sourcePrefix = originalBody[..<headingRange.lowerBound]
    XCTAssertTrue(sourcePrefix.hasPrefix("+++") || sourcePrefix.hasPrefix("---"))
    let duplicateNotice = element(identifier: "markdown-duplicate-body-title-notice")
    XCTAssertTrue(duplicateNotice.waitForExistence(timeout: 5))
    element(identifier: "markdown-remove-duplicate-body-title").click()
    var bodyWithoutHeading = originalBody
    bodyWithoutHeading.removeSubrange(headingRange)
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", bodyWithoutHeading), object: editor)
        ], timeout: 5),
      .completed,
      "Removing the duplicate title must preserve every character after the opening H1."
    )
    XCTAssertEqual(element(identifier: "markdown-article-title").value as? String, title)
    assertDisappears(duplicateNotice)
    editor.click()
    application.typeKey("z", modifierFlags: [.command])
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", originalBody), object: editor)
        ], timeout: 5),
      .completed,
      "Native Undo must restore the exact original body."
    )
    XCTAssertEqual(element(identifier: "markdown-article-title").value as? String, title)
    XCTAssertTrue(duplicateNotice.waitForExistence(timeout: 5))

    application.typeKey("h", modifierFlags: [.command, .option, .control])
    let history = element(identifier: "data-management-drafts-task")
    XCTAssertTrue(
      history.waitForExistence(timeout: 5),
      "The article history shortcut must work without opening More Actions."
    )
    XCTAssertTrue(history.staticTexts[title].exists, "History must target the edited article.")
    element(identifier: "data-management-drafts-task-close").click()
    assertDisappears(history)

    let tabs = element(identifier: "workspace-inspector-tabs")
    if !tabs.exists {
      element(identifier: "workspace-inspector-toggle").click()
    }
    XCTAssertTrue(tabs.waitForExistence(timeout: 5))
    tabs.radioButtons["信息"].click()
    let inspector = element(identifier: "article-inspector")
    XCTAssertTrue(inspector.waitForExistence(timeout: 5))
    let publishDates = inspector.datePickers.matching(
      NSPredicate(format: "label CONTAINS %@", "文章发布时间")
    )
    XCTAssertEqual(publishDates.count, 1, "The article publication date must have one date picker.")
    let commonMetadata = [
      inspector.textFields["文章摘要"],
      inspector.textFields["标签"],
      inspector.textFields["分类"],
      publishDates.firstMatch,
      element(identifier: "article-state-picker"),
    ]
    for field in commonMetadata {
      XCTAssertTrue(field.waitForExistence(timeout: 5))
      XCTAssertFalse(field.frame.isEmpty)
    }
    for (previous, next) in zip(commonMetadata, commonMetadata.dropFirst()) {
      XCTAssertLessThan(
        previous.frame.minY, next.frame.minY,
        "Common metadata must appear in summary, tags, categories, date, state order."
      )
    }
    let advanced = element(identifier: "article-metadata-advanced")
    XCTAssertTrue(advanced.waitForExistence(timeout: 5))
    let slug = inspector.textFields["文章固定链接"]
    XCTAssertFalse(slug.exists, "Slug must remain inside the initially collapsed Advanced group.")
    XCTAssertFalse(element(identifier: "article-publish-reminder").exists)
    let advancedLabel = advanced.disclosureTriangles["高级"].firstMatch
    XCTAssertTrue(advancedLabel.waitForExistence(timeout: 5))
    let inspectorScroll = inspector
    clickScrollableControl(advancedLabel, in: inspectorScroll, disclosureLeadingInset: 26)
    XCTAssertTrue(slug.waitForExistence(timeout: 5))
    XCTAssertTrue(element(identifier: "article-publish-reminder").waitForExistence(timeout: 5))
    XCTAssertTrue(slug.isEnabled)
    let editedSlug = "writing-ui-folded-slug"
    slug.click()
    application.typeKey("a", modifierFlags: [.command])
    let slugInputScreenshot = XCTAttachment(screenshot: application.screenshot())
    slugInputScreenshot.name = "Slug field before replacement input"
    slugInputScreenshot.lifetime = .keepAlways
    add(slugInputScreenshot)
    let slugInputHierarchy = XCTAttachment(string: application.debugDescription)
    slugInputHierarchy.name = "Slug hierarchy before replacement input"
    slugInputHierarchy.lifetime = .keepAlways
    add(slugInputHierarchy)
    application.typeText(editedSlug)
    let slugEditAppeared = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", editedSlug), object: slug
    )
    XCTAssertEqual(XCTWaiter.wait(for: [slugEditAppeared], timeout: 5), .completed)
    // Fold directly without Return or an intermediate focus change: removing
    // the focused field must commit its pending edit before it disappears.
    clickScrollableControl(advancedLabel, in: inspectorScroll, disclosureLeadingInset: 26)
    assertDisappears(slug)
    assertDisappears(element(identifier: "article-publish-reminder"))
    clickScrollableControl(advancedLabel, in: inspectorScroll, disclosureLeadingInset: 26)
    XCTAssertTrue(slug.waitForExistence(timeout: 5))
    XCTAssertEqual(slug.value as? String, editedSlug)
    clickScrollableControl(advancedLabel, in: inspectorScroll, disclosureLeadingInset: 26)
    assertDisappears(slug)

    let saveStatus = element(identifier: "markdown-editor-save-status")
    XCTAssertTrue(saveStatus.waitForExistence(timeout: 5))
    let changesSaved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", "已保存"), object: saveStatus
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [changesSaved], timeout: 15), .completed,
      "Editing and folding Slug must finish saving the isolated fixture."
    )
    XCTAssertFalse(element(identifier: "markdown-editor-save-failure").exists)

    // Query clickable controls only: SwiftUI also gives its internal menu
    // container the same identifier as the visible AI menu button.
    let aiMenus = [application.menuButtons, application.popUpButtons, application.buttons]
      .map { $0.matching(identifier: "markdown-editor-ai-actions-menu") }
    XCTAssertEqual(aiMenus.map(\.count).reduce(0, +), 1)
    let aiMenu = try XCTUnwrap(aiMenus.first { $0.count > 0 }?.firstMatch)
    aiMenu.click()
    let configure = application.menuItems.matching(identifier: "markdown-ai-configure-action")
      .firstMatch
    XCTAssertTrue(configure.waitForExistence(timeout: 5))
    XCTAssertTrue(
      configure.isEnabled, "The no-key fixture must offer an actionable configuration entry.")
    let openAIMenu = application.menus
      .containing(.menuItem, identifier: "markdown-ai-configure-action").firstMatch
    XCTAssertTrue(openAIMenu.waitForExistence(timeout: 5))
    let menuGroups = ["选区", "全文", "发布"].map { name in
      openAIMenu.descendants(matching: .any)
        .matching(NSPredicate(format: "label == %@ OR title == %@", name, name)).firstMatch
    }
    for group in menuGroups {
      XCTAssertTrue(group.waitForExistence(timeout: 5))
    }
    let groupedActions = [
      ["改写", "翻译"],
      ["续写", "内容审查", "引用资料"],
      ["摘要", "标题", "社交文案", "发布资产包"],
    ]
    for (index, titles) in groupedActions.enumerated() {
      for actionTitle in titles {
        let action = openAIMenu.menuItems[actionTitle]
        XCTAssertTrue(action.waitForExistence(timeout: 5), actionTitle)
        if !["改写", "翻译"].contains(actionTitle) {
          XCTAssertFalse(action.isEnabled, "Missing credentials must disable \(actionTitle).")
        }
        XCTAssertGreaterThan(action.frame.minY, menuGroups[index].frame.minY)
        if index + 1 < menuGroups.count {
          XCTAssertLessThan(action.frame.minY, menuGroups[index + 1].frame.minY)
        }
      }
    }
    let selectionSubmenus = [
      ("改写", ["自然", "读者友好", "正式", "轻松", "技术", "润色", "扩写", "压缩", "简化", "摘要", "删减冗余"]),
      ("翻译", ["选区翻译中文", "选区翻译英文"]),
    ]
    for (submenuTitle, leafTitles) in selectionSubmenus {
      let navigation = openAIMenu.menuItems[submenuTitle]
      navigation.hover()
      let submenu = navigation.menus.firstMatch
      XCTAssertTrue(submenu.waitForExistence(timeout: 5), submenuTitle)
      for leafTitle in leafTitles {
        let leaf = submenu.menuItems.matching(
          NSPredicate(format: "title == %@ OR label == %@", leafTitle, leafTitle)
        ).firstMatch
        XCTAssertTrue(leaf.waitForExistence(timeout: 5), leafTitle)
        XCTAssertFalse(leaf.isEnabled, "Missing credentials must disable \(leafTitle).")
      }
    }
    configure.click()
    XCTAssertTrue(element(identifier: "settings-content").waitForExistence(timeout: 10))
    XCTAssertTrue(element(identifier: "settings-ai-key-input").waitForExistence(timeout: 5))
    currentSettingsWindow().buttons[XCUIIdentifierCloseWindow].click()
    assertIdentifierDisappears("settings-content")
  }

  func testWritingFloatingToolbarStaysWithinEditorAndKeepsPathActionsReachable() throws {
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 1440, height: 820))
    let toolbar = element(identifier: "markdown-editor-floating-toolbar")
    let editor = element(identifier: "markdown-document-editor")
    let title = element(identifier: "markdown-article-title")
    let path = element(identifier: "markdown-article-path-menu")
    XCTAssertTrue(toolbar.waitForExistence(timeout: 10))
    XCTAssertTrue(editor.exists)
    XCTAssertLessThan(toolbar.frame.width, editor.frame.width)
    XCTAssertGreaterThanOrEqual(toolbar.frame.minX, editor.frame.minX)
    XCTAssertLessThanOrEqual(toolbar.frame.maxX, editor.frame.maxX)
    XCTAssertLessThanOrEqual(toolbar.frame.maxY, title.frame.minY)
    XCTAssertLessThanOrEqual(title.frame.maxY, path.frame.minY)
    path.click()
    for action in ["复制相对路径", "复制绝对路径", "复制文件名", "在 Finder 中显示"] {
      XCTAssertTrue(application.menuItems[action].waitForExistence(timeout: 3), action)
    }
    application.typeKey(.escape, modifierFlags: [])
  }

  func testWritingInspectorYieldsToTypingAndNarrowingBeforeArticleList() throws {
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 1440, height: 820))
    let window = application.windows.firstMatch
    // Raise the fixture through a clear title-bar area before checking controls.
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0))
      .withOffset(CGVector(dx: 0, dy: 10)).click()
    let inspector = element(identifier: "workspace-inspector")
    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    let wideScreenshot = XCTAttachment(screenshot: window.screenshot())
    wideScreenshot.name = "writing-layout-1440"
    wideScreenshot.lifetime = .keepAlways
    add(wideScreenshot)
    let originalEditorWidth = editor.frame.width
    editor.click()
    editor.typeText("layout check")
    assertIdentifierDisappears("workspace-inspector")
    XCTAssertTrue(
      (editor.value as? String)?.contains("layout check") == true,
      "Collapsing the Inspector during typing must preserve the complete entered text."
    )
    XCTAssertTrue(element(identifier: "writing-draft-list").exists)
    XCTAssertGreaterThan(editor.frame.width, originalEditorWidth + 200)

    element(identifier: "workspace-inspector-toggle").click()
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    let sizeChange = 1180 - window.frame.width
    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -2, dy: -2))
    corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: sizeChange, dy: 0)))
    XCTAssertEqual(window.frame.width, 1180, accuracy: 2)
    assertIdentifierDisappears("workspace-inspector")
    XCTAssertTrue(element(identifier: "writing-draft-list").exists)
    let narrowScreenshot = XCTAttachment(screenshot: window.screenshot())
    narrowScreenshot.name = "writing-layout-1180"
    narrowScreenshot.lifetime = .keepAlways
    add(narrowScreenshot)

    element(identifier: "workspace-inspector-toggle").click()
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    XCTAssertFalse(element(identifier: "writing-draft-list").exists)
  }

  func testNarrowWritingInspectorRevealImmediatelyReplacesArticleList() throws {
    launchApplication(
      surface: "seo-social-preview", screenshotContentSize: CGSize(width: 1180, height: 820))
    let window = application.windows.firstMatch
    window.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0))
      .withOffset(CGVector(dx: 0, dy: 10)).click()
    let inspectorToggle = element(identifier: "workspace-inspector-toggle")
    XCTAssertTrue(inspectorToggle.waitForExistence(timeout: 10))
    XCTAssertTrue(element(identifier: "writing-draft-list").exists)
    XCTAssertFalse(element(identifier: "workspace-inspector").exists)

    inspectorToggle.click()
    assertIdentifierExists("workspace-inspector")
    assertIdentifierDisappears("writing-draft-list")
    XCTAssertEqual(inspectorToggle.value as? String, "信息")
    XCTAssertEqual(window.frame.width, 1180, accuracy: 2)

    inspectorToggle.click()
    assertIdentifierDisappears("workspace-inspector")
    assertIdentifierExists("writing-draft-list")
    XCTAssertEqual(window.frame.width, 1180, accuracy: 2)
  }

  func testEditorAppearanceButtonOpensTheEditorSettingsPage() throws {
    launchApplication(surface: "writing")
    let moreActions = element(identifier: "markdown-editor-more-actions-menu")
    XCTAssertTrue(moreActions.waitForExistence(timeout: 10))
    moreActions.click()
    let appearanceButton = element(identifier: "markdown-editor-settings")
    XCTAssertTrue(appearanceButton.waitForExistence(timeout: 3))
    appearanceButton.click()

    assertIdentifierExists("editor-settings")
    assertUniqueIdentifier("editor-font-size")
    XCTAssertFalse(element(identifier: "editor-typewriter-mode").exists)
    XCTAssertFalse(element(identifier: "editor-paragraph-spotlight").exists)
    XCTAssertFalse(element(identifier: "editor-current-paragraph-highlight").exists)
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
      "workspace-primary-navigation-rail",
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
      .click()
    assertUniqueIdentifier("rss-reader-detail")

    XCTAssertEqual(
      application.windows.count,
      windowCountBeforeSelection,
      "Selecting RSS must reuse the main workspace instead of opening another window."
    )
  }

  func testSavedLongArticleReopensAndAcceptsFirstWheelScroll() throws {
    let repositoryRoot = knowledgeLibraryRootURL.appendingPathComponent(
      "long-article-zola", isDirectory: true)
    try FileManager.default.createDirectory(
      at: repositoryRoot.appendingPathComponent("content/posts"), withIntermediateDirectories: true)
    try "base_url = \"https://example.invalid\"\ntitle = \"Long article acceptance\"\n".write(
      to: repositoryRoot.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    try initializeAcceptanceRepository(at: repositoryRoot)
    launchApplication(surface: nil)
    completeDataRootSetupIfNeeded()
    openFirstRunSetupWizard()
    completeFirstRunRepositorySetup(at: repositoryRoot, replacingExistingRepository: false)
    XCTAssertTrue(element(identifier: "first-run-writing-summary").waitForExistence(timeout: 45))
    let createArticle = element(identifier: "first-run-create-article")
    XCTAssertTrue(createArticle.waitForExistence(timeout: 5))
    createArticle.click()
    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    let marker = "ColdReopen-\(UUID().uuidString)"
    let longBody =
      ([marker] + (1...1_600).map { "Paragraph \($0): saved long article scroll fixture." }
      + ["End-\(marker)"]).joined(separator: "\n\n")

    // Preserve the clipboard and restore it only while this test still owns
    // it. Pasting uses the actual editor and persistence path without typing
    // thousands of synthetic keystrokes or reseeding the launch fixture.
    let pasteboard = NSPasteboard.general
    let originalItems = (pasteboard.pasteboardItems ?? []).map { item in
      item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    }
    pasteboard.clearContents()
    XCTAssertTrue(pasteboard.setString(longBody, forType: .string))
    let fixtureChangeCount = pasteboard.changeCount
    defer {
      if pasteboard.changeCount == fixtureChangeCount {
        pasteboard.clearContents()
        let restored = originalItems.map { values in
          let item = NSPasteboardItem()
          for (type, data) in values { item.setData(data, forType: type) }
          return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
      }
    }
    application.activate()
    let editorScroll = application.scrollViews.containing(
      .textView, identifier: "markdown-document-editor").firstMatch
    XCTAssertTrue(editorScroll.waitForExistence(timeout: 5))
    let window = application.windows.firstMatch
    let visibleEditor = editor.frame.intersection(editorScroll.frame)
      .intersection(window.frame).insetBy(dx: 20, dy: 20)
    XCTAssertFalse(visibleEditor.isEmpty)
    let origin = window.coordinate(withNormalizedOffset: .zero)
    let screenOrigin = origin.screenPoint
    origin.withOffset(
      CGVector(dx: visibleEditor.midX - screenOrigin.x, dy: visibleEditor.midY - screenOrigin.y)
    ).click()
    let expectedAppID = try XCTUnwrap(Bundle(url: try runtimeAppURL())?.bundleIdentifier)
    let foreground = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == expectedAppID
      }, object: application)
    let foregroundResult = XCTWaiter.wait(for: [foreground], timeout: 5)
    let focusEvidence = XCTAttachment(string: """
      Expected app: \(expectedAppID)
      Frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")
      XCTest app state: \(application.state.rawValue)
      Window: \(window.frame)
      Editor: \(editor.frame)
      Scroll viewport: \(editorScroll.frame)
      Visible input rectangle: \(visibleEditor)
      """)
    focusEvidence.name = "Long article input focus and geometry"
    focusEvidence.lifetime = .keepAlways
    add(focusEvidence)
    XCTAssertEqual(foregroundResult, .completed, "The test app must receive the paste keystrokes.")
    application.typeKey("a", modifierFlags: [.command])
    application.typeKey("v", modifierFlags: [.command])
    let pasted = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", "End-\(marker)"), object: editor)
    let pasteResult = XCTWaiter.wait(for: [pasted], timeout: 5)
    let pastedValue = editor.value as? String ?? ""
    let pasteEvidence = XCTAttachment(string: """
      Clipboard still owned by fixture: \(pasteboard.changeCount == fixtureChangeCount)
      Clipboard matches intended body: \(pasteboard.string(forType: .string) == longBody)
      Frontmost app: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")
      Actual editor UTF-16 length: \(pastedValue.utf16.count)
      Expected body UTF-16 length: \(longBody.utf16.count)
      End marker present: \(pastedValue.contains("End-\(marker)"))
      Actual editor suffix: \(String(pastedValue.suffix(256)))
      """)
    pasteEvidence.name = "Long article actual paste result"
    pasteEvidence.lifetime = .keepAlways
    add(pasteEvidence)
    XCTAssertEqual(pasteResult, .completed)
    XCTAssertTrue((editor.value as? String)?.contains("End-\(marker)") == true)
    application.typeKey(.upArrow, modifierFlags: [.command])
    application.typeKey("s", modifierFlags: [.command])
    let inspector = element(identifier: "article-inspector")
    if !inspector.exists { element(identifier: "workspace-inspector-toggle").click() }
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    let joinProject = element(identifier: "metadata-add-draft-to-project")
    XCTAssertTrue(joinProject.waitForExistence(timeout: 10))
    clickScrollableControl(joinProject, in: inspector)
    let saved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", "已保存"),
      object: element(identifier: "markdown-editor-save-status"))
    XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
    let projectDocuments =
      (FileManager.default.enumerator(
        at: repositoryRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
      .filter { $0.pathExtension == "md" }
    XCTAssertEqual(projectDocuments.count, 1)
    let projectDocument = try XCTUnwrap(projectDocuments.first)
    XCTAssertTrue(try String(contentsOf: projectDocument, encoding: .utf8).contains("End-\(marker)"))
    let savedGitStatus = try acceptanceGit(["status", "--porcelain"], at: repositoryRoot)
    XCTAssertFalse(savedGitStatus.isEmpty, "Saving the new article must leave a local Git change.")
    let baselineCommit = try acceptanceGit(["rev-parse", "HEAD"], at: repositoryRoot)
    application.terminate()

    // Reuse the same isolated home, with demo mode disabled on both launches.
    application.launch()
    application.activate()
    let reopenedEditor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(reopenedEditor.waitForExistence(timeout: 20))
    XCTAssertTrue((reopenedEditor.value as? String)?.contains("End-\(marker)") == true)
    let scrollView = application.scrollViews.containing(
      .any, identifier: "markdown-document-editor"
    ).firstMatch
    XCTAssertTrue(scrollView.waitForExistence(timeout: 5))
    let scrollBar = scrollView.scrollBars.firstMatch
    XCTAssertTrue(
      scrollBar.waitForExistence(timeout: 5),
      "The reopened long article must expose its scroller immediately.")
    XCTAssertNotNil(scrollBar.value)
    let initialScrollValue = String(describing: scrollBar.value)
    let before = XCTAttachment(screenshot: application.screenshot())
    before.name = "Saved long article immediately after relaunch"
    before.lifetime = .keepAlways
    add(before)
    scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
      .scroll(byDeltaX: 0, deltaY: -320)
    let moved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        scrollBar.value != nil && String(describing: scrollBar.value) != initialScrollValue
      }, object: scrollBar)
    XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
    let after = XCTAttachment(screenshot: application.screenshot())
    after.name = "Saved long article after first wheel scroll"
    after.lifetime = .keepAlways
    add(after)
    XCTAssertEqual(try acceptanceGit(["rev-parse", "HEAD"], at: repositoryRoot), baselineCommit)
    try commitAcceptanceRepository(at: repositoryRoot, evidenceName: "Long article local Git state")
    let relativePath = String(projectDocument.path.dropFirst(repositoryRoot.path.count + 1))
    XCTAssertTrue(
      try acceptanceGit(["show", "HEAD:\(relativePath)"], at: repositoryRoot)
        .contains("End-\(marker)"))
  }

  func testNormalRepositoryMetadataPreviewAndSaveRecoverySurviveRelaunch() throws {
    let root = knowledgeLibraryRootURL.appendingPathComponent("normal-zola", isDirectory: true)
    let articleURL = root.appendingPathComponent("content/posts/2026/taxonomy-acceptance.md")
    let gitMarker = root.appendingPathComponent(".git", isDirectory: true)
    let parkedMarker = root.appendingPathComponent(".git-unavailable", isDirectory: true)
    try FileManager.default.createDirectory(
      at: articleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "base_url = \"https://example.invalid\"\ntitle = \"Isolated acceptance\"\n".write(
      to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    let original = """
      +++
      title = "Taxonomy acceptance"
      date = "2026-10-13"
      slug = "taxonomy-acceptance"
      description = "Isolated metadata and recovery acceptance."
      draft = true
      [taxonomies]
      tags = ["essay, long", "keep-tag"] # preserve taxonomy comment
      categories = ["Notes"]
      series = ["keep-series"]
      [extra]
      tags = ["must-stay-extra"]
      custom = "keep-custom"
      +++

      Original acceptance body.

      """
    try original.write(to: articleURL, atomically: true, encoding: .utf8)
    // Make this imported fixture newer than the first-launch unbound draft,
    // so the real "open recent" handoff selects the intended article.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000)],
      ofItemAtPath: articleURL.path)
    try initializeAcceptanceRepository(at: root)
    let baselineCommit = try acceptanceGit(["rev-parse", "HEAD"], at: root)
    launchApplication(surface: nil)
    completeDataRootSetupIfNeeded()
    openFirstRunSetupWizard()
    completeFirstRunRepositorySetup(at: root, replacingExistingRepository: false)
    XCTAssertTrue(element(identifier: "first-run-writing-summary").waitForExistence(timeout: 45))
    let openRecent = element(identifier: "first-run-open-recent-article")
    XCTAssertTrue(openRecent.waitForExistence(timeout: 10))
    openRecent.click()
    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(editor.waitForExistence(timeout: 15))
    XCTAssertTrue((editor.value as? String)?.contains("Original acceptance body.") == true)
    let inspector = element(identifier: "article-inspector")
    if !inspector.exists { element(identifier: "workspace-inspector-toggle").click() }
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    for (label, oldValue, addition) in [
      ("标签", "essay, long", "taxonomy-ui-tag"),
      ("分类", "Notes", "UITest"),
    ] {
      let field = inspector.textFields[label]
      XCTAssertTrue(field.waitForExistence(timeout: 10))
      XCTAssertTrue((field.value as? String)?.contains(oldValue) == true)
      clickScrollableControl(field, in: inspector)
      application.typeText(addition)
      application.typeKey(.return, modifierFlags: [])
      XCTAssertTrue((field.value as? String)?.contains(addition) == true)
    }
    editor.click()
    application.typeKey("s", modifierFlags: [.command])
    waitForSavedDraft()
    let savedMetadata = try String(contentsOf: articleURL, encoding: .utf8)
    XCTAssertTrue(savedMetadata.contains("taxonomy-ui-tag"))
    XCTAssertTrue(savedMetadata.contains("categories = [\"Notes\", \"UITest\"]"))
    for preserved in [
      "\"essay, long\"", "# preserve taxonomy comment", "series = [\"keep-series\"]",
      "[extra]\ntags = [\"must-stay-extra\"]\ncustom = \"keep-custom\"",
    ] { XCTAssertTrue(savedMetadata.contains(preserved), preserved) }
    XCTAssertTrue(
      try acceptanceGit(["status", "--porcelain"], at: root)
        .contains("content/posts/2026/taxonomy-acceptance.md"))
    XCTAssertEqual(try acceptanceGit(["rev-parse", "HEAD"], at: root), baselineCommit)

    // Check rendered Front Matter in the real inspector. This is distinct
    // from browser/site HTML preview, which needs the site's build tool.
    let seo = element(identifier: "article-inspector-group-seo")
    let seoDisclosure = seo.disclosureTriangles.matching(
      NSPredicate(format: "label BEGINSWITH %@", "SEO 与分享")
    ).firstMatch
    XCTAssertTrue(seoDisclosure.waitForExistence(timeout: 10))
    clickScrollableControl(seoDisclosure, in: inspector)
    let frontMatter = inspector.disclosureTriangles.matching(
      NSPredicate(format: "label BEGINSWITH %@", "文章头信息")
    ).firstMatch
    XCTAssertTrue(frontMatter.waitForExistence(timeout: 10))
    clickScrollableControl(frontMatter, in: inspector)
    let preview = inspector.staticTexts.matching(
      NSPredicate(
        format:
          "(label CONTAINS %@ AND label CONTAINS %@) OR (value CONTAINS %@ AND value CONTAINS %@)",
        "taxonomy-ui-tag", "keep-custom", "taxonomy-ui-tag", "keep-custom")
    ).firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 10))
    let previewScreenshot = XCTAttachment(screenshot: application.screenshot())
    previewScreenshot.name = "Normal article preserved Front Matter preview"
    previewScreenshot.lifetime = .keepAlways
    add(previewScreenshot)

    // Temporarily make only this test's local repository invalid. Production
    // validation must stop the write; restoring the marker must permit retry.
    try FileManager.default.moveItem(at: gitMarker, to: parkedMarker)
    defer {
      if FileManager.default.fileExists(atPath: parkedMarker.path) {
        try? FileManager.default.moveItem(at: parkedMarker, to: gitMarker)
      }
    }
    let marker = "Recovered-\(UUID().uuidString)"
    editor.click()
    application.typeKey(.downArrow, modifierFlags: [.command])
    application.typeKey(.return, modifierFlags: [])
    application.typeText(marker)
    application.typeKey("s", modifierFlags: [.command])
    let failedSave = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", "保存失败"),
      object: element(identifier: "markdown-editor-save-status"))
    XCTAssertEqual(XCTWaiter.wait(for: [failedSave], timeout: 15), .completed)
    XCTAssertEqual(try String(contentsOf: articleURL, encoding: .utf8), savedMetadata)
    XCTAssertTrue((editor.value as? String)?.contains(marker) == true)
    try FileManager.default.moveItem(at: parkedMarker, to: gitMarker)
    application.typeKey("s", modifierFlags: [.command])
    waitForSavedDraft()
    XCTAssertTrue(try String(contentsOf: articleURL, encoding: .utf8).contains(marker))
    application.terminate()
    application.launch()
    application.activate()
    XCTAssertTrue(editor.waitForExistence(timeout: 20))
    XCTAssertTrue((editor.value as? String)?.contains(marker) == true)
    if !inspector.exists { element(identifier: "workspace-inspector-toggle").click() }
    XCTAssertTrue(inspector.textFields["标签"].waitForExistence(timeout: 10))
    XCTAssertTrue(
      (inspector.textFields["标签"].value as? String)?.contains("taxonomy-ui-tag") == true)
    XCTAssertTrue((inspector.textFields["分类"].value as? String)?.contains("UITest") == true)
    XCTAssertFalse(element(identifier: "markdown-editor-save-failure").exists)
    try commitAcceptanceRepository(at: root, evidenceName: "Metadata recovery local Git state")
    XCTAssertTrue(
      try acceptanceGit(["show", "HEAD:content/posts/2026/taxonomy-acceptance.md"], at: root)
        .contains(marker))
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
  /// that article navigation remains local to each WindowGroup instance,
  /// then stops at final confirmation.
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
    let firstArticle = writingDraftRow(title: "RepoPress Studio 发布流程", in: firstWindow)
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
    let secondArticle = writingDraftRow(title: "私密客户复盘草稿", in: secondWindow)
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

    // Capture fixtures use identical window frames. A coordinate click on the
    // first window would hit the frontmost second window instead. With exactly
    // two windows, the system's cycle-window command raises the first one.
    application.typeKey("`", modifierFlags: [.command])
    select("workspace-sidebar-sync", revealing: "repository-workspace", in: firstWindow)
    let preparePublish = firstWindow.descendants(matching: .any)
      .matching(identifier: "workspace-prepare-publish")
      .firstMatch
    XCTAssertTrue(preparePublish.waitForExistence(timeout: 10))
    // The toolbar action is scoped to the current article. Repository pages
    // have no current article, so it stays present but disabled.
    XCTAssertFalse(preparePublish.isEnabled)
    XCTAssertFalse(application.sheets.firstMatch.exists)

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

    element(identifier: "workspace-quick-search-clear").click()
    assertUniqueIdentifier("workspace-quick-search-results")
  }

  func testRepositoryWorkspaceIdentifiersRemainUniqueAcrossAllStages() throws {
    // This case inspects the readable-repository dashboard. The generic demo
    // only creates a .git directory, which correctly shows a read-error state.
    let root = knowledgeLibraryRootURL.appendingPathComponent("repository-fixture", isDirectory: true)
    let remote = knowledgeLibraryRootURL.appendingPathComponent("demo-owner/demo-site.git")
    for directory in [root, remote] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try acceptanceGit(["init", "--quiet", "--bare", "--initial-branch=main"], at: remote)
    try acceptanceGit(["init", "--quiet", "--initial-branch=main"], at: root)
    try acceptanceGit(["config", "user.name", "RepoPress UI Fixture"], at: root)
    try acceptanceGit(["config", "user.email", "fixture@example.invalid"], at: root)
    try Data("Repository dashboard fixture\n".utf8).write(to: root.appendingPathComponent("README.md"))
    try acceptanceGit(["add", "README.md"], at: root)
    try acceptanceGit(["commit", "--quiet", "-m", "Dashboard baseline"], at: root)
    try acceptanceGit(["remote", "add", "origin", remote.path], at: root)
    try acceptanceGit(["push", "--quiet", "origin", "main"], at: root)
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
      "release-history-action-queue",
      "release-history-records",
      "release-history-copy-ledger",
      "release-history-polling-copy-checklist",
      "release-history-polling-run-now",
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

  func testArticleRepairReturnsToTheSameArticlePublishChecks() throws {
    launchApplication(surface: "writing")
    let windowID = application.windows.firstMatch.identifier
    let window = application.windows.matching(identifier: windowID).firstMatch
    let editor = window.descendants(matching: .any)
      .matching(identifier: "markdown-document-editor").firstMatch
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    let originalBody = try XCTUnwrap(editor.value as? String)

    showPublishChecks()
    let header = element(identifier: "publish-drawer-header")
    XCTAssertTrue(header.waitForExistence(timeout: 10))
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

    element(identifier: "article-publish-repair-return").click()
    XCTAssertTrue(header.waitForExistence(timeout: 10))
    assertIdentifierDisappears("article-publish-repair-bar")
    XCTAssertEqual(editor.value as? String, originalBody)
    XCTAssertFalse(application.sheets.firstMatch.exists, "Returning must never start a publish.")
  }

  func testMinimumWindowPublishActionsOpenOneSheetAndCloseWithoutPublishing() throws {
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 900, height: 620))
    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    XCTAssertEqual(application.windows.firstMatch.frame.width, 900, accuracy: 1)
    let originalBody = try XCTUnwrap(editor.value as? String)
    let prepare = element(identifier: "workspace-prepare-publish")
    XCTAssertTrue(prepare.isEnabled)
    prepare.click()
    closePublishSheet()
    XCTAssertEqual(editor.value as? String, originalBody)
    application.typeKey("p", modifierFlags: [.option, .command])
    closePublishSheet()
    XCTAssertEqual(editor.value as? String, originalBody)
    showPublishChecks()
    XCTAssertTrue(
      element(identifier: "workspace-compact-publish-sheet").waitForExistence(timeout: 10))
    assertUniqueIdentifier("publish-drawer-action-publish-current")
    assertUniqueIdentifier("publish-drawer-action-publish-all")
    element(identifier: "compact-publish-close").click()
    assertIdentifierDisappears("workspace-compact-publish-sheet")
    XCTAssertEqual(editor.value as? String, originalBody)
  }

  func testMinimumWindowPublishRepairClosesItsSheetBeforeOpeningTheRepair() throws {
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 900, height: 620))
    let editor = element(identifier: "markdown-document-editor")
    XCTAssertTrue(editor.waitForExistence(timeout: 10))
    XCTAssertEqual(application.windows.firstMatch.frame.width, 900, accuracy: 1)
    let originalBody = try XCTUnwrap(editor.value as? String)
    showPublishChecks()
    XCTAssertTrue(
      element(identifier: "workspace-compact-publish-sheet").waitForExistence(timeout: 10))
    let metadataIssue = application.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
        "publish-readiness-action-", "编辑元数据"
      )
    ).firstMatch
    XCTAssertTrue(metadataIssue.waitForExistence(timeout: 10))
    clickVisibleDrawerControl(metadataIssue)
    assertIdentifierDisappears("workspace-compact-publish-sheet")
    XCTAssertTrue(element(identifier: "article-publish-repair-bar").waitForExistence(timeout: 10))
    XCTAssertTrue(element(identifier: "article-inspector").waitForExistence(timeout: 10))
    application.sheets.firstMatch.buttons["完成"].click()
    XCTAssertFalse(application.sheets.firstMatch.exists)
    element(identifier: "article-publish-repair-return").click()
    XCTAssertTrue(
      element(identifier: "workspace-compact-publish-sheet").waitForExistence(timeout: 10))
    element(identifier: "compact-publish-close").click()
    assertIdentifierDisappears("workspace-compact-publish-sheet")
    XCTAssertEqual(editor.value as? String, originalBody)
  }

  func testMinimumWindowPublishSheetClosesWithoutPublishing() throws {
    launchApplication(
      surface: "sync-api-publish", screenshotContentSize: CGSize(width: 900, height: 620))
    let window = application.windows.firstMatch
    XCTAssertEqual(window.frame.width, 900, accuracy: 1)
    select("workspace-sidebar-writing", revealing: "markdown-document-editor", in: window)
    application.typeKey("s", modifierFlags: [.control, .command])
    let article = writingDraftRow(title: "RepoPress Studio 发布流程", in: window)
    XCTAssertTrue(article.waitForExistence(timeout: 10))
    article.click()
    let editor = element(identifier: "markdown-document-editor")
    let originalBody = try XCTUnwrap(editor.value as? String)
    let articlePublish = element(identifier: "workspace-prepare-publish")
    XCTAssertTrue(articlePublish.waitForExistence(timeout: 10))
    XCTAssertTrue(articlePublish.isEnabled)
    articlePublish.click()
    closePublishSheet()
    select("workspace-sidebar-sync", revealing: "repository-workspace", in: window)
    let repositoryPublish = element(identifier: "workspace-prepare-publish")
    XCTAssertTrue(repositoryPublish.waitForExistence(timeout: 10))
    XCTAssertFalse(repositoryPublish.isEnabled)
    XCTAssertFalse(application.sheets.firstMatch.exists)
    select("workspace-sidebar-writing", revealing: "markdown-document-editor", in: window)
    XCTAssertEqual(editor.value as? String, originalBody)
  }

  /// Both publish actions run end to end against a real repository whose
  /// origin is a bare repository inside this test's own data directory, so
  /// nothing can reach a hosted site or the user's articles.
  func testPublishThisAndPublishAllConfirmationsCancelWithoutPublishing() throws {
    try runPublishAcceptance(confirmPublication: false)
  }

  func testPublishThisAndPublishAllPushOnlyToTheTestOwnedRemote() throws {
    try runPublishAcceptance(confirmPublication: true)
  }

  func testAheadHistoryCanReviewSingleAndAllWithoutPublishing() throws {
    try runPublishAcceptance(confirmPublication: false, aheadCount: 5)
  }

  private func runPublishAcceptance(confirmPublication: Bool, aheadCount: Int = 0) throws {
    let root = knowledgeLibraryRootURL.appendingPathComponent(
      "repository-fixture", isDirectory: true)
    // The bare remote's owner/name match the demo site's repository identity.
    let remote = knowledgeLibraryRootURL.appendingPathComponent(
      "demo-owner/demo-site.git", isDirectory: true)
    for directory in [root, remote] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try acceptanceGit(["init", "--quiet", "--initial-branch=main"], at: root)
    try acceptanceGit(["config", "user.name", "RepoPress Acceptance"], at: root)
    try acceptanceGit(["config", "user.email", "acceptance@example.invalid"], at: root)
    try Data("Publish acceptance fixture\n".utf8).write(
      to: root.appendingPathComponent("README.md"))
    try acceptanceGit(["add", "README.md"], at: root)
    try acceptanceGit(["commit", "--quiet", "-m", "Acceptance baseline"], at: root)
    // Seed a local-only bare origin without executing any push command.
    try acceptanceGit(["clone", "--quiet", "--bare", root.path, remote.path], at: root)
    try acceptanceGit(["remote", "add", "origin", remote.path], at: root)
    try acceptanceGit(["fetch", "--quiet", "origin"], at: root)
    let origin = try acceptanceGit(["remote", "get-url", "--push", "origin"], at: root)
    XCTAssertTrue(origin.hasPrefix(knowledgeLibraryRootURL.path + "/"), origin)
    let remoteBaseline = try acceptanceGit(["rev-parse", "HEAD"], at: root)
    for index in 0..<aheadCount {
      try acceptanceGit(["commit", "--allow-empty", "-m", "Reviewed local history \(index)"], at: root)
    }
    let baseline = try acceptanceGit(["rev-parse", "HEAD"], at: root)

    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_UI_TEST_NO_DEPLOYMENT"] = "1"
    launchApplication(surface: "writing")
    let window = application.windows.firstMatch
    XCTAssertTrue(element(identifier: "markdown-document-editor").waitForExistence(timeout: 10))
    // The demo fixture writes a Zola config, but this runner's PATH has no
    // trusted Zola, so the site build gate would refuse every publish. That
    // gate has its own unit tests; here it is skipped for want of a config.
    try? FileManager.default.removeItem(at: root.appendingPathComponent("config.toml"))
    // A file outside every article must stay local until 发布全部.
    let theme = root.appendingPathComponent("static/acceptance-theme.css")
    try FileManager.default.createDirectory(
      at: theme.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("body { color: #222; }\n".utf8).write(to: theme)

    if !writingDraftRow(title: "RepoPress Studio 发布流程", in: window).waitForExistence(timeout: 5) {
      application.typeKey("s", modifierFlags: [.control, .command])
    }
    // The list may re-render while the demo fixture settles; resolve the row
    // again for each attempt instead of clicking a stale snapshot.
    var selectedArticle = false
    for _ in 0..<3 where !selectedArticle {
      let article = writingDraftRow(title: "RepoPress Studio 发布流程", in: window)
      guard article.waitForExistence(timeout: 10), article.isHittable else { continue }
      article.click()
      let path = element(identifier: "markdown-article-path-menu")
      selectedArticle =
        XCTWaiter.wait(
          for: [
            XCTNSPredicateExpectation(
              predicate: NSPredicate(
                format: "value CONTAINS %@", "repopress-studio-publishing-flow"),
              object: path)
          ], timeout: 5) == .completed
    }
    XCTAssertTrue(selectedArticle, "The demo article must open before publishing it.")

    element(identifier: "workspace-prepare-publish").click()
    let scopedConfirmation = element(identifier: "publish-worktree-confirmation")
    XCTAssertTrue(scopedConfirmation.waitForExistence(timeout: 60))
    XCTAssertTrue(element(identifier: "publish-worktree-article-summary").exists)
    let targetURL = element(identifier: "publish-worktree-target-url")
    XCTAssertTrue(targetURL.exists)
    let targetURLText = (targetURL.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? targetURL.label
    XCTAssertTrue(targetURLText.contains("待配置"), targetURL.debugDescription)
    XCTAssertTrue(element(identifier: "publish-worktree-content-summary").exists)
    let scopedSummary = element(identifier: "publish-worktree-summary")
    let scopeText = aheadCount > 0 ? "当前未提交文件仍只限于这篇文章" : "只提交这篇文章"
    let scopeDescription = scopedSummary.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", scopeText, scopeText)
    ).firstMatch
    XCTAssertTrue(scopeDescription.waitForExistence(timeout: 5), scopedSummary.debugDescription)
    let scopedFiles = element(identifier: "publish-worktree-file-list-details")
    XCTAssertTrue(scopedFiles.waitForExistence(timeout: 10))
    clickScrollableControl(
      scopedFiles, in: scopedConfirmation.descendants(matching: .scrollView).firstMatch,
      disclosureLeadingInset: 26)
    if String(describing: scopedFiles.value ?? "") != "1" {
      let screenshot = XCTAttachment(screenshot: application.screenshot())
      screenshot.name = "publish-files-disclosure-not-expanded"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      let hierarchy = XCTAttachment(string: application.debugDescription)
      hierarchy.name = "publish-files-disclosure-hierarchy"
      hierarchy.lifetime = .keepAlways
      add(hierarchy)
    }
    XCTAssertEqual(String(describing: scopedFiles.value ?? ""), "1")
    let fileReview = element(identifier: "publish-worktree-file-review")
    XCTAssertTrue(fileReview.waitForExistence(timeout: 10))
    let articlePath = fileReview.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@",
                  "repopress-studio-publishing-flow", "repopress-studio-publishing-flow")
    ).firstMatch
    XCTAssertNotNil(
      scrollToReveal(
        [articlePath], in: scopedConfirmation.descendants(matching: .scrollView).firstMatch,
        window: window, maxSteps: 8), fileReview.debugDescription)
    attachWindowScreenshot(named: "publish-this-confirmation-no-publish")
    let cancel = scopedConfirmation.buttons["取消"]
    XCTAssertTrue(cancel.waitForExistence(timeout: 5))
    cancel.click()
    assertIdentifierDisappears("publish-worktree-confirmation")
    XCTAssertEqual(try acceptanceGit(["rev-parse", "HEAD"], at: root), baseline)
    XCTAssertEqual(try acceptanceGit(["rev-parse", "refs/heads/main"], at: remote), remoteBaseline)
    XCTAssertTrue(
      try acceptanceGit(["status", "--porcelain", "--untracked-files=all"], at: root)
        .contains("static/acceptance-theme.css"))

    if !confirmPublication {
      attachWindowScreenshot(named: "publish-this-cancelled")
      application.typeKey("p", modifierFlags: [.option, .command])
      let allConfirmation = element(identifier: "publish-worktree-confirmation")
      XCTAssertTrue(allConfirmation.waitForExistence(timeout: 60))
      let title = allConfirmation.descendants(matching: .any).matching(
        NSPredicate(format: "value == %@ OR label == %@", "发布全部变更", "发布全部变更")
      ).firstMatch
      XCTAssertTrue(title.waitForExistence(timeout: 5))
      if aheadCount > 0 {
        let history = element(identifier: "publish-worktree-history-acknowledgement")
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        XCTAssertFalse(element(identifier: "publish-worktree-confirm").isEnabled)
        clickScrollableControl(
          history, in: allConfirmation.descendants(matching: .scrollView).firstMatch)
      }
      XCTAssertTrue(element(identifier: "publish-worktree-confirm").isEnabled)
      attachWindowScreenshot(named: "publish-all-confirmation-no-publish")
      allConfirmation.buttons["取消"].click()
      assertIdentifierDisappears("publish-worktree-confirmation")
      XCTAssertEqual(try acceptanceGit(["rev-parse", "HEAD"], at: root), baseline)
      XCTAssertEqual(try acceptanceGit(["rev-parse", "refs/heads/main"], at: remote), remoteBaseline)
      XCTAssertTrue(try acceptanceGit(["diff", "--cached", "--name-only"], at: root).isEmpty)
      return
    }

    element(identifier: "workspace-prepare-publish").click()
    let articleCommit = try confirmPublishAndAttachEvidence(
      name: "publish-this", expectedTitle: "发布这篇文章", root: root, remote: remote)
    XCTAssertNotEqual(articleCommit, baseline)
    let articlePaths = try acceptanceGit(
      ["diff", "--name-only", baseline, articleCommit], at: root)
    XCTAssertTrue(
      // The demo article's dated folder follows its publish date.
      articlePaths.contains("/repopress-studio-publishing-flow.md"),
      articlePaths)
    XCTAssertFalse(articlePaths.contains("acceptance-theme.css"), articlePaths)
    XCTAssertTrue(
      try acceptanceGit(["status", "--porcelain", "--untracked-files=all"], at: root)
        .contains("static/acceptance-theme.css"),
      "Publishing one article must leave other changes uncommitted.")

    application.typeKey("p", modifierFlags: [.option, .command])
    let allCommit = try confirmPublishAndAttachEvidence(
      name: "publish-all", expectedTitle: "发布全部变更", root: root, remote: remote)
    XCTAssertTrue(
      try acceptanceGit(["diff", "--name-only", articleCommit, allCommit], at: root)
        .contains("static/acceptance-theme.css"))
    XCTAssertTrue(
      try acceptanceGit(["status", "--porcelain", "--untracked-files=all"], at: root).isEmpty)
    let evidence = XCTAttachment(
      string: """
        Test-owned repository: \(root.path)
        Test-owned bare origin: \(origin)
        Baseline: \(baseline)
        发布这篇 commit: \(articleCommit) (\(articlePaths.replacingOccurrences(of: "\n", with: ", ")))
        发布全部 commit: \(allCommit)
        Remote main after both: \(try acceptanceGit(["rev-parse", "refs/heads/main"], at: remote))
        """)
    evidence.name = "publish-actions-git-evidence"
    evidence.lifetime = .keepAlways
    add(evidence)
  }

  /// Confirms the open publish sheet, waits for its outcome, and returns the
  /// pushed commit after checking the test-owned remote received exactly it.
  private func confirmPublishAndAttachEvidence(
    name: String, expectedTitle: String, root: URL, remote: URL
  ) throws -> String {
    let confirmation = element(identifier: "publish-worktree-confirmation")
    XCTAssertTrue(
      confirmation.waitForExistence(timeout: 60),
      "\(name) must open its confirmation: \(application.debugDescription)")
    // SwiftUI exposes Text content as the static text's value on macOS.
    let title = confirmation.descendants(matching: .any).matching(
      NSPredicate(format: "value == %@ OR label == %@", expectedTitle, expectedTitle)
    ).firstMatch
    XCTAssertTrue(title.waitForExistence(timeout: 5), expectedTitle)
    attachWindowScreenshot(named: "\(name)-confirmation")
    let confirm = element(identifier: "publish-worktree-confirm")
    XCTAssertTrue(confirm.isEnabled)
    confirm.click()
    let outcome = element(identifier: "publish-outcome")
    XCTAssertTrue(outcome.waitForExistence(timeout: 90), "\(name) must report its outcome.")
    let message = element(identifier: "publish-outcome-message")
    let messageText = (message.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? message.label
    XCTAssertTrue(messageText.contains("Git 推送已确认"), messageText)
    if name == "publish-this" {
      let trackingStatus = element(identifier: "publish-outcome-tracking-status")
      XCTAssertTrue(trackingStatus.waitForExistence(timeout: 10), name)
      let trackingStatusText = (trackingStatus.value as? String).flatMap {
        $0.isEmpty ? nil : $0
      } ?? trackingStatus.label
      XCTAssertEqual(trackingStatusText, "已推送，尚未确认上线", trackingStatus.debugDescription)
      let trackingMessage = element(identifier: "publish-outcome-tracking-message")
      XCTAssertTrue(trackingMessage.waitForExistence(timeout: 10), name)
      let trackingMessageText = (trackingMessage.value as? String).flatMap {
        $0.isEmpty ? nil : $0
      } ?? trackingMessage.label
      XCTAssertEqual(trackingMessageText, "先补齐 站点 URL 或状态端点 URL。")
      assertUniqueIdentifier("publish-outcome-tracking-progress")
    }
    attachWindowScreenshot(named: "\(name)-outcome")
    element(identifier: "publish-outcome-done").click()
    assertIdentifierDisappears("publish-outcome")
    let head = try acceptanceGit(["rev-parse", "HEAD"], at: root)
    if name == "publish-this" {
      let publishedPaths = try acceptanceGit(["show", "--format=", "--name-only", head], at: root)
      let articlePath = try XCTUnwrap(
        publishedPaths.split(separator: "\n").first {
          $0.hasSuffix("/repopress-studio-publishing-flow.md")
        }.map(String.init))
      select("workspace-sidebar-sync", revealing: "repository-sidebar-stage-history")
      select("repository-sidebar-stage-history", revealing: "repository-section-release-history")
      let actionQueue = element(identifier: "release-history-action-queue")
      XCTAssertTrue(actionQueue.waitForExistence(timeout: 10))
      let staleLocalAction = actionQueue.descendants(matching: .any).matching(
        NSPredicate(
          format: "(label CONTAINS %@ OR value CONTAINS %@)",
          "提交本地写入：RepoPress Studio 发布流程", "提交本地写入：RepoPress Studio 发布流程")
      ).firstMatch
      XCTAssertFalse(staleLocalAction.exists, "The confirmed article push must retire its local action.")
      attachWindowScreenshot(named: "publish-this-action-queue")
      XCTAssertTrue(
        revealReleaseTracking(
          commitSHA: head,
          articlePath: articlePath),
        "The release history must expose tracking for this article and commit \(head)."
      )
      select("workspace-sidebar-writing", revealing: "markdown-document-editor")
    }
    XCTAssertEqual(try acceptanceGit(["rev-parse", "refs/heads/main"], at: remote), head)
    return head
  }

  private func attachWindowScreenshot(named name: String) {
    let screenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    screenshot.name = name
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  /// Release history is date ordered and can lazy-load older cards. Find the
  /// record by its own commit/article metadata before asserting its tracking view.
  private func revealReleaseTracking(commitSHA: String, articlePath: String) -> Bool {
    let window = application.windows.firstMatch
    let scrollContainer = repositoryScrollContainer(in: window)
    let commitPrefix = String(commitSHA.prefix(8))
    for _ in 0..<32 {
      let records = application.descendants(matching: .any).matching(
        NSPredicate(
          format: "identifier MATCHES %@",
          "release-record-[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}")
      ).allElementsBoundByIndex
      for record in records {
        // Debug descriptions may truncate long metadata values. Match the
        // actual AX text inside this exact record, including its full path.
        let metadata = record.descendants(matching: .any)
        let commit = metadata.matching(
          NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", commitPrefix, commitPrefix)
        ).firstMatch
        let article = metadata.matching(
          NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", articlePath, articlePath)
        ).firstMatch
        guard commit.exists, article.exists else { continue }
        let tracking = record.descendants(matching: .any)
          .matching(identifier: "release-article-publish-tracking").firstMatch
        guard tracking.exists else { continue }
        let status = tracking.descendants(matching: .any)
          .matching(identifier: "release-article-publish-tracking-status").firstMatch
        let message = tracking.descendants(matching: .any)
          .matching(identifier: "release-article-publish-tracking-message").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5), record.debugDescription)
        XCTAssertTrue(message.waitForExistence(timeout: 5), record.debugDescription)
        XCTAssertEqual(axText(status), "已推送，尚未确认上线")
        XCTAssertFalse(axText(message).isEmpty)
        guard
          scrollToReveal([status], in: scrollContainer, window: window, maxSteps: 12) != nil
        else { continue }
        let viewport = window.frame.intersection(scrollContainer.frame).insetBy(dx: 4, dy: 12)
        for _ in 0..<4 {
          let progressFrame = status.frame.union(message.frame)
          if viewport.contains(progressFrame) { break }
          let delta = progressFrame.maxY > viewport.maxY
            ? -(progressFrame.maxY - viewport.maxY + 24)
            : viewport.minY - progressFrame.minY + 24
          scrollContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .scroll(byDeltaX: 0, deltaY: delta)
        }
        XCTAssertTrue(viewport.contains(status.frame.union(message.frame)))
        attachWindowScreenshot(named: "publish-this-tracking-in-history")
        return true
      }
      application.activate()
      scrollContainer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        .scroll(byDeltaX: 0, deltaY: -280)
    }
    return false
  }

  private func axText(_ element: XCUIElement) -> String {
    let value = (element.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let value, !value.isEmpty { return value }
    return element.label.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func testPublishChecksShowTheArticleChecksAndBothPublishActions() throws {
    launchApplication(surface: "sync-api-publish")
    XCTAssertTrue(element(identifier: "repository-workspace").waitForExistence(timeout: 10))
    select(
      "workspace-sidebar-writing", revealing: "markdown-document-editor",
      in: application.windows.firstMatch)
    // This fixture may already show the checks. Avoid opening a redundant
    // native menu whose popup AX tree is intermittently unavailable to XCTest.
    if !element(identifier: "publish-drawer-header").exists {
      showPublishChecks()
    }
    assertUniqueIdentifier("publish-drawer-header")
    assertUniqueIdentifier("article-publication-status")
    let publicationStatus = element(identifier: "article-publication-status")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(
              format: "label == %@ OR value == %@",
              "已推送，尚未确认上线", "已推送，尚未确认上线"),
            object: publicationStatus)
        ], timeout: 5),
      .completed
    )
    XCTAssertEqual(element(identifier: "workspace-prepare-publish").label, "发布这篇")
    for identifier in [
      "publish-drawer-readiness-checklist",
      "publish-drawer-action-publish-current",
      "publish-drawer-action-publish-all",
    ] {
      assertUniqueIdentifier(identifier)
    }
    let primaryAction = element(identifier: "publish-drawer-action-publish-current")
    let checksScroll = element(identifier: "publish-drawer-scroll-content")
    XCTAssertGreaterThanOrEqual(
      primaryAction.frame.minY, checksScroll.frame.maxY,
      "Both publish actions stay in the fixed footer below the scrolling checks."
    )
    XCTAssertFalse(application.sheets.firstMatch.exists, "Showing checks never starts a publish.")
    let checks = element(identifier: "workspace-publish-inspector")
    for removedTitle in ["发布账户", "变更内容", "高级发布方式", "保存到本地", "分支管理", "部署"] {
      XCTAssertFalse(
        checks.descendants(matching: .staticText)[removedTitle].exists,
        "\(removedTitle) must stay out of the publish checks panel.")
    }
    let screenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    screenshot.name = "publish-checks-panel"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  func testAdvancedMetadataCanBeReachedByVisibleInspectorControls() throws {
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 1440, height: 900))
    XCTAssertTrue(element(identifier: "markdown-document-editor").waitForExistence(timeout: 10))
    let tabs = element(identifier: "workspace-inspector-tabs")
    if !tabs.exists {
      element(identifier: "workspace-inspector-toggle").click()
    }
    XCTAssertTrue(tabs.waitForExistence(timeout: 5))
    tabs.radioButtons["信息"].click()
    let inspector = element(identifier: "article-inspector")
    XCTAssertTrue(inspector.waitForExistence(timeout: 5))
    let advanced = element(identifier: "article-metadata-advanced")
    XCTAssertTrue(advanced.waitForExistence(timeout: 5))
    let slug = inspector.textFields["文章固定链接"]
    XCTAssertFalse(slug.exists)
    XCTAssertFalse(element(identifier: "article-publish-reminder").exists)
    let disclosure = advanced.disclosureTriangles["高级"].firstMatch
    XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
    clickScrollableControl(disclosure, in: inspector, disclosureLeadingInset: 26)
    XCTAssertTrue(slug.waitForExistence(timeout: 5))
    XCTAssertTrue(slug.isEnabled)
    XCTAssertTrue(element(identifier: "article-publish-reminder").waitForExistence(timeout: 5))
    let originalSlug = slug.value as? String
    let screenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    screenshot.name = "advanced-metadata-visible-click-route"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    clickScrollableControl(disclosure, in: inspector, disclosureLeadingInset: 26)
    assertDisappears(slug)
    assertDisappears(element(identifier: "article-publish-reminder"))
    clickScrollableControl(disclosure, in: inspector, disclosureLeadingInset: 26)
    XCTAssertTrue(slug.waitForExistence(timeout: 5))
    XCTAssertEqual(slug.value as? String, originalSlug)
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
    select("workspace-sidebar-images", revealing: "repository-image-search")

    // SwiftUI coalesces single-child accessibility containers. Verify the
    // workbench and its actual controls, rather than intermediate view wrappers.
    for identifier in [
      "image-workbench",
      "repository-image-folder-search", "repository-image-search",
      "repository-image-display-mode", "repository-image-process-selection",
    ] {
      assertUniqueIdentifier(identifier)
    }
    select("image-sidebar-stage-overview", revealing: "image-workbench-overview")

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
      revealing: "repository-image-search"
    )
    for identifier in [
      "image-workbench",
      "repository-image-search",
      "repository-image-process-selection",
    ] {
      assertUniqueIdentifier(identifier)
    }
  }

  func testImageBatchPreviewCancelsAndAppliesOnlyCheckedImages() throws {
    let fixture = try makeImageBatchRepository()
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_PERSISTENCE_ROOT"] =
      screenshotRuntimeRootURL.appendingPathComponent("workbench", isDirectory: true).path
    launchApplication(surface: "writing")
    // Demo seeding points at this repository but does not import new files.
    // Use the real discovery flow to register the fixture's image references.
    showSettingsWindow()
    assertIdentifierExists("settings-content")
    let settings = currentSettingsWindow()
    select(
      "settings-tab-defaultRules", revealing: "repository-draft-discovery-scan-now", in: settings)
    let scan = settings.buttons
      .matching(identifier: "repository-draft-discovery-scan-now").firstMatch
    XCTAssertTrue(scan.isEnabled)
    scan.click()
    // Startup discovery may have imported the fixture before this manual scan.
    let discoveryFinished = settings.staticTexts.matching(
      NSPredicate(
        format: "label CONTAINS %@ OR value CONTAINS %@ OR label CONTAINS %@ OR value CONTAINS %@",
        "已发现并加入工作台", "已发现并加入工作台", "扫描完成，没有发现", "扫描完成，没有发现"
      )
    ).firstMatch
    XCTAssertTrue(discoveryFinished.waitForExistence(timeout: 30))
    settings.typeKey("w", modifierFlags: [.command])
    let search = element(identifier: "writing-draft-search")
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.click()
    search.typeText("Image batch fixture")
    let article = application.staticTexts["Image batch fixture"].firstMatch
    XCTAssertTrue(article.waitForExistence(timeout: 30))
    article.click()
    select("workspace-sidebar-images", revealing: "repository-image-grid")

    let selectedImage = application.buttons.matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label == %@",
        "repository-image-tile-", "selected.png"
      )
    ).firstMatch
    XCTAssertTrue(selectedImage.waitForExistence(timeout: 15))
    selectedImage.click()
    application.typeKey("a", modifierFlags: [.command])
    let originalArticle = try Data(contentsOf: fixture.article)

    func openPreview() {
      select("repository-image-process-selection", revealing: "image-action-fill-metadata")
      select("image-action-fill-metadata", revealing: "image-batch-preview")
    }

    openPreview()
    let preview = element(identifier: "image-batch-preview")
    let affectedImages = preview.descendants(matching: .checkBox).matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "image-batch-preview-item-")
    )
    XCTAssertEqual(affectedImages.count, 2)
    let exclusions = element(identifier: "image-batch-preview-excluded")
    XCTAssertTrue(exclusions.exists)
    XCTAssertTrue(((exclusions.value as? String) ?? exclusions.label).contains("1"))
    let screenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    screenshot.name = "Image batch preview with one unregistered file excluded"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    element(identifier: "image-batch-preview-cancel").click()
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: preview)
        ],
        timeout: 10
      ), .completed
    )
    XCTAssertEqual(try Data(contentsOf: fixture.article), originalArticle)

    openPreview()
    let reopenedPreview = element(identifier: "image-batch-preview")
    let confirm = element(identifier: "image-batch-preview-confirm")
    element(identifier: "image-batch-preview-exclude-all").click()
    XCTAssertFalse(confirm.isEnabled)
    element(identifier: "image-batch-preview-select-all").click()
    let untouched = reopenedPreview.descendants(matching: .checkBox).matching(
      NSPredicate(
        format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
        "image-batch-preview-item-", "untouched.png"
      )
    ).firstMatch
    XCTAssertTrue(untouched.exists)
    untouched.click()
    XCTAssertTrue(confirm.isEnabled)
    confirm.click()

    let selectedImageWasSaved = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        guard let body = try? String(contentsOf: fixture.article, encoding: .utf8) else {
          return false
        }
        return body.contains("/images/batch-ui/selected.png")
          && !body.contains("![](/images/batch-ui/selected.png)")
          && body.contains("![](/images/batch-ui/untouched.png)")
      }, object: nil
    )
    XCTAssertEqual(XCTWaiter.wait(for: [selectedImageWasSaved], timeout: 30), .completed)
    XCTAssertFalse(preview.exists)
    selectedImage.click()
    let caption = element(identifier: "repository-image-caption")
    XCTAssertTrue(caption.waitForExistence(timeout: 10))
    let captionText = try XCTUnwrap(caption.value as? String)
    XCTAssertFalse(captionText.isEmpty)
    XCTAssertNotEqual(captionText, caption.placeholderValue)
    for imageURL in fixture.images {
      XCTAssertEqual(try Data(contentsOf: imageURL), fixture.imageData)
    }
    let resultScreenshot = XCTAttachment(screenshot: application.windows.firstMatch.screenshot())
    resultScreenshot.name = "Image batch result with selected article usage"
    resultScreenshot.lifetime = .keepAlways
    add(resultScreenshot)
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
    select("repository-action-open-images", revealing: "repository-image-search", in: firstWindow)
    select("image-sidebar-stage-overview", revealing: "image-workbench-overview", in: firstWindow)
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

  func testContentHealthHasOneProblemListWithFilters() throws {
    launchApplication(surface: "writing")
    select(
      "workspace-sidebar-sync",
      revealing: "repository-workspace"
    )
    select(
      "repository-sidebar-stage-checks",
      revealing: "content-health-workspace"
    )

    for identifier in [
      "workspace-sidebar-writing",
      "workspace-sidebar-library",
      "workspace-sidebar-rss",
      "workspace-sidebar-images",
      "workspace-sidebar-sync",
    ] {
      assertUniqueIdentifier(identifier)
    }
    XCTAssertFalse(
      element(identifier: "workspace-sidebar-contentHealth").exists,
      "Site Checks must remain a Site child route, not a primary sidebar entry."
    )

    for identifier in [
      "repository-sidebar-stage-navigation",
      "repository-sidebar-stage-checks",
      "content-health-workspace",
      "content-health-stage-overview",
      "content-health-count-errors",
      "content-health-count-warnings",
      "content-health-count-maintenance",
      "content-health-count-passed",
      "content-health-search",
      "content-health-recheck",
      "content-health-grouping",
      "content-health-source-filter",
      "content-health-ai-filter",
    ] {
      assertUniqueIdentifier(identifier)
    }

    XCTAssertEqual(application.buttons.matching(identifier: "content-health-count-passed").count, 0)
    let errors = element(identifier: "content-health-count-errors")
    errors.click()
    assertUniqueIdentifier("content-health-count-errors")
    XCTAssertTrue(
      (element(identifier: "content-health-count-errors").value as? String ?? "").contains("已筛选"))
    element(identifier: "content-health-count-errors").click()
    assertUniqueIdentifier("content-health-count-errors")
    XCTAssertTrue(
      (element(identifier: "content-health-count-errors").value as? String ?? "").contains("未筛选"))

    let siteCounts = ["errors", "warnings", "maintenance", "passed"].map {
      (element(identifier: "content-health-count-\($0)").value as? String ?? "")
        .components(separatedBy: "，").first ?? ""
    }
    element(identifier: "content-health-count-maintenance").click()
    assertIdentifierDisappears("content-health-grouping")
    let filteredCounts = ["errors", "warnings", "maintenance", "passed"].map {
      (element(identifier: "content-health-count-\($0)").value as? String ?? "")
        .components(separatedBy: "，").first ?? ""
    }
    XCTAssertEqual(filteredCounts, siteCounts, "List filters must preserve full-site card counts.")
    element(identifier: "content-health-count-maintenance").click()
    assertUniqueIdentifier("content-health-grouping")

    let search = element(identifier: "content-health-search")
    search.click()
    search.typeText("987654321098765432109876543210")
    assertUniqueIdentifier("content-health-all-clear")
    XCTAssertFalse(element(identifier: "content-health-issue-list").exists)
    application.typeKey("a", modifierFlags: [.command])
    application.typeKey(.delete, modifierFlags: [])
    assertUniqueIdentifier("content-health-issue-list")
    let issueButtons = application.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "content-health-select-issue-"))
    XCTAssertTrue(issueButtons.firstMatch.waitForExistence(timeout: 10))
    XCTAssertGreaterThanOrEqual(
      issueButtons.count, 2, "The fixture must expose two issues for keyboard traversal.")
    let firstIssue = issueButtons.element(boundBy: 0)
    let secondIssue = issueButtons.element(boundBy: 1)
    firstIssue.click()
    XCTAssertTrue(firstIssue.isSelected)
    assertUniqueIdentifier("content-health-selected-issue-inspector")
    assertUniqueIdentifier("content-health-selected-issue-heading")
    let issueHeading = element(identifier: "content-health-selected-issue-heading")
    let firstTitle = firstIssue.label.replacingOccurrences(of: "选择问题：", with: "")
    XCTAssertTrue(
      issueHeading.label.contains(firstTitle),
      "Heading label \"\(issueHeading.label)\" (value \"\(String(describing: issueHeading.value))\", title \"\(issueHeading.title)\") must name the selected issue \"\(firstTitle)\".")
    let headingDetails = issueHeading.label.replacingOccurrences(of: firstTitle + "，", with: "")
    let metadata = headingDetails.components(separatedBy: "、")
    XCTAssertGreaterThanOrEqual(
      metadata.count, 2, "Heading metadata must include section and source: \(headingDetails)")
    XCTAssertTrue(["错误", "警告", "优化建议", "维护"].contains(metadata.first ?? ""))
    if metadata.count >= 2 {
      XCTAssertTrue(["文章", "站点", "维护"].contains(metadata[1]))
      if metadata[1] == "文章" {
        XCTAssertTrue(headingDetails.contains("篇文章"))
      }
    }
    application.typeKey(.downArrow, modifierFlags: [])
    XCTAssertTrue(secondIssue.isSelected, "Down must move selection to the next issue.")
    XCTAssertFalse(firstIssue.isSelected)
    let secondTitle = secondIssue.label.replacingOccurrences(of: "选择问题：", with: "")
    let headingUpdated = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", secondTitle), object: issueHeading)
    XCTAssertEqual(XCTWaiter.wait(for: [headingUpdated], timeout: 3), .completed)
    application.typeKey(.upArrow, modifierFlags: [])
    XCTAssertTrue(firstIssue.isSelected)
    XCTAssertFalse(secondIssue.isSelected)

    XCTAssertEqual(
      element(identifier: "repository-sidebar-stage-checks").value as? String,
      "已选中"
    )
    XCTAssertEqual(element(identifier: "workspace-sidebar-sync").value as? String, "已选中")
    XCTAssertEqual(
      element(identifier: "repository-sidebar-stage-overview").value as? String,
      "未选中"
    )

    select(
      "repository-sidebar-stage-overview",
      revealing: "repository-workspace"
    )
    application.typeKey("5", modifierFlags: [.command])
    let checksStage = element(identifier: "repository-sidebar-stage-checks")
    XCTAssertEqual(
      XCTWaiter.wait(
        for: [
          XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "已选中"), object: checksStage
          )
        ], timeout: 10
      ), .completed
    )

    let screenshot = XCTAttachment(screenshot: application.screenshot())
    screenshot.name = "site-checks-navigation"
    screenshot.lifetime = .keepAlways
    add(screenshot)

    XCTAssertFalse(application.buttons["repository-sidebar-stage-maintenance"].exists)
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

  func testAIInspectorMenuOpensAndSelectsInMainWindow() {
    launchApplication(surface: "writing")
    XCTAssertTrue(element(identifier: "ai-assistant-toolbar-button").waitForExistence(timeout: 10))
    let mainWindow = application.windows.firstMatch
    let initialWindowCount = application.windows.count
    let inspector = mainWindow.descendants(matching: .any)
      .matching(identifier: "ai-assistant-inspector").firstMatch
    XCTAssertFalse(inspector.exists)
    openAssistantFromMenu()
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    openAssistantFromMenu()
    XCTAssertTrue(inspector.exists, "Repeating the menu command must keep the AI tab open.")
    element(identifier: "workspace-inspector-tabs").radioButtons["信息"].click()
    XCTAssertTrue(element(identifier: "article-inspector").waitForExistence(timeout: 10))
    openAssistantFromMenu()
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    element(identifier: "workspace-inspector-toggle").click()
    assertIdentifierDisappears("workspace-inspector")
    openAssistantFromMenu()
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    XCTAssertTrue(mainWindow.exists)
    XCTAssertEqual(application.windows.count, initialWindowCount)
  }

  func testAIInspectorKeyboardShortcutOpensAndSelectsInMainWindow() {
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

    openAssistantFromMenu()
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    element(identifier: "workspace-inspector-toggle").click()
    assertIdentifierDisappears("workspace-inspector")

    application.typeKey("a", modifierFlags: [.option, .command])
    guard inspector.waitForExistence(timeout: 10) else {
      XCTFail("Option-Command-A must open the AI Inspector in the current window.")
      return
    }
    XCTAssertTrue(mainWindow.exists)
    XCTAssertEqual(application.windows.count, initialWindowCount)

    application.typeKey("a", modifierFlags: [.option, .command])
    XCTAssertTrue(inspector.exists, "Repeating Option-Command-A must keep the AI tab open.")
    let inspectorWidth = element(identifier: "workspace-inspector").frame.width
    XCTAssertEqual(
      inspectorWidth, 420, accuracy: 1, "The unified inspector must open at its 420pt ideal width.")
    element(identifier: "workspace-inspector-tabs").radioButtons["信息"].click()
    XCTAssertTrue(element(identifier: "article-inspector").waitForExistence(timeout: 10))
    XCTAssertEqual(
      element(identifier: "workspace-inspector").frame.width, inspectorWidth, accuracy: 1)
    application.typeKey("a", modifierFlags: [.option, .command])
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    XCTAssertEqual(
      element(identifier: "workspace-inspector").frame.width, inspectorWidth, accuracy: 1)
    element(identifier: "workspace-inspector-toggle").click()
    assertIdentifierDisappears("workspace-inspector")
    application.typeKey("a", modifierFlags: [.option, .command])
    XCTAssertTrue(inspector.waitForExistence(timeout: 10))
    XCTAssertTrue(mainWindow.exists)
    XCTAssertEqual(application.windows.count, initialWindowCount)
  }

  func testAICollaborationInspectorStaysInMainWindowAndPreservesDraft() throws {
    launchApplication(surface: "writing")

    let initialWindowCount = application.windows.count
    let mainWindow = application.windows.firstMatch
    mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0))
      .withOffset(CGVector(dx: 0, dy: 10)).click()
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
    element(identifier: "workspace-inspector-tabs").radioButtons["AI 助手"].click()
    XCTAssertTrue(mainWindowAIInspector.waitForExistence(timeout: 10))
    element(identifier: "ai-assistant-options").click()
    element(identifier: "ai-assistant-close").click()
    assertIdentifierDisappears("ai-assistant-inspector")
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
      "ai-assistant-context-menu",
      "ai-assistant-conversation-picker",
      "ai-assistant-input",
      "ai-assistant-send-button",
      "ai-assistant-options",
    ] {
      assertUniqueIdentifier(identifier)
    }
    XCTAssertEqual(
      application.windows.count,
      initialWindowCount,
      "Opening AI collaboration must not create another window."
    )

    let contextMenu = element(identifier: "ai-assistant-context-menu")
    let contextValue = try XCTUnwrap(contextMenu.value as? String)
    let draftTitle = try XCTUnwrap(element(identifier: "markdown-article-title").value as? String)
    XCTAssertTrue(contextValue.contains(draftTitle), "The context must identify the current article.")
    contextMenu.click()
    XCTAssertTrue(application.menuItems["当前文章"].waitForExistence(timeout: 3))
    XCTAssertTrue(application.menuItems["通用聊天"].exists)
    application.typeKey(.escape, modifierFlags: [])

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

    let tabs = element(identifier: "workspace-inspector-tabs")
    tabs.radioButtons["信息"].click()
    XCTAssertTrue(element(identifier: "article-inspector").waitForExistence(timeout: 10))
    toolbarButton.click()
    XCTAssertEqual(element(identifier: "ai-assistant-input").value as? String, unsentDraft)
    element(identifier: "ai-assistant-options").click()
    element(identifier: "ai-assistant-close").click()
    assertIdentifierDisappears("ai-assistant-inspector")
    toolbarButton.click()
    XCTAssertEqual(element(identifier: "ai-assistant-input").value as? String, unsentDraft)

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

  func testUnifiedInspectorSwitchesToolbarDestinations() throws {
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
      "The task center must stay directly available at the bottom of the primary rail."
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
    XCTAssertLessThan(taskCenterButton.frame.midX, profileMenu.frame.midX)
    XCTAssertLessThan(previewButton.frame.midX, aiButton.frame.midX)
    XCTAssertLessThan(aiButton.frame.midX, inspectorButton.frame.midX)
    XCTAssertLessThan(inspectorButton.frame.midX, publishButton.frame.midX)
    XCTAssertFalse(
      identifierExists("workspace-open-settings", in: mainWindow),
      "Settings opens from the app menu (⌘,), not a toolbar button."
    )

    showPublishChecks()
    XCTAssertTrue(
      element(identifier: "workspace-publish-inspector").waitForExistence(timeout: 10),
      "The publish menu must open the publish checks."
    )

    aiButton.click()
    assertIdentifierDisappears("workspace-publish-inspector")
    XCTAssertTrue(
      element(identifier: "ai-assistant-inspector").waitForExistence(timeout: 10),
      "The AI toolbar action must replace, rather than sit behind, the publish checks."
    )

    showPublishChecks()
    XCTAssertTrue(
      element(identifier: "workspace-publish-inspector").waitForExistence(timeout: 10),
      "Publish checks must remain available after leaving the AI Inspector."
    )

    inspectorButton.click()
    assertIdentifierDisappears("workspace-inspector")
    showPublishChecks()
    XCTAssertTrue(element(identifier: "workspace-inspector-tabs").waitForExistence(timeout: 10))
    let tabs = element(identifier: "workspace-inspector-tabs")
    tabs.radioButtons["信息"].click()
    XCTAssertTrue(element(identifier: "article-inspector").waitForExistence(timeout: 10))

    showPublishChecks()
    XCTAssertTrue(
      element(identifier: "workspace-publish-inspector").waitForExistence(timeout: 10),
      "Publish checks must remain available after leaving the article Inspector."
    )

    showSettingsWindow()
    XCTAssertTrue(
      element(identifier: "settings-content").waitForExistence(timeout: 10),
      "The app menu Settings action must open the standard Settings window."
    )
    XCTAssertFalse(
      identifierExists("settings-return-to-workbench", in: application),
      "App preferences must not replace the main workspace."
    )
  }

  func testNativeToolbarControlsKeepTheirOwnAccessibilityNames() throws {
    launchApplication(surface: "writing")

    let expectedNames: [(identifier: String, labels: Set<String>)] = [
      ("workspace-sidebar-toggle", ["隐藏侧栏", "显示侧栏"]),
      ("workspace-command-search", ["全局搜索"]),
      ("workspace-preview", ["预览"]),
      ("workspace-task-center-toggle", ["任务", "任务中心"]),
      ("workspace-prepare-publish", ["发布这篇", "更新文章"]),
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
    let applicationPages = [
      (tab: "ai", content: "ai-settings"),
      (tab: "dataManagement", content: "data-management-settings"),
      (tab: "appearance", content: "appearance-settings"),
      (tab: "editor", content: "editor-settings"),
      (tab: "rss", content: "rss-maintenance-settings"),
      (tab: "privacy", content: "privacy-settings"),
    ]
    let sitePages = [
      (tab: "configurationStatus", content: "configuration-status-settings"),
      (tab: "defaultRules", content: "default-rule-settings"),
      (tab: "token", content: "token-settings"),
    ]

    let settingsWindow = currentSettingsWindow()
    let windowCount = application.windows.count
    let allPages = applicationPages + sitePages
    for page in allPages {
      assertUniqueIdentifier("settings-tab-\(page.tab)")
    }
    assertSettingsWindowBaseline()
    visitSettingsPages(allPages, in: settingsWindow)
    XCTAssertEqual(application.windows.count, windowCount)

    let mainWindow = application.windows
      .containing(.any, identifier: "workspace-command-search")
      .firstMatch
    XCTAssertTrue(
      mainWindow.exists, "The main workspace must remain available while Settings is open.")
    XCTAssertFalse(identifierExists("settings-content", in: mainWindow))
    settingsWindow.buttons[XCUIIdentifierCloseWindow].click()
    assertIdentifierDisappears("settings-content")
    XCTAssertTrue(
      mainWindow.exists, "Closing Settings must preserve the original workspace window.")
  }

  private func visitSettingsPages(
    _ pages: [(tab: String, content: String)],
    in settingsWindow: XCUIElement
  ) {
    let contentIdentifiers = pages.map { $0.content }
    for page in pages {
      select(
        "settings-tab-\(page.tab)",
        revealing: page.content
      )
      assertUniqueIdentifier("settings-content")
      assertUniqueIdentifier(page.content)
      XCTAssertEqual(
        identifierExists("settings-profile-bar", in: settingsWindow),
        ["configurationStatus", "defaultRules", "token", "ai"].contains(page.tab),
        "Only pages with current-site settings should expose a site switcher."
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
    // Shared connection editing and the current site's connection choice share one page.
    let settingsWindow = currentSettingsWindow()
    let windowCount = application.windows.count
    select("settings-tab-ai", revealing: "ai-settings")
    assertIdentifierExists("settings-ai-managed-connection-picker", in: settingsWindow)

    let search = element(identifier: "settings-search-field")
    search.click()
    search.typeText("连接选择")
    let siteConnection = element(identifier: "settings-search-result-ai.siteConnection")
    XCTAssertTrue(siteConnection.waitForExistence(timeout: 10))
    siteConnection.click()
    assertIdentifierExists("ai-settings", in: settingsWindow)
    assertIdentifierExists("settings-site-ai-connection-picker", in: settingsWindow)
    XCTAssertEqual(application.windows.count, windowCount)

    search.click()
    application.typeKey("a", modifierFlags: .command)
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

  func testAIConnectionReconfigurationRequiresConfirmationAndKeepsCancelledSettings() throws {
    openSettings()
    select("settings-tab-ai", revealing: "ai-settings")

    let address = element(identifier: "settings-ai-base-url")
    let model = element(identifier: "settings-ai-model")
    XCTAssertTrue(address.waitForExistence(timeout: 10))
    XCTAssertTrue(model.waitForExistence(timeout: 10))
    let originalAddress = try XCTUnwrap(address.value as? String)
    let originalModel = try XCTUnwrap(model.value as? String)

    let preset = element(identifier: "settings-ai-provider-preset")
    preset.click()
    XCTAssertTrue(application.menuItems["DeepSeek"].waitForExistence(timeout: 5))
    application.menuItems["DeepSeek"].click()
    let confirmation = element(identifier: "settings-ai-reconfigure-confirmation")
    XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
    XCTAssertTrue(element(identifier: "settings-ai-reconfigure-sites").exists)
    element(identifier: "settings-ai-reconfigure-cancel").click()
    assertDisappears(confirmation, timeout: 5)
    XCTAssertEqual(address.value as? String, originalAddress)
    XCTAssertEqual(model.value as? String, originalModel)

    preset.click()
    XCTAssertTrue(application.menuItems["DeepSeek"].waitForExistence(timeout: 5))
    application.menuItems["DeepSeek"].click()
    XCTAssertTrue(confirmation.waitForExistence(timeout: 10))
    element(identifier: "settings-ai-reconfigure-confirm").click()
    assertDisappears(confirmation, timeout: 5)
    XCTAssertNotEqual(model.value as? String, originalModel)
    XCTAssertFalse(address.exists, "Official endpoint controls should start collapsed.")

    let advanced = element(identifier: "settings-ai-provider-advanced")
    XCTAssertTrue(advanced.waitForExistence(timeout: 5))
    XCTAssertEqual(String(describing: advanced.value ?? ""), "0")
    // Use the observed window coordinates to avoid XCTest scrolling this
    // already visible Form row's virtualized parent before sending the event.
    let settingsWindow = currentSettingsWindow()
    let disclosureScreenshot = XCTAttachment(screenshot: settingsWindow.screenshot())
    disclosureScreenshot.name = "ai-provider-advanced-before-expansion"
    disclosureScreenshot.lifetime = .keepAlways
    add(disclosureScreenshot)
    settingsWindow.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(
        dx: advanced.frame.midX - settingsWindow.frame.minX,
        dy: advanced.frame.midY - settingsWindow.frame.minY
      )
    ).click()
    XCTAssertEqual(String(describing: advanced.value ?? ""), "1")
    XCTAssertTrue(address.waitForExistence(timeout: 5))
    XCTAssertEqual(address.value as? String, "https://api.deepseek.com")
  }

  func testSavingAIKeyAndContinuingLeavesRemoteConsentPending() throws {
    openSettings()
    select("settings-tab-ai", revealing: "ai-settings")

    let keyInput = element(identifier: "settings-ai-key-input")
    XCTAssertTrue(keyInput.waitForExistence(timeout: 10))
    keyInput.click()
    keyInput.typeText("fixture-api-key-not-real")
    let saveAndContinue = element(identifier: "settings-ai-key-save-continue")
    XCTAssertTrue(saveAndContinue.waitForExistence(timeout: 5))
    XCTAssertTrue(saveAndContinue.isEnabled)
    XCTAssertTrue(saveAndContinue.isHittable)
    let settingsWindow = currentSettingsWindow()
    settingsWindow.coordinate(withNormalizedOffset: .zero).withOffset(
      CGVector(
        dx: saveAndContinue.frame.midX - settingsWindow.frame.minX,
        dy: saveAndContinue.frame.midY - settingsWindow.frame.minY
      )
    ).click()

    XCTAssertTrue(application.staticTexts["已保存 API Key"].waitForExistence(timeout: 10))
    XCTAssertTrue(application.buttons["同意并启用此 AI 服务"].exists)
    XCTAssertFalse(application.buttons["撤销授权"].exists)
    XCTAssertFalse(application.staticTexts["已允许发送"].exists)
    XCTAssertFalse(application.staticTexts["当前服务与模型已通过连接验证。可以开始使用 AI 功能。"].exists)
  }

  func testCodexBrowserFailureRecoversWithDeviceCodeAndCancel() throws {
    launchCodexFixture("browserFailure")
    let login = application.buttons["settings-ai-codex-account-login"]
    waitUntilEnabled(login)
    login.click()
    let failure = application.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "无法打开 ChatGPT 登录页面")
    ).firstMatch
    XCTAssertTrue(failure.waitForExistence(timeout: 10))
    waitUntilEnabled(application.buttons["settings-ai-codex-device-login"])
    application.buttons["settings-ai-codex-device-login"].click()
    XCTAssertTrue(element(identifier: "settings-ai-codex-device-code-value").waitForExistence(timeout: 10))
    XCTAssertTrue(element(identifier: "settings-ai-codex-device-code-value").label.contains("ABCD-EFGH"))
    application.buttons["settings-ai-codex-account-cancel-login"].click()
    assertDisappears(element(identifier: "settings-ai-codex-device-code-value"), timeout: 10)
    waitUntilEnabled(login)
    attachCodexFixtureScreenshot("browser-failure-device-cancel")
  }

  func testCodexDeviceCodeFailureClearsCodeAndCanRetry() throws {
    launchCodexFixture("device")
    let deviceLogin = application.buttons["settings-ai-codex-device-login"]
    waitUntilEnabled(deviceLogin)
    deviceLogin.click()
    XCTAssertTrue(element(identifier: "settings-ai-codex-device-code-value").waitForExistence(timeout: 10))
    application.buttons["fixture-login-fail"].click()
    assertDisappears(element(identifier: "settings-ai-codex-device-code-value"), timeout: 10)
    waitUntilEnabled(deviceLogin)
    deviceLogin.click()
    XCTAssertTrue(element(identifier: "settings-ai-codex-device-code-value").waitForExistence(timeout: 10))
    application.buttons["settings-ai-codex-account-cancel-login"].click()
    assertDisappears(element(identifier: "settings-ai-codex-device-code-value"), timeout: 10)
    attachCodexFixtureScreenshot("device-code-failure-retry")
  }

  func testCodexLoginRequiresScopedConsentBeforeConnectionTest() throws {
    launchCodexFixture("device")
    let deviceLogin = application.buttons["settings-ai-codex-device-login"]
    waitUntilEnabled(deviceLogin)
    deviceLogin.click()
    XCTAssertTrue(element(identifier: "settings-ai-codex-device-code-value").waitForExistence(timeout: 10))
    application.buttons["fixture-login-success"].click()
    let later = application.buttons["稍后"].firstMatch
    XCTAssertTrue(later.waitForExistence(timeout: 10))
    later.click()
    waitForFixtureLabel("fixture-test-count", equals: "0")
    waitUntilEnabled(application.buttons["settings-ai-codex-account-consent"])
    XCTAssertFalse(element(identifier: "settings-ai-codex-device-code-value").exists)
    attachCodexFixtureScreenshot("login-awaiting-consent")
  }

  func testCodexModelRefreshDoesNotCancelConnectionTest() throws {
    launchCodexFixture("ready")
    let test = application.buttons["settings-ai-codex-account-test"]
    waitUntilEnabled(test)
    let count = Int(element(identifier: "fixture-model-read-count").label) ?? 0
    test.click()
    waitForFixtureLabel("fixture-test-state", equals: "等待")
    let refresh = application.buttons["settings-ai-codex-model-refresh"]
    waitUntilEnabled(refresh)
    refresh.click()
    let reads = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", String(count + 1)),
      object: element(identifier: "fixture-model-read-count"))
    XCTAssertEqual(XCTWaiter.wait(for: [reads], timeout: 10), .completed)
    waitForFixtureLabel("fixture-test-state", equals: "等待")
    application.buttons["fixture-test-complete"].click()
    waitForFixtureLabel("fixture-test-state", equals: "通过")
    let result = application.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "ChatGPT 连接正常")
    ).firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    attachCodexFixtureScreenshot("model-refresh-keeps-connection-test")
  }

  func testCodexConnectionSwitchDiscardsLateTestResult() throws {
    launchCodexFixture("ready")
    let test = application.buttons["settings-ai-codex-account-test"]
    waitUntilEnabled(test)
    test.click()
    waitForFixtureLabel("fixture-test-state", equals: "等待")
    application.buttons["fixture-switch-connection"].click()
    waitUntilEnabled(application.buttons["settings-ai-codex-account-test"])
    waitForFixtureLabel("fixture-test-state", equals: "等待")
    application.buttons["fixture-test-complete"].click()
    waitForFixtureLabel("fixture-test-state", equals: "丢弃")
    XCTAssertFalse(application.descendants(matching: .any).matching(
      NSPredicate(format: "label CONTAINS %@", "ChatGPT 连接正常")
    ).firstMatch.exists)
    attachCodexFixtureScreenshot("connection-switch-discards-late-result")
  }

  private func launchCodexFixture(_ mode: String) {
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_CODEX_ACCOUNT_FIXTURE"] = mode
    launchApplication(surface: "writing", screenshotContentSize: CGSize(width: 1200, height: 1100))
    XCTAssertTrue(element(identifier: "settings-ai-codex-account").waitForExistence(timeout: 15))
  }

  private func waitUntilEnabled(_ element: XCUIElement) {
    XCTAssertTrue(element.waitForExistence(timeout: 10))
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: element)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    XCTAssertTrue(element.isHittable)
  }

  private func waitForFixtureLabel(_ identifier: String, equals value: String) {
    let state = element(identifier: identifier)
    XCTAssertTrue(state.waitForExistence(timeout: 10))
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", value), object: state)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
  }

  private func attachCodexFixtureScreenshot(_ name: String) {
    let attachment = XCTAttachment(screenshot: application.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
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
      "settings-tab-appearance",
      revealing: "appearance-settings"
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
      identifierExists("appearance-settings", in: reopenedSettingsWindow),
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
      // Foundation keeps its system temporary directory despite the TMPDIR
      // override below, so the default fixture root would be shared by every
      // run. Keep each test's workbench fixture inside its own data folder.
      let persistenceRootKey = "PERSONAL_SITE_PUBLISHER_SCREENSHOT_PERSISTENCE_ROOT"
      if application.launchEnvironment[persistenceRootKey] == nil {
        application.launchEnvironment[persistenceRootKey] =
          knowledgeLibraryRootURL
          .appendingPathComponent("screenshot-fixture", isDirectory: true)
          .path
      }
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

  private func completeDataRootSetupIfNeeded() {
    let sidebar = element(identifier: "workspace-sidebar")
    let setup = element(identifier: "workbench-data-root-setup")
    let readyOrSetup = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in sidebar.exists || setup.exists }, object: application)
    XCTAssertEqual(XCTWaiter.wait(for: [readyOrSetup], timeout: 20), .completed)
    if setup.exists {
      assertUniqueIdentifier("workbench-data-root-use-recommended")
      element(identifier: "workbench-data-root-use-recommended").click()
    }
    XCTAssertTrue(sidebar.waitForExistence(timeout: 20), application.debugDescription)
  }

  private func waitForSavedDraft() {
    let saved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value CONTAINS %@", "已保存"),
      object: element(identifier: "markdown-editor-save-status"))
    XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 15), .completed)
    XCTAssertFalse(element(identifier: "markdown-editor-save-failure").exists)
  }

  private func launchFirstRunApplication() {
    application.launchEnvironment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_PERSISTENCE_ROOT"] =
      knowledgeLibraryRootURL.appendingPathComponent("workbench", isDirectory: true).path
    launchApplication(surface: "writing")
  }

  private func openFirstRunSetupWizard() {
    application.activate()
    let helpMenu = application.menuBars.menuBarItems["帮助"]
    XCTAssertTrue(helpMenu.waitForExistence(timeout: 10))
    helpMenu.click()
    let wizard = application.menuItems["打开设置向导…"]
    XCTAssertTrue(wizard.waitForExistence(timeout: 5))
    wizard.click()
    XCTAssertTrue(application.buttons["连接已有仓库"].waitForExistence(timeout: 10))
  }

  private func completeFirstRunRepositorySetup(
    at repositoryRoot: URL, replacingExistingRepository: Bool = true
  ) {
    let connect = application.buttons["连接已有仓库"]
    XCTAssertTrue(connect.isHittable)
    connect.click()
    let continueButton = application.buttons["继续"]
    XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
    continueButton.click()

    let chooseRepository = application.buttons[
      replacingExistingRepository ? "更换本地仓库" : "选择本地仓库"]
    XCTAssertTrue(chooseRepository.waitForExistence(timeout: 5))
    chooseRepository.click()
    // The native picker is a nested sheet on current macOS, with its own
    // stable AppKit identifier; the setup wizard is the outer sheet.
    let panel = application.sheets.matching(identifier: "open-panel").firstMatch
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

  private func makeImageBatchRepository() throws -> (article: URL, images: [URL], imageData: Data) {
    let root = knowledgeLibraryRootURL.appendingPathComponent(
      "repository-fixture", isDirectory: true)
    let content = root.appendingPathComponent("content/posts/2026", isDirectory: true)
    let imageDirectory = root.appendingPathComponent("static/images/batch-ui", isDirectory: true)
    for directory in [content, imageDirectory] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    // /usr/bin/git invokes xcrun, which the sandboxed test runner cannot use.
    // Xcode supplies the executable from the selected developer toolchain.
    let gitPath = try XCTUnwrap(
      Bundle(for: Self.self).object(forInfoDictionaryKey: "WorkbenchXCUIGitPath") as? String)
    let git = Process()
    git.executableURL = URL(fileURLWithPath: gitPath)
    git.arguments = ["init", "--quiet", root.path]
    git.environment = ProcessInfo.processInfo.environment.merging([
      "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
    ]) { _, fixtureValue in fixtureValue }
    try git.run()
    git.waitUntilExit()
    XCTAssertEqual(git.terminationStatus, 0)

    let imageData = try XCTUnwrap(
      Data(
        base64Encoded: [
          "iVBORw0KGgoAAAANSUhEUgAAAGAAAAAwCAYAAADuFn/PAAAAAXNSR0IArs4c6QAAAERlWElm",
          "TU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAYK",
          "ADAAQAAAABAAAAMAAAAACRIJCFAAAA6klEQVR4Ae3XwQkCURTF0FHsQ+3MzrQztRIFC3iz",
          "+gTkuH1ChsQLzuFyf302n8zAMSMD/wwIEP8QBBAgNhDjLUCA2ECMtwABYgMx3gIEiA3E",
          "eAsQIDYQ4y1AgNhAjLcAAWIDMd4CBIgNxHgLECA2EOMtQIDYQIy3AAFiAzHeAgSIDcR4",
          "CxAgNhDjLUCA2ECMt4A4wGmP/7yd977iPhi4Pt7DddssYNSz/ijAescjQYBRz/qjAOsd",
          "jwQBRj3rjwKsdzwSBBj1rD/uvgfs/Y9d/4j/TbCAuK8AAsQGYrwFCBAbiPEWIEBsIMZ/",
          "ATxuB6TxZQ2xAAAAAElFTkSuQmCC",
        ].joined()))
    let images = ["selected.png", "untouched.png", "unregistered.png"].map {
      imageDirectory.appendingPathComponent($0)
    }
    for image in images { try imageData.write(to: image) }
    let article = content.appendingPathComponent("image-batch-fixture.md")
    try """
    +++
    title = "Image batch fixture"
    date = 2026-01-01
    draft = true
    +++

    # Image batch fixture

    ![](/images/batch-ui/selected.png)

    ![](/images/batch-ui/untouched.png)

    """.write(to: article, atomically: true, encoding: .utf8)
    return (article, images, imageData)
  }

  private func toggleAIInspectorForUITest(
    _ toolbarButton: XCUIElement,
    shouldBePresented: Bool
  ) {
    application.activate()
    // Exercise the toolbar itself. A system-wide shortcut registered by another
    // application can intercept the key event and cover the tested window.
    if shouldBePresented {
      toolbarButton.click()
    } else {
      element(identifier: "workspace-inspector-toggle").click()
    }

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

  private func writingDraftRow(title: String, in window: XCUIElement) -> XCUIElement {
    let list = window.descendants(matching: .any).matching(identifier: "writing-draft-list")
      .firstMatch
    return list.descendants(matching: .any)
      .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title) ·")).firstMatch
  }

  private func openAssistantFromMenu() {
    application.activate()
    application.menuBars.menuBarItems["AI"].click()
    let openAssistant = application.menuItems["打开 AI 助手"]
    XCTAssertTrue(openAssistant.waitForExistence(timeout: 5))
    XCTAssertTrue(openAssistant.isEnabled, "The active window must expose its AI command.")
    openAssistant.click()
  }

  /// Opens 发布检查 from the publish menu; narrow windows show it as a sheet.
  private func showPublishChecks() {
    let menu = element(identifier: "workspace-publish-menu")
    XCTAssertTrue(menu.waitForExistence(timeout: 10))
    menu.click()
    let item = application.menuItems["查看发布检查"]
    XCTAssertTrue(item.waitForExistence(timeout: 5))
    item.click()
  }

  /// Both publish actions open one sheet: a confirmation, the blocking
  /// checks, or an explanation. Closing it must never publish.
  private func closePublishSheet() {
    let sheet = application.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 20), "A publish action must open its sheet.")
    let close = sheet.buttons.matching(
      NSPredicate(format: "label IN %@", ["取消", "完成", "关闭"])
    ).firstMatch
    XCTAssertTrue(close.waitForExistence(timeout: 5))
    close.click()
    assertDisappears(sheet, "Closing the publish sheet must not start a publish.")
  }

  private func clickVisibleDrawerControl(_ control: XCUIElement) {
    clickScrollableControl(control, in: element(identifier: "publish-drawer-scroll-content"))
  }

  private func clickScrollableControl(
    _ control: XCUIElement, in scrollView: XCUIElement, disclosureLeadingInset: CGFloat = 8
  ) {
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
    // Native DisclosureGroup labels can extend beyond the chevron hit target.
    // Click the chevron while retaining the visible-viewport requirement.
    let point = CGPoint(
      x: control.elementType == .disclosureTriangle
        ? control.frame.minX + min(disclosureLeadingInset, control.frame.width / 2)
        : control.frame.midX,
      y: control.frame.midY)
    let origin = window.coordinate(withNormalizedOffset: .zero)
    let screenOrigin = origin.screenPoint
    origin.withOffset(
      CGVector(dx: point.x - screenOrigin.x, dy: point.y - screenOrigin.y)
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
    let targetFrame = destination.exists ? String(describing: destination.frame) : "not found"
    let diagnostic = XCTAttachment(
      string:
        "Target: \(identifier) frame=\(targetFrame) exists=\(destination.exists)\nWindow: \(window.frame)\nViewport: \(scrollContainer.frame)\n\(application.debugDescription)"
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
    let configuredRuntimeHomes = [
      ProcessInfo.processInfo.environment["PERSONAL_SITE_PUBLISHER_RUNTIME_HOME"],
      Bundle(for: Self.self).object(forInfoDictionaryKey: "PersonalSitePublisherRuntimeHome") as? String,
    ].compactMap { $0 }
    if let runtimeHome = configuredRuntimeHomes.first(where: { !$0.isEmpty && $0.hasPrefix("/") }) {
      return URL(fileURLWithPath: runtimeHome, isDirectory: true)
        .appendingPathComponent("AccessibilityUITestData", isDirectory: true)
    }
    return FileManager.default.temporaryDirectory
  }
}
