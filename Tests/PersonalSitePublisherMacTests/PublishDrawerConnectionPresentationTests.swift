import PublishingWorkbenchCore
import XCTest

@testable import PersonalSitePublisherMac

final class PublishDrawerConnectionPresentationTests: XCTestCase {
  func testGroupingPreservesAllDetailsStrongestSeverityAndDifferentPaths() {
    let issues: [PreflightIssue] = [
      .init(severity: .warning, title: "未选择仓库", message: "选择根目录", field: "repository"),
      .init(severity: .error, title: "未选择仓库", message: "当前操作需要仓库", field: "repository"),
      .init(
        severity: .warning, title: "图片缺失", message: "找不到图片", field: "attachments",
        relatedValue: "a.png"),
      .init(
        severity: .warning, title: "图片缺失", message: "找不到图片", field: "attachments",
        relatedValue: "b.png"),
    ]
    let grouped = PublishReadinessIssueGrouping.coalesced(issues)
    XCTAssertEqual(grouped.count, 3)
    XCTAssertEqual(grouped[0].severity, .error)
    XCTAssertTrue(grouped[0].message.contains("选择根目录"))
    XCTAssertTrue(grouped[0].message.contains("当前操作需要仓库"))
    XCTAssertEqual(grouped[0].id, issues[0].id)
  }

  func testGroupingKeepsDistinctIssueCodesSeparate() {
    let issues: [PreflightIssue] = [
      .init(
        severity: .warning, title: "Remote check", message: "Refresh first",
        field: "repository", code: .remoteStatusUnconfirmed),
      .init(
        severity: .warning, title: "Remote check", message: "Review paths",
        field: "repository", code: .remoteSamePathChanges),
    ]

    XCTAssertEqual(PublishReadinessIssueGrouping.coalesced(issues).count, 2)
  }

  func testInspectorUsesExplicitWindowDraftAndRejectsOtherProfile() {
    let profileID = UUID()
    let draft = ArticleDraft(siteProfileID: profileID, title: "Window article")
    XCTAssertEqual(
      PublishDrawerDraftPresentation.resolve(draftID: draft.id, profileID: profileID, draft: draft)?
        .id,
      draft.id)
    XCTAssertNil(
      PublishDrawerDraftPresentation.resolve(draftID: nil, profileID: profileID, draft: draft))
    XCTAssertNil(
      PublishDrawerDraftPresentation.resolve(draftID: UUID(), profileID: profileID, draft: draft))
    XCTAssertNil(
      PublishDrawerDraftPresentation.resolve(draftID: draft.id, profileID: UUID(), draft: draft))
  }

  func testIssueSelectionSurvivesRegeneratedIDsAndLocatesExactBodyValue() {
    let first = PreflightIssue(
      severity: .warning, title: "链接无法解析", message: "检查目标",
      field: "body", category: .brokenInternalLink, relatedValue: "/posts/missing")
    var refreshed = first
    refreshed.id = UUID()
    let draftID = UUID()
    let firstRow = PublishDrawerReadinessIssue.preflight(first, draftID: draftID, prefix: "body")
    let refreshedRow = PublishDrawerReadinessIssue.preflight(
      refreshed, draftID: draftID, prefix: "body")
    XCTAssertEqual(firstRow.id, refreshedRow.id)
    XCTAssertEqual(firstRow.draftID, draftID)
    XCTAssertEqual(firstRow.target, .body(query: "/posts/missing"))
    XCTAssertTrue(firstRow.supportsAIFix)
    let date = PreflightIssue(severity: .warning, title: "时间在未来", message: "确认时间", field: "date")
    let dateRow = PublishDrawerReadinessIssue.preflight(date, draftID: draftID, prefix: "date")
    XCTAssertEqual(dateRow.actionTitle, "修改时间")
    XCTAssertEqual(dateRow.target, .metadata(field: "date"))
    XCTAssertFalse(dateRow.supportsAIFix)
  }

