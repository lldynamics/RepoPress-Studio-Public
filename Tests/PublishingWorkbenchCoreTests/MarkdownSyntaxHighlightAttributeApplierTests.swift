import Foundation
@testable import PublishingWorkbenchCore
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

  func testApplicationPlannerPrioritizesVisibleRangeAndCoversSnapshotOnce() {
    let snapshotRange = NSRange(location: 100, length: 30_000)
    let visibleRange = NSRange(location: 12_000, length: 3_000)
    let chunks = MarkdownSyntaxHighlightApplicationPlanner.chunks(
      in: snapshotRange,
      prioritizing: visibleRange,
      maximumChunkUTF16Length: 8_192
    )

    XCTAssertEqual(chunks.first, visibleRange)
    XCTAssertTrue(chunks.allSatisfy { $0.length <= 8_192 })
    XCTAssertEqual(chunks.reduce(0) { $0 + $1.length }, snapshotRange.length)

    let locationSorted = chunks.sorted { $0.location < $1.location }
    var expectedLocation = snapshotRange.location
    for chunk in locationSorted {
      XCTAssertEqual(chunk.location, expectedLocation)
      expectedLocation = NSMaxRange(chunk)
    }
    XCTAssertEqual(expectedLocation, NSMaxRange(snapshotRange))

    let applicationSnapshots = chunks.map {
      MarkdownSyntaxHighlightSnapshot(range: $0, runs: [])
    }
    let scrolledRange = NSRange(location: 28_000, length: 1_000)
    let reprioritized = MarkdownSyntaxHighlightApplicationPlanner.prioritizing(
      applicationSnapshots,
      around: scrolledRange
    )
    XCTAssertNotNil(reprioritized.first)
    if let first = reprioritized.first {
      XCTAssertGreaterThan(
        NSIntersectionRange(first.range, scrolledRange).length,
        0
      )
    }
    XCTAssertEqual(
      reprioritized.map(\.range).sorted { $0.location < $1.location },
      locationSorted
    )
  }

  func testChunkedApplicationMatchesSinglePassAcrossRunBoundaries() {
    let text = String(repeating: "x", count: 24)
    let snapshot = MarkdownSyntaxHighlightSnapshot(
      range: NSRange(location: 0, length: 24),
      runs: [
        MarkdownSyntaxHighlightRun(
          style: .heading,
          range: NSRange(location: 6, length: 12)
        )
      ]
    )
    let singlePass = NSMutableAttributedString(string: text)
    let chunked = NSMutableAttributedString(string: text)
    let defaultAttributes = [baseKey: "base"]
    let styleAttributes: [MarkdownSyntaxHighlightStyle: [NSAttributedString.Key: Any]] = [
      .heading: [styleKey: "heading"]
    ]

    MarkdownSyntaxHighlightAttributeApplier.apply(
      snapshot,
      to: singlePass,
      defaultAttributes: defaultAttributes,
      styleAttributes: styleAttributes
    )
    let applicationSnapshots = MarkdownSyntaxHighlightApplicationPlanner.applicationSnapshots(
      for: snapshot,
      prioritizing: NSRange(location: 8, length: 4),
      maximumChunkUTF16Length: 5
    )
    for applicationSnapshot in applicationSnapshots {
      MarkdownSyntaxHighlightAttributeApplier.apply(
        applicationSnapshot,
        to: chunked,
        defaultAttributes: defaultAttributes,
        styleAttributes: styleAttributes
      )
    }

    XCTAssertEqual(chunked, singlePass)
  }
}
