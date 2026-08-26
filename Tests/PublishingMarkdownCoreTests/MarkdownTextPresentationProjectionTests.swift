import Foundation
import XCTest

@testable import PublishingMarkdownCore

final class MarkdownTextPresentationProjectionTests: XCTestCase {
  func testNoAttachmentsLeavesSourceAndUTF16RangesUnchanged() {
    let source = "标题🙂\r\n中文 body"
    let projection = MarkdownTextPresentationProjection(source: source)

    XCTAssertEqual(projection.source, source)
    XCTAssertEqual(projection.presentation, source)
    XCTAssertEqual(projection.sourceUTF16Length, (source as NSString).length)
    XCTAssertEqual(projection.presentationUTF16Length, (source as NSString).length)
    XCTAssertEqual(projection.acceptedAttachments, [])
    XCTAssertTrue(projection.rejectedAttachments.isEmpty)
    XCTAssertEqual(projection.segments.count, 1)
    XCTAssertEqual(
      projection.segments.first?.sourceRange,
      NSRange(location: 0, length: (source as NSString).length)
    )
    XCTAssertEqual(
      projection.presentationRange(
        forSourceRange: NSRange(location: 2, length: 3)
      ),
      NSRange(location: 2, length: 3)
    )
    XCTAssertEqual(
      projection.sourceRange(
        forPresentationRange: NSRange(location: 2, length: 3)
      ),
      NSRange(location: 2, length: 3)
    )
  }

  func testUnicodeCRLFAndAdjacentAttachmentsUseUTF16Coordinates() throws {
    let source = "🙂\r\n![图](a.png)$$x$$中文"
    let imageRange = (source as NSString).range(of: "![图](a.png)")
    let formulaRange = (source as NSString).range(of: "$$x$$")
    let projection = MarkdownTextPresentationProjection(
      source: source,
      attachments: [
        MarkdownTextPresentationAttachment(sourceRange: formulaRange),
        MarkdownTextPresentationAttachment(sourceRange: imageRange),
      ]
    )

    XCTAssertEqual(projection.acceptedAttachments.map(\.sourceRange), [imageRange, formulaRange])
    XCTAssertEqual(
      projection.presentation,
      "🙂\r\n\u{FFFC}\u{FFFC}中文"
    )
    XCTAssertEqual(
      projection.presentationUTF16Length,
      ("🙂\r\n\u{FFFC}\u{FFFC}中文" as NSString).length
    )

    let imagePresentationRange = try XCTUnwrap(
      projection.presentationRange(forSourceRange: imageRange)
    )
    let formulaPresentationRange = try XCTUnwrap(
      projection.presentationRange(forSourceRange: formulaRange)
    )
    XCTAssertEqual(imagePresentationRange.length, 1)
    XCTAssertEqual(formulaPresentationRange.length, 1)
    XCTAssertEqual(
      NSMaxRange(imagePresentationRange),
      formulaPresentationRange.location
    )
    XCTAssertEqual(
      projection.sourceRange(forPresentationRange: imagePresentationRange),
      imageRange
    )
    XCTAssertEqual(
      projection.sourceRange(forPresentationRange: formulaPresentationRange),
      formulaRange
    )
  }

  func testItemsConveniencePreservesAttachmentKind() throws {
    let source = "![封面](cover.png)"
    let item = try XCTUnwrap(
      MarkdownInlineAttachmentPlanService.plan(in: source).items.first
    )
    let projection = MarkdownTextPresentationProjection(source: source, items: [item])

    XCTAssertEqual(projection.presentation, "\u{FFFC}")
    XCTAssertEqual(projection.acceptedAttachments, [MarkdownTextPresentationAttachment(item: item)])
    XCTAssertEqual(projection.segments.count, 1)
    guard case .attachment(let attachment) = projection.segments[0].kind else {
      return XCTFail("Expected an attachment segment")
    }
    XCTAssertEqual(attachment.kind, item.kind)
  }

