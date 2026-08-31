import Combine
import Foundation

@MainActor
extension KnowledgeStore {
  public func createBackup(at destinationURL: URL) async -> KnowledgeLibraryBackupPreview? {
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在创建资料库一致性备份…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      let preview = try await service.createBackup(at: destinationURL)
      statusMessage = "资料库备份完成：\(preview.documentCount) 条资料，已通过完整性校验。"
      lastError = nil
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料库备份失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func exportDocuments(
    _ documentIDs: Set<UUID>,
    to destinationDirectory: URL
  ) async -> KnowledgeBatchExportReport? {
    guard !documentIDs.isEmpty else { return nil }
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在导出 \(documentIDs.count) 条资料…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      let report = try await service.exportDocuments(
        documentIDs: documentIDs,
        to: destinationDirectory
      )
      statusMessage = "已将 \(report.exportedDocumentCount) 条资料导出为 Markdown。"
      lastError = nil
      return report
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料导出失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func rebuildSemanticIndex(for documentIDs: Set<UUID>) async {
    guard !documentIDs.isEmpty else { return }
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在重建所选资料的本地语义向量…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      let report = try await performQueuedKnowledgeMutation { [service] in
        try await service.repairSemanticVectors(documentIDs: documentIDs)
      }
      statusMessage =
        "语义索引重建完成：扫描 \(report.scannedChunkCount) 个片段，生成 \(report.regeneratedVectorCount) 个向量。"
      lastError = nil
      await refreshLibraryHealth()
    } catch {
      lastError = error.localizedDescription
      statusMessage = "语义索引重建失败：\(error.localizedDescription)"
    }
  }

  public func rebuildAllSemanticIndex() async {
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在事务性替换全部本地语义向量…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      let report = try await performQueuedKnowledgeMutation { [service] in
        try await service.repairSemanticVectors()
      }
      statusMessage =
        "语义索引重建完成：扫描 \(report.scannedChunkCount) 个片段，生成 \(report.regeneratedVectorCount) 个向量，并清理旧模型。"
      lastError = nil
      await refreshLibraryHealth()
    } catch {
      lastError = error.localizedDescription
      statusMessage = "语义索引重建失败，旧索引已保留：\(error.localizedDescription)"
    }
  }

  @discardableResult
  public func refreshLibraryHealth() async -> KnowledgeLibraryHealthSnapshot? {
    isLoadingHealth = true
    defer { isLoadingHealth = false }
    do {
      let snapshot = try await service.libraryHealth()
      healthSnapshot = snapshot
      lastError = nil
      do {
        try await service.maintainDatabase()
      } catch {
        // Passive background database maintenance is best-effort.
      }
      return snapshot
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料库健康检查失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func localContentRepairPreviews(
    documentIDs: Set<UUID>? = nil,
    includingCurrentParserVersion: Bool = false
  ) async -> [KnowledgeSourceRefreshPreview]? {
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在分析本机网页归档和旧解析器版本…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      let previews = try await service.makeLocalContentRepairPreviews(
        documentIDs: documentIDs,
        includingCurrentParserVersion: includingCurrentParserVersion
      )
      statusMessage =
        previews.isEmpty
        ? "没有找到可使用本机原始归档重新净化的网页资料。"
        : "发现 \(previews.count) 条可在本机重新净化的网页资料，请预览后修复。"
      lastError = nil
      return previews
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料质量分析失败：\(error.localizedDescription)"
      return nil
    }
  }

  @discardableResult
  public func applyLocalContentRepairs(
    _ previews: [KnowledgeSourceRefreshPreview]
  ) async -> Bool {
    guard !previews.isEmpty else { return true }
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在重新净化网页正文并重建全文与语义索引…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      let result = try await performQueuedKnowledgeMutation { [service] in
        try await service.applyLocalContentRepairs(previews)
      }
      let selectedID = selectedDocumentID
      await reloadAfterAcceptedMutation(selecting: selectedID)
      _ = await refreshLibraryHealth()
      statusMessage = "资料质量修复完成：已为 \(result.updatedCount) 条网页创建新版，并重建检索索引。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料质量修复失败：\(error.localizedDescription)"
      return false
    }
  }

