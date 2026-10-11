import AppKit
import PublishingCoreSupport
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

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
  @Environment(\.publishReadinessNavigationRequest) private var publishNavigationRequest

  @Binding var selectedTab: ArticleInspectorTab
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var rssStore: RSSReaderStore
  @ObservedObject private var imageWorkbench: WorkbenchImageWorkbenchFeatureFacade
  @ObservedObject private var knowledge: KnowledgeStore
  @ObservedObject var presentation: ArticleInspectorPresentationState
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
    availableTabs: [ArticleInspectorTab],
    presentation: ArticleInspectorPresentationState
  ) {
    _selectedTab = selectedTab
    _draft = draft
    self.store = store
    _rssStore = ObservedObject(wrappedValue: rssStore)
    _imageWorkbench = ObservedObject(wrappedValue: store.imageWorkbench)
    _knowledge = ObservedObject(wrappedValue: store.knowledge)
    self.presentation = presentation
    self.section = section
    self.configuredTabs = availableTabs
  }

  private var preflightRequestKey: DraftScopedPreflightRequestKey? {
    store.draftScopedPreflightRequestKey(for: draft.id)
  }

  private var preflightTaskID: ArticleInspectorPreflightTaskID? {
    guard selectedTab == .checks,
      let key = store.draftPreflightRefreshIdentity(for: draft.id)
    else { return nil }
    return ArticleInspectorPreflightTaskID(key: key, generation: manualRefreshGeneration)
  }

  var body: some View {
    VStack(spacing: 0) {
      if section != .writing {
        header
        Divider()
      }

      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if section == .writing {
              informationGroups
            } else {
              selectedContent
            }
          }
          .padding(WorkbenchSpacing.content)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
          if revealsSEOSocialPreviewForScreenshot {
            presentation.revealSEOSocialPreview(for: draft.id, section: section)
            scrollToInformationGroup(.seo, using: proxy)
          } else {
            scrollToFocusedImage(using: proxy, expandsGroup: false)
          }
        }
        .onChange(of: imageWorkbench.imageInspectorFocusRequest?.id) { _, _ in
          scrollToFocusedImage(using: proxy)
        }
        .onChange(of: selectedTab) { _, tab in
          scrollToInformationGroup(tab, using: proxy)
        }
        .task(id: publishNavigationRequest?.id) {
          guard let request = publishNavigationRequest, request.draftID == draft.id,
            let tab = request.target.inspectorTab
          else { return }
          if case .metadata(let field) = request.target, field == "title" {
            store.requestEditorFocus(draftID: draft.id, field: field)
          } else {
            if case .metadata(let field) = request.target, let field {
              presentation.revealMetadataField(field, for: draft.id, section: section)
            }
            await Task.yield()
            guard !Task.isCancelled, draft.id == request.draftID else { return }
            if case .metadata(let field) = request.target {
              proxy.scrollTo(PublishMetadataFieldAnchor.id(for: field), anchor: .center)
            } else if case .images(let attachmentID) = request.target, let attachmentID {
              proxy.scrollTo(attachmentID, anchor: .center)
            } else {
              proxy.scrollTo(tab.informationAnchor, anchor: .top)
            }
          }
        }
      }

    }
    .background(.bar)
    .accessibilityIdentifier("article-inspector")
    .accessibilityLabel("文章详情栏")
    .onAppear {
      normalizeSelectedTab()
    }
    .onChange(of: draft.id) { _, _ in
      normalizeSelectedTab()
    }
    .onChange(of: moduleVisibility) { _, _ in
      normalizeSelectedTab()
    }
    .task(id: imageRefreshID) {
      guard imageRefreshID != nil else { return }
      await store.refreshImageWorkbenchCachesInBackground(for: draft)
    }
    .task(id: preflightTaskID) {
      guard selectedTab == .checks,
        let key = preflightRequestKey,
        let identity = store.draftPreflightRefreshIdentity(for: draft.id)
      else { return }
      let draftID = draft.id
      let forcesRefresh = isManualPreflightRefresh
      let debounceDuration =
        isManualPreflightRefresh ? nil : DebounceIntervals.preflightRefresh
      isManualPreflightRefresh = false
      await preflightModel.refresh(
        requestKey: key,
        draftID: draftID,
        debounceDuration: debounceDuration
      ) {
        let result =
          forcesRefresh
          ? await store.runPreflight(for: draftID)
          : await store.ensurePreflight(for: draftID)
        guard !Task.isCancelled,
          draft.id == draftID,
          store.draftPreflightRefreshIdentity(for: draftID) == identity
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
    .task(id: seoRefreshID) {
      guard seoRefreshID != nil else { return }
      store.prepareSEOSocialPreview(for: draft)
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
    .padding(WorkbenchSpacing.content)
  }

  private var revealsSEOSocialPreviewForScreenshot: Bool {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      section == .writing
        && ScreenshotDemoDataService.isEnabledFromEnvironment
        && ScreenshotDemoDataService.requestedSurfaceFromEnvironment == .seoSocialPreview
    #else
      false
    #endif
  }

  private var informationGroups: some View {
    ForEach(availableTabs) { tab in
      InspectorDisclosureSection(
        tab.informationTitle,
        detail: isExpanded(tab) ? nil : informationSummary(tab),
        isExpanded: presentation.expansionBinding(for: tab, draftID: draft.id, section: section)
      ) {
        if isExpanded(tab) {
          switch tab {
          case .metadata: metadataContent
          case .seo: seoContent
          case .images: imageContent
          case .knowledge: knowledgeContent
          case .checks: checkContent
          }
        }
      }
      .padding(WorkbenchSpacing.card)
      .background(
        WorkbenchSurface.groupedCard,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
      )
      .id(tab.informationAnchor)
      .accessibilityIdentifier(tab.informationAnchor)
      .help(informationSummary(tab))
    }
  }

  private func isExpanded(_ tab: ArticleInspectorTab) -> Bool {
    presentation.isExpanded(tab, for: draft.id, section: section)
  }

  private func informationSummary(_ tab: ArticleInspectorTab) -> String {
    switch tab {
    case .metadata:
      return String(localized: "\(draft.tags.count) 个标签 · \(draft.categories.count) 个分类")
    case .seo:
      return String(
        localized:
          "标题 \(draft.title.trimmedForPublishing.count) 字符 · 摘要 \(draft.summary.trimmedForPublishing.count) 字符"
      )
    case .images:
      guard let report = store.cachedImageWorkbenchReport(for: draft) else {
        let imageCount = draft.attachments.filter { $0.mediaKind == .image }.count
        return String(localized: "\(imageCount) 张 · 待检查")
      }
      let pendingCount = report.issues.filter { $0.severity != .info }.count
      return pendingCount > 0
        ? String(localized: "\(report.items.count) 张 · \(pendingCount) 项待处理")
        : String(localized: "\(report.items.count) 张 · 无待处理项")
    case .knowledge:
      let localCount =
        moduleVisibility.libraryEnabled
        ? knowledge.documents.filter { !$0.isArchived && $0.allowsLocalSemanticIndex }.count : 0
      let highlightedIDs = Set(rssStore.highlights.map(\.articleID))
      let readingCount =
        moduleVisibility.rssEnabled
        ? rssStore.articleHeaders.filter { $0.isStarred || highlightedIDs.contains($0.id) }.count
        : 0
      return localCount + readingCount > 0
        ? String(localized: "可关联 \(localCount + readingCount) 份本地资料")
        : String(localized: "尚无本地关联资料")
    case .checks:
      return String(localized: "检查")
    }
  }

  private func scrollToInformationGroup(_ tab: ArticleInspectorTab, using proxy: ScrollViewProxy) {
    guard section == .writing, availableTabs.contains(tab) else { return }
    let draftID = draft.id
    presentation.setExpanded(true, group: tab, for: draftID, section: section)
    Task { @MainActor in
      await Task.yield()
      guard draft.id == draftID, selectedTab == tab,
        !(publishNavigationRequest?.draftID == draftID
          && publishNavigationRequest?.target.inspectorTab == tab)
      else { return }
      proxy.scrollTo(tab.informationAnchor, anchor: .top)
    }
  }

  private func scrollToFocusedImage(using proxy: ScrollViewProxy, expandsGroup: Bool = true) {
    guard section == .writing || selectedTab == .images,
      let request = imageWorkbench.imageInspectorFocusRequest,
      request.draftID == draft.id
    else {
      return
    }
    if section == .writing {
      guard expandsGroup || isExpanded(.images) else { return }
      if expandsGroup {
        presentation.setExpanded(true, group: .images, for: draft.id, section: section)
      }
    }
    Task { @MainActor in
      await Task.yield()
      guard draft.id == request.draftID,
        imageWorkbench.imageInspectorFocusRequest?.id == request.id
      else { return }
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
      categorySuggestions: taxonomySuggestions(\.categories),
      isAdvancedExpanded: presentation.advancedMetadataBinding(for: draft.id, section: section)
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

  private func normalizeSelectedTab() {
    guard !availableTabs.contains(selectedTab), let first = availableTabs.first else { return }
    selectedTab = first
  }

  private var imageRefreshID: WorkspaceTaskImageRefreshID? {
    let showsImages = section == .writing ? isExpanded(.images) : selectedTab == .images
    guard showsImages || selectedTab == .checks else { return nil }
    return WorkspaceTaskImageRefreshID(draft: draft, profile: store.profile(for: draft))
  }

  private var knowledgeRefreshID: UUID? {
    let showsKnowledge = section == .writing ? isExpanded(.knowledge) : selectedTab == .knowledge
    return showsKnowledge && moduleVisibility.libraryEnabled ? draft.id : nil
  }

  private var seoRefreshID: UUID? {
    let showsSEO = section == .writing ? isExpanded(.seo) : selectedTab == .seo
    return showsSEO ? draft.id : nil
  }
}

private struct ArticleInspectorPreflightTaskID: Equatable {
  let key: DraftPreflightRefreshIdentity
  let generation: Int
}

private struct WorkspaceTaskImageRefreshID: Hashable {
  let draft: ArticleDraft
  let profile: SiteProfile
}