  func testInvalidAndOverlappingRangesAreDroppedDeterministically() {
    let source = "abcdefghij"
    let longer = MarkdownTextPresentationAttachment(
      sourceRange: NSRange(location: 2, length: 4)
    )
    let shorterOverlap = MarkdownTextPresentationAttachment(
      sourceRange: NSRange(location: 2, length: 2)
    )
    let later = MarkdownTextPresentationAttachment(
      sourceRange: NSRange(location: 6, length: 2)
    )
    let invalid = MarkdownTextPresentationAttachment(
      sourceRange: NSRange(location: 9, length: 4)
    )
    let negative = MarkdownTextPresentationAttachment(
      sourceRange: NSRange(location: -1, length: 1)
    )
    let zero = MarkdownTextPresentationAttachment(
      sourceRange: NSRange(location: 1, length: 0)
    )

    let projection = MarkdownTextPresentationProjection(
      source: source,
      attachments: [later, zero, shorterOverlap, negative, invalid, longer]
    )

    XCTAssertEqual(projection.acceptedAttachments.map(\.sourceRange), [longer.sourceRange, later.sourceRange])
    XCTAssertEqual(projection.rejectedAttachments.count, 4)
    XCTAssertEqual(
      projection.rejectedAttachments.map(\.reason),
      [
        .negativeLocation,
        .zeroLength,
        .overlapsAcceptedAttachment,
        .outOfBounds,
      ]
    )
    XCTAssertEqual(projection.presentation, "ab\u{FFFC}\u{FFFC}ij")
  }

  func testSourceOffsetAffinityInsideCollapsedRange() throws {
    let source = "prefix [formula] suffix"
    let range = (source as NSString).range(of: "[formula]")
    let projection = MarkdownTextPresentationProjection(
      source: source,
      attachments: [MarkdownTextPresentationAttachment(sourceRange: range)]
    )
    let presentationRange = try XCTUnwrap(
      projection.presentationRange(forSourceRange: range)
    )
    let inside = range.location + 2

    XCTAssertEqual(
      projection.presentationOffset(
        forSourceOffset: inside,
        affinity: .upstream
      ),
      presentationRange.location
    )
    XCTAssertEqual(
      projection.presentationOffset(
        forSourceOffset: inside,
        affinity: .downstream
      ),
      NSMaxRange(presentationRange)
    )
    XCTAssertEqual(
      projection.presentationOffset(
        forSourceOffset: range.location,
        affinity: .upstream
      ),
      presentationRange.location
    )
    XCTAssertEqual(
      projection.presentationOffset(
        forSourceOffset: NSMaxRange(range),
        affinity: .downstream
      ),
      NSMaxRange(presentationRange)
    )
  }

  func testPresentationOffsetAffinityAndAttachmentSelectionMapBackToSource() throws {
    let source = "before [image] after"
    let sourceRange = (source as NSString).range(of: "[image]")
    let projection = MarkdownTextPresentationProjection(
      source: source,
      attachments: [MarkdownTextPresentationAttachment(sourceRange: sourceRange)]
    )
    let presentationRange = try XCTUnwrap(
      projection.presentationRange(forSourceRange: sourceRange)
    )

    XCTAssertEqual(
      projection.sourceOffset(
        forPresentationOffset: presentationRange.location,
        affinity: .upstream
      ),
      sourceRange.location
    )
    XCTAssertEqual(
      projection.sourceOffset(
        forPresentationOffset: presentationRange.location,
        affinity: .downstream
      ),
      NSMaxRange(sourceRange)
    )
    XCTAssertEqual(
      projection.sourceRange(forPresentationRange: presentationRange),
      sourceRange
    )
    XCTAssertEqual(
      projection.attachment(atPresentationOffset: presentationRange.location)?.sourceRange,
      sourceRange
    )
  }

  func testRangeMappingIncludesWholeAttachmentForPartialSourceSelection() throws {
    let source = "aa<attachment>zz"
    let attachmentRange = (source as NSString).range(of: "<attachment>")
    let projection = MarkdownTextPresentationProjection(
      source: source,
      attachments: [MarkdownTextPresentationAttachment(sourceRange: attachmentRange)]
    )

    let partialSourceRange = NSRange(location: attachmentRange.location + 2, length: 2)
    let presentationRange = try XCTUnwrap(
      projection.presentationRange(forSourceRange: partialSourceRange)
    )
    XCTAssertEqual(presentationRange.length, 1)
    XCTAssertEqual(
      projection.sourceRange(forPresentationRange: presentationRange),
      attachmentRange
    )

    let sourceBeforeAttachment = NSRange(location: 0, length: attachmentRange.location)
    XCTAssertEqual(
      projection.presentationRange(forSourceRange: sourceBeforeAttachment)?.length,
      attachmentRange.location
    )
  }

