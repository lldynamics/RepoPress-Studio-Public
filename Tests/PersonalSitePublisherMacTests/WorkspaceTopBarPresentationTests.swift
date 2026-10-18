import AppKit
import Foundation
import PublishingGitCore
import SwiftUI
import UserNotifications
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
    let control = WorkspacePreparePublishToolbarButton(
      store: store,
      selectedDraftID: general.id,
      action: {}
    )
    XCTAssertEqual(control.draftStatus.severity, .information)
    XCTAssertEqual(control.draftStatus.value, String(localized: "仅本地草稿，未绑定站点"))
    XCTAssertNil(control.draftStatus.count)
    store.selectDraft(general.id)
    XCTAssertEqual(control.draftStatus.severity, .information)
    XCTAssertNil(control.draftStatus.count)
  }

  func testPublishButtonStatusUsesFirstBlockingReasonAndPanelCount() {
    let attention = ArticlePublishAttention(
      readiness: Self.articleReadiness(issues: [
        PreflightIssue(
          severity: .error,
          title: "Missing publication date",
          message: "Add a date before publishing."
        ),
        PreflightIssue(
          severity: .error,
          title: "Missing summary",
          message: "Add a summary before publishing."
        ),
        PreflightIssue(severity: .warning, title: "Short title", message: "Lengthen the title."),
      ]),
      account: ("Connected", .passed)
    )

    let status = WorkspacePreparePublishToolbarButton.status(
      attention: attention, publishConditions: nil, draftTitle: "Blocked draft")

    XCTAssertEqual(status.severity, .error)
    XCTAssertEqual(status.detail, "Missing publication date")
    // The badge counts every listed item, not only the most severe tier:
    // two errors, one warning and the not-yet-generated social card.
    XCTAssertEqual(status.count, 4)
    XCTAssertEqual(status.count, attention.pendingCount)
  }

  func testBadgeShowsNoPartialCountBeforeTheFirstPreflight() {
    // Only social/SEO/account items exist before preflight has ever run;
    // showing them would be a number that later jumps up.
    var readiness = Self.articleReadiness(issues: [])
    readiness.isAwaitingPreflight = true
    let attention = ArticlePublishAttention(readiness: readiness, account: ("None", .blocked))
    XCTAssertEqual(attention.pendingCount, 0)
    let status = WorkspacePreparePublishToolbarButton.status(
      attention: attention, publishConditions: nil, draftTitle: "Draft")
    XCTAssertEqual(status.severity, .pending)
    XCTAssertNil(status.count)
  }

  func testRefreshingChecklistKeepsThePreviousCompleteCount() {
    // A pending refresh marks the preflight section loading but keeps the
    // previous issues, so the badge does not drop while the author types.
    let readiness = PublishDrawerReadinessPresentation.article(
      draftID: UUID(),
      preflightIssues: [
        PreflightIssue(severity: .warning, title: "Short summary", message: "Add a sentence.")
      ],
      imageReport: nil, isImageReportLoading: false,
      seoReport: SEOAuditReport(
        titleCharacterCount: 10, summaryCharacterCount: 10, bodyCharacterCount: 10, h1Count: 1,
        hasPublishableCoverImage: false, markdownPath: "post.md", frontMatterPreview: "",
        findings: []),
      socialSnapshot: nil, isSocialPreviewStale: false, isPreflightLoading: true
    )
    XCTAssertTrue(readiness.isLoading)
    let attention = ArticlePublishAttention(readiness: readiness, account: ("OK", .passed))
    XCTAssertEqual(attention.pendingCount, 2)
    let status = WorkspacePreparePublishToolbarButton.status(
      attention: attention, publishConditions: nil, draftTitle: "Draft")
    XCTAssertEqual(status.count, 2)
  }

  func testPublishBadgeMatchesPanelCountIncludingSocialCardAndAccount() {
    // A missing social card is a 需要处理 item in the panel, so the badge must
    // count it too; this used to make the toolbar show 4 and the panel 5.
    let readiness = Self.articleReadiness(issues: [
      PreflightIssue(severity: .warning, title: "Short summary", message: "Add a sentence.")
    ])
    let connected = ArticlePublishAttention(readiness: readiness, account: ("OK", .passed))
    XCTAssertEqual(connected.pendingCount, 2)
    XCTAssertEqual(
      connected.pendingCount,
      ArticlePublishAttention.pendingCount(readiness: readiness, accountStatus: .passed))
    let warning = WorkspacePreparePublishToolbarButton.status(
      attention: connected, publishConditions: nil, draftTitle: "Draft")
    XCTAssertEqual(warning.severity, .warning)
    XCTAssertEqual(warning.count, 2)

    let blockedAccount = ArticlePublishAttention(
      readiness: readiness, account: ("No credentials", .blocked))
    XCTAssertEqual(blockedAccount.pendingCount, 3)
    let blocked = WorkspacePreparePublishToolbarButton.status(
      attention: blockedAccount, publishConditions: nil, draftTitle: "Draft")
    XCTAssertEqual(blocked.severity, .error)
    XCTAssertEqual(blocked.detail, "No credentials")
    XCTAssertEqual(blocked.count, 3)
  }

  func testPublishBadgeCountsActionableItemsWhileExcludingOptimizationsAndInfo() {
    let readiness = Self.articleReadiness(issues: [
      PreflightIssue(severity: .error, title: "Missing date", message: "Add a date."),
      PreflightIssue(severity: .warning, title: "Short summary", message: "Add a sentence."),
      PreflightIssue(
        severity: .warning, title: "Short body", message: "Add more detail.",
        ruleID: ContentHealthRuleID.shortBody.rawValue
      ),
      PreflightIssue(
        severity: .info, title: "Writing tip", message: "Consider a stronger opening."
      ),
    ])
    let attention = ArticlePublishAttention(readiness: readiness, account: ("OK", .passed))

    XCTAssertEqual(readiness.blockingCount, 1)
    XCTAssertEqual(readiness.warningCount, 2)
    XCTAssertEqual(readiness.optimizationCount, 1)
    XCTAssertEqual(attention.pendingCount, 3)

    let status = WorkspacePreparePublishToolbarButton.status(
      attention: attention, publishConditions: nil, draftTitle: "Draft")
    XCTAssertEqual(status.severity, .error)
    XCTAssertEqual(status.value, String(localized: "1 个阻断项"))
    XCTAssertEqual(status.detail, "Missing date")
    XCTAssertEqual(status.count, attention.pendingCount)
  }

  func testRepositoryConditionsAffectStatusWithoutInflatingArticleBadge() {
    let warning = ArticlePublishAttention(
      readiness: Self.articleReadiness(issues: [
        PreflightIssue(severity: .warning, title: "Short summary", message: "Add a sentence.")
      ]),
      account: ("OK", .passed)
    )
    let blockedConditions = LocalPublishReadiness(
      writeReadiness: .blocked, commitReadiness: .blocked,
      changedFileCount: 1, fileCount: 1,
      writeBlockingIssues: [
        PreflightIssue(severity: .error, title: "Write denied", message: "Cannot write files.")
      ],
      commitBlockingIssues: [
        PreflightIssue(
          severity: .error, title: "Commit denied", message: "Cannot commit changes."
        )
      ],
      warningIssues: []
    )
    let warningStatus = WorkspacePreparePublishToolbarButton.status(
      attention: warning, publishConditions: blockedConditions, draftTitle: "Draft")
    XCTAssertEqual(warning.pendingCount, 2)
    XCTAssertEqual(warningStatus.severity, .error)
    XCTAssertEqual(warningStatus.value, String(localized: "2 个发布条件未满足"))
    XCTAssertEqual(warningStatus.detail, "Write denied")
    XCTAssertEqual(warningStatus.count, warning.pendingCount)

    let readyArticle = ArticlePublishAttention(
      readiness: Self.articleReadiness(
        issues: [], socialSnapshot: Self.completedSocialSnapshot()),
      account: ("OK", .passed)
    )
    let conditionOnlyStatus = WorkspacePreparePublishToolbarButton.status(
      attention: readyArticle, publishConditions: blockedConditions, draftTitle: "Draft")
    XCTAssertEqual(readyArticle.pendingCount, 0)
    XCTAssertEqual(conditionOnlyStatus.severity, .error)
    XCTAssertEqual(conditionOnlyStatus.value, String(localized: "2 个发布条件未满足"))
    XCTAssertEqual(conditionOnlyStatus.detail, "Write denied")
    XCTAssertNil(conditionOnlyStatus.count)
  }

  func testFirstPreflightStaticAndInstanceCountsStayConsistent() {
    var readiness = Self.articleReadiness(issues: [])
    readiness.isAwaitingPreflight = true
    let attention = ArticlePublishAttention(readiness: readiness, account: ("None", .blocked))

    XCTAssertEqual(
      ArticlePublishAttention.pendingCount(readiness: readiness, accountStatus: .blocked), 0)
    XCTAssertEqual(attention.pendingCount, 0)
    let status = WorkspacePreparePublishToolbarButton.status(
      attention: attention, publishConditions: nil, draftTitle: "Draft")
    XCTAssertEqual(status.severity, .pending)
    XCTAssertNil(status.count)
  }

  func testRenderedAttentionSummaryIncludesBlockingAndPendingRows() {
    let summary = NSHostingView(
      rootView: PublishDrawerAttentionSummary(
        blockingCount: 1, pendingCount: 3, optimizationCount: 0, isReady: false
      )
      .padding()
    )
    let compact = NSHostingView(
      rootView: PublishDrawerAttentionSummary(
        blockingCount: 1, pendingCount: 0, optimizationCount: 0, isReady: false
      )
      .padding()
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    let compactWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = summary
    compactWindow.contentView = compact
    window.layoutIfNeeded()
    compactWindow.layoutIfNeeded()
    summary.displayIfNeeded()
    compact.displayIfNeeded()

    XCTAssertGreaterThan(summary.fittingSize.height, compact.fittingSize.height)
    XCTAssertGreaterThan(summary.fittingSize.width, 0)
  }

  func testPublishingNeedsALocalRepositoryRatherThanAnAPIToken() {
    var profile = SiteProfile(name: "Site", repoOwner: "owner", repoName: "site")
    XCTAssertEqual(ArticlePublishAttention.account(profile: profile).status, .blocked)
    profile.localRepositoryRootPath = "/tmp/site"
    XCTAssertEqual(ArticlePublishAttention.account(profile: profile).status, .passed)
    profile.repoName = ""
    XCTAssertEqual(ArticlePublishAttention.account(profile: profile).status, .blocked)
  }

  /// Without a social snapshot the panel always lists 社交预览尚未生成.
  private static func articleReadiness(
    issues: [PreflightIssue], socialSnapshot: SEOSocialPreviewSnapshot? = nil
  ) -> PublishDrawerReadinessPresentation {
    PublishDrawerReadinessPresentation.article(
      draftID: UUID(), preflightIssues: issues, imageReport: nil, isImageReportLoading: false,
      seoReport: SEOAuditReport(
        titleCharacterCount: 10, summaryCharacterCount: 10, bodyCharacterCount: 10, h1Count: 1,
        hasPublishableCoverImage: false, markdownPath: "post.md", frontMatterPreview: "",
        findings: []),
      socialSnapshot: socialSnapshot, isSocialPreviewStale: false
    )
  }

  private static func completedSocialSnapshot() -> SEOSocialPreviewSnapshot {
    SEOSocialPreviewSnapshot(
      draftID: UUID(), signature: "test", markdownPath: "post.md",
      canonicalURLText: "https://example.com/post",
      titleCharacterCount: 10, descriptionCharacterCount: 10, imagePath: nil,
      cards: [], findings: []
    )
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

@MainActor
final class WindowDraftPublishStatusTests: XCTestCase {
  func testBackgroundWindowUsesItsOwnPublishConditionsAcrossSelectionChanges() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = makeStore(in: directory)
    // Publishing pushes the local repository, so a configured one passes the
    // connection check and only each window's own conditions remain.
    store.updateActiveProfile {
      $0.localRepositoryRootPath = directory.path
      $0.repoOwner = "owner"
      $0.repoName = "site"
    }
    let profile = store.activeProfile
    let first = draft(profile: profile, title: "Window A", slug: "window-a")
    let second = draft(profile: profile, title: "Window B", slug: "window-b")
    store.setDrafts([first, second])
    store.setSelectedDraftID(first.id)
    store.preflightRefreshTask?.cancel()
    store.preflightRefreshTask = nil
    installResults(store: store, draft: first, reason: "Window A cannot commit")
    installResults(store: store, draft: second, reason: "Window B cannot commit")
    let firstButton = WorkspacePreparePublishToolbarButton(
      store: store, selectedDraftID: first.id, action: {})
    let secondButton = WorkspacePreparePublishToolbarButton(
      store: store, selectedDraftID: second.id, action: {})

    XCTAssertEqual(firstButton.draftStatus.detail, "Window A cannot commit")
    XCTAssertEqual(secondButton.draftStatus.detail, "Window B cannot commit")
    XCTAssertEqual(secondButton.draftStatus.severity, .error)
    XCTAssertEqual(store.selectedDraftID, first.id)

    store.setSelectedDraftID(second.id)

    XCTAssertEqual(firstButton.draftStatus.detail, "Window A cannot commit")
    XCTAssertEqual(secondButton.draftStatus.detail, "Window B cannot commit")
  }

  func testTypingAndStatusReadsDoNotSynchronouslyRebuildSiteLinkAudit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = makeStore(in: directory)
    let article = draft(profile: store.activeProfile, title: "Typing", slug: "typing")
    store.setDrafts([article])
    store.setSelectedDraftID(article.id)
    store.preflightRefreshTask?.cancel()
    store.preflightRefreshTask = nil
    let checked = await store.runPreflight(for: article.id)
    XCTAssertNotNil(checked)
    let replacementCount = store.siteLinkAuditSnapshotStore.replacementCount
    let button = WorkspacePreparePublishToolbarButton(
      store: store, selectedDraftID: article.id, action: {})

    for index in 1...20 {
      let buffer = store.draftBodyEditorBuffer(for: article.id)
      XCTAssertEqual(
        store.stageDraftBody(
          article.bodyMarkdown + String(repeating: "x", count: index),
          for: article.id, baseRevision: buffer.revision,
          notifyEditorObservers: false
        )?.wasAccepted, true)
      store.draftBodyCommitTasks[article.id]?.cancel()
      store.draftBodyCommitTasks[article.id] = nil

      XCTAssertNil(store.cachedPreflightResult(for: article.id))
      XCTAssertNotEqual(button.draftStatus.severity, .ready)
      let checks = ArticlePublishAttention.readiness(store: store, draft: article)
      XCTAssertTrue(checks.sections.first(where: { $0.id == "preflight" })?.isLoading == true)
      XCTAssertEqual(store.siteLinkAuditSnapshotStore.replacementCount, replacementCount)
    }
  }

  private func makeStore(in directory: URL) -> WorkbenchStore {
    func tokens(_ role: String) -> KeychainTokenStore {
      KeychainTokenStore(
        service: "window-draft-status-\(role)-\(UUID())", accountPrefix: "tests", inMemory: true)
    }
    return WorkbenchStore(
      persistence: WorkbenchPersistence(
        fileURL: directory.appendingPathComponent("workspace.json")),
      safeMode: true, keychainTokenStore: tokens("ai"),
      repositoryTokenStore: tokens("repository"), deploymentTokenStore: tokens("deployment")
    )
  }

  private func draft(profile: SiteProfile, title: String, slug: String) -> ArticleDraft {
    ArticleDraft(
      siteProfileID: profile.id, title: title, slug: slug, tags: ["Swift"], draft: false,
      summary: String(repeating: "A complete summary for publishing. ", count: 5),
      bodyMarkdown: String(
        repeating: "This article has substantial content for publishing. ", count: 30)
    )
  }

  private func installResults(store: WorkbenchStore, draft: ArticleDraft, reason: String) {
    let profile = store.profile(for: draft)
    let context = DraftExecutionContext(
      draftID: draft.id, profileID: profile.id,
      bodyRevision: store.draftBodyEditorBuffer(for: draft.id).revision
    )
    let generation = store.beginDraftPreflightCalculation(for: draft.id)
    let requestKey = store.draftScopedPreflightRequestKey(for: draft.id)!
    let result = DraftPreflightResult(context: context, issues: [])
    XCTAssertTrue(
      store.installDraftPreflightSnapshot(
        store.makeDraftPreflightSnapshot(result: result, requestKey: requestKey),
        generation: generation
      ))
    let package = PublishPackage(
      draftID: draft.id, title: draft.title, markdownPath: profile.markdownPath(for: draft),
      files: [], commitMessage: "Test", reviewBranchName: "test", reviewTitle: "Test",
      reviewChecklist: []
    )
    let blocker = PreflightIssue(severity: .error, title: reason, message: reason)
    let snapshot = DraftPublishPreviewSnapshot(
      context: context,
      publishPackage: package,
      localPublishPreview: LocalPublishPreview(package: package, fileDiffs: [], issues: []),
      localPublishReadiness: LocalPublishReadiness(
        writeReadiness: .ready, commitReadiness: .blocked, changedFileCount: 1, fileCount: 1,
        writeBlockingIssues: [], commitBlockingIssues: [blocker], warningIssues: []
      ),
      remotePublishPreview: RemoteRepositoryPublishPreview(
        provider: .github, repositoryName: "owner/site", mode: .directCommit,
        branchName: "main", targetBranch: "main", changedPaths: [], remoteRiskState: .clean,
        hasToken: true, blockingIssues: [], warningIssues: []
      ),
      remoteReviewDraft: RemoteReviewDraft(
        provider: .github, branchName: "test", targetBranch: "main", title: "Test",
        body: "Test", webURL: nil
      )
    )
    store.publishingStore.rememberDraftPublishPreviewInputBaseline(
      store.publishingStore.makeDraftPublishPreviewInputBaseline(for: draft, store: store),
      for: draft.id
    )
    XCTAssertTrue(store.publishingStore.installDraftPublishPreviewSnapshot(snapshot))
    XCTAssertNotNil(store.cachedPublishPreview(for: draft.id))
  }
}

@MainActor
final class ArticlePublishReminderReconciliationTests: XCTestCase {
  func testUnchangedReminderIsNotRescheduled() throws {
    let date = Date(timeIntervalSinceNow: 3_600).rounded()
    let plan = ArticlePublishReminderPlan(draftID: UUID(), title: "Launch post", date: date)
    func request(title: String, date: Date) -> UNNotificationRequest {
      let content = UNMutableNotificationContent()
      content.body = title
      let components = Calendar.current.dateComponents(
        [.year, .month, .day, .hour, .minute, .second], from: date)
      return UNNotificationRequest(
        identifier: plan.identifier, content: content,
        trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
    XCTAssertTrue(
      ArticlePublishReminderCoordinator.matches(request(title: "Launch post", date: date), plan))
    XCTAssertFalse(
      ArticlePublishReminderCoordinator.matches(request(title: "Renamed", date: date), plan))
    XCTAssertFalse(
      ArticlePublishReminderCoordinator.matches(
        request(title: "Launch post", date: date.addingTimeInterval(600)), plan))
  }
}

extension Date {
  fileprivate func rounded() -> Date {
    Date(timeIntervalSince1970: timeIntervalSince1970.rounded())
  }
}
