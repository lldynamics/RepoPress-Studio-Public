import XCTest
@testable import PersonalSitePublisherMac
@testable import PublishingWorkbenchCore

final class DefaultRuleFrontMatterPreviewTests: XCTestCase {
  func testYAMLPreviewUsesProductionRendererAndCurrentDateFormat() {
    let profile = makeProfile(style: .yaml, dateFormat: "yyyy/MM/dd")
    let preview = DefaultRuleFrontMatterPreview.make(profile: profile)

    XCTAssertEqual(
      preview.frontMatter,
      FrontMatterRenderer().render(
        draft: DefaultRuleFrontMatterPreview.sampleDraft(profile: profile),
        profile: profile
      )
    )
    XCTAssertTrue(preview.frontMatter.hasPrefix("---\n"))
    XCTAssertTrue(preview.frontMatter.contains("title: \"示例文章标题\""))
    XCTAssertTrue(preview.frontMatter.contains("date: \""))
    XCTAssertTrue(preview.frontMatter.contains("/"))
    XCTAssertTrue(preview.frontMatter.contains("authors: [\"王小明\"]"))
    XCTAssertTrue(preview.frontMatter.contains("tags: [\"Swift\", \"macOS\"]"))
    XCTAssertTrue(preview.frontMatter.contains("categories: [\"开发\"]"))

    let compactDatePreview = DefaultRuleFrontMatterPreview.make(
      profile: makeProfile(style: .yaml, dateFormat: "yyyyMMdd")
    )
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd"
    XCTAssertNotEqual(preview.frontMatter, compactDatePreview.frontMatter)
    XCTAssertTrue(
      compactDatePreview.frontMatter.contains(
        "date: \"\(formatter.string(from: DefaultRuleFrontMatterPreview.sampleDate))\""
      )
    )
  }

  func testTOMLPreviewUsesProductionRendererAndResolver() {
    let profile = makeProfile(style: .toml, dateFormat: "yyyy-MM-dd HH:mm")
    let preview = DefaultRuleFrontMatterPreview.make(profile: profile)

    XCTAssertEqual(
      preview.frontMatter,
      FrontMatterRenderer().render(
        draft: DefaultRuleFrontMatterPreview.sampleDraft(profile: profile),
        profile: profile
      )
    )
    XCTAssertTrue(preview.frontMatter.hasPrefix("+++\n"))
    XCTAssertTrue(preview.frontMatter.contains("title = \"示例文章标题\""))
    XCTAssertTrue(preview.frontMatter.contains("date = \""))
    XCTAssertTrue(preview.frontMatter.contains(":"))
    XCTAssertTrue(preview.frontMatter.contains("authors = [\"王小明\"]"))
    XCTAssertEqual(preview.markdownPath, "content/posts/2026/example-article.md")
    // Match the production Zola resolver: it removes content/posts and does
    // not append a trailing slash. The settings preview must not invent one.
    XCTAssertEqual(preview.url, "https://publisher.example.com/2026/example-article")
  }

  private func makeProfile(style: FrontMatterStyle, dateFormat: String) -> SiteProfile {
    SiteProfile(
      name: "Preview",
      siteKind: .zola,
      frontMatterStyle: style,
      contentRoot: "content",
      markdownPathPattern: "content/posts/{year}/{slug}.md",
      dateFormat: dateFormat,
      defaultAuthor: "王小明",
      defaultTags: ["Swift", "macOS"],
      defaultCategories: ["开发"],
      includeDraftFlagInFrontMatter: true,
      includeCoverInFrontMatter: false,
      deploymentSiteURL: "https://publisher.example.com"
    )
  }
}
