import PublishingWorkbenchCore
import SwiftUI

private struct WritingDraftFolderProjectionCacheKey: Equatable {
  let profileID: UUID
  let contentScope: DraftListContentScope
  let contentRoot: String
  let markdownPathPattern: String
  let sortOrderRawValue: String
  let draftSignatures: [WritingDraftFolderProjectionDraftSignature]
}

private struct WritingDraftFolderProjectionDraftSignature: Equatable {
  let id: UUID
  let folderAssignment: DraftFolderAssignmentCacheKey
  let ordering: WritingDraftFolderProjectionOrderingSignature

  init(
    draft: ArticleDraft,
    profile: SiteProfile,
    contentScope: DraftListContentScope,
    isMasked: Bool,
    sortOrder: DraftListSortOrder
  ) {
    id = draft.id
    folderAssignment = DraftFolderProjection.assignmentCacheKey(
      for: draft,
      profile: profile,
      contentScope: contentScope,
      isMasked: isMasked
    )
    ordering = WritingDraftFolderProjectionOrderingSignature(
      draft: draft,
      sortOrder: sortOrder
    )
  }
}

private struct WritingDraftFolderProjectionOrderingSignature: Equatable {
  let sortOrder: DraftListSortOrder
  let metadataUpdatedAt: Date?
  let articleDate: Date?
  let title: String?

  init(draft: ArticleDraft, sortOrder: DraftListSortOrder) {
    self.sortOrder = sortOrder
    switch sortOrder {
    case .updatedNewest, .updatedOldest:
      metadataUpdatedAt = draft.metadataUpdatedAt
      articleDate = nil
      // Updated sorting also falls back to the stable localized title order
      // when two metadata edits share the same timestamp.
      title = draft.title
    case .articleDateNewest, .articleDateOldest:
      metadataUpdatedAt = nil
      articleDate = draft.date
      // Date sorting falls back to the stable localized title order.
      title = draft.title
    case .titleAscending, .titleDescending:
      metadataUpdatedAt = draft.metadataUpdatedAt
      articleDate = nil
      title = draft.title
    }
  }
}

private struct WritingDraftFilteredFolderProjectionCacheKey: Equatable {
  let profileID: UUID
  let contentScope: DraftListContentScope
  let contentRoot: String
  let markdownPathPattern: String
  let sortOrderRawValue: String
  let draftSignatures: [WritingDraftFolderProjectionDraftSignature]
}

private struct WritingDraftFolderEntriesCacheKey: Equatable {
  let filtered: WritingDraftFilteredFolderProjectionCacheKey
  let expandedFolderIDs: Set<String>
  let loadedDraftIDs: Set<UUID>
}

struct WritingDraftListCache {
  var sourceMetadataRevision: UInt64?
  var sourceProfileID: UUID?
  var sourceContentScope: DraftListContentScope?
  var sourceDraftIDs: [UUID] = []
  var renderedDraftsByID: [UUID: ArticleDraft] = [:]
  var filteredDraftIDs: [UUID] = []
  var rowPresentations: [UUID: WritingDraftRowPresentation] = [:]
  var rowPresentationKeys: [UUID: WritingDraftRowPresentationCacheKey] = [:]
  private(set) var rowPresentationBuildCount = 0
  var universeFolderProjection: DraftFolderProjection?
  var filteredFolderProjection: DraftFolderProjection?
  var folderEntries: [WritingDraftFolderListEntry] = []
  private(set) var folderProjectionBuildCount = 0
  private(set) var folderEntriesBuildCount = 0
  private var universeFolderProjectionKey: WritingDraftFolderProjectionCacheKey?
  private var universeFolderProjectionSourceRevision: UInt64?
  private var filteredFolderProjectionKey: WritingDraftFilteredFolderProjectionCacheKey?
  private var folderEntriesKey: WritingDraftFolderEntriesCacheKey?
  var searchText = ""
  var filter: DraftListFilter = .all
  var sortOrder: WritingDraftSortOrder = .updatedNewest
  var draftTaskQueueStateVersion = 0
  var lastLoadMoreTriggerCount = -1

