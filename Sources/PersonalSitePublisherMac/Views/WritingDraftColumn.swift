import PublishingWorkbenchCore
import SwiftUI

private struct WritingDraftListCache {
  var filteredDrafts: [ArticleDraft] = []
  var visibleDraftIDs: [UUID] = []
  var visibleDraftSignatures: [UUID: DraftTaskQueueState.Signature] = [:]
  var searchText = ""
  var filter: DraftListFilter = .all
  var sortOrder: WritingDraftSortOrder = .updatedNewest
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
    @AppStorage("writingDraftSortOrderV1") private var sortOrderRawValue = WritingDraftSortOrder.updatedNewest.rawValue
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
    @State private var selectedDraftIDs: Set<UUID> = []
    @State private var draftOwnershipTransferPlan: DraftOwnershipTransferPlan?
    @Environment(\.undoManager) private var undoManager

  private var draftSelection: Binding<Set<UUID>> {
    Binding(
      get: { selectedDraftIDs },
      set: { updateDraftSelection($0) }
    )
  }

  private var contentScopeSelection: Binding<DraftListContentScope> {
    Binding(
      get: { store.draftListContentScope },
      set: { store.setDraftListContentScope($0) }
    )
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
    .sheet(item: $draftOwnershipTransferPlan) { plan in
      DraftOwnershipTransferConfirmationView(plan: plan) { confirmedPlan in
        applyDraftOwnershipTransfer(confirmedPlan)
      }
    }
  }

