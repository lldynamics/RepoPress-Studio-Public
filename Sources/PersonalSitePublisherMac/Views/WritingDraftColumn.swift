import PublishingWorkbenchCore
import SwiftUI

struct WritingDraftListCache {
  var presentationRevision: UInt64?
  var sourceDrafts: [ArticleDraft] = []
  var filteredDrafts: [ArticleDraft] = []
  var rowPresentations: [UUID: WritingDraftRowPresentation] = [:]
  var rowPresentationKeys: [UUID: WritingDraftRowPresentationCacheKey] = [:]
  private(set) var rowPresentationBuildCount = 0
  var searchText = ""
  var filter: DraftListFilter = .all
  var sortOrder: WritingDraftSortOrder = .updatedNewest
  var draftTaskQueueStateVersion = 0
  var lastLoadMoreTriggerCount = -1

  mutating func resetPaginationTrigger() {
    lastLoadMoreTriggerCount = -1
  }

  /// Reconciles only rows that can be rendered in the current page. The key is
  /// intentionally cheap (and excludes body text), so body-only edits can keep
  /// an existing presentation without rescanning the markdown for every row.
  mutating func updateRowPresentations(
    sourceDrafts: [ArticleDraft],
    visibleDrafts: ArraySlice<ArticleDraft>,
    profileFor: (ArticleDraft) -> SiteProfile,
    displayFor: (ArticleDraft) -> PrivateContentDisplay
  ) {
    let sourceIDs = Set(sourceDrafts.map(\.id))
    rowPresentations = rowPresentations.filter { sourceIDs.contains($0.key) }
    rowPresentationKeys = rowPresentationKeys.filter { sourceIDs.contains($0.key) }

    for draft in visibleDrafts {
      let profile = profileFor(draft)
      let display = displayFor(draft)
      let key = WritingDraftRowPresentationCacheKey(
        draft: draft,
        profile: profile,
        display: display
      )
      if rowPresentationKeys[draft.id] == key,
        rowPresentations[draft.id] != nil
      {
        continue
      }

      rowPresentationKeys[draft.id] = key
      rowPresentations[draft.id] = WritingDraftRowPresentation(
        draft: draft,
        profile: profile,
        display: display
      )
      rowPresentationBuildCount += 1
    }
  }
}

struct DraftListImageSummaryRefreshInput: Hashable {
  let revision: UInt64
}

struct WritingDraftColumn: View {
  let store: WorkbenchStore
  let isCompact: Bool
  @StateObject var draftListState: WorkbenchDraftListFeatureFacade
  @Environment(\.openSettings) var openSettings
  @AppStorage("settingsRequestedTabID") var requestedSettingsTabID = ""
  @AppStorage("dataManagementRequestedSection") var dataManagementRequestedSection =
    DataManagementSection.drafts.rawValue
  @AppStorage("writingDraftListDisplayModeV1") var displayModeRawValue =
    WritingDraftListDisplayMode.flat.rawValue
  @State var searchText = ""
  @State var filter: DraftListFilter = .all
  @AppStorage("writingDraftSortOrderV1") var sortOrderRawValue = WritingDraftSortOrder
    .updatedNewest.rawValue
  @State var isDraftListLoading = false
  @State var draftListLoadingNonce = 0
  @State var visibleDraftCount = 0
  @State var filteredDraftCount = 0
  @State var draftCountDelta: Int?
  @State var isDraftCountPunching = false
  @State var draftListLoadingTask: Task<Void, Never>?
  @State var draftCountBadgeTask: Task<Void, Never>?
  @State var draftFilterDebounceTask: Task<Void, Never>?
  @State var draftListLimit: Int = 36
  @State var debouncedSearchText = ""
  @State var debouncedFilter: DraftListFilter = .all
  @State var draftListCache = WritingDraftListCache()
  @State var folderExpansionState = WritingDraftFolderExpansionState()
  @State var folderExpansionSiteID: UUID?
  let draftLoadMorePrefetchThreshold = 15
  @FocusState var isSearchFieldFocused: Bool
  @State var draftPendingDeletion: ArticleDraft?
  @State var selectedDraftIDs: Set<UUID> = []
  @State var draftOwnershipTransferPlan: DraftOwnershipTransferPlan?
  @Environment(\.undoManager) var undoManager
  @EnvironmentObject private var sceneCommandRouter: WorkspaceSceneCommandRouter
  @State private var sceneCommandOwnerID = UUID()

  init(store: WorkbenchStore, isCompact: Bool) {
    self.store = store
    self.isCompact = isCompact
    _draftListState = StateObject(
      wrappedValue: WorkbenchDraftListFeatureFacade(store: store)
    )
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
    store.draftListContentScope == .currentSite && displayMode == .folders
  }

  /// General drafts retain the user's site preference for the next visit but
  /// always render as a flat list because they have no publishing folders.
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
    .sheet(item: $draftOwnershipTransferPlan) { plan in
      DraftOwnershipTransferConfirmationView(plan: plan) { confirmedPlan in
        applyDraftOwnershipTransfer(confirmedPlan)
      }
    }
  }
}