  func testPendingChecksAreNotReportedAsPassedAndBlockersPrecedeWarningsAcrossGroups() {
    let warning = PreflightIssue(severity: .warning, title: "提醒", message: "确认", field: "date")
    let blocker = PreflightIssue(severity: .error, title: "阻断", message: "修复", field: "title")
    let readiness = PublishDrawerReadinessPresentation(sections: [
      .init(
        id: "warning", title: "提醒组", systemImage: "clock",
        issues: [.preflight(warning, draftID: nil, prefix: "warning")], isLoading: false),
      .init(id: "passed", title: "通过组", systemImage: "photo", issues: [], isLoading: false),
      .init(id: "loading", title: "检查中", systemImage: "clock", issues: [], isLoading: true),
      .init(
        id: "blocker", title: "阻断组", systemImage: "doc",
        issues: [.preflight(blocker, draftID: nil, prefix: "blocker")], isLoading: false),
    ])
    XCTAssertEqual(readiness.issues.map(\.severity), [.error, .warning])
    XCTAssertEqual(readiness.passedSections.map(\.id), ["passed"])
    XCTAssertEqual(readiness.blockingCount, 1)
    XCTAssertEqual(readiness.warningCount, 1)
    XCTAssertTrue(readiness.isLoading)
  }

  func testArticleContentDoesNotTurnDeferredRemoteChecksIntoBlockers() {
    let draftID = UUID()
    let issues: [PreflightIssue] = [
      .init(severity: .error, title: "远端待确认", message: "确认前检查", field: "remoteBaseline"),
      .init(severity: .error, title: "缺少标题", message: "请填写", field: "title"),
    ]
    let seo = SEOAuditReport(
      titleCharacterCount: 10, summaryCharacterCount: 10,
      bodyCharacterCount: 10, h1Count: 1, hasPublishableCoverImage: false,
      markdownPath: "post.md", frontMatterPreview: "", findings: [])
    let readiness = PublishDrawerReadinessPresentation.article(
      draftID: draftID,
      preflightIssues: issues, imageReport: nil, isImageReportLoading: true,
      seoReport: seo, socialSnapshot: nil, isSocialPreviewStale: false)
    XCTAssertEqual(readiness.blockingCount, 1)
    XCTAssertEqual(readiness.issues.first?.title, "缺少标题")
    XCTAssertEqual(readiness.passedSections.map(\.id), ["seo"])
    XCTAssertTrue(readiness.issues.allSatisfy { $0.draftID == draftID })
  }

  func testIgnoredSiteCheckFindingsAreNeitherListedNorCounted() {
    let draftID = UUID()
    let ignored = PreflightIssue(severity: .warning, title: "正文偏短", message: "可选")
    let kept = PreflightIssue(severity: .warning, title: "摘要偏短", message: "可选")
    let seo = SEOAuditReport(
      titleCharacterCount: 10, summaryCharacterCount: 10,
      bodyCharacterCount: 10, h1Count: 1, hasPublishableCoverImage: false,
      markdownPath: "post.md", frontMatterPreview: "", findings: [])
    let readiness = PublishDrawerReadinessPresentation.article(
      draftID: draftID, preflightIssues: [ignored, kept], imageReport: nil,
      isImageReportLoading: false, seoReport: seo, socialSnapshot: nil,
      isSocialPreviewStale: false,
      isPreflightIssueIgnored: { $0.title == ignored.title })
    XCTAssertEqual(readiness.ignoredCount, 1)
    XCTAssertFalse(readiness.issues.contains { $0.title == ignored.title })
    XCTAssertTrue(readiness.issues.contains { $0.title == kept.title })
    // 摘要偏短 plus the not-yet-generated social card.
    XCTAssertEqual(
      ArticlePublishAttention.pendingCount(readiness: readiness, accountStatus: .passed), 2)

    let plan = BatchPublishPlan(
      profileID: UUID(), siteName: "Site",
      items: [])
    let batch = PublishDrawerReadinessPresentation.batch(
      plan: plan, profileID: plan.profileID, isRefreshing: false,
      isIssueIgnored: { _, _ in true })
    XCTAssertEqual(batch.ignoredCount, 0)
  }

