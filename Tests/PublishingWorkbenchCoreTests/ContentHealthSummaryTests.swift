import Foundation
import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class ContentHealthSummaryTests: XCTestCase {
  func testStoreSeparatesSiteIssuesFromDraftHealthSummaries() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))

    XCTAssertTrue(store.sitePreflightIssues.contains { $0.title == CoreL10n.text("未选择本地仓库") })
    XCTAssertEqual(store.contentHealthSummaries.count, store.visibleDrafts.count)
    XCTAssertFalse(
      store.contentHealthSummaries.flatMap(\.issues).contains {
        $0.title == CoreL10n.text("未选择本地仓库")
      }
    )
  }

  func testRepositoryBackupSiteIssuesSkipDeploymentReadinessButKeepRepositorySafety() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.purpose = .repositoryBackup
    profile.localRepositoryRootPath = "/tmp/site-backup"
    store.updateActiveProfile(profile)
    store.setRepositoryReport(repositoryReportWithDeploymentAndGitIssues())

    let issues = store.sitePreflightIssues

    XCTAssertTrue(issues.contains { $0.title == "未发现 .git" && $0.field == "repository" })
    XCTAssertFalse(issues.contains { $0.field == "siteKind" })
    XCTAssertFalse(issues.contains { $0.field == "contentRoot" })
    XCTAssertFalse(issues.contains { $0.field == "assetRoot" })
  }

  func testGeneralDraftSiteIssuesDoNotRequireRepositoryReadiness() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var profile = store.activeProfile
    profile.purpose = .generalDraftBackup
    store.updateActiveProfile(profile)
    store.setRepositoryReport(repositoryReportWithDeploymentAndGitIssues())

    XCTAssertTrue(store.sitePreflightIssues.isEmpty)
  }

  func testContentHealthSummariesCoverEveryVisibleDraft() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let profileID = store.activeProfileID
    let brokenDraft = ArticleDraft(
      siteProfileID: profileID,
      title: "",
      slug: "",
      bodyMarkdown: ""
    )
    store.updateDraft(brokenDraft)

    let summaries = store.contentHealthSummaries

    XCTAssertEqual(Set(summaries.map(\.draftID)), Set(store.visibleDrafts.map(\.id)))
    let brokenSummary = try XCTUnwrap(summaries.first(where: { $0.draftID == brokenDraft.id }))
    XCTAssertGreaterThan(brokenSummary.errorCount, 0)
    XCTAssertTrue(brokenSummary.issues.contains { $0.field == "title" })
    XCTAssertTrue(brokenSummary.issues.contains { $0.field == "slug" })
  }

  func testImageResourceProblemsAreIncludedInArticleChecks() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let attachment = DraftAttachment(
      originalFilename: "hero.jpg",
      relativePublishPath: "/images/hero.jpg",
      repositoryPath: "static/images/hero.jpg",
      altText: "Hero",
      byteSize: 2_000_000
    )
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Image checks",
      slug: "image-checks",
      bodyMarkdown: "![Hero](/images/hero.jpg)",
      attachments: [attachment]
    )
    store.updateDraft(draft)

    let summary = try XCTUnwrap(
      store.contentHealthReport.draftSummaries.first { $0.draftID == draft.id }
    )

    XCTAssertTrue(summary.issues.contains { $0.title == "源文件不可用" })
    XCTAssertTrue(summary.issues.contains { $0.title == "图片体积偏大" })
    XCTAssertFalse(summary.issues.contains { $0.title == "还没有图片" })
  }

  func testContentHealthReportDerivesRiskAndAIFixQueuesFromOneSummarySet() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Needs review",
      slug: "needs-review",
      bodyMarkdown: "正文足够长，包含一个本机路径 /Users/example/site/content/posts/review.md。"
    )
    store.updateDraft(draft)

    let report = store.contentHealthReport
    let summary = try XCTUnwrap(report.draftSummaries.first { $0.draftID == draft.id })

    XCTAssertEqual(report.draftSummaries.count, store.visibleDrafts.count)
    XCTAssertEqual(report.publicRiskSummary, PublicRiskSummary(issues: report.draftSummaries.flatMap(\.issues)))
    XCTAssertEqual(report.publicRiskDraftSummaries.map(\.draftID), report.draftSummaries.filter { !$0.publicRiskIssues.isEmpty }.map(\.draftID))
    XCTAssertTrue(report.aiFixQueueItems.contains { $0.draftID == draft.id })
    XCTAssertFalse(summary.issues.isEmpty)
  }

  func testContentHealthReportAsyncMatchesCurrentProfileSnapshot() async throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Async health",
      slug: "async-health",
      bodyMarkdown: "正文足够长，可以在后台单次扫描中生成内容健康报告并派生所有结果。"
    )
    store.updateDraft(draft)

    let report = try await store.contentHealthReportAsync()

    XCTAssertEqual(Set(report.draftSummaries.map(\.draftID)), Set(store.visibleDrafts.map(\.id)))
    XCTAssertEqual(report.publicRiskSummary, PublicRiskSummary(issues: report.draftSummaries.flatMap(\.issues)))
  }

  func testContentHealthAsyncProjectsInternalExternalAndSlugLinkIssues() async throws {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let target = ArticleDraft(
      siteProfileID: profile.id,
      title: "Renamed target",
      slug: "new-target",
      pendingSlugRedirectPaths: ["/old-target/"]
    )
    let source = ArticleDraft(
      siteProfileID: profile.id,
      title: "Link source",
      slug: "link-source",
      bodyMarkdown: "[old](/old-target/) [missing](/missing/) [gone](https://example.com/gone)"
    )
    let service = ContentHealthReportService(
      linkAuditService: SiteLinkAuditService(
        externalProbe: SiteExternalLinkProbe { url in
          SiteExternalLinkProbeResult(url: url, statusCode: 404, finalURL: url)
        }
      )
    )

    let report = try await service.reportAsync(
      drafts: [source, target],
      profile: profile,
      sitePreflightIssues: [],
      presentations: [:]
    )
    let sourceIssues = try XCTUnwrap(
      report.draftSummaries.first { $0.draftID == source.id }
    ).issues
    let targetIssues = try XCTUnwrap(
      report.draftSummaries.first { $0.draftID == target.id }
    ).issues

    XCTAssertTrue(sourceIssues.contains { $0.category == .brokenInternalLink })
    XCTAssertTrue(sourceIssues.contains { $0.category == .unreachableExternalLink })
    XCTAssertTrue(sourceIssues.contains { $0.category == .slugRedirectCandidate })
    XCTAssertTrue(targetIssues.contains { $0.category == .slugRedirectCandidate })
    let impact = try XCTUnwrap(report.slugChangeImpacts[target.id])
    XCTAssertEqual(impact.affectedDraftCount, 1)
    XCTAssertEqual(impact.referenceCount, 1)
  }

  func testContentHealthReportAsyncPropagatesCancellation() async {
    let profile = SiteProfile.defaultProfile
    let drafts = (0..<256).map { index in
      ArticleDraft(
        siteProfileID: profile.id,
        title: "Draft \(index)",
        slug: "draft-\(index)",
        bodyMarkdown: String(repeating: "Content health cancellation check. ", count: 64)
      )
    }
    let task = Task {
      try await ContentHealthReportService().reportAsync(
        drafts: drafts,
        profile: profile,
        sitePreflightIssues: [],
        presentations: [:]
      )
    }

    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected content health report cancellation to propagate")
    } catch is CancellationError {
      // Expected.
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
  }

  func testCanSuppressRepositoryReadinessForDraftOnlyChecks() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Ready",
      slug: "ready",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough to pass the body length preflight rule."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("未选择本地仓库") })
  }

  func testDraftPreflightSummaryAggregatesPublicRiskIssues() throws {
    let profile = SiteProfile.defaultProfile
    let secret = "sk-12345678901234567890abcd"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Risk",
      slug: "risk",
      bodyMarkdown: """
      This article is intentionally long enough for preflight.
      api_key = "\(secret)"
      Local preview was http://127.0.0.1:4321 from /Users/example/site/content/posts/risk.md.
      """
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )
    let summary = DraftPreflightSummary(
      draftID: draft.id,
      draftTitle: draft.title,
      markdownPath: profile.markdownPath(for: draft),
      issues: issues
    )

    XCTAssertEqual(summary.publicRiskErrorCount, 1)
    XCTAssertEqual(summary.publicRiskWarningCount, 2)
    XCTAssertEqual(summary.publicRiskSummary.statusTitle, CoreL10n.text("公开风险阻塞"))
    XCTAssertFalse(summary.publicRiskIssues.contains { $0.message.contains(secret) })
  }

  func testStoreExposesPublicRiskDraftSummaries() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let secret = "github_pat_123456789012345678901234567890"
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Risky Draft",
      slug: "risky-draft",
      bodyMarkdown: """
      This article is intentionally long enough for the body length preflight rule.
      token = "\(secret)"
      """
    )

    store.updateDraft(draft)

    let riskSummary = store.publicRiskSummary
    let draftSummary = try XCTUnwrap(store.publicRiskDraftSummaries.first { $0.draftID == draft.id })
    XCTAssertEqual(riskSummary.errorCount, 1)
    XCTAssertEqual(draftSummary.publicRiskErrorCount, 1)
    XCTAssertFalse(draftSummary.publicRiskIssues.contains { $0.message.contains(secret) })
  }

  func testAIFixQueuePrioritizesMobileStyleMetadataRepairs() throws {
    let profile = SiteProfile.defaultProfile
    let metadataErrorDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Metadata Error",
      slug: "metadata-error",
      tags: ["AI"],
      summary: "已有摘要",
      bodyMarkdown: "正文足够长，可以让 AI 检查 front matter 和 SEO 相关问题。"
    )
    let missingMetadataDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Missing Metadata",
      slug: "missing-metadata",
      bodyMarkdown: "正文足够长，但是还缺摘要和 tags，适合进入 AI 修复队列。"
    )
    let privateDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Private",
      slug: "private",
      visibility: .private,
      bodyMarkdown: "私密文章不应该进入 AI 修复队列。"
    )
    let emptyBodyDraft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Empty",
      slug: "empty"
    )

    let summaries = [
      DraftPreflightSummary(
        draftID: metadataErrorDraft.id,
        draftTitle: metadataErrorDraft.title,
        markdownPath: profile.markdownPath(for: metadataErrorDraft),
        issues: [
          PreflightIssue(
            severity: .error,
            title: "Slug 为空",
            message: "发布路径需要稳定 slug。",
            field: "slug"
          ),
        ]
      ),
      DraftPreflightSummary(
        draftID: missingMetadataDraft.id,
        draftTitle: missingMetadataDraft.title,
        markdownPath: profile.markdownPath(for: missingMetadataDraft),
        issues: [
          PreflightIssue(
            severity: .warning,
            title: "摘要为空",
            message: "列表页和社交分享会缺少说明。",
            field: "summary"
          ),
        ]
      ),
    ]

    let items = AIPublishingFixQueueService().items(
      drafts: [missingMetadataDraft, privateDraft, metadataErrorDraft, emptyBodyDraft],
      profile: profile,
      summaries: summaries
    )

    XCTAssertEqual(items.map(\.draftID), [metadataErrorDraft.id, missingMetadataDraft.id])
    XCTAssertEqual(items[0].priority, .high)
    XCTAssertEqual(items[0].recommendedAction, .draftFrontMatterPack)
    XCTAssertEqual(items[1].priority, .medium)
    XCTAssertTrue(items[1].needsSummary)
    XCTAssertTrue(items[1].needsTags)
    XCTAssertEqual(items[1].requestSummary, "摘要 / Tags / Front Matter 1 项")
    XCTAssertEqual(items[1].recommendedAction, .draftFrontMatterPack)
  }

  func testStoreExposesAIFixQueueItemsFromCurrentContentHealth() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Needs AI Metadata",
      slug: "needs-ai-metadata",
      bodyMarkdown: "正文足够长，可以让 AI 生成摘要和 tags，并检查发布前元数据。"
    )

    store.updateDraft(draft)

    let item = try XCTUnwrap(store.aiFixQueueItems.first { $0.draftID == draft.id })
    XCTAssertEqual(item.recommendedAction, .draftFrontMatterPack)
    XCTAssertTrue(item.needsSummary)
    XCTAssertTrue(item.needsTags)
    XCTAssertTrue(item.requestSummary.contains("摘要"))
    XCTAssertTrue(item.requestSummary.contains("Tags"))
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PersonalSitePublisherMacContentHealthTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }

  private func repositoryReportWithDeploymentAndGitIssues() -> RepositoryScanReport {
    RepositoryScanReport(
      rootPath: "/tmp/site-backup",
      detectedKind: .hugo,
      expectedKind: .zola,
      hasGitDirectory: false,
      contentRootExists: false,
      assetRootExists: false,
      markdownFileCount: 0,
      imageFileCount: 0,
      changedFiles: [],
      preflightIssues: [
        .init(severity: .warning, title: "站点类型可能不一致", message: "配置为 Zola，扫描到 Hugo。", field: "siteKind"),
        .init(severity: .warning, title: "未发现 .git", message: "当前目录不是 Git 工作树。", field: "repository"),
        .init(severity: .error, title: "内容目录不存在", message: "content", field: "contentRoot"),
        .init(severity: .warning, title: "图片目录不存在", message: "static", field: "assetRoot"),
      ]
    )
  }
}

