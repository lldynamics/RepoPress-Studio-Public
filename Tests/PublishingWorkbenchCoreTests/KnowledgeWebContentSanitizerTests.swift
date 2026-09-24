import Foundation
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeWebContentSanitizerTests: XCTestCase {
  func testHTMLImportUsesSanitizedSectionsForNormalizedTextAndSearch() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-clean-web-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("article.html")
    try """
    <html><head><title>净化导入测试</title></head><body>
      <nav>导航专用噪声词</nav>
      <main>
        <h1>资料库正文</h1>
        <p>真正正文介绍离线语义检索和长期保存。</p>
        <div class="advertisement">广告专用噪声词</div>
      </main>
      <footer>页脚专用噪声词</footer>
    </body></html>
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    let candidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertTrue(candidate.normalizedText.contains("离线语义检索"))
    XCTAssertFalse(candidate.normalizedText.contains("导航专用噪声词"))
    XCTAssertFalse(candidate.normalizedText.contains("广告专用噪声词"))
    XCTAssertFalse(candidate.normalizedText.contains("页脚专用噪声词"))
    XCTAssertTrue(candidate.warnings.contains { $0.contains("净化") })

    _ = try await service.commit(preview)
    XCTAssertFalse(try service.search(query: "离线语义检索").isEmpty)
    XCTAssertFalse(try service.search(query: "广告专用噪声词").contains {
      $0.signals.contains(.fullText)
    })
  }

  func testLegacyHTMLImportCanReadOriginalArchiveWithoutCapturedTextSidecar() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-legacy-original-view-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let sourceURL = rootURL.appendingPathComponent("social.html")
    try """
    <html><body>
      <nav>旧归档导航</nav>
      <article>
        <h1>旧社交帖子</h1>
        <p>这是需要阅读和检索的正文。</p>
        <p>浏览量 12.6万</p>
      </article>
    </body></html>
    """.write(to: sourceURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    XCTAssertNil(preview.candidates.first?.capturedText)
    let result = try await service.commit(preview)
    let documentID = try XCTUnwrap(result.documentIDs.first)
    let originalText = try XCTUnwrap(service.capturedText(documentID: documentID))

    XCTAssertTrue(originalText.contains("旧归档导航"))
    XCTAssertTrue(originalText.contains("浏览量 12.6万"))
    XCTAssertTrue(originalText.contains("需要阅读和检索的正文"))
    XCTAssertFalse(try service.normalizedText(documentID: documentID).contains("旧归档导航"))
    XCTAssertFalse(try service.normalizedText(documentID: documentID).contains("12.6万"))
  }
}
