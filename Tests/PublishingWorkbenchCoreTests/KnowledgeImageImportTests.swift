import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import XCTest

@testable import PublishingWorkbenchCore

final class KnowledgeImageImportTests: XCTestCase {
  func testImageImportStoresSanitizedOriginalWithoutExternalSourceAndDisablesSemanticIndex()
    async throws
  {
    let rootURL = try temporaryDirectory(named: "knowledge-image-import")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("外部图片.png")
    try makePNG().write(to: sourceURL, options: .atomic)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    let candidate = try XCTUnwrap(preview.candidates.first)
    XCTAssertEqual(candidate.kind, .image)
    XCTAssertNil(candidate.sourceURL)
    XCTAssertEqual(candidate.allowsLocalSemanticIndex, false)
    XCTAssertEqual(candidate.imageMetadata?.wasPrivacySanitized, true)

    let result = try await service.commit(preview)
    let documentID = try XCTUnwrap(result.documentIDs.first)
    let document = try XCTUnwrap(service.document(id: documentID))
    XCTAssertEqual(document.kind, .image)
    XCTAssertNil(document.sourceURL)
    XCTAssertFalse(document.allowsLocalSemanticIndex)
    let managedURL = try XCTUnwrap(try service.originalFileURL(documentID: documentID))
    XCTAssertTrue(FileManager.default.fileExists(atPath: managedURL.path))
    XCTAssertNotEqual(managedURL.standardizedFileURL, sourceURL.standardizedFileURL)
    XCTAssertTrue(managedURL.path.hasPrefix(rootURL.appendingPathComponent("store").path + "/"))
    XCTAssertEqual(
      try sqliteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings;",
        at: rootURL.appendingPathComponent("store/library.sqlite")
      ), 0)
  }

  func testExactSanitizedImageHashIsDuplicateAndOCRAnchorRoundTripsThroughSQLite() async throws {
    let rootURL = try temporaryDirectory(named: "knowledge-image-dedup")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("same.png")
    let imageData = try makePNG()
    try imageData.write(to: sourceURL, options: .atomic)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let firstPreview = try await service.makeImportPreview(sourceURL: sourceURL)
    _ = try await service.commit(firstPreview)
    let secondPreview = try await service.makeImportPreview(sourceURL: sourceURL)
    XCTAssertEqual(secondPreview.candidates.first?.disposition, .duplicate)

    let anchor = KnowledgeVisualAnchor(
      x: 0.2, y: 0.3, width: 0.4, height: 0.2, confidence: 0.8
    )
    let text = "区域 OCR 文本"
    let candidate = KnowledgeImportCandidate(
      kind: .image,
      title: "含区域的图片",
      sourceName: "anchor.png",
      allowsLocalSemanticIndex: false,
      originalFilenameExtension: "png",
      imageMetadata: KnowledgeImageMetadata(
        imageTypeIdentifier: "public.png", pixelWidth: 2, pixelHeight: 2,
        frameCount: 1, recognizedRegionCount: 1, wasPrivacySanitized: true
      ),
      originalData: imageData,
      capturedText: text,
      originalContentHash: KnowledgeChunkingService.contentHash(for: imageData),
      normalizedText: text,
      normalizedContentHash: KnowledgeChunkingService.contentHash(for: text),
      sections: [KnowledgeExtractedSection(text: text, visualAnchor: anchor)]
    )
    let result = try await service.commit(
      KnowledgeImportPreview(
        sourceName: "anchor", candidates: [candidate]
      ))
    let documentID = try XCTUnwrap(result.documentIDs.first)
    let searchResult = try XCTUnwrap(try service.search(query: text).first)
    XCTAssertEqual(searchResult.document.id, documentID)
    XCTAssertEqual(searchResult.chunk.visualAnchor, anchor)
    let anchorJSON = try sqliteText(
      "SELECT visual_anchor_json FROM knowledge_chunks WHERE document_id = '\(documentID.uuidString)';",
      at: rootURL.appendingPathComponent("store/library.sqlite")
    )
    XCTAssertTrue(anchorJSON.contains("confidence"))
  }

  @MainActor
  func testImageStoreLoadsCleanCapturedTextInsteadOfLocatorDecoratedNormalizedText() async throws {
    let rootURL = try temporaryDirectory(named: "knowledge-image-captured-text")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let imageData = try makePNG()
    let capturedText = "第一行 OCR 文字\n第二行 OCR 文字"
    let normalizedText = "[OCR 区域]\n\n第一行 OCR 文字\n\n[OCR 区域]\n\n第二行 OCR 文字"
    let candidate = KnowledgeImportCandidate(
      kind: .image,
      title: "OCR 显示测试",
      sourceName: "captured-text.png",
      allowsLocalSemanticIndex: false,
      originalFilenameExtension: "png",
      imageMetadata: KnowledgeImageMetadata(
        imageTypeIdentifier: "public.png", pixelWidth: 2, pixelHeight: 2,
        frameCount: 1, recognizedRegionCount: 2, wasPrivacySanitized: true
      ),
      originalData: imageData,
      capturedText: capturedText,
      originalContentHash: KnowledgeChunkingService.contentHash(for: imageData),
      normalizedText: normalizedText,
      normalizedContentHash: KnowledgeChunkingService.contentHash(for: normalizedText),
      sections: [
        KnowledgeExtractedSection(locator: "OCR 区域", text: "第一行 OCR 文字"),
        KnowledgeExtractedSection(locator: "OCR 区域", text: "第二行 OCR 文字"),
      ]
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let result = try await service.commit(
      KnowledgeImportPreview(sourceName: "captured-text", candidates: [candidate])
    )
    let documentID = try XCTUnwrap(result.documentIDs.first)
    let store = KnowledgeStore(service: service)
    await store.reload()

    store.loadDocument(documentID)
    for _ in 0..<100 {
      let isLoading =
        store.isLoadingSelectedDocumentText || store.isLoadingSelectedDocumentCapturedText
      guard isLoading else { break }
      try await Task.sleep(for: .milliseconds(10))
    }

    XCTAssertEqual(store.selectedDocumentText, normalizedText)
    XCTAssertEqual(store.selectedDocumentCapturedText, capturedText)
    XCTAssertFalse(try XCTUnwrap(store.selectedDocumentCapturedText).contains("[OCR 区域]"))
  }

  func testDisguisedImageExtensionFailsClosed() async throws {
    let rootURL = try temporaryDirectory(named: "knowledge-image-disguised")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("actually-png.jpg")
    try makePNG().write(to: sourceURL, options: .atomic)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    do {
      _ = try await service.makeImportPreview(sourceURL: sourceURL)
      XCTFail("实际 PNG 伪装为 JPG 必须被拒绝")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("扩展名与实际类型不一致"))
    }
  }

  private func makePNG() throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { throw TestError.imageCreation }
    context.setFillColor(red: 0.1, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    guard let image = context.makeImage() else { throw TestError.imageCreation }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data, "public.png" as CFString, 1, nil
      )
    else { throw TestError.imageCreation }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw TestError.imageCreation }
    return data as Data
  }

  private func temporaryDirectory(named name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(name)-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func sqliteInt(_ sql: String, at url: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else { throw TestError.sqlite }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw TestError.sqlite }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw TestError.sqlite }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func sqliteText(_ sql: String, at url: URL) throws -> String {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let database
    else { throw TestError.sqlite }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw TestError.sqlite }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let value = sqlite3_column_text(statement, 0)
    else { throw TestError.sqlite }
    return String(cString: value)
  }

  private enum TestError: Error { case imageCreation, sqlite }
}
