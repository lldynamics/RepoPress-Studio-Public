import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeLibraryManagementTests: XCTestCase {
  func testRecycleRestoreAndPermanentDeletePreserveThenCleanOwnedFiles() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-recycle")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.md")
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    try "# 回收站测试\n\n可恢复资料不应提前清理本地副本。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let revision = try XCTUnwrap(service.revisions(documentID: document.id).first)
    let storedFiles = [revision.originalStorageReference, revision.normalizedStorageReference]
      .compactMap { $0 }
      .map { storeURL.appendingPathComponent($0) }

    try service.moveToRecycleBin(documentIDs: [document.id])

    XCTAssertTrue(try service.documents().isEmpty)
    XCTAssertEqual(try service.recycledDocuments().map(\.id), [document.id])
    XCTAssertTrue(try service.search(query: "可恢复资料").isEmpty)
    XCTAssertTrue(storedFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

    try service.restoreFromRecycleBin(documentIDs: [document.id])

    XCTAssertEqual(try service.documents().map(\.id), [document.id])
    XCTAssertTrue(try service.recycledDocuments().isEmpty)
    XCTAssertFalse(try service.search(query: "可恢复资料").isEmpty)

    try service.moveToRecycleBin(documentIDs: [document.id])
    let report = try service.deleteDocument(id: document.id)

    XCTAssertEqual(report.failedStoredFileCount, 0)
    XCTAssertTrue(try service.recycledDocuments().isEmpty)
    XCTAssertTrue(storedFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
  }

  func testBatchMetadataAnnotationsAndBacklinksPersist() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-management")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let firstURL = rootURL.appendingPathComponent("first.md")
    let secondURL = rootURL.appendingPathComponent("second.md")
    try "# 第一条资料\n\n量子花园记录了长期研究线索。".write(
      to: firstURL,
      atomically: true,
      encoding: .utf8
    )
    try "# 第二条资料\n\n批量整理可以减少重复操作。".write(
      to: secondURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: firstURL))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: secondURL))
    let documents = try service.documents()
    let ids = Set(documents.map(\.id))
    let folder = try service.createFolder(name: "批量归档")

    try service.setFolder(folder.id, documentIDs: ids)
    try service.setAllowsRemoteAIUse(false, documentIDs: ids)
    try service.addTags(["量子花园标签"], documentIDs: ids)

    var updatedDocuments = try service.documents()
    XCTAssertTrue(updatedDocuments.allSatisfy { $0.folderID == folder.id })
    XCTAssertTrue(updatedDocuments.allSatisfy { !$0.allowsRemoteAIUse })
    XCTAssertTrue(updatedDocuments.allSatisfy { $0.tags.contains("量子花园标签") })

    let first = try XCTUnwrap(updatedDocuments.first { $0.sourceURL == firstURL })
    let updated = try service.updateMetadata(
      documentID: first.id,
      metadata: KnowledgeDocumentMetadata(
        kind: .article,
        title: "重命名后的研究资料",
        authors: ["林研究者"],
        language: "zh-CN",
        summary: "用于检验元数据与索引同步。",
        tags: first.tags
      )
    )
    XCTAssertEqual(updated.title, "重命名后的研究资料")
    XCTAssertEqual(updated.authors, ["林研究者"])
    XCTAssertTrue(try service.search(query: "重命名后的研究资料").contains {
      $0.document.id == first.id && $0.signals.contains(.title)
    })

    let hit = try XCTUnwrap(try service.search(query: "长期研究线索").first)
    let second = try XCTUnwrap(updatedDocuments.first { $0.id != first.id })
    XCTAssertThrowsError(try service.saveAnnotation(KnowledgeAnnotation(
      documentID: second.id,
      revisionID: hit.chunk.revisionID,
      chunkID: hit.chunk.id,
      note: "错误的跨资料锚点"
    )))
    let annotation = try service.saveAnnotation(KnowledgeAnnotation(
      documentID: first.id,
      revisionID: hit.chunk.revisionID,
      chunkID: hit.chunk.id,
      locator: hit.chunk.headingPath,
      highlightedText: "长期研究线索",
      note: "这里适合在文章结尾引用。"
    ))
    let storedAnnotation = try XCTUnwrap(service.annotations(documentID: first.id).first)
    XCTAssertEqual(storedAnnotation.id, annotation.id)
    XCTAssertEqual(storedAnnotation.chunkID, annotation.chunkID)
    XCTAssertEqual(storedAnnotation.note, annotation.note)

    let citation = KnowledgeCitation(
      id: "K1",
      documentID: first.id,
      chunkID: hit.chunk.id,
      title: updated.title,
      excerpt: hit.chunk.content
    )
    let target = KnowledgeBacklinkTarget(
      kind: .articleDraft,
      id: UUID().uuidString,
      title: "正在写的文章",
      location: "正文"
    )
    try service.recordBacklinks(citations: [citation], target: target)
    try service.recordBacklinks(citations: [citation], target: target)
    try service.recordBacklinks(
      citations: [citation],
      target: KnowledgeBacklinkTarget(
        kind: .aiResponse,
        id: UUID().uuidString,
        title: "AI 回复：正在写的文章"
      )
    )
    let backlinks = try service.backlinks(documentID: first.id)
    XCTAssertEqual(backlinks.count, 2)
    XCTAssertEqual(Set(backlinks.map(\.targetKind)), [.articleDraft, .aiResponse])
    let articleBacklinks = try service.backlinks(
      targetKind: .articleDraft,
      targetID: target.id
    )
    XCTAssertEqual(articleBacklinks.count, 1)
    XCTAssertEqual(articleBacklinks.first?.targetTitle, "正在写的文章")

    try service.deleteAnnotation(id: annotation.id)
    XCTAssertTrue(try service.annotations(documentID: first.id).isEmpty)

    try service.setAllowsRemoteAIUse(true, documentIDs: ids)
    updatedDocuments = try service.documents()
    XCTAssertTrue(updatedDocuments.allSatisfy(\.allowsRemoteAIUse))
    XCTAssertFalse(try service.search(query: "量子花园标签").isEmpty)

    let repair = try await service.repairSemanticVectors(documentIDs: ids)
    XCTAssertGreaterThan(repair.scannedChunkCount, 0)
    XCTAssertGreaterThanOrEqual(repair.regeneratedVectorCount, repair.scannedChunkCount)

    let exportURL = rootURL.appendingPathComponent("export", isDirectory: true)
    let export = try await service.exportDocuments(documentIDs: ids, to: exportURL)
    XCTAssertEqual(export.exportedDocumentCount, 2)
    let exportedFiles = try FileManager.default.contentsOfDirectory(
      at: exportURL,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "md" }
    XCTAssertEqual(exportedFiles.count, 2)
    let exportedText = try exportedFiles.map {
      try String(contentsOf: $0, encoding: .utf8)
    }.joined(separator: "\n")
    XCTAssertTrue(exportedText.contains("重命名后的研究资料"))
    XCTAssertTrue(exportedText.contains("量子花园标签"))
    XCTAssertTrue(exportedText.contains("批量整理可以减少重复操作"))
  }

  func testSourceRefreshCreatesVersionComparisonAndRollbackSwitchesSearchIndex() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-refresh")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("versioned.md")
    try "# 版本资料\n\n第一版独有词：琥珀航线。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let originalRevision = try XCTUnwrap(service.revisions(documentID: document.id).first)
    _ = try service.updateMetadata(
      documentID: document.id,
      metadata: KnowledgeDocumentMetadata(
        kind: document.kind,
        title: "用户整理后的版本资料",
        authors: ["版本管理员"],
        tags: ["版本跟踪"]
      )
    )

    try "# 版本资料\n\n第二版独有词：蓝鲸轨道。\n\n新增一行。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let refresh = try await service.makeSourceRefreshPreview(documentID: document.id)

    XCTAssertTrue(refresh.difference.hasChanges)
    XCTAssertGreaterThan(refresh.difference.addedLineCount, 0)
    XCTAssertEqual(refresh.importPreview.updateCount, 1)
    let result = try await service.applySourceRefresh(refresh)
    XCTAssertEqual(result.updatedCount, 1)
    XCTAssertEqual(try service.revisions(documentID: document.id).count, 2)
    XCTAssertEqual(try service.documents().first?.title, "用户整理后的版本资料")
    XCTAssertEqual(try service.documents().first?.authors, ["版本管理员"])
    XCTAssertTrue(try service.search(query: "蓝鲸轨道").contains { $0.chunk.content.contains("蓝鲸轨道") })
    XCTAssertFalse(try service.search(query: "琥珀航线").contains { $0.chunk.content.contains("琥珀航线") })
    XCTAssertTrue(try service.normalizedText(documentID: document.id).contains("蓝鲸轨道"))

    let comparison = try service.revisionDifference(
      documentID: document.id,
      revisionID: originalRevision.id
    )
    XCTAssertTrue(comparison.hasChanges)
    _ = try service.restoreRevision(documentID: document.id, revisionID: originalRevision.id)

    XCTAssertTrue(try service.search(query: "琥珀航线").contains { $0.chunk.content.contains("琥珀航线") })
    XCTAssertFalse(try service.search(query: "蓝鲸轨道").contains { $0.chunk.content.contains("蓝鲸轨道") })
    XCTAssertTrue(try service.normalizedText(documentID: document.id).contains("琥珀航线"))
    XCTAssertEqual(try service.documents().first?.currentRevisionID, originalRevision.id)
  }

  func testSearchDiversificationSuppressesNoiseDuplicatesAndDocumentMonopoly() {
    let noisyDocument = KnowledgeDocument(kind: .webpage, title: "网页壳")
    let usefulDocument = KnowledgeDocument(kind: .book, title: "研究书籍")
    let thirdDocument = KnowledgeDocument(kind: .article, title: "补充文章")
    let revisionID = UUID()
    func result(
      document: KnowledgeDocument,
      ordinal: Int,
      content: String,
      hash: String,
      score: Double
    ) -> KnowledgeSearchResult {
      KnowledgeSearchResult(
        document: document,
        chunk: KnowledgeChunk(
          documentID: document.id,
          revisionID: revisionID,
          ordinal: ordinal,
          content: content,
          tokenEstimate: 40,
          contentHash: hash
        ),
        score: score,
        signals: [.fullText]
      )
    }
    let candidates = [
      result(
        document: noisyDocument,
        ordinal: 0,
        content: "发表评论\n分享到\n较新的博文\n博客归档\nhttps://example.com/a\nhttps://example.com/b",
        hash: "noise",
        score: 1.1
      ),
      result(document: noisyDocument, ordinal: 1, content: "同一段落的重复正文", hash: "same", score: 1.0),
      result(document: noisyDocument, ordinal: 2, content: "同一段落的重复正文", hash: "same", score: 0.99),
      result(document: noisyDocument, ordinal: 3, content: "同一网页中的另一段有效正文，讨论知识连接。", hash: "other", score: 0.8),
      result(document: usefulDocument, ordinal: 0, content: "书籍章节说明如何保存来源并建立可靠引用。", hash: "book", score: 0.86),
      result(document: thirdDocument, ordinal: 0, content: "补充文章提供不同作者的独立论据和背景。", hash: "article", score: 0.78),
    ]

    let ranked = KnowledgeSearchDiversificationService().rank(candidates, limit: 5)

    XCTAssertNotEqual(ranked.first?.chunk.contentHash, "noise")
    XCTAssertLessThanOrEqual(ranked.filter { $0.document.id == noisyDocument.id }.count, 2)
    XCTAssertEqual(ranked.filter { $0.chunk.contentHash == "same" }.count, 1)
    XCTAssertEqual(Set(ranked.map { $0.document.id }).count, 3)
  }

  private func temporaryDirectory(named name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
