import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PublishingWorkbenchCore

final class ImagePrivacyWorkflowTests: XCTestCase {
  func testManagedImportRemovesSensitiveMetadataByDefault() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("phone-photo.jpg")
    try writeSensitiveJPEG(to: sourceURL)

    let sanitizer = ImagePrivacySanitizingService()
    XCTAssertTrue(try sanitizer.inspect(at: sourceURL).requiresSanitization)

    let store = ManagedAttachmentFileStore(
      rootDirectoryURL: root.appendingPathComponent("Managed", isDirectory: true)
    )
    let managedURL = try store.storeFile(at: sourceURL, attachmentID: UUID())

    XCTAssertNotEqual(managedURL.standardizedFileURL, sourceURL.standardizedFileURL)
    XCTAssertFalse(try sanitizer.inspect(at: managedURL).requiresSanitization)
  }

  func testWorkbenchReportBatchAndPreflightSharePrivacyState() throws {
    let root = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("location.jpg")
    try writeSensitiveJPEG(to: sourceURL)

    let attachment = DraftAttachment(
      originalFilename: "location.jpg",
      relativePublishPath: "/images/location.jpg",
      repositoryPath: "static/images/location.jpg",
      altText: "Location",
      byteSize: Int64((try Data(contentsOf: sourceURL)).count),
      sourceFilePath: sourceURL.path
    )
    let profile = SiteProfile.defaultProfile
    let draft = ArticleDraft(
      siteProfileID: profile.id,
      title: "Privacy",
      slug: "privacy",
      bodyMarkdown: "![Location](/images/location.jpg)",
      attachments: [attachment]
    )
    let workbench = SiteImageWorkbenchService()

    let report = workbench.report(draft: draft, profile: profile)
    XCTAssertEqual(report.sensitiveMetadataCount, 1)
    XCTAssertEqual(report.items.first?.privacyStatus, .sensitive)
    XCTAssertTrue(report.issues.contains { $0.kind == .sensitiveMetadata })

    let preflight = PreflightCheckService().run(
      draft: draft,
      allDrafts: [draft],
      profile: profile,
      includeRepositoryReadiness: false
    )
    XCTAssertTrue(
      preflight.contains {
        $0.title == "图片包含隐私元数据"
          && $0.severity == .error
          && $0.category == .publicRisk
      })

    let result = try workbench.sanitizeImagePrivacyAttachments(
      draft: draft,
      destinationDirectory: root.appendingPathComponent("Sanitized", isDirectory: true)
    )
    XCTAssertEqual(result.optimizedCount, 1)
    let updatedAttachment = try XCTUnwrap(result.draft.attachments.first)
    let sanitizedPath = try XCTUnwrap(updatedAttachment.sourceFilePath)
    XCTAssertNotEqual(sanitizedPath, sourceURL.path)
    XCTAssertFalse(
      try ImagePrivacySanitizingService().inspect(
        at: URL(fileURLWithPath: sanitizedPath)
      ).requiresSanitization
    )

    let cleanPreflight = PreflightCheckService().run(
      draft: result.draft,
      allDrafts: [result.draft],
      profile: profile,
      includeRepositoryReadiness: false
    )
    XCTAssertFalse(cleanPreflight.contains { $0.title == "图片包含隐私元数据" })
  }

  private func writeSensitiveJPEG(to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: 4,
        height: 3,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      return XCTFail("Unable to create JPEG fixture")
    }

    let properties: [CFString: Any] = [
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLatitude: 31.2304,
        kCGImagePropertyGPSLongitudeRef: "E",
        kCGImagePropertyGPSLongitude: 121.4737,
      ],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifDateTimeOriginal: "2026:08:28 12:00:00"
      ],
      kCGImagePropertyTIFFDictionary: [
        kCGImagePropertyTIFFMake: "Private Camera",
        kCGImagePropertyTIFFModel: "Serial Device",
      ],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ImagePrivacyWorkflowTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
