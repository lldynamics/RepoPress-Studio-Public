import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

/// A bounded, explicit three-way merge surface for files that Git left in its
/// unmerged index. Only the final column is editable; no side is auto-applied.
struct RepositoryMergeConflictView: View {
  let session: RepositoryMergeConflictSession
  let resolveAction: (String, String) async throws -> Void

  @State private var selectedPath: String?
  @State private var finalTexts: [String: String]
  @State private var resolvingPath: String?
  @State private var feedbackMessage: String?

  init(
    session: RepositoryMergeConflictSession,
    resolveAction: @escaping (String, String) async throws -> Void
  ) {
    self.session = session
    self.resolveAction = resolveAction
    let firstPath = session.conflicts.first?.repositoryPath
    _selectedPath = State(initialValue: firstPath)
    _finalTexts = State(
      initialValue: Dictionary(
        uniqueKeysWithValues: session.conflicts.map { conflict in
          (conflict.repositoryPath, conflict.final.text ?? "")
        }
      )
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Label("Git 冲突合并", systemImage: "arrow.left.arrow.right.square")
          .font(.workbenchSectionTitle)
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Text(String(session.conflicts.count) + " 个未解决文件")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text("先比较本地、远程和最终版本；只有点击“应用最终版本并暂存”后，才会写入工作区并执行 git add。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if let diagnostic = session.diagnostic {
        Label(diagnostic, systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.warning)
          .fixedSize(horizontal: false, vertical: true)
      }

      if !session.conflicts.isEmpty {
        Picker("冲突文件", selection: selectedPathBinding) {
          ForEach(session.conflicts) { conflict in
            Text(conflict.repositoryPath)
              .tag(Optional(conflict.repositoryPath))
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("repository-merge-conflict-file-picker")

        if let selectedConflict {
          conflictColumns(for: selectedConflict)
        }
      }

      if let feedbackMessage {
        Label(feedbackMessage, systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.success)
          .textSelection(.enabled)
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      WorkbenchBackgroundStyle.card,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.card)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("repository-section-merge-conflicts")
  }

  private var selectedConflict: RepositoryMergeConflict? {
    let path = selectedPath ?? session.conflicts.first?.repositoryPath
    return session.conflicts.first { $0.repositoryPath == path }
  }

  private var selectedPathBinding: Binding<String?> {
    Binding(
      get: { selectedPath ?? session.conflicts.first?.repositoryPath },
      set: { selectedPath = $0 }
    )
  }

  private func conflictColumns(for conflict: RepositoryMergeConflict) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 10) {
        mergeColumn(
          title: "本地版本",
          subtitle: "Git stage 2 / ours",
          content: conflict.ours,
          isEditable: false
        )
        mergeColumn(
          title: "远程版本",
          subtitle: "Git stage 3 / theirs",
          content: conflict.theirs,
          isEditable: false
        )
        mergeColumn(
          title: "最终合并版",
          subtitle: "仅此列可编辑",
          content: conflict.final,
          isEditable: conflict.canResolve,
          text: finalBinding(for: conflict)
        )
      }

      DisclosureGroup {
        mergeReadOnlyText(
          conflict.base,
          identifier: "repository-merge-conflict-base"
        )
        .frame(minHeight: 80, maxHeight: 180)
      } label: {
        Label("查看共同基线（stage 1）", systemImage: "arrow.triangle.branch")
          .font(.caption.weight(.medium))
      }

      HStack {
        Spacer()
        Button {
          resolve(conflict)
        } label: {
          Label("应用最终版本并暂存", systemImage: "checkmark.circle")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!conflict.canResolve || resolvingPath != nil)
        .accessibilityIdentifier("repository-merge-conflict-resolve")
      }
    }
  }

  @ViewBuilder
  private func mergeColumn(
    title: LocalizedStringKey,
    subtitle: LocalizedStringKey,
    content: RepositoryMergeConflictContent,
    isEditable: Bool,
    text: Binding<String>? = nil
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title)
        .font(.callout.weight(.semibold))
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)

      if isEditable, let text {
        TextEditor(text: text)
          .font(.system(.body, design: .monospaced))
          .scrollContentBackground(.hidden)
          .padding(6)
          .background(
            WorkbenchBackgroundStyle.control,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
          .frame(minHeight: 220, maxHeight: 420)
          .accessibilityIdentifier("repository-merge-conflict-final-editor")
      } else {
        mergeReadOnlyText(
          content,
          identifier: "repository-merge-conflict-read-only"
        )
        .frame(minHeight: 220, maxHeight: 420)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func mergeReadOnlyText(
    _ content: RepositoryMergeConflictContent,
    identifier: String
  ) -> some View {
    ScrollView {
      Text(verbatim: content.displayText)
        .font(.system(.body, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(8)
    }
    .background(
      WorkbenchBackgroundStyle.control,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
    .accessibilityIdentifier(identifier)
  }

  private func finalBinding(for conflict: RepositoryMergeConflict) -> Binding<String> {
    Binding(
      get: { finalTexts[conflict.repositoryPath] ?? conflict.final.text ?? "" },
      set: { finalTexts[conflict.repositoryPath] = $0 }
    )
  }

  private func resolve(_ conflict: RepositoryMergeConflict) {
    let path = conflict.repositoryPath
    let content = finalTexts[path] ?? conflict.final.text ?? ""
    resolvingPath = path
    feedbackMessage = nil
    Task {
      do {
        try await resolveAction(path, content)
        await MainActor.run {
          resolvingPath = nil
          feedbackMessage = "已暂存 " + path + "，正在刷新冲突列表。"
        }
      } catch {
        await MainActor.run {
          resolvingPath = nil
          feedbackMessage = "处理失败：\(error.localizedDescription)"
        }
      }
    }
  }
}
