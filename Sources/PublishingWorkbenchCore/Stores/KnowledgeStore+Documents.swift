import Combine
import Foundation

@MainActor
extension KnowledgeStore {
  public func createFolder(name: String) {
    do {
      let folder = try service.createFolder(name: name)
      folders.append(folder)
      folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      folderScope = .folder(folder.id)
      ensureVisibleSelection()
      statusMessage = "已创建资料文件夹“\(folder.name)”。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "新建文件夹失败：\(error.localizedDescription)"
    }
  }

  public func renameFolder(id: UUID, name: String) {
    do {
      _ = try service.renameFolder(id: id, name: name)
      folders = try service.folders()
      statusMessage = "资料文件夹已重命名。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "重命名失败：\(error.localizedDescription)"
    }
  }

  public func deleteFolder(id: UUID) {
    do {
      let name = folder(id: id)?.name ?? "文件夹"
      try service.deleteFolder(id: id)
      folders.removeAll { $0.id == id }
      for index in documents.indices where documents[index].folderID == id {
        documents[index].folderID = nil
      }
      searchResults = searchResults.map { result in
        guard result.document.folderID == id else { return result }
        var updated = result
        updated.document.folderID = nil
        return updated
      }
      if folderScope == .folder(id) {
        folderScope = .unfiled
      }
      ensureVisibleSelection()
      statusMessage = "已删除“\(name)”，其中资料已移到未分类。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "删除文件夹失败：\(error.localizedDescription)"
    }
  }

