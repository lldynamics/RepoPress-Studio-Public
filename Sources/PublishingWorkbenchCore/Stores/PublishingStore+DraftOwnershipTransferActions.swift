import Foundation

extension PublishingStore {
  public var canUndoLatestDraftOwnershipTransfer: Bool {
    latestDraftOwnershipTransferUndoState != nil
  }

  public func draftOwnershipTransferPlan(
    draftIDs: [UUID],
    operation: DraftOwnershipTransferOperation,
    targetProfileID: UUID?
  ) -> DraftOwnershipTransferPlan {
    DraftOwnershipTransferService().plan(
      draftIDs: draftIDs,
      operation: operation,
      targetProfileID: targetProfileID,
      drafts: drafts,
      profiles: profiles
    )
  }

  @discardableResult
  public func applyDraftOwnershipTransfer(
    _ plan: DraftOwnershipTransferPlan,
    store: WorkbenchStore
  ) -> DraftOwnershipTransferResult? {
    let refreshedPlan = draftOwnershipTransferPlan(
      draftIDs: plan.draftIDs,
      operation: plan.operation,
      targetProfileID: plan.targetProfileID
    )
    guard refreshedPlan.canApply else {
      publishActionMessage = CoreL10n.text("归属变更已停止：请先处理确认面板中的冲突。")
      return nil
    }

    let expectedUpdates = Dictionary(uniqueKeysWithValues: plan.items.map { ($0.draftID, $0.sourceUpdatedAt) })
    guard refreshedPlan.items.allSatisfy({ expectedUpdates[$0.draftID] == $0.sourceUpdatedAt }) else {
      publishActionMessage = CoreL10n.text("文章在确认期间发生了变化，请重新打开归属变更面板。")
      return nil
    }

    let previousActiveProfileID = activeProfileID
    let previousDraftListContentScope = draftListContentScope
    let previousSelectedDraftID = selectedDraftID
    let sourceIDs = Set(refreshedPlan.draftIDs)
    let originals = drafts.enumerated().compactMap { index, draft in
      sourceIDs.contains(draft.id)
        ? DraftOwnershipTransferUndoState.OriginalDraft(index: index, draft: draft)
        : nil
    }
    let targetProfile = refreshedPlan.targetProfileID.flatMap { id in
      profiles.first(where: { $0.id == id })
    }
    let now = Date()
    var createdDrafts: [ArticleDraft] = []
    var affectedDraftIDs: [UUID] = []

    for item in refreshedPlan.items {
      guard let sourceIndex = drafts.firstIndex(where: { $0.id == item.draftID }) else {
        publishActionMessage = CoreL10n.text("归属变更已停止：文章已不存在。")
        return nil
      }
      let source = drafts[sourceIndex]
      let sourceProfileName = source.isGeneralDraft
        ? CoreL10n.text("通用草稿")
        : profiles.first(where: { $0.id == source.siteProfileID })?.name
          ?? CoreL10n.text("原站点")

      if refreshedPlan.operation.isCopy {
        guard let targetProfile else { return nil }
        var copied = siteAssignedDraft(
          from: source,
          targetProfile: targetProfile,
          sourceProfileName: sourceProfileName,
          now: now
        )
        copied.id = UUID()
        copied.createdAt = now
        createdDrafts.append(copied)
        affectedDraftIDs.append(copied.id)
        continue
      }

      var moved = source
      moved.reusedFromSourceSnapshot = GeneralDraftReuseSourceSnapshot.make(
        from: source,
        sourceProfileName: sourceProfileName
      )
      switch refreshedPlan.operation {
      case .moveToSite:
        guard let targetProfile else { return nil }
        moved = siteAssignedDraft(
          from: moved,
          targetProfile: targetProfile,
          sourceProfileName: sourceProfileName,
          now: now
        )
      case .moveToGeneral:
        moved.assignToGeneralDraft(editingProfileID: source.siteProfileID)
        moved.updatedAt = now
      case .copyToSite:
        break
      }
      drafts[sourceIndex] = moved
      affectedDraftIDs.append(moved.id)
    }

    if !createdDrafts.isEmpty {
      drafts.insert(contentsOf: createdDrafts, at: 0)
    }

    switch refreshedPlan.operation {
    case .moveToGeneral:
      draftListContentScope = .general
    case .moveToSite, .copyToSite:
      if let targetProfile {
        activeProfileID = targetProfile.id
      }
      draftListContentScope = .currentSite
    }
    selectedDraftID = affectedDraftIDs.first
    selectedSection = .writing
    if let selectedDraftID {
      draftNavigationHistory.recordVisit(selectedDraftID)
    }

    let expectedDrafts = Dictionary(uniqueKeysWithValues: affectedDraftIDs.compactMap { id in
      drafts.first(where: { $0.id == id }).map { (id, $0) }
    })
    let undoState = DraftOwnershipTransferUndoState(
      id: UUID(),
      operation: refreshedPlan.operation,
      originals: refreshedPlan.operation.isCopy ? [] : originals,
      createdDraftIDs: createdDrafts.map(\.id),
      expectedDraftsAfterTransfer: expectedDrafts,
      previousActiveProfileID: previousActiveProfileID,
      previousDraftListContentScope: previousDraftListContentScope,
      previousSelectedDraftID: previousSelectedDraftID
    )
    latestDraftOwnershipTransferUndoState = undoState
    if refreshedPlan.operation == .copyToSite,
       let sourceID = refreshedPlan.items.first?.draftID,
       let source = drafts.first(where: { $0.id == sourceID }),
       let copiedID = affectedDraftIDs.first,
       let copied = drafts.first(where: { $0.id == copiedID }),
       let targetProfile {
      latestGeneralDraftReusePlan = generalDraftLibraryService.reusePlan(
        sourceDraft: source,
        copiedDraft: copied,
        sourceProfile: source.isGeneralDraft
          ? nil
          : profiles.first(where: { $0.id == source.siteProfileID }),
        targetProfile: targetProfile
      )
    } else {
      latestGeneralDraftReusePlan = nil
    }
    store.invalidateDraftDerivedCaches()
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: store.selectedDraft)
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
    publishActionMessage = successMessage(
      operation: refreshedPlan.operation,
      count: affectedDraftIDs.count,
      targetProfileName: targetProfile?.name
    )
    store.save()
    store.refreshSiteDraftFileAutosave(for: affectedDraftIDs)
    return DraftOwnershipTransferResult(
      operation: refreshedPlan.operation,
      affectedDraftIDs: affectedDraftIDs,
      undoID: undoState.id
    )
  }

  @discardableResult
  public func undoLatestDraftOwnershipTransfer(
    expectedUndoID: UUID? = nil,
    store: WorkbenchStore
  ) -> Bool {
    guard let undoState = latestDraftOwnershipTransferUndoState,
          expectedUndoID == nil || expectedUndoID == undoState.id else {
      publishActionMessage = CoreL10n.text("没有可撤销的草稿归属变更。")
      return false
    }

    let currentDraftsByID = Dictionary(uniqueKeysWithValues: drafts.map { ($0.id, $0) })
    guard undoState.expectedDraftsAfterTransfer.allSatisfy({ id, expected in
      currentDraftsByID[id] == expected
    }) else {
      latestDraftOwnershipTransferUndoState = nil
      publishActionMessage = CoreL10n.text("无法撤销：归属变更后有文章继续被编辑。")
      return false
    }

    let createdIDs = Set(undoState.createdDraftIDs)
    drafts.removeAll { createdIDs.contains($0.id) }
    for original in undoState.originals.sorted(by: { $0.index < $1.index }) {
      if let currentIndex = drafts.firstIndex(where: { $0.id == original.draft.id }) {
        drafts[currentIndex] = original.draft
      } else {
        drafts.insert(original.draft, at: min(original.index, drafts.count))
      }
    }

    if profiles.contains(where: { $0.id == undoState.previousActiveProfileID }) {
      activeProfileID = undoState.previousActiveProfileID
    }
    draftListContentScope = undoState.previousDraftListContentScope
    selectedDraftID = undoState.previousSelectedDraftID.flatMap { id in
      drafts.contains(where: { $0.id == id }) ? id : nil
    } ?? writingDrafts.first?.id
    latestDraftOwnershipTransferUndoState = nil
    store.invalidateDraftDerivedCaches()
    store.restoreSEOSocialPreviewSnapshotForCurrentSelection()
    store.runPreflight()
    store.scheduleImageWorkbenchReportRefresh(for: store.selectedDraft)
    store.refreshPublishPreviewInBackground(for: store.selectedDraft)
    publishActionMessage = CoreL10n.text("已撤销上一次草稿归属变更。")
    store.save()
    return true
  }

  private func siteAssignedDraft(
    from source: ArticleDraft,
    targetProfile: SiteProfile,
    sourceProfileName: String,
    now: Date
  ) -> ArticleDraft {
    var result = source
    result.assignToSite(targetProfile.id)
    result.status = .draft
    result.draft = true
    result.repositoryPath = nil
    result.repositorySHA = nil
    result.repositoryImportFingerprint = nil
    result.reusedFromSourceSnapshot = GeneralDraftReuseSourceSnapshot.make(
      from: source,
      sourceProfileName: sourceProfileName
    )
    result.updatedAt = now
    return result
  }

  private func successMessage(
    operation: DraftOwnershipTransferOperation,
    count: Int,
    targetProfileName: String?
  ) -> String {
    switch operation {
    case .moveToSite:
      return CoreL10n.format("已将 %d 篇文章移动到 %@，可撤销。", count, targetProfileName ?? "")
    case .copyToSite:
      return CoreL10n.format("已将 %d 篇文章复制到 %@，可撤销。", count, targetProfileName ?? "")
    case .moveToGeneral:
      return CoreL10n.format("已将 %d 篇文章转为通用草稿，可撤销。", count)
    }
  }
}
