import Testing

@testable import RepoPressCore

struct FrontMatterDocumentRendererTests {
  @Test
  func rendersYAMLWithEscapedValuesAndStableFieldOrder() {
    let document = sampleDocument(syntax: .yaml)

    let output = FrontMatterDocumentRenderer().render(document)

    #expect(output.contains(#"title: "A \"quoted\" title""#))
    #expect(output.contains(#"tags: ["swift", "ios"]"#))
    #expect(output.contains(#"summary: "Line 1\nLine 2""#))
    #expect(output.hasPrefix("---\n"))
    #expect(output.hasSuffix("\n---"))
  }

  @Test
  func rendersTOMLTaxonomyTableAndExtraCover() {
    var document = sampleDocument(syntax: .toml)
    document.taxonomyLayout = .table
    document.writesCoverInExtraTable = true

    let output = FrontMatterDocumentRenderer().render(document)

    #expect(output.contains("[taxonomies]\ntags = [\"swift\", \"ios\"]"))
    #expect(output.contains("[extra]\nog_preview_img = \"/images/cover.jpg\""))
    #expect(!output.contains("cover = "))
  }

  @Test
  func assemblesTrimmedMarkdownDocumentWithTrailingNewline() {
    var document = sampleDocument(syntax: .toml)
    document.bodyMarkdown = "\n Body \n"

    let output = FrontMatterDocumentRenderer().markdownDocument(document)

    #expect(output.hasSuffix("\n\nBody\n"))
  }

  private func sampleDocument(
    syntax: FrontMatterDocumentSyntax
  ) -> FrontMatterDocument {
    FrontMatterDocument(
      syntax: syntax,
      title: #"A "quoted" title"#,
      formattedDate: "2026-07-30",
      slug: "quoted-title",
      draftFlag: true,
      summaryField: "summary",
      summary: "Line 1\nLine 2",
      authors: ["author"],
      tags: ["swift", "ios"],
      categories: ["guide"],
      taxonomyLayout: .inlineTable,
      coverField: "cover",
      coverPath: "/images/cover.jpg",
      writesCoverInExtraTable: false,
      bodyMarkdown: "Body"
    )
  }
}
