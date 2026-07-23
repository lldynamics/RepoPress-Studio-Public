import AppKit
import Foundation
import PDFKit
import SQLite3
import XCTest
@testable import PublishingWorkbenchCore

final class KnowledgeLibraryServiceTests: XCTestCase {
  func testSemanticVectorsDoNotSynchronouslyLoadUnpreparedContextualModel() {
    let vectors = KnowledgeSemanticEmbeddingService().vectors(
      for: "本地资料库通过混合检索找到相关章节"
    )

    XCTAssertTrue(vectors.contains { $0.modelIdentifier == "local-semantic-hash-v2" })
    XCTAssertFalse(vectors.contains { $0.modelIdentifier.hasPrefix("apple-contextual-") })
    XCTAssertFalse(vectors.contains { $0.modelIdentifier.hasPrefix("apple-sentence-zh") })
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
    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunks;",
      at: storeURL.appendingPathComponent("library.sqlite")
    ), 0)
    XCTAssertEqual(try querySQLiteInt(
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
    let references = [revision.originalStorageReference, revision.normalizedStorageReference].compactMap { $0 }
    XCTAssertEqual(references.count, 2)
    for reference in references {
      try Data("damaged".utf8).write(to: storeURL.appendingPathComponent(reference), options: .atomic)
    }

    let duplicatePreview = try await service.makeImportPreview(sourceURL: sourceURL)
    let result = try await service.commit(duplicatePreview)

    XCTAssertEqual(result.skippedCount, 1)
    XCTAssertEqual(try service.normalizedText(documentID: document.id), source)
    let originalReference = try XCTUnwrap(revision.originalStorageReference)
    XCTAssertEqual(try Data(contentsOf: storeURL.appendingPathComponent(originalReference)), Data(source.utf8))
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
    XCTAssertEqual(try querySQLiteInt(
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
    XCTAssertTrue(previews.first?.importPreview.candidates.first?.normalizedText.contains("来源消失后仍可升级") == true)
    XCTAssertFalse(previews.first?.importPreview.candidates.first?.normalizedText.contains("评论区") == true)
    XCTAssertFalse(previews.first?.importPreview.candidates.first?.normalizedText.contains("查看新帖子") == true)
    XCTAssertFalse(previews.first?.importPreview.candidates.first?.normalizedText.contains("所有人可以回复") == true)
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
    XCTAssertFalse(try service.search(query: "查看新帖子").contains {
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

  func testBrowserCaptureImportsArchiveIntoFolderAndCanReclassifyDuplicate() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-browser-capture")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let readingFolder = try service.createFolder(name: "待读文章")
    let referenceFolder = try service.createFolder(name: "长期参考")
    let archive = Data("From: browser-extension\nContent-Type: multipart/related".utf8)
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/notes?from=reader#chapter")),
      title: "用资料库辅助长期写作",
      authors: ["测试作者"],
      language: "zh-CN",
      summary: "浏览器采集测试",
      tags: ["写作", "资料库"],
      capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
      contentText: """
      不同措辞也应该能够找到这一段关于长期知识积累的正文。

      [继续阅读](https://example.com/notes/chapter)
      """,
      archiveFormat: "mhtml",
      archiveData: archive
    )

    let preview = try await service.makeBrowserImportPreview(capture: capture)
    let candidate = try XCTUnwrap(preview.candidates.first)
    XCTAssertEqual(candidate.disposition, .new)
    XCTAssertEqual(candidate.kind, .webpage)
    XCTAssertEqual(candidate.originalFilenameExtension, "mhtml")
    XCTAssertEqual(candidate.originalData, archive)
    XCTAssertEqual(candidate.capturedText, capture.contentText)
    XCTAssertEqual(candidate.sourceURL?.fragment, nil)

    let inserted = try await service.commit(preview, destination: .folder(readingFolder.id))
    XCTAssertEqual(inserted.insertedCount, 1)
    var document = try XCTUnwrap(service.documents().first)
    XCTAssertEqual(inserted.documentIDs, [document.id])
    XCTAssertEqual(document.folderID, readingFolder.id)
    XCTAssertEqual(document.title, "用资料库辅助长期写作")
    XCTAssertFalse(try service.search(query: "长期知识积累", limit: 5).isEmpty)
    XCTAssertTrue(
      try service.normalizedText(documentID: document.id)
        .contains("[继续阅读](https://example.com/notes/chapter)")
    )
    XCTAssertEqual(try service.capturedText(documentID: document.id), capture.contentText)
    let firstRevision = try XCTUnwrap(service.revisions(documentID: document.id).first)
    XCTAssertNotNil(firstRevision.capturedTextStorageReference)

    let duplicatePreview = try await service.makeBrowserImportPreview(capture: capture)
    XCTAssertEqual(duplicatePreview.duplicateCount, 1)
    let duplicate = try await service.commit(
      duplicatePreview,
      destination: .folder(referenceFolder.id)
    )
    XCTAssertEqual(duplicate.skippedCount, 1)
    document = try XCTUnwrap(service.documents().first)
    XCTAssertEqual(duplicate.documentIDs, [document.id])
    XCTAssertEqual(document.folderID, referenceFolder.id)
    XCTAssertEqual(try service.capturedText(documentID: document.id), capture.contentText)

    var changedCapture = capture
    changedCapture.contentText += " 新版本补充了浏览器一键归档流程。"
    changedCapture.archiveData = Data("updated archive".utf8)
    let updatePreview = try await service.makeBrowserImportPreview(capture: changedCapture)
    XCTAssertEqual(updatePreview.updateCount, 1)
    let updated = try await service.commit(updatePreview, destination: .preserveExisting)
    XCTAssertEqual(updated.updatedCount, 1)
    document = try XCTUnwrap(service.documents().first)
    XCTAssertEqual(updated.documentIDs, [document.id])
    XCTAssertEqual(document.folderID, referenceFolder.id)
    XCTAssertFalse(try service.search(query: "一键归档", limit: 5).isEmpty)
    XCTAssertEqual(try service.capturedText(documentID: document.id), changedCapture.contentText)
  }

  func testBrowserCaptureRejectsUnsupportedSchemaAndCredentialedURL() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-browser-invalid")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))

    var capture = KnowledgeBrowserCapture(
      schemaVersion: 99,
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/article")),
      title: "无效页面",
      contentText: "仍然包含正文"
    )
    do {
      _ = try await service.makeBrowserImportPreview(capture: capture)
      XCTFail("Expected unsupported browser capture schema to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("不支持的数据版本"))
    }

    capture.schemaVersion = KnowledgeBrowserCapture.currentSchemaVersion
    capture.sourceURL = try XCTUnwrap(URL(string: "https://user:secret@example.com/article"))
    do {
      _ = try await service.makeBrowserImportPreview(capture: capture)
      XCTFail("Expected credentialed browser URL to fail")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("页面地址无效"))
    }
  }

  @MainActor
  func testBrowserPreparedCapturePersistsEditedMetadataModeAndAIPermission() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-browser-prepared-preview")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let store = KnowledgeStore(service: service)
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/reference-link")),
      title: "保存前编辑后的标题",
      authors: ["作者甲", "作者乙"],
      tags: ["研究", "写作"],
      contentText: "[保存前预览资料](https://example.com/reference-link)",
      captureMode: .linkOnly,
      allowsAIUse: false
    )

    let preview = try await service.makeBrowserImportPreview(capture: capture)
    let candidate = try XCTUnwrap(preview.candidates.first)
    XCTAssertEqual(candidate.allowsAIUse, false)
    XCTAssertTrue(candidate.warnings.contains {
      $0.contains("仅保存页面标题和原始链接")
    })

    let outcome = try await store.importBrowserCapture(
      capture,
      folderID: nil,
      newFolderName: nil
    )
    guard case .saved(let result, let action) = outcome else {
      return XCTFail("Expected prepared capture to be saved")
    }
    XCTAssertEqual(action, .inserted)
    let document = try XCTUnwrap(store.documents.first(where: {
      $0.id == result.documentIDs.first
    }))
    XCTAssertEqual(document.title, "保存前编辑后的标题")
    XCTAssertEqual(document.authors, ["作者甲", "作者乙"])
    XCTAssertEqual(document.tags, ["研究", "写作"])
    XCTAssertFalse(document.allowsAIUse)
    XCTAssertTrue(try service.normalizedText(documentID: document.id).contains("reference-link"))
  }

  @MainActor
  func testBrowserAIPermissionIsCommittedWithoutPostImportUpdate() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-browser-ai-permission-transaction")
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
    let store = KnowledgeStore(service: service)
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/transactional-ai-permission")),
      title: "AI 权限事务导入",
      contentText: "这段正文用于验证不允许 AI 的选择与文档在同一事务中提交。",
      allowsAIUse: false
    )

    let outcome = try await store.importBrowserCapture(
      capture,
      folderID: nil,
      newFolderName: nil
    )
    guard case .saved(let result, let action) = outcome else {
      return XCTFail("Expected browser capture to be saved")
    }
    XCTAssertEqual(action, .inserted)
    let documentID = try XCTUnwrap(result.documentIDs.first)
    XCTAssertFalse(try XCTUnwrap(service.documents().first { $0.id == documentID }).allowsAIUse)
  }

  @MainActor
  func testRevealDocumentClearsFiltersAndSelectsExactBrowserReceiptDocument() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-browser-receipt-open")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let destinationFolder = try service.createFolder(name: "长期参考")
    let hiddenFolder = try service.createFolder(name: "其他分类")
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/receipt-open")),
      title: "可从保存回执打开的资料",
      contentText: "这段正文用于验证浏览器保存回执能打开准确资料。"
    )
    let preview = try await service.makeBrowserImportPreview(capture: capture)
    let result = try await service.commit(preview, destination: .folder(destinationFolder.id))
    let documentID = try XCTUnwrap(result.documentIDs.first)
    let store = KnowledgeStore(service: service)
    await store.reload()
    store.setFolderScope(.folder(hiddenFolder.id))
    store.updateSearchText("不可能命中的搜索词")

    XCTAssertTrue(store.revealDocument(documentID))
    XCTAssertEqual(store.folderScope, .all)
    XCTAssertEqual(store.selectedDocumentID, documentID)
    XCTAssertEqual(store.selectedDocument?.title, "可从保存回执打开的资料")
    XCTAssertTrue(store.searchText.isEmpty)
  }

  @MainActor
  func testBrowserDuplicateResolutionSupportsVersionMoveCopyAndCancelWithoutSilentMutation() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-browser-duplicate-resolution")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let readingFolder = try service.createFolder(name: "阅读")
    let referenceFolder = try service.createFolder(name: "参考")
    let store = KnowledgeStore(service: service)
    await store.reload()
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/duplicate-panel")),
      title: "重复网页处理",
      authors: ["原作者"],
      tags: ["原标签"],
      contentText: "这是用于验证重复网页处理选项的长期参考正文。",
      allowsAIUse: true
    )

    let firstOutcome = try await store.importBrowserCapture(
      capture,
      folderID: readingFolder.id,
      newFolderName: nil
    )
    guard case .saved(let firstResult, let firstAction) = firstOutcome else {
      return XCTFail("首次导入应直接保存")
    }
    XCTAssertEqual(firstAction, .inserted)
    let originalDocumentID = try XCTUnwrap(firstResult.documentIDs.first)
    XCTAssertEqual(try service.revisions(documentID: originalDocumentID).count, 1)

    let unresolved = try await store.importBrowserCapture(
      capture,
      folderID: referenceFolder.id,
      newFolderName: nil
    )
    guard case .requiresDuplicateResolution(let conflict) = unresolved else {
      return XCTFail("同网址应先等待用户选择")
    }
    XCTAssertEqual(conflict.document.id, originalDocumentID)
    XCTAssertEqual(conflict.folder?.id, readingFolder.id)
    XCTAssertFalse(conflict.incomingHasChanges)
    XCTAssertEqual(try service.documents().count, 1)
    XCTAssertEqual(try service.documents().first?.folderID, readingFolder.id)
    XCTAssertEqual(try service.revisions(documentID: originalDocumentID).count, 1)

    var moveOnlyCapture = capture
    moveOnlyCapture.title = "不应写入的标题"
    moveOnlyCapture.authors = ["不应写入的作者"]
    moveOnlyCapture.tags = ["不应写入的标签"]
    moveOnlyCapture.contentText += " 这段新内容不应被仅移动分类写入。"
    moveOnlyCapture.allowsAIUse = false
    let moved = try await store.importBrowserCapture(
      moveOnlyCapture,
      folderID: referenceFolder.id,
      newFolderName: nil,
      duplicateResolution: .moveOnly
    )
    guard case .saved(let movedResult, let movedAction) = moved else {
      return XCTFail("仅移动分类应返回保存回执")
    }
    XCTAssertEqual(movedAction, .moved)
    XCTAssertEqual(movedResult.documentIDs, [originalDocumentID])
    let movedDocument = try XCTUnwrap(service.documents().first)
    XCTAssertEqual(movedDocument.folderID, referenceFolder.id)
    XCTAssertEqual(movedDocument.title, capture.title)
    XCTAssertEqual(movedDocument.authors, capture.authors)
    XCTAssertEqual(movedDocument.tags, capture.tags)
    XCTAssertTrue(movedDocument.allowsAIUse)
    XCTAssertFalse(
      try service.normalizedText(documentID: originalDocumentID)
        .contains("这段新内容不应被仅移动分类写入")
    )
    XCTAssertEqual(try service.revisions(documentID: originalDocumentID).count, 1)

    let versioned = try await store.importBrowserCapture(
      capture,
      folderID: referenceFolder.id,
      newFolderName: nil,
      duplicateResolution: .saveNewVersion
    )
    guard case .saved(let versionedResult, let versionedAction) = versioned else {
      return XCTFail("保存新版本应返回保存回执")
    }
    XCTAssertEqual(versionedAction, .updated)
    XCTAssertEqual(versionedResult.documentIDs, [originalDocumentID])
    XCTAssertEqual(try service.revisions(documentID: originalDocumentID).count, 2)

    var changedCapture = capture
    changedCapture.contentText += " 本次采集增加了一段新内容。"
    let changedConflict = try await store.importBrowserCapture(
      changedCapture,
      folderID: referenceFolder.id,
      newFolderName: nil
    )
    guard case .requiresDuplicateResolution(let conflict) = changedConflict else {
      return XCTFail("同网址新内容也应先询问")
    }
    XCTAssertTrue(conflict.incomingHasChanges)

    let copied = try await store.importBrowserCapture(
      changedCapture,
      folderID: readingFolder.id,
      newFolderName: nil,
      duplicateResolution: .keepCopy
    )
    guard case .saved(let copiedResult, let copiedAction) = copied else {
      return XCTFail("保留副本应返回保存回执")
    }
    XCTAssertEqual(copiedAction, .copied)
    let copiedDocumentID = try XCTUnwrap(copiedResult.documentIDs.first)
    XCTAssertNotEqual(copiedDocumentID, originalDocumentID)
    let documents = try service.documents()
    XCTAssertEqual(documents.count, 2)
    XCTAssertEqual(Set(documents.compactMap(\.sourceURL)), [capture.sourceURL])
    XCTAssertTrue(documents.contains { $0.id == copiedDocumentID && $0.title.hasSuffix("（副本）") })
  }

  func testBrowserCapturePreservesSelfContainedHTMLAndResourceWarnings() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-browser-self-contained-html")
    defer { try? FileManager.default.removeItem(at: rootURL) }

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let archive = Data("""
    <!doctype html><html><head><style>body{color:#222}</style></head>
    <body><article><h1>离线资料</h1><img src="data:image/png;base64,AA=="></article></body></html>
    """.utf8)
    let capture = KnowledgeBrowserCapture(
      sourceURL: try XCTUnwrap(URL(string: "https://example.com/offline")),
      title: "Firefox 自包含归档",
      contentText: "# 离线资料\n\n正文可以检索。",
      archiveFormat: "html",
      archiveData: archive,
      archiveEmbeddedResourceCount: 3,
      archiveMissingResourceCount: 2,
      archiveWasTruncated: true
    )

    let preview = try await service.makeBrowserImportPreview(capture: capture)
    let candidate = try XCTUnwrap(preview.candidates.first)
    XCTAssertEqual(candidate.originalFilenameExtension, "html")
    XCTAssertEqual(candidate.originalData, archive)
    XCTAssertTrue(candidate.warnings.contains { $0.contains("已内联 3 个") })
    XCTAssertTrue(candidate.warnings.contains { $0.contains("有 2 个外部资源") })
    XCTAssertTrue(candidate.warnings.contains { $0.contains("24 MB 上限") })
  }

  func testChunkerPreservesLocatorAndBoundsChunkSize() {
    let service = KnowledgeChunkingService(maximumChunkCharacters: 360, overlapCharacters: 40)
    let longText = Array(repeating: "这是一个用于验证资料分块边界的段落。", count: 80)
      .joined(separator: "")
    let chunks = service.chunks(
      documentID: UUID(),
      revisionID: UUID(),
      sections: [KnowledgeExtractedSection(
        headingPath: "第一章 › 资料库",
        locator: "第 12 页",
        text: longText
      )]
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

  func testEPUBImportPreservesMetadataSpineOrderAndCitations() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-epub")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = try makeEPUB(
      in: rootURL,
      packageXML: """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="book-id" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>Thinking with Sources</dc:title>
          <dc:creator>Ada Reader</dc:creator>
          <dc:language>en</dc:language>
          <dc:description>A practical book about durable research notes.</dc:description>
          <dc:subject>research</dc:subject>
          <dc:subject>writing</dc:subject>
        </metadata>
        <manifest>
          <item id="chapter-one" href="Text/chapter%20one.xhtml" media-type="application/xhtml+xml"/>
          <item id="chapter-two" href="Text/chapter-two.xhtml" media-type="application/xhtml+xml"/>
          <item id="appendix" href="Text/appendix.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine>
          <itemref idref="chapter-two"/>
          <itemref idref="chapter-one"/>
          <itemref idref="appendix" linear="no"/>
        </spine>
      </package>
      """,
      chapters: [
        "OEBPS/Text/chapter one.xhtml": """
        <!doctype html><html><head><title>First Notes</title></head><body>
        <h1>First Notes</h1><p>Atomic notes preserve the origin of every idea.</p>
        </body></html>
        """,
        "OEBPS/Text/chapter-two.xhtml": """
        <!doctype html><html><head><title>Second Principles</title></head><body>
        <h1>Second Principles</h1><p>Semantic retrieval reconnects durable notes while drafting.</p>
        <script>ignoreThisScript()</script>
        </body></html>
        """,
        "OEBPS/Text/appendix.xhtml": """
        <!doctype html><html><body><h1>Appendix</h1><p>Supplementary index.</p></body></html>
        """,
      ]
    )

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    let preview = try await service.makeImportPreview(sourceURL: sourceURL)
    let candidate = try XCTUnwrap(preview.candidates.first)

    XCTAssertEqual(candidate.kind, .book)
    XCTAssertEqual(candidate.title, "Thinking with Sources")
    XCTAssertEqual(candidate.authors, ["Ada Reader"])
    XCTAssertEqual(candidate.language, "en")
    XCTAssertEqual(candidate.summary, "A practical book about durable research notes.")
    XCTAssertEqual(candidate.tags, ["research", "writing"])
    XCTAssertEqual(candidate.sections.count, 2)
    XCTAssertEqual(candidate.sections.first?.headingPath, "Second Principles")
    XCTAssertEqual(candidate.sections.first?.locator, "第 1 章 · Second Principles")
    XCTAssertEqual(candidate.sections.last?.locator, "第 2 章 · First Notes")
    XCTAssertFalse(candidate.normalizedText.contains("ignoreThisScript"))
    XCTAssertTrue(candidate.warnings.contains { $0.contains("非线性阅读") })
    XCTAssertTrue(candidate.warnings.contains { $0.contains("2 个章节") })

    let secondRange = try XCTUnwrap(candidate.normalizedText.range(of: "Semantic retrieval"))
    let firstRange = try XCTUnwrap(candidate.normalizedText.range(of: "Atomic notes"))
    XCTAssertLessThan(secondRange.lowerBound, firstRange.lowerBound)

    let result = try await service.commit(preview)
    XCTAssertEqual(result.insertedCount, 1)
    let matches = try service.search(query: "semantic retrieval", limit: 10)
    XCTAssertFalse(matches.isEmpty)
    XCTAssertEqual(matches.first?.chunk.locator, "第 1 章 · Second Principles")
    let context = try service.context(query: "semantic retrieval")
    XCTAssertEqual(context?.citations.first?.locator, "第 1 章 · Second Principles")

    let paraphrasedMatches = try service.search(
      query: "how can I find related notes while drafting",
      limit: 10
    )
    XCTAssertEqual(paraphrasedMatches.first?.chunk.locator, "第 1 章 · Second Principles")
    XCTAssertTrue(paraphrasedMatches.first?.signals.contains(.semantic) ?? false)
  }

  func testEPUBRejectsChapterPathOutsideArchiveRoot() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-epub-path")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let sourceURL = try makeEPUB(
      in: rootURL,
      packageXML: """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:title>Unsafe Book</dc:title>
        </metadata>
        <manifest>
          <item id="escape" href="../../../outside.xhtml" media-type="application/xhtml+xml"/>
        </manifest>
        <spine><itemref idref="escape"/></spine>
      </package>
      """,
      chapters: [:]
    )

    let service = KnowledgeLibraryService(rootURL: rootURL.appendingPathComponent("store"))
    do {
      _ = try await service.makeImportPreview(sourceURL: sourceURL)
      XCTFail("Expected an unsafe EPUB path to be rejected")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("路径越界"))
    }
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
      KnowledgeDocument(kind: .book, title: "Gamma", sourceByteCount: 300, importedAt: Date(timeIntervalSince1970: 200)),
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
    _ = try await service.commit(try await service.makeImportPreview(sourceURL: sourceDirectory))

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

    XCTAssertFalse(try service.search(
      query: "省钱方法",
      onlyAIAllowed: true,
      documentIDs: [document.id]
    ).isEmpty)
    try service.setAllowsAIUse(false, documentID: document.id)
    XCTAssertTrue(try service.search(
      query: "省钱方法",
      onlyAIAllowed: true,
      documentIDs: [document.id]
    ).isEmpty)
    XCTAssertTrue(try service.search(
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
    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunk_embeddings;",
      at: databaseURL
    ), 0)

    let migratedService = KnowledgeLibraryService(rootURL: storeURL)
    let result = try XCTUnwrap(migratedService.search(query: "如何省钱", limit: 5).first)
    XCTAssertEqual(result.document.title, "个人财务")
    XCTAssertTrue(result.signals.contains(.semantic))
    XCTAssertGreaterThan(try querySQLiteInt(
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
    XCTAssertGreaterThan(try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'local-semantic-hash-v2' AND dimension = 12;",
      at: databaseURL
    ), 0)

    let repairedService = KnowledgeLibraryService(rootURL: storeURL)
    let result = try XCTUnwrap(repairedService.search(query: "怎样省钱", limit: 5).first)

    XCTAssertEqual(result.document.title, "家庭预算")
    XCTAssertTrue(result.signals.contains(.semantic))
    XCTAssertEqual(try querySQLiteInt(
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
    XCTAssertGreaterThan(try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'local-semantic-hash-v2' AND vector = zeroblob(dimension * 4);",
      at: databaseURL
    ), 0)

    let report = try await service.repairSemanticVectors()

    XCTAssertGreaterThan(report.scannedChunkCount, 0)
    XCTAssertGreaterThan(report.regeneratedVectorCount, 0)
    XCTAssertTrue(report.modelIdentifiers.contains("local-semantic-hash-v2"))
    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'local-semantic-hash-v2' AND vector = zeroblob(dimension * 4);",
      at: databaseURL
    ), 0)
    XCTAssertTrue(try service.search(query: "如何记住知识", limit: 5).contains {
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

    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'retired-semantic-model';",
      at: databaseURL
    ), 1)
    let healthBeforeRepair = try await service.libraryHealth()
    XCTAssertGreaterThan(healthBeforeRepair.semanticRepairChunkCount, 0)

    let report = try await service.repairSemanticVectors()

    XCTAssertGreaterThan(report.regeneratedVectorCount, 0)
    XCTAssertEqual(try querySQLiteInt(
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

    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunk_embeddings;",
      at: databaseURL
    ), originalVectorCount)
    XCTAssertEqual(try querySQLiteInt(
      "SELECT COUNT(*) FROM knowledge_chunk_embeddings WHERE model_id = 'retired-semantic-model';",
      at: databaseURL
    ), 1)
    XCTAssertGreaterThan(try querySQLiteInt(
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

    XCTAssertEqual(try querySQLiteInt(
      """
      SELECT COUNT(*)
      FROM knowledge_chunk_embeddings e
      JOIN knowledge_chunks c ON c.id = e.chunk_id
      WHERE e.model_id = 'retired-semantic-model'
        AND c.document_id = '\(firstDocumentID.uuidString)';
      """,
      at: databaseURL
    ), 0)
    XCTAssertGreaterThan(try querySQLiteInt(
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
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: recoveryURL.appendingPathComponent("current-only.txt").path
    ))
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: storeURL.appendingPathComponent("current-only.txt").path
    ))

    let restoredService = KnowledgeLibraryService(rootURL: storeURL)
    let document = try XCTUnwrap(restoredService.documents().first)
    XCTAssertEqual(document.id, restoredDocumentID)
    XCTAssertEqual(document.folderID, try restoredService.folders().first?.id)
    XCTAssertTrue(try restoredService.pinnedDocumentIDs().contains(document.id))
    XCTAssertTrue(try restoredService.normalizedText(documentID: document.id).contains("本地知识"))
  }

  func testKnowledgeBackupRoundTripRestoresBrowserCapturedText() async throws {
    let rootURL = temporaryDirectory(named: "knowledge-browser-capture-backup")
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let storeURL = rootURL.appendingPathComponent("store", isDirectory: true)
    let backupURL = rootURL.appendingPathComponent("browser-capture.pslibrarybackup", isDirectory: true)
    let capturedText = """
    # 浏览器采集正文

    这段文字必须和原始网页归档一起进入资料库备份。
    """
    let archive = Data("From: browser-extension\nContent-Type: multipart/related".utf8)
    var restoredDocumentID: UUID?

    do {
      let service = KnowledgeLibraryService(rootURL: storeURL)
      let capture = KnowledgeBrowserCapture(
        sourceURL: try XCTUnwrap(URL(string: "https://example.com/backup-proof")),
        title: "浏览器采集备份测试",
        authors: ["测试作者"],
        language: "zh-CN",
        summary: "验证采集正文和网页归档能够备份恢复",
        tags: ["备份", "浏览器采集"],
        capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
        contentText: capturedText,
        archiveFormat: "mhtml",
        archiveData: archive
      )
      let result = try await service.commit(
        try await service.makeBrowserImportPreview(capture: capture)
      )
      restoredDocumentID = try XCTUnwrap(result.documentIDs.first)

      _ = try await service.createBackup(
        at: backupURL,
        applicationVersion: "test-browser-capture"
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
    XCTAssertTrue(try restoredService.normalizedText(documentID: documentID).contains("必须和原始网页归档一起"))
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
    manifest.files.append(KnowledgeLibraryBackupFileRecord(
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
    let linkedBackupURL = rootURL.appendingPathComponent("linked.pslibrarybackup", isDirectory: true)
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
    let nestedRecord = try XCTUnwrap(manifest.files.first {
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
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: pendingURL.appendingPathComponent("unlisted/private.txt").path
    ))
    XCTAssertTrue(FileManager.default.fileExists(
      atPath: pendingURL.appendingPathComponent("library.sqlite").path
    ))
  }

  private func makeEPUB(
    in rootURL: URL,
    packageXML: String,
    chapters: [String: String]
  ) throws -> URL {
    let fixtureURL = rootURL.appendingPathComponent("fixture", isDirectory: true)
    let metaURL = fixtureURL.appendingPathComponent("META-INF", isDirectory: true)
    let packageURL = fixtureURL.appendingPathComponent("OEBPS", isDirectory: true)
    try FileManager.default.createDirectory(at: metaURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
    try "application/epub+zip".write(
      to: fixtureURL.appendingPathComponent("mimetype"),
      atomically: true,
      encoding: .utf8
    )
    try """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles>
        <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
      </rootfiles>
    </container>
    """.write(
      to: metaURL.appendingPathComponent("container.xml"),
      atomically: true,
      encoding: .utf8
    )
    try packageXML.write(
      to: packageURL.appendingPathComponent("content.opf"),
      atomically: true,
      encoding: .utf8
    )
    for (path, content) in chapters {
      let fileURL = fixtureURL.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    let archiveURL = rootURL.appendingPathComponent("book.epub")
    try runZIP(arguments: ["-q", "-X", "-0", archiveURL.path, "mimetype"], in: fixtureURL)
    try runZIP(arguments: ["-q", "-X", "-9", "-r", archiveURL.path, "META-INF", "OEBPS"], in: fixtureURL)
    return archiveURL
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

  private func runZIP(arguments: [String], in directoryURL: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = arguments
    process.currentDirectoryURL = directoryURL
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      let data = output.fileHandleForReading.readDataToEndOfFile()
      throw NSError(
        domain: "KnowledgeLibraryServiceTests.zip",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
      )
    }
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

  private func storedKnowledgeContentFiles(at rootURL: URL) -> [URL] {
    ["blobs", "captured", "normalized"].flatMap { directoryName -> [URL] in
      let directoryURL = rootURL.appendingPathComponent(directoryName, isDirectory: true)
      guard let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.isRegularFileKey]
      ) else { return [] }
      return enumerator.compactMap { item in
        guard let url = item as? URL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
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
          let statement else {
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
