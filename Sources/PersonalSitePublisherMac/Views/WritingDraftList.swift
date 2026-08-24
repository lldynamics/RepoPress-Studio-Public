import PublishingWorkbenchCore
import SwiftUI

extension WritingDraftColumn {
  private var paginatedDrafts: ArraySlice<ArticleDraft> {
    filteredDrafts.prefix(draftListLimit)
  }

  private var draftListAccessibilityValue: String {
    String(localized: "已显示 \(paginatedDrafts.count) 篇，共 \(filteredDrafts.count) 篇")
  }

  private var draftListBase: some View {
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
        } else if isFolderDisplayMode {
          folderDraftListContent
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
  }

  @ViewBuilder
  private var folderDraftListContent: some View {
    ForEach(draftListCache.folderEntries) { entry in
      folderDraftListEntry(entry, draftsByID: draftListCache.folderDraftsByID)
    }

    if paginatedDrafts.count < filteredDrafts.count {
      loadMoreDraftsButton
    }
  }

  @ViewBuilder
  private func folderDraftListEntry(
    _ entry: WritingDraftFolderListEntry,
    draftsByID: [UUID: ArticleDraft]
  ) -> some View {
    if let folder = entry.folder {
      folderHeaderRow(folder, depth: entry.depth)
    } else if let draftID = entry.draftID,
      let draft = draftsByID[draftID]
    {
      draftRow(draft)
        .padding(.leading, CGFloat(entry.depth) * 14)
    }
  }

  private func folderHeaderRow(_ folder: DraftFolderNode, depth: Int) -> some View {
    let isExpanded = folderExpansionState.isExpanded(folder.id)
    let displayName = folderDisplayName(for: folder)
    let expansionLabel =
      isExpanded
      ? String(localized: "已展开")
      : String(localized: "已折叠")

    return Button {
      withAnimation(WorkbenchMotion.standard) {
        folderExpansionState.toggle(folder.id)
      }
      updateFolderEntriesCache()
    } label: {
      HStack(spacing: 7) {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 12)

        Image(systemName: folderSystemImage(for: folder))
          .foregroundStyle(.secondary)
          .frame(width: 16)

        Text(displayName)
          .font(.workbenchBody.weight(.medium))
          .workbenchTruncatedIdentity(displayName)

        Spacer(minLength: 6)

        Text(folder.totalDescendantDraftCount.formatted())
          .font(.workbenchSupporting.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      .padding(.leading, CGFloat(depth) * 14)
      .padding(.horizontal, 4)
      .padding(.vertical, 5)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .listRowInsets(listRowInsets)
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
    .help(folderHeaderHelp(for: folder))
    .accessibilityLabel(
      String(localized: "\(displayName)，\(folder.totalDescendantDraftCount) 篇文章")
    )
    .accessibilityValue(expansionLabel)
    .accessibilityIdentifier(
      "writing-draft-folder-\(RepositoryAccessibilityIdentifier.token(for: folder.id))"
    )
  }

  private func folderDisplayName(for folder: DraftFolderNode) -> String {
    switch folder.kind {
    case .directory:
      return folder.name
    case .protectedContent:
      return String(localized: "display.draft-list-filter.private-articles")
    case .unfiled:
      return String(localized: "未分类")
    case .root:
      return String(localized: "文件夹")
    }
  }

  private func folderSystemImage(for folder: DraftFolderNode) -> String {
    switch folder.kind {
    case .directory:
      return "folder"
    case .protectedContent:
      return "lock.folder"
    case .unfiled:
      return "tray"
    case .root:
      return "folder"
    }
  }

  private func folderHeaderHelp(for folder: DraftFolderNode) -> String {
    switch folder.kind {
    case .protectedContent:
      return String(localized: "display.draft-list-filter.private-articles")
    case .unfiled:
      return String(localized: "未分类")
    case .directory, .root:
      return folder.directoryPath ?? folderDisplayName(for: folder)
    }
  }

  private var draftListWithInputEvents: some View {
    draftListBase
      .onDeleteCommand {
        requestDeleteSelectedDraft()
      }
      .onAppear {
        synchronizeDraftSelectionFromStore()
        applyDraftFilterDebounce()
        refreshDraftListLoadingState()
        refreshDraftCountsWithoutFiltering()
      }
      .task(
        id: DraftListImageSummaryRefreshInput(
          revision: draftListState.imageInputRevision
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
        handleDraftListSortChange()
      }
  }

  private var draftListWithStoreEvents: some View {
    draftListWithInputEvents
      .onChange(of: debouncedSearchText) { _, _ in
        handleDraftListFilterChange()
      }
      .onChange(of: debouncedFilter) { _, _ in
        handleDraftListFilterChange()
      }
      .onChange(of: draftListState.taskQueueStateVersion) { _, _ in
        handleDraftListStoreUpdate()
      }
      .onChange(of: draftListState.repositoryReport) { _, _ in
        handleDraftListStoreUpdate()
      }
      .onChange(of: draftListState.presentationRevision) { _, _ in
        handleDraftListPresentationRevisionChange()
      }
      .onChange(of: draftListState.contentScope) { _, _ in
        applyDraftFilterDebounce()
      }
      .onChange(of: displayModeRawValue) { _, _ in
        synchronizeFolderExpansionState()
      }
      .onChange(of: draftListState.selectedDraftID) { _, _ in
        revealSelectedDraftIfNeeded()
        synchronizeDraftSelectionFromStore()
      }
      .onChange(of: filteredDrafts.count) { _, newCount in
        handleFilteredDraftCountChange(newCount)
      }
  }

  var draftList: some View {
    draftListWithStoreEvents
      .accessibilityLabel("文章列表")
      .accessibilityValue(draftListAccessibilityValue)
      .accessibilityIdentifier("writing-draft-list")
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
    .accessibilityValue(
      String(localized: "当前显示 \(paginatedDrafts.count) 篇，共 \(filteredDrafts.count) 篇")
    )
    .accessibilityHint(String(localized: "每次再显示最多 \(draftPageStep) 篇文章"))
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
    let presentation =
      draftListCache.rowPresentations[draft.id]
      ?? WritingDraftRowPresentation(
        draft: draft,
        profile: store.profile(for: draft),
        display: store.privateContentDisplay(for: draft)
      )
    return WritingDraftRow(presentation: presentation)
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
    } else {
      Button {
        exportGeneralDraft(draft)
      } label: {
        Label("导出 Markdown…", systemImage: "square.and.arrow.up")
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

    if !draft.isGeneralDraft,
       draft.repositoryPath?.trimmedForPublishing.nilIfEmpty != nil {
      Button(role: .destructive) {
        requestUnpublish(draft)
      } label: {
        Label("从网站下线…", systemImage: "globe.badge.chevron.backward")
      }

      Button {
        requestDelete(draft)
      } label: {
        Label("仅移到回收站…", systemImage: "trash")
      }
    } else {
      Button(role: .destructive) {
        requestDelete(draft)
      } label: {
        Label("删除文章", systemImage: "trash")
      }
    }
  }
}
