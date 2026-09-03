import XCTest

@testable import PersonalSitePublisherMac

final class SelectionEditPreviewPresentationTests: XCTestCase {
  func testPunctuationReplacementProducesDeletionAndInsertionRuns() {
    let presentation = SelectionEditPreviewPresentation.make(
      original: "你好。",
      replacement: "你好！"
    )

    XCTAssertEqual(text(in: presentation.originalRuns, kind: .unchanged), "你好")
    XCTAssertEqual(text(in: presentation.originalRuns, kind: .deletion), "。")
    XCTAssertEqual(text(in: presentation.replacementRuns, kind: .unchanged), "你好")
    XCTAssertEqual(text(in: presentation.replacementRuns, kind: .insertion), "！")
  }

  func testEmptyOriginalMarksAllReplacementTextAsInsertion() {
    let presentation = SelectionEditPreviewPresentation.make(
      original: "",
      replacement: "新内容"
    )

    XCTAssertTrue(presentation.originalRuns.isEmpty)
    XCTAssertEqual(
      presentation.replacementRuns,
      [SelectionEditPreviewDiffRun(kind: .insertion, text: "新内容")]
    )
  }

  func testTextRegionHeightExpandsAndRemainsWithinBounds() {
    let compact = SelectionEditPreviewPresentation.textRegionHeight(
      original: "短文",
      replacement: "短文"
    )
    let expanded = SelectionEditPreviewPresentation.textRegionHeight(
      original: Array(repeating: "这是一行用于测试自适应高度的较长文本。", count: 30)
        .joined(separator: "\n"),
      replacement: ""
    )

    XCTAssertEqual(compact, SelectionEditPreviewPresentation.minimumTextRegionHeight)
    XCTAssertEqual(expanded, SelectionEditPreviewPresentation.maximumTextRegionHeight)
  }

  private func text(
    in runs: [SelectionEditPreviewDiffRun],
    kind: SelectionEditPreviewDiffKind
  ) -> String {
    runs.filter { $0.kind == kind }.map(\.text).joined()
  }
}