  public func backupPreview(from backupURL: URL) async -> KnowledgeLibraryBackupPreview? {
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在校验资料库备份…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      let preview = try await service.inspectBackup(at: backupURL)
      statusMessage = "备份校验通过，可以预览后恢复。"
      lastError = nil
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "备份不可恢复：\(error.localizedDescription)"
      return nil
    }
  }

  public func stageRestore(from backupURL: URL) async -> Bool {
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在准备资料库恢复…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      _ = try await service.stageRestore(from: backupURL)
      statusMessage = "恢复包已安全暂存，应用重新启动后生效。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "恢复准备失败：\(error.localizedDescription)"
      return false
    }
  }

  public func reportStartupRestoreOutcome(_ outcome: KnowledgeLibraryRestoreStartupOutcome) {
    switch outcome {
    case .none:
      break
    case .restored(let result):
      let recoveryMessage =
        result.previousLibraryURL.map {
          "恢复前资料库已保留在 \($0.path)。"
        } ?? "恢复前没有现有资料库。"
      statusMessage = "资料库已从备份恢复，共 \(result.restoredPreview.documentCount) 条资料。\(recoveryMessage)"
      lastError = nil
    case .failed(let detail):
      lastError = detail
      statusMessage = "资料库自动恢复未完成：\(detail)"
    }
  }

  func ensureVisibleSelection() {
    if !searchText.trimmedForPublishing.isEmpty {
      if let selectedSearchResult,
        visibleSearchResults.contains(where: { $0.id == selectedSearchResult.id })
      {
        return
      }
      if let result = visibleSearchResults.first {
        selectSearchResult(result)
      } else {
        selectDocument(nil)
      }
      return
    }
    if let selectedDocumentID,
      visibleDocuments.contains(where: { $0.id == selectedDocumentID })
    {
      return
    }
    selectDocument(visibleDocuments.first?.id)
  }

  func isIncludedInCurrentScope(_ document: KnowledgeDocument) -> Bool {
    switch folderScope {
    case .all:
      true
    case .unfiled:
      document.folderID == nil
    case .folder(let folderID):
      document.folderID == folderID
    case .smartCollection(let rule):
      smartCollectionService.matches(document, rule: rule)
    case .savedCollection(let collection):
      smartCollectionService.matches(
        document,
        rules: collection.rules,
        matchMode: collection.matchMode
      )
    }
  }

  public func context(
    query: String,
    policy: KnowledgeRetrievalPolicy
  ) async -> KnowledgeContextSnapshot? {
    guard policy != .off else { return nil }
    guard !documents.isEmpty else { return nil }
    let scopedIDs: Set<UUID>?
    switch policy {
    case .off:
      return nil
    case .automatic:
      scopedIDs = nil
    case .pinnedOnly:
      guard !pinnedDocumentIDs.isEmpty else { return nil }
      scopedIDs = pinnedDocumentIDs
    }

    do {
      let snapshot = try await service.contextAsync(query: query, documentIDs: scopedIDs)
      if let snapshot {
        statusMessage = "资料库通过全文与本地语义检索找到 \(snapshot.citations.count) 条相关片段。"
      } else {
        statusMessage = "全文与本地语义检索都没有找到足够相关的内容。"
      }
      return snapshot
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料库检索失败：\(error.localizedDescription)"
      return nil
    }
  }

  /// Retrieves local-only recommendations for the article context card.
  ///
  /// This path intentionally does not require `allowsRemoteAIUse`: showing a
  /// local recommendation is different from transmitting the source to a
  /// remote provider. Documents that opted out of the local semantic index are
  /// excluded by the database and by the final guard below.
  public func contextRecommendations(
    query: String,
    limit: Int = 6
  ) async throws -> [KnowledgeSearchResult] {
    let trimmedQuery = query.trimmedForPublishing
    guard !trimmedQuery.isEmpty, limit > 0 else { return [] }
    let localDocumentIDs = Set<UUID>(
      documents.compactMap { document in
        guard !document.isArchived, document.allowsLocalSemanticIndex else { return nil }
        return document.id
      }
    )
    guard !localDocumentIDs.isEmpty else { return [] }
    let results = try await service.searchAsync(
      query: trimmedQuery,
      limit: max(limit, 12),
      onlyRemoteAIAllowed: false,
      documentIDs: localDocumentIDs
    )
    return
      results
      .filter { !$0.document.isArchived && $0.document.allowsLocalSemanticIndex }
      .prefix(limit)
      .map { $0 }
  }

  /// Resolves one user-selected knowledge document for an explicit AI @
  /// reference. This does not change library selection and refuses documents
  /// that are archived or not authorized for AI use.
  public func explicitAIContextSnapshot(
    documentID: UUID
  ) async -> KnowledgeExplicitContextSnapshot? {
    do {
      return try await service.explicitAIContextSnapshot(documentID: documentID)
    } catch {
      lastError = error.localizedDescription
      statusMessage = "读取 @ 资料失败：\(error.localizedDescription)"
      return nil
    }
  }

  public func explicitAIContextText(documentID: UUID) async -> String? {
    await explicitAIContextSnapshot(documentID: documentID)?.text
  }

  /// Checks captured knowledge bindings against the SQLite authority, rather
  /// than the store's presentation cache. This closes the gap between a
  /// preview and the actual transport when permissions, revisions, archive
  /// state, or pinned membership changed meanwhile.
  public func validateKnowledgeAuthorizationBindings(
    _ bindings: [KnowledgeAuthorizationBinding],
    policy: KnowledgeRetrievalPolicy
  ) async -> Bool {
    do {
      return try await service.validateKnowledgeAuthorizationBindings(bindings, policy: policy)
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料权限校验失败，本次未发送。"
      return false
    }
  }
}
