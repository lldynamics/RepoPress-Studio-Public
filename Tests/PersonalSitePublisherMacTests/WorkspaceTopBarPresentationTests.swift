import Foundation
import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

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
      isLivePreviewEnabled: true,
      isLivePreviewRunning: true,
      isBrowserPreviewEnabled: true
    )
    XCTAssertEqual(browserReady.defaultAction, .browser)
    XCTAssertEqual(browserReady.accessibilityValue, "在浏览器中预览当前文章")

    let inAppOnly = WorkspaceTopBarPresentation.PreviewAvailability(
      isLivePreviewEnabled: true,
      isLivePreviewRunning: true,
      isBrowserPreviewEnabled: false
    )
    XCTAssertEqual(inAppOnly.defaultAction, .inApp)
    XCTAssertEqual(inAppOnly.accessibilityValue, "正在运行")

    let unavailable = WorkspaceTopBarPresentation.PreviewAvailability(
      isLivePreviewEnabled: false,
      isLivePreviewRunning: false,
      isBrowserPreviewEnabled: false
    )
    XCTAssertEqual(unavailable.defaultAction, .unavailable)
    XCTAssertEqual(unavailable.accessibilityValue, "不可用")
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