  func testBatchReadinessRejectsPlanFromAnotherSite() {
    let stalePlan = BatchPublishPlan(profileID: UUID(), siteName: "Other site", items: [])
    let presentation = PublishDrawerReadinessPresentation.batch(
      plan: stalePlan,
      profileID: UUID(), isRefreshing: false)
    XCTAssertTrue(presentation.isLoading)
    XCTAssertTrue(presentation.passedSections.isEmpty)
    XCTAssertTrue(presentation.issues.isEmpty)
  }

  func testOptionalOnlySiteFindingIsAvailableThroughOptimizationFilter() {
    let issue = PreflightIssue(
      severity: .warning, title: "正文偏短", message: "建议补充内容", field: "body",
      ruleID: ContentHealthRuleID.shortBody.rawValue)
    let snapshot = ContentHealthSnapshot(
      id: UUID(), generatedAt: Date(), profileID: UUID(), profileName: "Site",
      publicRiskDraftSummaries: [], aiFixQueueItems: [], sitePreflightIssues: [issue],
      contentHealthSummaries: [], slugChangeImpacts: [:], errorCount: 0, warningCount: 0,
      optimizationCount: 1, passingDraftCount: 0)
    let presentation = ContentHealthArticlePresentation(
      snapshot: snapshot, filter: .overview, severityFilter: .all)
    XCTAssertTrue(presentation.rows.isEmpty)
    XCTAssertEqual(presentation.siteIssues.count, 1)
    let optimizationPresentation = ContentHealthArticlePresentation(
      snapshot: snapshot, filter: .overview, severityFilter: .optimizations)
    XCTAssertEqual(optimizationPresentation.siteIssues.count, 1)
    XCTAssertEqual(snapshot.optimizationCount, 1)
  }
}

final class ArticlePublicationStatusPresentationTests: XCTestCase {
  private let publishedDigest =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  private let editedDigest =
    "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

  func testDraftAndReadyHaveNoRemoteEvidence() {
    let fixture = makeFixture()
    var draft = fixture.draft
    draft.draft = true

    XCTAssertEqual(
      presentation(draft: draft, profile: fixture.profile, digest: nil).stage,
      .draft
    )
    draft.draft = false
    draft.status = .ready
    let ready = presentation(draft: draft, profile: fixture.profile, digest: nil)
    XCTAssertEqual(ready.stage, .ready)
    XCTAssertNil(ready.verifiedAt)
    XCTAssertNil(ready.onlineURL)
  }

  func testEditingAfterPublishShowsPendingChangesWithoutOnlineEvidence() {
    let fixture = makeFixture()
    let result = presentation(
      draft: fixture.draft,
      profile: fixture.profile,
      digest: editedDigest,
      records: [fixture.record],
      snapshots: [fixture.record.id: fixture.successSnapshot]
    )

    XCTAssertEqual(result.stage, .pendingChanges)
    XCTAssertNil(result.verifiedAt)
    XCTAssertNil(result.onlineURL)
  }

  func testReturningToAnOldEditionCannotReuseItsSupersededOnlineProof() {
    let fixture = makeFixture()
    var latest = fixture.record
    latest.id = UUID()
    latest.createdAt = fixture.now.addingTimeInterval(2)
    latest.commitSHA = "newer-release"
    latest.batchItems[0].sourceDocumentDigest = editedDigest
    let result = presentation(
      draft: fixture.draft, profile: fixture.profile, digest: publishedDigest,
      records: [latest, fixture.record],
      snapshots: [fixture.record.id: fixture.successSnapshot])
    XCTAssertEqual(result.stage, .pendingChanges)
    XCTAssertNil(result.onlineURL)
  }

  func testNewerUntrackedPushDoesNotReuseOlderVerifiedProof() {
    let fixture = makeFixture()
    var latest = fixture.record
    latest.id = UUID()
    latest.createdAt = fixture.now.addingTimeInterval(2)
    latest.articlePublishTrackingRequest = nil
    latest.commitSHA = "newer-release"
    let result = presentation(
      draft: fixture.draft, profile: fixture.profile, digest: publishedDigest,
      records: [fixture.record, latest],
      snapshots: [fixture.record.id: fixture.successSnapshot])
    XCTAssertEqual(result.stage, .needsAttention)
    XCTAssertNil(result.onlineURL)
    XCTAssertNil(result.verifiedAt)
  }

