import Foundation
import PublishingWorkbenchCore

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
    let previous = previousText as NSString
    let updated = updatedText as NSString
    guard previousRange.location >= 0,
          NSMaxRange(previousRange) <= previous.length,
          updatedRange.location >= 0,
          NSMaxRange(updatedRange) <= updated.length,
          characterCount == previous.length else {
      return Self.make(for: updatedText)
    }

    let removedText = previous.substring(with: previousRange)
    let insertedText = updated.substring(with: updatedRange)
    let previousWordRange = Self.wordContextRange(around: previousRange, in: previous)
    let updatedWordRange = Self.wordContextRange(around: updatedRange, in: updated)
    let previousWritingStatistics = MarkdownWritingStatisticsService.statistics(
      in: previous.substring(with: previousWordRange)
    )
    let updatedWritingStatistics = MarkdownWritingStatisticsService.statistics(
      in: updated.substring(with: updatedWordRange)
    )
    let updatedHanCharacterCount = max(
      0,
      hanCharacterCount - previousWritingStatistics.hanCharacterCount
        + updatedWritingStatistics.hanCharacterCount
    )
    let updatedWordCount = max(
      0,
      wordCount - previousWritingStatistics.wordCount
        + updatedWritingStatistics.wordCount
    )
    let updatedLineBreakCount = max(
      0,
      lineBreakCount - Self.lineBreakCount(in: removedText) + Self.lineBreakCount(in: insertedText)
    )
    let updatedNonWhitespaceCount = max(
      0,
      nonWhitespaceCharacterCount
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

  private static func wordContextRange(around range: NSRange, in text: NSString) -> NSRange {
    var start = min(max(range.location, 0), text.length)
    var end = min(max(NSMaxRange(range), start), text.length)
    while start > 0, !isWordSeparator(text.character(at: start - 1)) {
      start -= 1
    }
    while end < text.length, !isWordSeparator(text.character(at: end)) {
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
}