  func testInvalidRangesNeverCrashAndReturnNil() {
    let projection = MarkdownTextPresentationProjection(
      source: "abc",
      attachments: [
        MarkdownTextPresentationAttachment(sourceRange: NSRange(location: 1, length: 1))
      ]
    )

    XCTAssertNil(projection.presentationOffset(forSourceOffset: -1))
    XCTAssertNil(projection.presentationOffset(forSourceOffset: 5))
    XCTAssertNil(projection.sourceOffset(forPresentationOffset: -1))
    XCTAssertNil(projection.sourceOffset(forPresentationOffset: 5))
    XCTAssertNil(
      projection.presentationRange(forSourceRange: NSRange(location: 2, length: 2))
    )
    XCTAssertNil(
      projection.sourceRange(forPresentationRange: NSRange(location: 2, length: 2))
    )
    XCTAssertNil(
      projection.presentationRange(forSourceRange: NSRange(location: -1, length: 0))
    )
  }

  func testNegativeLengthAndNSNotFoundRangesAreRejectedBeforeBoundsMath() {
    let source = "abc"
    let negativeLength = MarkdownTextPresentationAttachment(
      sourceRange: NSRange(location: 1, length: -1)
    )
    let notFound = MarkdownTextPresentationAttachment(
      sourceRange: NSRange(location: NSNotFound, length: 1)
    )
    let projection = MarkdownTextPresentationProjection(
      source: source,
      attachments: [notFound, negativeLength]
    )

    XCTAssertTrue(projection.acceptedAttachments.isEmpty)
    XCTAssertEqual(
      projection.rejectedAttachments.map(\.reason),
      [.negativeLength, .outOfBounds]
    )
    XCTAssertEqual(projection.presentation, source)
  }

  func testManyAttachmentsUseCompactSegmentStorage() throws {
    let attachmentCount = 2_000
    let source = String(repeating: "x----", count: attachmentCount)
    let attachments = stride(from: 0, to: (source as NSString).length, by: 5).map {
      MarkdownTextPresentationAttachment(sourceRange: NSRange(location: $0, length: 1))
    }
    let projection = MarkdownTextPresentationProjection(source: source, attachments: attachments)

    XCTAssertEqual(projection.acceptedAttachments.count, attachmentCount)
    XCTAssertEqual(projection.segments.count, attachmentCount * 2)
    XCTAssertEqual(
      projection.presentationUTF16Length,
      attachmentCount * 5
    )
    let middleSourceOffset = attachmentCount / 2 * 5 + 2
    let middlePresentationOffset = try XCTUnwrap(
      projection.presentationOffset(forSourceOffset: middleSourceOffset)
    )
    XCTAssertEqual(
      projection.sourceOffset(forPresentationOffset: middlePresentationOffset),
      middleSourceOffset
    )
  }

  func testNarrowRangeNearEndMapsThroughOnlyItsTrailingSegmentSemantics() throws {
    let attachmentCount = 2_000
    let source = String(repeating: "x----", count: attachmentCount)
    let attachments = stride(from: 0, to: (source as NSString).length, by: 5).map {
      MarkdownTextPresentationAttachment(sourceRange: NSRange(location: $0, length: 1))
    }
    let projection = MarkdownTextPresentationProjection(source: source, attachments: attachments)
    let narrowSourceRange = NSRange(
      location: (attachmentCount - 1) * 5 + 4,
      length: 1
    )

    let presentationRange = try XCTUnwrap(
      projection.presentationRange(forSourceRange: narrowSourceRange)
    )
    XCTAssertEqual(presentationRange.length, 1)
    XCTAssertEqual(
      projection.sourceRange(forPresentationRange: presentationRange),
      narrowSourceRange
    )
  }
}
