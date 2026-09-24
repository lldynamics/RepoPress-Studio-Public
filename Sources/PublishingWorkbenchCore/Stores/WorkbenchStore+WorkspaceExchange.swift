import Foundation

@MainActor
extension WorkbenchStore {
  public func makeWorkspaceExchangeData() async throws -> Data {
    guard canUseProtectedWorkbench, !isPersistenceRecoveryWriteProtected else {
      throw WorkspaceExchangeError.unavailable
    }
    guard flushPendingChanges() else { throw WorkspaceExchangeError.unavailable }
    flushDraftBodyEditorBuffers()
    let sourceProfiles = profiles
    let sourceDrafts = drafts
    let attachmentRoot = managedAttachmentFileStore.rootDirectoryURL
    return try await Task.detached(priority: .utility) {
      try WorkspaceExchangeTransferService.makeData(
        profiles: sourceProfiles,
        drafts: sourceDrafts,
        attachmentRootURL: attachmentRoot
      )
    }.value
  }

  public func previewWorkspaceExchange(data: Data) async throws -> WorkspaceExchangePreview {
    guard canUseProtectedWorkbench, !isPersistenceRecoveryWriteProtected else {
      throw WorkspaceExchangeError.unavailable
    }
    let localProfiles = profiles
    return try await Task.detached(priority: .utility) {
      try WorkspaceExchangeCodec.preview(
        data,
        existingProfiles: localProfiles
      )
    }.value
  }

  @discardableResult
  public func importWorkspaceExchange(
    _ preview: WorkspaceExchangePreview,
    profileMappings: [UUID: WorkspaceExchangeProfileMapping],
    slugOverrides: [UUID: String] = [:]
  ) async throws -> Int {
    guard canUseProtectedWorkbench, !isPersistenceRecoveryWriteProtected else {
      throw WorkspaceExchangeError.unavailable
    }
    let verifiedPackage = try WorkspaceExchangeCodec.decode(preview.sourceData)
    guard verifiedPackage.manifest == preview.package.manifest else {
      throw WorkspaceExchangeError.invalidPayloadHash
    }
    let sourceProfileIDs = Set(verifiedPackage.payload.profiles.map(\.id))
    let requiredProfileIDs = Set(verifiedPackage.payload.drafts.compactMap { draft in
      draft.scope == "site" ? draft.sourceProfileID : nil
    })
    guard sourceProfileIDs.allSatisfy({ profileMappings[$0] != nil }),
      requiredProfileIDs.allSatisfy({ profileMappings[$0] != nil })
    else {
      throw WorkspaceExchangeError.invalidReference("站点草稿必须映射到现有或新站点配置")
    }
    let currentProfileIDs = Set(profiles.map(\.id))
    for (sourceID, mapping) in profileMappings {
      switch mapping {
      case .existing(let destinationID):
        guard currentProfileIDs.contains(destinationID) else {
          throw WorkspaceExchangeError.invalidReference("目标站点配置已不存在")
        }
      case .importAsNewProfile:
        guard sourceProfileIDs.contains(sourceID) else {
          throw WorkspaceExchangeError.invalidReference("包外的来源配置不能被重建")
        }
      }
    }
    guard profileMappings.keys.allSatisfy({
      sourceProfileIDs.contains($0) || requiredProfileIDs.contains($0)
    }) else {
      throw WorkspaceExchangeError.invalidReference("存在无关的站点配置映射")
    }

    let initialConflicts = try WorkspaceExchangePathConflictService.conflicts(
      package: verifiedPackage,
      profileMappings: profileMappings,
      slugOverrides: slugOverrides,
      existingProfiles: profiles,
      existingDrafts: drafts
    )
    if let conflict = initialConflicts.first {
      throw WorkspaceExchangeError.duplicatePublishPath(conflict.path)
    }

    let activeProfile = activeProfileID
    let attachmentStore = ManagedAttachmentFileStore(
      rootDirectoryURL: managedAttachmentFileStore.rootDirectoryURL,
      sanitizesSensitiveImageMetadata: false
    )
    let prepared = try await Task.detached(priority: .utility) {
      try WorkspaceExchangeTransferService.prepareImport(
        package: verifiedPackage,
        profileMappings: profileMappings,
        slugOverrides: slugOverrides,
        activeProfileID: activeProfile,
        attachmentStore: attachmentStore
      )
    }.value
    defer { try? FileManager.default.removeItem(at: prepared.stagingURL) }
    do {
      try Task.checkCancellation()
      let currentConflicts = try WorkspaceExchangePathConflictService.conflicts(
        package: verifiedPackage,
        profileMappings: profileMappings,
        slugOverrides: slugOverrides,
        existingProfiles: profiles,
        existingDrafts: drafts
      )
      if let conflict = currentConflicts.first {
        throw WorkspaceExchangeError.duplicatePublishPath(conflict.path)
      }
      guard canUseProtectedWorkbench, !isPersistenceRecoveryWriteProtected,
        prepared.drafts.allSatisfy({ incoming in
          !drafts.contains(where: { $0.id == incoming.id })
        }),
        prepared.profiles.allSatisfy({ incoming in
          !profiles.contains(where: { $0.id == incoming.id })
        })
      else { throw WorkspaceExchangeError.unavailable }

      // Editor buffers are committed before taking the rollback baseline, so
      // a failed import never erases text typed while the preview was open.
      flushDraftBodyEditorBuffers()
      let previousDrafts = publishingStore.drafts
      let previousProfiles = publishingStore.profiles
      publishingStore.profiles.append(contentsOf: prepared.profiles)
      publishingStore.drafts.append(contentsOf: prepared.drafts)
      invalidateDraftDerivedCaches()
      persistenceStore.markUnsavedChanges()
      let persisted = persistenceStore.flush(
        input: persistenceStore.persistence.snapshotInput(from: self)
      )
      guard persisted, !persistenceStore.isRecoveryWriteProtected else {
        publishingStore.drafts = previousDrafts
        publishingStore.profiles = previousProfiles
        invalidateDraftDerivedCaches()
        persistenceStore.markUnsavedChanges()
        // A save may have reached disk before reporting an error. Preserve
        // promoted attachment files and protect follow-up writes on uncertainty.
        persistenceStore.protectWritesForUnrecoverableSnapshot(
          message: persistenceStore.lastSaveError ?? persistenceStore.status
        )
        throw WorkspaceExchangeError.persistenceFailed
      }
      return prepared.drafts.count
    } catch {
      if !(error is WorkspaceExchangeError && error as? WorkspaceExchangeError == .persistenceFailed) {
        for url in prepared.promotedAttachmentURLs {
          try? attachmentStore.discardStoredFile(at: url)
        }
      }
      throw error
    }
  }
}
