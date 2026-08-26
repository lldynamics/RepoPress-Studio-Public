import Foundation
import XCTest

@testable import PublishingAICore

final class AIPublishingChatParagraphServiceTests: XCTestCase {
  func testDraftParagraphParserExtractsStableParagraphs() throws {
    let markdown = """
    # 第一段标题
    第一段正文。

    > 第二段引用
    继续说明内容。
    """

    let paragraphs = AIPublishingChatDraftParagraphParser.extract(from: markdown)

    XCTAssertEqual(paragraphs.count, 2)
    XCTAssertEqual(paragraphs[0].title, "第一段标题")
    XCTAssertEqual(paragraphs[1].title, "第二段引用")

    for paragraph in paragraphs {
      let range = try XCTUnwrap(Range(paragraph.range, in: markdown))
      XCTAssertEqual(
        String(markdown[range]).trimmingCharacters(in: .whitespacesAndNewlines),
        paragraph.text
      )
    }
  }

  func testDraftParagraphParserSkipsShortBlocksAndCapsResults() {
    let markdown = (["短"] + (0..<45).map { index in
      "段落 \(index + 1) 内容足够长"
    })
    .joined(separator: "\n\n")

    let paragraphs = AIPublishingChatDraftParagraphParser.extract(from: markdown)

    XCTAssertEqual(paragraphs.count, 40)
    XCTAssertEqual(paragraphs.first?.title, "段落 1 内容足够长")
    XCTAssertEqual(paragraphs.last?.title, "段落 40 内容足够长")
    XCTAssertFalse(paragraphs.contains { $0.text == "短" })
  }
}
