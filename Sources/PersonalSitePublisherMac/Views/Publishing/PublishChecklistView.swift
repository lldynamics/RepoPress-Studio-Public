import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

/// The 发布检查 panel: the current article's checks, and the window's two
/// publish actions. Publishing itself happens in the confirmation sheet that
/// either action opens; this panel never commits or pushes.
struct PublishChecklistView: View {
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction
  @Environment(\.publishCommandAction) private var publishCommandAction
  @ObservedObject var publishingFacade: WorkbenchPublishingFeatureFacade
  @ObservedObject private var drawerObservation: WorkbenchPublishDrawerObservationFacade
  let store: WorkbenchStore
  let draftID: UUID?
  let isActive: Bool
  private let onNavigateIssue: ((UUID, PublishReadinessTarget) -> Void)?
  private let onRequestAIFix: ((UUID, PublishReadinessTarget) -> Void)?
  @State private var selectedIssueID: String?

  init(
    publishingFacade: WorkbenchPublishingFeatureFacade,
    store: WorkbenchStore,
    draftID: UUID?,
    isActive: Bool = true,
    onNavigateIssue: ((UUID, PublishReadinessTarget) -> Void)? = nil,
    onRequestAIFix: ((UUID, PublishReadinessTarget) -> Void)? = nil
  ) {
    self.publishingFacade = publishingFacade
    _drawerObservation = ObservedObject(wrappedValue: store.publishDrawerObservation)
    self.store = store
    self.draftID = draftID
    self.isActive = isActive
    self.onNavigateIssue = onNavigateIssue
    self.onRequestAIFix = onRequestAIFix
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      ScrollView {
        VStack(alignment: .leading, spacing: WorkbenchSpacing.control) {
          if !isRepositoryConfigured {
            repositorySetupNotice
          }
          if let draft = currentDraft {
            checks(for: draft)
          } else {
            Text("选择一篇文章即可查看它的发布检查。")
              .font(.workbenchBody)
              .foregroundStyle(.workbenchSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(WorkbenchSpacing.control)
      }
      .accessibilityIdentifier("publish-drawer-scroll-content")
      Divider()
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(WorkbenchSurface.inspector)
    .onAppear(perform: refreshChecks)
    .onChange(of: draftID) {
      selectedIssueID = nil
      refreshChecks()
    }
    .onChange(of: isActive) { refreshChecks() }
    .articlePreflightRefresh(store: store, draftID: currentDraft?.id, isEnabled: isActive)
  }

  private var currentDraft: ArticleDraft? {
    PublishDrawerDraftPresentation.resolve(
      draftID: draftID, profileID: store.activeProfileID,
      draft: draftID.flatMap { store.draft(for: $0) })
  }

  private var isRepositoryConfigured: Bool {
    PublishDrawerConnectionPresentation.isWorktreeConfigured(store.activeProfile)
  }

  private func refreshChecks() {
    guard isActive, let draft = currentDraft else { return }
    store.prepareSEOSocialPreview(for: draft)
    store.scheduleImageWorkbenchReportRefresh(for: draft)
    publishingFacade.refreshPublishPreviewInBackground(for: draft)
  }

  private var header: some View {
    let title = currentDraft?.title ?? store.activeProfile.name
    return HStack(spacing: WorkbenchSpacing.tight) {
      Text(title)
        .font(.workbenchBody.weight(.medium))
        .workbenchTruncatedTitle(title)
      Spacer(minLength: WorkbenchSpacing.tight)
      Button {
        store.runPreflight()
        refreshChecks()
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .disabled(currentDraft == nil)
      .help(String(localized: "重新运行发布检查"))
      .accessibilityLabel("重新运行发布检查")
    }
    .padding(WorkbenchSpacing.control)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-drawer-header")
    .accessibilityLabel("发布检查")
    .accessibilityValue(title)
  }

  private var repositorySetupNotice: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
      Label("还不能发布", systemImage: "xmark.octagon")
        .font(.workbenchBody.weight(.semibold)).foregroundStyle(WorkbenchTheme.risk)
      Text("发布会提交并推送本地 Git 仓库。请先在项目配置中选择本地仓库，并确认 origin 指向站点仓库。")
        .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("打开项目配置", action: presentRepositorySettings)
        .buttonStyle(.link)
    }
    .padding(WorkbenchSpacing.control)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityIdentifier("publish-inspector-connection-issue")
  }

  @ViewBuilder
  private func checks(for draft: ArticleDraft) -> some View {
    let readiness = ArticlePublishAttention.readiness(store: store, draft: draft)
    HStack(spacing: WorkbenchSpacing.control) {
      PublishDrawerAttentionSummary(
        blockingCount: readiness.isAwaitingPreflight ? 0 : readiness.blockingCount,
        pendingCount: ArticlePublishAttention.pendingCount(
          readiness: readiness, accountStatus: .passed),
        optimizationCount: readiness.optimizationCount,
        isReady: !readiness.isAwaitingPreflight && !readiness.isLoading
          && isRepositoryConfigured)
    }
    PublishDrawerReadinessChecklist(
      presentation: readiness, selectedIssueID: $selectedIssueID,
      onNavigate: onNavigateIssue.map { callback in
        { issue in
          guard let draftID = issue.draftID else { return }
          callback(draftID, issue.target)
        }
      },
      onRequestAIFix: onRequestAIFix.map { callback in
        { issue in
          guard let draftID = issue.draftID else { return }
          callback(draftID, issue.target)
        }
      },
      store: store
    )
    if draft.draft {
      Label("这是草稿。发布这篇时会先取消草稿标记，正式上线。", systemImage: "info.circle")
        .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: WorkbenchSpacing.tight) {
      if let feedback = store.publishDrawerFeedback, feedback.status == .inProgress {
        Label(feedback.message, systemImage: "arrow.up.circle")
          .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
          .lineLimit(2)
          .accessibilityIdentifier("publish-drawer-feedback-message")
      }
      Button {
        publishCommandAction?.publishCurrentArticle()
      } label: {
        Label("发布这篇…", systemImage: "doc.badge.arrow.up")
          .frame(maxWidth: .infinity)
      }
      .workbenchProminentActionStyle()
      .disabled(
        currentDraft == nil || !isRepositoryConfigured
          || publishCommandAction?.canPublishCurrentArticle != true
      )
      .help("只提交并推送这篇文章和它的图片")
      .accessibilityIdentifier("publish-drawer-action-publish-current")
      Button {
        publishCommandAction?.publishAll()
      } label: {
        Label("发布全部…", systemImage: "paperplane")
          .frame(maxWidth: .infinity)
      }
      .disabled(!isRepositoryConfigured || publishCommandAction?.canPublishAll != true)
      .help("提交并推送仓库里的全部改动")
      .accessibilityIdentifier("publish-drawer-action-publish-all")
      Text("两种发布都会先打开确认页，确认后才会提交并推送。")
        .font(.workbenchMetadata).foregroundStyle(.workbenchSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(WorkbenchSpacing.control)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func presentRepositorySettings() {
    if let draftID = currentDraft?.id, let onNavigateIssue {
      onNavigateIssue(draftID, .repository)
      return
    }
    SettingsNavigation.present(
      destination: .token(.repository),
      workspaceAction: settingsWorkspaceCommandAction
    ) { openSettings() }
  }
}
