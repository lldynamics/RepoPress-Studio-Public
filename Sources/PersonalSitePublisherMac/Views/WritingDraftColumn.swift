import PublishingWorkbenchCore
import SwiftUI

private struct WritingDraftFolderProjectionCacheKey: Equatable {
  let presentationRevision: UInt64
  let profileID: UUID
  let contentRoot: String
  let markdownPathPattern: String
  let sortOrderRawValue: String
  let draftIDs: [UUID]
  let maskedDraftIDs: Set<UUID>
}

private struct WritingDraftFilteredFolderProjectionCacheKey: Equatable {
  let universe: WritingDraftFolderProjectionCacheKey
  let query: String
  let filteredDraftIDs: [UUID]
}

private struct WritingDraftFolderEntriesCacheKey: Equatable {
  let filtered: WritingDraftFilteredFolderProjectionCacheKey
  let expandedFolderIDs: Set<String>
  let loadedDraftIDs: Set<UUID>
}

struct WritingDraftListCache {
  var presentationRevision: UInt64?
  var sourceProfileID: UUID?
  var sourceContentScope: DraftListContentScope?
  var sourceDrafts: [ArticleDraft] = []
  var filteredDrafts: [ArticleDraft] = []
  var rowPresentations: [UUID: WritingDraftRowPresentation] = [:]
  var rowPresentationKeys: [UUID: WritingDraftRowPresentationCacheKey] = [:]
  private(set) var rowPresentationBuildCount = 0
  var universeFolderProjection: DraftFolderProjection?
  var filteredFolderProjection: DraftFolderProjection?
  var folderDraftsByID: [UUID: ArticleDraft] = [:]
  var folderEntries: [WritingDraftFolderListEntry] = []
  private(set) var folderProjectionBuildCount = 0
  private(set) var folderEntriesBuildCount = 0
  private var universeFolderProjectionKey: WritingDraftFolderProjectionCacheKey?
  private var filteredFolderProjectionKey: WritingDraftFilteredFolderProjectionCacheKey?
  private var folderDraftsByIDKey: WritingDraftFilteredFolderProjectionCacheKey?
  private var folderEntriesKey: WritingDraftFolderEntriesCacheKey?
  var searchText = ""
  var filter: DraftListFilter = .all
  var sortOrder: WritingDraftSortOrder = .updatedNewest
  var draftTaskQueueStateVersion = 0
  var lastLoadMoreTriggerCount = -1

  mutating func resetPaginationTrigger() {
    lastLoadMoreTriggerCount = -1
  }

  /// Updates the folder projections and draft lookup only when their explicit
  /// source, site, query, sort, or privacy keys change. The presentation
  /// revision is intentionally part of the key so a row-affecting store event
  /// cannot leave a stale folder assignment in the sidebar.
  mutating func updateFolderProjectionCache(
    presentationRevision: UInt64,
    profile: SiteProfile,
    universeDrafts: [ArticleDraft],
    filteredDrafts: [ArticleDraft],
    query: String,
    sortOrder: DraftListSortOrder,
    maskedDraftIDs: Set<UUID>
  ) {
    let universeKey = WritingDraftFolderProjectionCacheKey(
      presentationRevision: presentationRevision,
      profileID: profile.id,
      contentRoot: profile.contentRoot,
      markdownPathPattern: profile.markdownPathPattern,
      sortOrderRawValue: sortOrder.rawValue,
      draftIDs: universeDrafts.map(\.id),
      maskedDraftIDs: maskedDraftIDs
    )
    if universeFolderProjectionKey != universeKey {
      universeFolderProjection = DraftFolderProjection(
        profile: profile,
        drafts: universeDrafts,
        sortOrder: sortOrder,
        maskedDraftIDs: maskedDraftIDs
      )
      universeFolderProjectionKey = universeKey
      folderProjectionBuildCount += 1
    }

    let filteredKey = WritingDraftFilteredFolderProjectionCacheKey(
      universe: universeKey,
      query: query,
      filteredDraftIDs: filteredDrafts.map(\.id)
    )
    if filteredFolderProjectionKey != filteredKey {
      filteredFolderProjection = DraftFolderProjection(
        profile: profile,
        drafts: filteredDrafts,
        sortOrder: sortOrder,
        maskedDraftIDs: maskedDraftIDs
      )
      filteredFolderProjectionKey = filteredKey
      folderProjectionBuildCount += 1
    }

    if folderDraftsByIDKey != filteredKey {
      folderDraftsByID = Dictionary(
        filteredDrafts.map { ($0.id, $0) },
        uniquingKeysWith: { _, latest in latest }
      )
      folderDraftsByIDKey = filteredKey
    }

    if folderEntriesKey?.filtered != filteredKey {
      folderEntriesKey = nil
      folderEntries.removeAll(keepingCapacity: true)
    }
  }

