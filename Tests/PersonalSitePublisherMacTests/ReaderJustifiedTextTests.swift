import AppKit
import XCTest

@testable import PersonalSitePublisherMac

final class ReaderJustifiedTextTests: XCTestCase {
  @MainActor
  func testJustifiedTextBuildsReaderParagraphStyleAndKeepsInlineTraits() throws {
    let reader = ReaderJustifiedText(
      markdown: "**重点** 与 `code`",
      fontFamily: .newYork,
      fontSize: 18,
      fontWeight: .regular,
      lineHeightMultiple: 1.75,
      foregroundColor: .labelColor,
      highlightTerms: ["重点"]
    )
    let attributed = reader.makeAttributedString()
    let fullText = attributed.string as NSString
    let paragraph = try XCTUnwrap(
      attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
        as? NSParagraphStyle
    )

    XCTAssertEqual(paragraph.alignment, .justified)
    XCTAssertEqual(paragraph.lineHeightMultiple, 1.75, accuracy: 0.001)
    XCTAssertTrue(paragraph.lineBreakStrategy.contains(.standard))
    XCTAssertTrue(paragraph.lineBreakStrategy.contains(.pushOut))

    let strongRange = fullText.range(of: "重点")
    let strongFont = try XCTUnwrap(
      attributed.attribute(.font, at: strongRange.location, effectiveRange: nil) as? NSFont
    )
    XCTAssertTrue(strongFont.fontDescriptor.symbolicTraits.contains(.bold))
    XCTAssertNotNil(
      attributed.attribute(.backgroundColor, at: strongRange.location, effectiveRange: nil)
    )

    let codeRange = fullText.range(of: "code")
    let codeFont = try XCTUnwrap(
      attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
    )
    XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
  }

  @MainActor
  func testReaderFontsAlwaysProvideAUsableFallback() {
    for family in ReaderFontFamily.allCases {
      let font = family.nsFont(size: 17)
      XCTAssertEqual(font.pointSize, 17, accuracy: 0.001)
    }
  }
}
