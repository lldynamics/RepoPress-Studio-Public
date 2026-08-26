import Testing
@testable import PublishingMarkdownCore

struct LocalKaTeXPreviewServiceTests {
  @Test func rendersCommonFractionAndCommandMarkup() {
    let rendered = LocalKaTeXPreviewService.render("\\frac{a}{b}")

    #expect(rendered.contains("local-katex-inline"))
    #expect(rendered.contains("math-fraction"))
    #expect(rendered.contains("math-numerator\">a</span>"))
    #expect(rendered.contains("math-denominator\">b</span>"))
  }

  @Test func prepareProtectsCodeAndRestoresInlineFormula() {
    let markdown = "正文 $x$\n\n```swift\nlet value = \"$y$\"\n```"
    let prepared = LocalKaTeXPreviewService.prepare(markdown: markdown)

    #expect(prepared.replacements.count == 1)
    #expect(prepared.replacements.first?.isBlock == false)
    #expect(prepared.markdown.contains("$y$"))
    #expect(!prepared.markdown.contains("$x$"))

    let token = prepared.replacements[0].token
    let restored = LocalKaTeXPreviewService.restore(
      renderedHTML: "<p>\(token)</p>",
      replacements: prepared.replacements
    )
    #expect(restored.contains("local-katex-inline"))
    #expect(!restored.contains(token))
  }

  @Test func prepareProtectsCodeAndRestoresDisplayFormula() {
    let markdown = "```\n$$not math$$\n```\n\n$$x^2$$"
    let prepared = LocalKaTeXPreviewService.prepare(markdown: markdown)

    #expect(prepared.replacements.count == 1)
    #expect(prepared.replacements.first?.isBlock == true)
    #expect(prepared.markdown.contains("$$not math$$"))

    let token = prepared.replacements[0].token
    let restored = LocalKaTeXPreviewService.restore(
      renderedHTML: "<p>\(token)</p>\n",
      replacements: prepared.replacements
    )
    #expect(restored.contains("local-katex-display"))
    #expect(!restored.contains(token))
  }

  @Test func renderEscapesUnsupportedFormulaText() {
    let rendered = LocalKaTeXPreviewService.render("a < b & c")

    #expect(rendered.contains("a &lt; b &amp; c"))
    #expect(!rendered.contains("a < b & c"))
  }
}
