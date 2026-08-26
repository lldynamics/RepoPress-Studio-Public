import CoreGraphics
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import XCTest
@testable import PersonalSitePublisherMac

final class WorkbenchThumbnailViewTests: XCTestCase {
  func testRequestConvertsPixelBudgetToDisplayPoints() {
    let request = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/example.png"),
      maxPixelSize: 512,
      displayScale: 2
    )

    XCTAssertEqual(request.quickLookRequest.size, CGSize(width: 256, height: 256))
    XCTAssertEqual(request.quickLookRequest.scale, 2)
    XCTAssertEqual(request.quickLookRequest.representationTypes, .thumbnail)
  }

  func testRequestClampsPixelBudget() {
    let tooSmall = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/small.png"),
      maxPixelSize: 0,
      displayScale: 1
    )
    let tooLarge = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/large.png"),
      maxPixelSize: 8_192,
      displayScale: 1
    )

    XCTAssertEqual(tooSmall.quickLookRequest.size, CGSize(width: 1, height: 1))
    XCTAssertEqual(tooLarge.quickLookRequest.size, CGSize(width: 4_096, height: 4_096))
  }

  func testRequestFallsBackToUnitScaleForInvalidDisplayScale() {
    let request = WorkbenchThumbnailRequest(
      fileURL: URL(fileURLWithPath: "/tmp/example.png"),
      maxPixelSize: 128,
      displayScale: .nan
    )

    XCTAssertEqual(request.quickLookRequest.scale, 1)
    XCTAssertEqual(request.quickLookRequest.size, CGSize(width: 128, height: 128))
  }

  func testImageIOThumbnailRespectsPixelBudgetFor4KImage() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("workbench-thumbnail-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }

    let width = 4_096
    let height = 2_160
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.setFillColor(CGColor(gray: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    )
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let thumbnail = try XCTUnwrap(
      WorkbenchImageIOThumbnailDecoder.downsampledImage(
        at: url,
        maxPixelSize: WorkbenchThumbnailSizing.listMaxPixelSize
      )
    )
    XCTAssertLessThanOrEqual(thumbnail.width, WorkbenchThumbnailSizing.listMaxPixelSize)
    XCTAssertLessThanOrEqual(thumbnail.height, WorkbenchThumbnailSizing.listMaxPixelSize)
  }
}
