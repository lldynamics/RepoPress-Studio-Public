import XCTest
@testable import PublishingWorkbenchCore

final class PreflightCheckServiceTests: XCTestCase {
  func testReportsMissingRequiredMetadata() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "",
      slug: "",
      bodyMarkdown: ""
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile
    )

    XCTAssertTrue(issues.contains { $0.severity == .error && $0.field == "title" })
    XCTAssertTrue(issues.contains { $0.severity == .error && $0.field == "slug" })
  }

  func testReportsDuplicateRenderedPublishPath() {
    let profile = SiteProfile.defaultProfile
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "First",
      slug: "same-slug",
      bodyMarkdown: "This body is intentionally long enough for the preflight length rule."
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "Second",
      slug: "same-slug",
      bodyMarkdown: "This body is intentionally long enough for the preflight length rule."
    )

    let issues = PreflightCheckService().run(
      draft: first,
      allDrafts: [first, second],
      profile: profile
    )

    XCTAssertTrue(issues.contains { $0.title == CoreL10n.text("发布路径重复") })
  }

  func testDuplicateIndexMatchesPerDraftScanForCaseInsensitiveTitlesAndPaths() {
    let profile = SiteProfile.defaultProfile
    let first = ArticleDraft(
      siteProfileID: profile.id,
      title: "Case Sensitive Title",
      slug: "shared-path",
      bodyMarkdown: "This body is intentionally long enough for indexed preflight comparison."
    )
    let second = ArticleDraft(
      siteProfileID: profile.id,
      title: "case sensitive title",
      slug: "shared-path",
      bodyMarkdown: "This second body is intentionally long enough for indexed preflight comparison."
    )
    let third = ArticleDraft(
      siteProfileID: profile.id,
      title: "Unique Title",
      slug: "unique-path",
      bodyMarkdown: "This third body is intentionally long enough for indexed preflight comparison."
    )
    let drafts = [first, second, third]
    let service = PreflightCheckService()
    let duplicateIndex = PreflightDuplicateIndex(drafts: drafts, profile: profile)

    for draft in drafts {
      let scanned = service.run(
        draft: draft,
        allDrafts: drafts,
        profile: profile,
        includeRepositoryReadiness: false
      )
      let indexed = service.run(
        draft: draft,
        allDrafts: drafts,
        profile: profile,
        includeRepositoryReadiness: false,
        duplicateIndex: duplicateIndex
      )

      XCTAssertEqual(issueSignatures(indexed), issueSignatures(scanned))
    }
  }

  func testDuplicateIndexDoesNotTreatRepeatedSameIDDraftAsAnotherDraft() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Repeated Snapshot",
      slug: "repeated-snapshot",
      bodyMarkdown: "This body is intentionally long enough for repeated snapshot duplicate checks."
    )
    let drafts = [draft, draft]
    let service = PreflightCheckService()
    let issues = service.run(
      draft: draft,
      allDrafts: drafts,
      profile: profile,
      includeRepositoryReadiness: false,
      duplicateIndex: PreflightDuplicateIndex(drafts: drafts, profile: profile)
    )

    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("标题重复") })
    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("发布路径重复") })
  }

  func testReportsMarkdownPathOutsideContentRoot() {
    var profile = SiteProfile.defaultProfile
    profile.contentRoot = "content"
    profile.markdownPathPattern = "notes/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Outside Content Root",
      slug: "outside-content-root",
      bodyMarkdown: "This body is intentionally long enough for the preflight path rule validation."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertTrue(
      issues.contains {
        $0.title == "Markdown 路径不在内容目录"
          && $0.field == "markdownPathPattern"
          && $0.severity == .error
      }
    )
  }

  func testReportsImagePathOutsideAssetRoot() {
    var profile = SiteProfile.defaultProfile
    profile.assetRoot = "static"
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "public/images/2026/cover.jpg",
      altText: "Cover image"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Outside Asset Root",
      slug: "outside-asset-root",
      bodyMarkdown: "This body is intentionally long enough for the preflight image path rule validation.",
      attachments: [attachment]
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertTrue(
      issues.contains {
        $0.title == "图片路径不在图片目录"
          && $0.field == "attachments"
          && $0.severity == .error
      }
    )
  }

  func testReportsUnsafeRepositoryPathRules() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "/content/posts/{slug}.md"
    let attachment = DraftAttachment(
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "/tmp/cover.jpg",
      altText: "Cover image"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Unsafe Paths",
      slug: "unsafe-paths",
      bodyMarkdown: "This body is intentionally long enough for unsafe path rule validation.",
      attachments: [attachment]
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertTrue(issues.contains { $0.title == "Markdown 路径规则不安全" && $0.severity == .error })
    XCTAssertTrue(issues.contains { $0.title == "图片路径不安全" && $0.severity == .error })
  }

  func testVideoAttachmentDoesNotRequireImageMetadata() {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "walkthrough.mp4",
      relativePublishPath: "/videos/2026/walkthrough.mp4",
      repositoryPath: "static/videos/2026/walkthrough.mp4",
      altText: "",
      caption: ""
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Video Attachment",
      slug: "video-attachment",
      bodyMarkdown: "This body is intentionally long enough to isolate video attachment preflight behavior.",
      attachments: [attachment]
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("图片缺少 alt") })
    XCTAssertFalse(issues.contains { $0.field == "attachments" && $0.severity == .error })
  }

  func testReportsPublicRiskWithoutEchoingSecretValue() {
    let profile = SiteProfile.defaultProfile
    let secret = "sk-12345678901234567890abcd"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Risk",
      slug: "risk",
      bodyMarkdown: "This article is long enough. api_key = \"\(secret)\" should never be published in a public post."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    let issue = issues.first {
      $0.title == CoreL10n.text("疑似密钥泄露") && $0.field == "body"
    }
    XCTAssertEqual(issue?.severity, .error)
    XCTAssertFalse(issue?.message.contains(secret) ?? true)
  }

  func testReportsInternalAddressAndLocalPathAsWarnings() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Local Debug",
      slug: "local-debug",
      bodyMarkdown: """
      This article documents a local preview workflow and includes enough text for the length rule.
      Preview was tested at http://192.168.1.12:4321 from /Users/example/site/content/posts/demo.md.
      """
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    XCTAssertTrue(issues.contains {
      $0.title == CoreL10n.text("内网地址疑似泄露") && $0.severity == .warning
    })
    XCTAssertTrue(issues.contains {
      $0.title == CoreL10n.text("本机路径疑似泄露") && $0.severity == .warning
    })
  }

  func testRepositoryBackupPurposeSkipsDeploymentReadinessButKeepsRepositorySafety() {
    var profile = SiteProfile.defaultProfile
    profile.purpose = .repositoryBackup
    profile.localRepositoryRootPath = "/tmp/site-backup"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Repository Backup",
      slug: "repository-backup",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so repository backup readiness filtering is isolated."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      repositoryReport: repositoryReportWithDeploymentAndGitIssues()
    )

    XCTAssertTrue(issues.contains { $0.title == "未发现 .git" && $0.field == "repository" })
    XCTAssertFalse(issues.contains { $0.field == "siteKind" })
    XCTAssertFalse(issues.contains { $0.field == "contentRoot" })
    XCTAssertFalse(issues.contains { $0.field == "assetRoot" })
  }

  func testGeneralDraftPurposeSkipsRepositoryReadiness() {
    var profile = SiteProfile.defaultProfile
    profile.purpose = .generalDraftBackup
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "General Draft",
      slug: "general-draft",
      draft: false,
      bodyMarkdown: "This body is intentionally long enough so general draft checks do not require repository readiness."
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      repositoryReport: repositoryReportWithDeploymentAndGitIssues()
    )

    XCTAssertFalse(issues.contains { $0.title == CoreL10n.text("未选择本地仓库") })
    XCTAssertFalse(issues.contains { $0.field == "repository" })
    XCTAssertFalse(issues.contains { $0.field == "siteKind" })
    XCTAssertFalse(issues.contains { $0.field == "contentRoot" })
    XCTAssertFalse(issues.contains { $0.field == "assetRoot" })
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

  private func issueSignatures(_ issues: [PreflightIssue]) -> [String] {
    issues.map {
      "\($0.severity.rawValue)|\($0.title)|\($0.message)|\($0.field ?? "")"
    }
  }
}
