import Foundation
import XCTest
@testable import PublishingMarkdownCore

final class MarkdownInlineAIContextServiceTests: XCTestCase {
  private let service = MarkdownInlineAIContextService()

  func testContextIsCursorScopedAndBoundedByUTF16Length() {
    let markdown = "前文\n你好世界\n最后一行"
    let cursor = ("前文\n你好世界\n最后" as NSString).length

    XCTAssertEqual(
      service.context(in: markdown, cursorUTF16Location: cursor, maximumUTF16Length: 5),
      "世界\n最后"
    )
    XCTAssertNil(service.context(in: markdown, cursorUTF16Location: 0))
    XCTAssertNil(service.context(in: markdown, cursorUTF16Location: -1))
  }

  func testNormalizedContinuationRemovesOnlyOuterNewlinesAndCapsLength() {
    XCTAssertEqual(
      service.normalizedContinuation("\n  下一句。\n\n", maximumUTF16Length: 4),
      "  下一"
    )
    XCTAssertNil(service.normalizedContinuation("\n  \n"))
  }

  func testContextNeverReturnsPartialComposedCharacters() {
    let markdown = "前😀后"
    let cursorAfterEmoji = ("前😀" as NSString).length

    XCTAssertEqual(
      service.context(
        in: markdown,
        cursorUTF16Location: cursorAfterEmoji,
        maximumUTF16Length: 2
      ),
      "😀"
    )
    XCTAssertNil(
      service.context(
        in: markdown,
        cursorUTF16Location: cursorAfterEmoji,
        maximumUTF16Length: 1
      )
    )
    XCTAssertEqual(
      service.context(in: markdown, cursorUTF16Location: 2),
      "前"
    )
  }

  func testNormalizedContinuationTruncatesAtComposedCharacterBoundary() {
    XCTAssertEqual(
      service.normalizedContinuation("a😀b", maximumUTF16Length: 2),
      "a"
    )
    XCTAssertEqual(
      service.normalizedContinuation("a😀b", maximumUTF16Length: 3),
      "a😀"
    )
    XCTAssertEqual(
      service.normalizedContinuation("e\u{301}x", maximumUTF16Length: 2),
      "e\u{301}"
    )
    XCTAssertNil(service.normalizedContinuation("😀", maximumUTF16Length: 1))
  }
}
