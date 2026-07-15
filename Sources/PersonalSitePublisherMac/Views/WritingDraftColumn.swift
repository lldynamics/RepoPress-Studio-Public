import PublishingWorkbenchCore
import SwiftUI

private struct WritingDraftListCache {
  var filteredDrafts: [ArticleDraft] = []
  var visibleDraftIDs: [UUID] = []
  var visibleDraftSignatures: [UUID: DraftTaskQueueState.Signature] = [:]
  var searchText = ""
  var filter: DraftListFilter = .all
  var activeProfileID: UUID?
  var draftTaskQueueStateVersion = 0
  var lastLoadMoreTriggerCount = -1

  mutating func resetPaginationTrigger() {
    lastLoadMoreTriggerCount = -1
  }
}
private struct DraftListImageSummaryRefreshInput: Hashable {
  let signature: ImageWorkbenchSiteSummaryInputSignature
}



  struct WritingDraftColumn: View {
    @ObservedObject var store: WorkbenchStore
    let isCompact: Bool
    @State private var searchText = ""
    @State private var filter: DraftListFilter = .all
    @State private var density: WritingDraftDensity = .compact
    @State private var isDraftListLoading = false
    @State private var draftListLoadingNonce = 0
    @State private var visibleDraftCount = 0
    @State private var filteredDraftCount = 0
    @State private var draftCountDelta: Int?
    @State private var isDraftCountPunching = false
    @State private var draftListLoadingTask: Task<Void, Never>?
    @State private var draftCountBadgeTask: Task<Void, Never>?
    @State private var draftFilterDebounceTask: Task<Void, Never>?
    @State private var draftListLimit: Int = 60
    @State private var debouncedSearchText = ""
    @State private var debouncedFilter: DraftListFilter = .all
    @State private var draftListCache = WritingDraftListCache()
    private let draftLoadMorePrefetchThreshold = 15
    @FocusState private var isSearchFieldFocused: Bool
    @State private var draftPendingDeletion: ArticleDraft?
    @State private var isDraftLifecycleCenterPresented = false

  private var draftSelection: Binding<UUID?> {
    Binding(
      get: { store.selectedDraftID },
      set: { store.selectDraft($0) }
    )
  }

  var body: some View {
    VStack(spacing: 0) {
      writingHeader
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      Divider()

      draftList

      Divider()

      statusFooter
        .padding(12)
    }
    .background(.bar)
    .focusedSceneValue(\.writingDraftCommandActions, writingDraftCommandActions)
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
    .sheet(isPresented: $isDraftLifecycleCenterPresented) {
      DraftLifecycleCenterView(store: store)
    }
  }

  private var writingHeader: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 2) {
          Text("文章")
            .font(.headline)
          HStack(spacing: 6) {
            Text("\(filteredDraftCount) / \(visibleDraftCount) 篇")
              .font(.caption)
              .foregroundStyle(.secondary)

            if let delta = draftCountDelta {
              Text(delta > 0 ? "+\(delta)" : "\(delta)")
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(delta > 0 ? .green : .red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background((delta > 0 ? WorkbenchTheme.success : WorkbenchTheme.risk).opacity(WorkbenchOpacity.accentBackground), in: Capsule())
                .scaleEffect(isDraftCountPunching ? 1.06 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDraftCountPunching)
                .transition(.scale.combined(with: .opacity))
            }
          }
          .lineLimit(1)
        }

        Spacer()

        if isDraftListLoading && store.visibleDrafts.isEmpty {
          ProgressView()
            .controlSize(.small)
            .help("加载草稿中…")
        }

        Spacer(minLength: 8)

        Button {
          isDraftLifecycleCenterPresented = true
        } label: {
          Label("版本历史与回收站", systemImage: "clock.arrow.circlepath")
        }
        .labelStyle(.iconOnly)
        .help("版本历史与回收站")
        .accessibilityLabel("打开版本历史与回收站")

        Button(role: .destructive) {
          requestDeleteSelectedDraft()
        } label: {
          Label("移到回收站", systemImage: "trash")
        }
        .labelStyle(.iconOnly)
        .disabled(selectedDraftForDeletion == nil)
        .help("将选中文章移到回收站")
        .accessibilityLabel("将选中文章移到回收站")

      }
    }
  }

  private var draftListToolbar: some View {
    VStack(spacing: 8) {
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)
          .font(.footnote)

        TextField("搜索草稿", text: $searchText)
          .textFieldStyle(.plain)
          .focused($isSearchFieldFocused)
          .accessibilityLabel("搜索草稿")
          .accessibilityValue(searchText.nilIfEmpty ?? "未输入")

        if !searchText.isEmpty {
          Button {
            searchText = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("清除搜索")
          .accessibilityLabel("清除草稿搜索")
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))

      HStack(spacing: 6) {
        if isCompact {
          draftFilterMenu
        } else {
          ForEach(DraftListFilter.primaryFilters) { candidate in
            Button(candidate.localizedDisplayName) {
              filter = candidate
            }
            .buttonStyle(.bordered)
            .tint(filter == candidate ? .accentColor : .secondary)
            .controlSize(.small)
            .accessibilityAddTraits(filter == candidate ? .isSelected : [])
          }

          Menu {
            ForEach(DraftListFilter.overflowFilters) { candidate in
              filterButton(candidate)
            }
          } label: {
            Label(overflowFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
          }
          .controlSize(.small)
          .accessibilityLabel("更多草稿筛选")
          .accessibilityValue(filter.localizedDisplayName)
        }

        Spacer(minLength: 0)

        Menu {
          Picker("列表密度", selection: $density) {
            ForEach(WritingDraftDensity.allCases) { option in
              Text(option.localizedDisplayName).tag(option)
            }
          }
        } label: {
          Image(systemName: density == .compact ? "line.3.horizontal" : "rectangle.3.group")
        }
        .menuStyle(.borderlessButton)
        .help("列表密度：\(density.localizedDisplayName)")
        .accessibilityLabel("草稿列表密度")
        .accessibilityValue(density.localizedDisplayName)
      }
    }
  }

  private var overflowFilterLabel: String {
    DraftListFilter.primaryFilters.contains(filter) ? "更多" : filter.localizedDisplayName
  }

  private var draftFilterMenu: some View {
    Menu {
      ForEach(DraftListFilter.allCases) { candidate in
        filterButton(candidate)
      }
    } label: {
      Label(filter.localizedDisplayName, systemImage: "line.3.horizontal.decrease.circle")
        .lineLimit(1)
    }
    .controlSize(.small)
    .accessibilityLabel("草稿筛选")
    .accessibilityValue(filter.localizedDisplayName)
    .help("筛选草稿")
  }

  @ViewBuilder
  private func filterButton(_ candidate: DraftListFilter) -> some View {
    Button {
      filter = candidate
    } label: {
      if filter == candidate {
        Label(candidate.localizedDisplayName, systemImage: "checkmark")
      } else {
        Text(candidate.localizedDisplayName)
      }
    }
    .accessibilityAddTraits(filter == candidate ? .isSelected : [])
  }

  private var paginatedDrafts: ArraySlice<ArticleDraft> {
    filteredDrafts.prefix(draftListLimit)
  }

  private var draftList: some View {
    List(selection: draftSelection) {
      if isDraftListLoading {
        ForEach(0..<skeletonPlaceholderCount, id: \.self) { _ in
          WritingDraftSkeletonRow(density: density)
            .listRowInsets(listRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .allowsHitTesting(false)
        }
      } else {
        ForEach(Array(paginatedDrafts.enumerated()), id: \.1.id) { index, draft in
          draftRow(draft)
            .onAppear {
              maybeLoadMoreDraftsIfNeeded(
                currentIndex: index,
                visibleCount: paginatedDrafts.count
              )
            }
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .safeAreaInset(edge: .top, spacing: 0) {
      draftListToolbar
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.clear)
        .overlay(alignment: .bottom) {
          Divider()
        }
    }
    .onDeleteCommand {
      requestDeleteSelectedDraft()
    }
    .onAppear {
      applyDraftFilterDebounce()
      refreshDraftListLoadingState()
      refreshDraftCounts()
    }
    .task(
      id: DraftListImageSummaryRefreshInput(
        signature: ImageWorkbenchSiteSummaryInputSignature(
          drafts: store.visibleDrafts,
          profile: store.activeProfile
        )
      )
    ) {
      await store.refreshImageWorkbenchSiteSummaryInBackground()
    }
    .onChange(of: searchText) { _, _ in
      scheduleDraftFilterDebounce()
    }
    .onChange(of: filter) { _, _ in
      scheduleDraftFilterDebounce()
    }
    .onChange(of: density) { _, _ in
      resetDraftPagination()
    }
    .onChange(of: debouncedSearchText) { _, _ in
      resetDraftPagination()
      refreshFilteredDraftsCache()
      refreshDraftCounts()
    }
    .onChange(of: debouncedFilter) { _, _ in
      resetDraftPagination()
      refreshFilteredDraftsCache()
      refreshDraftCounts()
    }
    .onChange(of: store.draftTaskQueueStateVersion) { _, _ in
      refreshFilteredDraftsCache()
      refreshDraftCounts()
    }
    .onChange(of: store.repositoryReport) { _, _ in
      refreshFilteredDraftsCache()
      refreshDraftCounts()
    }
    .onChange(of: store.visibleDrafts) { _, newDrafts in
      if isDraftListLoading && !newDrafts.isEmpty {
        isDraftListLoading = false
        draftListLoadingTask?.cancel()
      }
      refreshFilteredDraftsCache()
      refreshDraftCounts()
      refreshDraftListLoadingState()
      resetDraftPagination()
    }
    .onChange(of: filteredDrafts.count) { _, newCount in
      if newCount == 0 {
        draftListLimit = 0
      } else if newCount < draftListLimit {
        draftListLimit = newCount
      }
      refreshDraftCounts()
    }
  }
  private func maybeLoadMoreDraftsIfNeeded(
    currentIndex: Int,
    visibleCount: Int
  ) {
    guard visibleCount < filteredDrafts.count else {
      return
    }
    let triggerIndex = max(0, visibleCount - draftLoadMorePrefetchThreshold)
    guard currentIndex >= triggerIndex else {
      return
    }
    guard draftListCache.lastLoadMoreTriggerCount != visibleCount else {
      return
    }
    draftListCache.lastLoadMoreTriggerCount = visibleCount
    loadMoreDrafts()
  }

  private func draftRow(_ draft: ArticleDraft) -> some View {
    WritingDraftRow(
      draft: draft,
      profile: store.activeProfile,
      display: store.privateContentDisplay(for: draft),
      density: density
    )
    .tag(draft.id)
    .listRowInsets(listRowInsets)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .contextMenu {
      draftContextMenu(for: draft)
    }
  }

  @ViewBuilder
  private func draftContextMenu(for draft: ArticleDraft) -> some View {
    Button {
      _ = store.focusDraft(draft.id, section: .writing)
    } label: {
      Label("编辑文章", systemImage: "square.and.pencil")
    }

    Button {
      _ = store.focusDraft(draft.id, section: .contentHealth)
    } label: {
      Label("查看发布检查", systemImage: "checklist")
    }

    Button {
      _ = store.focusDraft(draft.id, section: .images)
    } label: {
      Label("查看图片元数据", systemImage: "photo.on.rectangle")
    }

    Divider()

    Button(role: .destructive) {
      requestDelete(draft)
    } label: {
      Label("删除文章", systemImage: "trash")
    }
  }

  private func loadMoreDrafts() {
    let nextLimit = draftListLimit + draftPageStep
    let totalCount = filteredDrafts.count
    guard nextLimit <= totalCount else {
      draftListLimit = totalCount
      return
    }
    withAnimation(.easeInOut(duration: 0.15)) {
      draftListLimit = nextLimit
    }
  }

  private func scheduleDraftFilterDebounce() {
    draftFilterDebounceTask?.cancel()

    let nextSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    let nextFilter = filter

    draftFilterDebounceTask = Task {
      do {
        try await Task.sleep(nanoseconds: 180_000_000)
      } catch {
        return
      }

      guard !Task.isCancelled else {
        return
      }

      await MainActor.run {
        let changedSearchText = nextSearchText
        let searchDidChange = changedSearchText != debouncedSearchText
        let filterDidChange = nextFilter != debouncedFilter
        if searchDidChange || filterDidChange {
          debouncedSearchText = changedSearchText
          debouncedFilter = nextFilter
        }
      }
    }
  }

  private func applyDraftFilterDebounce() {
    debouncedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    debouncedFilter = filter
    refreshFilteredDraftsCache()
    resetDraftPagination()
    refreshDraftCounts()
  }

  private func refreshDraftCounts() {
    refreshFilteredDraftsCache()
    let nextFilteredCount = filteredDrafts.count
    let nextVisibleCount = store.visibleDrafts.count
    let delta = nextVisibleCount - visibleDraftCount

    visibleDraftCount = nextVisibleCount
    filteredDraftCount = nextFilteredCount

    if delta != 0 {
      applyDraftCountDelta(delta)
    } else if draftCountDelta == nil {
      isDraftCountPunching = false
    }
  }

  private func applyDraftCountDelta(_ delta: Int) {
    draftCountDelta = delta
    isDraftCountPunching = true
    draftCountBadgeTask?.cancel()

    draftCountBadgeTask = Task {
      try? await Task.sleep(nanoseconds: 800_000_000)
      if Task.isCancelled {
        return
      }
      await MainActor.run {
        withAnimation(.easeInOut(duration: 0.2)) {
          isDraftCountPunching = false
          draftCountDelta = nil
        }
      }
    }
  }

  private var draftPageStep: Int {
    density == .compact ? 48 : 36
  }

  private func resetDraftPagination() {
    refreshFilteredDraftsCache()
    guard !filteredDrafts.isEmpty else {
      draftListLimit = 0
      draftListCache.resetPaginationTrigger()
      return
    }
    draftListLimit = min(filteredDrafts.count, draftPageStep)
    draftListCache.resetPaginationTrigger()
  }

  private var listRowInsets: EdgeInsets {
    EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
  }

  private func refreshDraftListLoadingState() {
    draftListLoadingTask?.cancel()
    draftListLoadingNonce += 1
    let nonce = draftListLoadingNonce

    guard store.visibleDrafts.isEmpty else {
      isDraftListLoading = false
      return
    }

    isDraftListLoading = true
    draftListLoadingTask = Task { @MainActor in
      do {
        try await Task.sleep(nanoseconds: 250_000_000)
      } catch {
        return
      }
      guard isDraftListLoading && nonce == draftListLoadingNonce else {
        return
      }
      isDraftListLoading = false
    }
  }

  private var filteredDrafts: [ArticleDraft] {
    draftListCache.filteredDrafts
  }

  private func refreshFilteredDraftsCache() {
    let visibleDrafts = store.visibleDrafts
    let visibleDraftIDs = visibleDrafts.map(\.id)
    let activeProfileID = store.activeProfile.id
    let taskQueueStates: [UUID: DraftTaskQueueState] = debouncedFilter.requiresTaskQueueState
      ? store.draftTaskQueueStates(for: visibleDrafts)
      : [:]
    let visibleDraftSignatures = Dictionary(
      uniqueKeysWithValues: visibleDrafts.map { draft in
        (
          draft.id,
          taskQueueStates[draft.id]?.signature ?? DraftTaskQueueState.Signature(
            draft: draft,
            profileID: activeProfileID,
            imageIssueCount: 0
          )
        )
      }
    )
    let query = debouncedSearchText
    let draftTaskQueueStateVersion = store.draftTaskQueueStateVersion

    guard visibleDraftIDs != draftListCache.visibleDraftIDs || visibleDraftSignatures != draftListCache.visibleDraftSignatures ||
      query != draftListCache.searchText || draftListCache.filter != debouncedFilter ||
      draftListCache.activeProfileID != activeProfileID ||
      draftListCache.draftTaskQueueStateVersion != draftTaskQueueStateVersion else {
      return
    }

    draftListCache.visibleDraftIDs = visibleDraftIDs
    draftListCache.visibleDraftSignatures = visibleDraftSignatures
    draftListCache.searchText = query
    draftListCache.filter = debouncedFilter
    draftListCache.activeProfileID = activeProfileID
    draftListCache.draftTaskQueueStateVersion = draftTaskQueueStateVersion
    let searchableDrafts = visibleDrafts.filter { draft in
      debouncedFilter.matches(draft, taskState: debouncedFilter.requiresTaskQueueState ? taskQueueStates[draft.id] : nil)
    }
    guard !query.isEmpty else {
      draftListCache.filteredDrafts = searchableDrafts
      return
    }

    draftListCache.filteredDrafts = searchableDrafts.filter { draft in
      store.matchesPrivacyProtectedDraftSearch(
        draft,
        query: query,
        profile: store.activeProfile
      )
    }
  }

  private var repositoryStatus: String {
    if let report = store.repositoryReport, !report.rootPath.isEmpty {
      return report.statusTitle
    }
    return store.activeProfile.purpose.repositoryStatusWhenUnconfigured
  }

  private var statusFooter: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(repositoryStatus, systemImage: store.activeProfile.purpose.systemImage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      HStack(spacing: 5) {
        if store.hasUnsavedChanges {
          Image(systemName: "circle.fill")
            .font(.system(size: 5))
            .foregroundStyle(WorkbenchTheme.warning)
            .accessibilityHidden(true)
        }
        if store.hasUnsavedChanges {
          Text(store.lastSaveStatus)
            .font(.caption2)
            .foregroundStyle(WorkbenchTheme.warning)
            .lineLimit(1)
        } else {
          Text(store.lastSaveStatus)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .accessibilityLabel("保存状态")
      .accessibilityValue(store.lastSaveStatus)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { draftPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          draftPendingDeletion = nil
        }
      }
    )
  }

  private var skeletonPlaceholderCount: Int {
    return density == .compact ? 10 : 8
  }

  private var selectedDraftForDeletion: ArticleDraft? {
    guard let selectedDraftID = store.selectedDraftID else {
      return nil
    }
    return store.visibleDrafts.first { $0.id == selectedDraftID }
  }

  private var writingDraftCommandActions: WritingDraftCommandActions {
    WritingDraftCommandActions(
      createDraft: {
        store.createDraft()
      },
      focusSearch: {
        isSearchFieldFocused = true
        if !searchText.isEmpty {
          searchText = ""
        }
      },
      selectPreviousDraft: {
        selectDraft(byOffset: -1)
      },
      selectNextDraft: {
        selectDraft(byOffset: 1)
      }
    )
  }

  private func requestDelete(_ draft: ArticleDraft) {
    draftPendingDeletion = draft
  }

  private func requestDeleteSelectedDraft() {
    guard let draft = selectedDraftForDeletion else {
      return
    }
    requestDelete(draft)
  }

  private func selectDraft(byOffset offset: Int) {
    guard !filteredDrafts.isEmpty else {
      return
    }

    guard let selectedDraftID = store.selectedDraftID,
          let currentIndex = filteredDrafts.firstIndex(where: { $0.id == selectedDraftID }) else {
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
