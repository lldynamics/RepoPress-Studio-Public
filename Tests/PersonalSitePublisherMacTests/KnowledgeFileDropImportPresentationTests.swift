import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import PersonalSitePublisherMac

final class KnowledgeFileDropImportPresentationTests: XCTestCase {
  func testRequestCarriesFirstDroppedFileAndDestinationTogether() throws {
    let fileURL = URL(fileURLWithPath: "/tmp/资料/../资料/图片.png")
    let folderID = UUID()

    let request = try XCTUnwrap(
      KnowledgeFileDropImportRequest.make(
        from: [fileURL],
        importDestination: .folder(folderID)
      )
    )

    XCTAssertEqual(request.sourceURLs, [fileURL.standardizedFileURL])
    XCTAssertEqual(request.importDestination, .folder(folderID))
  }

  func testRequestFiltersNonFileURLsAndDeduplicatesStandardizedPaths() throws {
    let fileURL = URL(fileURLWithPath: "/tmp/资料/图片.png")
    let equivalentFileURL = URL(fileURLWithPath: "/tmp/资料/./图片.png")
    let remoteURL = try XCTUnwrap(URL(string: "https://example.com/image.png"))

    let request = try XCTUnwrap(
      KnowledgeFileDropImportRequest.make(
        from: [remoteURL, fileURL, equivalentFileURL],
        importDestination: .preserveExisting
      )
    )

    XCTAssertEqual(request.sourceURLs, [fileURL.standardizedFileURL])
  }

  func testRequestRejectsDropWithoutLocalFiles() throws {
    let remoteURL = try XCTUnwrap(URL(string: "https://example.com/image.png"))

    XCTAssertNil(
      KnowledgeFileDropImportRequest.make(
        from: [remoteURL],
        importDestination: .preserveExisting
      )
    )
  }

  @MainActor
  func testDragExportsStoredBytesWithOriginalFilenameAndKeepsFileURLSupport() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let managedURL = directory.appendingPathComponent("content-hash.png")
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithURL(
        managedURL as CFURL, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let originalData = try Data(contentsOf: managedURL)
    let originalName = "旅行 照片.PNG"
    let provider = KnowledgeImageDocumentView.imageFileItemProvider(
      imageURL: managedURL, sourceName: originalName
    )
    XCTAssertEqual(provider.suggestedName, originalName)
    XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))

    let exported: (String, Data) = try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: UTType.png.identifier) { url, error in
        do {
          if let error { throw error }
          let fileURL = try XCTUnwrap(url)
          continuation.resume(returning: (fileURL.lastPathComponent, try Data(contentsOf: fileURL)))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
    XCTAssertEqual(exported.0, originalName)
    XCTAssertEqual(exported.1, originalData)
    XCTAssertEqual(try Data(contentsOf: managedURL), originalData)
  }
}
