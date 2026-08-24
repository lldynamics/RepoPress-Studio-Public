import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { draftPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          draftPendingDeletion = nil
        }
      }
    )
  }

  var unpublishConfirmationPresented: Binding<Bool> {
    Binding(
      get: { draftPendingUnpublish != nil },
      set: { isPresented in
        if !isPresented {
          draftPendingUnpublish = nil
        }
      }
    )
  }

  var skeletonPlaceholderCount: Int {
    8
  }

  var selectedDraftForDeletion: ArticleDraft? {
    guard let selectedDraftID = store.selectedDraftID else {
      return nil
    }
    return visibleDraftSnapshot.first { $0.id == selectedDraftID }
  }

  var writingDraftCommandActions: WritingDraftCommandActions {
    WritingDraftCommandActions(
      createDraft: {
        store.createDraft()
      },
      focusSearch: {
        isSearchFieldFocused = true
      },
      openVersionHistory: {
        store.flushDraftBodyEditorBuffers()
        openDataManagement(.drafts)
      },
      selectPreviousDraft: {
        selectDraft(byOffset: -1)
      },
      selectNextDraft: {
        selectDraft(byOffset: 1)
      }
    )
  }

  var draftListEmptyState: some View {
    VStack(spacing: 10) {
      Image(
        systemName: visibleDraftSnapshot.isEmpty ? "doc.badge.plus" : "doc.text.magnifyingglass"
      )
      .font(.system(size: 28))
      .foregroundStyle(.secondary)

      Text(draftListEmptyTitle)
        .font(.headline)

      Text(draftListEmptyMessage)
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if visibleDraftSnapshot.isEmpty {
        Button(emptyStateActionTitle) {
          if store.draftListContentScope == .general {
            store.createGeneralDraft()
          } else {
            store.createDraft()
          }
        }
        .workbenchProminentActionStyle()
      } else {
        Button("清除搜索与筛选") {
          searchText = ""
          filter = .all
        }
        .buttonStyle(.bordered)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 220)
    .listRowInsets(EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16))
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .accessibilityElement(children: .contain)
  }

  private var draftListEmptyTitle: LocalizedStringKey {
    guard visibleDraftSnapshot.isEmpty else { return "没有匹配的文章" }
    return store.draftListContentScope == .general ? "还没有通用草稿" : "还没有文章"
  }

  private var draftListEmptyMessage: LocalizedStringKey {
    guard visibleDraftSnapshot.isEmpty else {
      return "尝试清除搜索词或切换筛选条件。"
    }
    return store.draftListContentScope == .general
      ? "新建后可跨站点复用，复制到目标站点后再发布。"
      : "新建文章后即可开始写作。"
  }

  private var emptyStateActionTitle: LocalizedStringKey {
    store.draftListContentScope == .general ? "新建通用草稿" : "新建站点文章"
  }

  func requestDelete(_ draft: ArticleDraft) {
    draftPendingDeletion = draft
  }

  func requestUnpublish(_ draft: ArticleDraft) {
    draftPendingUnpublish = draft
  }

  func requestDeleteSelectedDraft() {
    guard let draft = selectedDraftForDeletion else {
      return
    }
    requestDelete(draft)
  }

  func updateDraftSelection(_ newSelection: Set<UUID>) {
    let previousSelection = selectedDraftIDs
    selectedDraftIDs = newSelection

    let newlySelectedID = newSelection.subtracting(previousSelection).first
    let primaryID =
      newlySelectedID
      ?? store.selectedDraftID.flatMap { newSelection.contains($0) ? $0 : nil }
      ?? newSelection.first
    if store.selectedDraftID != primaryID {
      store.selectDraft(primaryID)
    }
  }

  func synchronizeDraftSelectionFromStore() {
    guard let selectedDraftID = store.selectedDraftID else {
      selectedDraftIDs = []
      return
    }
    if !selectedDraftIDs.contains(selectedDraftID) {
      selectedDraftIDs = [selectedDraftID]
    }
  }

  func synchronizeDraftSelection(with drafts: [ArticleDraft]) {
    let availableIDs = Set(drafts.map(\.id))
    selectedDraftIDs.formIntersection(availableIDs)
    synchronizeDraftSelectionFromStore()
  }

  func transferDraftIDs(for draft: ArticleDraft) -> [UUID] {
    if selectedDraftIDs.count > 1 && selectedDraftIDs.contains(draft.id) {
      return Array(selectedDraftIDs)
    }
    return [draft.id]
  }

  func availableTransferProfiles(
    for referenceDraft: ArticleDraft?,
    includeCurrentSite: Bool
  ) -> [SiteProfile] {
    store.profiles.filter { profile in
      guard profile.purpose != .generalDraftBackup else { return false }
      guard !includeCurrentSite, let referenceDraft, !referenceDraft.isGeneralDraft else {
        return true
      }
      return !referenceDraft.belongs(toSiteProfileID: profile.id)
    }
  }

  func presentDraftOwnershipTransfer(
    draftIDs: [UUID],
    operation: DraftOwnershipTransferOperation,
    targetProfileID: UUID? = nil
  ) {
    guard !draftIDs.isEmpty else { return }
    draftOwnershipTransferPlan = store.draftOwnershipTransferPlan(
      draftIDs: draftIDs,
      operation: operation,
      targetProfileID: targetProfileID
    )
  }

  func openDataManagement(_ section: DataManagementSection) {
    dataManagementRequestedSection = section.rawValue
    requestedSettingsTabID = SettingsTab.dataManagement.id
    openSettings()
  }

  func applyDraftOwnershipTransfer(_ plan: DraftOwnershipTransferPlan) -> Bool {
    guard let result = store.applyDraftOwnershipTransfer(plan) else {
      return false
    }
    selectedDraftIDs = Set(result.affectedDraftIDs)
    registerDraftOwnershipUndo(result)
    return true
  }

  private func registerDraftOwnershipUndo(_ result: DraftOwnershipTransferResult) {
    let undoID = result.undoID
    undoManager?.registerUndo(withTarget: store) { target in
      // NSUndoManager invokes handlers synchronously on AppKit's main run loop.
      // This handler is registered from the MainActor UI path, so preserve that
      // synchronous contract while adapting the old SDK's nonisolated callback.
      MainActor.assumeIsolated {
        _ = target.undoLatestDraftOwnershipTransfer(expectedUndoID: undoID)
      }
    }
    undoManager?.setActionName(draftOwnershipUndoActionName(for: result.operation))
  }

  private func draftOwnershipUndoActionName(
    for operation: DraftOwnershipTransferOperation
  ) -> String {
    switch operation {
    case .moveToSite:
      return String(localized: "移动草稿归属")
    case .copyToSite:
      return String(localized: "复制草稿到站点")
    case .moveToGeneral:
      return String(localized: "转为通用草稿")
    }
  }

  private func selectDraft(byOffset offset: Int) {
    guard !filteredDrafts.isEmpty else {
      return
    }

    guard let selectedDraftID = store.selectedDraftID,
      let currentIndex = filteredDrafts.firstIndex(where: { $0.id == selectedDraftID })
    else {
      let targetIndex = offset >= 0 ? 0 : (filteredDrafts.count - 1)
      store.selectDraft(filteredDrafts[targetIndex].id)
      return
    }

    let targetIndex = currentIndex + offset
    if targetIndex < 0 {
      if let lastDraft = filteredDrafts.last {
        store.selectDraft(lastDraft.id)
      }
    } else if targetIndex >= filteredDrafts.count {
      if let firstDraft = filteredDrafts.first {
        store.selectDraft(firstDraft.id)
      }
    } else {
      store.selectDraft(filteredDrafts[targetIndex].id)
    }
  }
}
