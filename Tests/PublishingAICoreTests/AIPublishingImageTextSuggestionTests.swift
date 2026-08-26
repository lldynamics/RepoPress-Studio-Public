import Foundation
import XCTest

@testable import PublishingAICore

final class AIPublishingImageTextSuggestionTests: XCTestCase {
  func testParserAcceptsFencedJSONAndAltTextAlias() throws {
    let target = makeTarget(id: "image-1")
    let text = """
    ```json
    {"items":[{"id":"  image-1  ","alt_text":"  工作流截图  ","caption":"  发布前检查  ","reason":"  结合文章内容  "}]}
    ```
    """

    let suggestions = AIPublishingImageTextSuggestionParser.parse(
      text,
      targets: [target]
    )

    let suggestion = try XCTUnwrap(suggestions.first)
    XCTAssertEqual(suggestions.count, 1)
    XCTAssertEqual(suggestion.id, target.id)
    XCTAssertEqual(suggestion.attachmentID, target.attachmentID)
    XCTAssertEqual(suggestion.altText, "工作流截图")
    XCTAssertEqual(suggestion.caption, "发布前检查")
    XCTAssertEqual(suggestion.reason, "结合文章内容")
  }

  func testParserFiltersUnknownAndDuplicateTargetIDs() {
    let target = makeTarget(id: "image-1")
    let text = """
    {"items":[
      {"id":"unknown","alt":"不应保留","caption":""},
      {"id":" image-1 ","alt":"首次建议","caption":""},
      {"id":"image-1","alt":"重复建议","caption":"重复"}
    ]}
    """

    let suggestions = AIPublishingImageTextSuggestionParser.parse(
      text,
      targets: [target]
    )

    XCTAssertEqual(suggestions.count, 1)
    XCTAssertEqual(suggestions.first?.altText, "首次建议")
    XCTAssertEqual(suggestions.first?.caption, "")
  }

  func testParserDropsEmptySuggestionsAndTrimsOutputValues() {
    let emptyTarget = makeTarget(id: "empty")
    let validTarget = makeTarget(id: "valid")
    let text = #"""
    {"items":[
      {"id":"empty","alt_text":" \n\t ","caption":"  \n  ","reason":"不会输出"},
      {"id":"valid","alt_text":"  有效替代文本  ","caption":"  有效说明  ","reason":"  可用建议  "}
    ]}
    """#

    let suggestions = AIPublishingImageTextSuggestionParser.parse(
      text,
      targets: [emptyTarget, validTarget]
    )

    XCTAssertEqual(suggestions.count, 1)
    XCTAssertEqual(suggestions.first?.id, validTarget.id)
    XCTAssertEqual(suggestions.first?.altText, "有效替代文本")
    XCTAssertEqual(suggestions.first?.caption, "有效说明")
    XCTAssertEqual(suggestions.first?.reason, "可用建议")
    XCTAssertTrue(suggestions.first?.hasSuggestion == true)
  }

  private func makeTarget(id: String) -> AIPublishingImageTextTarget {
    let attachmentID = UUID()
    return AIPublishingImageTextTarget(
      id: id,
      draftID: UUID(),
      attachmentID: attachmentID,
      draftTitle: "图片文案建议",
      markdownPath: "content/posts/image.md",
      articleSummary: "文章摘要",
      articleExcerpt: "文章摘录",
      filename: "image.png",
      imagePath: "/images/image.png",
      existingAlt: "",
      existingCaption: "",
      isCover: false,
      isReferencedInMarkdown: true
    )
  }
}
