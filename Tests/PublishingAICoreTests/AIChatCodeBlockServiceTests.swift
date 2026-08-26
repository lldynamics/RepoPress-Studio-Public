import Foundation
import XCTest
@testable import PublishingAICore

final class AIChatCodeBlockServiceTests: XCTestCase {
  func testSegmentsKeepSurroundingTextAndLanguage() {
    let markdown = "前文\n\n```swift\nlet title = \"你好\"\n```\n\n后文"

    let segments = AIChatCodeBlockPresentationService.segments(in: markdown)

    XCTAssertEqual(segments.count, 3)
    guard case let .text(_, leading) = segments[0],
          case let .code(block) = segments[1],
          case let .text(_, trailing) = segments[2] else {
      return XCTFail("expected text, code, text segments")
    }
    XCTAssertEqual(leading, "前文\n\n")
    XCTAssertEqual(block.language, "swift")
    XCTAssertEqual(block.content, "let title = \"你好\"")
    XCTAssertEqual(block.fencedMarkdown, "```swift\nlet title = \"你好\"\n```")
    XCTAssertEqual(trailing, "\n后文")
  }

  func testUnclosedFenceRemainsReadableText() {
    let markdown = "说明\n```json\n{\"ready\": true}"

    let segments = AIChatCodeBlockPresentationService.segments(in: markdown)

    XCTAssertEqual(segments.count, 1)
    guard case let .text(_, text) = segments[0] else {
      return XCTFail("an unclosed fence should not become an action card")
    }
    XCTAssertEqual(text, markdown)
  }

  func testApplyReplacesSelectionAndKeepsMarkdownFence() {
    let body = "标题\n旧内容\n结尾"
    let bodyNSString = body as NSString
    let selection = bodyNSString.range(of: "旧内容")
    let fragment = "```swift\nlet value = 1\n```"

    let result = AIChatMarkdownInsertionService.inserting(
      fragment,
      into: body,
      selection: selection,
      mode: .applyToCurrentEditor
    )

    XCTAssertEqual(
      result?.updatedBodyMarkdown,
      "标题\n```swift\nlet value = 1\n```\n结尾"
    )
    XCTAssertEqual(
      result?.insertedRange,
      NSRange(location: "标题\n```swift\nlet value = 1\n```".utf16.count, length: 0)
    )
  }

  func testInsertAtCursorPreservesSelectedText() {
    let body = "开头\n选中的文字\n结尾"
    let bodyNSString = body as NSString
    let selection = bodyNSString.range(of: "选中的文字")
    let fragment = "```\n参考\n```"

    let result = AIChatMarkdownInsertionService.inserting(
      fragment,
      into: body,
      selection: selection,
      mode: .insertAtCursor
    )

    XCTAssertEqual(
      result?.updatedBodyMarkdown,
      "开头\n```\n参考\n```\n\n选中的文字\n结尾"
    )
    XCTAssertTrue(result?.updatedBodyMarkdown.contains("选中的文字") == true)
  }
}
