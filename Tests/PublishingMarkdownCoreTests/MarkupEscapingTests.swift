import Testing
@testable import PublishingMarkdownCore

struct MarkupEscapingTests {
  @Test func textAndAttributeEscapingHaveExplicitQuotePolicies() {
    let source = "<&>\"'"

    #expect(MarkupEscaping.htmlText(source) == "&lt;&amp;&gt;\"'")
    #expect(
      MarkupEscaping.htmlDoubleQuotedAttribute(source)
        == "&lt;&amp;&gt;&quot;'"
    )
    #expect(MarkupEscaping.html(source) == "&lt;&amp;&gt;&quot;&#39;")
  }
}
