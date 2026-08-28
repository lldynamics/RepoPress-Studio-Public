import XCTest

@testable import PersonalSitePublisherMac

final class ReaderCodeSyntaxHighlighterTests: XCTestCase {
  func testSwiftTokensClassifyKeywordsTypesStringsNumbersAndComments() {
    let tokens = ReaderCodeSyntaxHighlighter.tokens(
      in: "let value: Article = \"reader\" + 42 // note",
      language: "swift"
    )

    XCTAssertTrue(tokens.contains(ReaderCodeToken(text: "let", kind: .keyword)))
    XCTAssertTrue(tokens.contains(ReaderCodeToken(text: "Article", kind: .type)))
    XCTAssertTrue(tokens.contains(ReaderCodeToken(text: "\"reader\"", kind: .string)))
    XCTAssertTrue(tokens.contains(ReaderCodeToken(text: "42", kind: .number)))
    XCTAssertTrue(tokens.contains(ReaderCodeToken(text: "// note", kind: .comment)))
    XCTAssertEqual(tokens.map(\.text).joined(), "let value: Article = \"reader\" + 42 // note")
  }

  func testLanguageSpecificCommentsAndKeywordsDoNotAlterSource() {
    let python = "def read():\n    return 1 # local"
    let pythonTokens = ReaderCodeSyntaxHighlighter.tokens(in: python, language: "python")
    XCTAssertTrue(pythonTokens.contains(ReaderCodeToken(text: "def", kind: .keyword)))
    XCTAssertTrue(pythonTokens.contains(ReaderCodeToken(text: "# local", kind: .comment)))
    XCTAssertEqual(pythonTokens.map(\.text).joined(), python)

    let sql = "SELECT value -- local"
    let sqlTokens = ReaderCodeSyntaxHighlighter.tokens(in: sql, language: "sql")
    XCTAssertTrue(sqlTokens.contains(ReaderCodeToken(text: "SELECT", kind: .keyword)))
    XCTAssertTrue(sqlTokens.contains(ReaderCodeToken(text: "-- local", kind: .comment)))
    XCTAssertEqual(sqlTokens.map(\.text).joined(), sql)
  }

  func testUnterminatedStringAndBlockCommentRemainBounded() {
    XCTAssertEqual(
      ReaderCodeSyntaxHighlighter.tokens(in: "\"unfinished", language: "swift"),
      [ReaderCodeToken(text: "\"unfinished", kind: .string)]
    )
    XCTAssertEqual(
      ReaderCodeSyntaxHighlighter.tokens(in: "/* unfinished", language: "swift"),
      [ReaderCodeToken(text: "/* unfinished", kind: .comment)]
    )
  }
}
