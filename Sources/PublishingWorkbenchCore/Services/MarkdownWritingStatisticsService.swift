import Foundation

public struct MarkdownWritingStatistics: Equatable, Sendable {
  public let hanCharacterCount: Int
  public let wordCount: Int

  public init(hanCharacterCount: Int, wordCount: Int) {
    self.hanCharacterCount = max(0, hanCharacterCount)
    self.wordCount = max(0, wordCount)
  }

  /// One Chinese ideograph counts as one writing unit; other text is counted by word.
  public var writingUnitCount: Int {
    hanCharacterCount + wordCount
  }

  public var estimatedReadingMinutes: Int {
    guard writingUnitCount > 0 else { return 0 }
    let chineseMinutes = Double(hanCharacterCount)
      / Double(MarkdownWritingStatisticsService.chineseCharactersPerMinute)
    let otherLanguageMinutes = Double(wordCount)
      / Double(MarkdownWritingStatisticsService.otherLanguageWordsPerMinute)
    return max(1, Int(ceil(chineseMinutes + otherLanguageMinutes)))
  }

  public static let empty = MarkdownWritingStatistics(
    hanCharacterCount: 0,
    wordCount: 0
  )
}

public enum MarkdownWritingStatisticsService {
  public static let chineseCharactersPerMinute = 500
  public static let otherLanguageWordsPerMinute = 250

  public static func statistics(in text: String) -> MarkdownWritingStatistics {
    var hanCharacterCount = 0
    var wordCount = 0
    var isInsideWord = false

    for scalar in text.unicodeScalars {
      if scalar.properties.isIdeographic {
        hanCharacterCount += 1
        isInsideWord = false
      } else if isWordScalar(scalar) {
        if !isInsideWord {
          wordCount += 1
          isInsideWord = true
        }
      } else if !isCombiningMark(scalar) {
        isInsideWord = false
      }
    }

    return MarkdownWritingStatistics(
      hanCharacterCount: hanCharacterCount,
      wordCount: wordCount
    )
  }

  private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
    !scalar.properties.isIdeographic && CharacterSet.alphanumerics.contains(scalar)
  }

  private static func isCombiningMark(_ scalar: UnicodeScalar) -> Bool {
    switch scalar.properties.generalCategory {
    case .nonspacingMark, .spacingMark, .enclosingMark:
      return true
    default:
      return false
    }
  }
}
