import Foundation
import XCTest

@testable import PersonalSitePublisherMac

final class MarkdownTextEditInferenceTests: XCTestCase {
  func testInfersInsertedRangeFromStablePrefixAndSuffix() throws {
    let edit = try XCTUnwrap(
      MarkdownTextEdit.inferred(
        previousText: "before\nafter",
        currentText: "before\nnew after"
      )
    )

    XCTAssertEqual(edit.previousText, "before\nafter")
    XCTAssertEqual(edit.replacedRange, NSRange(location: 7, length: 0))
  }

  func testInferenceDoesNotSplitUTF16SurrogatePair() throws {
    let edit = try XCTUnwrap(
      MarkdownTextEdit.inferred(
        previousText: "a😀b",
        currentText: "a🚀b"
      )
    )

    XCTAssertEqual(edit.replacedRange, NSRange(location: 1, length: 2))
  }

  func testUnchangedTextHasNoInferredEdit() {
    XCTAssertNil(
      MarkdownTextEdit.inferred(previousText: "unchanged", currentText: "unchanged")
    )
  }
}
