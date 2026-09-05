import Foundation
import PublishingWorkbenchCore
import SwiftUI

enum WorkspaceQuickSearchScope: Equatable {
  case recent
  case imageResources
  case aiFixes
}

/// The command palette is the one search entry point.  These scopes only
/// select local presentation data; they do not change draft indexing or send
/// a query to an AI/provider.
enum WorkspaceUnifiedSearchScope: String, CaseIterable, Identifiable, Sendable {
  case all
  case articles
  case resources
  case rss
  case settings
  case commands

  var id: String { rawValue }

  var title: String {
    switch self {
    case .all: String(localized: "全部")
    case .articles: String(localized: "文章")
    case .resources: String(localized: "资料")
    case .rss: "RSS"
    case .settings: String(localized: "设置")
    case .commands: String(localized: "命令")
    }
  }

  var includesCommands: Bool { self == .all || self == .commands }
  var includesArticles: Bool { self == .all || self == .articles }
  var includesResources: Bool { self == .all || self == .resources }
  var includesRSS: Bool { self == .all || self == .rss }
  var includesSettings: Bool { self == .all || self == .settings }
}

enum WorkspaceUnifiedSearchPresentation {
  static let recentItemLimit = 6

  static func matchingSettings(
    query: String,
    recentItemIDs: [String] = []
  ) -> [SettingsSearchItem] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else {
      let byID = Dictionary(uniqueKeysWithValues: SettingsSearchIndex.allItems.map { ($0.id, $0) })
      let recent = recentItemIDs.compactMap { byID[$0] }
      let fallback = SettingsSearchIndex.allItems.filter { item in
        !recentItemIDs.contains(item.id)
      }
      return Array((recent + fallback).prefix(recentItemLimit))
    }
    return SettingsSearchIndex.search(query: normalized)
  }

  static func matchingSections(
    _ sections: [WorkspaceSection],
    query: String,
    scope: WorkspaceUnifiedSearchScope
  ) -> [WorkspaceSection] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return sections.filter { section in
      let isInScope: Bool
      switch section {
      case .library, .images, .siteStarter:
        isInScope = scope.includesResources
      case .rss:
        isInScope = scope.includesRSS
      case .writing, .sync, .contentHealth:
        isInScope = scope.includesCommands
      }
      guard isInScope else { return false }
      return normalized.isEmpty
        || workspaceNavigationLocalizedString(section.displayNameLocalizationKey)
          .localizedStandardContains(normalized)
        || section.rawValue.localizedStandardContains(normalized)
    }
  }
}

enum WorkspaceQuickSearchPresentation {
  static let recentResultLimit = 3
  static let searchResultLimit = 40

  static func resultSectionTitle(query: String, scope: WorkspaceQuickSearchScope) -> String {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalizedQuery.isEmpty else { return "搜索结果" }
    switch scope {
    case .recent:
      return "最近变更"
    case .imageResources:
      return "图片资源"
    case .aiFixes:
      return String(localized: "AI 可修复")
    }
  }

  static func scopedDrafts(
    _ drafts: [ArticleDraft],
    includedDraftIDs: Set<UUID>?
  ) -> [ArticleDraft] {
    guard let includedDraftIDs else { return drafts }
    return drafts.filter { includedDraftIDs.contains($0.id) }
  }

  static func matchingDrafts(
    drafts: [ArticleDraft],
    query: String,
    preferredDraftIDs: [UUID]? = nil,
    matches: (ArticleDraft, String) -> Bool
  ) -> [ArticleDraft] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let orderedDrafts: [ArticleDraft]
    if let preferredDraftIDs {
      var draftByID: [UUID: ArticleDraft] = [:]
      for draft in drafts where draftByID[draft.id] == nil {
        draftByID[draft.id] = draft
      }
      orderedDrafts = preferredDraftIDs.compactMap { draftByID[$0] }
    } else {
      orderedDrafts = drafts.sorted { lhs, rhs in
        if lhs.metadataUpdatedAt == rhs.metadataUpdatedAt {
          return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.metadataUpdatedAt > rhs.metadataUpdatedAt
      }
    }
    guard !normalizedQuery.isEmpty else { return orderedDrafts }
    return orderedDrafts.filter { matches($0, normalizedQuery) }
  }

