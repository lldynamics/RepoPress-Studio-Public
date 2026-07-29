import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerView: View {
  @ObservedObject var publishingFacade: WorkbenchPublishingFeatureFacade
  // 部分属性尚未迁移到 Facade，保留 store 访问，但去除 @ObservedObject 以避免全局不相关事件触发重绘
  let store: WorkbenchStore
  @Binding var isPresented: Bool
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
  @State private var isAllChangesPublishConfirmationPresented = false
  @State private var reviewedAllChangesPaths: Set<String> = []
  @State private var pendingSingleOnlinePublishDraft: ArticleDraft?
  @State private var isAdvancedFlowExpanded = false

  var body: some View {
    drawerContent
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    .onAppear {
      publishingFacade.ensureEditableDraftSelected()
      publishingFacade.runPreflight()
      if let draft = publishingFacade.selectedDraft {
        publishingFacade.refreshPublishPreviewInBackground(for: draft)
        store.refreshBatchPublishPlanInBackground()
      }
    }
    .sheet(isPresented: $isAllChangesPublishConfirmationPresented) {
      allChangesOnlinePublishConfirmation
    }
    .sheet(item: $pendingSingleOnlinePublishDraft) { draft in
      singleArticleOnlinePublishConfirmation(draft: draft)
    }
  }

  @ViewBuilder
  private var drawerContent: some View {
    if let draft = publishingFacade.selectedDraft {
      let issues = store.preflightIssues
      VStack(spacing: 0) {
        header(draft: draft)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            publishDecisionSummary(draft: draft, issues: issues)
            publishPrimaryActions(draft: draft, issues: issues)
            advancedPublishOptions(draft: draft, issues: issues)
          }
          .padding(16)
        }
        Divider()
        drawerFooter
      }
    } else {
      VStack(spacing: 12) {
        Image(systemName: "paperplane")
          .font(.system(size: 30))
          .foregroundStyle(.secondary)
        Text("没有可发布文章")
          .font(.headline)
        Button("关闭") {
          isPresented = false
        }
        .accessibilityLabel("关闭发布流程")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func header(draft: ArticleDraft) -> some View {
    HStack(spacing: 12) {
      Label("发布", systemImage: "paperplane")
        .font(.headline)

      Text(draft.title)
        .font(.callout.weight(.medium))
        .workbenchTruncatedIdentity(draft.title)

      Spacer()

      if publishingFacade.isPublishPreviewRefreshing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在刷新发布预览")
      }

      Button {
        publishingFacade.runPreflight()
        publishingFacade.refreshPublishPreviewInBackground(for: draft)
        store.refreshBatchPublishPlanInBackground()
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .accessibilityLabel("刷新发布检查和差异")

    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("publish-drawer-header")
    .accessibilityLabel("发布流程")
    .accessibilityValue(draft.title)
  }

  private func publishDecisionSummary(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let blocking = issues.filter { $0.severity == .error }
    let warnings = issues.filter { $0.severity == .warning }
    let changedCount = store.cachedLocalPublishPreview(for: draft)?.changedFileDiffs.count
    let status: (title: String, detail: String, systemImage: String, color: Color)

    if publishingFacade.isPublishPreviewRefreshing {
      status = ("正在准备发布信息", "正在检查文章、文件变化和线上发布条件。", "arrow.clockwise", .secondary)
    } else if !blocking.isEmpty {
      status = ("还需处理 \(blocking.count) 个问题", "处理后即可保存到本地或发布上线。", "xmark.octagon", WorkbenchTheme.risk)
    } else if changedCount == nil {
      status = ("发布信息待刷新", "刷新后会显示可以执行的操作。", "clock.arrow.circlepath", .secondary)
    } else if changedCount == 0 {
      status = ("没有需要保存的文件变化", "没有待写入变化。", "checkmark.circle", WorkbenchTheme.success)
    } else {
      status = ("可以选择下一步", "当前文章有 \(changedCount ?? 0) 个文件变化。", "checkmark.circle", WorkbenchTheme.success)
    }

    return PublishDrawerCard(title: "发布准备", systemImage: "checklist") {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: status.systemImage)
          .foregroundStyle(status.color)
          .font(.title3)
          .frame(width: 24)
        VStack(alignment: .leading, spacing: 3) {
          Text(status.title)
            .font(.headline)
          Text(status.detail)
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 8) {
        PublishDrawerStat(
          title: "文件变化",
          value: changedCount.map(String.init) ?? "—",
          systemImage: "doc.on.doc",
          color: .secondary
        )
        PublishDrawerStat(
          title: "需要处理",
          value: "\(blocking.count)",
          systemImage: "xmark.octagon",
          color: blocking.isEmpty ? .secondary : WorkbenchTheme.risk
        )
        PublishDrawerStat(
          title: "提醒",
          value: "\(warnings.count)",
          systemImage: "exclamationmark.triangle",
          color: warnings.isEmpty ? .secondary : WorkbenchTheme.warning
        )
      }

      ForEach(blocking.prefix(3)) { issue in
        PublishDrawerIssueRow(issue: issue)
      }

      if !blocking.isEmpty || !warnings.isEmpty {
        Button("查看全部检查") {
          isAdvancedFlowExpanded = true
        }
        .buttonStyle(.link)
        .accessibilityHint("展开检查结果和文件差异")
      }
    }
  }

  private func publishPrimaryActions(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let blockingCount = issues.filter { $0.severity == .error }.count
    let localReadiness = store.localPublishReadiness
    let singleArticlePreview = store.cachedRemotePublishPreview(for: draft)
    let remotePreview = store.batchRemotePublishPreviewSnapshot
    let batchPlan = store.batchPublishPlan
    let canSaveLocally = blockingCount == 0
      && localReadiness?.canWrite == true
      && !store.isLocalRepositoryMutationRunning
    let canPublishOnline = remotePreview?.canPublish == true
      && batchPlan?.remotePublishableItems.isEmpty == false
      && !store.isBatchPublishPlanRefreshing
      && !store.isRemoteRepositoryPublishing
    let canPublishCurrentArticle = singleArticlePreview?.canPublish == true
      && !store.isRemoteRepositoryChecking
      && !store.isRemoteRepositoryPublishing

    return PublishDrawerCard(title: "选择操作", systemImage: "cursorarrow.click.2") {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 250, maximum: 420), spacing: 12)],
        spacing: 12
      ) {
        PublishDrawerActionChoice(
          title: "保存到本地",
          detail: "只更新站点文件，不提交到 Git，也不会上传到网站。",
          status: localActionStatus(
            blockingCount: blockingCount,
            readiness: localReadiness
          ),
          systemImage: "folder.badge.plus",
          tint: WorkbenchTheme.navigationSelection,
          isEnabled: canSaveLocally,
          isPrimary: false,
          actionTitle: "保存到本地",
          actionSystemImage: "square.and.arrow.down",
          actionIdentifier: "publish-drawer-action-save-local"
        ) {
          writeDraftToRepository(draft)
        }

        PublishDrawerActionChoice(
          title: "发布所有变更",
          detail: "把当前站点中所有通过检查且有变化的文章合并为一次提交和推送；执行前会显示完整文件清单。",
          status: batchOnlineActionStatus(
            plan: batchPlan,
            preview: remotePreview
          ),
          systemImage: "globe",
          tint: WorkbenchTheme.success,
          isEnabled: canPublishOnline,
          isPrimary: true,
          actionTitle: "发布所有变更…",
          actionSystemImage: "paperplane.fill",
          actionIdentifier: "publish-drawer-action-publish-all"
        ) {
          prepareAllChangesOnlinePublish()
        }
      }

      Button {
        pendingSingleOnlinePublishDraft = draft
      } label: {
        Label("仅发布当前文章…", systemImage: "doc.badge.arrow.up")
      }
      .buttonStyle(.link)
      .disabled(!canPublishCurrentArticle)
      .accessibilityIdentifier("publish-drawer-action-publish-current")
      .accessibilityLabel("仅发布当前文章")
      .accessibilityHint(
        canPublishCurrentArticle
          ? "打开当前文章的最终发布确认页"
          : "当前文章的线上发布预览未通过"
      )
    }
  }

  private func localActionStatus(
    blockingCount: Int,
    readiness: LocalPublishReadiness?
  ) -> String {
    if blockingCount > 0 {
      return "请先处理上方问题"
    }
    if store.isLocalRepositoryMutationRunning {
      return "正在保存"
    }
    return readiness?.writeReadiness.localizedDisplayName ?? "正在准备"
  }

  private func batchOnlineActionStatus(
    plan: BatchPublishPlan?,
    preview: RemoteRepositoryPublishPreview?
  ) -> String {
    if store.isBatchPublishPlanRefreshing {
      return "正在汇总全部变更"
    }
    if store.isRemoteRepositoryPublishing {
      return "正在发布"
    }
    if let firstIssue = preview?.blockingIssues.first {
      return firstIssue.title
    }
    guard let plan else {
      return "正在准备"
    }
    let count = plan.remotePublishableItems.count
    guard count > 0 else {
      return "没有待发布变更"
    }
    return "待发布 \(count) 篇 · \(preview?.changedPaths.count ?? plan.changedFileCount) 个文件"
  }

  private func advancedPublishOptions(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let disclosureValue = isAdvancedFlowExpanded
      ? String(localized: "已展开")
      : String(localized: "已折叠")
    let disclosureHint = isAdvancedFlowExpanded
      ? String(localized: "收起检查结果和文件差异")
      : String(localized: "展开检查结果和文件差异")

    return VStack(alignment: .leading, spacing: 0) {
      Button {
        if accessibilityReduceMotion {
          isAdvancedFlowExpanded.toggle()
        } else {
          withAnimation(.easeInOut(duration: 0.2)) {
            isAdvancedFlowExpanded.toggle()
          }
        }
      } label: {
        HStack(spacing: 12) {
          VStack(alignment: .leading, spacing: 2) {
            Label("检查文件变化", systemImage: "doc.text.magnifyingglass")
              .font(.headline)
            Text("发布前请审阅本地差异。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 12)

          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(isAdvancedFlowExpanded ? 90 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("publish-drawer-review-disclosure")
      .accessibilityLabel("检查文件变化")
      .accessibilityValue(disclosureValue)
      .accessibilityHint(disclosureHint)

      if isAdvancedFlowExpanded {
        VStack(alignment: .leading, spacing: 12) {
          PublishDrawerCheckResultsCard(issues: issues)
          diffCard(draft: draft)
        }
        .padding(.top, 10)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(14)
    .background(WorkbenchBackgroundStyle.card, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card))
  }

  private var drawerFooter: some View {
    HStack(spacing: 12) {
      Button("关闭") {
        isPresented = false
      }
      .keyboardShortcut(.cancelAction)

      if store.isRemoteRepositoryPublishing {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("正在发布")
        Text(store.remoteRepositoryPublishProgress?.message ?? "正在发布")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      } else if let message = store.publishActionMessage {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer()
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func diffCard(draft: ArticleDraft) -> some View {
    let preview = store.cachedLocalPublishPreview(for: draft)
    let changedDiffs = preview?.changedFileDiffs ?? []

    return PublishDrawerCard(title: "差异", systemImage: "doc.text.magnifyingglass") {
      HStack(spacing: 8) {
        PublishDrawerStat(title: "文件", value: preview.map { "\($0.fileDiffs.count)" } ?? "—", systemImage: "doc.on.doc", color: .secondary)
        PublishDrawerStat(title: "变化", value: "\(changedDiffs.count)", systemImage: "arrow.left.arrow.right", color: changedDiffs.isEmpty ? .secondary : WorkbenchTheme.warning)
      }

      if preview == nil {
        Label("发布快照待刷新。", systemImage: "clock.arrow.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if changedDiffs.isEmpty {
        Label("没有待写入变化。", systemImage: "equal.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 8) {
          Label("已显示全部 \(changedDiffs.count) 个变化，可展开逐文件审阅。", systemImage: "checkmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)

          ForEach(Array(changedDiffs.enumerated()), id: \.element.id) { index, diff in
            PublishDrawerFileDiffRow(
              diff: diff,
              isExpandedInitially: index == 0
            )
          }
        }
      }
    }
    .accessibilityIdentifier("publish-drawer-diff")
  }

  private func writeDraftToRepository(_ draft: ArticleDraft) {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    publishingFacade.refreshPublishPreviewInBackground(for: draft)
    Task {
      await store.writeSelectedDraftToLocalRepository()
      publishingFacade.selectSection(currentSection)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
    }
  }

  private func prepareAllChangesOnlinePublish() {
    Task {
      await store.refreshBatchPublishPlanAsync()
      guard let preview = store.batchRemotePublishPreviewSnapshot,
            preview.canPublish,
            store.batchPublishPlan?.remotePublishableItems.isEmpty == false else {
        return
      }
      reviewedAllChangesPaths = Set(preview.changedPaths)
      isAllChangesPublishConfirmationPresented = true
    }
  }

  private func publishAllChangesOnline() {
    let currentSection = publishingFacade.selectedSection
    Task {
      await store.publishBatchReadyDraftsOnlineUsingPreferredStrategy(
        expectedChangedPaths: reviewedAllChangesPaths
      )
      publishingFacade.selectSection(currentSection)
      store.refreshBatchPublishPlanInBackground()
      if let draft = publishingFacade.selectedDraft {
        publishingFacade.refreshPublishPreviewInBackground(for: draft)
      }
    }
  }

  private func publishSingleArticleOnline(_ draft: ArticleDraft) {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    Task {
      await store.publishSelectedDraftOnlineUsingPreferredStrategy()
      publishingFacade.selectSection(currentSection)
      publishingFacade.refreshPublishPreviewInBackground(for: draft)
      store.refreshBatchPublishPlanInBackground()
    }
  }

  @ViewBuilder
  private var allChangesOnlinePublishConfirmation: some View {
    if let preview = store.batchRemotePublishPreviewSnapshot,
       let plan = store.batchPublishPlan {
      RemotePublishConfirmationView(
        targetLabel: "发布范围",
        targetTitle: "全部待发布变更（\(plan.remotePublishableItems.count) 篇文章）",
        preview: preview,
        reviewDraft: store.batchRemoteReviewDraft,
        isPublishing: store.isRemoteRepositoryPublishing,
        cancelAction: {
          isAllChangesPublishConfirmationPresented = false
        },
        confirmAction: {
          isAllChangesPublishConfirmationPresented = false
          publishAllChangesOnline()
        }
      )
    } else {
      VStack(spacing: 12) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 28))
          .foregroundStyle(.secondary)
        Text("发布预览已失效")
          .font(.headline)
        Text("请关闭确认页，刷新发布快照后重新审阅。")
          .foregroundStyle(.secondary)
        Button("关闭") {
          isAllChangesPublishConfirmationPresented = false
        }
      }
      .frame(minWidth: 420, minHeight: 260)
      .padding(24)
    }
  }

  @ViewBuilder
  private func singleArticleOnlinePublishConfirmation(draft: ArticleDraft) -> some View {
    if let preview = store.cachedRemotePublishPreview(for: draft) {
      RemotePublishConfirmationView(
        targetLabel: "文章",
        targetTitle: draft.title,
        preview: preview,
        reviewDraft: store.cachedRemoteReviewDraft(for: draft),
        isPublishing: store.isRemoteRepositoryPublishing,
        cancelAction: {
          pendingSingleOnlinePublishDraft = nil
        },
        confirmAction: {
          pendingSingleOnlinePublishDraft = nil
          publishSingleArticleOnline(draft)
        }
      )
    } else {
      VStack(spacing: 12) {
        Image(systemName: "clock.arrow.circlepath")
          .font(.system(size: 28))
          .foregroundStyle(.secondary)
        Text("发布预览已失效")
          .font(.headline)
        Text("请关闭确认页，刷新发布快照后重新审阅。")
          .foregroundStyle(.secondary)
        Button("关闭") {
          pendingSingleOnlinePublishDraft = nil
        }
      }
      .frame(minWidth: 420, minHeight: 260)
      .padding(24)
    }
  }

}
