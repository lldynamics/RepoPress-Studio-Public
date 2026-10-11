import PublishingDomainContracts
import XCTest

@testable import PublishingWorkbenchCore

final class DraftVersionAlignedDiffTests: XCTestCase {
  private let service = DraftVersionComparisonService()

  func testIdenticalBodyKeepsAllAlignedLinesWithoutChangingLegacyDiff() {
    let body = "\n相同正文\n"
    let comparison = compare(body, body)

    XCTAssertFalse(comparison.hasChanges)
    XCTAssertTrue(comparison.bodyLineDiffs.isEmpty)
    XCTAssertEqual(comparison.alignedBodyRows.count, 3)
    XCTAssertEqual(comparison.alignedBodyRows.map(\.id), [0, 1, 2])
    XCTAssertTrue(comparison.alignedBodyRows.allSatisfy { !$0.hasChanges })
    XCTAssertEqual(comparison.alignedBodyRows.compactMap { $0.previous?.lineNumber }, [1, 2, 3])
    XCTAssertEqual(comparison.alignedBodyRows.compactMap { $0.current?.lineNumber }, [1, 2, 3])
    assertReconstruction(comparison, previous: body, current: body)
  }

  func testInsertionBeforeReplacementDoesNotStealItsAlignedParagraph() {
    let previous = "开头\n原有段落的主题是保留自己的时间。\n结尾"
    let current = "开头\n额外插入的独立引言。\n原有段落的主题是保留自己的空闲时间。\n结尾"
    let comparison = compare(previous, current)
    let changes = comparison.alignedBodyRows.filter(\.hasChanges)

    XCTAssertEqual(changes.count, 2)
    XCTAssertNil(changes[0].previous)
    XCTAssertEqual(changes[0].current?.text, "额外插入的独立引言。")
    XCTAssertEqual(changes[1].previous?.lineNumber, 2)
    XCTAssertEqual(changes[1].current?.lineNumber, 3)
    XCTAssertEqual(changes[1].previous?.kind, .removed)
    XCTAssertEqual(changes[1].current?.kind, .added)
    XCTAssertEqual(comparison.removedLineCount, 1)
    XCTAssertEqual(comparison.addedLineCount, 2)
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testDeletionBeforeReplacementKeepsOneSidedRow() {
    let previous = "开头\n可以删除的独立介绍。\n原有段落的主题是保留自己的时间。\n结尾"
    let current = "开头\n原有段落的主题是保留自己的空闲时间。\n结尾"
    let comparison = compare(previous, current)
    let changes = comparison.alignedBodyRows.filter(\.hasChanges)

    XCTAssertEqual(changes.count, 2)
    XCTAssertEqual(changes[0].previous?.text, "可以删除的独立介绍。")
    XCTAssertNil(changes[0].current)
    XCTAssertEqual(changes[1].previous?.lineNumber, 3)
    XCTAssertEqual(changes[1].current?.lineNumber, 2)
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testPureAdditionAndRemovalHaveEmptyOpposingSide() {
    let added = compare("开头\n结尾", "开头\n新增\n结尾")
    let addedRow = added.alignedBodyRows.first { $0.hasChanges }
    XCTAssertNil(addedRow?.previous)
    XCTAssertEqual(
      addedRow?.current?.segments, [DraftVersionTextSegment(text: "新增", isChanged: true)])

    let removed = compare("开头\n删除\n结尾", "开头\n结尾")
    let removedRow = removed.alignedBodyRows.first { $0.hasChanges }
    XCTAssertNil(removedRow?.current)
    XCTAssertEqual(
      removedRow?.previous?.segments, [DraftVersionTextSegment(text: "删除", isChanged: true)])
  }

  func testCJKInlineChangeIsLocalized() {
    let previous = "我想把额度用满，也想留时间。"
    let current = "我想把额度用好，也想留时间。"
    let comparison = compare(previous, current)
    let row = comparison.alignedBodyRows[0]

    XCTAssertEqual(row.previous?.segments.filter(\.isChanged).map(\.text), ["满"])
    XCTAssertEqual(row.current?.segments.filter(\.isChanged).map(\.text), ["好"])
    XCTAssertEqual(row.previous?.segments.first?.text, "我想把额度用")
    XCTAssertEqual(row.current?.segments.last?.text, "，也想留时间。")
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testMultipleEnglishInlineChangesRetainUnchangedMiddle() {
    let previous = "Build fast, ship safely."
    let current = "Build slow, ship calmly."
    let comparison = compare(previous, current)
    let row = comparison.alignedBodyRows[0]

    XCTAssertTrue(
      row.previous?.segments.contains { !$0.isChanged && $0.text.contains(", ship ") } == true)
    XCTAssertTrue(
      row.current?.segments.contains { !$0.isChanged && $0.text.contains(", ship ") } == true)
    XCTAssertGreaterThan(row.previous?.segments.filter(\.isChanged).count ?? 0, 1)
    XCTAssertGreaterThan(row.current?.segments.filter(\.isChanged).count ?? 0, 1)
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testCombiningAccentsAndJoinedEmojiRemainWholeGraphemes() {
    let previous = "Cafe\u{301} 👩🏽‍💻 保留"
    let current = "Cafe\u{301} 🧑🏽‍🔬 保留"
    let comparison = compare(previous, current)
    let row = comparison.alignedBodyRows[0]

    XCTAssertEqual(row.previous?.segments.filter(\.isChanged).map(\.text), ["👩🏽‍💻"])
    XCTAssertEqual(row.current?.segments.filter(\.isChanged).map(\.text), ["🧑🏽‍🔬"])
    XCTAssertEqual(row.previous?.segments.first?.text, "Cafe\u{301} ")
    XCTAssertEqual(row.current?.segments.first?.text, "Cafe\u{301} ")
    XCTAssertEqual(row.previous?.segments.filter(\.isChanged).first?.text.count, 1)
    XCTAssertEqual(row.current?.segments.filter(\.isChanged).first?.text.count, 1)
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testHugeLineUsesBoundedMiddleFallbackAndRetainsPrefixSuffix() {
    let previous =
      "prefix " + String(repeating: "甲", count: 6_000)
      + " stable " + String(repeating: "乙", count: 6_000) + " suffix"
    let current =
      "prefix " + String(repeating: "丙", count: 6_000)
      + " stable " + String(repeating: "丁", count: 6_000) + " suffix"
    let comparison = compare(previous, current)
    let row = comparison.alignedBodyRows[0]

    XCTAssertEqual(row.previous?.segments.count, 3)
    XCTAssertEqual(row.current?.segments.count, 3)
    XCTAssertEqual(
      row.previous?.segments.first, DraftVersionTextSegment(text: "prefix ", isChanged: false))
    XCTAssertEqual(
      row.current?.segments.last, DraftVersionTextSegment(text: " suffix", isChanged: false))
    XCTAssertTrue(row.previous?.segments[1].isChanged == true)
    XCTAssertTrue(row.current?.segments[1].isChanged == true)
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testCRLFParagraphReplacementAndInsertionAlignAndReconstructExactly() {
    let previous = "第一段：具体项目。\r\n\r\n第二段：额度有剩余。\r\n\r\n第三段：保留时间。\r\n"
    let current = "第一段：具体项目。\r\n\r\n第二段：额度还有很多剩余。\r\n\r\n新增段：更想知道自己要做什么。\r\n\r\n第三段：保留时间。\r\n"
    let comparison = compare(previous, current)
    let replacement = comparison.alignedBodyRows.first { $0.previous?.lineNumber == 3 }
    let insertion = comparison.alignedBodyRows.first { $0.current?.lineNumber == 5 }

    XCTAssertEqual(comparison.removedLineCount, 1)
    XCTAssertEqual(comparison.addedLineCount, 3)
    XCTAssertEqual(comparison.alignedBodyRows.count, 8)
    XCTAssertEqual(replacement?.previous?.text, "第二段：额度有剩余。\r")
    XCTAssertEqual(replacement?.current?.text, "第二段：额度还有很多剩余。\r")
    XCTAssertEqual(replacement?.current?.lineNumber, 3)
    XCTAssertTrue(replacement?.hasChanges == true)
    XCTAssertNil(insertion?.previous)
    XCTAssertEqual(insertion?.current?.text, "新增段：更想知道自己要做什么。\r")
    XCTAssertEqual(comparison.alignedBodyRows.last?.previous?.lineNumber, 6)
    XCTAssertEqual(comparison.alignedBodyRows.last?.current?.lineNumber, 8)
    XCTAssertEqual(comparison.alignedBodyRows.last?.previous?.text, "")
    XCTAssertEqual(comparison.alignedBodyRows.last?.current?.text, "")
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testCanonicallyEquivalentTextKeepsEachSidesExactBytes() {
    let previous = "Café\nCafé ancien et fin.\n"
    let current = "Cafe\u{301}\nCafe\u{301} nouveau et fin.\n"
    let comparison = compare(previous, current)

    assertReconstruction(comparison, previous: previous, current: current)
    XCTAssertEqual(
      Array(comparison.alignedBodyRows[0].current?.text.utf8 ?? "".utf8),
      Array("Cafe\u{301}".utf8)
    )
  }

  func testLargeChangedBlockFallbackPreservesEveryLineAndOrder() {
    let previous = (1...140).map { "旧行 \($0)" }.joined(separator: "\n")
    let current = (1...150).map { "新行 \($0)" }.joined(separator: "\n")
    let comparison = compare(previous, current, contextLineCount: 0)

    XCTAssertEqual(comparison.alignedBodyRows.count, 150)
    XCTAssertTrue(comparison.alignedBodyRows.allSatisfy(\.hasChanges))
    XCTAssertEqual(
      comparison.alignedBodyRows.compactMap { $0.previous?.lineNumber }, Array(1...140))
    XCTAssertEqual(comparison.alignedBodyRows.compactMap { $0.current?.lineNumber }, Array(1...150))
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testDenseAlternatingInlineEditBoundsRenderedSegmentCount() {
    let previous = String(repeating: "aX", count: 120)
    let current = String(repeating: "aY", count: 120)
    let comparison = compare(previous, current)
    let row = comparison.alignedBodyRows[0]

    XCTAssertLessThanOrEqual(row.previous?.segments.count ?? 0, 128)
    XCTAssertLessThanOrEqual(row.current?.segments.count ?? 0, 128)
    XCTAssertTrue(row.previous?.segments.contains(where: \.isChanged) == true)
    XCTAssertTrue(row.current?.segments.contains(where: \.isChanged) == true)
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testEmptyTerminalNewlineAndRepeatedLinesReconstructExactly() {
    let fixtures = [
      "", "\n", "\n\n", "结束\n", "开头\n\n结束", "重复\n重复\n重复",
      "重复\n新段落\n重复\n", "emoji 👩🏽‍💻\n中文\n", "a\nb\na\nb",
    ]
    for previous in fixtures {
      for current in fixtures {
        let comparison = compare(previous, current, contextLineCount: 0)
        assertReconstruction(comparison, previous: previous, current: current)
        XCTAssertEqual(
          comparison.alignedBodyRows.map(\.id), Array(comparison.alignedBodyRows.indices))
        XCTAssertEqual(
          comparison.alignedBodyRows.contains(where: \.hasChanges),
          previous != current
        )
      }
    }
  }

  func testAlignedRowsIgnoreLegacyContextCollapsing() {
    let previousLines = (1...30).map { "第 \($0) 行" }
    var currentLines = previousLines
    currentLines[15] += "已更新"
    let previous = previousLines.joined(separator: "\n")
    let current = currentLines.joined(separator: "\n")
    let comparison = compare(previous, current, contextLineCount: 0)

    XCTAssertTrue(comparison.bodyLineDiffs.contains { $0.kind == .skipped })
    XCTAssertEqual(comparison.alignedBodyRows.count, 30)
    XCTAssertEqual(comparison.alignedBodyRows.filter(\.hasChanges).count, 1)
    assertReconstruction(comparison, previous: previous, current: current)
  }

  func testLegacyComparisonSkipsAlignedProjectionUnlessExplicitlyRequested() {
    let previous = ArticleDraft(
      siteProfileID: UUID(), title: "文章", bodyMarkdown: "开头\n需要修改的段落。\n结尾")
    var current = previous
    current.bodyMarkdown = "开头\n已经修改的段落。\n结尾"

    let legacy = service.compare(previous: previous, current: current)
    let aligned = service.compare(
      previous: previous, current: current, includeAlignedBodyRows: true)

    XCTAssertTrue(legacy.alignedBodyRows.isEmpty)
    XCTAssertFalse(aligned.alignedBodyRows.isEmpty)
    XCTAssertEqual(legacy.fieldChanges, aligned.fieldChanges)
    XCTAssertEqual(legacy.bodyLineDiffs, aligned.bodyLineDiffs)
    XCTAssertEqual(legacy.addedLineCount, aligned.addedLineCount)
    XCTAssertEqual(legacy.removedLineCount, aligned.removedLineCount)
    XCTAssertEqual(legacy.hasChanges, aligned.hasChanges)
  }

  func testComparisonInitializerRemainsCompatibleWithoutAlignedRows() {
    let comparison = DraftVersionComparison(
      fieldChanges: [], bodyLineDiffs: [], addedLineCount: 0, removedLineCount: 0)
    XCTAssertTrue(comparison.alignedBodyRows.isEmpty)
    XCTAssertFalse(comparison.hasChanges)
  }

  private func compare(
    _ previousBody: String,
    _ currentBody: String,
    contextLineCount: Int = 3
  ) -> DraftVersionComparison {
    let previous = ArticleDraft(siteProfileID: UUID(), title: "文章", bodyMarkdown: previousBody)
    var current = previous
    current.bodyMarkdown = currentBody
    return service.compare(
      previous: previous, current: current, contextLineCount: contextLineCount,
      includeAlignedBodyRows: true
    )
  }

  private func assertReconstruction(
    _ comparison: DraftVersionComparison,
    previous: String,
    current: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let previousLines = comparison.alignedBodyRows.compactMap(\.previous)
    let currentLines = comparison.alignedBodyRows.compactMap(\.current)
    XCTAssertEqual(
      previousLines.map(\.text).joined(separator: "\n"), previous, file: file, line: line)
    XCTAssertEqual(
      currentLines.map(\.text).joined(separator: "\n"), current, file: file, line: line)
    XCTAssertEqual(
      Array(previousLines.map(\.text).joined(separator: "\n").utf8),
      Array(previous.utf8), file: file, line: line
    )
    XCTAssertEqual(
      Array(currentLines.map(\.text).joined(separator: "\n").utf8),
      Array(current.utf8), file: file, line: line
    )
    for alignedLine in previousLines + currentLines {
      XCTAssertEqual(
        alignedLine.segments.map(\.text).joined(), alignedLine.text, file: file, line: line)
      XCTAssertEqual(
        Array(alignedLine.segments.map(\.text).joined().utf8),
        Array(alignedLine.text.utf8), file: file, line: line
      )
    }
  }
}
