import PublishingWorkbenchCore
import SwiftUI

struct WritingDraftColumn: View {
  @Environment(\.workbenchAccentColor) var workbenchAccentColor
  let store: WorkbenchStore
  let isCompact: Bool
  /// The draft selected by this window. This is deliberately not derived from
  /// `WorkbenchStore.selectedDraftID`: the same store can back more than one
  /// workspace window.
  let selectedDraftID: UUID?
  let onSelectDraft: (UUID?) -> Void
  let onFocusDraft: (UUID, WorkspaceSection) -> Void
  @ObservedObject var writingListState: WritingListWindowPresentationState
  let draftListState: DraftListStore
  @Environment(\.openSettings) var openSettings
  @Environment(\.openWindow) var openWindow
  @Environment(\.settingsWorkspaceCommandAction) var settingsWorkspaceCommandAction
  @AppStorage("dataManagementRequestedSection") var dataManagementRequestedSection =
    DataManagementSection.drafts.rawValue
  @State var displayModeRawValue = WritingDraftListDisplayMode.flat.rawValue
  @State var searchText = ""
  @State var filter: DraftListFilter = .all
  @State var sortOrderRawValue = WritingDraftSortOrder.updatedNewest.rawValue
  @State var isDraftListLoading = false
  @State var draftListLoadingNonce = 0
  @State var visibleDraftCount = 0
  @State var filteredDraftCount = 0
  @State var draftCountDelta: Int?
  @State var draftListLoadingTask: Task<Void, Never>?
  @State var draftCountBadgeTask: Task<Void, Never>?
  @State var draftFilterDebounceTask: Task<Void, Never>?
  @State var draftListLimit: Int = 36
  @State var debouncedSearchText = ""
  @State var debouncedFilter: DraftListFilter = .all
  @State var draftListCache = WritingDraftListCache()
  @State var folderExpansionState = WritingDraftFolderExpansionState()
  @State var folderExpansionSiteID: UUID?
  @State var folderExpansionContentScope: DraftListContentScope?
  let draftLoadMorePrefetchThreshold = 15
  @FocusState var isSearchFieldFocused: Bool
  @State var draftPendingDeletion: ArticleDraft?
  @State var draftPendingUnpublish: ArticleDraft?
  @State var selectedDraftIDs: Set<UUID> = []
  @State var draftOwnershipTransferPlan: DraftOwnershipTransferPlan?
  @State var isMetadataBatchMaintenancePresented = false
  @State var isAIBatchMaintenancePresented = false
  @State var isTemplatePickerPresented = false
  @State var isGeneralFolderNamePresented = false
  @State var generalFolderNameInput = ""
  @State var generalFolderDraftIDs: [UUID] = []
  @State var generalFolderRenameSource: String?
  @Environment(\.undoManager) var undoManager
  @EnvironmentObject var sceneCommandRouter: WorkspaceSceneCommandRouter
  @State private var sceneCommandOwnerID = UUID()

  init(
    store: WorkbenchStore,
    isCompact: Bool,
    selectedDraftID: UUID?,
    onSelectDraft: @escaping (UUID?) -> Void,
    onFocusDraft: @escaping (UUID, WorkspaceSection) -> Void,
    writingListState: WritingListWindowPresentationState
  ) {
    self.store = store
    self.isCompact = isCompact
    self.selectedDraftID = selectedDraftID
    self.onSelectDraft = onSelectDraft
    self.onFocusDraft = onFocusDraft
    _writingListState = ObservedObject(wrappedValue: writingListState)
    _displayModeRawValue = State(initialValue: writingListState.displayMode.rawValue)
    _searchText = State(initialValue: writingListState.searchText)
    _filter = State(initialValue: writingListState.filter)
    _sortOrderRawValue = State(initialValue: writingListState.sortOrder.rawValue)
    _folderExpansionState = State(initialValue: writingListState.makeFolderExpansionState())
    draftListState = store.draftList
  }

  var draftSelection: Binding<Set<UUID>> {
    Binding(
      get: { selectedDraftIDs },
      set: { updateDraftSelection($0) }
    )
  }

  var contentScopeSelection: Binding<DraftListContentScope> {
    Binding(
      get: { store.draftListContentScope },
      set: { store.setDraftListContentScope($0) }
    )
  }

  var displayMode: WritingDraftListDisplayMode {
    WritingDraftListDisplayMode(rawValue: displayModeRawValue) ?? .flat
  }

  var isFolderDisplayMode: Bool {
    displayMode == .folders
  }

  var effectiveDisplayMode: WritingDraftListDisplayMode {
    isFolderDisplayMode ? .folders : .flat
  }

