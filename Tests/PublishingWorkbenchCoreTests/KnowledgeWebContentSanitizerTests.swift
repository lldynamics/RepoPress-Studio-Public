import Foundation
import XCTest
@testable import PublishingWorkbenchCore

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

  func testBrowserCaptureReSanitizesOriginalHTMLBeforeBuildingPreview() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-browser-clean-web-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let originalHTML = """
    <html><body>
      <nav>浏览器导航噪声</nav>
      <article><h1>浏览器正文</h1><p>插件保存后仍由应用再次净化。</p></article>
      <footer>浏览器页脚噪声</footer>
    </body></html>
    """
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/clean-article")),
      title: "浏览器正文",
      contentText: "这是插件回退文本，不应覆盖可用的原始 HTML。",
      originalHTML: originalHTML
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let preview = try await service.makeBrowserImportPreview(capture: capture)
    let candidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertEqual(candidate.originalData, Data(originalHTML.utf8))
    XCTAssertTrue(candidate.normalizedText.contains("应用再次净化"))
    XCTAssertFalse(candidate.normalizedText.contains("浏览器导航噪声"))
    XCTAssertFalse(candidate.normalizedText.contains("浏览器页脚噪声"))
    XCTAssertFalse(candidate.normalizedText.contains("插件回退文本"))
    XCTAssertTrue(candidate.warnings.contains { $0.contains("重新净化") })
  }

  func testBrowserCaptureFallbackTextRemovesSocialInteractionMetrics() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-browser-social-clean-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/social-post")),
      title: "社交平台正文",
      contentText: """
      这段内容应该进入资料库和搜索索引。
      浏览量 12.6万
      428 replies · 3.1K likes · 91 reposts
      查看全部 428 条回复
      """,
      originalHTML: nil
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let preview = try await service.makeBrowserImportPreview(capture: capture)
    let candidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertEqual(candidate.capturedText, capture.contentText)
    XCTAssertTrue(candidate.normalizedText.contains("应该进入资料库和搜索索引"))
    XCTAssertFalse(candidate.normalizedText.contains("12.6万"))
    XCTAssertFalse(candidate.normalizedText.contains("428 replies"))
    XCTAssertFalse(candidate.normalizedText.contains("查看全部"))

    let result = try await service.commit(preview)
    let documentID = try XCTUnwrap(result.documentIDs.first)
    XCTAssertEqual(try service.capturedText(documentID: documentID), capture.contentText)
    XCTAssertTrue(try service.normalizedText(documentID: documentID).contains("应该进入资料库"))
    XCTAssertFalse(try service.normalizedText(documentID: documentID).contains("12.6万"))
    XCTAssertFalse(try service.search(query: "12.6万").contains {
      $0.signals.contains(.fullText)
    })

    let database = try KnowledgeDatabase(
      fileURL: rootURL.appendingPathComponent("store/library.sqlite")
    )
    let revision = try XCTUnwrap(database.currentRevision(documentID: documentID))
    let capturedReference = try XCTUnwrap(revision.capturedTextStorageReference)
    XCTAssertEqual(
      try String(
        contentsOf: rootURL
          .appendingPathComponent("store")
          .appendingPathComponent(capturedReference),
        encoding: .utf8
      ),
      capture.contentText
    )
  }

  func testBrowserFallbackTextCanBeRecleanedOfflineWithoutRestoringSocialNoise() async throws {
    let rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("knowledge-browser-fallback-reclean-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/social-fallback")),
      title: "社交平台纯文本归档",
      contentText: """
      这是需要用于 AI 检索的正文。
      查看新帖子
      12
      所有人可以回复
      36
      """,
      originalHTML: nil
    )
    let importResult = try await service.commit(
      try await service.makeBrowserImportPreview(capture: capture)
    )
    let documentID = try XCTUnwrap(importResult.documentIDs.first)

    let previews = try await service.makeLocalContentRepairPreviews(
      documentIDs: [documentID],
      includingCurrentParserVersion: true
    )
    let preview = try XCTUnwrap(previews.first)
    let recleanedText = try XCTUnwrap(preview.importPreview.candidates.first?.normalizedText)

    XCTAssertTrue(recleanedText.contains("需要用于 AI 检索的正文"))
    XCTAssertFalse(recleanedText.contains("查看新帖子"))
    XCTAssertFalse(recleanedText.contains("所有人可以回复"))
    XCTAssertFalse(recleanedText.components(separatedBy: .newlines).contains("12"))
    XCTAssertFalse(recleanedText.components(separatedBy: .newlines).contains("36"))

    _ = try await service.applyLocalContentRepairs(previews)
    XCTAssertFalse(try service.search(query: "所有人可以回复").contains {
      $0.signals.contains(.fullText)
    })
    XCTAssertEqual(try service.capturedText(documentID: documentID), capture.contentText)
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
