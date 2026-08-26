import XCTest

@testable import PublishingMarkdownCore

final class MarkdownSyntaxMarkerRangeServiceTests: XCTestCase {
  func testFindsSemanticMarkdownDelimitersInUTF16Coordinates() async throws {
    let markdown = "# **标题🙂** ~~deleted~~ `code` [site](https://example.com)"
    let parsedSnapshot = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(parsedSnapshot)
    let source = markdown as NSString

    let markers = MarkdownSyntaxMarkerRangeService.markerRanges(
      in: markdown,
      snapshot: snapshot
    )
    let values = markers.map { source.substring(with: $0) }

    XCTAssertTrue(values.contains("# "))
    XCTAssertEqual(values.filter { $0 == "**" }.count, 2)
    XCTAssertEqual(values.filter { $0 == "~~" }.count, 2)
    XCTAssertEqual(values.filter { $0 == "`" }.count, 2)
    XCTAssertTrue(values.contains("["))
    XCTAssertTrue(values.contains("](https://example.com)"))
  }

  func testKeepsMarkersVisibleForSyntaxRunTouchedByCaret() async throws {
    let markdown = "**first** and **second**"
    let parsedSnapshot = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(parsedSnapshot)
    let caret = NSRange(location: 4, length: 0)
    let source = markdown as NSString

    let markers = MarkdownSyntaxMarkerRangeService.markerRanges(
      in: markdown,
      snapshot: snapshot,
      activeSelection: caret
    )

    XCTAssertEqual(markers.map { source.substring(with: $0) }, ["**", "**"])
    XCTAssertTrue(markers.allSatisfy { $0.location > 10 })
  }

  func testProvidesNativePresentationsForListAndQuoteMarkers() async throws {
    let markdown = "- item\n  12. ordered\n> quote\n```swift\ncode\n```"
    let parsedSnapshot = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(parsedSnapshot)
    let source = markdown as NSString

    let markers = MarkdownSyntaxMarkerRangeService.markers(
      in: markdown,
      snapshot: snapshot
    )
    let values = markers.map { source.substring(with: $0.range) }

    XCTAssertEqual(values, ["- ", "12. ", "> ", "```swift", "```"])
    XCTAssertEqual(
      markers.map(\.presentation),
      [.unorderedList, .orderedList("12."), .quote, .hidden, .hidden]
    )
    XCTAssertFalse(values.contains("code"))
  }

  func testKeepsListAndQuoteSourceVisibleWhileCaretIsOnTheirLine() async throws {
    let markdown = "- first\n> second\n- third"
    let parsedSnapshot = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(parsedSnapshot)
    let source = markdown as NSString
    let caret = source.range(of: "second").location

    let markers = MarkdownSyntaxMarkerRangeService.markers(
      in: markdown,
      snapshot: snapshot,
      activeSelection: NSRange(location: caret, length: 0)
    )

    XCTAssertEqual(markers.map { source.substring(with: $0.range) }, ["- ", "- "])
    XCTAssertEqual(markers.map(\.presentation), [.unorderedList, .unorderedList])
  }

  func testProvidesNativeCheckboxesWithoutCollapsingNestedIndentation() async throws {
    let markdown = "- [ ] pending\n  - [x] nested done\n  - child\n- [q] ordinary item"
    let parsedSnapshot = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(parsedSnapshot)
    let source = markdown as NSString

    let markers = MarkdownSyntaxMarkerRangeService.markers(
      in: markdown,
      snapshot: snapshot
    )

    XCTAssertEqual(
      markers.map { source.substring(with: $0.range) },
      ["- [ ] ", "- [x] ", "- ", "- "]
    )
    XCTAssertEqual(
      markers.map(\.presentation),
      [
        .taskList(isChecked: false),
        .taskList(isChecked: true),
        .unorderedList,
        .unorderedList,
      ]
    )
    XCTAssertEqual(markers[1].range.location, source.range(of: "  - [x]").location + 2)
    XCTAssertEqual(markers[2].range.location, source.range(of: "  - child").location + 2)
  }

  func testKeepsTaskSourceVisibleWhileCaretIsOnTaskLine() async throws {
    let markdown = "- [ ] first\n- [x] second"
    let parsedSnapshot = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(parsedSnapshot)
    let source = markdown as NSString
    let caret = source.range(of: "first").location

    let markers = MarkdownSyntaxMarkerRangeService.markers(
      in: markdown,
      snapshot: snapshot,
      activeSelection: NSRange(location: caret, length: 0)
    )

    XCTAssertEqual(markers.map { source.substring(with: $0.range) }, ["- [x] "])
    XCTAssertEqual(markers.map(\.presentation), [.taskList(isChecked: true)])
  }

  func testCollapsesTildeFenceAndLeavesUnclosedBlockContentAlone() async throws {
    let markdown = "~~~javascript\nconst value = 1"
    let parsedSnapshot = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(parsedSnapshot)
    let source = markdown as NSString

    let values = MarkdownSyntaxMarkerRangeService.markerRanges(
      in: markdown,
      snapshot: snapshot
    ).map { source.substring(with: $0) }

    XCTAssertEqual(values, ["~~~javascript"])
  }

  func testKeepsCodeFencesVisibleWhileCaretIsInsideBlock() async throws {
    let markdown = "```swift\nlet value = 1\n```"
    let parsedSnapshot = await MarkdownSyntaxHighlightParser().snapshot(in: markdown)
    let snapshot = try XCTUnwrap(parsedSnapshot)
    let caret = (markdown as NSString).range(of: "value").location

    let markers = MarkdownSyntaxMarkerRangeService.markerRanges(
      in: markdown,
      snapshot: snapshot,
      activeSelection: NSRange(location: caret, length: 0)
    )

    XCTAssertTrue(markers.isEmpty)
  }
}
