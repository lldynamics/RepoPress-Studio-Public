import XCTest
@testable import PublishingWorkbenchCore

final class MarkdownEditorOverlayServiceTests: XCTestCase {
  func testCurrentParagraphRangeTracksOnlySelectedParagraph() {
    let markdown = "first\nsecond\nthird"

    XCTAssertEqual(
      MarkdownEditorOverlayService.currentParagraphRange(
        in: markdown,
        selectedRange: NSRange(location: 8, length: 0),
        isEnabled: true
      ),
      NSRange(location: 6, length: 7)
    )
    XCTAssertEqual(
      MarkdownEditorOverlayService.currentParagraphRange(
        in: markdown,
        selectedRange: NSRange(location: (markdown as NSString).length, length: 0),
        isEnabled: true
      ),
      NSRange(location: 13, length: 5)
    )
  }

  func testCurrentParagraphRangeHandlesDisabledEmptyAndInvalidSelection() {
    XCTAssertNil(
      MarkdownEditorOverlayService.currentParagraphRange(
        in: "content",
        selectedRange: NSRange(location: 0, length: 0),
        isEnabled: false
      )
    )
    XCTAssertNil(
      MarkdownEditorOverlayService.currentParagraphRange(
        in: "",
        selectedRange: NSRange(location: 0, length: 0),
        isEnabled: true
      )
    )
    XCTAssertEqual(
      MarkdownEditorOverlayService.currentParagraphRange(
        in: "first\nsecond",
        selectedRange: NSRange(location: NSNotFound, length: 0),
        isEnabled: true
      ),
      NSRange(location: 0, length: 6)
    )
  }

  func testDiagnosticOverlaysClampPartialRangesAndDropEmptyRanges() {
    let diagnostics = [
      diagnostic(id: "valid", severity: .warning, range: NSRange(location: 2, length: 3)),
      diagnostic(id: "partial", severity: .error, range: NSRange(location: 8, length: 10)),
      diagnostic(id: "outside", severity: .warning, range: NSRange(location: 20, length: 2)),
      diagnostic(id: "empty", severity: .warning, range: NSRange(location: 4, length: 0)),
    ]

    XCTAssertEqual(
      MarkdownEditorOverlayService.diagnosticOverlays(
        in: "0123456789",
        diagnostics: diagnostics
      ),
      [
        MarkdownEditorDiagnosticOverlay(
          range: NSRange(location: 2, length: 3),
          severity: .warning
        ),
        MarkdownEditorDiagnosticOverlay(
          range: NSRange(location: 8, length: 2),
          severity: .error
        ),
      ]
    )
  }

  private func diagnostic(
    id: String,
    severity: MarkdownInlineDiagnosticSeverity,
    range: NSRange
  ) -> MarkdownInlineDiagnostic {
    MarkdownInlineDiagnostic(
      id: id,
      severity: severity,
      title: id,
      message: id,
      range: range
    )
  }
}
