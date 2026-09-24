import AppKit
import Foundation
import PDFKit
import SQLite3
import XCTest

@testable import PublishingKnowledgeCore

final class KnowledgeLibraryServiceTests: XCTestCase {
  private final class ControlledDenseProvider: @unchecked Sendable,
    KnowledgeSemanticEmbeddingProvider
  {
    let descriptor = KnowledgeSemanticEmbeddingDescriptor(
      modelIdentifier: "test-dense-background-v1",
      dimension: 2,
      minimumSimilarity: 0,
      maximumTokenCount: 32,
      weightsVersion: "fixture",
      artifactDigest: "fixture-dense",
      preprocessingVersion: "fixture"
    )
    private let lock = NSLock()
    private var passageEnabled = false

    func enablePassages() {
      lock.lock()
      passageEnabled = true
      lock.unlock()
    }

    func vector(for input: KnowledgeSemanticEmbeddingInput) -> KnowledgeSemanticVector? {
      lock.lock()
      let canEmbedPassage = passageEnabled
      lock.unlock()
      guard input.role == .query || canEmbedPassage else { return nil }
      return KnowledgeSemanticVector(
        modelIdentifier: descriptor.modelIdentifier,
        values: [1, 1],
        minimumSimilarity: 0,
        encodingVersion: descriptor.encodingVersion
      )
    }
  }

  private struct TemporarilyUnavailableEmbeddingProvider: KnowledgeSemanticEmbeddingProvider {
    let descriptor = KnowledgeSemanticEmbeddingDescriptor(
      modelIdentifier: "bundled-bge-test",
      dimension: 2,
      minimumSimilarity: 0,
      maximumTokenCount: 32,
      weightsVersion: "fixture",
      preprocessingVersion: "fixture",
      availability: .temporarilyUnavailable
    )

    func vector(for input: KnowledgeSemanticEmbeddingInput) -> KnowledgeSemanticVector? { nil }
  }

  func testFullRepairPreservesKnownTemporarilyUnavailableProviderVectors() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-temporarily-unavailable")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("chapter.md")
    try "# 本地模型\n\n即使模型资源暂时不可用，也不能删除已有向量。".write(
      to: sourceURL, atomically: true, encoding: .utf8
    )
    let embeddingService = KnowledgeSemanticEmbeddingService(
      providers: [TemporarilyUnavailableEmbeddingProvider()]
    )
    let service = KnowledgeLibraryService(
      rootURL: storeURL,
      semanticEmbeddingService: embeddingService,
      searchCancellationCheck: { try Task.checkCancellation() }
    )
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite(
      """
      INSERT INTO knowledge_chunk_embeddings (
        chunk_id, revision_id, model_id, dimension, vector, input_hash, encoding_version, created_at
      ) SELECT id, revision_id, 'bundled-bge-test', 2, zeroblob(8), 'old', 'old', 0
      FROM knowledge_chunks LIMIT 1;
      """,
      at: databaseURL
    )

