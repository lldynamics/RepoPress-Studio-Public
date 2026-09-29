import Combine
import Foundation
import PublishingMarkdownCore

@MainActor
final class MarkdownComposerStatisticsState: ObservableObject {
  @Published private(set) var value: MarkdownEditorStatistics

  init(value: MarkdownEditorStatistics = .empty) {
    self.value = value
  }

  func update(_ updatedValue: MarkdownEditorStatistics) {
    guard value != updatedValue else { return }
    value = updatedValue
  }
}

struct MarkdownEditorStatistics: Equatable, Sendable {
  let characterCount: Int
  let hanCharacterCount: Int
  let wordCount: Int
  let lineCount: Int
  private let lineBreakCount: Int
  private let nonWhitespaceCharacterCount: Int

  static let empty = MarkdownEditorStatistics(
    characterCount: 0,
    hanCharacterCount: 0,
    wordCount: 0,
    lineCount: 0,
    lineBreakCount: 0,
    nonWhitespaceCharacterCount: 0
  )

  var writingUnitCount: Int {
    hanCharacterCount + wordCount
  }

  var readingMinutes: Int {
    MarkdownWritingStatistics(
      hanCharacterCount: hanCharacterCount,
      wordCount: wordCount
    ).estimatedReadingMinutes
  }

  static func make(for text: String) -> MarkdownEditorStatistics {
    let string = text as NSString
    let characterCount = string.length
    let lineBreakCount = text.utf16.reduce(into: 0) { count, value in
      if value == 10 { count += 1 }
    }
    let nonWhitespaceCharacterCount = text.unicodeScalars.reduce(into: 0) { count, scalar in
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
    }
    let writingStatistics = MarkdownWritingStatisticsService.statistics(in: text)
    return MarkdownEditorStatistics(
      characterCount: characterCount,
      hanCharacterCount: writingStatistics.hanCharacterCount,
      wordCount: writingStatistics.wordCount,
      lineCount: nonWhitespaceCharacterCount == 0 ? 0 : lineBreakCount + 1,
      lineBreakCount: lineBreakCount,
      nonWhitespaceCharacterCount: nonWhitespaceCharacterCount
    )
  }

  func applying(
    replacing previousRange: NSRange,
    in previousText: String,
    with updatedRange: NSRange,
    in updatedText: String
  ) -> MarkdownEditorStatistics {
    Self.apply(
      self,
      replacing: previousRange,
      in: previousText,
      with: updatedRange,
      in: updatedText,
      processingBudget: nil
    ) ?? Self.make(for: updatedText)
  }

  /// Applies a local edit only when every scan needed to certify the delta fits
  /// inside `maximumProcessedUTF16Count`. Returning `nil` asks the caller to
  /// retain the last exact value until it can schedule a full-document scan.
  ///
  /// The budget charges both old/new word-boundary probes, the old/new word
  /// contexts passed to the writing-statistics service, and both passes over
  /// old/new edit fragments for line and whitespace counts. It is not a limit
  /// on the edit range alone: one-character edits into a large unbroken token
  /// must decline this path before scanning that token on the main actor.
  func applyingBounded(
    replacing previousRange: NSRange,
    in previousText: String,
    with updatedRange: NSRange,
    in updatedText: String,
    maximumProcessedUTF16Count: Int = Self.incrementalUTF16ProcessingBudget
  ) -> MarkdownEditorStatistics? {
    guard maximumProcessedUTF16Count >= 0 else { return nil }
    return Self.apply(
      self,
      replacing: previousRange,
      in: previousText,
      with: updatedRange,
      in: updatedText,
      processingBudget: IncrementalProcessingBudget(
        remainingUTF16Count: maximumProcessedUTF16Count
      )
    )
  }

  static let incrementalUTF16ProcessingBudget = 4_096

  private static func apply(
    _ statistics: MarkdownEditorStatistics,
    replacing previousRange: NSRange,
    in previousText: String,
    with updatedRange: NSRange,
    in updatedText: String,
    processingBudget: IncrementalProcessingBudget?
  ) -> MarkdownEditorStatistics? {
    let previous = previousText as NSString
    let updated = updatedText as NSString
    guard previousRange.location >= 0,
      previousRange.length >= 0,
      NSMaxRange(previousRange) <= previous.length,
      updatedRange.location >= 0,
      updatedRange.length >= 0,
      NSMaxRange(updatedRange) <= updated.length,
      statistics.characterCount == previous.length
    else {
      return nil
    }

    var budget = processingBudget
    guard
      let previousWordRange = Self.wordContextRange(
        around: previousRange,
        in: previous,
        budget: &budget
      ),
      let updatedWordRange = Self.wordContextRange(
        around: updatedRange,
        in: updated,
        budget: &budget
      ),
      Self.consume(
        previousRange.length,
        from: &budget
      ),
      Self.consume(
        previousRange.length,
        from: &budget
      ),
      Self.consume(
        updatedRange.length,
        from: &budget
      ),
      Self.consume(
        updatedRange.length,
        from: &budget
      ),
      Self.consume(
        previousWordRange.length,
        from: &budget
      ),
      Self.consume(
        updatedWordRange.length,
        from: &budget
      )
    else {
      return nil
    }

    let removedText = previous.substring(with: previousRange)
    let insertedText = updated.substring(with: updatedRange)
    let previousWritingStatistics = MarkdownWritingStatisticsService.statistics(
      in: previous.substring(with: previousWordRange)
    )
    let updatedWritingStatistics = MarkdownWritingStatisticsService.statistics(
      in: updated.substring(with: updatedWordRange)
    )
    let updatedHanCharacterCount = max(
      0,
      statistics.hanCharacterCount - previousWritingStatistics.hanCharacterCount
        + updatedWritingStatistics.hanCharacterCount
    )
    let updatedWordCount = max(
      0,
      statistics.wordCount - previousWritingStatistics.wordCount
        + updatedWritingStatistics.wordCount
    )
    let updatedLineBreakCount = max(
      0,
      statistics.lineBreakCount - Self.lineBreakCount(in: removedText)
        + Self.lineBreakCount(in: insertedText)
    )
    let updatedNonWhitespaceCount = max(
      0,
      statistics.nonWhitespaceCharacterCount
        - Self.nonWhitespaceCharacterCount(in: removedText)
        + Self.nonWhitespaceCharacterCount(in: insertedText)
    )
    let updatedCharacterCount = updated.length
    return MarkdownEditorStatistics(
      characterCount: updatedCharacterCount,
      hanCharacterCount: updatedHanCharacterCount,
      wordCount: updatedWordCount,
      lineCount: updatedNonWhitespaceCount == 0 ? 0 : updatedLineBreakCount + 1,
      lineBreakCount: updatedLineBreakCount,
      nonWhitespaceCharacterCount: updatedNonWhitespaceCount
    )
  }