  func testNewerPartialPushAndMergedReviewPreventOlderOnlineProof() {
    let fixture = makeFixture()
    var latest = fixture.record
    latest.id = UUID()
    latest.createdAt = fixture.now.addingTimeInterval(2)
    latest.articlePublishTrackingRequest = nil
    latest.kind = .remotePublishFailure
    latest.commitSHA = "newer-release"
    func result(_ record: ReleaseRecord) -> ArticlePublicationStatusPresentation {
      presentation(
        draft: fixture.draft, profile: fixture.profile, digest: publishedDigest,
        records: [fixture.record, record], snapshots: [fixture.record.id: fixture.successSnapshot])
    }
    XCTAssertEqual(result(latest).stage, .needsAttention)
    latest.commitSHA = nil
    XCTAssertEqual(result(latest).stage, .verifiedOnline, "No remote commit cannot supersede proof")
    latest.commitSHA = "newer-release"
    latest.branchName = "preview"
    XCTAssertEqual(result(latest).stage, .verifiedOnline, "Preview writes do not change production")
    latest.kind = .remoteReviewRequest
    latest.reviewStatus = .init(
      provider: fixture.profile.repositoryProvider, reviewNumber: 1,
      reviewURL: "https://example.com/reviews/1", state: .merged, sourceBranch: "preview",
      targetBranch: fixture.profile.branch, headCommitSHA: latest.commitSHA,
      mergeCommitSHA: "merge-release")
    XCTAssertEqual(result(latest).stage, .needsAttention)
    latest.createdAt = fixture.now.addingTimeInterval(-100)
    latest.reviewStatus?.checkedAt = fixture.now.addingTimeInterval(3)
    XCTAssertEqual(result(latest).stage, .needsAttention, "An old review may have merged later")
    latest.reviewStatus?.state = .open
    XCTAssertEqual(result(latest).stage, .verifiedOnline)
  }

  func testNewerIncompleteArticleTargetCannotBorrowOlderProof() {
    let fixture = makeFixture()
    var latest = fixture.record
    latest.id = UUID()
    latest.createdAt = fixture.now.addingTimeInterval(2)
    latest.draftID = fixture.draft.id
    latest.batchItems = []
    let result = presentation(
      draft: fixture.draft, profile: fixture.profile, digest: publishedDigest,
      records: [fixture.record, latest], snapshots: [fixture.record.id: fixture.successSnapshot])
    XCTAssertNotEqual(result.stage, .verifiedOnline)
    XCTAssertNil(result.onlineURL)
  }

  func testMissingDigestIsSafePendingWhileCurrentEditionResolves() {
    let fixture = makeFixture()
    let result = presentation(
      draft: fixture.draft,
      profile: fixture.profile,
      digest: nil,
      records: [fixture.record],
      snapshots: [fixture.record.id: fixture.successSnapshot]
    )

    XCTAssertEqual(result.stage, .pendingChanges)
  }

  func testDifferentRepositoryAndUnrelatedArticleDoNotAttachLifecycle() {
    let fixture = makeFixture()
    var otherRepository = fixture.profile
    otherRepository.repoName = "another-repository"
    let otherRepositoryRecord = makeRecord(
      draftID: fixture.draft.id,
      profile: otherRepository,
      now: fixture.now
    )
    var otherProfile = fixture.profile
    otherProfile.id = UUID()
    let otherProfileRecord = makeRecord(
      draftID: fixture.draft.id,
      profile: otherProfile,
      now: fixture.now
    )
    let unrelated = makeRecord(
      draftID: UUID(),
      profile: fixture.profile,
      now: fixture.now.addingTimeInterval(1)
    )

    let result = presentation(
      draft: fixture.draft,
      profile: fixture.profile,
      digest: publishedDigest,
      records: [otherRepositoryRecord, otherProfileRecord, unrelated]
    )

    XCTAssertEqual(result.stage, .ready)
  }

