import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeContextQueryServiceTests: XCTestCase {
  func testQueryUsesMetadataAndHeadings() {
    let input = KnowledgeContextQueryInput(
      title: "React Server Components 实践",
      summary: "整理服务端组件的边界与数据流。",
      tags: ["React", "架构"],
      bodyMarkdown: """
      # React Server Components

      ## 数据获取

      这里讨论服务端渲染、客户端边界和缓存策略。
      """
    )

    let query = KnowledgeContextQueryService.query(
      input: input,
      maximumCharacters: 600
    )

    XCTAssertTrue(query.contains("标题：React Server Components 实践"))
    XCTAssertTrue(query.contains("摘要：整理服务端组件的边界与数据流。"))
    XCTAssertTrue(query.contains("标签：React、架构"))
    XCTAssertTrue(query.contains("章节：# React Server Components、## 数据获取"))
    XCTAssertTrue(query.contains("服务端渲染、客户端边界和缓存策略"))
  }

  func testQueryPrioritizesParagraphAtCaret() {
    let bodyMarkdown = """
    第一段讨论导入流程和资料整理。

    第二段讨论本地语义索引和向量检索。
    """
    let caret = (bodyMarkdown as NSString).range(of: "向量检索").location
    let input = KnowledgeContextQueryInput(
      title: "段落上下文",
      summary: "",
      tags: [],
      bodyMarkdown: bodyMarkdown
    )

    let query = KnowledgeContextQueryService.query(
      input: input,
      selectedRange: NSRange(location: caret, length: 0)
    )

    XCTAssertTrue(query.contains("当前段落：第二段讨论本地语义索引和向量检索。"))
  }

  func testQueryUsesBodySuppliedByEditorProjection() {
    let input = KnowledgeContextQueryInput(
      title: "实时编辑",
      summary: "",
      tags: [],
      bodyMarkdown: "## 尚未持久化\n\n这是编辑器中的实时正文。"
    )

    let query = KnowledgeContextQueryService.query(input: input)

    XCTAssertTrue(query.contains("章节：## 尚未持久化"))
    XCTAssertTrue(query.contains("这是编辑器中的实时正文。"))
  }

  func testLongDocumentQueryKeepsBoundedEdgesAndCaretParagraph() {
    let middle = String(
      repeating: "稳定正文段落用于验证长文档不会被整篇规范化。\n\n",
      count: 4_000
    )
    let caretParagraph = "尾部段落包含光标目标 🚀 与本地检索线索。"
    let bodyMarkdown = "# 有界查询\n\n开头上下文。\n\n\(middle)\(caretParagraph)\n\n结尾上下文。"
    let caret = (bodyMarkdown as NSString).range(of: "光标目标").location

    let query = KnowledgeContextQueryService.query(
      input: KnowledgeContextQueryInput(
        title: "十万字测试",
        summary: "",
        tags: [],
        bodyMarkdown: bodyMarkdown
      ),
      selectedRange: NSRange(location: caret, length: 0),
      maximumCharacters: 600
    )

    XCTAssertTrue(query.contains("章节：# 有界查询"))
    XCTAssertTrue(query.contains("当前段落：\(caretParagraph)"))
    XCTAssertTrue(query.contains("开头上下文"))
    XCTAssertTrue(query.contains("结尾上下文"))
    XCTAssertLessThan(query.count, 2_500)
  }

  func testCurrentParagraphUsesUTF16CaretAcrossCRLFAndEmoji() {
    let bodyMarkdown = "第一段🙂\r\n\r\n第二段包含目标🚀与内容。\r\n\r\n第三段"
    let caret = (bodyMarkdown as NSString).range(of: "目标🚀").location

    XCTAssertEqual(
      KnowledgeContextQueryService.currentParagraph(
        in: bodyMarkdown,
        selectedRange: NSRange(location: caret, length: 0)
      ),
      "第二段包含目标🚀与内容。"
    )
  }
}