  private static let wordSeparators = CharacterSet.whitespacesAndNewlines
    .union(.punctuationCharacters)
    .union(.symbols)

  private struct IncrementalProcessingBudget {
    var remainingUTF16Count: Int

    mutating func consume(_ count: Int) -> Bool {
      guard count >= 0, count <= remainingUTF16Count else { return false }
      remainingUTF16Count -= count
      return true
    }
  }

  private static func consume(
    _ count: Int,
    from budget: inout IncrementalProcessingBudget?
  ) -> Bool {
    guard var currentBudget = budget else { return true }
    guard currentBudget.consume(count) else { return false }
    budget = currentBudget
    return true
  }

  private static func lineBreakCount(in text: String) -> Int {
    text.utf16.reduce(into: 0) { count, value in
      if value == 10 { count += 1 }
    }
  }

  private static func nonWhitespaceCharacterCount(in text: String) -> Int {
    text.unicodeScalars.reduce(into: 0) { count, scalar in
      if !CharacterSet.whitespacesAndNewlines.contains(scalar) { count += 1 }
    }
  }

  private static func wordContextRange(
    around range: NSRange,
    in text: NSString,
    budget: inout IncrementalProcessingBudget?
  ) -> NSRange? {
    var start = min(max(range.location, 0), text.length)
    var end = min(max(NSMaxRange(range), start), text.length)
    while start > 0 {
      guard consume(1, from: &budget) else { return nil }
      guard !isWordSeparator(text.character(at: start - 1)) else { break }
      start -= 1
    }
    while end < text.length {
      guard consume(1, from: &budget) else { return nil }
      guard !isWordSeparator(text.character(at: end)) else { break }
      end += 1
    }
    return NSRange(location: start, length: end - start)
  }

  private static func isWordSeparator(_ value: unichar) -> Bool {
    UnicodeScalar(UInt32(value)).map(wordSeparators.contains) ?? false
  }
}
struct MarkdownTextEdit {
  let previousText: String
  let replacedRange: NSRange

  /// Recovers a single replacement when AppKit delivers `textDidChange`
  /// without a preceding `shouldChangeTextIn` callback. This keeps paste,
  /// accessibility, undo, and input-method commits on the incremental syntax
  /// path instead of immediately scheduling a full-document repaint.
  static func inferred(previousText: String, currentText: String) -> Self? {
    guard previousText != currentText else { return nil }
    let previous = previousText as NSString
    let current = currentText as NSString
    let commonLimit = min(previous.length, current.length)
    var prefixLength = 0
    while prefixLength < commonLimit,
      previous.character(at: prefixLength) == current.character(at: prefixLength)
    {
      prefixLength += 1
    }
    if prefixLength > 0,
      prefixLength < previous.length,
      prefixLength < current.length,
      isHighSurrogate(previous.character(at: prefixLength - 1))
    {
      prefixLength -= 1
    }

    var suffixLength = 0
    while suffixLength < previous.length - prefixLength,
      suffixLength < current.length - prefixLength,
      previous.character(at: previous.length - suffixLength - 1)
        == current.character(at: current.length - suffixLength - 1)
    {
      suffixLength += 1
    }
    if suffixLength > 0,
      previous.length - suffixLength > prefixLength,
      current.length - suffixLength > prefixLength,
      isLowSurrogate(previous.character(at: previous.length - suffixLength))
    {
      suffixLength -= 1
    }

    return MarkdownTextEdit(
      previousText: previousText,
      replacedRange: NSRange(
        location: prefixLength,
        length: previous.length - prefixLength - suffixLength
      )
    )
  }

  private static func isHighSurrogate(_ value: unichar) -> Bool {
    (0xD800...0xDBFF).contains(value)
  }

  private static func isLowSurrogate(_ value: unichar) -> Bool {
    (0xDC00...0xDFFF).contains(value)
  }
}