  public func moveDocument(_ documentID: UUID, to folderID: UUID?) {
    do {
      try service.setFolder(folderID, documentID: documentID)
      let now = Date()
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index].folderID = folderID
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document.folderID = folderID
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      let destination = folder(id: folderID)?.name ?? "未分类"
      statusMessage = "资料已移到“\(destination)”。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "移动资料失败：\(error.localizedDescription)"
    }
  }

  public func moveDocuments(_ documentIDs: Set<UUID>, to folderID: UUID?) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.setFolder(folderID, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        documents[index].folderID = folderID
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard documentIDs.contains(result.document.id) else { return result }
        var updated = result
        updated.document.folderID = folderID
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      let destination = folder(id: folderID)?.name ?? "未分类"
      statusMessage = "已将 \(documentIDs.count) 条资料移到“\(destination)”。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量移动失败：\(error.localizedDescription)"
    }
  }

  public func addTags(_ tags: [String], to documentIDs: Set<UUID>) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.addTags(tags, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        for tag in tags.map({ $0.trimmedForPublishing }).filter({ !$0.isEmpty })
        where
          !documents[index].tags.contains(where: {
            $0.compare(tag, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
          })
        {
          documents[index].tags.append(tag)
        }
        documents[index].updatedAt = now
      }
      searchResults = []
      if !searchText.trimmedForPublishing.isEmpty { updateSearchText(searchText) }
      ensureVisibleSelection()
      statusMessage = "已为 \(documentIDs.count) 条资料添加标签。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量添加标签失败：\(error.localizedDescription)"
    }
  }

  @discardableResult
  public func updateMetadata(
    documentID: UUID,
    metadata: KnowledgeDocumentMetadata
  ) -> Bool {
    do {
      let updatedDocument = try service.updateMetadata(
        documentID: documentID,
        metadata: metadata
      )
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index] = updatedDocument
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document = updatedDocument
        return updated
      }
      ensureVisibleSelection()
      statusMessage = "资料元数据已保存，并已更新全文与语义索引。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "元数据保存失败：\(error.localizedDescription)"
      return false
    }
  }

  public func makeImportPreview(
    sourceURL: URL,
    options: KnowledgeImportOptions = KnowledgeImportOptions()
  ) async throws -> KnowledgeImportPreview {
    statusMessage = "正在分析资料…"
    do {
      let preview = try await service.makeImportPreview(sourceURL: sourceURL, options: options)
      statusMessage = "资料预览已生成。"
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料分析失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func makeImportPreview(
    sourceURLs: [URL],
    options: KnowledgeImportOptions = KnowledgeImportOptions()
  ) async throws -> KnowledgeImportPreview {
    statusMessage = "正在分析拖入的资料…"
    do {
      let preview = try await service.makeImportPreview(
        sourceURLs: sourceURLs,
        options: options
      )
      statusMessage = "拖放资料预览已生成。"
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "拖放资料分析失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func makeWebImportPreview(url: URL) async throws -> KnowledgeImportPreview {
    statusMessage = "正在读取网页…"
    do {
      let preview = try await service.makeWebImportPreview(url: url)
      statusMessage = "网页预览已生成。"
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "网页读取失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func makeRSSImportPreview(article: RSSArticle) async throws -> KnowledgeImportPreview {
    statusMessage = CoreL10n.text("正在读取本机 RSS 缓存…")
    do {
      let preview = try await service.makeRSSImportPreview(article: article)
      statusMessage = CoreL10n.text("RSS 缓存预览已生成。")
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = CoreL10n.format("RSS 缓存读取失败：%@", error.localizedDescription)
      throw error
    }
  }

  public func commit(
    _ preview: KnowledgeImportPreview,
    destination: KnowledgeImportDestination = .preserveExisting
  ) async throws -> KnowledgeImportResult {
    beginImport(title: "保存并建立索引") { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.commit(preview, destination: destination)
      } catch {
        // `commit` records the failure on the store; the retry task must not
        // silently turn a failed save into a successful-looking background job.
      }
    }
    isBusy = true
    statusMessage = "正在保存并建立索引…"
    defer { isBusy = false }
    do {
      importProgress = 0.35
      let result = try await service.commit(preview, destination: destination)
      importProgress = 0.72
      await reload()
      finishImport()
      statusMessage =
        "资料导入完成：新增 \(result.insertedCount)，更新 \(result.updatedCount)，跳过 \(result.skippedCount)。"
      lastError = nil
      return result
    } catch {
      finishImport(failure: error.localizedDescription)
      lastError = error.localizedDescription
      statusMessage = "资料导入失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func importBrowserCapture(
    _ capture: KnowledgeBrowserCapture,
    folderID: UUID?,
    newFolderName: String?,
    duplicateResolution: KnowledgeBrowserDuplicateResolution? = nil
  ) async throws -> KnowledgeBrowserImportOutcome {
    beginImport(title: "保存浏览器页面") { [weak self] in
      guard let self else { return }
      do {
        _ = try await self.importBrowserCapture(
          capture,
          folderID: folderID,
          newFolderName: newFolderName,
          duplicateResolution: duplicateResolution
        )
      } catch {
        // `importBrowserCapture` publishes the user-visible error state itself.
      }
    }
    isBusy = true
    statusMessage = "正在保存浏览器页面并建立索引…"
    defer { isBusy = false }
    do {
      importProgress = 0.25
      var preview = try await service.makeBrowserImportPreview(capture: capture)
      guard var candidate = preview.candidates.first else {
        throw KnowledgeLibraryError.invalidBrowserCapture("浏览器页面没有可保存的内容。")
      }
      let currentDocuments = try service.documents()
      let currentFolders = try service.folders()
      let existingDocument = candidate.existingDocumentID.flatMap { documentID in
        currentDocuments.first(where: { $0.id == documentID })
      }
      let hasSameURL =
        existingDocument?.sourceURL?.absoluteString == candidate.sourceURL?.absoluteString
      if let existingDocument, hasSameURL, duplicateResolution == nil {
        let existingFolder = existingDocument.folderID.flatMap { existingFolderID in
          currentFolders.first(where: { $0.id == existingFolderID })
        }
        statusMessage = "检测到同网址资料，请选择处理方式。"
        lastError = nil
        finishImport()
        return .requiresDuplicateResolution(
          KnowledgeBrowserDuplicateConflict(
            document: existingDocument,
            folder: existingFolder,
            incomingHasChanges: candidate.disposition == .update
          ))
      }

      let destination = try browserImportDestination(
        folderID: folderID,
        newFolderName: newFolderName
      )
      let result: KnowledgeImportResult
      let action: KnowledgeBrowserImportAction
      importProgress = 0.62
      if let existingDocument, hasSameURL, duplicateResolution == .moveOnly {
        try service.setFolder(destination.folderID, documentID: existingDocument.id)
        result = KnowledgeImportResult(
          insertedCount: 0,
          updatedCount: 0,
          skippedCount: 0,
          documentIDs: [existingDocument.id]
        )
        action = .moved
      } else {
        if let existingDocument, hasSameURL, duplicateResolution == .saveNewVersion {
          candidate.existingDocumentID = existingDocument.id
          candidate.disposition = .update
        } else if hasSameURL, duplicateResolution == .keepCopy {
          candidate.existingDocumentID = nil
          candidate.disposition = .new
          candidate.title = "\(candidate.title)（副本）"
        }
        preview.candidates = [candidate]
        result = try await service.commit(preview, destination: destination.importDestination)
        if duplicateResolution == .keepCopy, hasSameURL {
          action = .copied
        } else if result.insertedCount > 0 {
          action = .inserted
        } else if result.updatedCount > 0 {
          action = .updated
        } else {
          action = .existing
        }
      }
      // 新版本和副本的 AI 权限已由导入候选项带入数据库事务。
      // “仅移动分类”不提交候选项，因此仍只更新分类并保留原 AI 权限。
      await reload(selecting: result.documentIDs.first)
      finishImport()
      statusMessage =
        action == .moved
        ? "已将原资料移到选定分类；正文、元数据和 AI 权限均保持不变。"
        : "浏览器页面已保存到资料库。"
      lastError = nil
      return .saved(result: result, action: action)
    } catch {
      finishImport(failure: error.localizedDescription)
      lastError = error.localizedDescription
      statusMessage = "浏览器页面保存失败：\(error.localizedDescription)"
      throw error
    }
  }

  func browserImportDestination(
    folderID: UUID?,
    newFolderName: String?
  ) throws -> (importDestination: KnowledgeImportDestination, folderID: UUID?) {
    if let requestedName = newFolderName?.trimmedForPublishing.nilIfEmpty {
      if let existing = try service.folders().first(where: {
        $0.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive])
          == .orderedSame
      }) {
        return (.folder(existing.id), existing.id)
      }
      let folder = try service.createFolder(name: requestedName)
      return (.folder(folder.id), folder.id)
    }
    if let folderID {
      return (.folder(folderID), folderID)
    }
    return (.unfiled, nil)
  }

  public func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentID: UUID) {
    do {
      try service.setAllowsLocalSemanticIndex(allowsLocalSemanticIndex, documentID: documentID)
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index].allowsLocalSemanticIndex = allowsLocalSemanticIndex
        documents[index].updatedAt = Date()
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document.allowsLocalSemanticIndex = allowsLocalSemanticIndex
        return updated
      }
      ensureVisibleSelection()
      statusMessage = allowsLocalSemanticIndex
        ? "这条资料已建立本地语义索引。"
        : "这条资料已关闭本地语义索引。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料设置保存失败：\(error.localizedDescription)"
    }
  }

  public func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentIDs: Set<UUID>) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.setAllowsLocalSemanticIndex(allowsLocalSemanticIndex, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        documents[index].allowsLocalSemanticIndex = allowsLocalSemanticIndex
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard documentIDs.contains(result.document.id) else { return result }
        var updated = result
        updated.document.allowsLocalSemanticIndex = allowsLocalSemanticIndex
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      statusMessage =
        allowsLocalSemanticIndex
        ? "已为 \(documentIDs.count) 条资料建立本地语义索引。"
        : "已关闭 \(documentIDs.count) 条资料的本地语义索引。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量本地语义索引设置失败：\(error.localizedDescription)"
    }
  }

  public func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentID: UUID) {
    do {
      try service.setAllowsRemoteAIUse(allowsRemoteAIUse, documentID: documentID)
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index].allowsRemoteAIUse = allowsRemoteAIUse
        documents[index].updatedAt = Date()
      }
      searchResults = searchResults.map { result in
        guard result.document.id == documentID else { return result }
        var updated = result
        updated.document.allowsRemoteAIUse = allowsRemoteAIUse
        return updated
      }
      ensureVisibleSelection()
      statusMessage = allowsRemoteAIUse
        ? "这条资料已允许发送给远程 AI。"
        : "这条资料已禁止发送给远程 AI。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料远程 AI 权限保存失败：\(error.localizedDescription)"
    }
  }

  public func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentIDs: Set<UUID>) {
    guard !documentIDs.isEmpty else { return }
    do {
      try service.setAllowsRemoteAIUse(allowsRemoteAIUse, documentIDs: documentIDs)
      let now = Date()
      for index in documents.indices where documentIDs.contains(documents[index].id) {
        documents[index].allowsRemoteAIUse = allowsRemoteAIUse
        documents[index].updatedAt = now
      }
      searchResults = searchResults.map { result in
        guard documentIDs.contains(result.document.id) else { return result }
        var updated = result
        updated.document.allowsRemoteAIUse = allowsRemoteAIUse
        updated.document.updatedAt = now
        return updated
      }
      ensureVisibleSelection()
      statusMessage = allowsRemoteAIUse
        ? "已允许发送给远程 AI 的资料：\(documentIDs.count) 条。"
        : "已禁止发送给远程 AI 的资料：\(documentIDs.count) 条。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "批量远程 AI 权限设置失败：\(error.localizedDescription)"
    }
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  public func setAllowsAIUse(_ allowsAIUse: Bool, documentID: UUID) {
    setAllowsRemoteAIUse(allowsAIUse, documentID: documentID)
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  public func setAllowsAIUse(_ allowsAIUse: Bool, documentIDs: Set<UUID>) {
    setAllowsRemoteAIUse(allowsAIUse, documentIDs: documentIDs)
  }

  @discardableResult
  public func moveToRecycleBin(_ documentIDs: Set<UUID>) -> Bool {
    guard !documentIDs.isEmpty else { return false }
    do {
      let now = Date()
      let movingDocuments = documents.filter { documentIDs.contains($0.id) }
      try service.moveToRecycleBin(documentIDs: documentIDs)
      documents.removeAll { documentIDs.contains($0.id) }
      searchResults.removeAll { documentIDs.contains($0.document.id) }
      recycledDocuments.insert(
        contentsOf: movingDocuments.map { document in
          var archived = document
          archived.isArchived = true
          archived.updatedAt = now
          return KnowledgeRecycledDocument(document: archived, deletedAt: now)
        }, at: 0)
      ensureVisibleSelection()
      statusMessage = "已将 \(documentIDs.count) 条资料移到回收站，可随时恢复。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "移到回收站失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  public func restoreFromRecycleBin(_ documentIDs: Set<UUID>) -> Bool {
    guard !documentIDs.isEmpty else { return false }
    do {
      let now = Date()
      let restoring = recycledDocuments.filter { documentIDs.contains($0.id) }
      try service.restoreFromRecycleBin(documentIDs: documentIDs)
      recycledDocuments.removeAll { documentIDs.contains($0.id) }
      documents.append(
        contentsOf: restoring.map { recycled in
          var document = recycled.document
          document.isArchived = false
          document.updatedAt = now
          return document
        })
      statusMessage = "已从回收站恢复 \(documentIDs.count) 条资料。"
      lastError = nil
      if let firstID = documentIDs.first { selectDocument(firstID) }
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "恢复资料失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  public func deleteDocument(_ documentID: UUID) -> Bool {
    do {
      let report = try service.deleteDocument(id: documentID)
      documents.removeAll { $0.id == documentID }
      recycledDocuments.removeAll { $0.id == documentID }
      searchResults.removeAll { $0.document.id == documentID }
      pinnedDocumentIDs.remove(documentID)
      ensureVisibleSelection()
      if report.failedStoredFileCount == 0 {
        statusMessage = "资料已永久删除，本地副本和检索索引已清理。"
      } else {
        statusMessage = "资料和检索索引已删除；有 \(report.failedStoredFileCount) 个本地副本因文件权限未能清理。"
      }
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "删除失败：\(error.localizedDescription)"
      return false
    }
  }

  /// Permanently deletes every item currently in the recycle bin on a utility
  /// task, then reconciles in-memory presentation state on the main actor.
  public func emptyRecycleBin() async -> KnowledgeRecycleBinCleanupSummary {
    let documentIDs = recycledDocuments.map(\.id)
    guard !documentIDs.isEmpty, !isBusy else {
      return KnowledgeRecycleBinCleanupSummary(
        requestedDocumentCount: documentIDs.count,
        removedDocumentCount: 0,
        failedDocumentCount: 0,
        removedStoredFileCount: 0,
        failedStoredFileCount: 0
      )
    }

    isBusy = true
    defer { isBusy = false }
    let service = self.service
    let result = await Task.detached(priority: .utility) {
      var removedIDs: [UUID] = []
      var failedDocumentCount = 0
      var removedStoredFileCount = 0
      var failedStoredFileCount = 0
      for documentID in documentIDs {
        do {
          let report = try service.deleteDocument(id: documentID)
          removedIDs.append(documentID)
          removedStoredFileCount += report.removedStoredFileCount
          failedStoredFileCount += report.failedStoredFileCount
        } catch {
          failedDocumentCount += 1
        }
      }
      return (
        removedIDs,
        failedDocumentCount,
        removedStoredFileCount,
        failedStoredFileCount
      )
    }.value

    let removedIDSet = Set(result.0)
    documents.removeAll { removedIDSet.contains($0.id) }
    recycledDocuments.removeAll { removedIDSet.contains($0.id) }
    searchResults.removeAll { removedIDSet.contains($0.document.id) }
    pinnedDocumentIDs.subtract(removedIDSet)
    ensureVisibleSelection()

    let summary = KnowledgeRecycleBinCleanupSummary(
      requestedDocumentCount: documentIDs.count,
      removedDocumentCount: removedIDSet.count,
      failedDocumentCount: result.1,
      removedStoredFileCount: result.2,
      failedStoredFileCount: result.3
    )
    if summary.failedDocumentCount == 0, summary.failedStoredFileCount == 0 {
      statusMessage = CoreL10n.format(
        "资料库回收站已清空：永久删除 %d 条资料。",
        summary.removedDocumentCount
      )
      lastError = nil
    } else {
      statusMessage = CoreL10n.format(
        "资料库回收站已清理：删除 %d 条，%d 条未能删除，%d 个本地文件未能移除。",
        summary.removedDocumentCount,
        summary.failedDocumentCount,
        summary.failedStoredFileCount
      )
      lastError = statusMessage
    }
    return summary
  }

  @discardableResult
  public func saveAnnotation(_ annotation: KnowledgeAnnotation) -> Bool {
    do {
      let saved = try service.saveAnnotation(annotation)
      annotations.removeAll { $0.id == saved.id }
      annotations.insert(saved, at: 0)
      statusMessage = "资料标注已保存。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "标注保存失败：\(error.localizedDescription)"
      return false
    }
  }

  public func deleteAnnotation(_ annotationID: UUID) {
    do {
      try service.deleteAnnotation(id: annotationID)
      annotations.removeAll { $0.id == annotationID }
      statusMessage = "资料标注已删除。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "标注删除失败：\(error.localizedDescription)"
    }
  }

  public func recordBacklinks(
    citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) {
    do {
      try service.recordBacklinks(citations: citations, target: target)
      if let selectedDocumentID, citations.contains(where: { $0.documentID == selectedDocumentID })
      {
        backlinks = try service.backlinks(documentID: selectedDocumentID)
      }
      if target.kind == .articleDraft,
         articleBacklinksTargetID == target.id {
        loadArticleBacklinks(for: UUID(uuidString: target.id))
      }
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料引用记录未保存：\(error.localizedDescription)"
    }
  }

  public func makeSourceRefreshPreview(
    documentID: UUID
  ) async throws -> KnowledgeSourceRefreshPreview {
    statusMessage = "正在检查资料来源更新…"
    do {
      let preview = try await service.makeSourceRefreshPreview(documentID: documentID)
      statusMessage =
        preview.difference.hasChanges
        ? "已发现来源内容变化，可预览后更新。"
        : "来源内容与当前版本一致。"
      lastError = nil
      return preview
    } catch {
      lastError = error.localizedDescription
      statusMessage = "来源检查失败：\(error.localizedDescription)"
      throw error
    }
  }

  public func revisionDifference(
    documentID: UUID,
    revisionID: UUID
  ) async throws -> KnowledgeRevisionDifference {
    let service = self.service
    return try await Task.detached(priority: .utility) {
      try service.revisionDifference(documentID: documentID, revisionID: revisionID)
    }.value
  }

  @discardableResult
  public func applySourceRefresh(_ preview: KnowledgeSourceRefreshPreview) async -> Bool {
    isBusy = true
    defer { isBusy = false }
    do {
      let result = try await service.applySourceRefresh(preview)
      await reload(selecting: preview.documentID)
      statusMessage =
        result.updatedCount > 0
        ? "来源更新已保存为新版本，可在版本历史中恢复旧内容。"
        : "来源内容未变化，没有创建重复版本。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "来源更新失败：\(error.localizedDescription)"
      return false
    }
  }

  @discardableResult
  public func restoreRevision(_ revisionID: UUID, documentID: UUID) -> Bool {
    do {
      let restored = try service.restoreRevision(documentID: documentID, revisionID: revisionID)
      if let index = documents.firstIndex(where: { $0.id == documentID }) {
        documents[index] = restored
      }
      selectedDocumentText = ""
      loadDocument(nil)
      loadDocument(documentID)
      loadDocumentInsights(documentID: documentID)
      loadRelatedChapters(documentID: documentID, anchorChunkID: nil)
      statusMessage = "已恢复所选资料版本，全文与语义检索已切换。"
      lastError = nil
      return true
    } catch {
      lastError = error.localizedDescription
      statusMessage = "版本恢复失败：\(error.localizedDescription)"
      return false
    }
  }

  public func setPinned(_ pinned: Bool, documentID: UUID) {
    do {
      try service.setPinned(pinned, documentID: documentID)
      if pinned {
        pinnedDocumentIDs.insert(documentID)
      } else {
        pinnedDocumentIDs.remove(documentID)
      }
      statusMessage = pinned ? "资料已固定到 AI 对话。" : "资料已取消固定。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "固定状态保存失败：\(error.localizedDescription)"
    }
  }

  public func isPinned(_ documentID: UUID) -> Bool {
    pinnedDocumentIDs.contains(documentID)
  }
}
