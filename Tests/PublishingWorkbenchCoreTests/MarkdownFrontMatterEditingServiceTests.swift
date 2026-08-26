import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownFrontMatterEditingServiceTests: XCTestCase {
  func testRenderAndApplyPreserveAliasesAndPermalink() throws {
    var yamlProfile = SiteProfile.defaultProfile
    yamlProfile.frontMatterStyle = .yaml
    let draft = ArticleDraft(
      siteProfileID: yamlProfile.id,
      title: "Garden",
      slug: "garden",
      aliases: ["/old-garden/", "/notes/garden/"],
      permalink: "/garden-entry/"
    )
    let service = MarkdownFrontMatterEditingService()

    let yaml = service.render(draft: draft, profile: yamlProfile)
    XCTAssertTrue(yaml.contains("aliases: [\"/old-garden/\", \"/notes/garden/\"]"))
    XCTAssertTrue(yaml.contains("permalink: \"/garden-entry/\""))
    let yamlResult = service.applying(yaml, to: draft, profile: yamlProfile)
    XCTAssertTrue(yamlResult.isValid)
    XCTAssertEqual(yamlResult.draft.aliases, draft.aliases)
    XCTAssertEqual(yamlResult.draft.permalink, draft.permalink)

    var tomlProfile = yamlProfile
    tomlProfile.frontMatterStyle = .toml
    let toml = service.render(draft: draft, profile: tomlProfile)
    XCTAssertTrue(toml.contains("aliases = [\"/old-garden/\", \"/notes/garden/\"]"))
    XCTAssertTrue(toml.contains("permalink = \"/garden-entry/\""))
    let tomlResult = service.applying(toml, to: draft, profile: tomlProfile)
    XCTAssertTrue(tomlResult.isValid)
    XCTAssertEqual(tomlResult.draft.aliases, draft.aliases)
    XCTAssertEqual(tomlResult.draft.permalink, draft.permalink)
  }

  func testYAMLEditUpdatesStructuredMetadataAndPreservesBody() throws {
    var profile = SiteProfile.defaultProfile
    profile.frontMatterStyle = .yaml
    profile.dateFormat = "yyyy-MM-dd"
    let original = ArticleDraft(
      siteProfileID: profile.id,
      title: "Old title",
      date: try XCTUnwrap(date("2026-07-18")),
      slug: "old-title",
      tags: ["Old"],
      categories: ["Notes"],
      authors: ["Jinfang"],
      bodyMarkdown: "# Body"
    )

    let source = """
    ---
    title: "新标题"
    date: "2026-07-19"
    slug: "new-title"
    description: "新摘要"
    authors: ["Jinfang", "Codex"]
    tags: ["Swift", "编辑器"]
    categories: ["Product"]
    draft: false
    visibility: "private"
    ---
    """

    let result = MarkdownFrontMatterEditingService().applying(source, to: original, profile: profile)

    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.draft.title, "新标题")
    XCTAssertEqual(result.draft.slug, "new-title")
    XCTAssertEqual(result.draft.summary, "新摘要")
    XCTAssertEqual(result.draft.authors, ["Jinfang", "Codex"])
    XCTAssertEqual(result.draft.tags, ["Swift", "编辑器"])
    XCTAssertEqual(result.draft.categories, ["Product"])
    XCTAssertFalse(result.draft.draft)
    XCTAssertEqual(result.draft.visibility, .private)
    XCTAssertEqual(result.draft.bodyMarkdown, original.bodyMarkdown)
    XCTAssertEqual(formattedDate(result.draft.date), "2026-07-19")
  }

  func testTOMLRoundTripKeepsMetadataValues() throws {
    var profile = SiteProfile.defaultProfile
    profile.frontMatterStyle = .toml
    profile.dateFormat = "yyyy-MM-dd"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "A quoted \"title\"",
      date: try XCTUnwrap(date("2026-07-18")),
      slug: "quoted-title",
      tags: ["one, two", "three"],
      categories: [],
      authors: [],
      draft: true,
      visibility: .public,
      summary: "Summary",
      bodyMarkdown: "Body"
    )
    let service = MarkdownFrontMatterEditingService()

    let source = service.render(draft: draft, profile: profile)
    let result = service.applying(source, to: draft, profile: profile)

    XCTAssertTrue(result.isValid)
    XCTAssertEqual(result.draft.title, draft.title)
    XCTAssertEqual(result.draft.tags, draft.tags)
    XCTAssertEqual(result.draft.summary, draft.summary)
    XCTAssertEqual(result.draft.bodyMarkdown, draft.bodyMarkdown)
  }

  func testRenderedDateKeepsTimeWhenProfilePublishesDateOnly() throws {
    var profile = SiteProfile.defaultProfile
    profile.frontMatterStyle = .toml
    profile.dateFormat = "yyyy-MM-dd"
    let draftDate = try XCTUnwrap(
      ISO8601DateFormatter().date(from: "2026-07-18T08:34:56Z")
    )
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Timed",
      date: draftDate,
      slug: "timed"
    )

    let source = MarkdownFrontMatterEditingService().render(draft: draft, profile: profile)

    XCTAssertTrue(source.contains(#"date = "2026-07-18T08:34:56Z""#))
  }

  func testInvalidSourceDoesNotMutateDraft() throws {
    var profile = SiteProfile.defaultProfile
    profile.frontMatterStyle = .yaml
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Original",
      date: try XCTUnwrap(date("2026-07-18")),
      slug: "original"
    )

    let result = MarkdownFrontMatterEditingService().applying(
      "---\ntitle without separator\n---",
      to: draft,
      profile: profile
    )

    XCTAssertEqual(result.issue, .malformedLine(2))
    XCTAssertEqual(result.draft, draft)
  }

  func testRenderedDocumentSplitsBackIntoFrontMatterAndBody() throws {
    var profile = SiteProfile.defaultProfile
    profile.frontMatterStyle = .toml
    let body = "# 正文\n\n包含中文和 emoji 🎉。"
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "完整 Markdown",
      date: try XCTUnwrap(date("2026-07-18")),
      slug: "complete-markdown",
      bodyMarkdown: body
    )
    let service = MarkdownFrontMatterEditingService()

    let document = service.renderDocument(draft: draft, profile: profile)
    let parts = try XCTUnwrap(service.splitDocument(document, profile: profile))

    XCTAssertEqual(parts.bodyMarkdown, body)
    XCTAssertTrue(parts.frontMatter.hasPrefix("+++\n"))
    XCTAssertEqual(
      (document as NSString).substring(from: parts.bodyUTF16Offset),
      body
    )
  }

  private func date(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: value)
  }

  private func formattedDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }
}