  /// Updates only the flattened rows affected by expansion or pagination.
  /// Folder headers stay cached with the filtered projection and are not
  /// rebuilt when an unrelated view invalidates the sidebar body.
  mutating func updateFolderEntriesCache(
    expandedFolderIDs: Set<String>,
    loadedDraftIDs: Set<UUID>
  ) {
    guard let filteredFolderProjection,
      let filteredFolderProjectionKey
    else {
      folderEntriesKey = nil
      folderEntries.removeAll(keepingCapacity: true)
      return
    }

    let key = WritingDraftFolderEntriesCacheKey(
      filtered: filteredFolderProjectionKey,
      expandedFolderIDs: expandedFolderIDs,
      loadedDraftIDs: loadedDraftIDs
    )
    guard folderEntriesKey != key else {
      return
    }

    folderEntries = WritingDraftFolderListProjection.flatten(
      root: filteredFolderProjection.root,
      expandedFolderIDs: expandedFolderIDs,
      loadedDraftIDs: loadedDraftIDs
    )
    folderEntriesKey = key
    folderEntriesBuildCount += 1
  }

  mutating func clearFolderProjectionCache() {
    universeFolderProjection = nil
    filteredFolderProjection = nil
    folderDraftsByID.removeAll(keepingCapacity: true)
    folderEntries.removeAll(keepingCapacity: true)
    universeFolderProjectionKey = nil
    filteredFolderProjectionKey = nil
    folderDraftsByIDKey = nil
    folderEntriesKey = nil
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
  /// The draft selected by this window. This is deliberately not derived from
  /// `WorkbenchStore.selectedDraftID`: the same store can back more than one
  /// workspace window.
  let selectedDraftID: UUID?
  let onSelectDraft: (UUID?) -> Void
  let onFocusDraft: (UUID, WorkspaceSection) -> Void
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
  @State var draftPendingUnpublish: ArticleDraft?
  @State var selectedDraftIDs: Set<UUID> = []
  @State var draftOwnershipTransferPlan: DraftOwnershipTransferPlan?
  @Environment(\.undoManager) var undoManager
  @EnvironmentObject private var sceneCommandRouter: WorkspaceSceneCommandRouter
  @State private var sceneCommandOwnerID = UUID()

  init(
    store: WorkbenchStore,
    isCompact: Bool,
    selectedDraftID: UUID?,
    onSelectDraft: @escaping (UUID?) -> Void,
    onFocusDraft: @escaping (UUID, WorkspaceSection) -> Void
  ) {
    self.store = store
    self.isCompact = isCompact
    self.selectedDraftID = selectedDraftID
    self.onSelectDraft = onSelectDraft
    self.onFocusDraft = onFocusDraft
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
      "从网站下线这篇文章？",
      isPresented: unpublishConfirmationPresented,
      titleVisibility: .visible,
      presenting: draftPendingUnpublish
    ) { draft in
      Button("确认下线", role: .destructive) {
        let draftID = draft.id
        draftPendingUnpublish = nil
        Task {
          await store.unpublishDraft(id: draftID)
        }
      }
      Button("取消", role: .cancel) {
        draftPendingUnpublish = nil
      }
    } message: { draft in
      let strategy = store.profile(for: draft).repositoryPublishStrategy == .direct
        ? String(localized: "直接提交远端删除")
        : String(localized: "创建下线 PR/MR")
      Text("软件会把「\(draft.title.nilIfEmpty ?? String(localized: "未命名文章"))」移到回收站、\(strategy)，并清理本地 Markdown；图片资源不会自动删除。失败项会保留在发布抽屉中重试。")
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
