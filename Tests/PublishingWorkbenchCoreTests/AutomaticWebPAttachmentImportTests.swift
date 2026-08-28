import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
final class AutomaticWebPAttachmentImportTests: XCTestCase {
  func testResultRoundsAndBoundsSavedPercentage() {
    let attachment = DraftAttachment(
      originalFilename: "image.webp",
      relativePublishPath: "/images/image.webp",
      repositoryPath: "static/images/image.webp"
    )

    let result = WorkbenchStore.AutomaticWebPAttachmentImportResult(
      attachment: attachment,
      wasConvertedToWebP: true,
      originalByteSize: 1_000,
      finalByteSize: 277
    )

    XCTAssertEqual(result.savedBytes, 723)
    XCTAssertEqual(result.savedPercentage, 72)
  }

  func testAlreadyWebPImportKeepsProfileDerivedPathAndManagedCopy() async throws {
    let root = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "AutomaticWebPAttachmentImport"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("ready.webp")
    try Data("existing-webp".utf8).write(to: sourceURL)
    let fileStore = ManagedAttachmentFileStore(
      rootDirectoryURL: root.appendingPathComponent("Managed", isDirectory: true)
    )
    let store = try TestWorkbenchFactory.makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "WebP",
      date: fixedDate(),
      slug: "webp"
    )

    let result = try await store.makeAutomaticWebPAttachment(
      from: sourceURL,
      draft: draft,
      fileStore: fileStore
    )

    XCTAssertFalse(result.wasConvertedToWebP)
    XCTAssertEqual(result.attachment.repositoryPath, "static/images/2026/ready.webp")
    XCTAssertEqual(result.attachment.relativePublishPath, "/images/2026/ready.webp")
    XCTAssertEqual(result.originalByteSize, result.finalByteSize)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: try XCTUnwrap(result.attachment.sourceFilePath)
      )
    )
  }

  func testPNGImportConvertsToWebPAndRemovesManagedOriginal() async throws {
    guard SiteImageWorkbenchService.supportsWebPEncoding else {
      throw XCTSkip("Current test environment has no WebP encoder.")
    }
    let root = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "AutomaticWebPAttachmentConversion"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("diagram.png")
    try writeTestImage(at: sourceURL, width: 180, height: 120, type: .png)
    let managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
    let fileStore = ManagedAttachmentFileStore(rootDirectoryURL: managedRoot)
    let store = try TestWorkbenchFactory.makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Diagram",
      date: fixedDate(),
      slug: "diagram"
    )

    let result = try await store.makeAutomaticWebPAttachment(
      from: sourceURL,
      draft: draft,
      fileStore: fileStore
    )

    XCTAssertTrue(result.wasConvertedToWebP)
    XCTAssertEqual(result.attachment.originalFilename, "diagram.webp")
    XCTAssertEqual(result.attachment.repositoryPath, "static/images/2026/diagram.webp")
    XCTAssertEqual(result.attachment.relativePublishPath, "/images/2026/diagram.webp")
    let finalURL = URL(fileURLWithPath: try XCTUnwrap(result.attachment.sourceFilePath))
    XCTAssertEqual(finalURL.pathExtension, "webp")
    XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
    let remainingFiles = try FileManager.default.contentsOfDirectory(
      at: finalURL.deletingLastPathComponent(),
      includingPropertiesForKeys: nil
    ).filter { !$0.lastPathComponent.hasPrefix(".") }
    XCTAssertEqual(remainingFiles.count, 1)
    XCTAssertEqual(
      remainingFiles.first?.resolvingSymlinksInPath(),
      finalURL.resolvingSymlinksInPath()
    )
  }

  func testConversionFailureCleansManagedAttachmentDirectory() async throws {
    let root = try TestWorkbenchFactory.temporaryDirectoryURL(
      prefix: "AutomaticWebPAttachmentFailure"
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let sourceURL = root.appendingPathComponent("invalid.png")
    try Data("not-an-image".utf8).write(to: sourceURL)
    let managedRoot = root.appendingPathComponent("Managed", isDirectory: true)
    let fileStore = ManagedAttachmentFileStore(rootDirectoryURL: managedRoot)
    let store = try TestWorkbenchFactory.makeStore()
    let draft = ArticleDraft(
      siteProfileID: store.activeProfileID,
      title: "Invalid",
      date: fixedDate(),
      slug: "invalid"
    )

    do {
      _ = try await store.makeAutomaticWebPAttachment(
        from: sourceURL,
        draft: draft,
        fileStore: fileStore
      )
      XCTFail("Expected invalid raster conversion to fail.")
    } catch {
      let contents = try FileManager.default.contentsOfDirectory(
        at: managedRoot,
        includingPropertiesForKeys: nil
      )
      XCTAssertTrue(contents.isEmpty)
    }
  }

  private func fixedDate() -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 8
    components.day = 27
    return components.date!
  }

  private func writeTestImage(
    at url: URL,
    width: Int,
    height: Int,
    type: UTType
  ) throws {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
      pixels[index] = UInt8((index / 4) % 251)
      pixels[index + 1] = UInt8((index / 7) % 239)
      pixels[index + 2] = UInt8((index / 11) % 227)
      pixels[index + 3] = 255
    }
    guard
      let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        type.identifier as CFString,
        1,
        nil
      )
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CocoaError(.fileWriteUnknown)
    }
  }
}