  static func visibleDrafts(from matches: [ArticleDraft], query: String) -> [ArticleDraft] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let limit = normalizedQuery.isEmpty ? recentResultLimit : searchResultLimit
    return Array(matches.prefix(limit))
  }
}

struct WorkspaceQuickSearchSnapshot {
  let matchingDrafts: [ArticleDraft]
  let visibleDrafts: [ArticleDraft]

  var isEmpty: Bool { matchingDrafts.isEmpty }
}

struct WorkspaceQuickSearchView: View {
  let store: WorkbenchStore
  let scope: WorkspaceQuickSearchScope
  @ObservedObject private var contentHealthSidebarProjection: ContentHealthSidebarProjection
  private let contentHealthFilter: Binding<ContentHealthContextFilter>?
  private let imageWorkbenchContextStage: Binding<ImageWorkbenchContextStage>?
  private let repositoryContextStage: Binding<RepositoryContextStage>?
  @ObservedObject private var draftListState: DraftListStore
  @State private var query = ""
  @FocusState private var isSearchFocused: Bool

  init(
    store: WorkbenchStore,
    scope: WorkspaceQuickSearchScope,
    contentHealthSidebarProjection: ContentHealthSidebarProjection,
    contentHealthFilter: Binding<ContentHealthContextFilter>? = nil,
    imageWorkbenchContextStage: Binding<ImageWorkbenchContextStage>? = nil,
    repositoryContextStage: Binding<RepositoryContextStage>? = nil
  ) {
    self.store = store
    self.scope = scope
    _contentHealthSidebarProjection = ObservedObject(
      wrappedValue: contentHealthSidebarProjection
    )
    self.contentHealthFilter = contentHealthFilter
    self.imageWorkbenchContextStage = imageWorkbenchContextStage
    self.repositoryContextStage = repositoryContextStage
    _draftListState = ObservedObject(wrappedValue: store.draftList)
  }

