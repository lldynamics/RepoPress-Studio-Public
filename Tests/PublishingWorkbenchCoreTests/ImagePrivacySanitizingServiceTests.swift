import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PublishingWorkbenchCore

final class ImagePrivacySanitizingServiceTests: XCTestCase {
  private let service = ImagePrivacySanitizingService()

  func testInspectsAndSanitizesJPEGWithGPSExifTIFFAndIPTC() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("private.jpg")
    let destinationURL = directory.appendingPathComponent("public.jpg")
    try writeFixture(to: sourceURL, type: .jpeg, includesPrivateMetadata: true)

    let inspection = try service.inspect(at: sourceURL)
    XCTAssertTrue(inspection.sensitiveMetadata.contains(.gps))
    XCTAssertTrue(inspection.sensitiveMetadata.contains(.exif))
    XCTAssertTrue(inspection.sensitiveMetadata.contains(.iptc))
    XCTAssertTrue(inspection.sensitiveMetadata.contains(.tiffAuthorOrDevice))
    XCTAssertEqual(inspection.pixelWidth, 7)
    XCTAssertEqual(inspection.pixelHeight, 5)
    XCTAssertEqual(inspection.orientation, 6)

    let result = try service.sanitize(at: sourceURL, to: destinationURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
    XCTAssertEqual(result.method, .metadataCopy)
    XCTAssertTrue(result.originalInspection.requiresSanitization)
    XCTAssertFalse(result.sanitizedInspection.requiresSanitization)
    XCTAssertEqual(result.sanitizedInspection.pixelWidth, 7)
    XCTAssertEqual(result.sanitizedInspection.pixelHeight, 5)
    XCTAssertEqual(result.sanitizedInspection.orientation, 6)
    XCTAssertEqual(
      try service.inspect(at: sourceURL).sensitiveMetadata, inspection.sensitiveMetadata)
  }

  func testInspectsPNGLocallyAndIdentifiesImageWithoutSensitiveMetadata() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("plain.png")
    let destinationURL = directory.appendingPathComponent("copy.png")
    try writeFixture(to: sourceURL, type: .png, includesPrivateMetadata: false)

    let inspection = try service.inspect(at: sourceURL)
    XCTAssertFalse(inspection.requiresSanitization)
    XCTAssertEqual(inspection.pixelWidth, 7)
    XCTAssertEqual(inspection.pixelHeight, 5)

    let result = try service.sanitize(at: sourceURL, to: destinationURL)
    XCTAssertFalse(result.sanitizedInspection.requiresSanitization)
    XCTAssertEqual(result.sanitizedInspection.pixelWidth, 7)
  }

  func testRejectsInPlaceAndExistingDestinations() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("image.png")
    try writeFixture(to: sourceURL, type: .png, includesPrivateMetadata: false)

    XCTAssertThrowsError(try service.sanitize(at: sourceURL, to: sourceURL)) { error in
      XCTAssertEqual(
        error as? ImagePrivacySanitizingError, .destinationMustDiffer(path: sourceURL.path))
    }
    let destinationURL = directory.appendingPathComponent("existing.png")
    try Data("existing".utf8).write(to: destinationURL)
    XCTAssertThrowsError(try service.sanitize(at: sourceURL, to: destinationURL)) { error in
      XCTAssertEqual(
        error as? ImagePrivacySanitizingError, .destinationExists(path: destinationURL.path))
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ImagePrivacySanitizingServiceTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeFixture(
    to url: URL,
    type: UTType,
    includesPrivateMetadata: Bool
  ) throws {
    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
      CGContext(
        data: nil,
        width: 7,
        height: 5,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 7, height: 5))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(
        url as CFURL,
        type.identifier as CFString,
        1,
        nil
      ))
    var properties: [CFString: Any] = [kCGImagePropertyOrientation: 6]
    if includesPrivateMetadata {
      properties[kCGImagePropertyGPSDictionary] = [
        kCGImagePropertyGPSLatitude: 31.2304,
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLongitude: 121.4737,
        kCGImagePropertyGPSLongitudeRef: "E",
      ]
      properties[kCGImagePropertyExifDictionary] = [
        kCGImagePropertyExifDateTimeOriginal: "2026:08:28 12:00:00",
        kCGImagePropertyExifBodySerialNumber: "camera-serial",
      ]
      properties[kCGImagePropertyIPTCDictionary] = [
        kCGImagePropertyIPTCByline: "Private Author",
        kCGImagePropertyIPTCCity: "Shanghai",
      ]
      properties[kCGImagePropertyTIFFDictionary] = [
        kCGImagePropertyTIFFArtist: "Private Author",
        kCGImagePropertyTIFFMake: "Private Camera",
        kCGImagePropertyTIFFModel: "Model 1",
      ]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }
}
