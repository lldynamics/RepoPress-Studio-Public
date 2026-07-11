import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class ContentMigrationServiceTests: XCTestCase {
  private let service = ContentMigrationService()
  private var profile: SiteProfile {
    var profile = SiteProfile.defaultProfile
    profile.markdownPathPattern = "content/posts/{slug}.md"
    return profile
  }

  func testConvertsWordPressWXRFrontMatterImagesAndRedirects() throws {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:wp="http://wordpress.org/export/1.2/"><channel>
      <wp:wxr_version>1.2</wp:wxr_version>
      <item>
        <title>迁移文章</title><link>https://old.example.com/old-post/</link>
        <wp:post_type>post</wp:post_type><wp:post_name>new-post</wp:post_name><wp:post_date>2026-07-01 10:20:00</wp:post_date><wp:status>publish</wp:status>
        <content:encoded><![CDATA[<p>正文</p><img src="https://cdn.example.com/media/photo.jpg">]]></content:encoded>
        <category domain="post_tag"><![CDATA[Swift]]></category><category><![CDATA[开发]]></category>
      </item>
      <item><title>附件</title><wp:post_type>attachment</wp:post_type></item>
    </channel></rss>
    """

    let plan = try makePlan(contents: xml, extension: "xml")

    XCTAssertEqual(plan.sourceKind, .wordpressWXR)
    XCTAssertEqual(plan.drafts.count, 1)
    let draft = try XCTUnwrap(plan.drafts.first)
    XCTAssertEqual(draft.title, "迁移文章")
    XCTAssertEqual(draft.slug, "new-post")
    XCTAssertEqual(draft.repositoryPath, "content/posts/new-post.md")
    XCTAssertEqual(draft.tags, ["Swift"])
    XCTAssertEqual(draft.categories, ["开发"])
    XCTAssertTrue(draft.bodyMarkdown.contains("![](/assets/imported/cdn.example.com/media/photo.jpg)"))
    XCTAssertEqual(plan.redirects, [ContentMigrationRedirect(sourcePath: "/old-post/", targetPath: "/new-post/")])
  }

  func testConvertsRSSItem() throws {
    let xml = """
    <rss version="2.0"><channel><item>
      <title>RSS 文章</title><link>https://old.example.com/rss-entry</link>
      <pubDate>Wed, 01 Jul 2026 10:20:00 +0000</pubDate><description>摘要</description>
    </item></channel></rss>
    """

    let plan = try makePlan(contents: xml, extension: "rss")

    XCTAssertEqual(plan.sourceKind, .rss)
    XCTAssertEqual(plan.drafts.count, 1)
    XCTAssertEqual(plan.drafts[0].title, "RSS 文章")
    XCTAssertEqual(plan.drafts[0].summary, "摘要")
    XCTAssertEqual(plan.redirects.first?.sourcePath, "/rss-entry/")
  }

  func testConvertsAtomHrefLink() throws {
    let atom = """
    <feed xmlns="http://www.w3.org/2005/Atom"><entry>
      <title>Atom 文章</title><link href="https://old.example.com/atom-entry" />
      <published>2026-07-01T10:20:00Z</published><content>正文</content>
    </entry></feed>
    """

    let plan = try makePlan(contents: atom, extension: "atom")

    XCTAssertEqual(plan.sourceKind, .rss)
    XCTAssertEqual(plan.redirects.first?.sourcePath, "/atom-entry/")
  }

  func testConvertsMarkdownFolderAndRewritesRelativeImages() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let markdown = """
    ---
    title: Markdown 文章
    slug: markdown-post
    tags: [Swift, macOS]
    categories: [开发]
    draft: true
    permalink: /old-markdown/
    ---
    ![封面](images/cover.png)
    """
    try markdown.write(to: directory.appendingPathComponent("post.md"), atomically: true, encoding: .utf8)

    let plan = try service.makePlan(sourceURL: directory, profile: profile)

    XCTAssertEqual(plan.sourceKind, .markdownFolder)
    XCTAssertEqual(plan.drafts.count, 1)
    XCTAssertEqual(plan.drafts[0].tags, ["Swift", "macOS"])
    XCTAssertTrue(plan.drafts[0].draft)
    XCTAssertTrue(plan.drafts[0].bodyMarkdown.contains("![封面](/assets/imported/images/cover.png)"))
    XCTAssertEqual(plan.redirects.first?.targetPath, "/markdown-post/")
  }

  func testConvertsTOMLFrontMatterFromMarkdownFolder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let markdown = """
    +++
    title = "TOML 文章"
    slug = "toml-post"
    draft = true
    permalink = "/old-toml/"
    +++
    TOML 正文
    """
    try markdown.write(to: directory.appendingPathComponent("toml.md"), atomically: true, encoding: .utf8)

    let plan = try service.makePlan(sourceURL: directory, profile: profile)

    XCTAssertEqual(plan.drafts.count, 1)
    XCTAssertEqual(plan.drafts[0].title, "TOML 文章")
    XCTAssertEqual(plan.drafts[0].slug, "toml-post")
    XCTAssertTrue(plan.drafts[0].draft)
    XCTAssertEqual(plan.drafts[0].bodyMarkdown, "TOML 正文")
    XCTAssertEqual(plan.redirects.first?.sourcePath, "/old-toml/")
  }

  func testConvertsGenericJSONAndEnsuresUniqueSlugs() throws {
    let json = """
    {"posts":[
      {"title":"第一篇","slug":"same","url":"https://old.example.com/a","content":"正文"},
      {"title":"第二篇","slug":"same","url":"https://old.example.com/b","content":"正文"}
    ]}
    """

    let plan = try makePlan(contents: json, extension: "json")

    XCTAssertEqual(plan.sourceKind, .genericJSON)
    XCTAssertEqual(Set(plan.drafts.map(\.slug)), Set(["same", "same-2"]))
    XCTAssertEqual(plan.redirects.map(\.sourcePath), ["/a/", "/b/"])
  }

  func testBuildsMigrationPlanAsynchronously() async throws {
    let markdown = """
    ---
    title: Async Migration
    slug: async-migration
    ---
    Async body
    """
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).md")
    defer { try? FileManager.default.removeItem(at: url) }
    try markdown.write(to: url, atomically: true, encoding: .utf8)

    let plan = try await service.makePlanAsync(sourceURL: url, profile: profile)

    XCTAssertEqual(plan.drafts.first?.title, "Async Migration")
    XCTAssertEqual(plan.drafts.first?.bodyMarkdown, "Async body")
  }

  private func makePlan(contents: String, extension fileExtension: String) throws -> ContentMigrationPlan {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("migration-\(UUID().uuidString).\(fileExtension)")
    defer { try? FileManager.default.removeItem(at: url) }
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return try service.makePlan(sourceURL: url, profile: profile)
  }
}
