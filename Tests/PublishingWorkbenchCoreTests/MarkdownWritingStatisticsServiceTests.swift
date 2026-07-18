import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownWritingStatisticsServiceTests: XCTestCase {
  func testContinuousChineseTextCountsEveryIdeograph() {
    let statistics = MarkdownWritingStatisticsService.statistics(
      in: "从这里开始写作，连续中文不应只算一个词。"
    )

    XCTAssertEqual(statistics.hanCharacterCount, 18)
    XCTAssertEqual(statistics.wordCount, 0)
    XCTAssertEqual(statistics.writingUnitCount, 18)
    XCTAssertEqual(statistics.estimatedReadingMinutes, 1)
  }

  func testLatinTextCountsWordsInsteadOfCharacters() {
    let text = Array(repeating: "markdown", count: 500).joined(separator: " ")
    let statistics = MarkdownWritingStatisticsService.statistics(in: text)

    XCTAssertEqual(statistics.hanCharacterCount, 0)
    XCTAssertEqual(statistics.wordCount, 500)
    XCTAssertEqual(statistics.writingUnitCount, 500)
    XCTAssertEqual(statistics.estimatedReadingMinutes, 2)
  }

  func testMixedTextCombinesChineseCharactersAndOtherLanguageWords() {
    let statistics = MarkdownWritingStatisticsService.statistics(
      in: "用 SwiftUI 构建 300 个页面"
    )

    XCTAssertEqual(statistics.hanCharacterCount, 6)
    XCTAssertEqual(statistics.wordCount, 2)
    XCTAssertEqual(statistics.writingUnitCount, 8)
    XCTAssertEqual(statistics.estimatedReadingMinutes, 1)
  }

  func testMarkdownPunctuationDoesNotInflateWritingUnits() {
    let statistics = MarkdownWritingStatisticsService.statistics(
      in: "## 标题\n\n**hello**, [world](https://example.com)."
    )

    XCTAssertEqual(statistics.hanCharacterCount, 2)
    XCTAssertEqual(statistics.wordCount, 5)
    XCTAssertEqual(statistics.writingUnitCount, 7)
  }

  func testReadingTimeUsesIndependentChineseAndLatinRates() {
    let chinese = String(repeating: "字", count: 501)
    let latin = Array(repeating: "word", count: 251).joined(separator: " ")

    XCTAssertEqual(
      MarkdownWritingStatisticsService.statistics(in: chinese).estimatedReadingMinutes,
      2
    )
    XCTAssertEqual(
      MarkdownWritingStatisticsService.statistics(in: latin).estimatedReadingMinutes,
      2
    )
  }

  func testEmptyTextHasNoReadingTime() {
    XCTAssertEqual(
      MarkdownWritingStatisticsService.statistics(in: "").estimatedReadingMinutes,
      0
    )
  }
}
