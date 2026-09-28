import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class WorkspaceTopBarPresentationTests: XCTestCase {
  func testDensityUsesTheThreeToolbarWidthBands() {
    XCTAssertEqual(WorkspaceTopBarPresentation.density(for: 1_180), .expanded)
    XCTAssertEqual(WorkspaceTopBarPresentation.density(for: 1_179), .compact)
    XCTAssertEqual(WorkspaceTopBarPresentation.density(for: 960), .compact)
    XCTAssertEqual(WorkspaceTopBarPresentation.density(for: 959), .minimal)
  }

  func testRepositoryScanStatusNeverReportsReadyWithoutGitOrWithBlockers() {
    typealias Status = WorkspaceTopBarPresentation.RepositoryScanStatus
    let changed = RepositoryChangedFile(
      status: " M", path: "content/a.md", kind: .modified, lineDiff: nil
    )
    let blocker = PreflightIssue(severity: .error, title: "blocked", message: "blocked")
    let warning = PreflightIssue(severity: .warning, title: "note", message: "note")

    XCTAssertEqual(
      WorkspaceTopBarPresentation.repositoryScanStatus(
        for: Self.report(hasGit: false, changed: [changed], issues: [blocker])
      ),
      Status.missingGitDirectory
    )
    XCTAssertEqual(
      WorkspaceTopBarPresentation.repositoryScanStatus(
        for: Self.report(remote: [changed], issues: [blocker, warning])
      ),
      Status.blockingIssues(count: 1)
    )
    XCTAssertEqual(
      WorkspaceTopBarPresentation.repositoryScanStatus(
        for: Self.report(changed: [changed], remote: [changed])
      ),
      Status.remoteChanges(count: 1)
    )
    XCTAssertEqual(
      WorkspaceTopBarPresentation.repositoryScanStatus(
        for: Self.report(changed: [changed], issues: [warning])
      ),
      Status.localChanges(count: 1)
    )
    XCTAssertEqual(
      WorkspaceTopBarPresentation.repositoryScanStatus(for: Self.report(issues: [warning])),
      Status.ready
    )
  }

  private static func report(
    hasGit: Bool = true,
    changed: [RepositoryChangedFile] = [],
    remote: [RepositoryChangedFile] = [],
    issues: [PreflightIssue] = []
  ) -> RepositoryScanReport {
    RepositoryScanReport(
      rootPath: "/tmp/site",
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: hasGit,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: changed,
      remoteChangedFiles: remote,
      preflightIssues: issues
    )
  }

  func testSearchWidthsContractAcrossDensities() {
    XCTAssertEqual(WorkspaceTopBarPresentation.searchWidth(for: .expanded), 340)
    XCTAssertEqual(WorkspaceTopBarPresentation.searchWidth(for: .compact), 216)
    XCTAssertEqual(WorkspaceTopBarPresentation.searchWidth(for: .minimal), 32)
  }

  func testPreviewDefaultsToBrowserAndFallsBackToInAppWhenUnavailable() {
    let browserReady = WorkspaceTopBarPresentation.PreviewAvailability(
      isLivePreviewRunning: true,
      isBrowserPreviewEnabled: true
    )
    XCTAssertEqual(browserReady.defaultAction, .browser)
    XCTAssertEqual(browserReady.accessibilityValue, "在浏览器中预览当前文章")

    let inAppOnly = WorkspaceTopBarPresentation.PreviewAvailability(
      isLivePreviewRunning: true,
      isBrowserPreviewEnabled: false
    )
    XCTAssertEqual(inAppOnly.defaultAction, .inApp)
    XCTAssertEqual(inAppOnly.accessibilityValue, "正在运行")

    let readyToStart = WorkspaceTopBarPresentation.PreviewAvailability(
      isLivePreviewRunning: false,
      isBrowserPreviewEnabled: false
    )
    XCTAssertEqual(readyToStart.defaultAction, .inApp)
    XCTAssertEqual(readyToStart.accessibilityValue, "准备就绪")
  }

  func testSidebarVisibilityProvidesShownAndHiddenAccessibilitySemantics() {
    XCTAssertEqual(
      WorkspaceTopBarPresentation.SidebarVisibility.visible.accessibilityValue,
      "侧栏已显示"
    )
    XCTAssertEqual(
      WorkspaceTopBarPresentation.SidebarVisibility.hidden.accessibilityValue,
      "侧栏已隐藏"
    )
  }

  func testRSSUsesReadingPrimaryActionsInsteadOfPublishingActions() {
    XCTAssertEqual(
      WorkspaceToolbarContextPolicy.primaryActionContext(for: .rss),
      .rssReading
    )
    XCTAssertEqual(
      WorkspaceToolbarContextPolicy.primaryActionContext(for: .writing),
      .publishing
    )
    XCTAssertEqual(
      WorkspaceToolbarContextPolicy.primaryActionContext(for: .library),
      .knowledgeLibrary
    )
    XCTAssertEqual(
      WorkspaceToolbarContextPolicy.primaryActionContext(for: .images),
      .images
    )
    XCTAssertEqual(
      WorkspaceToolbarContextPolicy.primaryActionContext(for: .sync),
      .publishing
    )
  }
}

@MainActor
final class LocalSitePreviewPanelRenderingTests: XCTestCase {
  func testGeneralDraftStatusIgnoresSitePublishingBlockersAndWindowSelection() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workspace.json")),
      safeMode: true
    )
    let general = ArticleDraft(
      siteProfileID: store.activeProfileID, scope: .general, title: "General draft"
    )
    let siteDraft = ArticleDraft(siteProfileID: store.activeProfileID, title: "Site draft")
    store.setDrafts([general, siteDraft])
    store.selectDraft(siteDraft.id)
    store.setPreflightIssues([
      PreflightIssue(
        severity: .error, title: "Site required", message: "Publishing requires a site")
    ])
    let control = PublishingStatusToolbarControl(
      store: store,
      selectedDraftID: general.id,
      selectedSection: .writing,
      isCompact: true,
      openPublishFlow: {},
      openRepositoryOverview: {},
      openContentHealthOverview: {},
      openReleaseHistory: {}
    )
    XCTAssertEqual(control.draftStatus.severity, .information)
    XCTAssertEqual(control.draftStatus.value, String(localized: "通用草稿，未绑定站点"))
    XCTAssertNil(control.draftStatus.count)
    store.selectDraft(general.id)
    XCTAssertEqual(control.draftStatus.severity, .information)
    XCTAssertNil(control.draftStatus.count)
  }

  func testPreviewPanelRendersWithoutAnEnvironmentObject() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workspace.json")),
      safeMode: true
    )
    let previewState = WorkbenchLocalSitePreviewFeatureFacade(store: store)
    let hostingView = NSHostingView(
      rootView: LocalSitePreviewPanelView(store: store, state: previewState)
        .frame(width: 800, height: 600)
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    window.contentView = hostingView
    window.layoutIfNeeded()
    hostingView.displayIfNeeded()

    XCTAssertGreaterThan(hostingView.fittingSize.width, 0)
  }
}
