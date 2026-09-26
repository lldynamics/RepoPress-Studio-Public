import CryptoKit
import Foundation

public struct ExternalDraftFolderScanSummary: Sendable {
  public var addedCount = 0
  public var refreshedCount = 0
  public var conflictCount = 0
  public var missingCount = 0
  public var errorMessage: String?

  public init() {}
}

extension WorkbenchStore {
  @discardableResult
  public func connectExternalDraftFolder(_ url: URL) -> Bool {
    let directory = url.standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue,
      FileManager.default.isReadableFile(atPath: directory.path),
      (try? FileManager.default.attributesOfItem(atPath: directory.path)[.type]
        as? FileAttributeType) == .typeDirectory
    else { return false }

    if activeProfile.externalDraftFolder?.path == directory.path { return true }

    guard disconnectExternalDraftFolder() else { return false }
    var profile = activeProfile
    profile.externalDraftFolder = ExternalDraftFolderMapping(path: directory.path)
    updateActiveProfile(profile)
    scheduleAutosave()
    return true
  }

  /// Stops syncing while retaining the imported general drafts as local data.
  @discardableResult
  public func disconnectExternalDraftFolder() -> Bool {
    guard let mapping = activeProfile.externalDraftFolder else { return true }
    guard
      !drafts.contains(where: {
        $0.externalDraftSource?.mappingID == mapping.id
          && externalDraftWritesInProgress.contains($0.id)
      })
    else { return false }
    for index in publishingStore.drafts.indices
    where publishingStore.drafts[index].externalDraftSource?.mappingID == mapping.id {
      let draftID = publishingStore.drafts[index].id
      cancelExternalDraftWrite(for: draftID)
      publishingStore.drafts[index].externalDraftSource = nil
      externalDraftConflicts.remove(draftID)
    }
    var profile = activeProfile
    profile.externalDraftFolder = nil
    updateActiveProfile(profile)
    invalidateDraftDerivedCaches()
    scheduleAutosave()
    return true
  }

