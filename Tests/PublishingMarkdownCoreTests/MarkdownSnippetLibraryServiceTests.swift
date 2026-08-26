import Foundation
import XCTest
@testable import PublishingMarkdownCore

final class MarkdownSnippetLibraryServiceTests: XCTestCase {
  func testExpansionUsesValueContextAndPreservesDatePlaceholder() throws {
    let snippet = MarkdownSnippet(
      id: "expansion",
      title: "扩展",
      detail: "",
      systemImage: "doc.text",
      kind: .articleTemplate,
      markdown: "# {{title}}\n\n/{{slug}}\n\n{{date}}"
    )
    let date = Date(timeIntervalSince1970: 1_735_689_600)
    let expanded = MarkdownSnippetLibraryService.expandedMarkdown(
      for: snippet,
      context: MarkdownSnippetExpansionContext(title: "  发布标题  ", slug: "publish-title"),
      date: date
    )

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    XCTAssertEqual(
      expanded,
      "# 发布标题\n\n/publish-title\n\n\(formatter.string(from: date))"
    )
  }

  func testSavingFilteringAndRemovingCustomSnippetsRemainScoped() throws {
    let firstSiteID = UUID()
    let secondSiteID = UUID()
    let saved = MarkdownSnippetLibraryService.savingCustomSnippet(
      title: "  发布提醒 ",
      detail: "  发布前检查 ",
      kind: .snippet,
      markdown: "  > 请检查链接。  ",
      siteProfileID: firstSiteID,
      shortcut: " /Publish-Check ",
      in: []
    )
    let snippet = try XCTUnwrap(saved.first)

    XCTAssertEqual(snippet.title, "发布提醒")
    XCTAssertEqual(snippet.detail, "发布前检查")
    XCTAssertEqual(snippet.markdown, "> 请检查链接。")
    XCTAssertEqual(snippet.shortcut, "publish-check")
    XCTAssertTrue(
      MarkdownSnippetLibraryService.availableSnippets(
        for: firstSiteID,
        customSnippets: saved
      ).contains(where: { $0.id == snippet.id })
    )
    XCTAssertFalse(
      MarkdownSnippetLibraryService.availableSnippets(
        for: secondSiteID,
        customSnippets: saved
      ).contains(where: { $0.id == snippet.id })
    )

    let updated = MarkdownSnippetLibraryService.savingCustomSnippet(
      id: snippet.id,
      title: "更新提醒",
      detail: "已更新",
      kind: .articleTemplate,
      markdown: "# {{title}}",
      siteProfileID: firstSiteID,
      in: saved
    )
    XCTAssertEqual(updated.count, 1)
    XCTAssertEqual(updated.first?.id, snippet.id)
    XCTAssertEqual(updated.first?.kind, .articleTemplate)

    XCTAssertTrue(
      MarkdownSnippetLibraryService.removingCustomSnippet(
        id: snippet.id,
        from: updated
      ).isEmpty
    )
    XCTAssertEqual(
      MarkdownSnippetLibraryService.savingCustomSnippet(
        title: " ",
        detail: "无效",
        kind: .snippet,
        markdown: "内容",
        siteProfileID: firstSiteID,
        in: updated
      ),
      updated
    )
  }

  func testShortcutNormalizationRejectsWhitespaceAndPathLikeValues() {
    XCTAssertEqual(MarkdownSnippetLibraryService.normalizedShortcut(" /Callout "), "callout")
    XCTAssertNil(MarkdownSnippetLibraryService.normalizedShortcut("call out"))
    XCTAssertNil(MarkdownSnippetLibraryService.normalizedShortcut("foo/bar"))
    XCTAssertNil(MarkdownSnippetLibraryService.normalizedShortcut(""))
  }

  func testMarkdownSnippetCodableSchemaRemainsStable() throws {
    let snippet = MarkdownSnippet(
      id: "schema",
      title: "结构",
      detail: "字段",
      systemImage: "doc.text",
      kind: .snippet,
      markdown: "{{title}}",
      siteProfileID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"),
      shortcut: "schema",
      previewKind: .custom,
      selectionToken: "title"
    )
    let encoded = try JSONEncoder().encode(snippet)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    XCTAssertEqual(
      Set(object.keys),
      [
        "id", "title", "detail", "systemImage", "kind", "markdown",
        "siteProfileID", "shortcut", "previewKind", "selectionToken",
      ]
    )
    XCTAssertEqual(try JSONDecoder().decode(MarkdownSnippet.self, from: encoded), snippet)
  }
}
