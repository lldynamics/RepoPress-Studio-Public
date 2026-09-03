import Foundation

extension WorkbenchStore {
  public func previewStructuralDraftRepair() async throws -> StructuralDraftRepairPreview {
    let profile = activeProfile
    let capturedDrafts = drafts
    let buffers = Dictionary(
      uniqueKeysWithValues: capturedDrafts.map {
        ($0.id, draftBodyEditorBuffer(for: $0.id))
      })
    var preview = await Task.detached(priority: .userInitiated) {
      StructuralDraftRepairService().preview(profile: profile, drafts: capturedDrafts)
    }.value
    try Task.checkCancellation()
    preview.bodyBuffers = buffers
    try validateStructuralRepairPreview(preview)
    return preview
  }

  public func applyStructuralDraftRepair(
    preview: StructuralDraftRepairPreview,
    selectedDraftIDs: Set<UUID>,
    selectedPaths: Set<String>
  ) async throws -> StructuralDraftRepairResult {
    try Task.checkCancellation()
    try validateStructuralRepairPreview(preview)
    guard !selectedDraftIDs.isEmpty || !selectedPaths.isEmpty,
      selectedDraftIDs.isSubset(of: Set(preview.drafts.map(\.id))),
      selectedPaths.isSubset(of: Set(preview.files.map(\.repositoryPath)))
    else {
      throw StructuralDraftRepairError.invalidSelection
    }
    guard !persistenceStore.isRecoveryWriteProtected else {
      throw StructuralDraftRepairError.unavailable("工作台处于恢复保护状态，未执行修复。")
    }
    guard !isRemoteRepositoryPublishing, !isLocalRepositoryBranchOperationRunning,
      let operation = publishingStore.beginLocalRepositoryMutation(profile: activeProfile)
    else {
      throw StructuralDraftRepairError.unavailable("有发布或仓库操作正在运行，请等待完成再修复。")
    }
    defer { publishingStore.finishLocalRepositoryMutation(operation) }

    // Capture effective editor bodies without flushing site-file autosaves.
    var before = persistenceStore.persistence.snapshot(from: self)
    before.drafts = before.drafts.map { draft in
      var copy = draft
      let buffer = draftBodyEditorBuffer(for: draft.id)
      if buffer.isDirty { copy.bodyMarkdown = buffer.bodyMarkdown }
      return copy
    }
    let backupSnapshot = before
    let parent = persistenceStore.persistence.recoveryArchiveDirectoryURL
    let service = StructuralDraftRepairService()
    let backupURL = try await Task.detached(priority: .userInitiated) {
      try service.createBackup(
        snapshot: backupSnapshot, preview: preview,
        selectedDraftIDs: selectedDraftIDs, paths: selectedPaths, parentURL: parent)
    }.value
    try Task.checkCancellation()
    // The user may edit or switch sites during backup I/O. A valid backup is
    // harmless; applying a no-longer-current confirmation is not.
    try validateStructuralRepairPreview(preview)
    guard !persistenceStore.isRecoveryWriteProtected else {
      throw StructuralDraftRepairError.unavailable("备份后工作台进入恢复保护状态，未执行修复。")
    }
    try service.validateFiles(preview, paths: selectedPaths)
    let repairedDrafts = drafts.map { original in
      guard selectedDraftIDs.contains(original.id) else { return original }
      var repaired = original
      repaired.bodyMarkdown = draftBodyEditorBuffer(for: original.id).bodyMarkdown
      repaired.assignToGeneralDraft()
      repaired.markUpdated(replacing: original)
      return repaired
    }
    var after = persistenceStore.persistence.snapshot(from: self)
    after.drafts = repairedDrafts.map { draft in
      var copy = draft
      let buffer = draftBodyEditorBuffer(for: draft.id)
      if buffer.isDirty { copy.bodyMarkdown = buffer.bodyMarkdown }
      return copy
    }
    // Commit the exact candidate before publishing it to observers. Unlike
    // flushPendingChanges(), this does not write any repository files.
    persistenceStore.markUnsavedChanges()
    guard persistenceStore.flush(snapshot: after), !persistenceStore.isRecoveryWriteProtected else {
      throw StructuralDraftRepairError.unavailable(
        "工作台保存失败，记录和仓库文件均未修复。备份已保留：\(backupURL.path)")
    }
    for id in selectedDraftIDs {
      cancelSiteDraftFileAutosave(for: id)
      draftBodyCommitTasks[id]?.cancel()
      draftBodyCommitTasks[id] = nil
    }
    publishingStore.drafts = repairedDrafts
    for draft in repairedDrafts where selectedDraftIDs.contains(draft.id) {
      let buffer = draftBodyEditorBuffer(for: draft.id)
      publishingStore.setDraftBodyEditorBuffer(
        .init(
          draftID: draft.id, bodyMarkdown: draft.bodyMarkdown,
          revision: buffer.revision &+ 1, isDirty: false),
        for: draft.id, notifyObservers: true)
    }
    invalidateDraftDerivedCaches()

    var restoredPaths: [String] = []
    var fileError: String?
    do {
      restoredPaths = try await Task.detached(priority: .userInitiated) {
        try service.restoreFiles(preview, paths: selectedPaths)
      }.value
    } catch StructuralDraftRepairError.stalePreview {
      fileError = "工作台记录已修复，但栏目文件或 Git 基线随后发生变化，未覆盖这些文件。请重新扫描栏目恢复预览。"
    } catch {
      fileError = "工作台记录已修复；栏目文件恢复失败：\(error.localizedDescription)"
    }
    if !restoredPaths.isEmpty { requestRepositoryScan() }
    setLastSaveStatus(
      fileError == nil
        ? "异常记录修复完成；备份已保留，未提交或推送。"
        : "记录修复已保存，但栏目文件恢复未完成；请查看结果并重新扫描。")
    return .init(
      backupURL: backupURL, repairedDraftCount: selectedDraftIDs.count,
      restoredPaths: restoredPaths, fileRecoveryError: fileError)
  }

  private func validateStructuralRepairPreview(_ preview: StructuralDraftRepairPreview) throws {
    guard activeProfile == preview.profileSnapshot, drafts == preview.draftSnapshots else {
      throw StructuralDraftRepairError.stalePreview
    }
    for (id, buffer) in preview.bodyBuffers {
      guard draftBodyEditorBuffer(for: id) == buffer else {
        throw StructuralDraftRepairError.stalePreview
      }
    }
  }
}
