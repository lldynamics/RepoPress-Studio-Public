import Foundation
import Testing

@testable import PublishingMarkdownCore

struct DelimitedFrontMatterParserTests {
  @Test func splitsYAMLWithCRLFAndPreservesOriginalBodyOffset() {
    let source = "---\r\ntitle: Test\r\n---\r\n\r\nBody"
    let result = DelimitedFrontMatterParser().split(source)

    #expect(result?.delimiter == .yaml)
    #expect(result?.frontMatter == "---\ntitle: Test\n---")
    #expect(result?.contentLines == ["title: Test"])
    #expect(result?.body == "Body")
    #expect(result?.bodyUTF16Offset == 25)
    assertBodyStartsAtOffset(source, result)
  }

  @Test func splitsTOMLWithLFAndNoBlankLine() {
    let source = "+++\ntitle = \"Test\"\n+++\nBody"
    let result = DelimitedFrontMatterParser().split(source, expectedDelimiter: .toml)

    #expect(result?.delimiter == .toml)
    #expect(result?.frontMatter == "+++\ntitle = \"Test\"\n+++")
    #expect(result?.body == "Body")
    #expect(result?.bodyUTF16Offset == 23)
    assertBodyStartsAtOffset(source, result)
  }

  @Test func splitsYAMLWithIsolatedCRAndPreservesBodyNewlines() {
    let source = "---\rtitle: Test\r---\r\rFirst\rSecond\nThird\r\nFourth"
    let result = DelimitedFrontMatterParser().split(source)

    #expect(result?.contentLines == ["title: Test"])
    #expect(result?.body == "First\rSecond\nThird\r\nFourth")
    #expect(result?.bodyUTF16Offset == 21)
    assertBodyStartsAtOffset(source, result)
  }

  @Test func measuresUnicodeSurrogatePairsInOriginalUTF16() {
    let source = "---\r\ntitle: 😀\r\n---\r\n正文\r\n😀"
    let result = DelimitedFrontMatterParser().split(source)

    #expect(result?.body == "正文\r\n😀")
    #expect(result?.bodyUTF16Offset == 21)
    assertBodyStartsAtOffset(source, result)
  }

  @Test func rejectsUnexpectedDelimiter() {
    let source = "+++\ntitle = \"Test\"\n+++\nBody"
    #expect(
      DelimitedFrontMatterParser().split(source, expectedDelimiter: .yaml) == nil
    )
  }

  private func assertBodyStartsAtOffset(
    _ source: String,
    _ result: DelimitedFrontMatterDocument?
  ) {
    guard let result else {
      Issue.record("Expected front matter to parse")
      return
    }

    #expect((source as NSString).substring(from: result.bodyUTF16Offset) == result.body)
  }
}