  /// Reads an external Markdown directory into linked general drafts. A file
  /// changed in both applications is left untouched on both sides.
  public func scanExternalDraftFolder() async -> ExternalDraftFolderScanSummary {
    var summary = ExternalDraftFolderScanSummary()
    guard !isSafeMode, canUseProtectedWorkbench,
      let mapping = activeProfile.externalDraftFolder
    else { return summary }
    let profileID = activeProfileID

    // File-system events from our own atomic replacement may arrive before
    // its new fingerprint is recorded. Read only after that write completes.
    await waitForPendingExternalDraftWrites()
    guard !Task.isCancelled, !isSafeMode, canUseProtectedWorkbench,
      activeProfileID == profileID,
      activeProfile.externalDraftFolder == mapping
    else { return summary }

    externalDraftFolderScanGeneration &+= 1
    let generation = externalDraftFolderScanGeneration
    let files: [ExternalDraftFile]
    do {
      files = try await Task.detached(priority: .utility) {
        try ExternalDraftFolderService().scan(rootURL: mapping.directoryURL)
      }.value
    } catch {
      summary.errorMessage = CoreL10n.format(
        "外部草稿文件夹无法扫描：%@",
        error.localizedDescription
      )
      return summary
    }
    guard !Task.isCancelled,
      externalDraftFolderScanGeneration == generation,
      activeProfileID == profileID,
      activeProfile.externalDraftFolder == mapping
    else { return summary }

    flushDraftBodyEditorBuffers()
    let filePaths = Set(files.map(\.relativePath))
    summary.missingCount =
      drafts.filter {
        $0.externalDraftSource?.mappingID == mapping.id
          && !filePaths.contains($0.externalDraftSource?.relativePath ?? "")
      }.count

    for file in files {
      let source = ExternalDraftSource(
        mappingID: mapping.id,
        relativePath: file.relativePath,
        importedTitle: file.title,
        importedFingerprint: file.fingerprint
      )
      if let existing = drafts.first(where: {
        guard let existingSource = $0.externalDraftSource else { return false }
        return existingSource.relativePath == file.relativePath
          && ((existingSource.mappingID == mapping.id && !existingSource.isDetached)
            || existingSource.isDetached(in: mapping))
      }) {
        guard let previousSource = existing.externalDraftSource else { continue }
        guard previousSource.importedFingerprint != file.fingerprint || previousSource.isDetached
        else {
          externalDraftConflicts.remove(existing.id)
          continue
        }
        let localFingerprint = Self.externalDraftFingerprint(existing.bodyMarkdown)
        // The file did not change while its Profile was absent. Reattach the
        // local edit to the newly selected mapping and retain the original
        // baseline, so the normal CAS writeback can safely continue.
        if previousSource.isDetached,
          file.fingerprint == previousSource.importedFingerprint
        {
          var rebound = existing
          var reboundSource = previousSource
          reboundSource.reconnect(to: mapping)
          rebound.externalDraftSource = reboundSource
          updateDraft(rebound)
          externalDraftConflicts.remove(existing.id)
          continue
        }
        guard
          localFingerprint == previousSource.importedFingerprint
            || localFingerprint == file.fingerprint
        else {
          externalDraftConflicts.insert(existing.id)
          if previousSource.isDetached {
            var rebound = existing
            var reboundSource = previousSource
            reboundSource.reconnect(to: mapping)
            rebound.externalDraftSource = reboundSource
            updateDraft(rebound)
          }
          summary.conflictCount += 1
          continue
        }
        var refreshed = existing
        if localFingerprint == previousSource.importedFingerprint {
          refreshed.bodyMarkdown = file.markdown
        }
        if refreshed.title == previousSource.importedTitle {
          refreshed.title = file.title
        }
        refreshed.externalDraftSource = source
        updateDraft(refreshed)
        synchronizeDraftBodyEditorBuffer(with: refreshed)
        externalDraftWriteFailures.removeValue(forKey: refreshed.id)
        externalDraftConflicts.remove(refreshed.id)
        summary.refreshedCount += 1
      } else {
        let draft = ArticleDraft(
          siteProfileID: profileID,
          scope: .general,
          title: file.title,
          bodyMarkdown: file.markdown,
          externalDraftSource: source
        )
        publishingStore.drafts.insert(draft, at: 0)
        scheduleDraftWordCountRefresh(for: draft.id, bodyMarkdown: draft.bodyMarkdown)
        summary.addedCount += 1
      }
    }
    if summary.addedCount > 0 {
      invalidateDraftDerivedCaches()
      scheduleAutosave()
    }
    if summary.conflictCount > 0 {
      setPublishActionMessage(
        CoreL10n.format(
          "有 %d 篇外部草稿在两处都已修改；已保留两边内容，请先处理冲突。",
          summary.conflictCount
        ),
        status: .warning
      )
    }
    for draft in drafts where draft.externalDraftSource?.mappingID == mapping.id {
      scheduleExternalDraftWrite(for: draft)
    }
    return summary
  }

  func scheduleExternalDraftWrite(for draft: ArticleDraft, immediate: Bool = false) {
    guard !isSafeMode, canUseProtectedWorkbench,
      let source = draft.externalDraftSource,
      externalDraftMapping(for: source) != nil,
      Self.externalDraftFingerprint(draft.bodyMarkdown) != source.importedFingerprint,
      !externalDraftConflicts.contains(draft.id),
      externalDraftWriteFailures[draft.id] == nil
    else { return }

    let generation = (externalDraftWriteGenerations[draft.id] ?? 0) &+ 1
    externalDraftWriteGenerations[draft.id] = generation
    if isPreparingSafeTermination { return }
    guard !externalDraftWritesInProgress.contains(draft.id) else { return }
    externalDraftWriteTasks[draft.id]?.cancel()
    externalDraftWriteTasks[draft.id] = Task { [weak self] in
      guard let self else { return }
      if !immediate {
        do { try await Task.sleep(for: .milliseconds(350)) } catch {
          if self.externalDraftWriteGenerations[draft.id] == generation {
            self.externalDraftWriteTasks[draft.id] = nil
          }
          return
        }
      }
      guard !Task.isCancelled,
        self.externalDraftWriteGenerations[draft.id] == generation
      else {
        if self.externalDraftWriteGenerations[draft.id] == generation {
          self.externalDraftWriteTasks[draft.id] = nil
        }
        return
      }
      await self.writeExternalDraft(draftID: draft.id)
    }
  }