  var body: some View {
    VStack(spacing: 0) {
      if scope != .imageResources {
        searchField
          .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
          .padding(.vertical, WorkspaceSidebarMetrics.toolbarVerticalPadding)
      }

      if let repositoryContextStage {
        repositoryStageNavigation(repositoryContextStage)
          .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
          .padding(.bottom, WorkspaceSidebarMetrics.toolbarVerticalPadding)
      } else if let imageWorkbenchContextStage {
        imageStageNavigation(imageWorkbenchContextStage)
          .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
          .padding(.bottom, WorkspaceSidebarMetrics.toolbarVerticalPadding)
      } else if let contentHealthFilter {
        contentHealthNavigation(contentHealthFilter)
          .padding(.horizontal, WorkspaceSidebarMetrics.horizontalPadding)
          .padding(.bottom, WorkspaceSidebarMetrics.toolbarVerticalPadding)
      }

      Divider()

      if scope == .imageResources {
        imageResourceState
      } else {
        searchResultsContent(searchSnapshot)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("workspace-quick-search")
  }

  private func repositoryStageNavigation(
    _ stage: Binding<RepositoryContextStage>
  ) -> some View {
    VStack(spacing: 5) {
      ForEach(RepositoryContextStage.navigationStages) { item in
        repositoryStageButton(item, stage: stage)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("仓库与发布页面")
    .accessibilityValue(stage.wrappedValue.primaryNavigationStage.accessibilityTitle)
    .accessibilityIdentifier("repository-sidebar-stage-navigation")
  }

  private func repositoryStageButton(
    _ item: RepositoryContextStage,
    stage: Binding<RepositoryContextStage>
  ) -> some View {
    let isSelected = stage.wrappedValue.primaryNavigationStage == item
    let isDisabled = item.requiresRepository && !hasSelectedRepository

    return sidebarStageButton(
      title: item.title,
      systemImage: repositoryStageSystemImage(item),
      isSelected: isSelected,
      isDisabled: isDisabled,
      help: item.accessibilityTitle,
      identifier: "repository-sidebar-stage-\(item.rawValue)"
    ) {
      stage.wrappedValue = item
    }
  }

  private func imageStageNavigation(
    _ stage: Binding<ImageWorkbenchContextStage>
  ) -> some View {
    VStack(spacing: 5) {
      ForEach(ImageWorkbenchContextStage.navigationStages) { item in
        sidebarStageButton(
          title: item.title,
          systemImage: item.systemImage,
          isSelected: stage.wrappedValue == item,
          help: item.accessibilityTitle,
          identifier: "image-sidebar-stage-\(item.rawValue)"
        ) {
          stage.wrappedValue = item
        }
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("图片工作台页面")
    .accessibilityValue(stage.wrappedValue.accessibilityTitle)
    .accessibilityIdentifier("image-sidebar-stage-navigation")
  }

  private func contentHealthNavigation(
    _ filter: Binding<ContentHealthContextFilter>
  ) -> some View {
    VStack(spacing: 5) {
      ForEach(ContentHealthContextFilter.navigationFilters) { item in
        sidebarStageButton(
          title: item.title,
          systemImage: item.systemImage,
          isSelected: filter.wrappedValue == item,
          help: item.accessibilityTitle,
          identifier: "content-health-sidebar-stage-\(item.rawValue)"
        ) {
          filter.wrappedValue = item
        }
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("内容健康页面")
    .accessibilityValue(filter.wrappedValue.accessibilityTitle)
    .accessibilityIdentifier("content-health-sidebar-stage-navigation")
  }

  private func sidebarStageButton(
    title: LocalizedStringKey,
    systemImage: String,
    isSelected: Bool,
    isDisabled: Bool = false,
    help: String,
    identifier: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .frame(width: 16)
          .accessibilityHidden(true)

        Text(title)
          .font(.workbenchButtonLabel)
          .lineLimit(1)

        Spacer(minLength: 4)

        if isSelected {
          Image(systemName: "checkmark")
            .font(.caption.weight(.semibold))
            .accessibilityHidden(true)
        }
      }
      .foregroundStyle(isSelected ? WorkbenchTheme.navigationSelection : Color.primary)
      .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
      .padding(.horizontal, 10)
      .background {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .fill(
            isSelected
              ? AnyShapeStyle(
                WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.accentBackground)
              )
              : WorkbenchBackgroundStyle.control
          )
      }
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .strokeBorder(
            isSelected
              ? WorkbenchTheme.navigationSelection.opacity(0.30)
              : Color.primary.opacity(0.08),
            lineWidth: 1
          )
      }
      .contentShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .help(help)
    .accessibilityLabel(Text(title))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier(identifier)
  }

  private func repositoryStageSystemImage(_ stage: RepositoryContextStage) -> String {
    switch stage {
    case .overview:
      return "rectangle.grid.2x2"
    case .changes:
      return "arrow.left.arrow.right"
    case .history:
      return "clock.arrow.circlepath"
    case .source:
      return "chevron.left.forwardslash.chevron.right"
    }
  }

  private var hasSelectedRepository: Bool {
    !store.activeProfile.localRepositoryRootPath
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  private var searchField: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField("搜索当前站点文章", text: $query)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .onSubmit(openFirstResult)
        .accessibilityLabel("搜索当前站点文章")
        .accessibilityValue(query.nilIfEmpty ?? "未输入")
        .accessibilityIdentifier("workspace-quick-search-field")

      if !query.isEmpty {
        Button {
          query = ""
          isSearchFocused = true
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("清除搜索")
        .accessibilityLabel("清除搜索")
        .accessibilityIdentifier("workspace-quick-search-clear")
      }
    }
    .padding(.horizontal, 9)
    .frame(minHeight: 30)
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .overlay {
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
    }
  }

  @ViewBuilder
  private func searchResultsContent(_ snapshot: WorkspaceQuickSearchSnapshot) -> some View {
    if store.visibleDrafts.isEmpty {
      noArticlesState
    } else if scope == .aiFixes {
      switch contentHealthQueueState {
      case .loading:
        aiFixQueueLoadingState
      case .failed:
        aiFixQueueFailureState
      case .cancelled:
        aiFixQueueCancelledState
      case .ready:
        if snapshot.isEmpty {
          if normalizedQuery.isEmpty {
            noAIFixableArticlesState
          } else {
            noResultsState
          }
        } else {
          resultList(snapshot)
        }
      }
    } else if snapshot.isEmpty {
      noResultsState
    } else {
      resultList(snapshot)
    }
  }

  private var imageResourceState: some View {
    VStack(spacing: 10) {
      Image(systemName: "photo.stack")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("图片资源")
        .font(.workbenchItemTitle)
      Text("图片工作区只管理图片资源。文章缺图、无效引用、过大图片等问题请到“检查”处理。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, WorkbenchSpacing.page)
    .padding(.top, 28)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("image-resource-sidebar-state")
  }

  private func resultList(_ snapshot: WorkspaceQuickSearchSnapshot) -> some View {
    List {
      Section {
        ForEach(snapshot.visibleDrafts) { draft in
          resultRow(draft)
        }
      } header: {
        HStack(spacing: 8) {
          Text(LocalizedStringKey(resultSectionTitle))
          Spacer(minLength: 4)
          Text(resultCountLabel(for: snapshot))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .listStyle(.sidebar)
    .scrollContentBackground(.hidden)
    .accessibilityLabel("当前站点文章搜索结果")
    .accessibilityIdentifier("workspace-quick-search-results")
  }

  private func resultRow(_ draft: ArticleDraft) -> some View {
    let display = store.privateContentDisplay(for: draft)
    let title = display.title.nilIfEmpty ?? String(localized: "未命名文章")
    let detail =
      display.isMasked
      ? display.summary
      : (draft.slug.nilIfEmpty ?? display.summary)

    return Button {
      openDraft(draft.id)
    } label: {
      HStack(spacing: 9) {
        Image(systemName: draft.isPrivate ? "lock.doc" : "doc.text")
          .foregroundStyle(.secondary)
          .frame(width: 16)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.workbenchItemTitle)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if !detail.isEmpty {
            Text(detail)
              .font(.workbenchSupporting)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 4)

        Image(systemName: "chevron.right")
          .font(.workbenchMetadata.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("打开文章\(title)")
    .accessibilityLabel(title)
    .accessibilityHint("打开文章并进入写作页面")
    .accessibilityIdentifier("workspace-quick-search-draft-\(draft.id.uuidString)")
  }

  private var noArticlesState: some View {
    VStack(spacing: 10) {
      Image(systemName: "doc.badge.plus")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("当前站点还没有文章")
        .font(.workbenchItemTitle)
      Button {
        store.createDraft()
      } label: {
        Label("新建文章", systemImage: "plus")
      }
      .controlSize(.regular)
      .accessibilityIdentifier("workspace-quick-search-create-draft")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, 28)
  }

  private var noResultsState: some View {
    VStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("没有匹配的文章")
        .font(.workbenchItemTitle)
      Button("清除搜索") {
        query = ""
        isSearchFocused = true
      }
      .buttonStyle(.link)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.top, 28)
  }

  private var aiFixQueueLoadingState: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.small)
      Text("正在生成 AI 可修复队列")
        .font(.workbenchItemTitle)
      Text("内容健康快照完成后，这里只显示可由 AI 协助修复的文章。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, WorkbenchSpacing.page)
    .padding(.top, 28)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("content-health-sidebar-ai-fix-loading")
  }

  private var aiFixQueueFailureState: some View {
    VStack(spacing: 10) {
      Image(systemName: "exclamationmark.triangle")
        .font(.title2)
        .foregroundStyle(WorkbenchTheme.warning)
        .accessibilityHidden(true)
      Text("AI 可修复队列暂时不可用")
        .font(.workbenchItemTitle)
      Text("请在右侧重新检查内容健康快照。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, WorkbenchSpacing.page)
    .padding(.top, 28)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("content-health-sidebar-ai-fix-failure")
  }

  private var aiFixQueueCancelledState: some View {
    VStack(spacing: 10) {
      Image(systemName: "pause.circle")
        .font(.title2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Text("内容健康检查已取消")
        .font(.workbenchItemTitle)
      Text("请在内容健康页面点击“重新开始”，生成 AI 可修复队列。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, WorkbenchSpacing.page)
    .padding(.top, 28)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("content-health-sidebar-ai-fix-cancelled")
  }

  private var noAIFixableArticlesState: some View {
    VStack(spacing: 10) {
      Image(systemName: "checkmark.circle")
        .font(.title2)
        .foregroundStyle(WorkbenchTheme.success)
        .accessibilityHidden(true)
      Text("当前没有可由 AI 修复的文章")
        .font(.workbenchItemTitle)
      Text("当前站点的摘要、标签和 Front Matter 暂无可由 AI 协助修复的问题。")
        .font(.workbenchSupporting)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .padding(.horizontal, WorkbenchSpacing.page)
    .padding(.top, 28)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("content-health-sidebar-ai-fix-empty")
  }

  private var normalizedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var resultSectionTitle: String {
    WorkspaceQuickSearchPresentation.resultSectionTitle(
      query: normalizedQuery,
      scope: scope
    )
  }

  private var searchSnapshot: WorkspaceQuickSearchSnapshot {
    _ = draftListState.presentationRevision
    let index = draftListState.searchIndex(for: .activeSite)
    let matchingDrafts = index.matching(
      query: normalizedQuery,
      preferredDraftIDs: preferredDraftIDs
    ).filter { draft in
      (includedDraftIDs?.contains(draft.id) ?? true)
        && (normalizedQuery.isEmpty
          || store.matchesPrivacyProtectedDraftSearch(
            draft,
            query: normalizedQuery,
            profile: store.activeProfile
          ))
    }
    let visibleDrafts = WorkspaceQuickSearchPresentation.visibleDrafts(
      from: matchingDrafts,
      query: normalizedQuery
    )
    return WorkspaceQuickSearchSnapshot(
      matchingDrafts: matchingDrafts,
      visibleDrafts: visibleDrafts
    )
  }

  private var includedDraftIDs: Set<UUID>? {
    switch scope {
    case .recent:
      return nil
    case .imageResources:
      return []
    case .aiFixes:
      switch contentHealthQueueState {
      case .ready(let orderedDraftIDs):
        return Set(orderedDraftIDs)
      case .loading, .failed, .cancelled:
        return []
      }
    }
  }

  private var preferredDraftIDs: [UUID]? {
    guard scope == .aiFixes,
      case .ready(let orderedDraftIDs) = contentHealthQueueState
    else {
      return nil
    }
    return orderedDraftIDs
  }

  private var contentHealthQueueState: ContentHealthSidebarProjection.QueueState {
    contentHealthSidebarProjection.queueState(for: store.activeProfile.id)
  }

  private func resultCountLabel(for snapshot: WorkspaceQuickSearchSnapshot) -> String {
    let count = snapshot.matchingDrafts.count
    let limit =
      normalizedQuery.isEmpty
      ? WorkspaceQuickSearchPresentation.recentResultLimit
      : WorkspaceQuickSearchPresentation.searchResultLimit
    return count > limit ? "\(limit)+" : "\(count)"
  }

  private func openFirstResult() {
    guard let draftID = searchSnapshot.visibleDrafts.first?.id else { return }
    openDraft(draftID)
  }

  private func openDraft(_ draftID: UUID) {
    _ = store.focusDraft(draftID, section: .writing)
  }
}