  mutating func replaceRenderedSourceDrafts(_ drafts: [ArticleDraft]) {
    sourceDraftIDs = drafts.map(\.id)
    renderedDraftsByID = Dictionary(
      drafts.map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
  }

  func renderedDraft(for draftID: UUID) -> ArticleDraft? {
    renderedDraftsByID[draftID]
  }

  func renderedDrafts<S: Sequence>(for draftIDs: S) -> [ArticleDraft]
  where S.Element == UUID {
    draftIDs.compactMap { renderedDraftsByID[$0] }
  }

  mutating func resetPaginationTrigger() {
    lastLoadMoreTriggerCount = -1
  }

  /// Updates the folder projections only when fields that can affect folder
  /// membership or ordering change. Body text, derived word counts, summaries,
  /// and automatic persistence timestamps are deliberately absent from these
  /// signatures so autosave cannot rebuild the tree.
  mutating func updateFolderProjectionCache(
    profile: SiteProfile,
    contentScope: DraftListContentScope = .currentSite,
    universeDrafts: [ArticleDraft],
    filteredDrafts: [ArticleDraft],
    sortOrder: DraftListSortOrder,
    maskedDraftIDs: Set<UUID>,
    universeSourceRevision: UInt64? = nil
  ) {
    let shouldEvaluateUniverse =
      universeSourceRevision == nil
      || universeFolderProjection == nil
      || universeFolderProjectionSourceRevision != universeSourceRevision
      || universeFolderProjectionKey?.profileID != profile.id
      || universeFolderProjectionKey?.contentScope != contentScope
      || universeFolderProjectionKey?.contentRoot != profile.contentRoot
      || universeFolderProjectionKey?.markdownPathPattern != profile.markdownPathPattern
      || universeFolderProjectionKey?.sortOrderRawValue != sortOrder.rawValue
    if shouldEvaluateUniverse {
      let universeKey = WritingDraftFolderProjectionCacheKey(
        profileID: profile.id,
        contentScope: contentScope,
        contentRoot: profile.contentRoot,
        markdownPathPattern: profile.markdownPathPattern,
        sortOrderRawValue: sortOrder.rawValue,
        draftSignatures: Self.folderProjectionSignatures(
          for: universeDrafts,
          profile: profile,
          contentScope: contentScope,
          sortOrder: sortOrder,
          maskedDraftIDs: maskedDraftIDs
        )
      )
      if universeFolderProjectionKey != universeKey {
        universeFolderProjection = DraftFolderProjection(
          profile: profile,
          drafts: universeDrafts,
          contentScope: contentScope,
          sortOrder: sortOrder,
          maskedDraftIDs: maskedDraftIDs
        )
        universeFolderProjectionKey = universeKey
        folderProjectionBuildCount += 1
      }
      universeFolderProjectionSourceRevision = universeSourceRevision
    }

    let filteredKey = WritingDraftFilteredFolderProjectionCacheKey(
      profileID: profile.id,
      contentScope: contentScope,
      contentRoot: profile.contentRoot,
      markdownPathPattern: profile.markdownPathPattern,
      sortOrderRawValue: sortOrder.rawValue,
      draftSignatures: Self.folderProjectionSignatures(
        for: filteredDrafts,
        profile: profile,
        contentScope: contentScope,
        sortOrder: sortOrder,
        maskedDraftIDs: maskedDraftIDs
      )
    )
    if filteredFolderProjectionKey != filteredKey {
      filteredFolderProjection = DraftFolderProjection(
        profile: profile,
        drafts: filteredDrafts,
        contentScope: contentScope,
        sortOrder: sortOrder,
        maskedDraftIDs: maskedDraftIDs
      )
      filteredFolderProjectionKey = filteredKey
      folderProjectionBuildCount += 1
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


  /// Reconciles only rows that can be rendered in the current page. The key is
  /// intentionally cheap (and excludes body text), so body-only edits can keep
  /// an existing presentation without rescanning the markdown for every row.
  mutating func updateRowPresentations(
    sourceDrafts: [ArticleDraft],
    visibleDrafts: ArraySlice<ArticleDraft>,
    profileFor: (ArticleDraft) -> SiteProfile,
    displayFor: (ArticleDraft) -> PrivateContentDisplay,
    attentionFor: (ArticleDraft) -> WritingDraftRowAttention = { _ in .none }
  ) {
    updateRowPresentations(
      sourceDraftIDs: Set(sourceDrafts.map(\.id)),
      visibleDrafts: visibleDrafts,
      profileFor: profileFor,
      displayFor: displayFor,
      attentionFor: attentionFor
    )
  }

  mutating func updateRowPresentations(
    sourceDraftIDs: Set<UUID>,
    visibleDrafts: ArraySlice<ArticleDraft>,
    profileFor: (ArticleDraft) -> SiteProfile,
    displayFor: (ArticleDraft) -> PrivateContentDisplay,
    attentionFor: (ArticleDraft) -> WritingDraftRowAttention = { _ in .none }
  ) {
    let sourceIDs = sourceDraftIDs
    rowPresentations = rowPresentations.filter { sourceIDs.contains($0.key) }
    rowPresentationKeys = rowPresentationKeys.filter { sourceIDs.contains($0.key) }

    for draft in visibleDrafts {
      let profile = profileFor(draft)
      let display = displayFor(draft)
      let attention = attentionFor(draft)
      let key = WritingDraftRowPresentationCacheKey(
        draft: draft,
        profile: profile,
        display: display,
        attention: attention
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
        display: display,
        attention: attention
      )
      rowPresentationBuildCount += 1
    }
  }

  private static func folderProjectionSignatures(
    for drafts: [ArticleDraft],
    profile: SiteProfile,
    contentScope: DraftListContentScope,
    sortOrder: DraftListSortOrder,
    maskedDraftIDs: Set<UUID>
  ) -> [WritingDraftFolderProjectionDraftSignature] {
    drafts
      .map { draft in
        WritingDraftFolderProjectionDraftSignature(
          draft: draft,
          profile: profile,
          contentScope: contentScope,
          isMasked: maskedDraftIDs.contains(draft.id),
          sortOrder: sortOrder
        )
      }
      .sorted { lhs, rhs in
        lhs.id.uuidString < rhs.id.uuidString
      }
  }
}
