import AppKit
import PublishingMarkdownCore
import XCTest

@testable import PersonalSitePublisherMac

@MainActor
final class MarkdownTextKit2PresentationDocumentTests: XCTestCase {
  func testNoAttachmentsPreservesExactMarkdownSource() {
    let source = "标题🙂\r\n中文 body"
    let document = MarkdownTextKit2PresentationDocument(source: source)

    XCTAssertEqual(document.source, source)
    XCTAssertEqual(document.projection.presentation, source)
    XCTAssertEqual(document.attributedString.string, source)
    XCTAssertFalse(source.contains("\u{FFFC}"))
    XCTAssertTrue(document.installedAttachments.isEmpty)
    XCTAssertTrue(document.rejectedEntries.isEmpty)
  }

  func testUnicodeCRLFAdjacentAttachmentsInstallIdentityAndMetadata() throws {
    let source = "🙂\r\n![图](a.png)$$x$$中文"
    let imageRange = (source as NSString).range(of: "![图](a.png)")
    let formulaRange = (source as NSString).range(of: "$$x$$")
    let image = makeAttachment(
      content: .image(accessibilityText: "图"),
      bounds: NSRect(x: 0, y: -24, width: 96, height: 30)
    )
    let formula = makeAttachment(
      content: .formula(
        source: "x",
        displayMode: .display,
        fontSize: 16
      ),
      bounds: NSRect(x: 0, y: -48, width: 160, height: 42)
    )
    let imageKind = MarkdownInlineAttachmentItem.Kind.image(
      reference: "a.png",
      altText: "图"
    )
    let formulaKind = MarkdownInlineAttachmentItem.Kind.formula(
      source: "x",
      displayMode: .display
    )
    let document = MarkdownTextKit2PresentationDocument(
      source: source,
      entries: [
        .init(sourceRange: imageRange, kind: imageKind, attachment: image),
        .init(sourceRange: formulaRange, kind: formulaKind, attachment: formula),
      ]
    )

    XCTAssertEqual(document.source, source)
    XCTAssertEqual(document.attributedString.string, "🙂\r\n\u{FFFC}\u{FFFC}中文")
    XCTAssertEqual(document.installedAttachments.count, 2)

    let installedImage = try XCTUnwrap(
      document.installedAttachments.first { $0.sourceRange == imageRange }
    )
    let installedFormula = try XCTUnwrap(
      document.installedAttachments.first { $0.sourceRange == formulaRange }
    )
    XCTAssertEqual(installedImage.kind, imageKind)
    XCTAssertEqual(installedFormula.kind, formulaKind)
    XCTAssertTrue(
      document.attributedString.attribute(
        .attachment,
        at: installedImage.presentationRange.location,
        effectiveRange: nil
      ) as AnyObject? === image
    )
    XCTAssertTrue(
      document.attributedString.attribute(
        .attachment,
        at: installedFormula.presentationRange.location,
        effectiveRange: nil
      ) as AnyObject? === formula
    )

    XCTAssertEqual(
      document.sourceRange(
        forPresentationRange: installedImage.presentationRange
      ),
      imageRange
    )
    XCTAssertEqual(
      document.sourceRange(
        forPresentationRange: installedFormula.presentationRange
      ),
      formulaRange
    )
    XCTAssertTrue(
      document.installedAttachment(
        atPresentationOffset: installedImage.presentationRange.location
      )?.attachment === image
    )
    XCTAssertTrue(
      document.installedAttachment(
        atPresentationOffset: installedFormula.presentationRange.location
      )?.attachment === formula
    )
  }

  func testSourceRangeMappingReturnsCompleteMarkdownForPartialAttachmentSelection() throws {
    let source = "前缀 [数学公式] 后缀🙂"
    let sourceRange = (source as NSString).range(of: "[数学公式]")
    let attachment = makeAttachment(
      content: .formula(
        source: "x^2",
        displayMode: .inline,
        fontSize: 16
      ),
      bounds: NSRect(x: 0, y: -24, width: 80, height: 28)
    )
    let document = MarkdownTextKit2PresentationDocument(
      source: source,
      entries: [
        .init(sourceRange: sourceRange, attachment: attachment)
      ]
    )

    let partialSourceRange = NSRange(
      location: sourceRange.location + 2,
      length: 2
    )
    let presentationRange = try XCTUnwrap(
      document.presentationRange(forSourceRange: partialSourceRange)
    )
    XCTAssertEqual(presentationRange.length, 1)
    XCTAssertEqual(
      document.sourceRange(forPresentationRange: presentationRange),
      sourceRange
    )
    XCTAssertEqual(
      document.presentationRange(
        forSourceRange: sourceRange,
        affinity: .upstream
      ),
      presentationRange
    )
    XCTAssertEqual(document.source, source)
    XCTAssertFalse(document.source.contains("\u{FFFC}"))
  }

