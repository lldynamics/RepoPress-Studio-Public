import AppKit
import PublishingWorkbenchCore
import SwiftUI

enum ArticleInspectorTab: String, CaseIterable, Identifiable {
  case metadata
  case seo
  case images
  case checks

  var id: String { rawValue }

  var title: String {
    switch self {
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

  static func defaultTab(for section: WorkspaceSection) -> ArticleInspectorTab {
    switch section {
    case .writing:
      return .metadata
    case .sync, .releaseHistory:
      return .metadata
    case .contentHealth:
      return .checks
    case .images:
      return .images
    case .siteStarter, .library, .generalDrafts, .maintenance:
      return .metadata
    }
  }
}

extension PreflightIssue {
  var editorQuery: String? {
    guard field == "body" else {
      return nil
    }

    if title == "正文图片未登记" {
      return message.components(separatedBy: " 不在").first
    }

    return nil
  }
}

struct ArticleInspectorTabs: View {
  @Binding var selectedTab: ArticleInspectorTab
  @Binding var draft: ArticleDraft
  @ObservedObject var store: WorkbenchStore
  let availableTabs: [ArticleInspectorTab]

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if availableTabs.count > 1 {
        tabPicker
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
        .onChange(of: store.imageInspectorFocusRequest?.id) { _, _ in
          scrollToFocusedImage(using: proxy)
        }
      }

      Divider()
      actionFooter
    }
    .background(.bar)
    .accessibilityIdentifier("article-inspector")
    .accessibilityLabel("文章 Inspector")
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
    .task(id: imageRefreshID) {
      guard selectedTab == .images else { return }
      await store.refreshImageWorkbenchCachesInBackground(for: draft)
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: selectedTab.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text("文章 Inspector")
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
    Picker("Inspector", selection: $selectedTab) {
      ForEach(availableTabs) { tab in
        Label(tab.title, systemImage: tab.systemImage)
          .tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .tint(WorkbenchTheme.navigationSelection)
    .labelsHidden()
    .padding(10)
    .accessibilityLabel("文章 Inspector 标签")
    .accessibilityValue(selectedTab.title)
  }

  private var actionFooter: some View {
    HStack(spacing: 10) {
      if availableTabs.contains(.metadata) || availableTabs.contains(.seo) || availableTabs.contains(.images) {
        Button {
          store.save()
        } label: {
          Label("保存", systemImage: "tray.and.arrow.down")
        }
      }

      if availableTabs.contains(.checks) {
        Button {
          selectedTab = .checks
          store.runPreflight()
        } label: {
          Label("重新检查", systemImage: "checklist")
        }
      }

      Spacer(minLength: 0)

    }
    .controlSize(.small)
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .background(.bar)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("文章 Inspector 主要操作")
  }

  private func scrollToFocusedImage(using proxy: ScrollViewProxy) {
    guard selectedTab == .images,
          let request = store.imageInspectorFocusRequest,
          request.draftID == draft.id else {
      return
    }
    Task { @MainActor in
      await Task.yield()
      withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(request.attachmentID, anchor: .center)
      }
    }
  }

  @ViewBuilder
  private var selectedContent: some View {
    switch selectedTab {
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

  private var metadataContent: some View {
    WorkspaceTaskMetadataSection(
      draft: $draft,
      state: WorkspaceTaskMetadataState(
        draft: draft,
        profile: store.profile(for: draft)
      ),
      tagSuggestions: taxonomySuggestions(\.tags),
      categorySuggestions: taxonomySuggestions(\.categories)
    )
  }

  private func taxonomySuggestions(_ keyPath: KeyPath<ArticleDraft, [String]>) -> [String] {
    Array(Set(store.drafts.flatMap { $0[keyPath: keyPath] }))
      .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  private var seoContent: some View {
    WorkspaceTaskSEOSection(draft: draft, store: store)
  }

  private var imageContent: some View {
    WorkspaceTaskImageSection(
      draft: $draft,
      state: WorkspaceTaskImageState(
        report: store.cachedImageWorkbenchReport(for: draft),
        siteSummary: store.cachedImageWorkbenchSiteSummary,
        actionMessage: store.imageActionMessage,
        focusedAttachmentID: store.imageInspectorFocusRequest.flatMap { request in
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
    let issues = draft.id == store.selectedDraftID
      ? store.preflightIssues
      : store.preflightIssues(for: draft)
    return WorkspaceTaskChecksSection(
      state: WorkspaceTaskChecksState(
        issues: issues,
        publicRisk: PublicRiskSummary(issues: issues)
      ),
      actions: WorkspaceTaskChecksActions(
        rerunPreflight: {
          store.runPreflight()
        },
        focusIssue: focus
      )
    )
  }

  private func focus(_ issue: PreflightIssue) {
    switch issue.field {
    case "body":
      store.requestEditorFocus(draftID: draft.id, field: issue.field, query: issue.editorQuery)
    case "attachments", "cover":
      selectedTab = .images
    case "repository", "contentRoot", "assetRoot", "markdownPathPattern":
      store.selectSection(.sync)
    default:
      selectedTab = .metadata
    }
  }

  private func prepareSelectedTab() {
    switch selectedTab {
    case .seo:
      store.prepareSEOSocialPreview(for: draft)
    case .images:
      break
    case .checks:
      store.runPreflight()
    case .metadata:
      break
    }
  }

  private func normalizeSelectedTab() {
    guard !availableTabs.contains(selectedTab), let first = availableTabs.first else { return }
    selectedTab = first
  }

  private var imageRefreshID: WorkspaceTaskImageRefreshID? {
    guard selectedTab == .images else { return nil }
    return WorkspaceTaskImageRefreshID(draft: draft, profile: store.profile(for: draft))
  }
}

private struct WorkspaceTaskImageRefreshID: Hashable {
  let draft: ArticleDraft
  let profile: SiteProfile
}