  var body: some View {
    VStack(spacing: 0) {
      writingHeader
        .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
        .padding(.vertical, WorkspaceSidebarMetrics.headerVerticalPadding)

      Divider()

      draftListToolbar
        .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
        .padding(.vertical, WorkspaceSidebarMetrics.toolbarVerticalPadding)

      Divider()

      draftList
    }
    .onAppear {
      applyWindowListState()
      sceneCommandRouter.registerWritingDrafts(
        writingDraftCommandActions,
        owner: sceneCommandOwnerID
      )
    }
    .onDisappear {
      sceneCommandRouter.unregisterWritingDrafts(owner: sceneCommandOwnerID)
    }
    .onChange(of: store.activeProfileID) { _, _ in
      synchronizeFolderExpansionState()
    }
    .onChange(of: writingListState.restorationRevision) { _, _ in
      applyWindowListState()
    }
    .onChange(of: searchText) { _, value in
      writingListState.searchText = value
    }
    .onChange(of: filter) { _, value in
      writingListState.filter = value
    }
    .onChange(of: displayModeRawValue) { _, value in
      writingListState.displayMode = WritingDraftListDisplayMode(rawValue: value) ?? .flat
    }
    .onChange(of: sortOrderRawValue) { _, value in
      writingListState.sortOrder = WritingDraftSortOrder(rawValue: value) ?? .updatedNewest
    }
    .onChange(of: folderExpansionState.userExpandedFolderIDs) { _, value in
      writingListState.setUserExpandedFolderIDs(value)
    }
    .sheet(item: $draftPendingUnpublish) { draft in
      let profile = store.profile(for: draft)
      DraftUnpublishReviewView(
        target: draft,
        profile: profile,
        displayTitle: { sourceID, fallback in
          guard let source = store.draft(for: sourceID) else { return fallback }
          return store.privateContentDisplay(for: source).title
        },
        isMasked: { sourceID in
          guard let source = store.draft(for: sourceID) else { return true }
          return store.privateContentDisplay(for: source).isMasked
        },
        loadSnapshot: {
          store.flushDraftBodyEditorBuffers()
          guard let current = store.draft(for: draft.id), !current.isGeneralDraft else {
            throw NSError(
              domain: "SiteUnpublishImpact", code: 1,
              userInfo: [NSLocalizedDescriptionKey: String(localized: "文章已不存在或已移出站点，请关闭预览。")]
            )
          }
          let currentProfile = store.profile(for: current)
          return try await SiteUnpublishImpactService().previewAsync(
            target: current,
            drafts: store.drafts,
            profile: currentProfile
          )
        },
        onOpenSource: { sourceID in
          guard store.draft(for: sourceID) != nil else { return }
          draftPendingUnpublish = nil
          onFocusDraft(sourceID, .writing)
        },
        onConfirm: { preview in
          store.flushDraftBodyEditorBuffers()
          guard let current = store.draft(for: draft.id),
            preview.remainsValid(
              target: current, sources: store.drafts, profile: store.profile(for: current)
            )
          else { return false }
          let draftID = draft.id
          draftPendingUnpublish = nil
          _ = await store.unpublishDraft(id: draftID)
          return true
        },
        onCancel: {
          draftPendingUnpublish = nil
        }
      )
    }
    .confirmationDialog(
      "移到回收站？",
      isPresented: deleteConfirmationPresented,
      titleVisibility: .visible,
      presenting: draftPendingDeletion
    ) { draft in
      Button("移到回收站", role: .destructive) {
        store.deleteDraft(id: draft.id)
        draftPendingDeletion = nil
      }
      Button("取消", role: .cancel) {
        draftPendingDeletion = nil
      }
    } message: { draft in
      Text("「\(draft.title.nilIfEmpty ?? "未命名文章")」将保留在回收站中，不会立即删除本地仓库文件。")
    }
    .alert(
      generalFolderRenameSource == nil
        ? String(localized: "新建通用草稿文件夹")
        : String(localized: "重命名通用草稿文件夹"),
      isPresented: $isGeneralFolderNamePresented
    ) {
      TextField("文件夹名称", text: $generalFolderNameInput)
        .accessibilityLabel("文件夹名称")
      Button("取消", role: .cancel) {
        generalFolderRenameSource = nil
      }
      Button("保存") {
        commitGeneralFolderName()
      }
      .disabled(ArticleDraft.validGeneralDraftFolderName(generalFolderNameInput) == nil)
    } message: {
      Text("文件夹只整理通用草稿，不会更改站点仓库中的文章路径。")
    }
    .sheet(item: $draftOwnershipTransferPlan) { plan in
      DraftOwnershipTransferConfirmationView(plan: plan) { confirmedPlan in
        applyDraftOwnershipTransfer(confirmedPlan)
      }
    }
    .sheet(isPresented: $isMetadataBatchMaintenancePresented) {
      MetadataBatchMaintenancePanel(store: store, initialDraftIDs: selectedDraftIDs)
    }
    .sheet(isPresented: $isAIBatchMaintenancePresented) {
      AIBatchMaintenancePanel(store: store, initialDraftIDs: selectedDraftIDs)
    }
    .sheet(isPresented: $isTemplatePickerPresented) {
      WritingDraftTemplatePicker(store: store) { template, asGeneralDraft, title in
        guard
          let draftID = store.createDraft(
            from: template, asGeneralDraft: asGeneralDraft, title: title)
        else {
          return false
        }
        onFocusDraft(draftID, .writing)
        return true
      }
    }
  }

  private func applyWindowListState() {
    searchText = writingListState.searchText
    filter = writingListState.filter
    displayModeRawValue = writingListState.displayMode.rawValue
    sortOrderRawValue = writingListState.sortOrder.rawValue
    folderExpansionState = writingListState.makeFolderExpansionState()
    if writingListState.hasPersistedFolderExpansion {
      // The cache's first-projection policy would otherwise replace restored
      // choices with defaults before it has a chance to reconcile old IDs.
      folderExpansionSiteID =
        store.draftListContentScope == .general
        ? DraftFolderProjection.generalLibraryID : store.activeProfile.id
      folderExpansionContentScope = store.draftListContentScope
      synchronizeFolderExpansionState()
    }
  }
}