  func testInvalidAndOverlappingEntriesAreRejectedWithoutChangingSource() {
    let source = "0123456789中文"
    let validRange = NSRange(location: 2, length: 3)
    let valid = makeAttachment(
      content: .formula(
        source: "x",
        displayMode: .inline,
        fontSize: 14
      ),
      bounds: NSRect(x: 0, y: -20, width: 50, height: 24)
    )
    let overlap = makeAttachment(
      content: .formula(
        source: "y",
        displayMode: .inline,
        fontSize: 14
      ),
      bounds: NSRect(x: 0, y: -20, width: 50, height: 24)
    )
    let negativeLocation = makeAttachment(
      content: .image(accessibilityText: "negative"),
      bounds: NSRect(x: 0, y: -20, width: 40, height: 24)
    )
    let negativeLength = makeAttachment(
      content: .image(accessibilityText: "negative length"),
      bounds: NSRect(x: 0, y: -20, width: 40, height: 24)
    )
    let outOfBounds = makeAttachment(
      content: .image(accessibilityText: "out of bounds"),
      bounds: NSRect(x: 0, y: -20, width: 40, height: 24)
    )
    let document = MarkdownTextKit2PresentationDocument(
      source: source,
      entries: [
        .init(sourceRange: validRange, attachment: valid),
        .init(sourceRange: NSRange(location: 3, length: 4), attachment: overlap),
        .init(sourceRange: NSRange(location: -1, length: 1), attachment: negativeLocation),
        .init(sourceRange: NSRange(location: 8, length: -1), attachment: negativeLength),
        .init(sourceRange: NSRange(location: 20, length: 1), attachment: outOfBounds),
      ]
    )

    XCTAssertEqual(document.installedAttachments.count, 1)
    XCTAssertTrue(document.installedAttachments[0].attachment === valid)
    XCTAssertEqual(document.rejectedEntries.count, 4)
    XCTAssertEqual(
      Set(document.rejectedEntries.map(\.reason)),
      Set([
        .overlapsAcceptedAttachment,
        .negativeLocation,
        .negativeLength,
        .outOfBounds,
      ])
    )
    XCTAssertEqual(document.attributedString.string, "01\u{FFFC}56789中文")
    XCTAssertEqual(document.source, source)
    XCTAssertFalse(document.source.contains("\u{FFFC}"))
  }

  func testPresentationRangeMappingUsesUTF16AndKeepsBaseAttributes() throws {
    let source = "🙂![图](a.png)后"
    let sourceRange = (source as NSString).range(of: "![图](a.png)")
    let attachment = makeAttachment(
      content: .image(accessibilityText: "图"),
      bounds: NSRect(x: 0, y: -24, width: 72, height: 28)
    )
    let color = NSColor.systemBlue
    let document = MarkdownTextKit2PresentationDocument(
      source: source,
      entries: [
        .init(sourceRange: sourceRange, attachment: attachment)
      ],
      attributes: [.foregroundColor: color]
    )
    let installed = try XCTUnwrap(document.installedAttachments.first)

    XCTAssertEqual(sourceRange.location, 2)
    XCTAssertEqual(installed.presentationRange.location, 2)
    XCTAssertEqual(
      document.presentationRange(
        forSourceRange: NSRange(location: 0, length: 2)
      ),
      NSRange(location: 0, length: 2)
    )
    XCTAssertEqual(
      document.attributedString.attribute(
        .foregroundColor,
        at: 0,
        effectiveRange: nil
      ) as? NSColor,
      color
    )
    XCTAssertEqual(
      document.attributedString.attribute(
        .foregroundColor,
        at: NSMaxRange(installed.presentationRange),
        effectiveRange: nil
      ) as? NSColor,
      color
    )
  }

  func testLargeAttachmentPlanInstallsEverySegmentInPresentationOrder() {
    let attachmentCount = 512
    let source = String(repeating: "x----", count: attachmentCount)
    var entries: [MarkdownTextKit2PresentationDocument.Entry] = []
    entries.reserveCapacity(attachmentCount)
    for location in stride(from: 0, to: (source as NSString).length, by: 5) {
      let attachment = makeAttachment(
        content: .image(accessibilityText: "image"),
        bounds: NSRect(x: 0, y: -16, width: 24, height: 20)
      )
      entries.append(
        .init(
          sourceRange: NSRange(location: location, length: 1),
          attachment: attachment
        )
      )
    }

    let document = MarkdownTextKit2PresentationDocument(
      source: source,
      entries: entries
    )

    XCTAssertEqual(document.installedAttachments.count, attachmentCount)
    XCTAssertEqual(
      document.attributedString.string,
      String(repeating: "\u{FFFC}----", count: attachmentCount)
    )
    XCTAssertEqual(
      document.installedAttachments.first?.presentationRange,
      NSRange(location: 0, length: 1)
    )
    XCTAssertEqual(
      document.installedAttachments.last?.presentationRange,
      NSRange(location: (attachmentCount - 1) * 5, length: 1)
    )
    XCTAssertTrue(
      document.installedAttachment(
        atPresentationOffset: (attachmentCount / 2) * 5
      ) != nil
    )
  }

  private func makeAttachment(
    content: MarkdownInlineAttachmentOverlayView.Content,
    bounds: NSRect
  ) -> MarkdownNativeTextAttachment {
    MarkdownNativeTextAttachment(content: content, bounds: bounds)
  }
}
