import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

struct RemoteRepositoryConflictResolverView: View {
  let session: RemoteRepositoryConflictSession
  let resolve:
    (RemoteRepositoryConflictResolutionPlan) async
      -> RemoteRepositoryConflictResolutionOutcome

  @Environment(\.dismiss) private var dismiss
  @State private var selectedPath: String
  @State private var draftSelection = RemoteConflictDraftSelection()
  @State private var isResolving = false
  @State private var resolutionFeedback: String?

  init(
    session: RemoteRepositoryConflictSession,
    resolve:
      @escaping (RemoteRepositoryConflictResolutionPlan) async
      -> RemoteRepositoryConflictResolutionOutcome
  ) {
    self.session = session
    self.resolve = resolve
    let firstPath = session.conflicts.first?.repositoryPath ?? ""
    _selectedPath = State(initialValue: firstPath)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if let item = selectedItem {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            targetSummary(item)
            conflictColumns(item)
            quickChoices(item)
            baseSection(item)
          }
          .padding(16)
        }
        Divider()
        footer(item)
      } else {
        ContentUnavailableView(
          "没有可协调的文本冲突",
          systemImage: "checkmark.shield",
          description: Text("请关闭面板并重新运行发布预检。")
        )
      }
    }
    .frame(minWidth: 900, idealWidth: 1180, minHeight: 620, idealHeight: 760)
    .accessibilityIdentifier("remote-repository-conflict-resolver")
    .interactiveDismissDisabled(isResolving)
  }

  private var header: some View {
    HStack(spacing: 12) {
      Label("远端三方冲突协调", systemImage: "arrow.triangle.merge")
        .font(.headline)
      Picker("冲突文件", selection: $selectedPath) {
        ForEach(session.conflicts) { item in
          Text(
            verbatim:
              "\(draftSelection.isResolved(item) ? "✓" : "○") \(item.repositoryPath)"
          )
          .tag(item.repositoryPath)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: 420)
      .disabled(isResolving)
      Spacer()
      VStack(alignment: .trailing, spacing: 3) {
        Text(
          "\(draftSelection.resolvedCount(in: session))/\(session.totalConflictCount) 已协调"
        )
        .font(.caption.weight(.semibold))
        ProgressView(
          value: Double(draftSelection.resolvedCount(in: session)),
          total: Double(max(session.totalConflictCount, 1))
        )
        .frame(width: 100)
        .accessibilityLabel("冲突协调进度")
      }
      .foregroundStyle(.secondary)
      Button("关闭") { dismiss() }
        .keyboardShortcut(.cancelAction)
        .disabled(isResolving)
    }
    .padding(16)
  }

  private var selectedItem: RemoteRepositoryConflictItem? {
    session.conflicts.first(where: { $0.repositoryPath == selectedPath })
  }

  private func targetSummary(_ item: RemoteRepositoryConflictItem) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(item.repositoryPath)
        .font(.callout.monospaced().weight(.semibold))
        .textSelection(.enabled)
      Text("远端版本：\(item.actualSHA ?? "未知") · 本地基线：\(item.expectedSHA ?? "未记录")")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
      Text("保留本地或合并内容会创建 PR/MR；不会直接覆盖目标分支。使用远端只更新草稿，不写远端。")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func conflictColumns(_ item: RemoteRepositoryConflictItem) -> some View {
    HStack(alignment: .top, spacing: 10) {
      readOnlyColumn(title: "我的修改", subtitle: "冻结发布包", content: item.local)
      readOnlyColumn(title: "远端版本", subtitle: "当前目标分支", content: item.remote)
      VStack(alignment: .leading, spacing: 5) {
        Text("合并协调区").font(.callout.weight(.semibold))
        Text("安全逐块选择；复杂格式保留完整源码")
          .font(.caption)
          .foregroundStyle(.secondary)
        if draftSelection.choice(for: item.repositoryPath) == .merge,
          let state = draftSelection.mergeState(for: item.repositoryPath)
        {
          RemoteConflictSemanticMergeWorkspace(
            state: state,
            isDisabled: isResolving,
            selectMode: { mode in
              draftSelection.selectMergeMode(mode, for: item.repositoryPath)
            },
            selectFrontMatterChoice: { conflictID, choice in
              draftSelection.selectFrontMatterChoice(
                choice,
                conflictID: conflictID,
                path: item.repositoryPath
              )
            },
            selectBodyChoice: { conflictID, choice in
              draftSelection.selectBodyChoice(
                choice,
                conflictID: conflictID,
                path: item.repositoryPath
              )
            },
            updateSource: { text in
              draftSelection.updateMergeDraft(text, for: item.repositoryPath)
            },
            confirmSource: {
              draftSelection.confirmSourceDraft(for: item.repositoryPath)
            },
            copySemanticResultToSource: {
              draftSelection.copySemanticResultToSource(for: item.repositoryPath)
            }
          )
        } else {
          Text("选择“合并双方内容”后，这里会显示逐字段和逐段落协调。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
            .background(
              WorkbenchBackgroundStyle.control,
              in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            )
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func quickChoices(_ item: RemoteRepositoryConflictItem) -> some View {
    HStack(spacing: 10) {
      choiceButton(
        "保留我的修改",
        systemImage: "person.crop.circle.badge.checkmark",
        choice: .keepLocal,
        item: item,
        enabled: item.canKeepLocalOperation
      )
      choiceButton(
        "使用远端版本",
        systemImage: "cloud.badge.checkmark",
        choice: .useRemote,
        item: item,
        enabled: item.canUseRemoteText
      )
      choiceButton(
        "合并双方内容",
        systemImage: "arrow.triangle.merge",
        choice: .merge,
        item: item,
        enabled: item.canMergeText
      )
    }
  }

  private func choiceButton(
    _ title: LocalizedStringKey,
    systemImage: String,
    choice: RemoteRepositoryConflictResolutionChoice,
    item: RemoteRepositoryConflictItem,
    enabled: Bool
  ) -> some View {
    let isSelected = draftSelection.choice(for: item.repositoryPath) == choice
    return Button {
      draftSelection.select(
        path: item.repositoryPath,
        choice: choice,
        base: item.base.text,
        local: item.local.text,
        remote: item.remote.text
      )
    } label: {
      HStack(spacing: 8) {
        Label(title, systemImage: systemImage)
        Spacer(minLength: 4)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 30)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .tint(isSelected ? .accentColor : nil)
    .disabled(!enabled || isResolving)
    .help(choiceAvailabilityHelp(choice, item: item, enabled: enabled))
    .accessibilityValue(isSelected ? "已选择" : "未选择")
    .accessibilityIdentifier("remote-conflict-choice-\(choice.rawValue)")
  }

  private func choiceAvailabilityHelp(
    _ choice: RemoteRepositoryConflictResolutionChoice,
    item: RemoteRepositoryConflictItem,
    enabled: Bool
  ) -> String {
    guard !enabled else {
      switch choice {
      case .keepLocal:
        return item.operation == .delete
          ? String(localized: "通过 PR/MR 继续本地下线操作")
          : String(localized: "通过 PR/MR 保留本地发布内容")
      case .useRemote:
        return String(localized: "导入当前远端 Markdown，不写入远端")
      case .merge:
        return String(localized: "逐块协调 Front Matter 与正文，并通过 PR/MR 交付")
      }
    }
    switch choice {
    case .keepLocal:
      return String(localized: "当前操作暂不可用")
    case .useRemote:
      return String(localized: "只有可安全解码的远端 Markdown 才能导入")
    case .merge:
      return String(localized: "只有本地和远端都是可编辑 Markdown 时才能合并")
    }
  }

  private func baseSection(_ item: RemoteRepositoryConflictItem) -> some View {
    DisclosureGroup("查看共同基线") {
      ScrollView {
        Text(verbatim: item.base.displayText)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(8)
      }
      .frame(minHeight: 100, maxHeight: 220)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
    }
  }

  private func footer(_ item: RemoteRepositoryConflictItem) -> some View {
    HStack {
      Text(resolutionFeedback ?? transactionExplanation(for: item))
        .font(.caption)
        .foregroundStyle(resolutionFeedback == nil ? Color.secondary : Color.orange)
      Spacer()
      if isResolving { ProgressView().controlSize(.small) }
      Button(transactionActionTitle) {
        guard let plan = draftSelection.resolutionPlan(for: session) else { return }
        isResolving = true
        Task {
          let outcome = await resolve(plan)
          await MainActor.run {
            isResolving = false
            resolutionFeedback = outcome.message
            if outcome.shouldDismissResolver {
              dismiss()
            }
          }
        }
      }
      .workbenchProminentActionStyle()
      .disabled(draftSelection.resolutionPlan(for: session) == nil || isResolving)
      .keyboardShortcut(.return, modifiers: [.command])
      .accessibilityIdentifier("remote-conflict-apply-all")
    }
    .padding(16)
  }

  private var transactionActionTitle: String {
    guard draftSelection.resolutionPlan(for: session) != nil else {
      return String(localized: "请先协调全部文件")
    }
    let requiresReviewRequest = session.conflicts.contains { item in
      switch draftSelection.choice(for: item.repositoryPath) {
      case .keepLocal, .merge: return true
      case .useRemote, nil: return false
      }
    }
    return requiresReviewRequest
      ? String(localized: "应用全部协调并创建 PR/MR")
      : String(localized: "应用全部协调")
  }

  private func transactionExplanation(for item: RemoteRepositoryConflictItem) -> String {
    guard session.hasCompleteConflictSnapshot else {
      return String(
        format: String(localized: "冲突共 %d 个，超过单次安全协调上限；请缩小发布批次后重试。"),
        session.totalConflictCount
      )
    }
    let unresolvedPaths = draftSelection.unresolvedPaths(in: session)
    if !unresolvedPaths.isEmpty {
      return String(
        format: String(localized: "还需协调 %d 个文件；当前选择只会保存在面板中。"),
        unresolvedPaths.count
      )
    }
    let invalidPaths = draftSelection.invalidPaths(in: session)
    if !invalidPaths.isEmpty {
      if let state = draftSelection.mergeState(for: item.repositoryPath),
        state.mode == .semantic,
        state.unresolvedSemanticCount > 0
      {
        return String(
          format: String(localized: "当前文件还有 %d 个冲突块待选择。"),
          state.unresolvedSemanticCount
        )
      }
      return String(
        format: String(localized: "%d 个最终合并版无效或仍含冲突标记。"),
        invalidPaths.count
      )
    }
    switch draftSelection.choice(for: item.repositoryPath) {
    case .keepLocal:
      return String(localized: "全部选择已就绪；确认后统一校验，并只创建一次 PR/MR。")
    case .useRemote:
      return String(localized: "全部选择已就绪；确认后统一应用，只有需要交付的修改才创建 PR/MR。")
    case .merge:
      return String(localized: "全部选择已就绪；确认后统一应用合并稿，并只创建一次 PR/MR。")
    case nil:
      return String(localized: "当前选择只会保存在面板中。")
    }
  }

  private func readOnlyColumn(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey,
    content: RepositoryMergeConflictContent
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.callout.weight(.semibold))
      Text(subtitle).font(.caption).foregroundStyle(.secondary)
      ScrollView {
        Text(verbatim: content.displayText)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(8)
      }
      .frame(minHeight: 320)
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

}
