import AppKit
import PublishingCoreSupport
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

enum ArticleInspectorTab: String, CaseIterable, Identifiable {
  case knowledge
  case metadata
  case seo
  case images
  case checks

  var id: String { rawValue }

  var title: String {
    switch self {
    case .knowledge:
      return String(localized: "上下文知识建议")
    case .metadata:
      return String(localized: "元数据")
    case .seo:
      return "SEO"
    case .images:
      return String(localized: "图片")
    case .checks:
      return String(localized: "检查")
    }
  }

  var systemImage: String {
    switch self {
    case .knowledge:
      return "books.vertical"
    case .metadata:
      return "slider.horizontal.3"
    case .seo:
      return "chart.bar.doc.horizontal"
    case .images:
      return "photo.on.rectangle"
    case .checks:
      return "checklist"
    }
  }

  var pickerTitle: String {
    switch self {
    case .knowledge:
      return String(localized: "知识建议")
    case .metadata, .seo, .images, .checks:
      return title
    }
  }

  static func defaultTab(for section: WorkspaceSection) -> ArticleInspectorTab {
    switch section {
    case .writing:
      return .metadata
    case .sync:
      return .metadata
    case .contentHealth:
      return .checks
    case .images:
      return .images
    case .library, .rss:
      return .metadata
    }
  }

  static func availableTabs(for section: WorkspaceSection) -> [ArticleInspectorTab] {
    switch section {
    case .writing:
      return [.metadata, .seo, .images, .knowledge]
    case .contentHealth:
      return [.checks]
    case .images:
      return [.images]
    case .sync, .library, .rss:
      return []
    }
  }
}

extension PreflightIssue {
  var editorQuery: String? {
    guard structuredField == .body,
          category == .unregisteredBodyImage
    else {
      return nil
    }
    return relatedValue
  }
}

struct ArticleInspectorTabs: View {
  @WorkspaceModuleVisibilityStorage private var moduleVisibility
  @Environment(\.workbenchAccentColor) private var workbenchAccentColor
  @Environment(\.publishReadinessNavigationRequest) private var publishNavigationRequest

  @Binding var selectedTab: ArticleInspectorTab
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var rssStore: RSSReaderStore
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade
  let section: WorkspaceSection
  private let configuredTabs: [ArticleInspectorTab]
  @StateObject private var preflightModel = ArticleInspectorPreflightModel()
  @State private var manualRefreshGeneration = 0
  @State private var isManualPreflightRefresh = false

  private var availableTabs: [ArticleInspectorTab] {
    configuredTabs.filter {
      $0 != .knowledge || moduleVisibility.libraryEnabled || moduleVisibility.rssEnabled
    }
  }

  init(
    selectedTab: Binding<ArticleInspectorTab>,
    draft: Binding<ArticleDraft>,
    store: WorkbenchStore,
    rssStore: RSSReaderStore,
    section: WorkspaceSection,
    availableTabs: [ArticleInspectorTab]
  ) {
    _selectedTab = selectedTab
    _draft = draft
    self.store = store
    _rssStore = ObservedObject(wrappedValue: rssStore)
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
    self.section = section
    self.configuredTabs = availableTabs
  }

  private var preflightRequestKey: DraftScopedPreflightRequestKey? {
    store.draftScopedPreflightRequestKey(for: draft.id)
  }

  private var preflightTaskID: ArticleInspectorPreflightTaskID? {
    guard selectedTab == .checks, let key = preflightRequestKey else { return nil }
    return ArticleInspectorPreflightTaskID(key: key, generation: manualRefreshGeneration)
  }

