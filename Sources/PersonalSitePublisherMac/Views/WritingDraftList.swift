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

  var draftList: some View {
    draftListBase
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
      .onChange(of: draftListState.taskQueueStateVersion) { _, _ in
        refreshFilteredDraftsCache()
        refreshDraftCounts()
      }
      .onChange(of: draftListState.repositoryReport) { _, _ in
        refreshFilteredDraftsCache()
        refreshDraftCounts()
      }
      .onChange(of: draftListState.presentationRevision) { _, _ in
        refreshFilteredDraftsCache()
        revealSelectedDraftIfNeeded()
        let newDrafts = visibleDraftSnapshot
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
      .onChange(of: draftListState.selectedDraftID) { _, _ in
        revealSelectedDraftIfNeeded()
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

    Button(role: .destructive) {
      requestDelete(draft)
    } label: {
      Label("删除文章", systemImage: "trash")
    }
  }
}
