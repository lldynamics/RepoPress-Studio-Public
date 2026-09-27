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

  func testDetectedReferencesCoverHugoAndZolaSyntaxesButSkipTemplateNoise() {
    let markdown = """
      正文 {{< product-card owner/repo >}} 和 {% component gallery("图集") %}。
      {{% notice %}}内容{{% /notice %}}
      {{ legacy("😀") }} {% image(src="x") %}
      {{ ordinary_variable }} {% if user %}ignored{% endif %}
      `{{< inline-code >}}`
      ```md
      {{< fenced >}}
      ```
      <!-- {{< comment >}} -->
      """

    let references = MarkdownSSGComponentLibraryService.detectedReferences(in: markdown)
    XCTAssertEqual(
      references.map(\.name), ["product-card", "gallery", "notice", "notice", "legacy", "image"])
    XCTAssertEqual(
      references.map(\.engineSyntax),
      [.hugoAngle, .zolaComponent, .hugoPercent, .hugoPercent, .zolaLegacy, .zolaComponent])
    XCTAssertEqual(references.first?.lineNumber, 1)
    XCTAssertEqual(references[4].lineNumber, 3)
    XCTAssertEqual(
      (markdown as NSString).substring(with: references[4].sourceRange), "{{ legacy(\"😀\") }}")
  }

  func testZolaInlineComponentIsRecognizedWithoutMatchingOrdinaryVariable() {
    let markdown = "{{<badge label=\"New\" />}} and {{ page.title }}"
    let references = MarkdownSSGComponentLibraryService.detectedReferences(in: markdown)
    XCTAssertEqual(references.map(\.name), ["badge"])
    XCTAssertEqual(references.first?.engineSyntax, .zolaInlineComponent)
    XCTAssertEqual(MarkdownSSGComponentLibraryService.occurrences(in: markdown).count, 1)
  }

  func testOccurrencesHandleCustomPairedShortcodesAndDoNotCaptureUnmatchedToEOF() {
    let markdown = """
      {{< panel >}}
      中文内容
      {{< /panel >}}
      {{< broken >}}
      后面的普通文字
      """

    let occurrences = MarkdownSSGComponentLibraryService.occurrences(in: markdown)
    XCTAssertEqual(occurrences.count, 2)
    XCTAssertEqual(occurrences[0].kind, .custom)
    XCTAssertTrue(occurrences[0].previewText.contains("中文内容"))
    XCTAssertEqual(occurrences[1].source, "{{< broken >}}")
    XCTAssertFalse(occurrences[1].source.contains("后面的普通文字"))
  }

  func testReferencesDistinguishClosingTagsAndSkipZolaRawBlocks() {
    let markdown = "😀 {% raw %} {% component hidden(1) %} {% endraw %}\n{{< open %}}"
    let references = MarkdownSSGComponentLibraryService.detectedReferences(in: markdown)

    XCTAssertTrue(references.isEmpty, "Mismatched Hugo delimiters and raw contents are ignored")
    XCTAssertTrue(MarkdownSSGComponentLibraryService.occurrences(in: markdown).isEmpty)
    let closing = MarkdownSSGComponentLibraryService.detectedReferences(in: "{{< /panel >}}")
    XCTAssertEqual(closing.first?.name, "panel")
    XCTAssertTrue(closing.first?.isClosing == true)
  }

  func testHugoSubdirectoryShortcodeAndSelfClosingTag() {
    let markdown = "{{< media/audio path=\"song.mp3\" >}}\n{{< media/image / >}}"
    let references = MarkdownSSGComponentLibraryService.detectedReferences(in: markdown)
    XCTAssertEqual(references.map(\.name), ["media/audio", "media/image"])
    XCTAssertFalse(references.contains(where: \.isClosing))

    let occurrences = MarkdownSSGComponentLibraryService.occurrences(in: markdown)
    XCTAssertEqual(occurrences.count, 2)
    XCTAssertEqual(occurrences[1].kind, .custom)
    XCTAssertEqual(occurrences[1].source, "{{< media/image / >}}")
  }

  func testZolaNamespacedInlineAndBlockComponents() {
    let markdown = """
      {{<ui.button label="x" />}}
      {% <ui.forms.widget title="Form"> %}
      内容
      {% </ui.forms.widget> %}
      """

    let references = MarkdownSSGComponentLibraryService.detectedReferences(in: markdown)
    XCTAssertEqual(references.map(\.name), ["ui.button", "ui.forms.widget", "ui.forms.widget"])
    XCTAssertEqual(references.map(\.isClosing), [false, false, true])
    XCTAssertEqual(
      references.map(\.engineSyntax),
      [.zolaInlineComponent, .zolaInlineComponent, .zolaInlineComponent])

    let occurrences = MarkdownSSGComponentLibraryService.occurrences(in: markdown)
    XCTAssertEqual(occurrences.count, 2)
    XCTAssertEqual(occurrences[0].source, "{{<ui.button label=\"x\" />}}")
    XCTAssertTrue(occurrences[1].previewText.contains("内容"))
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

  func testAutomaticShortcutKeepsUTF16NormalizationWhitespaceAndFenceBoundaries() throws {
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
    let service = MarkdownCursorCompletionService()
    let longPrefix = String(repeating: "😀正文\n", count: 20_000)
    let source = longPrefix + "\t/CALLOUT"
    let cursor = NSRange(location: (source as NSString).length, length: 0)

    let candidate = try XCTUnwrap(
      service.automaticShortcutCandidate(
        in: source,
        selectedRange: cursor,
        snippets: snippets
      )
    )
    XCTAssertEqual(candidate.expectedText, "/CALLOUT")
    XCTAssertEqual(candidate.replacementRange.location, (longPrefix as NSString).length + 1)
    XCTAssertEqual(candidate.replacementRange.length, ("/CALLOUT" as NSString).length)
    XCTAssertEqual(candidate.selectedRangeAfterApplying.length, 0)

    XCTAssertNil(
      service.automaticShortcutCandidate(
        in: longPrefix + " /callout ",
        selectedRange: NSRange(
          location: ((longPrefix + " /callout ") as NSString).length,
          length: 0
        ),
        snippets: snippets
      )
    )
    XCTAssertNil(
      service.automaticShortcutCandidate(
        in: longPrefix + " /callout",
        selectedRange: NSRange(
          location: (longPrefix as NSString).length + 1,
          length: 1
        ),
        snippets: snippets
      )
    )
    for command in ["/c", "/callou", "/unknown", "//callout"] {
      let incomplete = longPrefix + " " + command
      XCTAssertNil(
        service.automaticShortcutCandidate(
          in: incomplete,
          selectedRange: NSRange(location: (incomplete as NSString).length, length: 0),
          snippets: snippets
        )
      )
    }
    let fenced = longPrefix + "```text\n/callout\n```"
    XCTAssertNil(
      service.automaticShortcutCandidate(
        in: fenced,
        selectedRange: NSRange(
          location: NSMaxRange((fenced as NSString).range(of: "/callout")),
          length: 0
        ),
        snippets: snippets
      )
    )
  }
}