@MainActor
final class ContentHealthSuppressionTests: XCTestCase {
  func testLegacyProfileAndIssueDecodeWithoutSuppressionFields() throws {
    let encoder = JSONEncoder()
    let profileData = try encoder.encode(SiteProfile.defaultProfile)
    var profileObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: profileData) as? [String: Any])
    profileObject.removeValue(forKey: "contentHealthSuppressions")
    let profile = try JSONDecoder().decode(
      SiteProfile.self, from: JSONSerialization.data(withJSONObject: profileObject)
    )
    XCTAssertNil(profile.contentHealthSuppressions)

    let original = shortBodyIssue()
    var issueObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
    issueObject.removeValue(forKey: "ruleID")
    issueObject.removeValue(forKey: "fingerprintContext")
    let issue = try JSONDecoder().decode(
      PreflightIssue.self, from: JSONSerialization.data(withJSONObject: issueObject)
    )
    XCTAssertNil(issue.ruleID)
    XCTAssertFalse(issue.canSuppressInContentHealth)
  }

  func testSuppressionProfileRoundTripUsesStableRuleAndFingerprint() throws {
    var profile = SiteProfile.defaultProfile
    let draft = shortDraft(profileID: profile.id)
    let occurrence = ContentHealthIssueOccurrence(
      issue: shortBodyIssue(), draft: draft, draftTitle: draft.title)
    let suppression = try XCTUnwrap(occurrence.suppression(profileID: profile.id, mode: .baseline))
    profile.contentHealthSuppressions = [suppression]

    let restored = try JSONDecoder().decode(SiteProfile.self, from: JSONEncoder().encode(profile))
    XCTAssertEqual(restored.contentHealthSuppressions, [suppression])
    XCTAssertEqual(restored.contentHealthSuppressions?.first?.ruleID, "content.body.short")
  }

  func testIssueUUIDAndLocalizedCopyDoNotChangeBaselineFingerprint() {
    let profile = SiteProfile.defaultProfile
    let draft = shortDraft(profileID: profile.id)
    let first = ContentHealthIssueOccurrence(
      issue: shortBodyIssue(), draft: draft, draftTitle: "中文标题")
    var translated = shortBodyIssue()
    translated.id = UUID()
    translated.title = "Short body"
    translated.message = "Please review this body."
    let second = ContentHealthIssueOccurrence(
      issue: translated, draft: draft, draftTitle: "English title")
    XCTAssertEqual(first.fingerprint, second.fingerprint)
    XCTAssertEqual(first.id, second.id)
  }

  func testArticleRuleDoesNotHideOtherArticlesAndSiteRuleDoes() throws {
    var profile = SiteProfile.defaultProfile
    let first = shortDraft(profileID: profile.id, title: "First", slug: "first")
    let second = shortDraft(profileID: profile.id, title: "Second", slug: "second")
    let occurrence = ContentHealthIssueOccurrence(
      issue: shortBodyIssue(), draft: first, draftTitle: first.title)
    profile.contentHealthSuppressions = [
      try XCTUnwrap(occurrence.suppression(profileID: profile.id, mode: .articleRule))
    ]
    let service = ContentHealthReportService()
    var report = service.report(
      drafts: [first, second], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertFalse(
      summary(first, in: report).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
    XCTAssertTrue(
      summary(second, in: report).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })

    profile.contentHealthSuppressions = [
      try XCTUnwrap(occurrence.suppression(profileID: profile.id, mode: .siteRule))
    ]
    report = service.report(
      drafts: [first, second], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertEqual(
      report.suppressedIssues.filter { $0.issue.ruleID == ContentHealthRuleID.shortBody.rawValue }
        .count, 2)
  }

  func testCopiedPolicyCannotHideIssuesInAnotherSite() throws {
    let firstProfile = SiteProfile.defaultProfile
    var otherProfile = SiteProfile(name: "Other", siteKind: .hugo)
    let draft = shortDraft(profileID: otherProfile.id)
    let occurrence = ContentHealthIssueOccurrence(
      issue: shortBodyIssue(), draft: draft, draftTitle: draft.title)
    otherProfile.contentHealthSuppressions = [
      try XCTUnwrap(occurrence.suppression(profileID: firstProfile.id, mode: .siteRule))
    ]
    let report = ContentHealthReportService().report(
      drafts: [draft], profile: otherProfile, sitePreflightIssues: [], presentations: [:]
    )
    XCTAssertTrue(
      summary(draft, in: report).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
    XCTAssertTrue(report.suppressedIssues.isEmpty)
  }

  func testBaselineReopensChangedBodyAndDoesNotHideNewArticle() throws {
    var profile = SiteProfile.defaultProfile
    let first = shortDraft(profileID: profile.id)
    let occurrence = ContentHealthIssueOccurrence(
      issue: shortBodyIssue(), draft: first, draftTitle: first.title)
    profile.contentHealthSuppressions = [
      try XCTUnwrap(occurrence.suppression(profileID: profile.id, mode: .baseline))
    ]
    let service = ContentHealthReportService()
    let initial = service.report(
      drafts: [first], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertFalse(
      summary(first, in: initial).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })

    var changed = first
    changed.bodyMarkdown = "A different short body"
    let newDraft = shortDraft(profileID: profile.id, title: "New", slug: "new")
    let report = service.report(
      drafts: [changed, newDraft], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertTrue(
      summary(changed, in: report).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
    XCTAssertTrue(
      summary(newDraft, in: report).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
    XCTAssertTrue(report.suppressedIssues.isEmpty)
  }

  func testBaselineReopensChangedExternalFailureEvidence() throws {
    var profile = SiteProfile.defaultProfile
    let draft = shortDraft(profileID: profile.id)
    func audit(status: Int) -> SiteLinkAuditReport {
      SiteLinkAuditReport(
        references: [],
        items: [
          SiteLinkAuditItem(
            draftID: draft.id, draftTitle: draft.title, target: "https://example.com/missing",
            anchorText: "Example", severity: .warning, message: "Unavailable", kind: .externalDead,
            statusCode: status)
        ])
    }
    let service = ContentHealthReportService()
    let initial = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:],
      linkAuditReport: audit(status: 404))
    let issue = try XCTUnwrap(
      summary(draft, in: initial).issues.first { $0.category == .unreachableExternalLink })
    let occurrence = ContentHealthIssueOccurrence(
      issue: issue, draft: draft, draftTitle: draft.title)
    profile.contentHealthSuppressions = [
      try XCTUnwrap(occurrence.suppression(profileID: profile.id, mode: .baseline))
    ]
    let same = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:],
      linkAuditReport: audit(status: 404))
    XCTAssertFalse(
      summary(draft, in: same).issues.contains { $0.category == .unreachableExternalLink })
    let changed = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:],
      linkAuditReport: audit(status: 500))
    XCTAssertTrue(
      summary(draft, in: changed).issues.contains { $0.category == .unreachableExternalLink })
  }

  func testOptionalInfoCanBeSuppressedWithoutOptingInUnknownInfo() {
    let profile = SiteProfile.defaultProfile
    let draft = shortDraft(profileID: profile.id)
    let notice = PreflightIssue(
      severity: .info, title: "Optional caption", message: "Add a caption if useful",
      field: "attachments", ruleID: ContentHealthRuleID.missingCaption.rawValue
    )
    XCTAssertTrue(notice.canSuppressInContentHealth)
    let occurrence = ContentHealthIssueOccurrence(
      issue: notice, draft: draft, draftTitle: draft.title)
    XCTAssertNotNil(occurrence.suppression(profileID: profile.id, mode: .articleRule))
    XCTAssertFalse(
      PreflightIssue(severity: .info, title: "Unknown", message: "Unreviewed")
        .canSuppressInContentHealth)
  }

  func testSafetyAndErrorsRejectForgedAllowlistedRuleIDs() {
    var issue = shortBodyIssue()
    issue.severity = .error
    XCTAssertFalse(issue.canSuppressInContentHealth)
    issue.severity = .warning
    issue.category = .publicRisk
    XCTAssertFalse(issue.canSuppressInContentHealth)
    issue.category = .unsafeMediaRepositoryPath
    XCTAssertFalse(issue.canSuppressInContentHealth)
    issue.category = nil
    issue.field = "repository"
    XCTAssertFalse(issue.canSuppressInContentHealth)
    issue.field = "body"
    issue.code = .remoteBaselineChanged
    XCTAssertFalse(issue.canSuppressInContentHealth)
    issue.code = nil
    issue.ruleID = "future.unknown-rule"
    XCTAssertFalse(issue.canSuppressInContentHealth)
  }

  func testBaselineKeepsPublicRisksErrorsAndRawPublishingPreflight() throws {
    var profile = SiteProfile.defaultProfile
    var draft = shortDraft(profileID: profile.id)
    draft.title = ""
    draft.bodyMarkdown = "Local path /Users/example/private/article.md"
    let service = ContentHealthReportService()
    let initial = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    profile.contentHealthSuppressions = summary(draft, in: initial).issues.compactMap {
      ContentHealthIssueOccurrence(issue: $0, draft: draft, draftTitle: draft.title).suppression(
        profileID: profile.id, mode: .baseline)
    }
    let report = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertTrue(summary(draft, in: report).issues.contains { $0.severity == .error })
    XCTAssertTrue(summary(draft, in: report).issues.contains(where: \.isPublicRiskIssue))
    XCTAssertTrue(
      PreflightCheckService().run(draft: draft, allDrafts: [draft], profile: profile).contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
  }

  func testPolicyAdditionAndRestoreInvalidateIncrementalCache() throws {
    var profile = SiteProfile.defaultProfile
    let draft = shortDraft(profileID: profile.id)
    let service = ContentHealthReportService(cache: ContentHealthReportCache())
    _ = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    _ = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertEqual(service.cacheStatistics.hitCount, 1)
    let occurrence = ContentHealthIssueOccurrence(
      issue: shortBodyIssue(), draft: draft, draftTitle: draft.title)
    profile.contentHealthSuppressions = [
      try XCTUnwrap(occurrence.suppression(profileID: profile.id, mode: .articleRule))
    ]
    let ignored = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertEqual(service.cacheStatistics.missCount, 2)
    XCTAssertFalse(ignored.suppressedIssues.isEmpty)
    profile.contentHealthSuppressions = nil
    let restored = service.report(
      drafts: [draft], profile: profile, sitePreflightIssues: [], presentations: [:])
    XCTAssertEqual(service.cacheStatistics.missCount, 3)
    XCTAssertTrue(
      summary(draft, in: restored).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
  }

  func testStorePersistsIgnoresRestoresAndRejectsStaleSnapshot() throws {
    let url = try persistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    let draft = shortDraft(profileID: store.activeProfileID)
    store.updateDraft(draft)
    let version = store.contentHealthSnapshotVersion
    let issue = try XCTUnwrap(
      summary(draft, in: store.contentHealthReport).issues.first {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
    XCTAssertTrue(
      store.suppressContentHealthIssue(
        issue, draftID: draft.id, profileID: store.activeProfileID, mode: .articleRule,
        expectedVersion: version))
    XCTAssertGreaterThan(store.contentHealthSnapshotVersion, version)
    XCTAssertFalse(
      store.suppressContentHealthIssue(
        issue, draftID: draft.id, profileID: store.activeProfileID, mode: .siteRule,
        expectedVersion: version))
    let restoredStore = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertEqual(restoredStore.contentHealthSuppressions, store.contentHealthSuppressions)
    XCTAssertTrue(
      store.restoreContentHealthSuppression(try XCTUnwrap(store.contentHealthSuppressions.first)))
    XCTAssertTrue(store.contentHealthSuppressions.isEmpty)
    XCTAssertTrue(
      summary(draft, in: store.contentHealthReport).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
  }

  func testPublishChecklistRecognizesFindingIgnoredInSiteChecks() async throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try persistenceURL()))
    let draft = shortDraft(profileID: store.activeProfileID)
    store.updateDraft(draft)
    let current = try XCTUnwrap(store.draft(for: draft.id))
    let publishResult = await store.runPreflight(for: draft.id)
    let publishIssues = try XCTUnwrap(publishResult).issues
    let shortBody = try XCTUnwrap(
      publishIssues.first { $0.ruleID == ContentHealthRuleID.shortBody.rawValue })
    XCTAssertFalse(
      store.isSuppressedInContentHealth(shortBody, draft: current), "No rules yet")

    let healthIssue = try XCTUnwrap(
      summary(draft, in: store.contentHealthReport).issues.first {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
    XCTAssertTrue(
      store.suppressContentHealthIssue(
        healthIssue, draftID: draft.id, profileID: store.activeProfileID, mode: .articleRule,
        expectedVersion: store.contentHealthSnapshotVersion))

    // The publish preflight computes its findings separately; the same rule
    // must match them so 站点检查 and the publish badge count alike.
    XCTAssertTrue(store.isSuppressedInContentHealth(shortBody, draft: current))
    for issue in publishIssues where issue.severity == .error {
      XCTAssertFalse(
        store.isSuppressedInContentHealth(issue, draft: current),
        "Errors are never hidden from publishing: \(issue.title)")
    }
  }

  func testSaveCurrentBaselineAndRestoreAllPersistWithoutChangingArticle() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try persistenceURL()))
    let draft = shortDraft(profileID: store.activeProfileID)
    store.updateDraft(draft)
    let before = try XCTUnwrap(store.draft(for: draft.id))
    XCTAssertTrue(
      store.saveContentHealthBaseline(
        profileID: store.activeProfileID, expectedVersion: store.contentHealthSnapshotVersion))
    XCTAssertEqual(store.draft(for: draft.id), before)
    XCTAssertFalse(
      summary(draft, in: store.contentHealthReport).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
    XCTAssertTrue(store.restoreAllContentHealthSuppressions(profileID: store.activeProfileID))
    XCTAssertTrue(
      summary(draft, in: store.contentHealthReport).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
  }

  func testFailedPersistenceDoesNotKeepSuppressionInMemory() throws {
    let directory = try persistenceURL().deletingLastPathComponent()
    let blocker = directory.appendingPathComponent("parent-is-a-file")
    try Data("Not a directory".utf8).write(to: blocker)
    let url = blocker.appendingPathComponent("workbench.json")
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    let draft = shortDraft(profileID: store.activeProfileID)
    store.updateDraft(draft)
    let issue = try XCTUnwrap(
      summary(draft, in: store.contentHealthReport).issues.first {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
    // A file at the parent path prevents any queued or synchronous snapshot write.
    XCTAssertFalse(
      store.suppressContentHealthIssue(
        issue, draftID: draft.id, profileID: store.activeProfileID, mode: .articleRule,
        expectedVersion: store.contentHealthSnapshotVersion
      ))
    XCTAssertTrue(store.contentHealthSuppressions.isEmpty)
    XCTAssertTrue(
      summary(draft, in: store.contentHealthReport).issues.contains {
        $0.ruleID == ContentHealthRuleID.shortBody.rawValue
      })
  }

  private func shortDraft(profileID: UUID, title: String = "Short", slug: String = "short")
    -> ArticleDraft
  {
    ArticleDraft(
      siteProfileID: profileID, title: title, slug: slug, draft: false, bodyMarkdown: "Short body")
  }

  private func shortBodyIssue() -> PreflightIssue {
    PreflightIssue(
      severity: .warning, title: "正文偏短", message: "Optional warning", field: "body",
      ruleID: ContentHealthRuleID.shortBody.rawValue)
  }

  private func summary(_ draft: ArticleDraft, in report: ContentHealthReport)
    -> DraftPreflightSummary
  {
    guard let result = report.draftSummaries.first(where: { $0.draftID == draft.id }) else {
      XCTFail("Expected a health summary for the supplied article")
      return DraftPreflightSummary(
        draftID: draft.id, draftTitle: draft.title, markdownPath: "", issues: [])
    }
    return result
  }

  private func persistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ContentHealthSuppressionTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try FileManager.default.removeItem(at: directory) }
    return directory.appendingPathComponent("workbench.json")
  }
}
