import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeImageExportTests: XCTestCase {
  func testOriginalExportPreservesBytesAndUsesCollisionSuffixWithoutChangingSource() async throws {
    let rootURL = try temporaryDirectory(named: "knowledge-image-export-original")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source/海边照片.png")
    let exportURL = rootURL.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
    let sourceData = try makeImageData(type: "public.png", includesSensitiveMetadata: false)
    try sourceData.write(to: sourceURL, options: .atomic)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await importImage(sourceURL, using: service)
    let managedURL = try XCTUnwrap(try service.originalFileURL(documentID: documentID))
    let managedBytesBeforeExport = try Data(contentsOf: managedURL)
    let preexistingURL = exportURL.appendingPathComponent("海边照片.png")
    let preexistingBytes = Data("keep existing export".utf8)
    try preexistingBytes.write(to: preexistingURL, options: .atomic)

    let report = try await service.exportImages(
      documentIDs: [documentID], to: exportURL, mode: .originalFile)
    XCTAssertEqual(report.exportedCount, 1)
    let outputURL = try exportedURL(from: report)
    XCTAssertEqual(outputURL.lastPathComponent, "海边照片 (2).png")
    XCTAssertEqual(try Data(contentsOf: outputURL), managedBytesBeforeExport)
    XCTAssertEqual(try Data(contentsOf: managedURL), managedBytesBeforeExport)
    XCTAssertEqual(try Data(contentsOf: preexistingURL), preexistingBytes)
  }

  func testMixedSelectionContinuesAfterMissingImageAndSkipsNonImage() async throws {
    let rootURL = try temporaryDirectory(named: "knowledge-image-export-mixed")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceDirectory = rootURL.appendingPathComponent("source", isDirectory: true)
    let exportURL = rootURL.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let goodSourceURL = sourceDirectory.appendingPathComponent("good.png")
    let missingSourceURL = sourceDirectory.appendingPathComponent("missing.png")
    try makeImageData(type: "public.png", includesSensitiveMetadata: false).write(
      to: goodSourceURL, options: .atomic)
    try makeImageData(type: "public.png", includesSensitiveMetadata: true).write(
      to: missingSourceURL, options: .atomic)
    let goodID = try await importImage(goodSourceURL, using: service)
    let missingID = try await importImage(missingSourceURL, using: service)
    XCTAssertNotEqual(goodID, missingID, "测试夹具必须创建两个独立的图片资料。")
    let textSourceURL = sourceDirectory.appendingPathComponent("notes.txt")
    try "不应作为图片导出。".write(to: textSourceURL, atomically: true, encoding: .utf8)
    let textPreview = try await service.makeImportPreview(sourceURL: textSourceURL)
    let textCommit = try await service.commit(textPreview)
    let textID = try XCTUnwrap(textCommit.documentIDs.first)
    let missingManagedURL = try XCTUnwrap(try service.originalFileURL(documentID: missingID))
    try FileManager.default.removeItem(at: missingManagedURL)

    let report = try await service.exportImages(
      documentIDs: [goodID, missingID, textID], to: exportURL, mode: .originalFile)
    XCTAssertEqual(report.exportedCount, 1)
    XCTAssertEqual(report.failedCount, 1)
    XCTAssertEqual(report.skippedCount, 1)
    XCTAssertTrue(
      report.items.contains { item in
        guard item.documentID == missingID else { return false }
        if case .failed = item.outcome { return true }
        return false
      })
    XCTAssertTrue(
      report.items.contains { item in
        guard item.documentID == textID else { return false }
        if case .skipped = item.outcome { return true }
        return false
      })
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: exportURL.appendingPathComponent("good.png").path))
  }

  func testPrivacyShareCopyRemovesSensitiveMetadataAndPreservesManagedOriginal() async throws {
    let rootURL = try temporaryDirectory(named: "knowledge-image-export-privacy")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source/private.jpg")
    let exportURL = rootURL.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
    try makeImageData(type: "public.jpeg", includesSensitiveMetadata: true).write(
      to: sourceURL, options: .atomic)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await importImage(sourceURL, using: service)
    let managedURL = try XCTUnwrap(try service.originalFileURL(documentID: documentID))
    let originalBytes = try Data(contentsOf: managedURL)
    XCTAssertTrue(try containsSensitiveEXIF(at: managedURL))

    let report = try await service.exportImages(
      documentIDs: [documentID], to: exportURL, mode: .privacySanitizedShareCopy)
    XCTAssertEqual(report.exportedCount, 1)
    let outputURL = try exportedURL(from: report)
    XCTAssertFalse(try containsSensitiveEXIF(at: outputURL))
    XCTAssertEqual(try Data(contentsOf: managedURL), originalBytes)
    XCTAssertTrue(try containsSensitiveEXIF(at: managedURL))
  }

  func testRejectsLibraryDestinationAndReportsSymlinkedManagedSourceAsFailure() async throws {
    let rootURL = try temporaryDirectory(named: "knowledge-image-export-path")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source/linked.png")
    let externalURL = rootURL.appendingPathComponent("external.png")
    let exportURL = rootURL.appendingPathComponent("export", isDirectory: true)
    try FileManager.default.createDirectory(
      at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: exportURL, withIntermediateDirectories: true)
    let data = try makeImageData(type: "public.png", includesSensitiveMetadata: false)
    try data.write(to: sourceURL, options: .atomic)
    try data.write(to: externalURL, options: .atomic)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let documentID = try await importImage(sourceURL, using: service)

    do {
      _ = try await service.exportImages(
        documentIDs: [documentID], to: service.rootURL, mode: .originalFile)
      XCTFail("导出目标在资料库内必须被拒绝")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("资料库目录"))
    }

    let managedURL = try XCTUnwrap(try service.originalFileURL(documentID: documentID))
    try FileManager.default.removeItem(at: managedURL)
    try FileManager.default.createSymbolicLink(at: managedURL, withDestinationURL: externalURL)
    let report = try await service.exportImages(
      documentIDs: [documentID], to: exportURL, mode: .originalFile)
    XCTAssertEqual(report.exportedCount, 0)
    XCTAssertEqual(report.failedCount, 1)
  }

  func testMultiFrameImageExportsOnlyAsOriginalAndFailsForPrivacyShareCopy() async throws {
    let rootURL = try temporaryDirectory(named: "knowledge-image-export-multiframe")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let originalExportURL = rootURL.appendingPathComponent("original-export", isDirectory: true)
    let privacyExportURL = rootURL.appendingPathComponent("privacy-export", isDirectory: true)
    try FileManager.default.createDirectory(
      at: originalExportURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: privacyExportURL, withIntermediateDirectories: true)
    let data = try makeTwoFrameGIF()
    XCTAssertEqual(try frameCount(in: data), 2, "多帧 GIF 夹具必须包含两帧。")
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("library"))
    let text = "两帧图片"
    let candidate = KnowledgeImportCandidate(
      kind: .image,
      title: "动画图片",
      sourceName: "animated.gif",
      allowsLocalSemanticIndex: false,
      originalFilenameExtension: "gif",
      imageMetadata: KnowledgeImageMetadata(
        imageTypeIdentifier: "com.compuserve.gif",
        pixelWidth: 2,
        pixelHeight: 2,
        frameCount: 2,
        recognizedRegionCount: 0
      ),
      originalData: data,
      capturedText: text,
      originalContentHash: KnowledgeChunkingService.contentHash(for: data),
      normalizedText: text,
      normalizedContentHash: KnowledgeChunkingService.contentHash(for: text),
      sections: [KnowledgeExtractedSection(text: text)]
    )
    let multiFrameCommit = try await service.commit(
      KnowledgeImportPreview(sourceName: "animated", candidates: [candidate])
    )
    let documentID = try XCTUnwrap(multiFrameCommit.documentIDs.first)

    let originalReport = try await service.exportImages(
      documentIDs: [documentID], to: originalExportURL, mode: .originalFile)
    XCTAssertEqual(originalReport.exportedCount, 1)
    XCTAssertEqual(try Data(contentsOf: exportedURL(from: originalReport)), data)

    let privacyReport = try await service.exportImages(
      documentIDs: [documentID], to: privacyExportURL, mode: .privacySanitizedShareCopy)
    XCTAssertEqual(privacyReport.exportedCount, 0)
    XCTAssertEqual(privacyReport.failedCount, 1)
    guard case .failed(let reason) = try XCTUnwrap(privacyReport.items.first).outcome else {
      return XCTFail("多帧图片的分享副本必须明确失败")
    }
    XCTAssertTrue(reason.contains("多帧"))
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: privacyExportURL.path).isEmpty)
  }

  private func importImage(_ sourceURL: URL, using service: KnowledgeLibraryService) async throws
    -> UUID
  {
    let preview = try await service.makeImportPreview(
      sourceURL: sourceURL,
      options: KnowledgeImportOptions(performsImageOCR: false)
    )
    let result = try await service.commit(preview)
    return try XCTUnwrap(result.documentIDs.first)
  }

  private func exportedURL(from report: KnowledgeImageExportReport) throws -> URL {
    guard let item = report.items.first,
      case .exported(let destinationURL) = item.outcome
    else { throw TestError.missingExport }
    return destinationURL
  }

  private func containsSensitiveEXIF(at url: URL) throws -> Bool {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    else { return false }
    return exif[kCGImagePropertyExifUserComment] != nil
  }

  private func makeImageData(type: String, includesSensitiveMetadata: Bool) throws -> Data {
    let image = try makeRasterImage(red: 0.1, green: 0.4, blue: 0.8)
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil)
    else { throw TestError.imageCreation }
    var properties: [CFString: Any] = [:]
    if includesSensitiveMetadata {
      properties[kCGImagePropertyExifDictionary] = [
        kCGImagePropertyExifUserComment: "private camera note"
      ]
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw TestError.imageCreation }
    return data as Data
  }

  private func makeTwoFrameGIF() throws -> Data {
    let firstImage = try makeRasterImage(red: 0.1, green: 0.4, blue: 0.8)
    let secondImage = try makeRasterImage(red: 0.8, green: 0.2, blue: 0.1)
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, "com.compuserve.gif" as CFString, 2, nil
      )
    else { throw TestError.imageCreation }
    CGImageDestinationSetProperties(
      destination,
      [
        kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFLoopCount: 0
        ]
      ] as CFDictionary
    )
    let frameProperties: [CFString: Any] = [
      kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFDelayTime: 0.1
      ]
    ]
    CGImageDestinationAddImage(destination, firstImage, frameProperties as CFDictionary)
    CGImageDestinationAddImage(destination, secondImage, frameProperties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw TestError.imageCreation }
    return data as Data
  }

  private func makeRasterImage(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: 2,
        height: 2,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { throw TestError.imageCreation }
    context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    guard let image = context.makeImage() else { throw TestError.imageCreation }
    return image
  }

  private func frameCount(in data: Data) throws -> Int {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw TestError.imageCreation
    }
    return CGImageSourceGetCount(source)
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(name)-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private enum TestError: Error {
    case imageCreation
    case missingExport
  }
}