    _ = try await service.repairSemanticVectors()
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'bundled-bge-test';",
        at: databaseURL
      ), 1)
  }

  func testSemanticRepairDetectsMetadataOnlySearchableTextHashChange() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-metadata-hash")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("chapter.md")
    try "# 原始标题\n\n正文保持不变。".write(to: sourceURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let database = try service.database()
    let before = try XCTUnwrap(database.semanticIndexRecords().first)
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")

    // This intentionally leaves revision/chunk rows untouched.  The vector
    // input nevertheless changed because the title participates in searchableText.
    try executeSQLite(
      "UPDATE knowledge_documents SET title = '仅改元数据后的标题' WHERE id = '\(before.document.id.uuidString)';",
      at: databaseURL
    )
    let after = try XCTUnwrap(database.semanticIndexRecords().first)
    XCTAssertEqual(after.chunk.id, before.chunk.id)
    XCTAssertEqual(after.chunk.revisionID, before.chunk.revisionID)
    XCTAssertNotEqual(after.searchableTextHash, before.searchableTextHash)

    let needingRepair = try database.semanticIndexRecordsNeedingRepair(
      modelIdentifier: KnowledgeSemanticEmbeddingService.fallbackModelIdentifier,
      expectedDimension: 384,
      expectedEncodingVersion: "features-v2"
    )
    XCTAssertEqual(needingRepair.map(\.chunk.id), [after.chunk.id])
  }

  func testDenseProviderBackfillIsDeferredAndCanBeRescheduledAfterCancellation() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-background-backfill")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("chapter.md")
    try "# 后台回填\n\n首次搜索应使用已有 hash 向量，不应同步重建新稠密模型。".write(
      to: sourceURL, atomically: true, encoding: .utf8
    )
    do {
      let initialService = KnowledgeLibraryService(rootURL: storeURL)
      _ = try await initialService.commit(
        try await initialService.makeImportPreview(sourceURL: sourceURL))
    }
    let provider = ControlledDenseProvider()
    let service = KnowledgeLibraryService(
      rootURL: storeURL,
      semanticEmbeddingService: KnowledgeSemanticEmbeddingService(providers: [provider]),
      searchCancellationCheck: { try Task.checkCancellation() }
    )
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")

    _ = try service.search(query: "后台回填")
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'test-dense-background-v1';",
        at: databaseURL
      ), 0, "首次搜索不能同步写完整稠密索引")

    service.invalidateSemanticBackfillCache()
    provider.enablePassages()
    _ = try service.search(query: "后台回填")
    var denseCount = 0
    for _ in 0..<80 where denseCount == 0 {
      await Task.yield()
      denseCount = try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'test-dense-background-v1';",
        at: databaseURL
      )
    }
    XCTAssertGreaterThan(denseCount, 0, "取消后的新 generation 应可重新调度并继续回填")
  }
  func testRSSImportPreviewUsesCachedContentAndPreservesMetadata() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-rss-cached-import")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let article = RSSArticle(
      id: "rss-cached-1",
      feedID: UUID(),
      title: "缓存文章标题",
      link: URL(string: "https://example.com/cached-article"),
      author: "缓存作者",
      summaryHTML: "<p>不应覆盖正文的摘要标记 summary-fallback</p>",
      contentHTML: "<article><h1>缓存正文</h1><p>只应从本机读取 cached-body-unique。</p></article>",
      webPageSnapshotHTML: "<p>不应使用的旧快照 snapshot-fallback</p>",
      tags: ["RSS", "离线"]
    )

    let preview = try await service.makeRSSImportPreview(article: article)
    let importedCandidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertEqual(importedCandidate.kind, .article)
    XCTAssertEqual(importedCandidate.title, "缓存文章标题")
    XCTAssertEqual(importedCandidate.authors, ["缓存作者"])
    XCTAssertEqual(importedCandidate.tags, ["RSS", "离线"])
    XCTAssertEqual(importedCandidate.sourceURL, article.link)
    XCTAssertTrue(importedCandidate.normalizedText.contains("cached-body-unique"))
    XCTAssertFalse(importedCandidate.normalizedText.contains("summary-fallback"))
    XCTAssertFalse(importedCandidate.normalizedText.contains("snapshot-fallback"))

    _ = try await service.commit(preview)
    let repeatedPreview = try await service.makeRSSImportPreview(article: article)
    XCTAssertEqual(repeatedPreview.candidates.first?.disposition, .duplicate)
  }

  func testRSSImportPreviewFallsBackToCachedSnapshotWithoutLink() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-rss-snapshot-import")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let article = RSSArticle(
      id: "rss-cached-2",
      feedID: UUID(),
      title: "无链接缓存文章",
      webPageSnapshotHTML: "<p>本机历史快照 snapshot-only-unique</p>"
    )

    let preview = try await service.makeRSSImportPreview(article: article)
    let importedCandidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertNil(importedCandidate.sourceURL)
    XCTAssertTrue(importedCandidate.normalizedText.contains("snapshot-only-unique"))
  }

  func testSearchAsyncPropagatesCancellationIntoDetachedSearchWork() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-search-cancellation")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let probe = KnowledgeSearchCancellationProbe()
    let service = KnowledgeLibraryService(
      rootURL: rootURL.appendingPathComponent("store"),
      searchCancellationCheck: { try probe.checkpoint() }
    )
    let searchTask = Task {
      try await service.searchAsync(query: "可取消的资料检索")
    }

    let didStart = await Task.detached {
      probe.waitForStart(timeout: 1)
    }.value
    guard didStart else {
      searchTask.cancel()
      return XCTFail("搜索子任务未进入可取消工作")
    }

    let cancellationStartedAt = Date()
    searchTask.cancel()
    do {
      _ = try await searchTask.value
      XCTFail("取消外层搜索后应抛出 CancellationError")
    } catch is CancellationError {
      XCTAssertTrue(probe.didObserveCancellation)
      XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 1)
    } catch {
      XCTFail("应传播 CancellationError，实际为：\(error)")
    }
  }

  func testMultipleFilePreviewDeduplicatesDragItemsAndReportsUnsupportedFiles() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-multi-file-drop")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let firstURL = rootURL.appendingPathComponent("first.md")
    let secondURL = rootURL.appendingPathComponent("second.txt")
    let duplicateURL = rootURL.appendingPathComponent("duplicate.md")
    let unsupportedURL = rootURL.appendingPathComponent("image.bin")
    let firstContent = "# 第一条拖放资料\n\n拖放后应先生成安全预览。"
    try firstContent.write(to: firstURL, atomically: true, encoding: .utf8)
    try "second\n\n第二条拖放资料用于验证批量导入。".write(
      to: secondURL,
      atomically: true,
      encoding: .utf8
    )
    try firstContent.write(to: duplicateURL, atomically: true, encoding: .utf8)
    try Data([0x00, 0x01, 0x02]).write(to: unsupportedURL)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    let preview = try await service.makeImportPreview(
      sourceURLs: [firstURL, secondURL, duplicateURL, unsupportedURL, firstURL]
    )

    XCTAssertEqual(preview.candidates.count, 2)
    XCTAssertEqual(Set(preview.candidates.map(\.title)), ["第一条拖放资料", "second"])
    XCTAssertTrue(preview.warnings.contains { $0.contains("重复拖入") })
    XCTAssertTrue(preview.warnings.contains { $0.contains("暂不支持这种资料格式") })

    let folder = try service.createFolder(name: "拖放导入")
    let result = try await service.commit(preview, destination: .folder(folder.id))
    XCTAssertEqual(result.insertedCount, 2)
    XCTAssertTrue(try service.documents().allSatisfy { $0.folderID == folder.id })
  }

  func testBatchImportPreflightFailureLeavesNoPartialDocumentsOrContentFiles() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-batch-preflight-rollback")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let service = KnowledgeLibraryService(rootURL: storeURL)
    let validCandidate = makeKnowledgeImportCandidate(
      title: "第一条有效资料",
      text: "# 第一条\n\n整批导入失败时，这条资料也不能被留下。"
    )
    let invalidCandidate = makeKnowledgeImportCandidate(
      title: "第二条无分段资料",
      text: "这条资料故意不提供任何可建索分段。",
      sections: []
    )

    do {
      _ = try await service.commit(
        KnowledgeImportPreview(
          sourceName: "批量预检失败",
          candidates: [validCandidate, invalidCandidate]
        )
      )
      XCTFail("后续文件无法分块时，整批导入应失败")
    } catch let error as KnowledgeLibraryError {
      guard case .emptyContent = error else {
        return XCTFail("应报告空内容，实际为：\(error)")
      }
    }

    XCTAssertTrue(try service.documents().isEmpty)
    XCTAssertTrue(storedKnowledgeContentFiles(at: storeURL).isEmpty)
  }

  func testBatchImportDatabaseFailureRollsBackEveryDocumentAndContentFile() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-batch-database-rollback")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try service.documents()
    try executeSQLite(
      """
      CREATE TRIGGER reject_second_batch_document
      BEFORE INSERT ON knowledge_documents
      WHEN NEW.title = '第二条触发回滚'
      BEGIN
        SELECT RAISE(ABORT, 'forced batch rollback');
      END;
      """,
      at: storeURL.appendingPathComponent("library.sqlite")
    )
    let firstCandidate = makeKnowledgeImportCandidate(
      title: "第一条不应留下",
      text: "# 第一条\n\n数据库后续写入失败时，本文档和内容文件都应回滚。"
    )
    let secondCandidate = makeKnowledgeImportCandidate(
      title: "第二条触发回滚",
      text: "# 第二条\n\n这条资料的插入由 SQLite 触发器故意拒绝。"
    )

    do {
      _ = try await service.commit(
        KnowledgeImportPreview(
          sourceName: "批量数据库回滚",
          candidates: [firstCandidate, secondCandidate]
        )
      )
      XCTFail("任一文档写入失败时，整批导入应失败")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("forced batch rollback"))
    }

    XCTAssertTrue(try service.documents().isEmpty)
    XCTAssertTrue(storedKnowledgeContentFiles(at: storeURL).isEmpty)
  }

  func testCancelledBatchImportNeverStartsDetachedPersistenceWork() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-batch-cancellation")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let service = KnowledgeLibraryService(rootURL: storeURL)
    let candidate = makeKnowledgeImportCandidate(
      title: "取消的批量资料",
      text: "# 取消导入\n\n外层任务取消后，不应再启动脱离管理的持久化工作。"
    )
    let started = expectation(description: "批量导入任务已等待")
    let gate = KnowledgeImportCancellationGate()
    let task = Task {
      started.fulfill()
      await gate.wait()
      return try await service.commit(
        KnowledgeImportPreview(sourceName: "取消批量", candidates: [candidate])
      )
    }

    await fulfillment(of: [started], timeout: 1)
    task.cancel()
    await gate.release()
    do {
      _ = try await task.value
      XCTFail("已取消的批量导入应抛出 CancellationError")
    } catch is CancellationError {
      // Expected.
    }

    XCTAssertTrue(try service.documents().isEmpty)
    XCTAssertTrue(storedKnowledgeContentFiles(at: storeURL).isEmpty)
  }

  func testRelatedChaptersUseSemanticAndMetadataSignals() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-related-chapters")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let firstURL = rootURL.appendingPathComponent("first.md")
    let secondURL = rootURL.appendingPathComponent("second.md")
    try """
    ---
    title: 本地写作方法
    author: 陈作者
    tags: [本地优先, 写作]
    ---

    # 素材管理

    把长期阅读素材保存在本地资料库，写作时只召回必要章节。

    # 隐私边界

    本地检索可以减少不必要的全文上传。
    """.write(to: firstURL, atomically: true, encoding: .utf8)
    try """
    ---
    title: 长期知识整理
    author: 陈作者
    tags: [本地优先, 知识管理]
    ---

    # 相关章节

    私有阅读库通过混合检索找到意思接近的书籍段落。
    """.write(to: secondURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: firstURL))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: secondURL))
    let documents = try service.documents()
    let first = try XCTUnwrap(documents.first { $0.title == "本地写作方法" })

    let recommendations = try service.relatedChapters(documentID: first.id, limit: 6)

    XCTAssertFalse(recommendations.isEmpty)
    let relatedDocument = try XCTUnwrap(
      recommendations.first { $0.document.title == "长期知识整理" }
    )
    XCTAssertTrue(relatedDocument.reasons.contains(.author("陈作者")))
    XCTAssertTrue(relatedDocument.reasons.contains(.tag("本地优先")))
  }

  func testSearchExplainsTitleAndFullTextMatchesSeparately() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-search-reasons")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("article.md")
    try """
    ---
    title: 星云写作笔记
    ---

    # 方法

    正文只讨论长期素材管理和结构化写作。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))

    let titleMatches = try service.search(query: "星云", limit: 10)
    let bodyMatches = try service.search(query: "素材管理", limit: 10)
    let titleOnlyMatches = try service.search(
      query: "星云",
      limit: 10,
      requiredSignal: .title
    )
    let bodyExcludedFromTitle = try service.search(
      query: "素材管理",
      limit: 10,
      requiredSignal: .title
    )

    XCTAssertFalse(titleMatches.isEmpty)
    XCTAssertTrue(titleMatches.allSatisfy { $0.signals.contains(.title) })
    XCTAssertTrue(titleMatches.allSatisfy { !$0.signals.contains(.fullText) })
    XCTAssertFalse(bodyMatches.isEmpty)
    XCTAssertTrue(bodyMatches.allSatisfy { $0.signals.contains(.fullText) })
    XCTAssertTrue(bodyMatches.allSatisfy { !$0.signals.contains(.title) })
    XCTAssertFalse(titleOnlyMatches.isEmpty)
    XCTAssertTrue(titleOnlyMatches.allSatisfy { $0.signals.contains(.title) })
    XCTAssertTrue(bodyExcludedFromTitle.isEmpty)
  }

  func testMarkdownImportPersistsSearchableDocumentAndCitations() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-library")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try """
    ---
    title: 本地优先写作
    author: 测试作者
    tags: [知识库, 写作]
    ---

    # 为什么使用本地资料库

    本地优先的资料库可以长期保存阅读材料，并且只把命中的片段发送给 AI。

    ## 引用

    AI 回答必须保留资料标题和章节位置，方便回到原文核对。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    XCTAssertEqual(preview.newCount, 1)
    XCTAssertEqual(preview.candidates.first?.title, "本地优先写作")
    XCTAssertEqual(preview.candidates.first?.authors, ["测试作者"])

    let result = try await service.commit(preview)
    XCTAssertEqual(result.insertedCount, 1)
    XCTAssertEqual(result.updatedCount, 0)

    let documents = try service.documents()
    XCTAssertEqual(documents.count, 1)
    XCTAssertEqual(documents.first?.title, "本地优先写作")
    try service.setAllowsRemoteAIUse(true, documentID: try XCTUnwrap(documents.first?.id))

    let matches = try service.search(query: "命中的片段", limit: 10)
    XCTAssertFalse(matches.isEmpty)
    XCTAssertEqual(matches.first?.document.id, documents.first?.id)

    let context = try service.context(query: "AI 如何使用资料")
    XCTAssertFalse(context?.citations.isEmpty ?? true)
    XCTAssertEqual(context?.citations.first?.id, "K1")
    XCTAssertEqual(context?.citations.first?.title, "本地优先写作")
  }

  func testDeleteDocumentRemovesIndexAndOwnedFilesButKeepsExternalSource() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-delete")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.md")
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    try """
    # 可删除资料

    这段内容会进入全文与语义检索索引。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let database = try KnowledgeDatabase(
      fileURL: storeURL.appendingPathComponent("library.sqlite")
    )
    let revision = try XCTUnwrap(database.currentRevision(documentID: document.id))
    let storedFileURLs = [revision.originalStorageReference, revision.normalizedStorageReference]
      .compactMap { $0 }
      .map { storeURL.appendingPathComponent($0) }
    XCTAssertTrue(storedFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertFalse(try service.search(query: "语义检索", limit: 5).isEmpty)

    let report = try service.deleteDocument(id: document.id)

    XCTAssertEqual(report.removedStoredFileCount, storedFileURLs.count)
    XCTAssertEqual(report.failedStoredFileCount, 0)
    XCTAssertTrue(try service.documents().isEmpty)
    XCTAssertTrue(try service.search(query: "语义检索", limit: 5).isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    XCTAssertTrue(storedFileURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunks;",
        at: storeURL.appendingPathComponent("library.sqlite")
      ), 0)
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings;",
        at: storeURL.appendingPathComponent("library.sqlite")
      ), 0)
  }

  func testDeleteDocumentRetainsContentAddressedFilesStillUsedByAnotherRevision() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-delete-shared")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let firstURL = rootURL.appendingPathComponent("first.md")
    let secondURL = rootURL.appendingPathComponent("second.md")
    let sharedContent = "# 共享内容\n\n相同哈希的内部副本不应被误删。"
    try sharedContent.write(to: firstURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: firstURL))
    try "# 新版本\n\n第一条资料已更新。".write(
      to: firstURL,
      atomically: true,
      encoding: .utf8
    )
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: firstURL))
    try sharedContent.write(to: secondURL, atomically: true, encoding: .utf8)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: secondURL))

    let secondDocument = try XCTUnwrap(service.documents().first { $0.sourceURL == secondURL })
    let database = try KnowledgeDatabase(
      fileURL: storeURL.appendingPathComponent("library.sqlite")
    )
    let sharedRevision = try XCTUnwrap(database.currentRevision(documentID: secondDocument.id))
    let sharedFileURLs = [
      sharedRevision.originalStorageReference,
      sharedRevision.normalizedStorageReference,
    ]
    .compactMap { $0 }
    .map { storeURL.appendingPathComponent($0) }

    let report = try service.deleteDocument(id: secondDocument.id)

    XCTAssertEqual(report.removedStoredFileCount, 0)
    XCTAssertEqual(report.failedStoredFileCount, 0)
    XCTAssertTrue(sharedFileURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    XCTAssertEqual(try service.documents().count, 1)
  }

  func testDeleteDocumentNeverFollowsUnsafeStorageReferenceOutsideLibrary() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-delete-path")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    let outsideURL = rootURL.appendingPathComponent("outside.txt")
    try "# 路径安全\n\n删除只能发生在资料库内部。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    try "不可删除".write(to: outsideURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite(
      "UPDATE knowledge_revisions SET normalized_storage_ref = '../outside.txt';",
      at: databaseURL
    )

    let report = try service.deleteDocument(id: document.id)

    XCTAssertEqual(report.failedStoredFileCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: outsideURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    XCTAssertTrue(try service.documents().isEmpty)
  }

  func testReimportDetectsDuplicateThenCreatesRevisionForChangedSource() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-reimport")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("article.txt")
    try "第一版资料内容".write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let firstPreview = try await service.makeImportPreview(sourceURL: sourceURL)
    _ = try await service.commit(firstPreview)

    let duplicatePreview = try await service.makeImportPreview(sourceURL: sourceURL)
    XCTAssertEqual(duplicatePreview.duplicateCount, 1)

    try "第二版资料内容，增加了可检索的新段落。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let updatePreview = try await service.makeImportPreview(sourceURL: sourceURL)
    XCTAssertEqual(updatePreview.updateCount, 1)
    let result = try await service.commit(updatePreview)
    XCTAssertEqual(result.updatedCount, 1)
    XCTAssertEqual(try service.documents().count, 1)
    XCTAssertFalse(try service.search(query: "新段落").isEmpty)
  }

  func testDuplicateReimportRepairsDamagedContentAddressedFiles() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-duplicate-repair")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("article.md")
    let source = "# 完整资料\n\n这些字节应在重复导入时自动修复。"
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let database = try KnowledgeDatabase(fileURL: storeURL.appendingPathComponent("library.sqlite"))
    let revision = try XCTUnwrap(database.currentRevision(documentID: document.id))
    let references = [revision.originalStorageReference, revision.normalizedStorageReference]
      .compactMap { $0 }
    XCTAssertEqual(references.count, 2)
    for reference in references {
      try Data("damaged".utf8).write(
        to: storeURL.appendingPathComponent(reference), options: .atomic)
    }

    let duplicatePreview = try await service.makeImportPreview(sourceURL: sourceURL)
    let result = try await service.commit(duplicatePreview)

    XCTAssertEqual(result.skippedCount, 1)
    XCTAssertEqual(try service.normalizedText(documentID: document.id), source)
    let originalReference = try XCTUnwrap(revision.originalStorageReference)
    XCTAssertEqual(
      try Data(contentsOf: storeURL.appendingPathComponent(originalReference)), Data(source.utf8))
  }

  func testParserUpgradeReprocessesUnchangedHTMLInsteadOfTreatingItAsDuplicate() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-web-parser-upgrade")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("article.html")
    try """
    <html><body><main>
      <h1>解析器升级测试</h1>
      <p>正文需要由最新净化规则重新提取。</p>
    </main></body></html>
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite("UPDATE knowledge_revisions SET parser_version = 1;", at: databaseURL)

    let upgradedPreview = try await service.makeImportPreview(sourceURL: sourceURL)

    XCTAssertEqual(upgradedPreview.updateCount, 1)
    XCTAssertEqual(upgradedPreview.duplicateCount, 0)
    _ = try await service.commit(upgradedPreview)
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT parser_version FROM knowledge_revisions ORDER BY imported_at DESC LIMIT 1;",
        at: databaseURL
      ), KnowledgeLibraryService.parserVersion)
  }

  func testLocalContentRepairUsesStoredOriginalBlobAfterSourceDisappears() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-local-content-repair")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("saved-page.html")
    try """
    <html><body>
      <main><article>
        <h1>离线重新净化</h1>
        <p>原始网页归档保存在资料库内部，因此来源消失后仍可升级。</p>
        <p>查看新帖子</p>
        <p>12</p>
        <p>所有人可以回复</p>
        <p>36</p>
        <section class="comments">不应进入新版正文的评论区。</section>
      </article></main>
    </body></html>
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite("UPDATE knowledge_revisions SET parser_version = 2;", at: databaseURL)
    try FileManager.default.removeItem(at: sourceURL)

    let healthBefore = try await service.libraryHealth()
    let previews = try await service.makeLocalContentRepairPreviews()

    XCTAssertEqual(healthBefore.outdatedParserDocumentCount, 1)
    XCTAssertEqual(healthBefore.locallyRepairableDocumentCount, 1)
    XCTAssertEqual(previews.map(\.documentID), [document.id])
    XCTAssertEqual(previews.first?.importPreview.updateCount, 1)
    XCTAssertTrue(
      previews.first?.importPreview.candidates.first?.normalizedText.contains("来源消失后仍可升级") == true)
    XCTAssertFalse(
      previews.first?.importPreview.candidates.first?.normalizedText.contains("评论区") == true)
    XCTAssertFalse(
      previews.first?.importPreview.candidates.first?.normalizedText.contains("查看新帖子") == true)
    XCTAssertFalse(
      previews.first?.importPreview.candidates.first?.normalizedText.contains("所有人可以回复") == true)
    XCTAssertFalse(
      previews.first?.importPreview.candidates.first?.normalizedText
        .components(separatedBy: .newlines)
        .contains("12") == true
    )
    XCTAssertFalse(
      previews.first?.importPreview.candidates.first?.normalizedText
        .components(separatedBy: .newlines)
        .contains("36") == true
    )

    let result = try await service.applyLocalContentRepairs(previews)
    XCTAssertEqual(result.updatedCount, 1)
    XCTAssertEqual(try service.revisions(documentID: document.id).count, 2)
    XCTAssertEqual(
      try service.revisions(documentID: document.id).first?.parserVersion,
      KnowledgeLibraryService.parserVersion
    )
    let healthAfterRepair = try await service.libraryHealth()
    XCTAssertEqual(healthAfterRepair.outdatedParserDocumentCount, 0)
    XCTAssertFalse(try service.normalizedText(documentID: document.id).contains("查看新帖子"))
    XCTAssertFalse(try service.normalizedText(documentID: document.id).contains("所有人可以回复"))
    XCTAssertFalse(
      try service.search(query: "查看新帖子").contains {
        $0.signals.contains(.fullText)
      })
    let defaultPreviews = try await service.makeLocalContentRepairPreviews()
    let userRequestedPreviews = try await service.makeLocalContentRepairPreviews(
      documentIDs: [document.id],
      includingCurrentParserVersion: true
    )
    XCTAssertTrue(defaultPreviews.isEmpty)
    XCTAssertEqual(userRequestedPreviews.map(\.documentID), [document.id])
  }

  func testCleaningRuleUpgradeHealthOnlyFlagsOutdatedWebPages() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-cleaning-version-scope")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let markdownURL = rootURL.appendingPathComponent("notes.md")
    let webpageURL = rootURL.appendingPathComponent("article.html")
    try "# 普通笔记\n\n这份 Markdown 不需要网页清洗升级。".write(
      to: markdownURL,
      atomically: true,
      encoding: .utf8
    )
    try """
    <html><body><article>
      <h1>网页资料</h1>
      <p>这份资料需要跟随网页清洗规则升级。</p>
    </article></body></html>
    """.write(to: webpageURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: markdownURL))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: webpageURL))
    try executeSQLite(
      "UPDATE knowledge_revisions SET parser_version = 1;",
      at: storeURL.appendingPathComponent("library.sqlite")
    )

    let health = try await service.libraryHealth()

    XCTAssertEqual(health.documentCount, 2)
    XCTAssertEqual(health.outdatedParserDocumentCount, 1)
    XCTAssertEqual(health.locallyRepairableDocumentCount, 1)
  }

  func testHistoricalWebCandidatePreservesArchiveAndReadableFallback() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-historical-web-archive")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let originalHTML = Data(
      """
      <html><body><nav>旧归档导航</nav><article><h1>历史网页</h1>
      <p>需要保留并检索的网页正文。</p><p>浏览量 12.6万</p></article></body></html>
      """.utf8)
    let normalizedText = "# 历史网页\n\n需要保留并检索的网页正文。"
    let candidate = makeWebpageImportCandidate(
      title: "历史网页",
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/historical-archive")),
      originalData: originalHTML,
      normalizedText: normalizedText
    )
    let service = KnowledgeLibraryService(rootURL: storeURL)

    let result = try await service.commit(
      KnowledgeImportPreview(sourceName: "historical-archive.html", candidates: [candidate]))
    let documentID = try XCTUnwrap(result.documentIDs.first)
    let revision = try XCTUnwrap(service.revisions(documentID: documentID).first)
    let originalReference = try XCTUnwrap(revision.originalStorageReference)
    let originalFileURL = storeURL.appendingPathComponent(originalReference)
    XCTAssertEqual(try Data(contentsOf: originalFileURL), originalHTML)

    let readableOriginal = try XCTUnwrap(service.capturedText(documentID: documentID))
    XCTAssertTrue(readableOriginal.contains("旧归档导航"))
    XCTAssertTrue(readableOriginal.contains("浏览量 12.6万"))
    XCTAssertTrue(readableOriginal.contains("需要保留并检索的网页正文"))
    XCTAssertEqual(try service.normalizedText(documentID: documentID), normalizedText)

    let repairPreviews = try await service.makeLocalContentRepairPreviews(
      documentIDs: [documentID],
      includingCurrentParserVersion: true
    )
    let repairPreview = try XCTUnwrap(repairPreviews.first)
    let reSanitizedText = try XCTUnwrap(
      repairPreview.importPreview.candidates.first?.normalizedText
    )
    XCTAssertTrue(reSanitizedText.contains("需要保留并检索的网页正文"))
    XCTAssertFalse(reSanitizedText.contains("旧归档导航"))
    XCTAssertFalse(reSanitizedText.contains("12.6万"))
  }

  @MainActor
  func testRevealDocumentClearsFiltersAndSelectsCommittedHTMLDocument() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-reveal-committed-html")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("reference.html")
    try """
    <html><body><article><h1>可从导入结果打开的资料</h1>
    <p>这段正文用于验证资料导航会选中准确的已提交文档。</p>
    </article></body></html>
    """.write(to: sourceURL, atomically: true, encoding: .utf8)
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let destinationFolder = try service.createFolder(name: "长期参考")
    let hiddenFolder = try service.createFolder(name: "其他分类")
    let result = try await service.commit(
      try await service.makeImportPreview(sourceURL: sourceURL),
      destination: .folder(destinationFolder.id)
    )
    let documentID = try XCTUnwrap(result.documentIDs.first)
    let store = KnowledgeStore(service: service)
    await store.reload()
    store.setFolderScope(.folder(hiddenFolder.id))
    store.updateSearchText("不可能命中的搜索词")

    XCTAssertTrue(store.revealDocument(documentID))
    XCTAssertEqual(store.folderScope, .all)
    XCTAssertEqual(store.selectedDocumentID, documentID)
    XCTAssertEqual(store.selectedDocument?.title, "reference")
    XCTAssertTrue(store.searchText.isEmpty)
  }

  func testCandidateAISettingsAreCommittedWithinImportTransaction() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-import-ai-permission-transaction")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store")
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try service.documents()
    try executeSQLite(
      """
      CREATE TRIGGER reject_post_import_ai_permission_update
      BEFORE UPDATE OF allows_ai_use ON knowledge_documents
      BEGIN
        SELECT RAISE(ABORT, 'AI permission must be part of the import transaction');
      END;
      """,
      at: storeURL.appendingPathComponent("library.sqlite")
    )
    let originalHTML = Data(
      "<html><body><article>AI 权限事务导入</article></body></html>".utf8
    )
    let candidate = makeWebpageImportCandidate(
      title: "AI 权限事务导入",
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/transactional-ai-permission")),
      originalData: originalHTML,
      allowsRemoteAIUse: false,
      normalizedText: "AI 权限设置必须与文档在同一导入事务中提交。"
    )

    let result = try await service.commit(
      KnowledgeImportPreview(
        sourceName: "transactional-ai-permission.html",
        candidates: [candidate]
      )
    )
    let documentID = try XCTUnwrap(result.documentIDs.first)
    XCTAssertFalse(
      try XCTUnwrap(service.documents().first { $0.id == documentID }).allowsRemoteAIUse)
  }

  func testChunkerPreservesLocatorAndBoundsChunkSize() {
    let service = KnowledgeChunkingService(maximumChunkCharacters: 360, overlapCharacters: 40)
    let longText = Array(repeating: "这是一个用于验证资料分块边界的段落。", count: 80)
      .joined(separator: "")
    let chunks = service.chunks(
      documentID: UUID(),
      revisionID: UUID(),
      sections: [
        KnowledgeExtractedSection(
          headingPath: "第一章 › 资料库",
          locator: "第 12 页",
          text: longText
        )
      ]
    )

    XCTAssertGreaterThan(chunks.count, 1)
    XCTAssertTrue(chunks.allSatisfy { $0.locator == "第 12 页" })
    XCTAssertTrue(chunks.allSatisfy { $0.headingPath == "第一章 › 资料库" })
    XCTAssertTrue(chunks.allSatisfy { $0.content.count <= 360 })
    XCTAssertEqual(chunks.map(\.ordinal), Array(chunks.indices))
  }

  @MainActor
  func testScannedPDFUsesLocalVisionOCRWhenEnabled() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-pdf-ocr")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("scanned-book.pdf")

    let image = NSImage(size: NSSize(width: 1_600, height: 900))
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1_600, height: 900).fill()
    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.alignment = .center
    NSAttributedString(
      string: "SPACED REPETITION MEMORY",
      attributes: [
        .font: NSFont.systemFont(ofSize: 92, weight: .bold),
        .foregroundColor: NSColor.black,
        .paragraphStyle: paragraphStyle,
      ]
    ).draw(in: NSRect(x: 80, y: 360, width: 1_440, height: 180))
    image.unlockFocus()

    let document = PDFDocument()
    let page = try XCTUnwrap(PDFPage(image: image))
    document.insert(page, at: 0)
    do {
      _ = try KnowledgePDFOCRService().recognizeText(in: page)
    } catch let error as NSError {
      let isUnavailableInTestHost =
        (error.domain == NSOSStatusErrorDomain && error.code == -6_662)
        || (error.domain == "CRImageReaderErrorDomain" && error.code == -8)
      guard isUnavailableInTestHost else { throw error }
      throw XCTSkip("当前测试宿主无法初始化 Vision OCR：\(error.localizedDescription)")
    }
    try XCTUnwrap(document.dataRepresentation()).write(to: sourceURL, options: .atomic)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let preview = try await service.makeImportPreview(
      sourceURL: sourceURL,
      options: KnowledgeImportOptions(performsPDFOCR: true, maximumPDFOCRPageCount: 5)
    )

    let candidate = try XCTUnwrap(preview.candidates.first)
    let recognizedText = candidate.normalizedText.lowercased()
    XCTAssertTrue(recognizedText.contains("spaced"))
    XCTAssertTrue(recognizedText.contains("repetition"))
    XCTAssertEqual(candidate.sections.first?.locator, "第 1 页（OCR）")
    XCTAssertTrue(candidate.warnings.contains { $0.contains("Vision OCR") })
  }

  func testPDFOCROptionsClampPageLimit() {
    XCTAssertEqual(
      KnowledgeImportOptions(maximumPDFOCRPageCount: 0).maximumPDFOCRPageCount,
      1
    )
    XCTAssertEqual(
      KnowledgeImportOptions(maximumPDFOCRPageCount: 800).maximumPDFOCRPageCount,
      500
    )
  }

  func testNewEPUBImportIsRejectedAndFolderImportSkipsEPUBWhileImportingMarkdown() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-epub-retired-import")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let importFolderURL = rootURL.appendingPathComponent("mixed-import", isDirectory: true)
    try FileManager.default.createDirectory(at: importFolderURL, withIntermediateDirectories: true)
    let epubURL = importFolderURL.appendingPathComponent("new-book.epub")
    let markdownURL = importFolderURL.appendingPathComponent("notes.md")
    try Data([0x50, 0x4B, 0x03, 0x04]).write(to: epubURL)
    try "# 可导入的 Markdown\n\n混合文件夹仍应保留这条资料。".write(
      to: markdownURL,
      atomically: true,
      encoding: .utf8
    )

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    do {
      _ = try await service.makeImportPreview(sourceURL: epubURL)
      XCTFail("新 EPUB 文件不应再生成导入预览")
    } catch let error as KnowledgeLibraryError {
      guard case .unsupportedSource(let sourceName) = error else {
        return XCTFail("应拒绝 EPUB 格式，实际错误：\(error)")
      }
      XCTAssertEqual(sourceName, "new-book.epub")
    }

    let preview = try await service.makeImportPreview(sourceURL: importFolderURL)
    XCTAssertEqual(preview.candidates.count, 1)
    XCTAssertEqual(preview.candidates.first?.sourceName, "notes.md")
    XCTAssertEqual(preview.candidates.first?.kind, .markdown)
    XCTAssertFalse(preview.candidates.contains { $0.sourceName == "new-book.epub" })

    let result = try await service.commit(preview)
    XCTAssertEqual(result.insertedCount, 1)
    XCTAssertTrue(
      try service.normalizedText(documentID: try XCTUnwrap(result.documentIDs.first))
        .contains("混合文件夹仍应保留这条资料。"))
  }

  func testHistoricalEPUBBookRemainsReadableSearchableAndRestorable() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-historical-epub")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let backupURL = rootURL.appendingPathComponent(
      "historical-book.pslibrarybackup", isDirectory: true)
    let originalData = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00])
    let chapterText = "历史 EPUB 正文仍可用于检索和写作引用。"
    let normalizedText = "# 第二章：历史兼容\n\n[第 2 章 · 历史兼容]\n\n\(chapterText)"
    var documentID: UUID?

    do {
      let service = KnowledgeLibraryService(rootURL: storeURL)
      let candidate = KnowledgeImportCandidate(
        kind: .book,
        title: "历史 EPUB 书籍",
        authors: ["旧资料作者"],
        sourceName: "historical-book.epub",
        originalFilenameExtension: "epub",
        originalData: originalData,
        originalContentHash: KnowledgeChunkingService.contentHash(for: originalData),
        normalizedText: normalizedText,
        normalizedContentHash: KnowledgeChunkingService.contentHash(for: normalizedText),
        sections: [
          KnowledgeExtractedSection(
            headingPath: "第二章：历史兼容",
            locator: "第 2 章 · 历史兼容",
            text: chapterText
          )
        ]
      )
      let result = try await service.commit(
        KnowledgeImportPreview(sourceName: "historical-book.epub", candidates: [candidate])
      )
      let importedDocumentID = try XCTUnwrap(result.documentIDs.first)
      documentID = importedDocumentID
      XCTAssertEqual(try service.documents().first?.kind, .book)
      XCTAssertEqual(try service.normalizedText(documentID: importedDocumentID), normalizedText)
      XCTAssertEqual(
        try service.search(query: "检索和写作引用", limit: 5).first?.chunk.locator,
        "第 2 章 · 历史兼容"
      )
      try service.setAllowsRemoteAIUse(true, documentIDs: [importedDocumentID])
      XCTAssertEqual(
        try service.context(query: "检索和写作引用")?.citations.first?.locator,
        "第 2 章 · 历史兼容"
      )

      _ = try await service.createBackup(at: backupURL, applicationVersion: "test-historical-epub")
      _ = try await service.stageRestore(from: backupURL)
    }

    guard case .restored = KnowledgeLibraryService.applyPendingRestoreIfNeeded(rootURL: storeURL)
    else {
      return XCTFail("历史 EPUB 资料的备份应能恢复")
    }

    let restoredService = KnowledgeLibraryService(rootURL: storeURL)
    let restoredDocumentID = try XCTUnwrap(documentID)
    XCTAssertEqual(
      try restoredService.normalizedText(documentID: restoredDocumentID), normalizedText)
    XCTAssertEqual(
      try restoredService.search(query: "检索和写作引用", limit: 5).first?.chunk.locator,
      "第 2 章 · 历史兼容"
    )
    let revision = try XCTUnwrap(restoredService.revisions(documentID: restoredDocumentID).first)
    let originalReference = try XCTUnwrap(revision.originalStorageReference)
    XCTAssertTrue(originalReference.hasSuffix(".epub"))
    XCTAssertEqual(
      try Data(contentsOf: storeURL.appendingPathComponent(originalReference)), originalData)
  }

  func testFoldersPersistClassificationSizeAndSurviveReimport() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-folders")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("research.txt")
    let firstContent = "第一版研究资料，记录检索与引用。"
    try firstContent.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let initialPreview = try await service.makeImportPreview(sourceURL: sourceURL)
    _ = try await service.commit(initialPreview)
    let initialDocument = try XCTUnwrap(service.documents().first)
    XCTAssertEqual(initialDocument.sourceByteCount, Int64(Data(firstContent.utf8).count))
    XCTAssertNil(initialDocument.folderID)

    let folder = try service.createFolder(name: "研究")
    try service.setFolder(folder.id, documentID: initialDocument.id)
    XCTAssertEqual(try service.documents().first?.folderID, folder.id)

    let secondContent = "第二版研究资料，增加长期保存、语义检索与章节引用。"
    try secondContent.write(to: sourceURL, atomically: true, encoding: .utf8)
    let updatePreview = try await service.makeImportPreview(sourceURL: sourceURL)
    XCTAssertEqual(updatePreview.updateCount, 1)
    _ = try await service.commit(updatePreview)
    let updatedDocument = try XCTUnwrap(service.documents().first)
    XCTAssertEqual(updatedDocument.folderID, folder.id)
    XCTAssertEqual(updatedDocument.sourceByteCount, Int64(Data(secondContent.utf8).count))

    _ = try service.renameFolder(id: folder.id, name: "深度研究")
    XCTAssertEqual(try service.folders().first?.name, "深度研究")
    XCTAssertThrowsError(try service.createFolder(name: "深度研究")) { error in
      XCTAssertTrue(error.localizedDescription.contains("已经存在"))
    }

    try service.deleteFolder(id: folder.id)
    XCTAssertTrue(try service.folders().isEmpty)
    XCTAssertEqual(try service.documents().count, 1)
    XCTAssertNil(try service.documents().first?.folderID)
  }

  func testKnowledgeDocumentSortSupportsSizeKindAndAddedTime() {
    let early = Date(timeIntervalSince1970: 100)
    let late = Date(timeIntervalSince1970: 300)
    let documents = [
      KnowledgeDocument(kind: .text, title: "Beta", sourceByteCount: 500, importedAt: early),
      KnowledgeDocument(kind: .pdf, title: "Alpha", sourceByteCount: 100, importedAt: late),
      KnowledgeDocument(
        kind: .book, title: "Gamma", sourceByteCount: 300,
        importedAt: Date(timeIntervalSince1970: 200)),
    ]

    XCTAssertEqual(
      KnowledgeDocumentSort(field: .fileSize, direction: .ascending)
        .sorted(documents).map(\.sourceByteCount),
      [100, 300, 500]
    )
    XCTAssertEqual(
      KnowledgeDocumentSort(field: .addedAt, direction: .descending)
        .sorted(documents).map(\.title),
      ["Alpha", "Gamma", "Beta"]
    )
    XCTAssertEqual(
      KnowledgeDocumentSort(field: .title, direction: .ascending)
        .sorted(documents).map(\.title),
      ["Alpha", "Beta", "Gamma"]
    )
    let kindSorted = KnowledgeDocumentSort(field: .kind, direction: .ascending).sorted(documents)
    XCTAssertEqual(kindSorted.map(\.kind), [.book, .text, .pdf])
  }

  func testVersionOneDatabaseMigratesFoldersWithoutLosingDocuments() throws {
    let rootURL = temporaryDirectory(named: "knowledge-folder-migration")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    let documentID = UUID()
    let revisionID = UUID()
    try executeSQLite(
      """
      CREATE TABLE knowledge_documents (
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        title TEXT NOT NULL,
        authors_json TEXT NOT NULL,
        language TEXT,
        summary TEXT NOT NULL,
        tags_json TEXT NOT NULL,
        source_url TEXT,
        source_name TEXT NOT NULL,
        allows_ai_use INTEGER NOT NULL DEFAULT 1,
        is_archived INTEGER NOT NULL DEFAULT 0,
        imported_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        current_revision_id TEXT NOT NULL
      );
      INSERT INTO knowledge_documents VALUES (
        '\(documentID.uuidString)', 'text', '旧资料', '[]', NULL, '', '[]',
        NULL, 'legacy.txt', 1, 0, 100, 100, '\(revisionID.uuidString)'
      );
      PRAGMA user_version = 1;
      """,
      at: databaseURL
    )

    let service = KnowledgeLibraryService(rootURL: storeURL)
    let migrated = try service.documents()
    XCTAssertEqual(migrated.map(\.title), ["旧资料"])
    XCTAssertNil(migrated.first?.folderID)
    XCTAssertEqual(migrated.first?.sourceByteCount, 0)

    let folder = try service.createFolder(name: "迁移后分类")
    try service.setFolder(folder.id, documentID: documentID)
    XCTAssertEqual(try service.documents().first?.folderID, folder.id)
  }

  func testHybridSearchFindsChapterThroughDifferentChineseWording() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-hybrid-semantic")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceDirectory = rootURL.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    try """
    # 家庭预算方法

    本章介绍如何建立月度预算，通过削减不必要的日常开支控制家庭支出。
    """.write(
      to: sourceDirectory.appendingPathComponent("budget.md"),
      atomically: true,
      encoding: .utf8
    )
    try """
    # 改善睡眠

    保持固定作息并减少睡前光线，有助于更快入睡和恢复精力。
    """.write(
      to: sourceDirectory.appendingPathComponent("sleep.md"),
      atomically: true,
      encoding: .utf8
    )

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let result = try await service.commit(
      try await service.makeImportPreview(sourceURL: sourceDirectory))
    try service.setAllowsRemoteAIUse(true, documentIDs: Set(result.documentIDs))

    let results = try service.search(query: "有什么办法可以省钱", limit: 10)
    let first = try XCTUnwrap(results.first)
    XCTAssertEqual(first.document.title, "家庭预算方法")
    XCTAssertTrue(first.signals.contains(.semantic))
    XCTAssertFalse(first.signals.contains(.fullText))

    let context = try service.context(query: "怎样减少生活成本")
    XCTAssertEqual(context?.citations.first?.title, "家庭预算方法")
  }

  func testHybridSearchMergesFullTextAndSemanticSignals() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-hybrid-signals")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("research.md")
    try """
    # 语义召回研究

    全文检索负责精确词语命中，向量检索负责寻找含义相近的章节。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))

    let result = try XCTUnwrap(service.search(query: "全文检索", limit: 5).first)
    XCTAssertTrue(result.signals.contains(.fullText))
    XCTAssertTrue(result.signals.contains(.semantic))
  }

  func testSemanticSearchRespectsAIAndPinnedDocumentScopes() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-scope")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("budget.md")
    try """
    # 支出控制

    用预算削减非必要开销，并定期检查家庭支出。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let document = try XCTUnwrap(service.documents().first)

    XCTAssertTrue(document.allowsLocalSemanticIndex)
    XCTAssertFalse(document.allowsRemoteAIUse)
    try service.setAllowsRemoteAIUse(true, documentID: document.id)
    XCTAssertFalse(
      try service.search(
        query: "省钱方法",
        onlyRemoteAIAllowed: true,
        documentIDs: [document.id]
      ).isEmpty)
    try service.setAllowsRemoteAIUse(false, documentID: document.id)
    XCTAssertTrue(
      try service.search(
        query: "省钱方法",
        onlyRemoteAIAllowed: true,
        documentIDs: [document.id]
      ).isEmpty)
    XCTAssertTrue(
      try service.search(
        query: "省钱方法",
        documentIDs: [UUID()]
      ).isEmpty)
  }

  func testVersionTwoDatabaseLazilyBackfillsSemanticVectors() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-migration")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("chapter.md")
    try """
    # 个人财务

    通过预算减少日常开支，避免冲动消费带来的额外支出。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    do {
      let service = KnowledgeLibraryService(rootURL: storeURL)
      _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    }
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite(
      "DELETE FROM knowledge_chunk_embeddings; PRAGMA user_version = 2;",
      at: databaseURL
    )
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings;",
        at: databaseURL
      ), 0)

    let migratedService = KnowledgeLibraryService(rootURL: storeURL)
    let result = try XCTUnwrap(migratedService.search(query: "如何省钱", limit: 5).first)
    XCTAssertEqual(result.document.title, "个人财务")
    XCTAssertTrue(result.signals.contains(.semantic))
    XCTAssertGreaterThan(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings;",
        at: databaseURL
      ), 0)
    XCTAssertEqual(
      try querySQLiteInt("PRAGMA user_version;", at: databaseURL),
      KnowledgeDatabase.currentSchemaVersion
    )
  }

  func testSemanticSearchAutomaticallyRepairsStructurallyCorruptFallbackVector() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-auto-repair")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("budget.md")
    try """
    # 家庭预算

    建立每月预算可以减少冲动消费，并持续降低不必要的日常支出。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    do {
      let service = KnowledgeLibraryService(rootURL: storeURL)
      _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    }
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite(
      """
      UPDATE knowledge_chunk_embeddings
      SET dimension = 12, vector = zeroblob(48)
      WHERE model_id = 'local-semantic-hash-v2';
      """,
      at: databaseURL
    )
    XCTAssertGreaterThan(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'local-semantic-hash-v2' AND dimension = 12;",
        at: databaseURL
      ), 0)

    let repairedService = KnowledgeLibraryService(rootURL: storeURL)
    let result = try XCTUnwrap(repairedService.search(query: "怎样省钱", limit: 5).first)

    XCTAssertEqual(result.document.title, "家庭预算")
    XCTAssertTrue(result.signals.contains(.semantic))
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'local-semantic-hash-v2' AND dimension != 384;",
        at: databaseURL
      ), 0)
  }

  func testExplicitSemanticRepairRebuildsVectorsAfterInProcessCorruption() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-explicit-repair")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("memory.md")
    try """
    # 记忆方法

    间隔重复和主动回忆可以帮助长期记忆。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    _ = try service.search(query: "如何记住知识", limit: 5)

    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite(
      """
      UPDATE knowledge_chunk_embeddings
      SET vector = zeroblob(dimension * 4)
      WHERE model_id = 'local-semantic-hash-v2';
      """,
      at: databaseURL
    )
    XCTAssertGreaterThan(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'local-semantic-hash-v2' AND vector = zeroblob(dimension * 4);",
        at: databaseURL
      ), 0)

    let report = try await service.repairSemanticVectors()

    XCTAssertGreaterThan(report.scannedChunkCount, 0)
    XCTAssertGreaterThan(report.regeneratedVectorCount, 0)
    XCTAssertTrue(report.modelIdentifiers.contains("local-semantic-hash-v2"))
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'local-semantic-hash-v2' AND vector = zeroblob(dimension * 4);",
        at: databaseURL
      ), 0)
    XCTAssertTrue(
      try service.search(query: "如何记住知识", limit: 5).contains {
        $0.signals.contains(.semantic)
      })
  }

  func testFullSemanticRepairPrunesUnknownModelsAndHealthEnumeratesThem() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-prune-unknown-model")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("retrieval.md")
    try """
    # 检索维护

    全量修复应清理已经停用的语义模型，避免旧向量永久残留。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite(
      """
      INSERT INTO knowledge_chunk_embeddings (
        chunk_id, revision_id, model_id, dimension, vector, created_at
      )
      SELECT id, revision_id, 'retired-semantic-model', 2, zeroblob(8), 0
      FROM knowledge_chunks
      LIMIT 1;
      """,
      at: databaseURL
    )

    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'retired-semantic-model';",
        at: databaseURL
      ), 1)
    let healthBeforeRepair = try await service.libraryHealth()
    XCTAssertGreaterThan(healthBeforeRepair.semanticRepairChunkCount, 0)

    let report = try await service.repairSemanticVectors()

    XCTAssertGreaterThan(report.regeneratedVectorCount, 0)
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'retired-semantic-model';",
        at: databaseURL
      ), 0)
    let healthAfterRepair = try await service.libraryHealth()
    XCTAssertEqual(healthAfterRepair.semanticRepairChunkCount, 0)
  }

  func testFullSemanticRepairRollsBackDeleteWhenRebuildInsertFails() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-repair-rollback")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("transaction.md")
    try """
    # 事务修复

    新索引写入失败时，旧索引必须完整保留并继续可用。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite(
      """
      INSERT INTO knowledge_chunk_embeddings (
        chunk_id, revision_id, model_id, dimension, vector, created_at
      )
      SELECT id, revision_id, 'retired-semantic-model', 2, zeroblob(8), 0
      FROM knowledge_chunks
      LIMIT 1;
      CREATE TRIGGER force_semantic_rebuild_rollback
      BEFORE INSERT ON knowledge_chunk_embeddings
      WHEN NEW.model_id = 'local-semantic-hash-v2'
      BEGIN
        SELECT RAISE(ABORT, 'forced semantic rebuild rollback');
      END;
      """,
      at: databaseURL
    )
    let originalVectorCount = try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunk_embeddings;",
      at: databaseURL
    )

    do {
      _ = try await service.repairSemanticVectors()
      XCTFail("重建向量插入失败时应回滚整个替换事务")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("forced semantic rebuild rollback"))
    }

    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings;",
        at: databaseURL
      ), originalVectorCount)
    XCTAssertEqual(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'retired-semantic-model';",
        at: databaseURL
      ), 1)
    XCTAssertGreaterThan(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'local-semantic-hash-v2';",
        at: databaseURL
      ), 0)
  }

  func testDocumentSemanticRepairPrunesOnlySelectedDocuments() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-semantic-partial-prune")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let firstURL = rootURL.appendingPathComponent("first.md")
    let secondURL = rootURL.appendingPathComponent("second.md")
    try "# 第一份资料\n\n局部修复只替换选中的资料。".write(
      to: firstURL,
      atomically: true,
      encoding: .utf8
    )
    try "# 第二份资料\n\n未选中的资料索引必须保持不变。".write(
      to: secondURL,
      atomically: true,
      encoding: .utf8
    )

    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: firstURL))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: secondURL))
    let firstDocumentID = try XCTUnwrap(service.documents().first { $0.title == "第一份资料" }?.id)
    let databaseURL = storeURL.appendingPathComponent("library.sqlite")
    try executeSQLite(
      """
      INSERT INTO knowledge_chunk_embeddings (
        chunk_id, revision_id, model_id, dimension, vector, created_at
      )
      SELECT id, revision_id, 'retired-semantic-model', 2, zeroblob(8), 0
      FROM knowledge_chunks;
      """,
      at: databaseURL
    )

    _ = try await service.repairSemanticVectors(documentIDs: [firstDocumentID])

    XCTAssertEqual(
      try querySQLiteInt(
        """
        SELECT COUNT(*)
        FROM knowledge_chunk_embeddings e
        JOIN knowledge_chunks c ON c.id = e.chunk_id
        WHERE e.model_id = 'retired-semantic-model'
          AND c.document_id = '\(firstDocumentID.uuidString)';
        """,
        at: databaseURL
      ), 0)
    XCTAssertGreaterThan(
      try querySQLiteInt(
        "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'retired-semantic-model';",
        at: databaseURL
      ), 0)
  }

  func testKnowledgeBackupRoundTripRestoresFoldersPinsAndReferencedFiles() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-round-trip")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let backupURL = rootURL.appendingPathComponent("library.pslibrarybackup", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("chapter.md")
    try """
    # 长期写作资料

    这一章讨论如何把阅读材料保存为可检索的本地知识。
    """.write(to: sourceURL, atomically: true, encoding: .utf8)

    var restoredDocumentID: UUID?
    do {
      let service = KnowledgeLibraryService(rootURL: storeURL)
      let folder = try service.createFolder(name: "阅读笔记")
      _ = try await service.commit(
        try await service.makeImportPreview(sourceURL: sourceURL),
        destination: .folder(folder.id)
      )
      let document = try XCTUnwrap(service.documents().first)
      restoredDocumentID = document.id
      try service.setPinned(true, documentID: document.id)

      let orphanURL = storeURL.appendingPathComponent("blobs/orphan/unused.bin")
      try FileManager.default.createDirectory(
        at: orphanURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("unused".utf8).write(to: orphanURL)

      let preview = try await service.createBackup(
        at: backupURL,
        applicationVersion: "test-1.0"
      )
      XCTAssertEqual(preview.documentCount, 1)
      XCTAssertEqual(preview.folderCount, 1)
      XCTAssertEqual(preview.applicationVersion, "test-1.0")

      let manifest = try decodeKnowledgeBackupManifest(at: backupURL)
      XCTAssertTrue(manifest.files.contains { $0.relativePath == "library.sqlite" })
      XCTAssertFalse(manifest.files.contains { $0.relativePath.contains("orphan") })
      _ = try await service.stageRestore(from: backupURL)
    }

    try Data("current library marker".utf8).write(
      to: storeURL.appendingPathComponent("current-only.txt")
    )
    let outcome = KnowledgeLibraryService.applyPendingRestoreIfNeeded(rootURL: storeURL)
    guard case .restored(let result) = outcome else {
      return XCTFail("应从已暂存的资料库备份恢复，实际结果：\(outcome)")
    }

    XCTAssertEqual(result.restoredPreview.documentCount, 1)
    let recoveryURL = try XCTUnwrap(result.previousLibraryURL)
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: recoveryURL.appendingPathComponent("current-only.txt").path
      ))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: storeURL.appendingPathComponent("current-only.txt").path
      ))

    let restoredService = KnowledgeLibraryService(rootURL: storeURL)
    let document = try XCTUnwrap(restoredService.documents().first)
    XCTAssertEqual(document.id, restoredDocumentID)
    XCTAssertEqual(document.folderID, try restoredService.folders().first?.id)
    XCTAssertTrue(try restoredService.pinnedDocumentIDs().contains(document.id))
    XCTAssertTrue(try restoredService.normalizedText(documentID: document.id).contains("本地知识"))
  }

  func testKnowledgeBackupRoundTripRestoresHistoricalWebArchiveAndCapturedText() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-historical-web-backup")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let backupURL = rootURL.appendingPathComponent(
      "historical-web.pslibrarybackup", isDirectory: true)
    let capturedText = """
      # 历史网页正文

      这段文字必须和原始网页归档一起进入资料库备份。
      """
    let archive = Data("From: historical-source\nContent-Type: multipart/related".utf8)
    var restoredDocumentID: UUID?

    do {
      let service = KnowledgeLibraryService(rootURL: storeURL)
      let candidate = makeWebpageImportCandidate(
        title: "历史网页备份测试",
        sourceURL: try XCTUnwrap(URL(string: "https://example.com/backup-proof")),
        originalData: archive,
        originalFilenameExtension: "mhtml",
        capturedText: capturedText,
        normalizedText: capturedText
      )
      let result = try await service.commit(
        KnowledgeImportPreview(sourceName: "backup-proof.mhtml", candidates: [candidate])
      )
      restoredDocumentID = try XCTUnwrap(result.documentIDs.first)

      _ = try await service.createBackup(
        at: backupURL,
        applicationVersion: "test-historical-web"
      )
      let manifest = try decodeKnowledgeBackupManifest(at: backupURL)
      XCTAssertTrue(manifest.files.contains { $0.relativePath.hasPrefix("captured/") })
      XCTAssertTrue(manifest.files.contains { $0.relativePath.hasPrefix("blobs/") })
      XCTAssertTrue(manifest.files.contains { $0.relativePath.hasPrefix("normalized/") })
      _ = try await service.stageRestore(from: backupURL)
    }

    let outcome = KnowledgeLibraryService.applyPendingRestoreIfNeeded(rootURL: storeURL)
    guard case .restored = outcome else {
      return XCTFail("应恢复包含浏览器采集正文的资料库备份，实际结果：\(outcome)")
    }

    let restoredService = KnowledgeLibraryService(rootURL: storeURL)
    let documentID = try XCTUnwrap(restoredDocumentID)
    XCTAssertEqual(try restoredService.capturedText(documentID: documentID), capturedText)
    XCTAssertTrue(
      try restoredService.normalizedText(documentID: documentID).contains("必须和原始网页归档一起"))
    let revision = try XCTUnwrap(restoredService.revisions(documentID: documentID).first)
    let originalReference = try XCTUnwrap(revision.originalStorageReference)
    let originalFileURL = storeURL.appendingPathComponent(originalReference)
    XCTAssertEqual(try Data(contentsOf: originalFileURL), archive)
  }

  func testKnowledgeBackupRejectsTamperedFile() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-tampered")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# 校验测试\n\n备份必须发现内容被篡改。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let backupURL = rootURL.appendingPathComponent("tampered.pslibrarybackup", isDirectory: true)
    _ = try await service.createBackup(at: backupURL, applicationVersion: "test")

    let manifest = try decodeKnowledgeBackupManifest(at: backupURL)
    let contentRecord = try XCTUnwrap(manifest.files.first { $0.relativePath != "library.sqlite" })
    let contentURL = backupURL.appendingPathComponent(contentRecord.relativePath)
    var content = try Data(contentsOf: contentURL)
    content[content.startIndex] ^= 0xff
    try content.write(to: contentURL)

    do {
      _ = try await service.inspectBackup(at: backupURL)
      XCTFail("被篡改的备份不应通过校验")
    } catch let error as KnowledgeLibraryBackupError {
      guard case .checksumMismatch(let path) = error else {
        return XCTFail("应报告校验和错误，实际为：\(error)")
      }
      XCTAssertEqual(path, contentRecord.relativePath)
    }
  }

  func testKnowledgeBackupRejectsPathTraversalManifest() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-path")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# 路径测试\n\n备份不能越过包目录。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let backupURL = rootURL.appendingPathComponent("unsafe.pslibrarybackup", isDirectory: true)
    _ = try await service.createBackup(at: backupURL, applicationVersion: "test")

    var manifest = try decodeKnowledgeBackupManifest(at: backupURL)
    manifest.files.append(
      KnowledgeLibraryBackupFileRecord(
        relativePath: "../escape",
        byteCount: 0,
        sha256: String(repeating: "0", count: 64)
      ))
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(
      to: backupURL.appendingPathComponent("manifest.json"),
      options: .atomic
    )

    do {
      _ = try await service.inspectBackup(at: backupURL)
      XCTFail("包含目录穿越路径的备份不应通过校验")
    } catch let error as KnowledgeLibraryBackupError {
      guard case .invalidPath(let path) = error else {
        return XCTFail("应报告不安全路径，实际为：\(error)")
      }
      XCTAssertEqual(path, "../escape")
    }
  }

  func testKnowledgeBackupRejectsSymbolicLinkPackageRoot() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-root-symlink")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# 根目录链接测试\n\n不能通过符号链接读取整个备份包。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let backupURL = rootURL.appendingPathComponent("actual.pslibrarybackup", isDirectory: true)
    _ = try await service.createBackup(at: backupURL, applicationVersion: "test")
    let linkedBackupURL = rootURL.appendingPathComponent(
      "linked.pslibrarybackup", isDirectory: true)
    try FileManager.default.createSymbolicLink(
      at: linkedBackupURL,
      withDestinationURL: backupURL
    )

    do {
      _ = try await service.inspectBackup(at: linkedBackupURL)
      XCTFail("符号链接备份包不应通过校验")
    } catch let error as KnowledgeLibraryBackupError {
      XCTAssertEqual(error, .invalidPath("manifest.json"))
    }
  }

  func testKnowledgeBackupRejectsSymbolicLinkParentDirectory() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-parent-symlink")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# 父目录链接测试\n\n备份文件的父目录必须位于包内。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let backupURL = rootURL.appendingPathComponent("parent.pslibrarybackup", isDirectory: true)
    _ = try await service.createBackup(at: backupURL, applicationVersion: "test")

    let manifest = try decodeKnowledgeBackupManifest(at: backupURL)
    let nestedRecord = try XCTUnwrap(
      manifest.files.first {
        $0.relativePath.split(separator: "/").count >= 2
      })
    let storageDirectoryName = try XCTUnwrap(
      nestedRecord.relativePath.split(separator: "/").first.map(String.init)
    )
    let packagedDirectoryURL = backupURL.appendingPathComponent(
      storageDirectoryName,
      isDirectory: true
    )
    let externalDirectoryURL = rootURL.appendingPathComponent(
      "external-\(storageDirectoryName)",
      isDirectory: true
    )
    try FileManager.default.copyItem(at: packagedDirectoryURL, to: externalDirectoryURL)
    try FileManager.default.removeItem(at: packagedDirectoryURL)
    try FileManager.default.createSymbolicLink(
      at: packagedDirectoryURL,
      withDestinationURL: externalDirectoryURL
    )

    do {
      _ = try await service.inspectBackup(at: backupURL)
      XCTFail("父目录为符号链接的备份文件不应通过校验")
    } catch let error as KnowledgeLibraryBackupError {
      XCTAssertEqual(error, .invalidPath(nestedRecord.relativePath))
    }
  }

  func testKnowledgeBackupEnforcesManifestAndArchiveResourceLimits() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-limits")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# 资源上限测试\n\n备份读取必须在固定资源预算内完成。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let backupURL = rootURL.appendingPathComponent("limits.pslibrarybackup", isDirectory: true)
    _ = try await service.createBackup(at: backupURL, applicationVersion: "test")
    let manifest = try decodeKnowledgeBackupManifest(at: backupURL)
    XCTAssertGreaterThan(manifest.files.count, 1)
    XCTAssertGreaterThan(manifest.totalByteCount, 1)

    let manifestLimitedService = KnowledgeLibraryBackupService(
      rootURL: storeURL,
      limits: .init(maximumManifestByteCount: 1)
    )
    do {
      _ = try manifestLimitedService.inspectBackup(at: backupURL)
      XCTFail("超出上限的清单不应被完整载入")
    } catch let error as KnowledgeLibraryBackupError {
      XCTAssertEqual(error, .manifestTooLarge(maximumByteCount: 1))
    }

    let fileCountLimit = manifest.files.count - 1
    let fileCountLimitedService = KnowledgeLibraryBackupService(
      rootURL: storeURL,
      limits: .init(maximumFileCount: fileCountLimit)
    )
    do {
      _ = try fileCountLimitedService.inspectBackup(at: backupURL)
      XCTFail("文件数量超限的备份不应通过校验")
    } catch let error as KnowledgeLibraryBackupError {
      XCTAssertEqual(error, .tooManyFiles(maximumCount: fileCountLimit))
    }

    let singleFileLimitedService = KnowledgeLibraryBackupService(
      rootURL: storeURL,
      limits: .init(maximumSingleFileByteCount: 1)
    )
    do {
      _ = try singleFileLimitedService.inspectBackup(at: backupURL)
      XCTFail("单个文件超限的备份不应通过校验")
    } catch let error as KnowledgeLibraryBackupError {
      guard case .fileTooLarge(let path, let maximumByteCount) = error else {
        return XCTFail("应报告单文件大小超限，实际为：\(error)")
      }
      XCTAssertTrue(manifest.files.map(\.relativePath).contains(path))
      XCTAssertEqual(maximumByteCount, 1)
    }

    let totalByteLimit = manifest.totalByteCount - 1
    let totalLimitedService = KnowledgeLibraryBackupService(
      rootURL: storeURL,
      limits: .init(maximumTotalByteCount: totalByteLimit)
    )
    do {
      _ = try totalLimitedService.inspectBackup(at: backupURL)
      XCTFail("总容量超限的备份不应通过校验")
    } catch let error as KnowledgeLibraryBackupError {
      XCTAssertEqual(error, .backupTooLarge(maximumByteCount: totalByteLimit))
    }
  }

  func testKnowledgeBackupCancelsLargeStreamAndCleansTemporaryPackage() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-stream-cancel")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let blobURL = storeURL.appendingPathComponent("blobs/big.bin")
    try FileManager.default.createDirectory(
      at: blobURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(repeating: 0xB4, count: 4 * 1_024 * 1_024).write(to: blobURL)
    let destinationURL = rootURL.appendingPathComponent("existing.pslibrarybackup")
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let sentinelURL = destinationURL.appendingPathComponent("sentinel.txt")
    try Data("preserve".utf8).write(to: sentinelURL)

    let gate = KnowledgeBackupStreamGate()
    let inspection = KnowledgePersistenceInspection(
      userVersion: 1,
      documentCount: 0,
      folderCount: 0,
      revisionCount: 0,
      chunkCount: 0,
      storageReferences: ["blobs/big.bin"],
      sampleTitles: []
    )
    let service = KnowledgeLibraryBackupService(
      rootURL: storeURL,
      lifecycle: KnowledgeBackupFixtureLifecycle(inspection: inspection),
      streamChunkHook: { path, copiedByteCount in
        guard path == "blobs/big.bin", copiedByteCount > 0 else { return }
        gate.signalChunk()
        gate.waitUntilCancellationIsForwarded()
      }
    )
    let worker = Task.detached {
      try service.createBackup(
        at: destinationURL,
        database: KnowledgeBackupFixtureSnapshot(inspection: inspection),
        applicationVersion: "test"
      )
    }

    XCTAssertTrue(gate.waitForChunk(timeout: 2))
    let cancellationStartedAt = Date()
    worker.cancel()
    gate.allowCancellationToProceed()
    let result = await worker.result
    guard case .failure(let error) = result else {
      return XCTFail("cancelled knowledge backup unexpectedly succeeded")
    }
    XCTAssertTrue(error is CancellationError)
    XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 1)
    XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("preserve".utf8))
    let temporaryEntries = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
      .filter { $0.hasPrefix(".existing.pslibrarybackup.creating-") }
    XCTAssertEqual(temporaryEntries, [])
  }

  func testKnowledgeBackupCancelsDatabaseSnapshotAndCleansTemporaryPackage() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-database-cancel")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let destinationURL = rootURL.appendingPathComponent("existing.pslibrarybackup")
    try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
    let sentinelURL = destinationURL.appendingPathComponent("sentinel.txt")
    try Data("preserve".utf8).write(to: sentinelURL)

    let gate = KnowledgeDatabaseBackupStepGate()
    let database = try KnowledgeDatabase(
      fileURL: storeURL.appendingPathComponent("library.sqlite"),
      backupStepHook: { step in
        guard step == 1 else { return }
        gate.signalStep()
        gate.waitUntilCancellationIsForwarded()
      }
    )
    let backupService = KnowledgeLibraryBackupService(rootURL: storeURL)
    let worker = Task.detached {
      try backupService.createBackup(
        at: destinationURL,
        database: database,
        applicationVersion: "test"
      )
    }

    XCTAssertTrue(gate.waitForStep(timeout: 2))
    let cancellationStartedAt = Date()
    worker.cancel()
    gate.allowCancellationToProceed()
    let result = await worker.result
    guard case .failure(let error) = result else {
      return XCTFail("cancelled database snapshot unexpectedly succeeded")
    }
    XCTAssertTrue(error is CancellationError)
    XCTAssertLessThan(Date().timeIntervalSince(cancellationStartedAt), 1)
    XCTAssertEqual(try Data(contentsOf: sentinelURL), Data("preserve".utf8))
    let temporaryEntries = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
      .filter { $0.hasPrefix(".existing.pslibrarybackup.creating-") }
    XCTAssertEqual(temporaryEntries, [])
  }

  func testKnowledgeBackupCancellationAfterCommitReturnsPreview() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-commit-cancel")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
    let inspection = KnowledgePersistenceInspection(
      userVersion: 1,
      documentCount: 0,
      folderCount: 0,
      revisionCount: 0,
      chunkCount: 0,
      storageReferences: [],
      sampleTitles: []
    )
    let destinationURL = rootURL.appendingPathComponent("committed.pslibrarybackup")
    let gate = KnowledgeBackupCommitGate()
    let service = KnowledgeLibraryBackupService(
      rootURL: storeURL,
      lifecycle: KnowledgeBackupFixtureLifecycle(inspection: inspection),
      backupCommitHook: {
        gate.signalCommitted()
        gate.waitUntilTestReleasesCommit()
      }
    )
    let worker = Task.detached {
      try service.createBackup(
        at: destinationURL,
        database: KnowledgeBackupFixtureSnapshot(inspection: inspection),
        applicationVersion: "test"
      )
    }

    XCTAssertTrue(gate.waitForCommit(timeout: 2))
    worker.cancel()
    gate.releaseCommit()
    let result = await worker.result
    guard case .success(let preview) = result else {
      return XCTFail("committed knowledge backup must not be reclassified as cancellation")
    }
    XCTAssertEqual(preview.backupURL, destinationURL)
    XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))
  }

  func testKnowledgeBackupStageRestoreCopiesOnlyManifestFiles() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-backup-listed-files")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let sourceURL = rootURL.appendingPathComponent("source.md")
    try "# 清单复制测试\n\n恢复暂存区只能接收清单声明的文件。".write(
      to: sourceURL,
      atomically: true,
      encoding: .utf8
    )
    let service = KnowledgeLibraryService(rootURL: storeURL)
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceURL))
    let backupURL = rootURL.appendingPathComponent("listed.pslibrarybackup", isDirectory: true)
    _ = try await service.createBackup(at: backupURL, applicationVersion: "test")
    let unlistedURL = backupURL.appendingPathComponent("unlisted/private.txt")
    try FileManager.default.createDirectory(
      at: unlistedURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "不得进入恢复区".write(to: unlistedURL, atomically: true, encoding: .utf8)

    _ = try await service.stageRestore(from: backupURL)

    let pendingURL = KnowledgeLibraryBackupService.pendingRestoreURL(for: storeURL)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: pendingURL.appendingPathComponent("unlisted/private.txt").path
      ))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: pendingURL.appendingPathComponent("library.sqlite").path
      ))
  }

  private func decodeKnowledgeBackupManifest(
    at backupURL: URL
  ) throws -> KnowledgeLibraryBackupManifest {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(
      KnowledgeLibraryBackupManifest.self,
      from: Data(contentsOf: backupURL.appendingPathComponent("manifest.json"))
    )
  }

  private func executeSQLite(_ sql: String, at databaseURL: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      throw NSError(domain: "KnowledgeLibraryServiceTests.sqlite", code: 1)
    }
    defer { sqlite3_close(database) }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? "SQLite fixture failed"
      sqlite3_free(errorMessage)
      throw NSError(
        domain: "KnowledgeLibraryServiceTests.sqlite",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }

  private func makeKnowledgeImportCandidate(
    title: String,
    text: String,
    sections: [KnowledgeExtractedSection]? = nil
  ) -> KnowledgeImportCandidate {
    let contentHash = KnowledgeChunkingService.contentHash(for: text)
    return KnowledgeImportCandidate(
      kind: .markdown,
      title: title,
      sourceName: "\(title).md",
      originalFilenameExtension: "md",
      originalData: Data(text.utf8),
      originalContentHash: contentHash,
      normalizedText: text,
      normalizedContentHash: contentHash,
      sections: sections ?? [KnowledgeExtractedSection(headingPath: title, text: text)]
    )
  }

  private func makeWebpageImportCandidate(
    title: String,
    sourceURL: URL,
    originalData: Data,
    originalFilenameExtension: String = "html",
    capturedText: String? = nil,
    allowsRemoteAIUse: Bool? = nil,
    normalizedText: String
  ) -> KnowledgeImportCandidate {
    KnowledgeImportCandidate(
      kind: .webpage,
      title: title,
      sourceURL: sourceURL,
      sourceName: "\(title).\(originalFilenameExtension)",
      allowsRemoteAIUse: allowsRemoteAIUse,
      originalFilenameExtension: originalFilenameExtension,
      originalData: originalData,
      capturedText: capturedText,
      originalContentHash: KnowledgeChunkingService.contentHash(for: originalData),
      normalizedText: normalizedText,
      normalizedContentHash: KnowledgeChunkingService.contentHash(for: normalizedText),
      sections: [KnowledgeExtractedSection(headingPath: title, text: normalizedText)]
    )
  }

  private func storedKnowledgeContentFiles(at rootURL: URL) -> [URL] {
    ["blobs", "captured", "normalized"].flatMap { directoryName -> [URL] in
      let directoryURL = rootURL.appendingPathComponent(directoryName, isDirectory: true)
      guard
        let enumerator = FileManager.default.enumerator(
          at: directoryURL,
          includingPropertiesForKeys: [.isRegularFileKey]
        )
      else { return [] }
      return enumerator.compactMap { item in
        guard let url = item as? URL,
          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else {
          return nil
        }
        return url
      }
    }
  }

  private func querySQLiteInt(_ sql: String, at databaseURL: URL) throws -> Int {
    var database: OpaquePointer?
    guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
      throw NSError(domain: "KnowledgeLibraryServiceTests.sqlite", code: 3)
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
      let statement
    else {
      throw NSError(domain: "KnowledgeLibraryServiceTests.sqlite", code: 4)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw NSError(domain: "KnowledgeLibraryServiceTests.sqlite", code: 5)
    }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func temporaryDirectory(named name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}

private struct KnowledgeBackupFixtureSnapshot: KnowledgeBackupSnapshotSource {
  let inspection: KnowledgePersistenceInspection

  func createBackupSnapshot(at destinationURL: URL) throws -> KnowledgePersistenceInspection {
    try Data("fixture database".utf8).write(to: destinationURL)
    return inspection
  }
}

private struct KnowledgeBackupFixtureLifecycle: KnowledgePersistenceLifecycle {
  let inspection: KnowledgePersistenceInspection

  var supportedSchemaVersion: Int { inspection.userVersion }

  func createOrOpenAndValidate(at fileURL: URL) throws -> KnowledgePersistenceInspection {
    inspection
  }

  func inspectBackup(at fileURL: URL) throws -> KnowledgePersistenceInspection {
    inspection
  }
}

private final class KnowledgeBackupStreamGate: Sendable {
  private let chunk = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  func signalChunk() { chunk.signal() }
  func waitForChunk(timeout: TimeInterval) -> Bool {
    chunk.wait(timeout: .now() + timeout) == .success
  }
  func waitUntilCancellationIsForwarded() { release.wait() }
  func allowCancellationToProceed() { release.signal() }
}

private final class KnowledgeBackupCommitGate: Sendable {
  private let committed = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  func signalCommitted() { committed.signal() }
  func waitForCommit(timeout: TimeInterval) -> Bool {
    committed.wait(timeout: .now() + timeout) == .success
  }
  func waitUntilTestReleasesCommit() { release.wait() }
  func releaseCommit() { release.signal() }
}

private final class KnowledgeDatabaseBackupStepGate: Sendable {
  private let step = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)

  func signalStep() { step.signal() }
  func waitForStep(timeout: TimeInterval) -> Bool {
    step.wait(timeout: .now() + timeout) == .success
  }
  func waitUntilCancellationIsForwarded() { release.wait() }
  func allowCancellationToProceed() { release.signal() }
}

private final class KnowledgeSearchCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let started = DispatchSemaphore(value: 0)
  private var didSignalStart = false
  private var observedCancellation = false

  var didObserveCancellation: Bool {
    lock.lock()
    defer { lock.unlock() }
    return observedCancellation
  }

  func waitForStart(timeout: TimeInterval) -> Bool {
    started.wait(timeout: .now() + timeout) == .success
  }

  func checkpoint() throws {
    lock.lock()
    let shouldSignalStart = !didSignalStart
    didSignalStart = true
    lock.unlock()
    if shouldSignalStart {
      started.signal()
    }

    let deadline = Date().addingTimeInterval(2)
    while !Task.isCancelled, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    guard Task.isCancelled else {
      throw NSError(
        domain: "KnowledgeSearchCancellationProbe",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Detached search did not receive cancellation"]
      )
    }

    lock.lock()
    observedCancellation = true
    lock.unlock()
    throw CancellationError()
  }
}

private actor KnowledgeImportCancellationGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isReleased = false

  func wait() async {
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      self.continuation = continuation
    }
  }

  func release() {
    isReleased = true
    continuation?.resume()
    continuation = nil
  }
}
