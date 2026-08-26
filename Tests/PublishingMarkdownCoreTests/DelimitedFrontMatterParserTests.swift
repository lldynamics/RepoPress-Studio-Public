import Testing
@testable import PublishingMarkdownCore

struct DelimitedFrontMatterParserTests {
  @Test func splitsYAMLAndNormalizesLineEndingsAndBodyOffset() {
    let source = "---\r\ntitle: Test\r\n---\r\n\r\nBody"
    let result = DelimitedFrontMatterParser().split(source)

    #expect(result?.delimiter == .yaml)
    #expect(result?.contentLines == ["title: Test"])
    #expect(result?.body == "Body")
    #expect(result?.bodyUTF16Offset == 21)
  }

  @Test func rejectsUnexpectedDelimiter() {
    let source = "+++\ntitle = \"Test\"\n+++\nBody"
    #expect(
      DelimitedFrontMatterParser().split(source, expectedDelimiter: .yaml) == nil
    )
  }
}
