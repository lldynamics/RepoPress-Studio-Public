import AppKit
import PublishingTestSupport
import SwiftUI
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownEditorStatisticsTests: XCTestCase {
  func testDraftSwitchWithSameRevisionAndOffsetRejectsLateStatisticsAndKeepsBindings() async {
    let firstBody = String(repeating: "Article A has different statistics. ", count: 2_000)
    let secondBody = "Article B stays selected."
    let clock = ManualClock()
    var text = firstBody
    var selection = NSRange(location: 0, length: 0)
    var frontMatterSelection = false
    var delivered: [MarkdownEditorStatistics] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
      bodyMarkdown: firstBody, bodyUTF16Offset: 0, statisticsClock: clock,
      selectedRange: Binding(get: { selection }, set: { selection = $0 }),
      isFrontMatterSelection: Binding(
        get: { frontMatterSelection }, set: { frontMatterSelection = $0 }),
      comfortConfiguration: MarkdownEditorComfortConfiguration(), diagnostics: [],
      onStatisticsChanged: { delivered.append($0) }, onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in }, onDroppedFiles: { _ in })
    let textView = NSTextView()
    textView.string = firstBody
    coordinator.scheduleFullStatistics(for: firstBody)
    await clock.waitForSleepCount(1)
    let oldTask = coordinator.statisticsTask
    let revision = coordinator.syntaxDocumentRevision

    text = secondBody
    selection = NSRange(location: 5, length: 0)
    textView.string = secondBody
    textView.setSelectedRange(selection)
    coordinator.updateDocumentContext(
      bodyMarkdown: secondBody, bodyUTF16Offset: 0, allowsLiveBodyChanges: true,
      attachments: [], in: textView)
    XCTAssertEqual(coordinator.syntaxDocumentRevision, revision)
    clock.advance(by: .seconds(2.5))
    await oldTask?.value

    XCTAssertTrue(
      delivered.isEmpty,
      "Statistics for A must not be delivered into B's unchanged revision and offset.")
    XCTAssertEqual(text, secondBody)
    XCTAssertEqual(textView.string, secondBody)
    XCTAssertEqual(selection, NSRange(location: 5, length: 0))
    XCTAssertEqual(textView.selectedRange(), selection)
    coordinator.scheduleFullStatistics(for: secondBody)
    await clock.waitForSleepCount(2)
    clock.advance(by: .seconds(2.5))
    await coordinator.waitForPendingStatisticsDelivery()
    XCTAssertEqual(delivered, [MarkdownEditorStatistics.make(for: secondBody)])
  }

  func testBoundedDeltasMatchFullStatisticsForUnicodeAndSeparators() throws {
    try assertBoundedDelta(
      previous: "你好 world",
      replacedText: "world",
      replacement: "swift"
    )
    try assertBoundedDelta(
      previous: "Cafe\u{301} 😀 alpha",
      replacedText: "alpha",
      replacement: "beta"
    )
    try assertBoundedDelta(
      previous: "helloworld",
      replacedRange: NSRange(location: 5, length: 0),
      replacement: " "
    )
    try assertBoundedDelta(
      previous: "hello world",
      replacedText: " ",
      replacement: ""
    )
  }

  func testBoundedDeltaRejectsLongUnbrokenToken() {
    let previous = String(repeating: "a", count: 100_000)
    let replacementRange = NSRange(location: 50_000, length: 1)
    let updated = (previous as NSString).replacingCharacters(
      in: replacementRange,
      with: "b"
    )

    XCTAssertNil(
      MarkdownEditorStatistics.make(for: previous).applyingBounded(
        replacing: replacementRange,
        in: previous,
        with: replacementRange,
        in: updated
      )
    )
  }

  func testRepeatedBoundedFailuresDeliverOnlyLatestFullScanThenResumeLocalUpdates() async throws {
    let initial = String(repeating: "a", count: 10_000) + " delimiter word"
    let clock = ManualClock()
    var text = initial
    var selectedRange = NSRange(location: 0, length: 0)
    var isFrontMatterSelection = false
    var deliveredStatistics: [MarkdownEditorStatistics] = []
    let coordinator = MacMarkdownTextView.Coordinator(
      text: Binding(get: { text }, set: { text = $0 }),
      bodyMarkdown: initial,
      bodyUTF16Offset: 0,
      statisticsClock: clock,
      selectedRange: Binding(
        get: { selectedRange },
        set: { selectedRange = $0 }
      ),
      isFrontMatterSelection: Binding(
        get: { isFrontMatterSelection },
        set: { isFrontMatterSelection = $0 }
      ),
      comfortConfiguration: MarkdownEditorComfortConfiguration(),
      diagnostics: [],
      onStatisticsChanged: { deliveredStatistics.append($0) },
      onPasteMessage: { _ in },
      onScrollPositionChanged: { _ in },
      onDroppedFiles: { _ in }
    )
    let replacementRange = NSRange(location: 5_000, length: 1)
    let firstFallbackText = (initial as NSString).replacingCharacters(
      in: replacementRange,
      with: "b"
    )
    coordinator.statistics = MarkdownEditorStatistics.make(for: initial)
    coordinator.statisticsText = initial
    coordinator.statisticsFullScanCount = 0

    coordinator.updateStatistics(
      afterEditing: firstFallbackText,
      edit: MarkdownTextEdit(
        previousText: initial,
        replacedRange: replacementRange
      )
    )

    XCTAssertEqual(coordinator.statisticsFullScanCount, 1)
    XCTAssertEqual(coordinator.statisticsIncrementalUpdateCount, 0)
    XCTAssertEqual(coordinator.statistics, MarkdownEditorStatistics.make(for: initial))
    await clock.waitForSleepCount(1)

    let secondReplacementRange = NSRange(location: 5_001, length: 1)
    let secondFallbackText = (firstFallbackText as NSString).replacingCharacters(
      in: secondReplacementRange,
      with: "c"
    )
    coordinator.updateStatistics(
      afterEditing: secondFallbackText,
      edit: MarkdownTextEdit(
        previousText: firstFallbackText,
        replacedRange: secondReplacementRange
      )
    )

    XCTAssertNil(coordinator.statisticsText)
    XCTAssertEqual(coordinator.statisticsFullScanCount, 2)
    XCTAssertEqual(coordinator.statisticsIncrementalUpdateCount, 0)
    await clock.waitForSleepCount(2)
    clock.advance(by: .seconds(2.5))
    await coordinator.waitForPendingStatisticsDelivery()
    XCTAssertEqual(
      coordinator.statistics,
      MarkdownEditorStatistics.make(for: secondFallbackText)
    )
    XCTAssertEqual(
      deliveredStatistics,
      [MarkdownEditorStatistics.make(for: secondFallbackText)]
    )

    let ordinaryRange = (secondFallbackText as NSString).range(of: "word")
    let ordinaryText = (secondFallbackText as NSString).replacingCharacters(
      in: ordinaryRange,
      with: "tokens"
    )
    coordinator.updateStatistics(
      afterEditing: ordinaryText,
      edit: MarkdownTextEdit(
        previousText: secondFallbackText,
        replacedRange: ordinaryRange
      )
    )

    XCTAssertEqual(coordinator.statisticsFullScanCount, 2)
    XCTAssertEqual(coordinator.statisticsIncrementalUpdateCount, 1)
    await clock.waitForSleepCount(3)
    clock.advance(by: .seconds(0.5))
    await coordinator.waitForPendingStatisticsDelivery()
    XCTAssertEqual(coordinator.statistics, MarkdownEditorStatistics.make(for: ordinaryText))
    XCTAssertEqual(deliveredStatistics.last, MarkdownEditorStatistics.make(for: ordinaryText))
  }

  private func assertBoundedDelta(
    previous: String,
    replacedText: String,
    replacement: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let replacedRange = try XCTUnwrap(
      (previous as NSString).range(of: replacedText).nonNotFoundRange
    )
    try assertBoundedDelta(
      previous: previous,
      replacedRange: replacedRange,
      replacement: replacement,
      file: file,
      line: line
    )
  }

  private func assertBoundedDelta(
    previous: String,
    replacedRange: NSRange,
    replacement: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let updated = (previous as NSString).replacingCharacters(
      in: replacedRange,
      with: replacement
    )
    let insertedRange = NSRange(
      location: replacedRange.location,
      length: (replacement as NSString).length
    )
    let updatedStatistics = try XCTUnwrap(
      MarkdownEditorStatistics.make(for: previous).applyingBounded(
        replacing: replacedRange,
        in: previous,
        with: insertedRange,
        in: updated
      ),
      file: file,
      line: line
    )
    XCTAssertEqual(
      updatedStatistics,
      MarkdownEditorStatistics.make(for: updated),
      file: file,
      line: line
    )
  }
}

extension NSRange {
  fileprivate var nonNotFoundRange: NSRange? {
    location == NSNotFound ? nil : self
  }
}
