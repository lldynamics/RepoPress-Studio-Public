import XCTest

@testable import PublishingMarkdownCore

final class ChineseTypographyFormattingServiceTests: XCTestCase {
  private let service = ChineseTypographyFormattingService()

  func testInsertsSpacesBetweenChineseAndLatinWords() {
    let input = "使用Mac版编辑器开发Swift应用"
    let expected = "使用 Mac 版编辑器开发 Swift 应用"
    XCTAssertEqual(service.formattedText(for: input), expected)
  }

  func testInsertsSpacesBetweenChineseAndDigits() {
    let input = "在2026年共完成100篇博客"
    let expected = "在 2026 年共完成 100 篇博客"
    XCTAssertEqual(service.formattedText(for: input), expected)
  }

  func testCleansSpacesAroundFullWidthPunctuation() {
    let input = "你好 ， 世界 ！ 这是 《 Swift 进阶 》 。"
    let expected = "你好，世界！这是《Swift 进阶》。"
    XCTAssertEqual(service.formattedText(for: input), expected)
  }

  func testPreservesFrontMatter() {
    let input = """
    ---
    title: 我的Swift6博客
    date: 2026-08-15
    tags: [Swift, Mac]
    ---
    欢迎阅读这篇Blog文章。
    """
    let expected = """
    ---
    title: 我的Swift6博客
    date: 2026-08-15
    tags: [Swift, Mac]
    ---
    欢迎阅读这篇 Blog 文章。
    """
    XCTAssertEqual(service.formattedText(for: input), expected)
  }

  func testPreservesFencedCodeBlocks() {
    let input = """
    这是正文Swift代码介绍：

    ```swift
    let myVariable = "无需空格中文Chinese"
    ```

    代码块外部的Swift代码需要空格。
    """
    let expected = """
    这是正文 Swift 代码介绍：

    ```swift
    let myVariable = "无需空格中文Chinese"
    ```

    代码块外部的 Swift 代码需要空格。
    """
    XCTAssertEqual(service.formattedText(for: input), expected)
  }

  func testPreservesInlineCodeAndLinkURLs() {
    let input = "请访问 [Apple官网](https://apple.com/cn/mac) 查看 `let x = 1` 代码。"
    let expected = "请访问 [Apple 官网](https://apple.com/cn/mac) 查看 `let x = 1` 代码。"
    XCTAssertEqual(service.formattedText(for: input), expected)
  }

  func testCollapsesExcessConsecutiveNewlines() {
    let input = "第一段\n\n\n\n\n第二段"
    let expected = "第一段\n\n第二段"
    XCTAssertEqual(service.formattedText(for: input), expected)
  }
}