  var body: some View {
    VStack(spacing: 0) {
      // With several tabs the picker is the header; the article path is
      // already shown in the editor breadcrumb.
      if availableTabs.count > 1 {
        tabPicker
        Divider()
      } else {
        header
        Divider()
      }

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            selectedContent
          }
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
          scrollToFocusedImage(using: proxy)
        }
        .onChange(of: imageWorkbench.imageInspectorFocusRequest?.id) { _, _ in
          scrollToFocusedImage(using: proxy)
        }
        .task(id: publishNavigationRequest?.id) {
          guard let request = publishNavigationRequest, request.draftID == draft.id,
            selectedTab == .metadata,
            case .metadata(let field) = request.target else { return }
          if field == "title" {
            store.requestEditorFocus(draftID: draft.id, field: "title")
            return
          }
          await Task.yield()
          guard !Task.isCancelled else { return }
          proxy.scrollTo(PublishMetadataFieldAnchor.id(for: field), anchor: .center)
        }
      }

    }
    .background(.bar)
    .accessibilityIdentifier("article-inspector")
    .accessibilityLabel("文章详情栏")
    .onAppear {
      normalizeSelectedTab()
      prepareSelectedTab()
    }
    .onChange(of: draft.id) { _, _ in
      normalizeSelectedTab()
      prepareSelectedTab()
    }
    .onChange(of: selectedTab) { _, _ in
      prepareSelectedTab()
    }
    .onChange(of: moduleVisibility) { _, _ in
      normalizeSelectedTab()
      prepareSelectedTab()
    }
    .task(id: imageRefreshID) {
      guard selectedTab == .images || selectedTab == .checks else { return }
      await store.refreshImageWorkbenchCachesInBackground(for: draft)
    }
    .task(id: preflightTaskID) {
      guard selectedTab == .checks,
        let key = preflightRequestKey
      else { return }
      let draftID = draft.id
      let debounceDuration =
        isManualPreflightRefresh ? nil : DebounceIntervals.preflightRefresh
      isManualPreflightRefresh = false
      await preflightModel.refresh(
        requestKey: key,
        draftID: draftID,
        debounceDuration: debounceDuration
      ) {
        let result = await store.runPreflight(for: draftID)
        guard !Task.isCancelled,
          draft.id == draftID,
          store.draftScopedPreflightRequestKey(for: draftID) == key
        else {
          return nil
        }
        return result
      }
    }
    .task(id: knowledgeRefreshID) {
      guard let draftID = knowledgeRefreshID else { return }
      store.knowledge.loadArticleBacklinks(for: draftID)
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: selectedTab.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text("文章详情栏")
          .font(.headline)
        let markdownPath = store.profile(for: draft).markdownPath(for: draft)
        Text(markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(markdownPath, lineLimit: 2)
      }

      Spacer()
    }
    .padding(14)
  }

  private var tabPicker: some View {
    Picker("详情栏", selection: $selectedTab) {
      ForEach(availableTabs) { tab in
        Label(tab.pickerTitle, systemImage: tab.systemImage)
          .tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .tint(workbenchAccentColor)
    .labelsHidden()
    .padding(10)
    .accessibilityLabel("文章详情栏标签")
    .accessibilityValue(selectedTab.title)
  }

  private func scrollToFocusedImage(using proxy: ScrollViewProxy) {
    guard selectedTab == .images,
          let request = imageWorkbench.imageInspectorFocusRequest,
          request.draftID == draft.id else {
      return
    }
    Task { @MainActor in
      await Task.yield()
      proxy.scrollTo(request.attachmentID, anchor: .center)
    }
  }

  @ViewBuilder
  private var selectedContent: some View {
    switch selectedTab {
    case .knowledge:
      if section == .writing {
        knowledgeContent
      }
    case .metadata:
      metadataContent
    case .seo:
      seoContent
    case .images:
      imageContent
    case .checks:
      checkContent
    }
  }

  private var knowledgeContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      if moduleVisibility.rssEnabled {
        RSSLibraryInspectorPanel(
          rssStore: rssStore,
          workbenchStore: store
        )
      }
      if moduleVisibility.libraryEnabled {
        KnowledgeContextRecommendationCard(
          draft: draft,
          store: store,
          onOpenSource: { result in
            store.knowledge.selectSearchResult(result)
            store.selectSection(.library)
          },
          onSearch: { query in
            store.knowledge.updateSearchText(query)
            store.selectSection(.library)
          }
        )
        KnowledgeArticleBacklinksSection(
          draft: draft,
          knowledge: store.knowledge,
          onOpenDocument: { documentID in
            store.knowledge.selectDocument(documentID)
            store.selectSection(.library)
          }
        )
      }
    }
    .accessibilityIdentifier("article-inspector-knowledge-page")
  }

  private var metadataContent: some View {
    WorkspaceTaskMetadataSection(
      draft: $draft,
      store: store,
      tagSuggestions: taxonomySuggestions(\.tags),
      categorySuggestions: taxonomySuggestions(\.categories)
    )
  }

  private func taxonomySuggestions(_ keyPath: KeyPath<ArticleDraft, [String]>) -> [String] {
    TaxonomySuggestionRanking.suggestions(
      selectedValues: draft[keyPath: keyPath],
      draftValues: store.drafts.map {
        (siteProfileID: $0.scope.siteProfileID, values: $0[keyPath: keyPath])
      },
      siteProfileID: store.profile(for: draft).id
    )
  }

  private var seoContent: some View {
    WorkspaceTaskSEOSection(draft: draft, store: store)
  }

  private var imageContent: some View {
    WorkspaceTaskImageSection(
      draft: $draft,
      state: WorkspaceTaskImageState(
        report: store.cachedImageWorkbenchReport(for: draft),
        actionMessage: store.imageActionMessage,
        focusedAttachmentID: imageWorkbench.imageInspectorFocusRequest.flatMap { request in
          request.draftID == draft.id ? request.attachmentID : nil
        }
      ),
      actions: WorkspaceTaskImageActions(
        fillMissingMetadataForCurrentDraft: {
          store.fillMissingImageMetadataForSelectedDraft()
        },
        optimizeJPEGForCurrentDraft: {
          store.optimizeSelectedDraftJPEGImages()
        },
        openImageWorkbench: {
          _ = store.focusDraft(draft.id, section: .images)
        },
        refreshReport: {
          store.scheduleImageWorkbenchCachesRefresh(force: true)
        }
      )
    )
  }

  private var checkContent: some View {
    Group {
      if let result = preflightModel.result,
        result.context.draftID == draft.id,
        result.context.profileID == store.profile(for: draft).id
      {
        VStack(alignment: .leading, spacing: 10) {
          if preflightModel.state == .loading {
            preflightLoadingIndicator
          } else if preflightModel.state == .unavailable {
            preflightUnavailableIndicator
          }
          checkContent(result: result)
        }
      } else {
        preflightUnavailableContent
      }
    }
  }

  @ViewBuilder
  private func checkContent(result: DraftPreflightResult) -> some View {
    let preflightIssues = result.issues
    let imageIssues =
      store.cachedImageWorkbenchReport(for: draft)?.issues
      .filter { !$0.isCovered(by: preflightIssues) }
      .compactMap(\.preflightIssue) ?? []
    let issues = (preflightIssues + imageIssues).sorted {
      if $0.severity.sortRank == $1.severity.sortRank {
        return $0.title < $1.title
      }
      return $0.severity.sortRank < $1.severity.sortRank
    }
    let deploymentRecord = store.activeProfileReleaseRecords
      .first(where: { $0.draftID == draft.id })
    let deploymentStatus = deploymentRecord.flatMap { store.deploymentStatusSnapshot(for: $0) }
    let sourceProfile = deploymentRecord.flatMap {
      DeploymentSourceContext.profile(for: $0, in: store.profiles)
    }
    WorkspaceTaskChecksSection(
      state: WorkspaceTaskChecksState(
        issues: issues,
        publicRisk: PublicRiskSummary(issues: issues),
        deploymentStatus: deploymentStatus,
        deploymentSourceContext: sourceProfile.map {
          DeploymentSourceContext(profile: $0, shell: store.shell)
        }
      ),
      actions: WorkspaceTaskChecksActions(
        rerunPreflight: {
          requestManualPreflightRefresh()
          store.scheduleImageWorkbenchCachesRefresh(for: draft, force: true)
        },
        focusIssue: focus
      )
    )
  }

  private var preflightUnavailableContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      if preflightModel.state != .unavailable || preflightModel.requestKey != preflightRequestKey {
        preflightLoadingIndicator
      } else {
        preflightFailureIndicator
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityIdentifier("article-inspector-checks-unavailable")
  }

  private func focus(_ issue: PreflightIssue) {
    switch issue.structuredField {
    case .body:
      store.requestEditorFocus(draftID: draft.id, field: issue.field, query: issue.editorQuery)
    case .title:
      store.requestEditorFocus(draftID: draft.id, field: "title")
    case .attachments, .cover:
      selectedTab = .images
    case .repository, .contentRoot, .assetRoot, .markdownPathPattern:
      store.selectSection(.sync)
    default:
      selectedTab = .metadata
    }
  }

  private var preflightLoadingIndicator: some View {
    HStack(spacing: 6) {
      ProgressView()
        .controlSize(.small)
      Text("正在检查…")
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("article-inspector-checks-loading")
  }

  private var preflightUnavailableIndicator: some View {
    HStack(spacing: 8) {
      Label("检查尚未完成，显示上一次结果。", systemImage: "exclamationmark.circle")
      preflightRetryButton
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .accessibilityIdentifier("article-inspector-checks-stale")
  }

  private var preflightFailureIndicator: some View {
    HStack(spacing: 8) {
      Label("检查尚未完成，请重试。", systemImage: "exclamationmark.circle")
      preflightRetryButton
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var preflightRetryButton: some View {
    Button {
      requestManualPreflightRefresh()
    } label: {
      Label("重新检查", systemImage: "arrow.clockwise")
    }
    .controlSize(.small)
  }

  private func requestManualPreflightRefresh() {
    isManualPreflightRefresh = true
    manualRefreshGeneration += 1
  }

  private func prepareSelectedTab() {
    switch selectedTab {
    case .knowledge:
      break
    case .seo:
      store.prepareSEOSocialPreview(for: draft)
    case .images:
      break
    case .checks:
      break
    case .metadata:
      break
    }
  }

  private func normalizeSelectedTab() {
    guard !availableTabs.contains(selectedTab), let first = availableTabs.first else { return }
    selectedTab = first
  }

  private var imageRefreshID: WorkspaceTaskImageRefreshID? {
    guard selectedTab == .images || selectedTab == .checks else { return nil }
    return WorkspaceTaskImageRefreshID(draft: draft, profile: store.profile(for: draft))
  }

  private var knowledgeRefreshID: UUID? {
    selectedTab == .knowledge && moduleVisibility.libraryEnabled ? draft.id : nil
  }
}

private struct ArticleInspectorPreflightTaskID: Equatable {
  let key: DraftScopedPreflightRequestKey
  let generation: Int
}

private struct WorkspaceTaskImageRefreshID: Hashable {
  let draft: ArticleDraft
  let profile: SiteProfile
}
