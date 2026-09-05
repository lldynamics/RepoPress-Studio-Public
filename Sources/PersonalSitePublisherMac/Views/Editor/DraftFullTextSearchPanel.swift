import PublishingWorkbenchCore
import SwiftUI

struct DraftFullTextSearchPanel: View {
  @Environment(\.dismiss) private var dismiss
  @AppStorage("draftFullTextSavedQueriesV1") private var savedQueriesStorage = ""
  @ObservedObject private var publishing: WorkbenchPublishingFeatureFacade
  let store: WorkbenchStore
  @State private var query = ""
  @State private var scope = DraftFullTextSearchScope.currentSite
  @State private var searchSnapshot = DraftFullTextSearchPresentationSnapshot.empty
  @State private var isSearching = false
  @State private var protectedPrivateDraftCount = 0
  @State private var searchTask: Task<Void, Never>?
  @State private var savedQueries: [DraftFullTextSavedQuery] = []
  @State private var selectedHitID: DraftFullTextSearchHitID?
  @State private var isBatchReplacePresented = false
  @FocusState private var isSearchFocused: Bool

  init(store: WorkbenchStore) {
    self.store = store
    _publishing = ObservedObject(wrappedValue: store.publishing)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        searchField
        Divider()
        searchScopeBar
        Divider()
        searchContent
        Divider()
        sheetActionBar
      }
      .navigationTitle("跨文章全文搜索")
    }
    .frame(minWidth: 720, idealWidth: 820, minHeight: 540, idealHeight: 640)
    .onAppear {
      loadSavedQueries()
      isSearchFocused = true
      scheduleSearch()
    }
    .onChange(of: query) { _, _ in
      scheduleSearch()
    }
    .onChange(of: scope) { _, _ in
      scheduleSearch(immediately: true)
    }
    .onChange(of: publishing.drafts) { _, _ in
      scheduleSearch(immediately: true)
    }
    .onChange(of: searchSnapshot) { _, _ in
      synchronizeSelection()
    }
    .onDisappear {
      searchTask?.cancel()
      searchTask = nil
    }
    .onKeyPress(.downArrow) {
      moveSelection(by: 1)
      return .handled
    }
    .onKeyPress(.upArrow) {
      moveSelection(by: -1)
      return .handled
    }
    .onExitCommand {
      dismiss()
    }
    .sheet(isPresented: $isBatchReplacePresented) {
      MarkdownBatchFindReplacePanel(
        store: store,
        siteProfileID: scope == .currentSite ? publishing.activeProfileID : nil
      )
    }
    .accessibilityLabel("跨文章全文搜索")
    .accessibilityIdentifier("draft-full-text-search-panel")
  }

  private var searchField: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass")
          .foregroundStyle(.secondary)

        TextField("搜索文章或输入结构化条件", text: $query)
          .textFieldStyle(.plain)
          .font(.title3)
          .focused($isSearchFocused)
          .accessibilityLabel("搜索文章或输入结构化条件")
          .onSubmit(openSelectedResult)

        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
          .help("清除全文搜索")
          .accessibilityLabel("清除全文搜索")
        }

        Text(verbatim: "⌥⌘F")
          .font(.caption.monospaced())
          .foregroundStyle(.tertiary)
      }

      if parsedQuery.invalidFilters.isEmpty {
        Text("支持 title:、tag:、status:、before:、after:、is:private；日期按文章日期。")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        Label(
          "无法识别的搜索条件：\(parsedQuery.invalidFilters.joined(separator: "、"))",
          systemImage: "exclamationmark.triangle"
        )
        .font(.caption)
        .foregroundStyle(WorkbenchTheme.warning)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }

  private var searchScopeBar: some View {
    HStack(spacing: 12) {
      Picker("搜索范围", selection: $scope) {
        ForEach(DraftFullTextSearchScope.allCases) { candidate in
          Text(candidate.localizedDisplayName).tag(candidate)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 250)
      .accessibilityLabel("全文搜索范围")

      savedQueriesMenu

      Button {
        isBatchReplacePresented = true
      } label: {
        Label("批量替换", systemImage: "arrow.triangle.2.circlepath")
      }
      .help("预览并安全替换多篇文章的正文")
      .accessibilityLabel("跨文章批量查找替换")

      Spacer()

      if protectedPrivateDraftCount > 0 {
        Label {
          Text("\(protectedPrivateDraftCount) 篇私密文章仅搜索标题")
        } icon: {
          Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      if !normalizedQuery.isEmpty {
        Text("\(searchSnapshot.displayedHits.count) 个匹配")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .accessibilityLabel("找到 \(searchSnapshot.displayedHits.count) 个匹配")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var searchContent: some View {
    if normalizedQuery.isEmpty {
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(kind: .empty),
        detail: "输入关键词搜索文章。搜索标题、摘要、正文和元数据，或组合结构化条件；保存的查询可在搜索范围旁重新载入。"
      )
    } else if isSearching && searchSnapshot.displayedHits.isEmpty {
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(
          kind: .loading(detail: String(localized: "正在搜索…"))
        )
      )
    } else if searchSnapshot.groups.isEmpty {
      WorkbenchStateView(
        presentation: WorkbenchStatePresentation(kind: .empty),
        detail: "请清除部分条件，或将搜索范围扩大到全部站点。",
        actions: WorkbenchStateActions(
          primary: WorkbenchStateAction(
            title: "清除条件",
            systemImage: "xmark.circle",
            action: clearSearchConditions
          ),
          secondary: WorkbenchStateAction(
            title: "搜索全部站点",
            systemImage: "globe",
            isEnabled: scope != .allSites,
            action: searchAllSites
          )
        )
      )
    } else {
      ScrollViewReader { proxy in
        List {
          ForEach(searchSnapshot.groups) { group in
            Section {
              ForEach(group.hits) { hit in
                Button {
                  selectedHitID = hit.id
                  open(hit)
                } label: {
                  searchResultRow(hit)
                }
                .buttonStyle(.plain)
                .id(hit.id)
                .listRowBackground(
                  selectedHitID == hit.id
                    ? WorkbenchTheme.primary.opacity(0.14)
                    : Color.clear
                )
                .accessibilityAddTraits(selectedHitID == hit.id ? .isSelected : [])
                .accessibilityHint("打开文章并定位到匹配内容")
                .onHover { isHovering in
                  if isHovering { selectedHitID = hit.id }
                }
              }
            } header: {
              searchResultHeader(group)
            }
          }
        }
        .listStyle(.inset)
        .onChange(of: selectedHitID) { _, hitID in
          guard let hitID else { return }
          proxy.scrollTo(hitID, anchor: .center)
        }
      }
    }
  }

  private var sheetActionBar: some View {
    HStack {
      Button("取消") { dismiss() }
        .keyboardShortcut(.cancelAction)

      Spacer()

      if let selectedHit {
        let selectionLabel = "已选择：\(selectedHit.draftTitle.nilIfEmpty ?? String(localized: "未命名文章"))"
        Text(selectionLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(selectionLabel)
      }

      Button {
        openSelectedResult()
      } label: {
        Label("打开所选结果", systemImage: "arrow.right.circle.fill")
      }
      .workbenchProminentActionStyle()
      .keyboardShortcut(.defaultAction)
      .disabled(selectedHit == nil)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func searchResultHeader(_ group: DraftFullTextSearchGroup) -> some View {
    let groupTitle = group.title.nilIfEmpty ?? String(localized: "未命名文章")
    return HStack(spacing: 8) {
      Image(systemName: group.draftID == publishing.selectedDraftID ? "doc.text.fill" : "doc.text")
      Text(groupTitle)
        .fontWeight(.semibold)
        .workbenchTruncatedIdentity(groupTitle)
      if let profileName = profileName(for: group.siteProfileID) {
        Text(profileName)
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(profileName)
      }
      Spacer()
      Text("\(group.hits.count) 处")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }

  private func searchResultRow(_ hit: DraftFullTextSearchHit) -> some View {
    HStack(alignment: .top, spacing: 11) {
      Image(systemName: hit.field.systemImage)
        .foregroundStyle(WorkbenchTheme.primary)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 4) {
        Text(hit.field.localizedDisplayName)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)

        (
          Text(hit.snippetPrefix)
          + Text(hit.matchedText)
            .bold()
            .foregroundColor(WorkbenchTheme.primary)
          + Text(hit.snippetSuffix)
        )
        .font(.callout)
        .foregroundStyle(.primary)
        .lineLimit(3)
        .multilineTextAlignment(.leading)
      }

      Spacer(minLength: 12)

      Image(systemName: "arrow.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.top, 5)
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
  }

  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var parsedQuery: DraftFullTextSearchQuery {
    DraftFullTextSearchService().parse(query: normalizedQuery)
  }

  private var selectedHit: DraftFullTextSearchHit? {
    guard let selectedHitID else { return nil }
    return searchSnapshot.hit(withID: selectedHitID)
  }

  private var savedQueriesMenu: some View {
    Menu {
      if savedQueries.isEmpty {
        Text("尚未保存查询")
      } else {
        ForEach(savedQueries) { savedQuery in
          Button {
            apply(savedQuery)
          } label: {
            Label(
              savedQuery.query,
              systemImage: savedQuery.searchesAllSites ? "rectangle.3.group" : "doc.text"
            )
          }
        }
      }

      Divider()

      Button {
        saveCurrentQuery()
      } label: {
        Label("保存当前查询", systemImage: "bookmark")
      }
      .disabled(!parsedQuery.hasCriteria)

      if !savedQueries.isEmpty {
        Menu("删除保存的查询") {
          ForEach(savedQueries) { savedQuery in
            Button(role: .destructive) {
              delete(savedQuery)
            } label: {
              Label(savedQuery.query, systemImage: "trash")
            }
          }
        }
      }
    } label: {
      Label("保存的查询", systemImage: "bookmark")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("保存、载入或删除全文搜索查询")
    .accessibilityLabel("保存的全文搜索查询")
  }

  private func profileName(for profileID: UUID) -> String? {
    guard scope == .allSites else { return nil }
    return publishing.profiles.first { $0.id == profileID }?.name
  }

  private func loadSavedQueries() {
    savedQueries = DraftFullTextSavedQueryService.decode(savedQueriesStorage)
  }

  private func saveCurrentQuery() {
    savedQueries = DraftFullTextSavedQueryService.saving(
      query: normalizedQuery,
      searchesAllSites: scope == .allSites,
      in: savedQueries
    )
    persistSavedQueries()
  }

  private func apply(_ savedQuery: DraftFullTextSavedQuery) {
    query = savedQuery.query
    scope = savedQuery.searchesAllSites ? .allSites : .currentSite
    isSearchFocused = true
  }

  private func delete(_ savedQuery: DraftFullTextSavedQuery) {
    savedQueries = DraftFullTextSavedQueryService.removing(
      id: savedQuery.id,
      from: savedQueries
    )
    persistSavedQueries()
  }

  private func persistSavedQueries() {
    savedQueriesStorage = DraftFullTextSavedQueryService.encode(savedQueries)
  }

  private func scheduleSearch(immediately: Bool = false) {
    searchTask?.cancel()
    let requestedQuery = normalizedQuery
    guard !requestedQuery.isEmpty else {
      searchSnapshot = .empty
      selectedHitID = nil
      protectedPrivateDraftCount = 0
      isSearching = false
      return
    }

    let scopedDrafts = publishing.drafts.filter { draft in
      scope == .allSites
        ? !draft.isGeneralDraft
        : draft.belongs(toSiteProfileID: publishing.activeProfileID)
    }
    let privacyMasksPrivateContent = store.privacySettings.masksPrivateContent
    protectedPrivateDraftCount =
      privacyMasksPrivateContent
      ? scopedDrafts.count(where: \.isPrivate)
      : 0
    // Capture the actor-owned editor buffers once, then perform the expensive
    // draft copying and privacy projection in the detached worker below.
    let searchInputs = scopedDrafts.map { draft in
      DraftFullTextSearchInput(
        draft: draft,
        bodyMarkdown: publishing.draftBodyEditorBuffer(for: draft.id).bodyMarkdown
      )
    }
    searchSnapshot = .empty
    selectedHitID = nil
    isSearching = true
    let requestedScope = scope

    searchTask = Task { @MainActor in
      if !immediately {
        try? await Task.sleep(for: .milliseconds(140))
      }
      guard !Task.isCancelled else { return }
      let searchWorker = Task.detached(priority: .userInitiated) {
        let searchableDrafts = DraftFullTextSearchPreparation.prepare(
          inputs: searchInputs,
          masksPrivateContent: privacyMasksPrivateContent
        )
        let matches = DraftFullTextSearchService().search(
          query: requestedQuery,
          drafts: searchableDrafts
        )
        return DraftFullTextSearchPresentationSnapshot(hits: matches)
      }
      let snapshot = await withTaskCancellationHandler(
        operation: { await searchWorker.value },
        onCancel: { searchWorker.cancel() }
      )
      guard !Task.isCancelled,
            normalizedQuery == requestedQuery,
            scope == requestedScope else {
        return
      }
      searchSnapshot = snapshot
      isSearching = false
    }
  }

  private func synchronizeSelection() {
    if let selectedHitID, searchSnapshot.hit(withID: selectedHitID) != nil {
      return
    }
    selectedHitID = searchSnapshot.displayedHits.first?.id
  }

  private func moveSelection(by offset: Int) {
    let hits = searchSnapshot.displayedHits
    guard !hits.isEmpty else { return }
    guard let selectedHitID,
          let currentIndex = searchSnapshot.index(of: selectedHitID) else {
      self.selectedHitID = offset < 0 ? hits.last?.id : hits.first?.id
      return
    }
    let nextIndex = min(max(currentIndex + offset, hits.startIndex), hits.index(before: hits.endIndex))
    self.selectedHitID = hits[nextIndex].id
  }

  private func openSelectedResult() {
    guard let selectedHit else { return }
    open(selectedHit)
  }

  private func clearSearchConditions() {
    query = ""
    isSearchFocused = true
  }

  private func searchAllSites() {
    scope = .allSites
    isSearchFocused = true
  }

  private func open(_ hit: DraftFullTextSearchHit) {
    guard store.focusDraft(hit.draftID, section: .writing) else { return }
    store.requestEditorFocus(
      draftID: hit.draftID,
      field: hit.field.rawValue,
      query: hit.matchedText,
      selectedRange: hit.field == .body ? hit.sourceRange : nil
    )
    dismiss()
  }
}

struct DraftFullTextSearchInput: Sendable {
  let draft: ArticleDraft
  let bodyMarkdown: String
}

enum DraftFullTextSearchPreparation {
  static func prepare(
    inputs: [DraftFullTextSearchInput],
    masksPrivateContent: Bool
  ) -> [ArticleDraft] {
    inputs.map { input in
      var draft = input.draft
      draft.bodyMarkdown = input.bodyMarkdown
      guard masksPrivateContent, draft.isPrivate else { return draft }
      draft.slug = ""
      draft.summary = ""
      draft.bodyMarkdown = ""
      draft.tags = []
      draft.categories = []
      draft.authors = []
      draft.detachFromRepository()
      return draft
    }
  }
}

private enum DraftFullTextSearchScope: String, CaseIterable, Identifiable {
  case currentSite
  case allSites

  var id: String { rawValue }

  var localizedDisplayName: String {
    switch self {
    case .currentSite: String(localized: "当前站点")
    case .allSites: String(localized: "全部站点")
    }
  }
}

struct DraftFullTextSearchGroup: Identifiable, Equatable, Sendable {
  var id: UUID { draftID }
  let draftID: UUID
  let siteProfileID: UUID
  let title: String
  var hits: [DraftFullTextSearchHit]
}

/// A single linear projection of search hits into the grouped and keyboard-
/// navigable forms consumed by the panel. Keeping it in state avoids rebuilding
/// groups and repeatedly flattening them on every SwiftUI body evaluation.
struct DraftFullTextSearchPresentationSnapshot: Equatable, Sendable {
  static let empty = DraftFullTextSearchPresentationSnapshot(hits: [])

  let groups: [DraftFullTextSearchGroup]
  let displayedHits: [DraftFullTextSearchHit]
  private let displayedIndexByID: [DraftFullTextSearchHitID: Int]

  init(hits: [DraftFullTextSearchHit]) {
    var groups: [DraftFullTextSearchGroup] = []
    var groupIndexByDraftID: [UUID: Int] = [:]
    groupIndexByDraftID.reserveCapacity(hits.count)

    for hit in hits {
      if let index = groupIndexByDraftID[hit.draftID] {
        groups[index].hits.append(hit)
      } else {
        groupIndexByDraftID[hit.draftID] = groups.count
        groups.append(
          DraftFullTextSearchGroup(
            draftID: hit.draftID,
            siteProfileID: hit.siteProfileID,
            title: hit.draftTitle,
            hits: [hit]
          )
        )
      }
    }

    let displayedHits = groups.flatMap(\.hits)
    var displayedIndexByID: [DraftFullTextSearchHitID: Int] = [:]
    displayedIndexByID.reserveCapacity(displayedHits.count)
    for (index, hit) in displayedHits.enumerated() {
      displayedIndexByID[hit.id] = index
    }

    self.groups = groups
    self.displayedHits = displayedHits
    self.displayedIndexByID = displayedIndexByID
  }

  func hit(withID id: DraftFullTextSearchHitID) -> DraftFullTextSearchHit? {
    guard let index = displayedIndexByID[id] else { return nil }
    return displayedHits[index]
  }

  func index(of id: DraftFullTextSearchHitID) -> Int? {
    displayedIndexByID[id]
  }
}

private extension DraftFullTextSearchField {
  var localizedDisplayName: String {
    switch self {
    case .title: String(localized: "标题")
    case .summary: String(localized: "摘要")
    case .body: String(localized: "正文")
    case .slug: "Slug"
    case .tags: String(localized: "标签")
    case .categories: String(localized: "分类")
    case .authors: String(localized: "作者")
    case .repositoryPath: String(localized: "仓库路径")
    }
  }

  var systemImage: String {
    switch self {
    case .title: "textformat"
    case .summary: "text.alignleft"
    case .body: "doc.text"
    case .slug: "link"
    case .tags: "tag"
    case .categories: "folder"
    case .authors: "person.2"
    case .repositoryPath: "point.topleft.down.to.point.bottomright.curvepath"
    }
  }
}