  public func retryExternalDraftWrites() {
    externalDraftWriteFailures.removeAll()
    for draft in drafts where draft.externalDraftSource != nil {
      scheduleExternalDraftWrite(for: draft, immediate: true)
    }
  }

  /// Resolve a two-sided edit without losing either body. The current local
  /// text becomes an unlinked general draft; the linked draft takes the latest
  /// source bytes and baseline.
  @discardableResult
  public func keepLocalCopyAndAcceptExternal(draftID: UUID) async -> Bool {
    guard externalDraftConflicts.contains(draftID),
      !externalDraftWritesInProgress.contains(draftID),
      let original = drafts.first(where: { $0.id == draftID }),
      let source = original.externalDraftSource,
      let mapping = externalDraftMapping(for: source)
    else { return false }

    let files: [ExternalDraftFile]
    do {
      files = try await Task.detached(priority: .utility) {
        try ExternalDraftFolderService().scan(rootURL: mapping.directoryURL)
      }.value
    } catch { return false }
    guard !Task.isCancelled,
      let file = files.first(where: { $0.relativePath == source.relativePath }),
      file.fingerprint != source.importedFingerprint,
      let current = drafts.first(where: { $0.id == draftID }),
      current.externalDraftSource == source,
      current.bodyMarkdown == original.bodyMarkdown,
      externalDraftMapping(for: source) == mapping,
      !externalDraftWritesInProgress.contains(draftID)
    else { return false }

    flushDraftBodyEditorBuffer(for: draftID)
    guard let resolvedCurrent = drafts.first(where: { $0.id == draftID }),
      resolvedCurrent.bodyMarkdown == original.bodyMarkdown,
      resolvedCurrent.externalDraftSource == source
    else { return false }

    cancelExternalDraftWrite(for: draftID)
    var localCopy = resolvedCurrent
    localCopy.id = UUID()
    localCopy.title += CoreL10n.text("（本地冲突副本）")
    localCopy.externalDraftSource = nil
    publishingStore.drafts.insert(localCopy, at: 0)

    var refreshed = resolvedCurrent
    refreshed.bodyMarkdown = file.markdown
    if refreshed.title == source.importedTitle { refreshed.title = file.title }
    refreshed.externalDraftSource = ExternalDraftSource(
      mappingID: source.mappingID,
      relativePath: source.relativePath,
      importedTitle: file.title,
      importedFingerprint: file.fingerprint
    )
    updateDraft(refreshed)
    synchronizeDraftBodyEditorBuffer(with: refreshed)
    externalDraftConflicts.remove(draftID)
    invalidateDraftDerivedCaches()
    scheduleAutosave()
    return true
  }

  public var pendingExternalDraftWriteCount: Int {
    drafts.filter { draft in
      guard let source = draft.externalDraftSource,
        externalDraftMapping(for: source) != nil
      else { return false }
      return Self.externalDraftFingerprint(draft.bodyMarkdown)
        != source.importedFingerprint
    }.count
  }

  func suspendScheduledExternalDraftWrites() {
    for draftID in Array(externalDraftWriteTasks.keys)
    where !externalDraftWritesInProgress.contains(draftID) {
      externalDraftWriteTasks[draftID]?.cancel()
      externalDraftWriteTasks[draftID] = nil
      externalDraftWriteGenerations[draftID, default: 0] &+= 1
    }
  }

