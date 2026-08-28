import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

struct RemoteRepositoryConflictResolverView: View {
  let session: RemoteRepositoryConflictSession
  let resolve:
    (String, RemoteRepositoryConflictResolutionChoice, String?) async
      -> RemoteRepositoryConflictResolutionOutcome

  @Environment(\.dismiss) private var dismiss
  @State private var selectedPath: String
  @State private var choices: [String: RemoteRepositoryConflictResolutionChoice] = [:]
  @State private var finalDocuments: [String: String]
  @State private var isResolving = false
  @State private var resolutionFeedback: String?

  init(
    session: RemoteRepositoryConflictSession,
    resolve:
      @escaping (String, RemoteRepositoryConflictResolutionChoice, String?) async
      -> RemoteRepositoryConflictResolutionOutcome
  ) {
    self.session = session
    self.resolve = resolve
    let firstPath = session.conflicts.first?.repositoryPath ?? ""
    _selectedPath = State(initialValue: firstPath)
    _finalDocuments = State(
      initialValue: Dictionary(
        uniqueKeysWithValues: session.conflicts.compactMap { item in
          item.local.text.map { (item.repositoryPath, $0) }
        }
      )
    )
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
  }

  private var header: some View {
    HStack(spacing: 12) {
      Label("远端三方冲突协调", systemImage: "arrow.triangle.merge")
        .font(.headline)
      Picker("冲突文件", selection: $selectedPath) {
        ForEach(session.conflicts) { item in
          Text(item.repositoryPath).tag(item.repositoryPath)
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: 420)
      Spacer()
      Text("\(session.conflicts.count) 个冲突")
        .font(.caption)
        .foregroundStyle(.secondary)
      Button("关闭") { dismiss() }
        .keyboardShortcut(.cancelAction)
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
        Text("最终合并版").font(.callout.weight(.semibold))
        Text("选择“合并双方内容”后可编辑")
          .font(.caption)
          .foregroundStyle(.secondary)
        TextEditor(text: finalDocumentBinding(for: item))
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(6)
          .background(
            WorkbenchBackgroundStyle.control,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
          .disabled(choices[item.repositoryPath] != .merge)
          .frame(minHeight: 320)
          .accessibilityLabel("最终合并版")
          .accessibilityIdentifier("remote-conflict-final-editor")
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
    let isSelected = choices[item.repositoryPath] == choice
    return Button {
      choices[item.repositoryPath] = choice
      switch choice {
      case .keepLocal, .merge:
        if let text = item.local.text { finalDocuments[item.repositoryPath] = text }
      case .useRemote:
        if let text = item.remote.text { finalDocuments[item.repositoryPath] = text }
      }
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
        return String(localized: "编辑最终合并版并通过 PR/MR 交付")
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
      Text(resolutionFeedback ?? actionExplanation(for: item))
        .font(.caption)
        .foregroundStyle(resolutionFeedback == nil ? Color.secondary : Color.orange)
      Spacer()
      if isResolving { ProgressView().controlSize(.small) }
      Button(actionTitle(for: item)) {
        guard let choice = choices[item.repositoryPath] else { return }
        isResolving = true
        Task {
          let outcome = await resolve(
            item.repositoryPath,
            choice,
            choice == .merge ? finalDocuments[item.repositoryPath] : nil
          )
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
      .disabled(choices[item.repositoryPath] == nil || isResolving)
      .keyboardShortcut(.return, modifiers: [.command])
      .accessibilityIdentifier("remote-conflict-apply")
    }
    .padding(16)
  }

  private func actionTitle(for item: RemoteRepositoryConflictItem) -> String {
    switch choices[item.repositoryPath] {
    case .keepLocal:
      return item.operation == .delete
        ? String(localized: "创建 PR/MR 继续下线")
        : String(localized: "创建 PR/MR 保留我的修改")
    case .useRemote: return String(localized: "采用远端版本")
    case .merge: return String(localized: "应用合并并创建 PR/MR")
    case nil: return String(localized: "请选择处理方式")
    }
  }

  private func actionExplanation(for item: RemoteRepositoryConflictItem) -> String {
    switch choices[item.repositoryPath] {
    case .keepLocal:
      return item.operation == .delete
        ? String(localized: "将在独立分支提交下线操作并创建 PR/MR，目标分支不会被直接修改。")
        : String(localized: "将在独立分支提交并创建 PR/MR，目标分支不会被直接覆盖。")
    case .useRemote:
      return String(localized: "将先保存草稿历史，再导入当前远端正文；不会写远端。")
    case .merge:
      return String(localized: "将更新草稿并通过 PR/MR 交付合并结果。")
    case nil:
      return String(localized: "三个快捷按钮只准备选择；确认后才执行。")
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

  private func finalDocumentBinding(for item: RemoteRepositoryConflictItem) -> Binding<String> {
    Binding(
      get: { finalDocuments[item.repositoryPath] ?? item.local.text ?? "" },
      set: { finalDocuments[item.repositoryPath] = $0 }
    )
  }
}
