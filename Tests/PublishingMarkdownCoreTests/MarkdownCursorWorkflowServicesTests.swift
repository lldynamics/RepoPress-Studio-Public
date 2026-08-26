import Foundation
import XCTest

@testable import PublishingMarkdownCore

final class MarkdownCursorWorkflowServicesTests: XCTestCase {
  func testSlashCompletionExposesFourRequiredCommandsAndStaleGuard() throws {
    let service = MarkdownCursorCompletionService()
    let all = try XCTUnwrap(
      service.completion(
        in: "/",
        selectedRange: NSRange(location: 1, length: 0)
      )
    )
    XCTAssertEqual(
      Set(all.candidates.map(\.id)),
      Set(["slash-table", "slash-code", "slash-image", "slash-footnote"])
    )

    let source = "/表"
    let tableContext = try XCTUnwrap(
      service.completion(
        in: source,
        selectedRange: NSRange(location: (source as NSString).length, length: 0)
      )
    )
    let table = try XCTUnwrap(tableContext.candidates.first { $0.id == "slash-table" })
    let edit = try XCTUnwrap(service.edit(applying: table, in: source))
    XCTAssertTrue(edit.replacement.hasPrefix("| 列 1 |"))
    XCTAssertEqual(
      (edit.replacement as NSString).substring(
        with: NSRange(
          location: edit.selectedRange.location - edit.replacedRange.location,
          length: edit.selectedRange.length
        )
      ),
      "列 1"
    )
    XCTAssertNil(service.edit(applying: table, in: "/不同"))
  }

  func testFootnoteCompletionChoosesUnusedNumericIdentifier() throws {
    let markdown = "已有[^2]\n\n/脚注"
    let service = MarkdownCursorCompletionService()
    let context = try XCTUnwrap(
      service.completion(
        in: markdown,
        selectedRange: NSRange(location: (markdown as NSString).length, length: 0)
      )
    )
    let candidate = try XCTUnwrap(context.candidates.first)
    XCTAssertTrue(candidate.replacement.contains("[^3]"))
    XCTAssertTrue(candidate.replacement.contains("[^3]:"))
  }

  func testInternalLinkCompletionHandlesOpenAndClosedWikiSyntax() throws {
    let article = MarkdownCompletionArticle(
      id: UUID(),
      title: "发布流程",
      slug: "publish-flow",
      destination: "/posts/publish-flow/"
    )
    let service = MarkdownCursorCompletionService()
    let openSource = "参见 [[发]]"
    let closingLocation = (openSource as NSString).range(of: "]]").location
    let openContext = try XCTUnwrap(
      service.completion(
        in: openSource,
        selectedRange: NSRange(location: closingLocation, length: 0),
        articles: [article]
      )
    )
    let candidate = try XCTUnwrap(openContext.candidates.first)
    XCTAssertEqual(candidate.expectedText, "[[发]]")
    let edit = try XCTUnwrap(service.edit(applying: candidate, in: openSource))
    let replaced = (openSource as NSString).replacingCharacters(
      in: edit.replacedRange,
      with: edit.replacement
    )
    XCTAssertEqual(replaced, "参见 [发布流程](/posts/publish-flow/)")

    let closedSource = "参见 [[发布流程]]"
    let closed = try XCTUnwrap(
      service.completion(
        in: closedSource,
        selectedRange: NSRange(location: (closedSource as NSString).length, length: 0),
        articles: [article]
      )
    )
    XCTAssertEqual(closed.query, "发布流程")
  }

  func testCodeLanguageCompletionAndCodeBlockSuppression() throws {
    let markdown = "```sw\nlet value = 1\n```"
    let cursor = (markdown as NSString).range(of: "sw").upperBound
    let service = MarkdownCursorCompletionService()
    let context = try XCTUnwrap(
      service.completion(
        in: markdown,
        selectedRange: NSRange(location: cursor, length: 0)
      )
    )
    XCTAssertEqual(context.kind, .codeLanguage)
    let swift = try XCTUnwrap(context.candidates.first { $0.id == "language-swift" })
    let edit = try XCTUnwrap(service.edit(applying: swift, in: markdown))
    XCTAssertEqual(
      (markdown as NSString).replacingCharacters(in: edit.replacedRange, with: edit.replacement),
      "```swift\nlet value = 1\n```"
    )

    let slashInsideFence = "```\n/表格\n```"
    let slashCursor = (slashInsideFence as NSString).range(of: "/表格").upperBound
    XCTAssertNil(
      service.completion(
        in: slashInsideFence,
        selectedRange: NSRange(location: slashCursor, length: 0)
      )
    )
  }

  func testCursorPositionUsesGraphemeColumnAndTracksUTF16Column() throws {
    let markdown = "😀a\r\n二\n"
    let service = MarkdownCursorContextService()
    let lines = service.lineLocations(in: markdown)
    XCTAssertEqual(lines.count, 3)
    XCTAssertEqual(lines.map(\.lineNumber), [1, 2, 3])

    let position = try XCTUnwrap(
      service.position(
        in: markdown,
        selectedRange: NSRange(location: 2, length: 0)
      )
    )
    XCTAssertEqual(position.line, 1)
    XCTAssertEqual(position.column, 2)
    XCTAssertEqual(position.utf16Column, 3)

    let lineTwoEnd = try XCTUnwrap(
      service.jumpTarget(in: markdown, line: 2, column: 2)
    )
    XCTAssertEqual(lineTwoEnd.location, lines[1].contentRange.location + 1)
    XCTAssertNil(service.jumpTarget(in: markdown, line: 4))
  }

  func testFenceMatchingReturnsCounterpartAndUnclosedState() throws {
    let markdown = "正文\n```swift\nlet value = 1\n````   \n结尾"
    let service = MarkdownCursorContextService()
    let match = try XCTUnwrap(service.fenceMatches(in: markdown).first)
    XCTAssertEqual(match.marker, "`")
    XCTAssertEqual(match.markerLength, 3)
    XCTAssertEqual(match.languageHint, "swift")
    XCTAssertEqual(match.openingLine, 2)
    XCTAssertEqual(match.closingLine, 4)
    XCTAssertEqual(match.closingMarkerRange?.length, 4)
    XCTAssertTrue(match.isClosed)
    XCTAssertEqual(
      service.counterpartFenceMarkerRange(
        in: markdown,
        cursorLocation: match.openingMarkerRange.location
      ),
      match.closingMarkerRange
    )

    let unclosed = try XCTUnwrap(
      service.fenceMatches(in: "~~~yaml\nvalue: true").first
    )
    XCTAssertFalse(unclosed.isClosed)
    XCTAssertNil(unclosed.closingLine)
  }
}

extension NSRange {
  var upperBound: Int {
    NSMaxRange(self)
  }
}
