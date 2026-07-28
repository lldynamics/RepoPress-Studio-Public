import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PublishDrawerView: View {
  @ObservedObject var publishingFacade: WorkbenchPublishingFeatureFacade
  // 部分属性尚未迁移到 Facade，保留 store 访问，但去除 @ObservedObject 以避免全局不相关事件触发重绘
  let store: WorkbenchStore
  @Binding var isPresented: Bool
  @State private var newBranchName = ""
  @State private var showAllCommits = false
  @State private var selectedStep: PublishDrawerFlowCard = .checks
  @State private var didManuallySelectStep = false
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
        didManuallySelectStep = false
        publishingFacade.refreshPublishPreviewInBackground(for: draft)
        store.refreshBatchPublishPlanInBackground()
        synchronizeRecommendedStep(for: draft)
      }
    }
    .onChange(of: publishingFacade.isPublishPreviewRefreshing) { wasRefreshing, isRefreshing in
      guard wasRefreshing, !isRefreshing, let draft = publishingFacade.selectedDraft else { return }
      synchronizeRecommendedStep(for: draft)
    }
    .onChange(of: publishingFacade.selectedDraftID) { _, _ in
      didManuallySelectStep = false
      guard let draft = publishingFacade.selectedDraft else { return }
      synchronizeRecommendedStep(for: draft)
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
      status = ("没有需要保存的文件变化", "仍可查看线上状态和高级发布选项。", "checkmark.circle", WorkbenchTheme.success)
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
          didManuallySelectStep = true
          selectedStep = .checks
          isAdvancedFlowExpanded = true
        }
        .buttonStyle(.link)
        .accessibilityHint("展开高级选项并显示全部检查结果")
      }
    }
  }

  private func publishPrimaryActions(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> some View {
    let blockingCount = issues.filter { $0.severity == .error }.count
    let localReadiness = store.localPublishReadiness
    let remotePreview = store.batchRemotePublishPreviewSnapshot
    let batchPlan = store.batchPublishPlan
    let canSaveLocally = blockingCount == 0
      && localReadiness?.canWrite == true
      && !store.isLocalRepositoryMutationRunning
    let canPublishOnline = remotePreview?.canPublish == true
      && batchPlan?.remotePublishableItems.isEmpty == false
      && !store.isBatchPublishPlanRefreshing
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
          actionSystemImage: "square.and.arrow.down"
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
          actionSystemImage: "paperplane.fill"
        ) {
          prepareAllChangesOnlinePublish()
        }
      }
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
    DisclosureGroup(isExpanded: $isAdvancedFlowExpanded) {
      VStack(alignment: .leading, spacing: 12) {
        PublishDrawerFlowStepper(
          steps: publishFlowSteps(draft: draft, issues: issues),
          selection: selectedStepBinding
        )
        publishStepContent(draft: draft, issues: issues)
      }
      .padding(.top, 10)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Label("检查、差异与高级选项", systemImage: "slider.horizontal.3")
          .font(.headline)
        Text("需要时再查看 Git 分支、提交、远端和部署详情")
          .font(.caption)
          .foregroundStyle(.secondary)
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

      if let message = store.publishActionMessage {
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

  @ViewBuilder
  private func publishStepContent(draft: ArticleDraft, issues: [PreflightIssue]) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      switch selectedStep {
      case .checks:
        PublishDrawerCheckResultsCard(issues: issues)
      case .diff:
        diffCard(draft: draft)
      case .write:
        commitMethodCard(draft: draft)
        repositoryBranchCard
        commitHistoryCard
      case .remote:
        remotePublishPreviewCard(draft: draft)
        reviewDescriptionCard(draft: draft)
        remotePublishProgressCard
      case .deployment:
        deploymentStatusCard(draft: draft)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(selectedStep.title)步骤内容")
  }

  private func stepNavigation(draft: ArticleDraft, issues: [PreflightIssue]) -> some View {
    let isFinalStep = selectedStep == PublishDrawerFlowCard.allCases.last
    let finalAction = publishFinalAction(for: draft, issues: issues)

    return VStack(alignment: .leading, spacing: 8) {
      if isFinalStep {
        Label(finalAction.summary, systemImage: finalAction.systemImage)
          .font(.caption)
          .foregroundStyle(finalAction.isDeploymentSuccessful ? WorkbenchTheme.success : .secondary)
          .accessibilityLabel("发布结果摘要")
          .accessibilityValue(finalAction.summary)
      }

      HStack {
        Button("取消") {
          isPresented = false
        }
        .keyboardShortcut(.cancelAction)

        Button("上一步") {
          moveSelectedStep(by: -1)
        }
        .disabled(selectedStep == PublishDrawerFlowCard.allCases.first)

        Spacer()

        Text("步骤 \((PublishDrawerFlowCard.allCases.firstIndex(of: selectedStep) ?? 0) + 1) / \(PublishDrawerFlowCard.allCases.count)")
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Button(isFinalStep ? finalAction.title : "下一步") {
          if isFinalStep {
            isPresented = false
          } else {
            moveSelectedStep(by: 1)
          }
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityLabel(isFinalStep ? finalAction.title : "下一步")
        .accessibilityHint(isFinalStep ? finalAction.summary : "进入下一步")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private func moveSelectedStep(by offset: Int) {
    guard let index = PublishDrawerFlowCard.allCases.firstIndex(of: selectedStep) else {
      return
    }
    let target = index + offset
    guard PublishDrawerFlowCard.allCases.indices.contains(target) else {
      return
    }
    didManuallySelectStep = true
    selectedStep = PublishDrawerFlowCard.allCases[target]
  }

  private var selectedStepBinding: Binding<PublishDrawerFlowCard> {
    Binding(
      get: { selectedStep },
      set: { newValue in
        didManuallySelectStep = true
        selectedStep = newValue
      }
    )
  }

  private func synchronizeRecommendedStep(for draft: ArticleDraft) {
    guard !didManuallySelectStep else { return }
    selectedStep = recommendedStep(
      for: publishFlowSteps(draft: draft, issues: store.preflightIssues)
    )
  }

  private func publishFlowSteps(
    draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> [PublishDrawerFlowStep] {
    let blockingCount = issues.filter { $0.severity == .error }.count
    let warningCount = issues.filter { $0.severity == .warning }.count
    guard let preview = store.cachedLocalPublishPreview(for: draft) else {
      return [
        PublishDrawerFlowStep(title: "检查", detail: "等待快照", systemImage: "clock", state: .pending),
        PublishDrawerFlowStep(title: "差异", detail: "待刷新", systemImage: "doc.text.magnifyingglass", state: .active),
        PublishDrawerFlowStep(title: "写入", detail: "等待差异确认", systemImage: "square.and.arrow.down", state: .pending),
        PublishDrawerFlowStep(title: "远端", detail: "等待本地写入", systemImage: "arrow.up.circle", state: .pending),
        PublishDrawerFlowStep(title: "部署", detail: "等待发布", systemImage: "globe", state: .pending),
      ]
    }
    let changedCount = preview.changedFileDiffs.count
    let canWrite = store.localPublishReadiness?.canWrite == true
    let hasToken = store.repositoryTokenAvailability.hasToken

    if blockingCount > 0 {
      return [
        PublishDrawerFlowStep(
          title: "检查",
          detail: "\(blockingCount) 个阻断",
          systemImage: "xmark.octagon",
          state: .blocked
        ),
        PublishDrawerFlowStep(title: "差异", detail: "等待检查通过", systemImage: "doc.text.magnifyingglass", state: .pending),
        PublishDrawerFlowStep(title: "写入", detail: "暂不可写入", systemImage: "square.and.arrow.down", state: .pending),
        PublishDrawerFlowStep(title: "远端", detail: "等待本地写入", systemImage: "arrow.up.circle", state: .pending),
        PublishDrawerFlowStep(title: "部署", detail: "等待发布", systemImage: "globe", state: .pending)
      ]
    }

    if changedCount == 0 {
      return [
        PublishDrawerFlowStep(
          title: "检查",
          detail: warningCount == 0 ? "已通过" : "\(warningCount) 个警告",
          systemImage: "checkmark.circle",
          state: .complete
        ),
        PublishDrawerFlowStep(title: "差异", detail: "无待写入变化", systemImage: "equal.circle", state: .complete),
        PublishDrawerFlowStep(title: "写入", detail: "本地已同步", systemImage: "checkmark.seal", state: .complete),
        PublishDrawerFlowStep(
          title: "远端",
          detail: hasToken ? "可继续发布" : "需要访问令牌",
          systemImage: hasToken ? "arrow.up.circle" : "key",
          state: hasToken ? .active : .blocked
        ),
        PublishDrawerFlowStep(title: "部署", detail: "发布后跟踪", systemImage: "globe", state: .pending)
      ]
    }

    if !canWrite {
      return [
        PublishDrawerFlowStep(
          title: "检查",
          detail: warningCount == 0 ? "已通过" : "\(warningCount) 个警告",
          systemImage: "checkmark.circle",
          state: .complete
        ),
        PublishDrawerFlowStep(title: "差异", detail: "\(changedCount) 个变化", systemImage: "doc.text.magnifyingglass", state: .complete),
        PublishDrawerFlowStep(title: "写入", detail: "准备状态不足", systemImage: "exclamationmark.triangle", state: .blocked),
        PublishDrawerFlowStep(title: "远端", detail: "等待本地写入", systemImage: "arrow.up.circle", state: .pending),
        PublishDrawerFlowStep(title: "部署", detail: "等待发布", systemImage: "globe", state: .pending)
      ]
    }

    return [
      PublishDrawerFlowStep(
        title: "检查",
        detail: warningCount == 0 ? "已通过" : "\(warningCount) 个警告",
        systemImage: "checkmark.circle",
        state: .complete
      ),
      PublishDrawerFlowStep(title: "差异", detail: "\(changedCount) 个变化", systemImage: "doc.text.magnifyingglass", state: .complete),
      PublishDrawerFlowStep(title: "写入", detail: "下一步写入仓库", systemImage: "square.and.arrow.down", state: .active),
      PublishDrawerFlowStep(
        title: "远端",
        detail: hasToken ? "访问令牌已就绪" : "需要访问令牌",
        systemImage: hasToken ? "arrow.up.circle" : "key",
        state: hasToken ? .pending : .blocked
      ),
      PublishDrawerFlowStep(title: "部署", detail: "发布后跟踪", systemImage: "globe", state: .pending)
    ]
  }

  private func publishFlowDestination(for step: PublishDrawerFlowStep) -> PublishDrawerFlowCard {
    switch step.title {
    case "检查":
      return .checks
    case "差异":
      return .diff
    case "写入":
      return .write
    case "远端":
      return .remote
    case "部署":
      return .deployment
    default:
      return .checks
    }
  }

  private func recommendedStep(for steps: [PublishDrawerFlowStep]) -> PublishDrawerFlowCard {
    guard let currentStep = steps.first(where: { $0.state == .blocked || $0.state == .active }) else {
      return .deployment
    }
    return publishFlowDestination(for: currentStep)
  }

  private func publishFinalAction(
    for draft: ArticleDraft,
    issues: [PreflightIssue]
  ) -> PublishDrawerFinalAction {
    let steps = publishFlowSteps(draft: draft, issues: issues)
    let latestEntry = latestReleaseRecord(for: draft).map { store.releaseLedgerEntry(for: $0) }

    if let blocked = steps.first(where: { $0.state == .blocked }) {
      return PublishDrawerFinalAction(
        title: "稍后继续",
        summary: "未完成：\(blocked.title) · \(blocked.detail)。",
        systemImage: "exclamationmark.triangle",
        isDeploymentSuccessful: false
      )
    }

    if let localWrite = steps.first(where: { $0.title == "写入" && $0.state == .active }) {
      return PublishDrawerFinalAction(
        title: "稍后继续",
        summary: "未完成：\(localWrite.title) · \(localWrite.detail)。",
        systemImage: localWrite.systemImage,
        isDeploymentSuccessful: false
      )
    }

    if latestEntry?.deploymentStatus?.level == .success {
      return PublishDrawerFinalAction(
        title: "完成",
        summary: "部署已确认成功，可以结束发布流程。",
        systemImage: "checkmark.seal",
        isDeploymentSuccessful: true
      )
    }

    if let latestEntry {
      return PublishDrawerFinalAction(
        title: "稍后继续",
        summary: "未完成：部署\(latestEntry.status.localizedDisplayName)。\(latestEntry.statusMessage)",
        systemImage: latestEntry.status.systemImage,
        isDeploymentSuccessful: false
      )
    }

    if let nextStep = steps.first(where: { $0.state != .complete }) {
      return PublishDrawerFinalAction(
        title: "稍后继续",
        summary: "未完成：\(nextStep.title) · \(nextStep.detail)。",
        systemImage: nextStep.systemImage,
        isDeploymentSuccessful: false
      )
    }

    return PublishDrawerFinalAction(
      title: "关闭",
      summary: "尚未确认部署成功；关闭后可从发布记录继续核验。",
      systemImage: "clock.badge.questionmark",
      isDeploymentSuccessful: false
    )
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
  }

  private var repositoryBranchCard: some View {
    let branches = store.localRepositoryBranches
    let currentBranch = store.repositoryReport?.branchStatus?.branchName
      ?? store.localRepositoryBranches.first(where: \.isCurrent)?.name
      ?? "未识别"
    let currentBranchUpstream = branches.first(where: \.isCurrent)?.upstreamName
      ?? store.repositoryReport?.branchStatus?.upstreamName
    let profile = publishingFacade.activeProfile
    let hasBranches = !branches.isEmpty

    return PublishDrawerCard(title: "分支管理", systemImage: "arrow.triangle.branch") {
      PublishDrawerInfoRow(
        title: "当前分支",
        value: currentBranch,
        systemImage: "pin.circle"
      )
      PublishDrawerInfoRow(
        title: "目标分支",
        value: profile.branch.nilIfEmpty ?? "未配置",
        systemImage: "flag"
      )

      if let upstream = currentBranchUpstream {
        PublishDrawerInfoRow(title: "上游", value: upstream, systemImage: "link")
      } else {
        PublishDrawerInfoRow(title: "上游", value: "未配置", systemImage: "link")
      }

      Text("切换或新建分支前，工作区必须没有未提交变更；成功后会同步更新发布目标。")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineSpacing(1)

      if hasBranches {
        Text("本地工作分支")
          .font(.caption)
          .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 5) {
          ForEach(Array(branches.prefix(6))) { branch in
            HStack {
              Text(branch.name)
                .workbenchTruncatedIdentity(branch.name)
                .font(.caption.monospaced())
              Spacer()
              if branch.isCurrent {
                Label("当前", systemImage: "checkmark.circle.fill")
                  .font(.caption)
                  .foregroundStyle(WorkbenchTheme.success)
              } else {
                Button("切换") {
                  Task {
                    await store.switchActiveProfileRepositoryBranch(to: branch.name)
                  }
                }
                .controlSize(.small)
                .disabled(store.isLocalRepositoryBranchOperationRunning)
              }
            }
          }
        }
      } else {
        Text("未检测到可用分支。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Divider()

      HStack {
        TextField("新建分支名", text: $newBranchName)
          .textFieldStyle(.roundedBorder)
          .accessibilityLabel("新建分支名")
          .accessibilityValue(newBranchName.isEmpty ? "未填写" : newBranchName)
        Button {
          Task {
            await createAndSwitchBranch()
          }
        } label: {
          if store.isLocalRepositoryBranchOperationRunning {
            Label("处理中", systemImage: "hourglass")
          } else {
            Text("创建并切换")
          }
        }
        .controlSize(.small)
        .disabled(
          newBranchName.trimmedForPublishing.isEmpty
            || store.isLocalRepositoryBranchOperationRunning
        )
        .accessibilityLabel("创建并切换到新分支")
      }
    }
  }

  private var commitHistoryCard: some View {
    let commits = store.localRepositoryRecentCommits

    return PublishDrawerCard(title: "提交历史", systemImage: "clock.arrow.circlepath") {
      PublishDrawerStat(
        title: "最近提交",
        value: "\(commits.count)",
        systemImage: "list.number",
        color: WorkbenchTheme.documentForeground
      )

      if commits.isEmpty {
        Text("未查询到提交记录。")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          let defaultCount = 6
          let displayCount = min(showAllCommits ? commits.count : defaultCount, commits.count)
          let displayCommits = Array(commits.prefix(displayCount))
          ForEach(Array(displayCommits.enumerated()), id: \.offset) { index, commit in
            VStack(alignment: .leading, spacing: 2) {
              HStack(alignment: .top, spacing: 6) {
                Text(commit.shortSHA)
                  .font(.caption.monospaced())
                  .foregroundStyle(.secondary)
                Text(commit.message)
                  .font(.caption.weight(.medium))
                  .workbenchTruncatedIdentity(commit.message)
                Spacer(minLength: 0)
              }
              Text("\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if index != displayCommits.count - 1 {
              Divider()
            }
          }
          if commits.count > defaultCount {
            Button(showAllCommits ? "收起" : "显示更多") {
              showAllCommits.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.documentForeground)
            .padding(.top, 4)
            .accessibilityLabel(showAllCommits ? "收起提交历史" : "显示更多提交历史")
          }
        }
      }
    }
  }

  private func commitMethodCard(draft: ArticleDraft) -> some View {
    let profile = publishingFacade.profile(for: draft)
    let mode = store.preferredRemoteRepositoryPublishMode(for: profile)
    let readiness = store.localPublishReadiness

    return PublishDrawerCard(title: "提交方式", systemImage: "arrow.triangle.branch") {
      PublishDrawerInfoRow(title: "本地策略", value: profile.repositoryPublishStrategy.localizedDisplayName, systemImage: profile.repositoryPublishStrategy == .direct ? "checkmark.seal" : "arrow.triangle.branch")
      PublishDrawerInfoRow(title: "线上策略", value: mode.localizedDisplayName, systemImage: "network")
      PublishDrawerInfoRow(title: "写入", value: readiness?.writeReadiness.localizedDisplayName ?? "待刷新", systemImage: readiness?.writeReadiness.systemImage ?? "clock")
      PublishDrawerInfoRow(title: "提交", value: readiness?.commitReadiness.localizedDisplayName ?? "待刷新", systemImage: readiness?.commitReadiness.systemImage ?? "clock")

      HStack(spacing: 8) {
        Button {
          writeDraftToRepository(draft)
        } label: {
          Label("写入", systemImage: "square.and.arrow.down")
        }
        .disabled(readiness?.canWrite != true || store.isLocalRepositoryMutationRunning)
        .accessibilityLabel("写入本地仓库")
        .accessibilityHint(readiness?.canWrite == true ? "写入当前文章" : "当前不能写入")

        Button {
          commitDraftUsingPreferredStrategy(draft)
        } label: {
          Label(profile.repositoryPublishStrategy.localizedDisplayName, systemImage: profile.repositoryPublishStrategy == .direct ? "checkmark.seal" : "arrow.triangle.branch")
        }
        .disabled(readiness?.canCommit != true || store.isLocalRepositoryMutationRunning)
        .accessibilityLabel("提交方式：\(profile.repositoryPublishStrategy.localizedDisplayName)")
        .accessibilityHint(readiness?.canCommit == true ? "按当前策略提交文章" : "当前不能提交")
      }
      .controlSize(.small)
    }
  }

  private func reviewDescriptionCard(draft: ArticleDraft) -> some View {
    let review = store.cachedRemoteReviewDraft(for: draft)

    return PublishDrawerCard(title: "PR/MR 描述", systemImage: "text.page") {
      if let review {
        PublishDrawerInfoRow(title: "分支", value: review.branchName, systemImage: "arrow.triangle.branch")
        PublishDrawerInfoRow(title: "目标", value: review.targetBranch, systemImage: "arrow.down.to.line")

        Text(review.title)
          .font(.caption.weight(.semibold))
          .workbenchTruncatedIdentity(review.title, lineLimit: 2)

        Text(review.body)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineSpacing(2)
          .lineLimit(6)
          .textSelection(.enabled)

        Button {
          copy(review.body, message: "已复制 PR/MR 描述。")
        } label: {
          Label("复制描述", systemImage: "doc.on.doc")
        }
        .controlSize(.small)
        .accessibilityLabel("复制 PR 或 MR 描述")
      } else {
        Label("发布快照待刷新。", systemImage: "clock.arrow.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func remotePublishPreviewCard(draft: ArticleDraft) -> some View {
    let preview = store.cachedRemotePublishPreview(for: draft)

    return PublishDrawerCard(title: "线上发布预览", systemImage: "network") {
      if let preview {
      PublishDrawerInfoRow(title: "状态", value: preview.readiness.localizedDisplayName, systemImage: preview.readiness.systemImage)
      PublishDrawerInfoRow(title: "远端", value: preview.repositoryName, systemImage: preview.provider == .github ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted")
      PublishDrawerInfoRow(title: "模式", value: preview.mode.localizedDisplayName, systemImage: preview.mode == .directCommit ? "arrow.up.circle" : "arrow.triangle.pull")
      PublishDrawerInfoRow(title: "目标", value: preview.targetBranch, systemImage: "arrow.down.to.line")
      PublishDrawerInfoRow(title: "分支", value: preview.branchName, systemImage: "arrow.triangle.branch")
      PublishDrawerInfoRow(title: "权限", value: preview.accessSummary, systemImage: preview.hasToken ? "person.badge.key" : "key")

      if !preview.blockingIssues.isEmpty || !preview.warningIssues.isEmpty {
        ForEach(preview.blockingIssues) { issue in
          PublishDrawerIssueRow(issue: issue)
        }

        if !preview.warningIssues.isEmpty {
          DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(preview.warningIssues) { issue in
                PublishDrawerIssueRow(issue: issue)
              }
            }
            .padding(.top, 4)
          } label: {
            Label("警告（\(preview.warningIssues.count)）", systemImage: "exclamationmark.triangle")
              .font(.caption.weight(.medium))
              .foregroundStyle(WorkbenchTheme.warning)
          }
        }
      } else {
        let changedPaths = preview.changedPaths.prefix(3).joined(separator: "\n")
        Text(changedPaths)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(changedPaths, lineLimit: 3)
      }

      HStack(spacing: 8) {
        Button {
          Task {
            await checkRepositoryTokenAccess(for: draft)
          }
        } label: {
          Label("查权限", systemImage: "person.badge.key")
        }
        .disabled(store.isRemoteRepositoryChecking)
        .accessibilityLabel("检查仓库访问令牌权限")

        Button {
          pendingSingleOnlinePublishDraft = draft
        } label: {
          Label("审阅并发布…", systemImage: preview.mode == .directCommit ? "arrow.up.circle" : "arrow.triangle.pull")
        }
        .disabled(!preview.canPublish || store.isRemoteRepositoryPublishing)
        .accessibilityLabel("审阅并线上发布：\(preview.mode.localizedDisplayName)")
        .accessibilityHint(preview.canPublish ? "打开最终确认页" : "当前线上发布预览未通过")

        Button {
          copy(preview.checklistMarkdown, message: "已复制线上发布核对包。")
        } label: {
          Label("复制核对包", systemImage: "doc.on.doc")
        }
        .accessibilityLabel("复制线上发布核对包")
      }
      .controlSize(.small)
      } else {
        Label("发布快照待刷新。", systemImage: "clock.arrow.circlepath")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var remotePublishProgressCard: some View {
    if let progress = store.remoteRepositoryPublishProgress {
      PublishDrawerCard(title: "发布进度", systemImage: "chart.bar") {
        PublishDrawerInfoRow(
          title: "阶段",
          value: progress.stage.localizedDisplayName,
          systemImage: progress.stage == .failed ? "xmark.octagon" : "flag.checkered"
        )
        PublishDrawerInfoRow(
          title: "提示",
          value: progress.message,
          systemImage: progress.stage == .failed ? "exclamationmark.triangle" : "info.circle"
        )

        if let progressValue = progress.progress {
          ProgressView(value: progressValue) {
            Text("\(Int(progressValue * 100))%")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .progressViewStyle(.linear)
        } else {
          ProgressView()
        }

        if let detail = progress.detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineSpacing(1)
            .lineLimit(2)
        }
        if let filePath = progress.filePath {
          Text(filePath)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .workbenchTruncatedIdentity(filePath, lineLimit: 2)
        }

        if progress.stage == .completed {
          Text("已完成")
            .font(.caption.weight(.medium))
            .foregroundStyle(WorkbenchTheme.success)
        } else if progress.stage == .failed {
          Text("已失败")
            .font(.caption.weight(.medium))
            .foregroundStyle(WorkbenchTheme.risk)
        }
      }
    } else {
      PublishDrawerCard(title: "发布进度", systemImage: "chart.bar") {
        Label("暂无发布进度", systemImage: "clock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func deploymentStatusCard(draft: ArticleDraft) -> some View {
    let latestRecord = latestReleaseRecord(for: draft)
    let entry = latestRecord.map { store.releaseLedgerEntry(for: $0) }

    return PublishDrawerCard(title: "部署状态", systemImage: "checkmark.icloud") {
      PublishDrawerInfoRow(
        title: "轮询",
        value: store.deploymentPollingSettings.isEnabled ? "已开启" : "已关闭",
        systemImage: store.deploymentPollingSettings.isEnabled ? "timer" : "pause.circle"
      )
      PublishDrawerInfoRow(
        title: "待检查",
        value: "\(store.deploymentPollingEligibleRecords.count)",
        systemImage: "hourglass"
      )
      Button {
        copy(store.deploymentPollingState.followUpChecklistMarkdown, message: "已复制部署轮询后续清单。")
      } label: {
        Label("复制轮询清单", systemImage: "checklist")
      }
      .controlSize(.small)
      .disabled(store.deploymentPollingState.checkedRecords.isEmpty)
      .accessibilityLabel("复制部署轮询清单")

      if let entry {
        PublishDrawerInfoRow(title: "最近记录", value: entry.status.localizedDisplayName, systemImage: entry.status.systemImage)
        Text(entry.record.title)
          .font(.caption.weight(.medium))
          .workbenchTruncatedIdentity(entry.record.title)
        Text(entry.statusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineSpacing(1)
          .lineLimit(3)

        if let deploymentStatus = entry.deploymentStatus {
          PublishDrawerInfoRow(
            title: "校验",
            value: deploymentStatus.level.localizedDisplayName,
            systemImage: deploymentStatus.level.systemImage
          )
          PublishDrawerInfoRow(
            title: "清单",
            value: "\(deploymentStatus.postPublishCheckItems.count) 项",
            systemImage: "checklist.checked"
          )
          Button {
            copy(deploymentStatus.postPublishChecklistMarkdown, message: "已复制发布后校验报告。")
          } label: {
            Label("复制校验报告", systemImage: "doc.on.doc")
          }
          .controlSize(.small)
          .accessibilityLabel("复制发布后校验报告")
        }
      } else {
        Label("还没有发布记录。", systemImage: "clock")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let latestRecord {
        Button {
          Task {
            await store.refreshDeploymentStatus(for: latestRecord)
          }
        } label: {
          Label("检查部署", systemImage: "arrow.clockwise")
        }
        .disabled(store.isDeploymentStatusChecking || !store.canCheckDeploymentStatus(for: latestRecord))
        .controlSize(.small)
        .accessibilityLabel("检查最新部署状态")
      }
    }
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

  private func commitDraftUsingPreferredStrategy(_ draft: ArticleDraft) {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    publishingFacade.refreshPublishPreviewInBackground(for: draft)
    Task {
      await store.commitSelectedDraftUsingPreferredStrategy()
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

  @MainActor
  private func createAndSwitchBranch() async {
    let branchName = newBranchName
    await store.createAndSwitchActiveProfileRepositoryBranch(name: branchName)
    if publishingFacade.activeProfile.branch == branchName.trimmedForPublishing {
      newBranchName = ""
    }
  }

  @MainActor
  private func checkRepositoryTokenAccess(for draft: ArticleDraft) async {
    let currentSection = publishingFacade.selectedSection
    _ = publishingFacade.focusDraft(draft.id)
    await store.checkRepositoryTokenAccess()
    publishingFacade.selectSection(currentSection)
  }

  private func latestReleaseRecord(for draft: ArticleDraft) -> ReleaseRecord? {
    ReleaseRecordDraftResolver.latestRecord(
      for: draft,
      in: store.activeProfileReleaseRecords
    )
  }

  private func copy(_ value: String, message: String) {
    ClipboardWriter.copy(value, successMessage: message) { store.setPublishActionMessage($0) }
  }
}
