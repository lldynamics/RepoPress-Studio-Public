import Foundation
@testable import PublishingMarkdownCore
import XCTest

final class MarkdownSyntaxHighlightAttributeApplierTests: XCTestCase {
  private let baseKey = NSAttributedString.Key("benchmark.base")
  private let styleKey = NSAttributedString.Key("benchmark.style")

  func testAppliesDefaultsAndKnownStyleRuns() {
    let storage = NSMutableAttributedString(string: "# Title\nBody")
    let snapshot = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 0, length: storage.length),
      runs: [
        MarkdownSyntaxHighlightRun(style: .heading, range: NSRange(location: 0, length: 7))
      ]
    )

    let appliedRunCount = MarkdownSyntaxHighlightAttributeApplier.apply(
      snapshot,
      to: storage,
      defaultAttributes: [baseKey: "base"],
      styleAttributes: [.heading: [styleKey: "heading"]]
    )

    XCTAssertEqual(appliedRunCount, 1)
    XCTAssertEqual(storage.attribute(baseKey, at: 8, effectiveRange: nil) as? String, "base")
    XCTAssertEqual(storage.attribute(styleKey, at: 2, effectiveRange: nil) as? String, "heading")
  }

  func testSkipsUnknownAndOutOfBoundsRunsWithoutMutatingOutsideSnapshot() {
    let storage = NSMutableAttributedString(string: "0123456789")
    storage.addAttribute(baseKey, value: "preserved", range: NSRange(location: 0, length: 2))
    let snapshot = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 2, length: 6),
      runs: [
        MarkdownSyntaxHighlightRun(style: .heading, range: NSRange(location: 2, length: 2)),
        MarkdownSyntaxHighlightRun(style: .link, range: NSRange(location: 4, length: 2)),
        MarkdownSyntaxHighlightRun(style: .heading, range: NSRange(location: 7, length: 2))
      ]
    )

    let appliedRunCount = MarkdownSyntaxHighlightAttributeApplier.apply(
      snapshot,
      to: storage,
      defaultAttributes: [baseKey: "base"],
      styleAttributes: [.heading: [styleKey: "heading"]]
    )

    XCTAssertEqual(appliedRunCount, 1)
    XCTAssertEqual(storage.attribute(baseKey, at: 0, effectiveRange: nil) as? String, "preserved")
    XCTAssertEqual(storage.attribute(styleKey, at: 2, effectiveRange: nil) as? String, "heading")
    XCTAssertNil(storage.attribute(styleKey, at: 7, effectiveRange: nil))
  }

  func testRejectsSnapshotOutsideStorage() {
    let storage = NSMutableAttributedString(string: "Body")
    let snapshot = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 0, length: 5),
      runs: []
    )

    let appliedRunCount = MarkdownSyntaxHighlightAttributeApplier.apply(
      snapshot,
      to: storage,
      defaultAttributes: [baseKey: "base"],
      styleAttributes: [:]
    )

    XCTAssertEqual(appliedRunCount, 0)
    XCTAssertNil(storage.attribute(baseKey, at: 0, effectiveRange: nil))
  }

}
