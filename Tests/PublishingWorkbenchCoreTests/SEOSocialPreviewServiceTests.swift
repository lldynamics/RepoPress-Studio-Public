import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class SEOSocialPreviewServiceTests: XCTestCase {
  func testSnapshotBuildsSearchOpenGraphAndTwitterCards() {
    var profile = SiteProfile.defaultProfile
    profile.name = "Jinfang Notes"
    profile.markdownPathPattern = "content/posts/{slug}.md"

    let coverID = UUID(uuidString: "7FD5F66F-A748-4FA2-8B58-E37BB8BA07AA")!
    let cover = DraftAttachment(
      id: coverID,
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/2026/cover.jpg",
      repositoryPath: "static/images/2026/cover.jpg",
      altText: "Mac publishing workflow"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "macOS 个人网站发布控制台实践",
      date: Date(timeIntervalSince1970: 1_783_396_800),
      slug: "mac-publishing-console",
      tags: ["Mac 发布", "#SEO", "SEO"],
      categories: ["个人网站"],
      authors: ["Jinfang", "Jinfang"],
      draft: false,
      summary: "这篇文章说明 macOS 发布控制台如何把本地仓库、预检、图片、SEO 和发布说明收进一个清晰的桌面工作流，减少发布前来回切换。",
      coverAttachmentID: coverID,
      bodyMarkdown: "# macOS 个人网站发布控制台实践\n\nBody",
      attachments: [cover],
      updatedAt: Date(timeIntervalSince1970: 1_783_400_400)
    )

    let snapshot = SEOSocialPreviewService().snapshot(
      draft: draft,
      profile: profile,
      localPreviewURL: URL(string: "http://127.0.0.1:1111")
    )

    XCTAssertEqual(snapshot.markdownPath, "content/posts/mac-publishing-console.md")
    XCTAssertEqual(snapshot.renderingMode, .staticMetadataSnapshot)
    XCTAssertEqual(snapshot.canonicalURLText, "http://127.0.0.1:1111/mac-publishing-console")
    XCTAssertEqual(snapshot.imagePath, "/images/2026/cover.jpg")
    XCTAssertEqual(snapshot.socialImageURLText, "http://127.0.0.1:1111/images/2026/cover.jpg")
    XCTAssertEqual(snapshot.cards.map(\.kind), [.search, .openGraph, .twitter])
    XCTAssertNil(snapshot.cards.first { $0.kind == .search }?.imagePath)
    XCTAssertEqual(snapshot.imageAltText, "Mac publishing workflow")
    let openGraphCard = snapshot.cards.first { $0.kind == .openGraph }
    XCTAssertEqual(openGraphCard?.imageAltText, "Mac publishing workflow")
    XCTAssertEqual(openGraphCard?.titleCharacterLimit, 60)
    XCTAssertEqual(openGraphCard?.descriptionCharacterLimit, 200)
    XCTAssertEqual(openGraphCard?.imageAspectRatio, "1.91:1")
    XCTAssertTrue(openGraphCard?.imageGuidance.contains("1200x630") == true)
    XCTAssertTrue(openGraphCard?.isTitleWithinBudget == true)
    XCTAssertTrue(openGraphCard?.isDescriptionWithinBudget == true)
    XCTAssertEqual(snapshot.cards.first { $0.kind == .twitter }?.titleCharacterLimit, 70)
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:title" }?.content, "macOS 个人网站发布控制台实践")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:image" }?.content, "http://127.0.0.1:1111/images/2026/cover.jpg")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:image:width" }?.content, "1200")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:image:height" }?.content, "630")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:image:alt" }?.content, "Mac publishing workflow")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "article:published_time" }?.content, "2026-07-07T04:00:00Z")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "article:modified_time" }?.content, "2026-07-07T05:00:00Z")
    XCTAssertEqual(snapshot.metaTags.filter { $0.property == "article:author" }.map(\.content), ["Jinfang"])
    XCTAssertEqual(snapshot.metaTags.filter { $0.property == "article:section" }.map(\.content), ["个人网站"])
    XCTAssertEqual(snapshot.metaTags.filter { $0.property == "article:tag" }.map(\.content), ["Mac 发布", "SEO"])
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "twitter:card" }?.content, "summary_large_image")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "description" }?.scope, .search)
    XCTAssertEqual(snapshot.shareHashtags, ["Mac发布", "SEO", "个人网站"])
    XCTAssertEqual(snapshot.socialShareCopyItems.map(\.kind), [.search, .openGraph, .twitter])
    let twitterCopy = snapshot.socialShareCopyItems.first { $0.kind == .twitter }
    XCTAssertEqual(twitterCopy?.imageURLText, "http://127.0.0.1:1111/images/2026/cover.jpg")
    XCTAssertEqual(twitterCopy?.hashtagText, "#Mac发布 #SEO #个人网站")
    XCTAssertTrue(twitterCopy?.clipboardText.contains("http://127.0.0.1:1111/mac-publishing-console") == true)
    XCTAssertTrue(twitterCopy?.clipboardText.contains("#Mac发布 #SEO #个人网站") == true)
    XCTAssertTrue(snapshot.findings.contains { $0.title == "社交预览字段完整" })
    XCTAssertEqual(snapshot.platformReadiness.map(\.status), [.ready, .ready, .ready])
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Open Graph: 可发布"))
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Twitter/X: 可发布"))
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Rendering: 静态元数据快照"))
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("## Structured Data"))
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("JSON-LD: 可发布"))
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Image alt: Mac publishing workflow"))
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Image URL: http://127.0.0.1:1111/images/2026/cover.jpg"))
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Hashtags: #Mac发布 #SEO #个人网站"))
    let package = snapshot.publishPackageMarkdown()
    XCTAssertTrue(package.contains("# SEO / Social 发布包"))
    XCTAssertTrue(package.contains("- 预览类型：静态元数据快照"))
    XCTAssertTrue(package.contains("## 平台就绪度"))
    XCTAssertTrue(package.contains("## 结构化数据"))
    XCTAssertTrue(package.contains("## 分享文案"))
    XCTAssertTrue(package.contains("## 卡片预览"))
    XCTAssertTrue(package.contains("Hashtags：#Mac发布 #SEO #个人网站"))
    XCTAssertTrue(package.contains("- 图片 URL：http://127.0.0.1:1111/images/2026/cover.jpg"))
    XCTAssertTrue(package.contains("## Meta HTML"))
    XCTAssertTrue(package.contains("- 图片 Alt：Mac publishing workflow"))
    XCTAssertTrue(package.contains(#"<meta property="og:title" content="macOS 个人网站发布控制台实践">"#))
    XCTAssertTrue(package.contains(#"<meta property="article:published_time" content="2026-07-07T04:00:00Z">"#))
    XCTAssertTrue(package.contains(#"<meta property="article:modified_time" content="2026-07-07T05:00:00Z">"#))
    XCTAssertTrue(package.contains(#"<meta property="article:author" content="Jinfang">"#))
    XCTAssertTrue(package.contains(#"<meta property="article:section" content="个人网站">"#))
    XCTAssertTrue(package.contains(#"<meta property="article:tag" content="Mac 发布">"#))
    XCTAssertTrue(package.contains(#"<meta property="og:image:width" content="1200">"#))
    XCTAssertTrue(package.contains(#"<meta property="og:image:height" content="630">"#))
    XCTAssertEqual(snapshot.structuredData.status, .ready)
    XCTAssertTrue(snapshot.structuredData.jsonLD.contains(#""@type" : "Article""#))
    XCTAssertTrue(snapshot.structuredData.jsonLD.contains(#""headline" : "macOS 个人网站发布控制台实践""#))
    XCTAssertTrue(snapshot.structuredData.jsonLD.contains(#""image" : ["#))
    XCTAssertTrue(snapshot.structuredData.jsonLD.contains("http://127.0.0.1:1111/images/2026/cover.jpg"))
    XCTAssertTrue(snapshot.findings.contains { $0.title == "JSON-LD 已生成" })
  }

  func testSitemapPreviewGeneratesXmlForPublicDraftsOnly() throws {
    var profile = SiteProfile.defaultProfile
    profile.name = "Jinfang Notes"
    profile.deploymentSiteURL = "https://example.com/blog/"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let selectedID = UUID(uuidString: "E27E0D48-0581-45C9-BA0A-3B4D48806C85")!
    let privateID = UUID(uuidString: "91D93445-7F83-4A45-BFF8-F01B19EC79F0")!
    let draftID = UUID(uuidString: "EEA13B35-A65F-45CB-A5E6-E53320717806")!
    let selected = ArticleDraft(
      id: selectedID,
      siteProfileID: profile.id,
      title: "公开 sitemap 文章",
      date: Date(timeIntervalSince1970: 1_783_396_800),
      slug: "public-sitemap-entry",
      draft: false,
      summary: "这篇文章验证 sitemap.xml 会生成公开文章条目。",
      bodyMarkdown: "# 公开 sitemap 文章",
      updatedAt: Date(timeIntervalSince1970: 1_783_400_400)
    )
    let privateDraft = ArticleDraft(
      id: privateID,
      siteProfileID: profile.id,
      title: "私密 sitemap 文章",
      slug: "private-sitemap-entry",
      draft: false,
      visibility: .private,
      summary: "不应进入 sitemap。",
      bodyMarkdown: "# 私密 sitemap 文章"
    )
    let unpublishedDraft = ArticleDraft(
      id: draftID,
      siteProfileID: profile.id,
      title: "草稿 sitemap 文章",
      slug: "draft-sitemap-entry",
      draft: true,
      summary: "草稿不应进入 sitemap。",
      bodyMarkdown: "# 草稿 sitemap 文章"
    )

    let sitemap = SEOSocialPreviewService().sitemapPreview(
      drafts: [privateDraft, unpublishedDraft, selected],
      selectedDraft: selected,
      profile: profile
    )

    XCTAssertEqual(sitemap.status, .ready)
    XCTAssertEqual(sitemap.sitemapURLText, "https://example.com/blog/sitemap.xml")
    XCTAssertEqual(sitemap.entries.count, 1)
    XCTAssertEqual(sitemap.entries.first?.loc, "https://example.com/blog/public-sitemap-entry")
    XCTAssertEqual(sitemap.entries.first?.lastmod, "2026-07-07")
    XCTAssertTrue(sitemap.entries.first?.isSelectedDraft == true)
    XCTAssertTrue(sitemap.xml.contains("<urlset"))
    XCTAssertTrue(sitemap.xml.contains("<loc>https://example.com/blog/public-sitemap-entry</loc>"))
    XCTAssertFalse(sitemap.xml.contains("private-sitemap-entry"))
    XCTAssertFalse(sitemap.xml.contains("draft-sitemap-entry"))

    let privateSitemap = SEOSocialPreviewService().sitemapPreview(
      drafts: [privateDraft, selected],
      selectedDraft: privateDraft,
      profile: profile
    )
    XCTAssertEqual(privateSitemap.status, .warning)
    XCTAssertTrue(privateSitemap.message.contains("私密文章或草稿"))
  }

  func testSitemapPreviewRequiresAbsoluteSiteURL() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "相对 sitemap",
      slug: "relative-sitemap",
      draft: false,
      summary: "这篇文章验证没有部署 URL 时 sitemap 会提示缺少站点地址。",
      bodyMarkdown: "# 相对 sitemap"
    )

    let sitemap = SEOSocialPreviewService().sitemapPreview(
      drafts: [draft],
      selectedDraft: draft,
      profile: profile
    )

    XCTAssertEqual(sitemap.status, .missing)
    XCTAssertNil(sitemap.sitemapURLText)
    XCTAssertTrue(sitemap.message.contains("部署站点 URL"))
    XCTAssertTrue(sitemap.xml.contains("<loc>/relative-sitemap/</loc>"))
  }

  func testPlatformReadinessWarnsWhenSocialImageAltTextIsMissing() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let coverID = UUID(uuidString: "7B2E403E-0D4C-4E79-94BB-7DD1B0F43C19")!
    let cover = DraftAttachment(
      id: coverID,
      originalFilename: "cover.jpg",
      relativePublishPath: "/images/cover.jpg",
      repositoryPath: "static/images/cover.jpg",
      altText: ""
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "社交图 Alt 检查",
      slug: "social-alt-check",
      draft: false,
      summary: "这篇文章验证 Open Graph 和 Twitter/X 社交卡片会提示缺少图片 Alt 文本。",
      coverAttachmentID: coverID,
      bodyMarkdown: "Body",
      attachments: [cover]
    )

    let snapshot = SEOSocialPreviewService().snapshot(draft: draft, profile: profile)
    let openGraph = snapshot.platformReadiness.first { $0.kind == .openGraph }
    let twitter = snapshot.platformReadiness.first { $0.kind == .twitter }
    let package = snapshot.publishPackageMarkdown()

    XCTAssertEqual(snapshot.imagePath, "/images/cover.jpg")
    XCTAssertNil(snapshot.imageAltText)
    XCTAssertEqual(openGraph?.status, .warning)
    XCTAssertEqual(twitter?.status, .warning)
    XCTAssertTrue(openGraph?.warningMessages.contains { $0.contains("缺少 Alt 文本") } == true)
    XCTAssertTrue(twitter?.warningMessages.contains { $0.contains("twitter:image:alt") } == true)
    XCTAssertTrue(snapshot.findings.contains { $0.title == "社交预览图缺少 Alt" })
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Image alt: missing"))
    XCTAssertTrue(package.contains("- 图片 Alt：missing"))
    XCTAssertNil(snapshot.metaTags.first { $0.property == "og:image:alt" })
    XCTAssertNil(snapshot.metaTags.first { $0.property == "twitter:image:alt" })
  }

  func testSnapshotProvidesExternalSocialDebugLinks() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "社交调试链接",
      slug: "social-debug-links",
      draft: false,
      summary: "这篇文章验证 SEO 社交预览可以生成平台外部调试链接。",
      bodyMarkdown: "# 社交调试链接"
    )

    let snapshot = SEOSocialPreviewService().snapshot(
      draft: draft,
      profile: profile,
      localPreviewURL: URL(string: "https://example.com/blog/")
    )

    XCTAssertEqual(
      snapshot.externalDebugLinks.map(\.platform),
      [.facebookSharingDebugger, .linkedinPostInspector, .xShareIntent, .xCardValidator]
    )
    XCTAssertEqual(
      snapshot.externalDebugLinks.first { $0.platform == .facebookSharingDebugger }?.urlText,
      "https://developers.facebook.com/tools/debug/?q=https://example.com/blog/social-debug-links"
    )
    XCTAssertEqual(
      snapshot.externalDebugLinks.first { $0.platform == .linkedinPostInspector }?.urlText,
      "https://www.linkedin.com/post-inspector/inspect/https%3A%2F%2Fexample.com%2Fblog%2Fsocial-debug-links"
    )
    let xShareLink = snapshot.externalDebugLinks.first { $0.platform == .xShareIntent }?.urlText
    XCTAssertTrue(xShareLink?.contains("https://twitter.com/intent/tweet?") == true)
    XCTAssertTrue(xShareLink?.contains("url=https://example.com/blog/social-debug-links") == true)
    XCTAssertTrue(xShareLink?.contains("text=%E7%A4%BE%E4%BA%A4%E8%B0%83%E8%AF%95%E9%93%BE%E6%8E%A5") == true)
    XCTAssertEqual(
      snapshot.externalDebugLinks.first { $0.platform == .xCardValidator }?.urlText,
      "https://cards-dev.twitter.com/validator"
    )

    let package = snapshot.publishPackageMarkdown()
    let checklist = snapshot.socialShareChecklistMarkdown
    XCTAssertTrue(checklist.contains("## External Debug Links"))
    XCTAssertTrue(checklist.contains("- [ ] Facebook Sharing Debugger"))
    XCTAssertTrue(checklist.contains("Purpose: 刷新 Open Graph 抓取缓存并检查分享卡片字段。"))
    XCTAssertTrue(checklist.contains("https://www.linkedin.com/post-inspector/inspect/https%3A%2F%2Fexample.com%2Fblog%2Fsocial-debug-links"))
    XCTAssertTrue(package.contains("## 外部调试链接"))
    XCTAssertTrue(package.contains("Facebook Sharing Debugger"))
    XCTAssertTrue(package.contains("LinkedIn Post Inspector"))
    XCTAssertTrue(package.contains("X Card Validator"))
  }

  func testSnapshotUsesJekyllDatedPermalinkForCanonicalAndMetaURLs() {
    var profile = SiteProfile.defaultProfile
    profile.name = "Jekyll Notes"
    profile.applyPublishingDefaults(for: .jekyll)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Jekyll 社交预览",
      date: Date(timeIntervalSince1970: 1_783_396_800),
      slug: "jekyll-social-preview",
      draft: false,
      summary: "这篇文章验证 Jekyll 日期文章在 SEO 社交预览中使用公开 permalink。",
      bodyMarkdown: "# Jekyll 社交预览"
    )

    let snapshot = SEOSocialPreviewService().snapshot(
      draft: draft,
      profile: profile,
      localPreviewURL: URL(string: "https://example.com/blog/")
    )

    XCTAssertEqual(snapshot.markdownPath, "_posts/2026-07-07-jekyll-social-preview.md")
    XCTAssertEqual(snapshot.canonicalURLText, "https://example.com/blog/2026/07/07/jekyll-social-preview")
    XCTAssertEqual(snapshot.cards.first { $0.kind == .openGraph }?.urlText, "https://example.com/blog/2026/07/07/jekyll-social-preview")
    XCTAssertEqual(snapshot.cards.first { $0.kind == .twitter }?.urlText, "https://example.com/blog/2026/07/07/jekyll-social-preview")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:url" }?.content, "https://example.com/blog/2026/07/07/jekyll-social-preview")
  }

  func testSnapshotUsesDeploymentSiteURLForProductionSocialMetaWhenPreviewURLIsMissing() {
    var profile = SiteProfile.defaultProfile
    profile.name = "Production Notes"
    profile.deploymentSiteURL = "https://example.com/blog/"
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let coverID = UUID(uuidString: "1A4C7F92-2D91-42C7-80C2-BA705E7C9C44")!
    let cover = DraftAttachment(
      id: coverID,
      originalFilename: "production.jpg",
      relativePublishPath: "/images/production.jpg",
      repositoryPath: "static/images/production.jpg",
      altText: "Production social card"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "生产社交预览",
      slug: "production-social-preview",
      draft: false,
      summary: "这篇文章验证没有本地预览 URL 时使用线上部署地址生成社交分享元数据。",
      coverAttachmentID: coverID,
      bodyMarkdown: "# 生产社交预览",
      attachments: [cover]
    )

    let snapshot = SEOSocialPreviewService().snapshot(draft: draft, profile: profile)

    XCTAssertEqual(snapshot.canonicalURLText, "https://example.com/blog/production-social-preview")
    XCTAssertEqual(snapshot.socialImageURLText, "https://example.com/images/production.jpg")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:url" }?.content, "https://example.com/blog/production-social-preview")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:image" }?.content, "https://example.com/images/production.jpg")
    XCTAssertEqual(snapshot.cards.first { $0.kind == .openGraph }?.urlText, "https://example.com/blog/production-social-preview")
    XCTAssertTrue(snapshot.externalDebugLinks.first { $0.platform == .facebookSharingDebugger }?.urlText.contains("https://example.com/blog/production-social-preview") == true)

    let localSnapshot = SEOSocialPreviewService().snapshot(
      draft: draft,
      profile: profile,
      localPreviewURL: URL(string: "http://127.0.0.1:1111")
    )

    XCTAssertEqual(localSnapshot.canonicalURLText, "http://127.0.0.1:1111/production-social-preview")
    XCTAssertEqual(localSnapshot.metaTags.first { $0.property == "og:url" }?.content, "http://127.0.0.1:1111/production-social-preview")
  }

  func testSnapshotKeepsHugoSectionPathForCanonicalURL() {
    var profile = SiteProfile.defaultProfile
    profile.name = "Hugo Notes"
    profile.applyPublishingDefaults(for: .hugo)
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Hugo 社交预览",
      slug: "hugo-social-preview",
      draft: false,
      summary: "这篇文章验证 Hugo section 路径会保留在 SEO 社交预览公开 URL 中。",
      bodyMarkdown: "# Hugo 社交预览"
    )

    let snapshot = SEOSocialPreviewService().snapshot(
      draft: draft,
      profile: profile,
      localPreviewURL: URL(string: "https://example.com")
    )

    XCTAssertEqual(snapshot.markdownPath, "content/posts/hugo-social-preview.md")
    XCTAssertEqual(snapshot.canonicalURLText, "https://example.com/posts/hugo-social-preview")
    XCTAssertEqual(snapshot.cards.first { $0.kind == .search }?.urlText, "example.com/posts/hugo-social-preview")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:url" }?.content, "https://example.com/posts/hugo-social-preview")
  }

  func testPrivateSnapshotHidesSocialImage() {
    let profile = SiteProfile.defaultProfile
    let coverID = UUID(uuidString: "D1854705-168B-4027-A8F6-C741A1E0B87C")!
    let cover = DraftAttachment(
      id: coverID,
      originalFilename: "private.jpg",
      relativePublishPath: "/images/private.jpg",
      repositoryPath: "static/images/private.jpg",
      altText: "Private"
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "私密内容草稿",
      slug: "private-note",
      visibility: .private,
      summary: "这篇文章用于检查私密内容在社交预览里不会暴露封面图片。",
      coverAttachmentID: coverID,
      bodyMarkdown: "# 私密内容草稿",
      attachments: [cover]
    )

    let snapshot = SEOSocialPreviewService().snapshot(draft: draft, profile: profile)

    XCTAssertNil(snapshot.imagePath)
    XCTAssertTrue(snapshot.cards.allSatisfy { $0.imagePath == nil })
    XCTAssertNil(snapshot.metaTags.first { $0.property == "og:image" })
    XCTAssertNil(snapshot.metaTags.first { $0.property == "og:image:width" })
    XCTAssertNil(snapshot.metaTags.first { $0.property == "og:image:height" })
    XCTAssertNil(snapshot.metaTags.first { $0.property == "twitter:image" })
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "twitter:card" }?.content, "summary")
    XCTAssertFalse(snapshot.findings.contains { $0.title == "缺少社交预览图" })
  }

  func testMetaTagsBuildCopyableEscapedHTMLBlock() {
    let tags = [
      SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:title", content: #"A "quoted" <title> & more"#),
      SEOSocialPreviewMetaTag(scope: .twitter, property: "twitter:description", content: "Twitter summary"),
      SEOSocialPreviewMetaTag(scope: .search, property: "description", content: "Search summary"),
    ]

    XCTAssertEqual(
      tags[0].htmlElement,
      #"<meta property="og:title" content="A &quot;quoted&quot; &lt;title&gt; &amp; more">"#
    )
    XCTAssertEqual(
      tags[1].htmlElement,
      #"<meta name="twitter:description" content="Twitter summary">"#
    )
    XCTAssertEqual(
      tags[2].htmlElement,
      #"<meta name="description" content="Search summary">"#
    )
    XCTAssertEqual(tags.htmlBlock.components(separatedBy: "\n").count, 3)
  }

  func testSocialPreviewCardDecodesLegacySnapshotWithoutPlatformBudgets() throws {
    let card = SEOSocialPreviewCard(
      kind: .twitter,
      title: "Legacy Twitter Card",
      description: "Legacy card decoded from an older cached SEO social preview snapshot.",
      urlText: "/legacy/",
      imagePath: "/images/legacy.jpg",
      imageAltText: "Legacy",
      siteName: "Legacy Site"
    )
    let encoded = try JSONEncoder.workbench.encode(card)
    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    payload.removeValue(forKey: "titleCharacterLimit")
    payload.removeValue(forKey: "descriptionCharacterLimit")
    payload.removeValue(forKey: "imageAspectRatio")
    payload.removeValue(forKey: "imageGuidance")
    let legacyData = try JSONSerialization.data(withJSONObject: payload)

    let decoded = try JSONDecoder.workbench.decode(SEOSocialPreviewCard.self, from: legacyData)

    XCTAssertEqual(decoded.kind, .twitter)
    XCTAssertEqual(decoded.titleCharacterLimit, 70)
    XCTAssertEqual(decoded.descriptionCharacterLimit, 200)
    XCTAssertEqual(decoded.imageAspectRatio, "1.91:1")
    XCTAssertTrue(decoded.imageGuidance.contains("summary_large_image"))
  }

  func testSocialPreviewSnapshotDecodesLegacyCacheWithoutShareHashtags() throws {
    let snapshot = SEOSocialPreviewSnapshot(
      draftID: UUID(),
      signature: "legacy",
      markdownPath: "content/posts/legacy.md",
      canonicalURLText: "/legacy/",
      titleCharacterCount: 6,
      descriptionCharacterCount: 36,
      imagePath: nil,
      cards: [
        SEOSocialPreviewCard(
          kind: .twitter,
          title: "Legacy",
          description: "Legacy cached snapshot without share tags.",
          urlText: "/legacy/",
          imagePath: nil,
          imageAltText: nil,
          siteName: "Legacy Site"
        ),
      ],
      findings: []
    )
    let encoded = try JSONEncoder.workbench.encode(snapshot)
    var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    payload.removeValue(forKey: "shareHashtags")
    payload.removeValue(forKey: "socialImageURLText")
    payload.removeValue(forKey: "renderingMode")
    payload.removeValue(forKey: "structuredData")
    let legacyData = try JSONSerialization.data(withJSONObject: payload)

    let decoded = try JSONDecoder.workbench.decode(SEOSocialPreviewSnapshot.self, from: legacyData)

    XCTAssertEqual(decoded.shareHashtags, [])
    XCTAssertNil(decoded.socialImageURLText)
    XCTAssertEqual(decoded.renderingMode, .staticMetadataSnapshot)
    XCTAssertEqual(decoded.structuredData.status, .warning)
    XCTAssertEqual(decoded.socialShareCopyItems.first?.clipboardText, "Legacy\n\nLegacy cached snapshot without share tags.\n\n/legacy/")
  }

  func testPlatformReadinessWarnsForMissingSocialImageAndOverBudgetFields() {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: String(repeating: "长", count: 72),
      slug: "long-social-card",
      draft: false,
      summary: String(repeating: "这是一段会超过社交平台建议长度的摘要。", count: 12),
      bodyMarkdown: "Body"
    )

    let snapshot = SEOSocialPreviewService().snapshot(draft: draft, profile: profile)
    let openGraph = snapshot.platformReadiness.first { $0.kind == .openGraph }
    let twitter = snapshot.platformReadiness.first { $0.kind == .twitter }
    let search = snapshot.platformReadiness.first { $0.kind == .search }

    XCTAssertEqual(search?.status, .warning)
    XCTAssertEqual(openGraph?.status, .warning)
    XCTAssertEqual(twitter?.status, .warning)
    XCTAssertTrue(openGraph?.warningMessages.contains { $0.contains("缺少大图") } == true)
    XCTAssertTrue(twitter?.warningMessages.contains { $0.contains("标题 72/70") } == true)
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Warning: Open Graph 缺少大图"))
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("社交标题可能截断"))
  }

  func testPlatformReadinessWarnsForSmallOrWrongRatioSocialImage() throws {
    let imageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("seo-square-\(UUID().uuidString).jpg")
    try writeTestImage(at: imageURL, width: 800, height: 800)
    defer {
      try? FileManager.default.removeItem(at: imageURL)
    }

    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    let coverID = UUID(uuidString: "1FA3211D-8B58-4698-B90E-2453E8B7FE74")!
    let cover = DraftAttachment(
      id: coverID,
      originalFilename: "square.jpg",
      relativePublishPath: "/images/square.jpg",
      repositoryPath: "static/images/square.jpg",
      altText: "Square cover",
      sourceFilePath: imageURL.path
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "社交图片尺寸检查",
      slug: "social-image-size",
      draft: false,
      summary: "这篇文章用于验证 Mac 版 SEO 社交预览会检查封面图的实际尺寸和比例。",
      coverAttachmentID: coverID,
      bodyMarkdown: "Body",
      attachments: [cover]
    )

    let snapshot = SEOSocialPreviewService().snapshot(draft: draft, profile: profile)
    let openGraph = snapshot.platformReadiness.first { $0.kind == .openGraph }
    let twitter = snapshot.platformReadiness.first { $0.kind == .twitter }
    let openGraphCard = snapshot.cards.first { $0.kind == .openGraph }
    let package = snapshot.publishPackageMarkdown()

    XCTAssertEqual(snapshot.imageDimensions, ImageDimensions(width: 800, height: 800))
    XCTAssertEqual(openGraphCard?.imageDimensions, ImageDimensions(width: 800, height: 800))
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:image:width" }?.content, "800")
    XCTAssertEqual(snapshot.metaTags.first { $0.property == "og:image:height" }?.content, "800")
    XCTAssertEqual(openGraph?.status, .warning)
    XCTAssertEqual(twitter?.status, .warning)
    XCTAssertTrue(openGraph?.warningMessages.contains { $0.contains("图片尺寸 800x800") } == true)
    XCTAssertTrue(openGraph?.warningMessages.contains { $0.contains("图片比例 1.00:1") } == true)
    XCTAssertTrue(snapshot.findings.contains { $0.title == "社交预览图尺寸偏小" })
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Image size: 800x800"))
    XCTAssertTrue(package.contains("- 图片尺寸：800x800"))
    XCTAssertTrue(package.contains(#"<meta property="og:image:width" content="800">"#))
    XCTAssertTrue(package.contains(#"<meta property="og:image:height" content="800">"#))
  }

  func testPlatformReadinessReportsMissingRequiredMetaTags() {
    let snapshot = SEOSocialPreviewSnapshot(
      draftID: UUID(),
      signature: "manual",
      markdownPath: "content/posts/manual.md",
      canonicalURLText: "/manual/",
      titleCharacterCount: 6,
      descriptionCharacterCount: 12,
      imagePath: nil,
      cards: [
        SEOSocialPreviewCard(
          kind: .openGraph,
          title: "Manual",
          description: "Manual card",
          urlText: "/manual/",
          imagePath: nil,
          imageAltText: nil,
          siteName: "Manual Site"
        ),
      ],
      metaTags: [
        SEOSocialPreviewMetaTag(scope: .openGraph, property: "og:title", content: "Manual"),
      ],
      findings: []
    )

    let search = snapshot.platformReadiness.first { $0.kind == .search }
    let openGraph = snapshot.platformReadiness.first { $0.kind == .openGraph }

    XCTAssertEqual(search?.status, .missing)
    XCTAssertEqual(search?.missingRequiredProperties, ["previewCard"])
    XCTAssertEqual(openGraph?.status, .missing)
    XCTAssertTrue(openGraph?.missingRequiredProperties.contains("og:type") == true)
    XCTAssertTrue(openGraph?.missingRequiredProperties.contains("og:url") == true)
    XCTAssertTrue(snapshot.socialShareChecklistMarkdown.contains("Missing: og:type"))
  }

  func testStoreKeepsCachedSnapshotUntilManualRefresh() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    var draft = try XCTUnwrap(store.selectedDraft)

    let missingPresentation = store.seoSocialPreviewCachePresentation(for: draft)
    XCTAssertEqual(missingPresentation.state, .missing)
    XCTAssertTrue(missingPresentation.needsManualRefresh)
    XCTAssertEqual(missingPresentation.manualRefreshTitle, "生成快照")

    store.prepareSEOSocialPreview(for: draft)
    let originalTitle = try XCTUnwrap(store.seoSocialPreviewSnapshot?.cards.first?.title)
    let freshPresentation = store.seoSocialPreviewCachePresentation(for: draft)
    XCTAssertEqual(freshPresentation.state, .fresh)
    XCTAssertFalse(freshPresentation.needsManualRefresh)
    XCTAssertTrue(freshPresentation.message.contains("缓存快照"))

    draft.title = "更新后的社交标题"
    store.updateDraft(draft)

    XCTAssertEqual(store.seoSocialPreviewSnapshot?.cards.first?.title, originalTitle)
    XCTAssertTrue(store.isSEOSocialPreviewStale(for: draft))
    let stalePresentation = store.seoSocialPreviewCachePresentation(for: draft)
    XCTAssertEqual(stalePresentation.state, .stale)
    XCTAssertTrue(stalePresentation.needsManualRefresh)
    XCTAssertEqual(stalePresentation.manualRefreshTitle, "刷新过期快照")
    XCTAssertTrue(stalePresentation.message.contains("上次缓存快照"))

    store.refreshSEOSocialPreview(for: draft)

    XCTAssertEqual(store.seoSocialPreviewSnapshot?.cards.first?.title, "更新后的社交标题")
    XCTAssertFalse(store.isSEOSocialPreviewStale(for: draft))
    XCTAssertEqual(store.seoSocialPreviewCachePresentation(for: draft).state, .fresh)
  }

  func testStoreMarksSocialPreviewStaleWhenCoverSourceFileChanges() throws {
    let imageURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("seo-cache-cover-\(UUID().uuidString).jpg")
    try writeTestImage(at: imageURL, width: 1200, height: 630)
    defer {
      try? FileManager.default.removeItem(at: imageURL)
    }

    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let coverID = UUID(uuidString: "D2CFBE2D-E2DD-4B07-A8C8-E72F59B15B8A")!
    var draft = try XCTUnwrap(store.selectedDraft)
    draft.title = "封面缓存检测"
    draft.slug = "cover-cache-check"
    draft.summary = "这篇文章用于验证封面源文件变化会让 SEO 社交预览缓存过期。"
    draft.coverAttachmentID = coverID
    draft.attachments = [
      DraftAttachment(
        id: coverID,
        originalFilename: "cover.jpg",
        relativePublishPath: "/images/cover.jpg",
        repositoryPath: "static/images/cover.jpg",
        altText: "Cover",
        byteSize: 128,
        sourceFilePath: imageURL.path
      )
    ]
    store.updateDraft(draft)

    store.prepareSEOSocialPreview(for: draft)
    XCTAssertFalse(store.isSEOSocialPreviewStale(for: draft))

    let changedDate = Date(timeIntervalSince1970: 2_000_000_000)
    try FileManager.default.setAttributes([.modificationDate: changedDate], ofItemAtPath: imageURL.path)

    XCTAssertTrue(store.isSEOSocialPreviewStale(for: draft))
    XCTAssertEqual(store.seoSocialPreviewCachePresentation(for: draft).state, .stale)
  }

	  func testApplyingAIMetadataRefreshesSEOSocialPreviewSnapshot() throws {
	    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
	    let draft = try XCTUnwrap(store.selectedDraft)
	    store.prepareSEOSocialPreview(for: draft)
	    let originalTitle = try XCTUnwrap(store.seoSocialPreviewSnapshot(for: draft)?.cards.first?.title)

	    let updated = try XCTUnwrap(
	      store.applyAIMetadataSuggestion(
	        AIPublishingMetadataSuggestion(
	          titles: ["AI 刷新的社交标题"],
	          summary: "AI 生成的社交摘要，用来验证应用元数据后会刷新 SEO 社交预览。",
	          tags: ["SEO", "AI"]
	        ),
	        draft: draft
	      )
	    )

	    XCTAssertEqual(store.seoSocialPreviewSnapshot(for: updated)?.cards.first?.title, "AI 刷新的社交标题")
	    XCTAssertFalse(store.isSEOSocialPreviewStale(for: updated))
	    XCTAssertEqual(store.seoSocialPreviewMessage, "AI 元数据变更后，SEO 社交预览已同步刷新。")

	    let record = try XCTUnwrap(store.recentAIMetadataApplicationRecords(for: updated).first)
	    let restored = try XCTUnwrap(store.rollbackAIMetadataApplicationRecord(record))

	    XCTAssertEqual(store.seoSocialPreviewSnapshot(for: restored)?.cards.first?.title, originalTitle)
	    XCTAssertFalse(store.isSEOSocialPreviewStale(for: restored))
	  }
	
  func testStoreCachesSocialPreviewSnapshotsPerDraftAndPersistsThem() throws {
    let url = try temporaryPersistenceURL()
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    var firstDraft = try XCTUnwrap(store.selectedDraft)
    firstDraft.title = "第一篇社交预览"
    firstDraft.slug = "first-social-preview"
    firstDraft.summary = "第一篇文章的社交预览摘要，用来验证 Mac 版发布控制台会按文章保留 SEO 社交快照。"
    store.updateDraft(firstDraft)

    var secondDraft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "第二篇社交预览",
      slug: "second-social-preview",
      draft: false,
      summary: "第二篇文章的社交预览摘要，用来验证多个文章的快照不会互相覆盖。",
      bodyMarkdown: "# 第二篇社交预览\n\nBody"
    )
    secondDraft.bodyMarkdown = "This body is intentionally long enough for the second cached social preview snapshot."
    store.setDrafts([secondDraft] + store.drafts)

    store.prepareSEOSocialPreview(for: firstDraft)
    store.prepareSEOSocialPreview(for: secondDraft)

    XCTAssertEqual(store.seoSocialPreviewSnapshots.count, 2)
    XCTAssertEqual(store.seoSocialPreviewSnapshot(for: firstDraft)?.cards.first?.title, "第一篇社交预览")
    XCTAssertEqual(store.seoSocialPreviewSnapshot(for: secondDraft)?.cards.first?.title, "第二篇社交预览")

    firstDraft.title = "第一篇已修改"
    store.updateDraft(firstDraft)

    XCTAssertEqual(store.seoSocialPreviewSnapshot(for: firstDraft)?.cards.first?.title, "第一篇社交预览")
    XCTAssertTrue(store.isSEOSocialPreviewStale(for: firstDraft))
    XCTAssertFalse(store.isSEOSocialPreviewStale(for: secondDraft))

    store.save()

    let reloaded = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: url))
    XCTAssertEqual(reloaded.seoSocialPreviewSnapshots.count, 2)
    XCTAssertEqual(reloaded.selectedDraftID, secondDraft.id)
    XCTAssertEqual(reloaded.seoSocialPreviewSnapshot?.draftID, secondDraft.id)
    XCTAssertEqual(reloaded.seoSocialPreviewSnapshot?.cards.first?.title, "第二篇社交预览")
    XCTAssertEqual(reloaded.seoSocialPreviewSnapshot(for: firstDraft)?.cards.first?.title, "第一篇社交预览")
    XCTAssertTrue(reloaded.isSEOSocialPreviewStale(for: firstDraft))

    XCTAssertTrue(reloaded.focusDraft(firstDraft.id, section: .writing))
    XCTAssertEqual(reloaded.seoSocialPreviewSnapshot?.draftID, firstDraft.id)
    XCTAssertEqual(reloaded.seoSocialPreviewSnapshot?.cards.first?.title, "第一篇社交预览")

    reloaded.createDraft()
    XCTAssertNil(reloaded.seoSocialPreviewSnapshot)
  }

  func testStoreSEOSocialPublishPackageIncludesRelatedArticleSuggestions() throws {
    let store = WorkbenchStore(persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()))
    let profile = store.activeProfile
    let sourceID = UUID(uuidString: "8E76D4C3-1573-4246-9E1F-9C744420C7C1")!
    let targetID = UUID(uuidString: "9712FC15-C35D-4EB0-9E53-F3C730694BC8")!
    let unpublishedTargetID = UUID(uuidString: "7A4A1F55-3627-462B-A1D9-436916C82FC1")!
    let source = ArticleDraft(
      id: sourceID,
      siteProfileID: profile.id,
      title: "SEO 发布包",
      slug: "seo-publish-package",
      tags: ["SEO", "Mac"],
      draft: false,
      summary: "这篇文章验证 SEO 社交发布包会携带平台状态、Meta HTML 和关联文章建议。",
      bodyMarkdown: "正文还没有链接到目标文章。",
      status: .published
    )
    let target = ArticleDraft(
      id: targetID,
      siteProfileID: profile.id,
      title: "Mac SEO 预览",
      slug: "mac-seo-preview",
      tags: ["SEO"],
      draft: false,
      summary: "目标文章。",
      bodyMarkdown: "目标正文。",
      status: .published
    )
    let unpublishedTarget = ArticleDraft(
      id: unpublishedTargetID,
      siteProfileID: profile.id,
      title: "未上线 SEO 预览",
      slug: "unpublished-seo-preview",
      tags: ["SEO"],
      draft: false,
      summary: "还没有发布的候选文章。",
      bodyMarkdown: "未上线正文。",
      status: .ready
    )
    store.setDrafts([source, target, unpublishedTarget])

    store.prepareSEOSocialPreview(for: source)

    let package = try XCTUnwrap(store.seoSocialPublishPackageMarkdown(for: source))
    XCTAssertTrue(package.contains("## 关联文章建议"))
    XCTAssertTrue(package.contains("SEO 发布包 -> Mac SEO 预览"))
    XCTAssertTrue(package.contains("/mac-seo-preview/"))
    XCTAssertFalse(package.contains("未上线 SEO 预览"))
    XCTAssertFalse(package.contains("/unpublished-seo-preview/"))
    XCTAssertTrue(package.contains("## Meta HTML"))
  }

  private func temporaryPersistenceURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("workbench.json")
  }

  private func writeTestImage(at url: URL, width: Int, height: Int) throws {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let offset = (y * width + x) * 4
        pixels[offset] = UInt8((x * 17 + y * 11) % 256)
        pixels[offset + 1] = UInt8((x * 23 + y * 5) % 256)
        pixels[offset + 2] = UInt8((x * 7 + y * 29) % 256)
        pixels[offset + 3] = 255
      }
    }

    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
      XCTFail("Failed to create test image")
      return
    }

    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}