  func testChangedArticlePathIsPendingForSameFrozenTarget() {
    var fixture = makeFixture()
    fixture.draft.slug = "new-path"

    let result = presentation(
      draft: fixture.draft,
      profile: fixture.profile,
      digest: publishedDigest,
      records: [fixture.record]
    )

    XCTAssertEqual(result.stage, .pendingChanges)
  }

  func testMissingAndOldSnapshotsRemainWaitingDuringTrackingWindow() {
    let fixture = makeFixture()
    let missing = presentation(
      draft: fixture.draft,
      profile: fixture.profile,
      digest: publishedDigest,
      records: [fixture.record],
      now: fixture.now.addingTimeInterval(2)
    )
    let oldSnapshot = makeSnapshot(
      record: fixture.record,
      profile: fixture.profile,
      checkedAt: fixture.now.addingTimeInterval(-1),
      platform: .success,
      articleLevel: .success,
      digest: publishedDigest
    )
    let old = presentation(
      draft: fixture.draft,
      profile: fixture.profile,
      digest: publishedDigest,
      records: [fixture.record],
      snapshots: [fixture.record.id: oldSnapshot],
      now: fixture.now.addingTimeInterval(2)
    )

    XCTAssertEqual(missing.stage, .waitingForDeployment)
    XCTAssertEqual(old.stage, .waitingForDeployment)
  }

  func testDeploymentVerificationAndAttentionPhasesArePreserved() {
    let fixture = makeFixture()
    let verifyingSnapshot = makeSnapshot(
      record: fixture.record,
      profile: fixture.profile,
      checkedAt: fixture.now.addingTimeInterval(1),
      platform: .success,
      articleLevel: .failed,
      digest: editedDigest
    )
    let failedSnapshot = makeSnapshot(
      record: fixture.record,
      profile: fixture.profile,
      checkedAt: fixture.now.addingTimeInterval(1),
      platform: .failed,
      articleLevel: .unknown,
      digest: nil,
      message: "deployment failed"
    )

    XCTAssertEqual(
      presentation(
        draft: fixture.draft,
        profile: fixture.profile,
        digest: publishedDigest,
        records: [fixture.record],
        snapshots: [fixture.record.id: verifyingSnapshot]
      ).stage,
      .verifyingArticle
    )
    XCTAssertEqual(
      presentation(
        draft: fixture.draft,
        profile: fixture.profile,
        digest: publishedDigest,
        records: [fixture.record],
        snapshots: [fixture.record.id: failedSnapshot]
      ).stage,
      .needsAttention
    )
  }

  func testCompletedSuccessSurvivesDeadlineAndKeepsBoundTimeAndLink() {
    var fixture = makeFixture()
    fixture.record.articlePublishTrackingRequest?.completedSnapshot = fixture.successSnapshot
    let laterSnapshot = makeSnapshot(
      record: fixture.record,
      profile: fixture.profile,
      checkedAt: fixture.now.addingTimeInterval(10),
      platform: .failed,
      articleLevel: .unknown,
      digest: nil,
      message: "later unrelated state"
    )

    let result = presentation(
      draft: fixture.draft,
      profile: fixture.profile,
      digest: publishedDigest,
      records: [fixture.record],
      snapshots: [fixture.record.id: laterSnapshot],
      now: fixture.now.addingTimeInterval(ArticlePublishTrackingRequest.duration + 60)
    )

    XCTAssertEqual(result.stage, .verifiedOnline)
    XCTAssertEqual(
      result.verifiedAt,
      fixture.successSnapshot.articleResults?.first?.checkedAt
    )
    XCTAssertEqual(result.onlineURL?.absoluteString, "https://example.com/article/")
  }

  func testUnverifiedOrMalformedURLIsNeverExposed() {
    var fixture = makeFixture(publicURLText: "file:///tmp/article.html")
    fixture.record.articlePublishTrackingRequest?.completedSnapshot = fixture.successSnapshot

    let result = presentation(
      draft: fixture.draft,
      profile: fixture.profile,
      digest: publishedDigest,
      records: [fixture.record],
      now: fixture.now.addingTimeInterval(ArticlePublishTrackingRequest.duration + 1)
    )

    XCTAssertEqual(result.stage, .verifiedOnline)
    XCTAssertNotNil(result.verifiedAt)
    XCTAssertNil(result.onlineURL)
  }