  private var writingHeader: some View {
    WorkspaceContextListHeader(title: "文章") {
      HStack(spacing: 6) {
        Text("\(filteredDraftCount) / \(visibleDraftCount) 篇")

        if let delta = draftCountDelta {
          Text(delta > 0 ? "+\(delta)" : "\(delta)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(delta > 0 ? WorkbenchTheme.success : WorkbenchTheme.risk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
              (delta > 0 ? WorkbenchTheme.success : WorkbenchTheme.risk)
                .opacity(WorkbenchOpacity.accentBackground),
              in: Capsule()
            )
            .scaleEffect(isDraftCountPunching ? 1.06 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDraftCountPunching)
            .transition(.scale.combined(with: .opacity))
        }
      }
    } actions: {
      if isDraftListLoading && store.writingDrafts.isEmpty {
        ProgressView()
          .controlSize(.small)
          .help("加载草稿中…")
      }

      if store.canUndoLatestDraftOwnershipTransfer {
        Button {
          _ = store.undoLatestDraftOwnershipTransfer()
        } label: {
          WorkspaceSidebarHeaderIcon("arrow.uturn.backward")
        }
        .buttonStyle(.plain)
        .help(String(localized: "撤销上次归属变更"))
        .accessibilityLabel("撤销上次归属变更")
      }

      Button {
        store.flushDraftBodyEditorBuffers()
        isDraftLifecycleCenterPresented = true
      } label: {
        Label("历史", systemImage: "clock.arrow.circlepath")
      }
      .buttonStyle(.bordered)
      .controlSize(.regular)
      .fixedSize()
      .help("版本历史与回收站")
      .accessibilityLabel("打开版本历史与回收站")

      Menu {
        Button {
          store.createDraft()
        } label: {
          Label("新建站点文章", systemImage: "doc.badge.plus")
        }

        Button {
          store.createGeneralDraft()
        } label: {
          Label("新建通用草稿", systemImage: "square.and.pencil")
        }
      } label: {
        HStack(spacing: 5) {
          Image(systemName: "plus")
          Text("新建")
            .fixedSize(horizontal: true, vertical: false)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(Color.white)
        .layoutPriority(1)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .controlSize(.regular)
      .tint(.white)
      .padding(.horizontal, 8)
      .frame(height: 28)
      .background(
        WorkbenchTheme.primaryActionFill,
        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
      )
      .fixedSize()
      .help("新建文章或通用草稿")
      .accessibilityLabel("新建文章或通用草稿")
    }
  }

  private var draftListToolbar: some View {
    VStack(spacing: 8) {
      Picker("内容范围", selection: contentScopeSelection) {
        Text("当前站点").tag(DraftListContentScope.currentSite)
        Text("通用草稿").tag(DraftListContentScope.general)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("内容范围")

      if selectedDraftIDs.count > 1 {
        bulkSelectionBar
      }

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
          .menuIndicator(.hidden)
          .controlSize(.small)
          .accessibilityLabel("更多草稿筛选")
          .accessibilityValue(filter.localizedDisplayName)
        }

        Spacer(minLength: 0)

        Menu {
          ForEach(WritingDraftSortOrder.allCases) { option in
            Button {
              sortOrderRawValue = option.rawValue
            } label: {
              if sortOrder == option {
                Label(option.localizedDisplayName, systemImage: "checkmark")
              } else {
                Text(option.localizedDisplayName)
              }
            }
          }
        } label: {
          Image(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("排序：\(sortOrder.localizedDisplayName)")
        .accessibilityLabel("文章排序")
        .accessibilityValue(sortOrder.localizedDisplayName)
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
    .menuIndicator(.hidden)
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
          WritingDraftSkeletonRow()
            .listRowInsets(listRowInsets)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .allowsHitTesting(false)
        }
      } else {
        if filteredDrafts.isEmpty {
          draftListEmptyState
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

          if paginatedDrafts.count < filteredDrafts.count {
            loadMoreDraftsButton
          }
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .background(Color.clear)
    .onDeleteCommand {
      requestDeleteSelectedDraft()
    }
    .onAppear {
      synchronizeDraftSelectionFromStore()
      applyDraftFilterDebounce()
      refreshDraftListLoadingState()
      refreshDraftCounts()
    }
    .task(
      id: DraftListImageSummaryRefreshInput(
        signature: ImageWorkbenchSiteSummaryInputSignature(
          drafts: store.writingDrafts,
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
    .onChange(of: sortOrderRawValue) { _, _ in
      resetDraftPagination()
      refreshDraftCounts()
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
    .onChange(of: store.writingDrafts) { _, newDrafts in
      synchronizeDraftSelection(with: newDrafts)
      if isDraftListLoading && !newDrafts.isEmpty {
        isDraftListLoading = false
        draftListLoadingTask?.cancel()
      }
      refreshFilteredDraftsCache()
      refreshDraftCounts()
      refreshDraftListLoadingState()
      resetDraftPagination()
    }
    .onChange(of: store.selectedDraftID) { _, _ in
      synchronizeDraftSelectionFromStore()
    }
    .onChange(of: filteredDrafts.count) { _, newCount in
      if newCount == 0 {
        draftListLimit = 0
      } else if newCount < draftListLimit {
        draftListLimit = newCount
      }
      refreshDraftCounts()
    }
    .accessibilityLabel("文章列表")
    .accessibilityValue("已显示 \(paginatedDrafts.count) 篇，共 \(filteredDrafts.count) 篇")
  }

  private var loadMoreDraftsButton: some View {
    Button {
      loadMoreDrafts()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "chevron.down.circle")
          .foregroundStyle(.secondary)
          .frame(width: 16)
        Text("显示更多文章")
        Spacer(minLength: 8)
        Text("\(paginatedDrafts.count) / \(filteredDrafts.count)")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
      .padding(.vertical, 6)
    }
    .buttonStyle(.plain)
    .listRowInsets(listRowInsets)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .accessibilityLabel("显示更多文章")
    .accessibilityValue("当前显示 \(paginatedDrafts.count) 篇，共 \(filteredDrafts.count) 篇")
    .accessibilityHint("每次再显示最多 \(draftPageStep) 篇文章")
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
      profile: store.profile(for: draft),
      display: store.privateContentDisplay(for: draft)
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

    if !draft.isGeneralDraft {
      Button {
        _ = store.focusDraft(draft.id, section: .contentHealth)
      } label: {
        Label("查看发布检查", systemImage: "checklist")
      }
    }

    Divider()

    draftOwnershipActions(for: draft)

    Button {
      _ = store.focusDraft(draft.id, section: .images)
    } label: {
      Label("在图片工作台检查此文", systemImage: "photo.on.rectangle")
    }

    Divider()

    Button(role: .destructive) {
      requestDelete(draft)
    } label: {
      Label("删除文章", systemImage: "trash")
    }
  }

  private var bulkSelectionBar: some View {
    HStack(spacing: 8) {
      Label {
        Text("已选择 \(selectedDraftIDs.count) 篇")
      } icon: {
        Image(systemName: "checkmark.circle.fill")
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)

      Spacer(minLength: 0)

      Menu {
        bulkDraftOwnershipActions
      } label: {
        Label(String(localized: "管理归属"), systemImage: "arrow.triangle.branch")
      }
      .controlSize(.small)
      .help(String(localized: "批量移动、复制或转为通用草稿"))

      Button(String(localized: "取消选择")) {
        if let selectedDraftID = store.selectedDraftID {
          selectedDraftIDs = [selectedDraftID]
        } else {
          selectedDraftIDs = []
        }
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.accentColor.opacity(WorkbenchOpacity.accentBackground), in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func draftOwnershipActions(for draft: ArticleDraft) -> some View {
    let draftIDs = transferDraftIDs(for: draft)

    if !draft.isGeneralDraft {
      Button {
        presentDraftOwnershipTransfer(
          draftIDs: draftIDs,
          operation: .moveToGeneral
        )
      } label: {
        Label(
          draftIDs.count > 1 ? String(localized: "批量转为通用草稿") : String(localized: "转为通用草稿"),
          systemImage: "tray.and.arrow.down"
        )
      }
    }

    Menu {
      ForEach(availableTransferProfiles(for: draft, includeCurrentSite: false)) { profile in
        Button(profile.name) {
          presentDraftOwnershipTransfer(
            draftIDs: draftIDs,
            operation: .moveToSite,
            targetProfileID: profile.id
          )
        }
      }
    } label: {
      Label(
        draftIDs.count > 1 ? String(localized: "批量移动到站点") : String(localized: "移动到站点"),
        systemImage: "arrow.right.doc.on.clipboard"
      )
    }
    .disabled(availableTransferProfiles(for: draft, includeCurrentSite: false).isEmpty)

    Menu {
      ForEach(availableTransferProfiles(for: draft, includeCurrentSite: false)) { profile in
        Button(profile.name) {
          presentDraftOwnershipTransfer(
            draftIDs: draftIDs,
            operation: .copyToSite,
            targetProfileID: profile.id
          )
        }
      }
    } label: {
      Label(
        draftIDs.count > 1 ? String(localized: "批量复制到站点") : String(localized: "复制到站点"),
        systemImage: "doc.on.doc"
      )
    }
    .disabled(availableTransferProfiles(for: draft, includeCurrentSite: false).isEmpty)

    if store.canUndoLatestDraftOwnershipTransfer {
      Divider()
      Button {
        _ = store.undoLatestDraftOwnershipTransfer()
      } label: {
        Label(String(localized: "撤销上次归属变更"), systemImage: "arrow.uturn.backward")
      }
    }
  }

  @ViewBuilder
  private var bulkDraftOwnershipActions: some View {
    let selectedDrafts = store.writingDrafts.filter { selectedDraftIDs.contains($0.id) }

    if selectedDrafts.allSatisfy({ !$0.isGeneralDraft }) {
      Button {
        presentDraftOwnershipTransfer(
          draftIDs: Array(selectedDraftIDs),
          operation: .moveToGeneral
        )
      } label: {
        Label(String(localized: "批量转为通用草稿"), systemImage: "tray.and.arrow.down")
      }
    }

    Menu(String(localized: "批量移动到站点")) {
      ForEach(availableTransferProfiles(for: selectedDrafts.first, includeCurrentSite: false)) { profile in
        Button(profile.name) {
          presentDraftOwnershipTransfer(
            draftIDs: Array(selectedDraftIDs),
            operation: .moveToSite,
            targetProfileID: profile.id
          )
        }
      }
    }

    Menu(String(localized: "批量复制到站点")) {
      ForEach(availableTransferProfiles(for: selectedDrafts.first, includeCurrentSite: false)) { profile in
        Button(profile.name) {
          presentDraftOwnershipTransfer(
            draftIDs: Array(selectedDraftIDs),
            operation: .copyToSite,
            targetProfileID: profile.id
          )
        }
      }
    }

    if store.canUndoLatestDraftOwnershipTransfer {
      Divider()
      Button(String(localized: "撤销上次归属变更")) {
        _ = store.undoLatestDraftOwnershipTransfer()
      }
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
    let nextVisibleCount = store.writingDrafts.count
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
    36
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
    WorkspaceSidebarMetrics.rowInsets
  }

  private func refreshDraftListLoadingState() {
    draftListLoadingTask?.cancel()
    draftListLoadingNonce += 1
    let nonce = draftListLoadingNonce

    guard store.writingDrafts.isEmpty else {
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

  private var sortOrder: WritingDraftSortOrder {
    WritingDraftSortOrder(rawValue: sortOrderRawValue) ?? .updatedNewest
  }

  private func refreshFilteredDraftsCache() {
    let visibleDrafts = store.writingDrafts
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
      draftListCache.sortOrder != sortOrder ||
      draftListCache.activeProfileID != activeProfileID ||
      draftListCache.draftTaskQueueStateVersion != draftTaskQueueStateVersion else {
      return
    }

    draftListCache.visibleDraftIDs = visibleDraftIDs
    draftListCache.visibleDraftSignatures = visibleDraftSignatures
    draftListCache.searchText = query
    draftListCache.filter = debouncedFilter
    draftListCache.sortOrder = sortOrder
    draftListCache.activeProfileID = activeProfileID
    draftListCache.draftTaskQueueStateVersion = draftTaskQueueStateVersion
    let searchableDrafts = visibleDrafts.filter { draft in
      debouncedFilter.matches(draft, taskState: debouncedFilter.requiresTaskQueueState ? taskQueueStates[draft.id] : nil)
    }
    let matchedDrafts = query.isEmpty
      ? searchableDrafts
      : searchableDrafts.filter { draft in
          draft.title.localizedCaseInsensitiveContains(query)
            || store.matchesPrivacyProtectedDraftSearch(
              draft,
              query: query,
              profile: store.activeProfile
            )
        }
    draftListCache.filteredDrafts = sortOrder.sorted(matchedDrafts)
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
    8
  }

  private var selectedDraftForDeletion: ArticleDraft? {
    guard let selectedDraftID = store.selectedDraftID else {
      return nil
    }
    return store.writingDrafts.first { $0.id == selectedDraftID }
  }

  private var writingDraftCommandActions: WritingDraftCommandActions {
    WritingDraftCommandActions(
      createDraft: {
        store.createDraft()
      },
      focusSearch: {
        isSearchFieldFocused = true
      },
      openVersionHistory: {
        store.flushDraftBodyEditorBuffers()
        isDraftLifecycleCenterPresented = true
      },
      selectPreviousDraft: {
        selectDraft(byOffset: -1)
      },
      selectNextDraft: {
        selectDraft(byOffset: 1)
      }
    )
  }

  private var draftListEmptyState: some View {
    VStack(spacing: 10) {
      Image(systemName: store.writingDrafts.isEmpty ? "doc.badge.plus" : "doc.text.magnifyingglass")
        .font(.system(size: 28))
        .foregroundStyle(.secondary)

      Text(draftListEmptyTitle)
        .font(.headline)

      Text(draftListEmptyMessage)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      if store.writingDrafts.isEmpty {
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
    guard store.writingDrafts.isEmpty else { return "没有匹配的文章" }
    return store.draftListContentScope == .general ? "还没有通用草稿" : "还没有文章"
  }

  private var draftListEmptyMessage: LocalizedStringKey {
    guard store.writingDrafts.isEmpty else {
      return "尝试清除搜索词或切换筛选条件。"
    }
    return store.draftListContentScope == .general
      ? "新建后可跨站点复用，复制到目标站点后再发布。"
      : "新建文章后即可开始写作。"
  }

  private var emptyStateActionTitle: LocalizedStringKey {
    store.draftListContentScope == .general ? "新建通用草稿" : "新建站点文章"
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

  private func updateDraftSelection(_ newSelection: Set<UUID>) {
    let previousSelection = selectedDraftIDs
    selectedDraftIDs = newSelection

    let newlySelectedID = newSelection.subtracting(previousSelection).first
    let primaryID = newlySelectedID
      ?? store.selectedDraftID.flatMap { newSelection.contains($0) ? $0 : nil }
      ?? newSelection.first
    if store.selectedDraftID != primaryID {
      store.selectDraft(primaryID)
    }
  }

  private func synchronizeDraftSelectionFromStore() {
    guard let selectedDraftID = store.selectedDraftID else {
      selectedDraftIDs = []
      return
    }
    if !selectedDraftIDs.contains(selectedDraftID) {
      selectedDraftIDs = [selectedDraftID]
    }
  }

  private func synchronizeDraftSelection(with drafts: [ArticleDraft]) {
    let availableIDs = Set(drafts.map(\.id))
    selectedDraftIDs.formIntersection(availableIDs)
    synchronizeDraftSelectionFromStore()
  }

  private func transferDraftIDs(for draft: ArticleDraft) -> [UUID] {
    if selectedDraftIDs.count > 1 && selectedDraftIDs.contains(draft.id) {
      return Array(selectedDraftIDs)
    }
    return [draft.id]
  }

  private func availableTransferProfiles(
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

  private func presentDraftOwnershipTransfer(
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

  private func applyDraftOwnershipTransfer(_ plan: DraftOwnershipTransferPlan) -> Bool {
    guard let result = store.applyDraftOwnershipTransfer(plan) else {
      return false
    }
    selectedDraftIDs = Set(result.affectedDraftIDs)
    registerDraftOwnershipUndo(result)
    return true
  }

  private func registerDraftOwnershipUndo(_ result: DraftOwnershipTransferResult) {
    undoManager?.registerUndo(withTarget: store) { target in
      _ = target.undoLatestDraftOwnershipTransfer(expectedUndoID: result.undoID)
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
