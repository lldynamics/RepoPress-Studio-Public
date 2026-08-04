import XCTest
@testable import PublishingWorkbenchCore

final class SEOAuditServiceTests: XCTestCase {
  func testReportPassesCoreSEOFieldsForPublicArticle() {
    let profile = SiteProfile.defaultProfile
    let attachmentID = UUID(uuidString: "07B42021-7E75-4623-84A8-A72F086DF198")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "static/images/2026/cover.jpg",
      altText: "Cover"
    )
    let summary = "这篇文章说明 macOS 发布控制台如何把本地仓库、预检、图片、SEO 和发布说明收进一个清晰的桌面工作流，减少发布前来回切换。"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "macOS RepoPress实践",
      slug: "mac-publishing-console",
      tags: ["Mac", "发布"],
      draft: false,
      summary: summary,
      coverAttachmentID: attachmentID,
      bodyMarkdown: """
      # macOS RepoPress实践

      This article is long enough to exercise the local SEO audit path.
      """,
      attachments: [attachment]
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertEqual(report.warningCount, 0)
    XCTAssertEqual(report.errorCount, 0)
    XCTAssertEqual(report.h1Count, 1)
    XCTAssertTrue(report.hasPublishableCoverImage)
    XCTAssertTrue(report.frontMatterPreview.contains("og_preview_img"))
  }

  func testReportFlagsMissingSummaryCoverTagsAndHeading() {
    var profile = SiteProfile.defaultProfile
    profile.defaultTags = []
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "短题",
      slug: "short-title",
      tags: [],
      draft: false,
      summary: "",
      bodyMarkdown: "Body without a top level heading but enough text to check SEO hints."
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertTrue(report.findings.contains { $0.title == "标题偏短" && $0.severity == .warning })
    XCTAssertTrue(report.findings.contains { $0.title == "摘要为空" && $0.severity == .warning })
    XCTAssertTrue(report.findings.contains { $0.title == "正文缺少 H1" && $0.severity == .warning })
    XCTAssertTrue(report.findings.contains { $0.title == "缺少预览图" && $0.severity == .warning })
    XCTAssertTrue(report.findings.contains { $0.title == "标签为空" && $0.severity == .warning })
  }

  func testPrivateArticleDoesNotRequirePublishableCoverImage() {
    let profile = SiteProfile.defaultProfile
    let attachmentID = UUID(uuidString: "3E4D3DD1-CBC6-4FB2-A9E8-D7D9B3098200")!
    let attachment = DraftAttachment(
      id: attachmentID,
      originalFilename: "private-cover.jpg",
      relativePublishPath: "/images/2026/private-cover.jpg",
      repositoryPath: "static/images/2026/private-cover.jpg",
      altText: "Private cover"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "私密草稿发布前检查记录",
      slug: "private-seo",
      draft: true,
      visibility: .private,
      summary: "这篇私密草稿只用于验证本地发布控制台不会把封面图写进公开 SEO 元数据。",
      coverAttachmentID: attachmentID,
      bodyMarkdown: "# 私密草稿发布前检查记录\n\nPrivate body content for local checks.",
      attachments: [attachment]
    )

    let report = SEOAuditService().report(draft: draft, profile: profile)

    XCTAssertFalse(report.findings.contains { $0.title == "缺少预览图" })
    XCTAssertTrue(report.findings.contains { $0.title == "私密文章不输出预览图" && $0.severity == .info })
    XCTAssertFalse(report.frontMatterPreview.contains("private-cover.jpg"))
  }
}
