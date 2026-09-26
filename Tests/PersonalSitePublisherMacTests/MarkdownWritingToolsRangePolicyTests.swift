import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownWritingToolsRangePolicyTests: XCTestCase {
  func testProtectsFrontMatterAndCodeWhileLeavingProseAvailable() {
    let frontMatter = "---\ntitle: Example\n---\n"
    let document =
      frontMatter + "A paragraph 📝 with `literal` text.\n\n```swift\nlet x = 1\n```\nAfter."
    let source = document as NSString
    let ranges = MarkdownWritingToolsRangePolicy.ignoredRanges(
      in: document,
      bodyUTF16Offset: (frontMatter as NSString).length,
      enclosingRange: NSRange(location: 0, length: source.length)
    )

    XCTAssertTrue(ranges.contains { NSLocationInRange(source.range(of: "title:").location, $0) })
    XCTAssertTrue(ranges.contains { NSLocationInRange(source.range(of: "literal").location, $0) })
    XCTAssertTrue(ranges.contains { NSLocationInRange(source.range(of: "let x").location, $0) })
    XCTAssertFalse(
      ranges.contains { NSLocationInRange(source.range(of: "paragraph").location, $0) })
    XCTAssertFalse(ranges.contains { NSLocationInRange(source.range(of: "After.").location, $0) })
  }

  func testClipsProtectedRangeToWritingToolsEnclosingRange() {
    let document = "Outside\n```\ncode 📝\n```\nOutside"
    let source = document as NSString
    let codeRange = source.range(of: "code 📝")
    let ranges = MarkdownWritingToolsRangePolicy.ignoredRanges(
      in: document,
      bodyUTF16Offset: 0,
      enclosingRange: codeRange
    )

    XCTAssertEqual(ranges, [codeRange])
  }

  func testRejectsInvalidEnclosingRange() {
    XCTAssertEqual(
      MarkdownWritingToolsRangePolicy.ignoredRanges(
        in: "Text",
        bodyUTF16Offset: 0,
        enclosingRange: NSRange(location: 5, length: 1)
      ),
      []
    )
  }

  func testUnclosedFenceKeepsFollowingSourceProtected() {
    let document = "Intro\n~~~swift\nlet token = \"private\"\n"
    let source = document as NSString
    let ranges = MarkdownWritingToolsRangePolicy.ignoredRanges(
      in: document,
      bodyUTF16Offset: 0,
      enclosingRange: NSRange(location: 0, length: source.length)
    )

    XCTAssertFalse(ranges.contains { NSLocationInRange(source.range(of: "Intro").location, $0) })
    XCTAssertTrue(ranges.contains { NSLocationInRange(source.range(of: "token").location, $0) })
  }
}