  func waitForPendingExternalDraftWrites() async {
    while !Task.isCancelled,
      !externalDraftWriteTasks.isEmpty || !externalDraftWritesInProgress.isEmpty
    {
      await Task.yield()
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func cancelExternalDraftWrite(for draftID: UUID) {
    externalDraftWriteGenerations[draftID, default: 0] &+= 1
    externalDraftWriteTasks[draftID]?.cancel()
    externalDraftWriteTasks[draftID] = nil
    externalDraftWriteFailures.removeValue(forKey: draftID)
    externalDraftConflicts.remove(draftID)
  }

  /// Profile deletion must not silently convert a live writeback into a
  /// dangling mapping. Pending tasks are cancelled; an already-running writer
  /// keeps ownership until it finishes, so the caller can ask the user to
  /// retry rather than racing the file replacement.
  @discardableResult
  func detachExternalDraftSources(for mapping: ExternalDraftFolderMapping) -> Bool {
    let sourceUsesMapping: (ExternalDraftSource?) -> Bool = { source in
      guard let source else { return false }
      return source.mappingID == mapping.id && !source.isDetached
    }
    let linkedDraftIDs = Set(
      publishingStore.drafts.filter { sourceUsesMapping($0.externalDraftSource) }.map(\.id)
        + publishingStore.recycledDrafts.filter { sourceUsesMapping($0.draft.externalDraftSource) }
        .map { $0.draft.id }
    )
    guard linkedDraftIDs.isDisjoint(with: externalDraftWritesInProgress) else { return false }

    for index in publishingStore.drafts.indices
    where sourceUsesMapping(publishingStore.drafts[index].externalDraftSource) {
      let draftID = publishingStore.drafts[index].id
      cancelExternalDraftWrite(for: draftID)
      publishingStore.drafts[index].externalDraftSource?.detach(from: mapping)
    }
    for index in publishingStore.recycledDrafts.indices
    where sourceUsesMapping(publishingStore.recycledDrafts[index].draft.externalDraftSource) {
      let draftID = publishingStore.recycledDrafts[index].draft.id
      cancelExternalDraftWrite(for: draftID)
      publishingStore.recycledDrafts[index].draft.externalDraftSource?.detach(from: mapping)
    }
    for index in publishingStore.draftVersions.indices
    where sourceUsesMapping(publishingStore.draftVersions[index].draft.externalDraftSource) {
      publishingStore.draftVersions[index].draft.externalDraftSource?.detach(from: mapping)
    }
    return true
  }

  /// Undoing a Profile deletion restores its original mapping ID. Only sources
  /// detached from that exact mapping are reattached; another Profile's folder
  /// selection is never inferred or modified.
  func reconnectDetachedExternalDraftSources(to mapping: ExternalDraftFolderMapping) {
    let sourceWasDetachedFromMapping: (ExternalDraftSource?) -> Bool = { source in
      source?.isDetached(from: mapping) == true
    }
    for index in publishingStore.drafts.indices
    where sourceWasDetachedFromMapping(publishingStore.drafts[index].externalDraftSource) {
      publishingStore.drafts[index].externalDraftSource?.reconnect(to: mapping)
    }
    for index in publishingStore.recycledDrafts.indices
    where sourceWasDetachedFromMapping(
      publishingStore.recycledDrafts[index].draft.externalDraftSource)
    {
      publishingStore.recycledDrafts[index].draft.externalDraftSource?.reconnect(to: mapping)
    }
    for index in publishingStore.draftVersions.indices
    where sourceWasDetachedFromMapping(
      publishingStore.draftVersions[index].draft.externalDraftSource)
    {
      publishingStore.draftVersions[index].draft.externalDraftSource?.reconnect(to: mapping)
    }
  }

  /// Safe termination waits for pending writeback instead of claiming the
  /// external source is saved when a conflict or unavailable folder remains.
  func flushPendingExternalDraftWrites(retryKnownFailures: Bool = true) -> Bool {
    for task in externalDraftWriteTasks.values { task.cancel() }
    externalDraftWriteTasks.removeAll()
    guard externalDraftWritesInProgress.isEmpty else { return false }
    var succeeded = true
    for draft in drafts where draft.externalDraftSource != nil {
      guard let source = draft.externalDraftSource,
        Self.externalDraftFingerprint(draft.bodyMarkdown) != source.importedFingerprint
      else { continue }
      guard !externalDraftConflicts.contains(draft.id) else {
        succeeded = false
        continue
      }
      guard let mapping = externalDraftMapping(for: source) else {
        continue
      }
      if !retryKnownFailures, externalDraftWriteFailures[draft.id] != nil {
        succeeded = false
        continue
      }
      do {
        let fingerprint = try ExternalDraftFileWriter().write(
          rootURL: mapping.directoryURL,
          relativePath: source.relativePath,
          expectedFingerprint: source.importedFingerprint,
          markdown: draft.bodyMarkdown
        )
        acceptExternalDraftWrite(draftID: draft.id, source: source, fingerprint: fingerprint)
      } catch {
        externalDraftWriteFailures[draft.id] = error.localizedDescription
        if let writerError = error as? ExternalDraftFileWriterError,
          case .conflict = writerError
        {
          externalDraftConflicts.insert(draft.id)
        }
        succeeded = false
      }
    }
    return succeeded
  }

  private func writeExternalDraft(draftID: UUID) async {
    guard !externalDraftWritesInProgress.contains(draftID),
      let draft = drafts.first(where: { $0.id == draftID }),
      let source = draft.externalDraftSource,
      let mapping = externalDraftMapping(for: source),
      Self.externalDraftFingerprint(draft.bodyMarkdown) != source.importedFingerprint
    else {
      externalDraftWriteTasks[draftID] = nil
      return
    }
    externalDraftWritesInProgress.insert(draftID)
    let fingerprint: String
    do {
      let markdown = draft.bodyMarkdown
      fingerprint = try await Task.detached(priority: .utility) {
        try ExternalDraftFileWriter().write(
          rootURL: mapping.directoryURL,
          relativePath: source.relativePath,
          expectedFingerprint: source.importedFingerprint,
          markdown: markdown
        )
      }.value
    } catch {
      externalDraftWritesInProgress.remove(draftID)
      externalDraftWriteTasks[draftID] = nil
      if drafts.contains(where: { $0.id == draftID }) {
        externalDraftWriteFailures[draftID] = error.localizedDescription
        if let writerError = error as? ExternalDraftFileWriterError,
          case .conflict = writerError
        {
          externalDraftConflicts.insert(draftID)
        }
        setPublishActionMessage(
          CoreL10n.format("外部草稿写回失败：%@", error.localizedDescription),
          status: .warning
        )
      }
      return
    }
    externalDraftWritesInProgress.remove(draftID)
    externalDraftWriteTasks[draftID] = nil
    acceptExternalDraftWrite(draftID: draftID, source: source, fingerprint: fingerprint)
    if let latest = drafts.first(where: { $0.id == draftID }) {
      scheduleExternalDraftWrite(for: latest)
    }
  }

  private func acceptExternalDraftWrite(
    draftID: UUID,
    source: ExternalDraftSource,
    fingerprint: String
  ) {
    guard let index = publishingStore.drafts.firstIndex(where: { $0.id == draftID }),
      var currentSource = publishingStore.drafts[index].externalDraftSource,
      currentSource.mappingID == source.mappingID,
      !currentSource.isDetached,
      currentSource.relativePath == source.relativePath,
      currentSource.importedFingerprint == source.importedFingerprint
    else { return }
    currentSource.importedFingerprint = fingerprint
    publishingStore.drafts[index].externalDraftSource = currentSource
    externalDraftWriteFailures.removeValue(forKey: draftID)
    externalDraftConflicts.remove(draftID)
    scheduleAutosave()
  }

  private func externalDraftMapping(for source: ExternalDraftSource)
    -> ExternalDraftFolderMapping?
  {
    guard !source.isDetached else { return nil }
    return profiles.compactMap(\.externalDraftFolder).first { $0.id == source.mappingID }
  }

  private static func externalDraftFingerprint(_ markdown: String) -> String {
    SHA256.hash(data: Data(markdown.utf8))
      .map { String(format: "%02x", $0) }.joined()
  }
}