  private func presentation(
    draft: ArticleDraft,
    profile: SiteProfile,
    digest: String?,
    records: [ReleaseRecord] = [],
    snapshots: [UUID: DeploymentStatusSnapshot] = [:],
    now: Date = Date(timeIntervalSince1970: 10_002)
  ) -> ArticlePublicationStatusPresentation {
    ArticlePublicationStatusPresentation.make(
      draft: draft,
      profile: profile,
      currentSourceDigest: digest,
      records: records,
      snapshots: snapshots,
      now: now
    )
  }

  private func makeFixture(
    publicURLText: String = "https://example.com/article/"
  ) -> (
    draft: ArticleDraft,
    profile: SiteProfile,
    record: ReleaseRecord,
    successSnapshot: DeploymentStatusSnapshot,
    now: Date
  ) {
    let now = Date(timeIntervalSince1970: 10_000)
    var profile = SiteProfile.defaultProfile
    profile.deploymentProvider = .custom
    profile.deploymentSiteURL = "https://example.com/"
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Article",
      slug: "article",
      draft: false,
      status: .ready
    )
    let record = makeRecord(
      draftID: draft.id,
      profile: profile,
      now: now,
      publicURLText: publicURLText
    )
    draft.repositoryPath = record.articleVerificationTargets[0].markdownPath
    let snapshot = makeSnapshot(
      record: record,
      profile: profile,
      checkedAt: now.addingTimeInterval(1),
      platform: .success,
      articleLevel: .success,
      digest: publishedDigest
    )
    return (draft, profile, record, snapshot, now)
  }

  private func makeRecord(
    draftID: UUID,
    profile: SiteProfile,
    now: Date,
    publicURLText: String = "https://example.com/article/"
  ) -> ReleaseRecord {
    let draft = ArticleDraft(
      id: draftID,
      siteProfileID: profile.id,
      title: "Article",
      slug: "article",
      draft: false,
      status: .ready
    )
    let path = profile.markdownPath(for: draft)
    let target = ReleaseRecordBatchItem(
      draftID: draftID,
      draftTitle: draft.title,
      markdownPath: path,
      publicPath: "/article/",
      publicURLText: publicURLText,
      sourceDocumentDigest: publishedDigest,
      changedPaths: [path]
    )
    return ReleaseRecord(
      kind: .remoteDirectCommit,
      title: "Article",
      summary: "Published",
      siteProfileID: profile.id,
      siteName: profile.name,
      repositoryProvider: profile.repositoryProvider,
      repositoryBaseURL: profile.repositoryBaseURL,
      repoOwner: profile.repoOwner,
      repoName: profile.repoName,
      branchName: profile.branch,
      targetBranch: profile.branch,
      commitSHA: "release-sha",
      batchItems: [target],
      articlePublishTrackingRequest: ArticlePublishTrackingRequest(profile: profile, now: now),
      createdAt: now
    )
  }

  private func makeSnapshot(
    record: ReleaseRecord,
    profile: SiteProfile,
    checkedAt: Date,
    platform: DeploymentStatusLevel,
    articleLevel: DeploymentStatusLevel,
    digest: String?,
    message: String = "ok"
  ) -> DeploymentStatusSnapshot {
    let target = record.articleVerificationTargets[0]
    let article = DeploymentArticleVerificationResult(
      target: target,
      checkedAt: checkedAt,
      signals: [
        DeploymentStatusSignal(
          level: articleLevel,
          title: "Article",
          message: message,
          verifiedSourceDocumentDigest: digest
        )
      ]
    )
    return DeploymentStatusSnapshot(
      profileID: profile.id,
      releaseRecordID: record.id,
      provider: .custom,
      level: platform,
      title: "Platform",
      message: message,
      siteURLText: profile.deploymentSiteURL,
      checkedAt: checkedAt,
      signals: [],
      expectedBranch: record.branchName,
      expectedCommitSHA: record.deploymentCommitSHA,
      attributionVerified: true,
      platformLevel: platform,
      articleResults: [article]
    )
  }
}
