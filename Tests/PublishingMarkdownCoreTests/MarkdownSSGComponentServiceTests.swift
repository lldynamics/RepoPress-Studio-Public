import Foundation
import XCTest
@testable import PublishingMarkdownCore

final class MarkdownSSGComponentServiceTests: XCTestCase {
  func testBuiltInComponentsExposeSlashShortcutsAndEditablePlaceholders() throws {
    let callout = try XCTUnwrap(
      MarkdownSSGComponentLibraryService.builtInSnippets.first { $0.id == "ssg-callout" }
    )
    let youtube = try XCTUnwrap(
      MarkdownSSGComponentLibraryService.builtInSnippets.first { $0.id == "ssg-youtube" }
    )

    XCTAssertEqual(callout.shortcut, "callout")
    XCTAssertEqual(callout.previewKind, .callout)
    XCTAssertEqual(callout.selectionToken, "在这里输入提示内容。")
    XCTAssertEqual(youtube.shortcut, "youtube")
    XCTAssertTrue(youtube.markdown.contains("VIDEO_ID"))
  }

  func testOccurrencesParseDirectiveHugoLeadAndInlineEmbeds() {
    let markdown = """
    ::: tip 注意
    先确认站点已经启用提示框。
    :::

    {{< lead >}}
    这是一段文章导语。
    {{< /lead >}}

    {{< youtube dQw4w9WgXcQ >}}
    {{< bilibili BV1xx411c7mD >}}
    {{< github-card openai/codex >}}
    """

    let occurrences = MarkdownSSGComponentLibraryService.occurrences(in: markdown)

    XCTAssertEqual(
      occurrences.map(\.kind),
      [.callout, .lead, .youtube, .bilibili, .githubCard]
    )
    XCTAssertEqual(occurrences[0].title, "注意")
    XCTAssertTrue(occurrences[0].previewText.contains("启用提示框"))
    XCTAssertTrue(occurrences[1].previewText.contains("文章导语"))
    XCTAssertEqual(occurrences[2].previewText, "dQw4w9WgXcQ")
    XCTAssertEqual(occurrences[4].previewText, "openai/codex")
    XCTAssertEqual(occurrences[0].lineNumber, 1)
    XCTAssertEqual(occurrences[1].lineNumber, 5)
  }

  func testCustomShortcodesInferGenericVisualPreviewKinds() {
    XCTAssertEqual(
      MarkdownSSGComponentLibraryService.inferredPreviewKind(
        for: "::: warning\n请确认配置。\n:::"
      ),
      .callout
    )
    XCTAssertEqual(
      MarkdownSSGComponentLibraryService.inferredPreviewKind(
        for: "{{< product-card owner/repo >}}"
      ),
      .custom
    )
    XCTAssertNil(MarkdownSSGComponentLibraryService.inferredPreviewKind(for: "普通 Markdown"))
  }

  func testCustomShortcutCreatesExactAndAutomaticCompletionCandidate() throws {
    let siteID = UUID()
    let snippets = MarkdownSnippetLibraryService.savingCustomSnippet(
      title: "警告框",
      detail: "项目自己的提醒组件",
      kind: .snippet,
      markdown: "::: warning 警告\n请确认配置。\n:::",
      siteProfileID: siteID,
      shortcut: "/callout",
      in: []
    )
    let snippet = try XCTUnwrap(snippets.first)
    let service = MarkdownCursorCompletionService()
    let cursor = NSRange(location: ("/callout" as NSString).length, length: 0)

    let context = try XCTUnwrap(
      service.completion(in: "/callout", selectedRange: cursor, snippets: snippets)
    )
    let candidate = try XCTUnwrap(context.candidates.first)
    let automatic = try XCTUnwrap(
      service.automaticShortcutCandidate(
        in: "/callout",
        selectedRange: cursor,
        snippets: snippets
      )
    )

    XCTAssertEqual(context.kind, .slashCommand)
    XCTAssertEqual(candidate.id, "snippet-\(snippet.id)")
    XCTAssertEqual(candidate.replacement, snippet.markdown)
    XCTAssertEqual(automatic.id, candidate.id)
    XCTAssertEqual(automatic.selectedRangeAfterApplying.length, 0)
    XCTAssertNil(
      service.automaticShortcutCandidate(
        in: "普通段落输入",
        selectedRange: NSRange(location: ("普通段落输入" as NSString).length, length: 0),
        snippets: snippets
      )
    )
    let fenced = "```text\n/callout\n```"
    XCTAssertNil(
      service.automaticShortcutCandidate(
        in: fenced,
        selectedRange: NSRange(
          location: (fenced as NSString).range(of: "/callout").upperBound,
          length: 0
        ),
        snippets: snippets
      )
    )
  }
}
