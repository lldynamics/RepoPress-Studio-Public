import Combine
import Foundation

@MainActor
extension KnowledgeStore {
  /// Keeps legacy synchronous UI actions responsive while their persistence
  /// work awaits the cancellable service boundary. The lease belongs to the
  /// scheduled operation, so another completion cannot clear busy state.
  func enqueueKnowledgeIO(_ operation: @escaping @MainActor () async -> Void) async {
    let busyOperationID = beginBusyOperation()
    await performQueuedKnowledgeMutation { [weak self] in
      guard let self else { return }
      defer { finishBusyOperation(busyOperationID) }
      await operation()
    }
  }

  public func createFolder(name: String) async {
    await enqueueKnowledgeIO { [weak self] in
      await self?.createFolderAsync(name: name)
    }
  }

  private func createFolderAsync(name: String) async {
    do {
      let folder = try await service.createFolderAsync(name: name)
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

  public func renameFolder(id: UUID, name: String) async {
    await enqueueKnowledgeIO { [weak self] in
      await self?.renameFolderAsync(id: id, name: name)
    }
  }

  private func renameFolderAsync(id: UUID, name: String) async {
    do {
      _ = try await service.renameFolderAsync(id: id, name: name)
      folders = try await service.foldersAsync()
      statusMessage = "资料文件夹已重命名。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "重命名失败：\(error.localizedDescription)"
    }
  }

  public func deleteFolder(id: UUID) async {
    let name = folder(id: id)?.name ?? "文件夹"
    await enqueueKnowledgeIO { [weak self] in
      await self?.deleteFolderAsync(id: id, name: name)
    }
  }

  private func deleteFolderAsync(id: UUID, name: String) async {
    do {
      try await service.deleteFolderAsync(id: id)
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

  public func moveDocument(_ documentID: UUID, to folderID: UUID?) async {
    await enqueueKnowledgeIO { [weak self] in
      await self?.moveDocumentAsync(documentID, to: folderID)
    }
  }

  private func moveDocumentAsync(_ documentID: UUID, to folderID: UUID?) async {
    do {
      try await service.setFolderAsync(folderID, documentID: documentID)
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

  public func moveDocuments(_ documentIDs: Set<UUID>, to folderID: UUID?) async {
    guard !documentIDs.isEmpty else { return }
    await enqueueKnowledgeIO { [weak self] in
      await self?.moveDocumentsAsync(documentIDs, to: folderID)
    }
  }

  private func moveDocumentsAsync(_ documentIDs: Set<UUID>, to folderID: UUID?) async {
    do {
      try await service.setFolderAsync(folderID, documentIDs: documentIDs)
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

  public func addTags(_ tags: [String], to documentIDs: Set<UUID>) async {
    guard !documentIDs.isEmpty else { return }
    await enqueueKnowledgeIO { [weak self] in
      await self?.addTagsAsync(tags, to: documentIDs)
    }
  }

  private func addTagsAsync(_ tags: [String], to documentIDs: Set<UUID>) async {
    do {
      try await service.addTagsAsync(tags, documentIDs: documentIDs)
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
  ) async -> Bool {
    var succeeded = false
    await enqueueKnowledgeIO { [weak self] in
      guard let self else { return }
      succeeded = await self.updateMetadataAsync(documentID: documentID, metadata: metadata)
    }
    return succeeded
  }

  private func updateMetadataAsync(
    documentID: UUID,
    metadata: KnowledgeDocumentMetadata
  ) async -> Bool {
    do {
      let updatedDocument = try await service.updateMetadataAsync(
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
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在保存并建立索引…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      importProgress = 0.35
      let result = try await performQueuedKnowledgeMutation { [service] in
        try await service.commit(preview, destination: destination)
      }
      importProgress = 0.72
      await waitAfterAcceptedMutationBeforeProjection()
      await reloadAfterAcceptedMutation()
      finishImport()
      statusMessage =
        "资料导入完成：新增 \(result.insertedCount)，更新 \(result.updatedCount)，跳过 \(result.skippedCount)。"
      lastError = nil
      recordKnowledgeImportEvent(
        outcome: knowledgeImportOutcome(for: result),
        result: result
      )
      return result
    } catch {
      finishImport(failure: error.localizedDescription)
      lastError = error.localizedDescription
      statusMessage = "资料导入失败：\(error.localizedDescription)"
      recordKnowledgeImportEvent(
        outcome: error is CancellationError ? .cancelled : .failed
      )
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
    let busyOperationID = beginBusyOperation()
    statusMessage = "正在保存浏览器页面并建立索引…"
    defer { finishBusyOperation(busyOperationID) }
    do {
      importProgress = 0.25
      var preview = try await service.makeBrowserImportPreview(capture: capture)
      guard var candidate = preview.candidates.first else {
        throw KnowledgeLibraryError.invalidBrowserCapture("浏览器页面没有可保存的内容。")
      }
      let currentDocuments = try await service.documentsAsync()
      let currentFolders = try await service.foldersAsync()
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

      let destination = try await browserImportDestination(
        folderID: folderID,
        newFolderName: newFolderName
      )
      let result: KnowledgeImportResult
      let action: KnowledgeBrowserImportAction
      importProgress = 0.62
      if let existingDocument, hasSameURL, duplicateResolution == .moveOnly {
        try await performQueuedKnowledgeMutation { [service] in
          try await service.setFolderAsync(destination.folderID, documentID: existingDocument.id)
        }
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
        result = try await performQueuedKnowledgeMutation { [service] in
          try await service.commit(preview, destination: destination.importDestination)
        }
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
      await waitAfterAcceptedMutationBeforeProjection()
      await reloadAfterAcceptedMutation(selecting: result.documentIDs.first)
      finishImport()
      statusMessage =
        action == .moved
        ? "已将原资料移到选定分类；正文、元数据和 AI 权限均保持不变。"
        : "浏览器页面已保存到资料库。"
      lastError = nil
      recordKnowledgeImportEvent(
        outcome: knowledgeImportOutcome(for: result),
        result: result
      )
      return .saved(result: result, action: action)
    } catch {
      finishImport(failure: error.localizedDescription)
      recordKnowledgeImportEvent(
        outcome: error is CancellationError ? .cancelled : .failed
      )
      lastError = error.localizedDescription
      statusMessage = "浏览器页面保存失败：\(error.localizedDescription)"
      throw error
    }
  }

  func browserImportDestination(
    folderID: UUID?,
    newFolderName: String?
  ) async throws -> (importDestination: KnowledgeImportDestination, folderID: UUID?) {
    if let requestedName = newFolderName?.trimmedForPublishing.nilIfEmpty {
      if let existing = try await service.foldersAsync().first(where: {
        $0.name.compare(requestedName, options: [.caseInsensitive, .diacriticInsensitive])
          == .orderedSame
      }) {
        return (.folder(existing.id), existing.id)
      }
      let folder = try await performQueuedKnowledgeMutation { [service] in
        try await service.createFolderAsync(name: requestedName)
      }
      return (.folder(folder.id), folder.id)
    }
    if let folderID {
      return (.folder(folderID), folderID)
    }
    return (.unfiled, nil)
  }

  public func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentID: UUID) async
  {
    await enqueueKnowledgeIO { [weak self] in
      await self?.setAllowsLocalSemanticIndexAsync(
        allowsLocalSemanticIndex,
        documentID: documentID
      )
    }
  }

  private func setAllowsLocalSemanticIndexAsync(
    _ allowsLocalSemanticIndex: Bool,
    documentID: UUID
  ) async {
    do {
      try await service.setAllowsLocalSemanticIndexAsync(
        allowsLocalSemanticIndex,
        documentID: documentID
      )
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
      statusMessage =
        allowsLocalSemanticIndex
        ? "这条资料已建立本地语义索引。"
        : "这条资料已关闭本地语义索引。"
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      statusMessage = "资料设置保存失败：\(error.localizedDescription)"
    }
  }

  public func setAllowsLocalSemanticIndex(_ allowsLocalSemanticIndex: Bool, documentIDs: Set<UUID>)
    async
  {
    guard !documentIDs.isEmpty else { return }
    await enqueueKnowledgeIO { [weak self] in
      await self?.setAllowsLocalSemanticIndexAsync(
        allowsLocalSemanticIndex,
        documentIDs: documentIDs
      )
    }
  }

  private func setAllowsLocalSemanticIndexAsync(
    _ allowsLocalSemanticIndex: Bool,
    documentIDs: Set<UUID>
  ) async {
    do {
      try await service.setAllowsLocalSemanticIndexAsync(
        allowsLocalSemanticIndex,
        documentIDs: documentIDs
      )
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

  public func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentID: UUID) async {
    await enqueueKnowledgeIO { [weak self] in
      await self?.setAllowsRemoteAIUseAsync(allowsRemoteAIUse, documentID: documentID)
    }
  }

  private func setAllowsRemoteAIUseAsync(
    _ allowsRemoteAIUse: Bool,
    documentID: UUID
  ) async {
    do {
      try await service.setAllowsRemoteAIUseAsync(allowsRemoteAIUse, documentID: documentID)
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

  public func setAllowsRemoteAIUse(_ allowsRemoteAIUse: Bool, documentIDs: Set<UUID>) async {
    guard !documentIDs.isEmpty else { return }
    await enqueueKnowledgeIO { [weak self] in
      await self?.setAllowsRemoteAIUseAsync(allowsRemoteAIUse, documentIDs: documentIDs)
    }
  }

  private func setAllowsRemoteAIUseAsync(
    _ allowsRemoteAIUse: Bool,
    documentIDs: Set<UUID>
  ) async {
    do {
      try await service.setAllowsRemoteAIUseAsync(allowsRemoteAIUse, documentIDs: documentIDs)
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
  public func setAllowsAIUse(_ allowsAIUse: Bool, documentID: UUID) async {
    await setAllowsRemoteAIUse(allowsAIUse, documentID: documentID)
  }

  @available(*, deprecated, message: "请使用 setAllowsRemoteAIUse")
  public func setAllowsAIUse(_ allowsAIUse: Bool, documentIDs: Set<UUID>) async {
    await setAllowsRemoteAIUse(allowsAIUse, documentIDs: documentIDs)
  }

  @discardableResult
  public func moveToRecycleBin(_ documentIDs: Set<UUID>) async -> Bool {
    guard !documentIDs.isEmpty else { return false }
    var succeeded = false
    await enqueueKnowledgeIO { [weak self] in
      guard let self else { return }
      succeeded = await self.moveToRecycleBinAsync(documentIDs)
    }
    return succeeded
  }

  private func moveToRecycleBinAsync(_ documentIDs: Set<UUID>) async -> Bool {
    do {
      let now = Date()
      let movingDocuments = documents.filter { documentIDs.contains($0.id) }
      try await service.moveToRecycleBinAsync(documentIDs: documentIDs)
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
  public func restoreFromRecycleBin(_ documentIDs: Set<UUID>) async -> Bool {
    guard !documentIDs.isEmpty else { return false }
    var succeeded = false
    await enqueueKnowledgeIO { [weak self] in
      guard let self else { return }
      succeeded = await self.restoreFromRecycleBinAsync(documentIDs)
    }
    return succeeded
  }

  private func restoreFromRecycleBinAsync(_ documentIDs: Set<UUID>) async -> Bool {
    do {
      let now = Date()
      let restoring = recycledDocuments.filter { documentIDs.contains($0.id) }
      try await service.restoreFromRecycleBinAsync(documentIDs: documentIDs)
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
  public func deleteDocument(_ documentID: UUID) async -> Bool {
    var succeeded = false
    await enqueueKnowledgeIO { [weak self] in
      guard let self else { return }
      succeeded = await self.deleteDocumentAsync(documentID)
    }
    return succeeded
  }

  private func deleteDocumentAsync(_ documentID: UUID) async -> Bool {
    do {
      let report = try await service.deleteDocumentAsync(id: documentID)
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
    let busyOperationID = beginBusyOperation()
    defer { finishBusyOperation(busyOperationID) }
    do {
      return try await performQueuedKnowledgeMutation { [weak self] in
        guard let self else {
          return KnowledgeRecycleBinCleanupSummary(
            requestedDocumentCount: documentIDs.count,
            removedDocumentCount: 0,
            failedDocumentCount: documentIDs.count,
            removedStoredFileCount: 0,
            failedStoredFileCount: 0
          )
        }
        return await self.emptyRecycleBinMutation(documentIDs: documentIDs)
      }
    } catch {
      return KnowledgeRecycleBinCleanupSummary(
        requestedDocumentCount: documentIDs.count,
        removedDocumentCount: 0,
        failedDocumentCount: documentIDs.count,
        removedStoredFileCount: 0,
        failedStoredFileCount: 0
      )
    }
  }

  private func emptyRecycleBinMutation(
    documentIDs: [UUID]
  ) async -> KnowledgeRecycleBinCleanupSummary {
    let result: KnowledgeRecycleBinDeletionResult
    do {
      result = try await service.deleteDocumentsAsync(ids: documentIDs)
    } catch is CancellationError {
      return KnowledgeRecycleBinCleanupSummary(
        requestedDocumentCount: documentIDs.count,
        removedDocumentCount: 0,
        failedDocumentCount: 0,
        removedStoredFileCount: 0,
        failedStoredFileCount: 0
      )
    } catch {
      lastError = error.localizedDescription
      statusMessage = "清空回收站失败：\(error.localizedDescription)"
      return KnowledgeRecycleBinCleanupSummary(
        requestedDocumentCount: documentIDs.count,
        removedDocumentCount: 0,
        failedDocumentCount: documentIDs.count,
        removedStoredFileCount: 0,
        failedStoredFileCount: 0
      )
    }

    let removedIDSet = Set(result.removedIDs)
    documents.removeAll { removedIDSet.contains($0.id) }
    recycledDocuments.removeAll { removedIDSet.contains($0.id) }
    searchResults.removeAll { removedIDSet.contains($0.document.id) }
    pinnedDocumentIDs.subtract(removedIDSet)
    ensureVisibleSelection()

    let summary = KnowledgeRecycleBinCleanupSummary(
      requestedDocumentCount: documentIDs.count,
      removedDocumentCount: removedIDSet.count,
      failedDocumentCount: result.failedDocumentCount,
      removedStoredFileCount: result.removedStoredFileCount,
      failedStoredFileCount: result.failedStoredFileCount
    )
    if result.wasCancelled {
      statusMessage = CoreL10n.format(
        "回收站清理已取消：已永久删除 %d 条资料，剩余项目保持不变。",
        summary.removedDocumentCount
      )
      lastError = nil
    } else if summary.failedDocumentCount == 0, summary.failedStoredFileCount == 0 {
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
  public func saveAnnotation(_ annotation: KnowledgeAnnotation) async -> Bool {
    var succeeded = false
    await enqueueKnowledgeIO { [weak self] in
      guard let self else { return }
      succeeded = await self.saveAnnotationAsync(annotation)
    }
    return succeeded
  }

  private func saveAnnotationAsync(_ annotation: KnowledgeAnnotation) async -> Bool {
    do {
      let saved = try await service.saveAnnotationAsync(annotation)
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

  public func deleteAnnotation(_ annotationID: UUID) async {
    await enqueueKnowledgeIO { [weak self] in
      await self?.deleteAnnotationAsync(annotationID)
    }
  }

  private func deleteAnnotationAsync(_ annotationID: UUID) async {
    do {
      try await service.deleteAnnotationAsync(id: annotationID)
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
  ) async {
    await enqueueKnowledgeIO { [weak self] in
      await self?.recordBacklinksAsync(citations: citations, target: target)
    }
  }

  private func recordBacklinksAsync(
    citations: [KnowledgeCitation],
    target: KnowledgeBacklinkTarget
  ) async {
    do {
      try await service.recordBacklinksAsync(citations: citations, target: target)
      if let selectedDocumentID, citations.contains(where: { $0.documentID == selectedDocumentID })
      {
        backlinks = try await service.backlinksAsync(documentID: selectedDocumentID)
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
    try await service.revisionDifferenceAsync(documentID: documentID, revisionID: revisionID)
  }

  @discardableResult
  public func applySourceRefresh(_ preview: KnowledgeSourceRefreshPreview) async -> Bool {
    let busyOperationID = beginBusyOperation()
    defer { finishBusyOperation(busyOperationID) }
    do {
      let result = try await performQueuedKnowledgeMutation { [service] in
        try await service.applySourceRefresh(preview)
      }
      await waitAfterAcceptedMutationBeforeProjection()
      await reloadAfterAcceptedMutation(selecting: preview.documentID)
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
  public func restoreRevision(_ revisionID: UUID, documentID: UUID) async -> Bool {
    var succeeded = false
    await enqueueKnowledgeIO { [weak self] in
      guard let self else { return }
      succeeded = await self.restoreRevisionAsync(revisionID, documentID: documentID)
    }
    return succeeded
  }

  private func restoreRevisionAsync(_ revisionID: UUID, documentID: UUID) async -> Bool {
    do {
      let restored = try await service.restoreRevisionAsync(
        documentID: documentID,
        revisionID: revisionID
      )
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

  public func setPinned(_ pinned: Bool, documentID: UUID) async {
    await enqueueKnowledgeIO { [weak self] in
      await self?.setPinnedAsync(pinned, documentID: documentID)
    }
  }

  private func setPinnedAsync(_ pinned: Bool, documentID: UUID) async {
    do {
      try await service.setPinnedAsync(pinned, documentID: documentID)
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
