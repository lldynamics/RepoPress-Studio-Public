import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeDocumentBlockParserTests: XCTestCase {
  func testParserSeparatesSemanticHeadingsParagraphsAndStructuredBlocks() {
    let blocks = KnowledgeDocumentBlockParser().blocks(in: """
    # 第一章

    第一段包含 **强调**。
    仍属于第一段。

    ## 第二节

    [第 12 页]

    > 一条引用
    > 引用的第二行

    - 无序项目
    2. 有序项目

    ```swift
    let answer = 42
    ```
    """)

    XCTAssertEqual(blocks.map(\.kind), [
      .heading(level: 1),
      .paragraph,
      .heading(level: 2),
      .locator,
      .quote,
      .unorderedListItem,
      .orderedListItem(number: 2),
      .code(language: "swift"),
    ])
    XCTAssertEqual(blocks[0].text, "第一章")
    XCTAssertEqual(blocks[1].text, "第一段包含 **强调**。\n仍属于第一段。")
    XCTAssertEqual(blocks[3].text, "第 12 页")
    XCTAssertEqual(blocks[4].text, "一条引用\n引用的第二行")
    XCTAssertEqual(blocks[7].text, "let answer = 42")
    XCTAssertEqual(blocks.map(\.id), Array(blocks.indices))
  }

  func testParserKeepsSeparateParagraphsAsSeparateAccessibilityNodes() {
    let blocks = KnowledgeDocumentBlockParser().blocks(in: """
    第一段。

    第二段。

    第三段。
    """)

    XCTAssertEqual(blocks.count, 3)
    XCTAssertTrue(blocks.allSatisfy { $0.kind == .paragraph })
    XCTAssertEqual(blocks.map(\.text), ["第一段。", "第二段。", "第三段。"])
  }

  func testUnclosedCodeFenceStillProducesCodeBlock() {
    let blocks = KnowledgeDocumentBlockParser().blocks(in: """
    ```text
    incomplete but readable
    """)

    XCTAssertEqual(blocks, [
      KnowledgeDocumentBlock(
        id: 0,
        kind: .code(language: "text"),
        text: "incomplete but readable"
      ),
    ])
  }
}
