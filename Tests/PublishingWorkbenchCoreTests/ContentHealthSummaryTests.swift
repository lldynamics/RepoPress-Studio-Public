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
