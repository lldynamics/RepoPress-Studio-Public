import XCTest

@testable import PublishingWorkbenchCore

final class ContentHealthQuickFixTests: XCTestCase {
  func testPinyinSlugNormalizesHanUppercaseAndPunctuation() {
    XCTAssertEqual(SlugService.pinyinSlug(from: "我的 New 文章"), "wo-de-new-wen-zhang")
    XCTAssertEqual(SlugService.pinyinSlug(from: "Hello_WORLD"), "hello-world")
    XCTAssertTrue(SlugService.needsPinyinNormalization("我的-Article"))
    XCTAssertFalse(SlugService.needsPinyinNormalization("existing-article"))
  }

  func testPreflightOffersNormalizedSlugForOtherwiseValidHanSlug() {
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "中文文章",
      slug: "中文文章",
      bodyMarkdown: "这是一段足够长的正文，用于隔离 Slug 标准化检查，不应因为正文过短影响本测试对快捷修复建议的判断。"
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    let issue = issues.first { $0.category == .nonStandardSlug }
    XCTAssertEqual(issue?.field, PreflightIssueField.slug.rawValue)
    XCTAssertEqual(issue?.relatedValue, "zhong-wen-wen-zhang")
  }

  func testMissingAltIssueCarriesStableAttachmentIdentifier() {
    let profile = SiteProfile.defaultProfile
    let attachment = DraftAttachment(
      originalFilename: "cover.png",
      relativePublishPath: "/images/cover.png",
      repositoryPath: "static/images/cover.png",
      altText: "",
      caption: ""
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Image Article",
      slug: "image-article",
      bodyMarkdown:
        "This body is intentionally long enough to isolate the missing image alt issue.",
      attachments: [attachment]
    )

    let issues = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )

    let issue = issues.first { $0.category == .missingMediaAlt }
    XCTAssertEqual(issue?.relatedValue, attachment.id.uuidString)
  }

  func testLinkAuditAcceptsExistingRepositoryResourceSelectedByQuickFix() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("content-health-resource-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let resource = root.appendingPathComponent("assets/guide.pdf")
    try FileManager.default.createDirectory(
      at: resource.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("guide".utf8).write(to: resource)

    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = root.path
    var draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Resource Article",
      slug: "resource-article",
      bodyMarkdown: "[Guide](../../assets/guide.pdf)"
    )
    draft.repositoryPath = "content/posts/resource-article.md"

    let report = SiteLinkAuditService().report(drafts: [draft], profile: profile)

    XCTAssertEqual(report.references.first?.resolution, .validInternal)
    XCTAssertFalse(report.items.contains { $0.kind == .brokenInternal })
  }
}
