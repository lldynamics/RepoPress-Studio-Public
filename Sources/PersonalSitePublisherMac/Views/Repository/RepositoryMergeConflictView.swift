import AppKit
import PublishingGitCore
import PublishingWorkbenchCore
import SwiftUI

private enum ConflictViewLayoutMode: String, CaseIterable, Identifiable {
  case threeWay = "三栏合并"
  case twoWay = "双栏对比"

  var id: String { rawValue }
}

private enum DualColumnSource: String, CaseIterable, Identifiable {
  case ours = "本地版本 (Ours)"
  case theirs = "远程版本 (Theirs)"
  case base = "共同基线 (Base)"

  var id: String { rawValue }
}

enum RepositoryMergeConflictDraftChoice: Equatable {
  case ours
  case theirs
  case manualMerge
}

/// Pure preparation policy for the visual resolver. A choice never performs
/// I/O. Missing sides stay unavailable so a delete conflict cannot be silently
/// converted into an empty file.
struct RepositoryMergeConflictDraftPolicy {
  static func preparedText(
    for choice: RepositoryMergeConflictDraftChoice,
    conflict: RepositoryMergeConflict
  ) -> String? {
    switch choice {
    case .ours:
      return conflict.ours.isText ? conflict.ours.text : nil
    case .theirs:
      return conflict.theirs.isText ? conflict.theirs.text : nil
    case .manualMerge:
      guard conflict.canResolve, let finalText = conflict.final.text else { return nil }
      if let markerFreeDraft = markerFreeWorkingTreeDraft(finalText) {
        return markerFreeDraft
      }
      if containsGitConflictMarker(finalText) {
        return conflict.ours.text ?? conflict.theirs.text
      }
      return finalText
    }
  }

  static func initialText(for conflict: RepositoryMergeConflict) -> String {
    preparedText(for: .manualMerge, conflict: conflict)
      ?? preparedText(for: .ours, conflict: conflict)
      ?? preparedText(for: .theirs, conflict: conflict)
      ?? ""
  }

  /// Keep the ours/theirs sections from Git's working-tree merge seed,
  /// discard the optional base section, and remove every marker line.
  static func markerFreeWorkingTreeDraft(_ text: String) -> String? {
    enum Region: Equatable { case normal, ours, base, theirs }
    var region = Region.normal
    var sawStart = false
    var sawEnd = false
    var output: [String] = []

    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("<<<<<<<") {
        sawStart = true
        region = .ours
        continue
      }
      if line.hasPrefix("|||||||") && region == .ours {
        region = .base
        continue
      }
      if line.hasPrefix("=======") && (region == .ours || region == .base) {
        region = .theirs
        continue
      }
      if line.hasPrefix(">>>>>>>") && region == .theirs {
        sawEnd = true
        region = .normal
        continue
      }
      if region != .base {
        output.append(line)
      }
    }

    guard sawStart, sawEnd, region == .normal else { return nil }
    return output.joined(separator: "\n")
  }

  private static func containsGitConflictMarker(_ text: String) -> Bool {
    text.components(separatedBy: "\n").contains { line in
      line.hasPrefix("<<<<<<<")
        || line.hasPrefix("|||||||")
        || line.hasPrefix("=======")
        || line.hasPrefix(">>>>>>>")
    }
  }
}

private struct RepositoryMergeQuickChoiceBar: View {
  let conflict: RepositoryMergeConflict
  let choose: (RepositoryMergeConflictDraftChoice) -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) { buttons }
      VStack(spacing: 8) { buttons }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("冲突快捷选择")
  }

  @ViewBuilder
  private var buttons: some View {
    choiceButton(
      title: "保留我的修改",
      systemImage: "person.crop.circle.badge.checkmark",
      choice: .ours
    )
    choiceButton(
      title: "使用远端版本",
      systemImage: "cloud.badge.checkmark",
      choice: .theirs
    )
    choiceButton(
      title: "合并双方内容",
      systemImage: "arrow.triangle.merge",
      choice: .manualMerge
    )
  }

  private func choiceButton(
    title: LocalizedStringKey,
    systemImage: String,
    choice: RepositoryMergeConflictDraftChoice
  ) -> some View {
    Button {
      choose(choice)
    } label: {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity, minHeight: 28)
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
    .disabled(
      RepositoryMergeConflictDraftPolicy.preparedText(for: choice, conflict: conflict) == nil
    )
    .accessibilityIdentifier(accessibilityIdentifier(for: choice))
    .help(
      RepositoryMergeConflictDraftPolicy.preparedText(for: choice, conflict: conflict) == nil
        ? String(localized: "该版本不是可安全编辑的文本；不会将删除语义改成空文件。")
        : String(localized: "只准备最终内容，不会写入或暂存。")
    )
  }

  private func accessibilityIdentifier(
    for choice: RepositoryMergeConflictDraftChoice
  ) -> String {
    switch choice {
    case .ours: return "repository-merge-choose-ours"
    case .theirs: return "repository-merge-choose-theirs"
    case .manualMerge: return "repository-merge-choose-both"
    }
  }
}

/// A bounded, explicit three-way merge surface for files that Git left in its
/// unmerged index. Only the final column is editable; no side is auto-applied.
struct RepositoryMergeConflictView: View {
  let session: RepositoryMergeConflictSession
  let resolveAction: (String, String) async throws -> Void

  @State private var selectedPath: String?
  @State private var finalTexts: [String: String]
  @State private var resolvingPath: String?
  @State private var feedbackMessage: String?
  @State private var feedbackSeverity: AccessibleStatusSeverity = .info
  @State private var layoutMode: ConflictViewLayoutMode = .threeWay
  @State private var dualColumnSource: DualColumnSource = .ours
  @State private var isBaseSheetPresented = false
  @State private var isMaximizeSheetPresented = false
  @State private var hasAutomaticallyPresentedResolver = false

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
          (conflict.repositoryPath, RepositoryMergeConflictDraftPolicy.initialText(for: conflict))
        }
      )
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

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
        fileSelectorAndControls

        if let selectedConflict {
          conflictColumns(for: selectedConflict)
        }
      }

      if let feedbackMessage {
        AccessibleStatusMessage(
          message: feedbackMessage,
          severity: feedbackSeverity,
          announcesNonUrgentStatus: true
        )
        .font(.caption)
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
    .sheet(isPresented: $isBaseSheetPresented) {
      if let selectedConflict {
        RepositoryMergeBaseSheet(
          path: selectedConflict.repositoryPath,
          baseContent: selectedConflict.base
        )
      }
    }
    .sheet(isPresented: $isMaximizeSheetPresented) {
      if let selectedConflict {
        RepositoryMergeMaximizedSheet(
          conflict: selectedConflict,
          layoutMode: $layoutMode,
          dualColumnSource: $dualColumnSource,
          finalText: finalBinding(for: selectedConflict),
          resolvingPath: resolvingPath,
          onChoose: { prepare($0, for: selectedConflict) },
          onResolve: { resolve(selectedConflict) },
          onOpenBaseSheet: { isBaseSheetPresented = true }
        )
      }
    }
    .onAppear {
      guard !session.conflicts.isEmpty, !hasAutomaticallyPresentedResolver else { return }
      hasAutomaticallyPresentedResolver = true
      isMaximizeSheetPresented = true
    }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Label("Git 冲突合并", systemImage: "arrow.left.arrow.right.square")
        .font(.workbenchSectionTitle)
        .accessibilityAddTraits(.isHeader)
      Spacer()
      Text("\(session.conflicts.count) 个未解决文件")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var fileSelectorAndControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 12) {
        Picker("冲突文件", selection: selectedPathBinding) {
          ForEach(session.conflicts) { conflict in
            Text(conflict.repositoryPath)
              .tag(Optional(conflict.repositoryPath))
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("repository-merge-conflict-file-picker")

        Spacer(minLength: 8)

        Picker("视图模式", selection: $layoutMode) {
          ForEach(ConflictViewLayoutMode.allCases) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 180)
        .accessibilityIdentifier("repository-merge-conflict-layout-picker")

        Button {
          isMaximizeSheetPresented = true
        } label: {
          Label("最大化合并窗口", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("repository-merge-conflict-maximize-button")
      }

      VStack(alignment: .leading, spacing: 8) {
        Picker("冲突文件", selection: selectedPathBinding) {
          ForEach(session.conflicts) { conflict in
            Text(conflict.repositoryPath)
              .tag(Optional(conflict.repositoryPath))
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("repository-merge-conflict-file-picker")

        HStack {
          Picker("视图模式", selection: $layoutMode) {
            ForEach(ConflictViewLayoutMode.allCases) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .frame(maxWidth: 180)
          .accessibilityIdentifier("repository-merge-conflict-layout-picker")

          Spacer()

          Button {
            isMaximizeSheetPresented = true
          } label: {
            Label("最大化合并窗口", systemImage: "arrow.up.left.and.arrow.down.right")
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
          .accessibilityIdentifier("repository-merge-conflict-maximize-button")
        }
      }
    }
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
      if layoutMode == .threeWay {
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
      } else {
        HStack(alignment: .top, spacing: 10) {
          dualColumnSourceView(for: conflict)
          mergeColumn(
            title: "最终合并版",
            subtitle: "仅此列可编辑",
            content: conflict.final,
            isEditable: conflict.canResolve,
            text: finalBinding(for: conflict)
          )
        }
      }

      RepositoryMergeQuickChoiceBar(conflict: conflict) { choice in
        prepare(choice, for: conflict)
      }

      baselineSection(for: conflict)

      HStack {
        Spacer()
        Button {
          resolve(conflict)
        } label: {
          Label("应用最终版本并暂存", systemImage: "checkmark.circle")
        }
        .workbenchProminentActionStyle()
        .disabled(!conflict.canResolve || resolvingPath != nil)
        .accessibilityIdentifier("repository-merge-conflict-resolve")
      }
    }
  }

  private func dualColumnSourceView(for conflict: RepositoryMergeConflict) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Picker("对比源版本", selection: $dualColumnSource) {
        ForEach(DualColumnSource.allCases) { src in
          Text(src.rawValue).tag(src)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("repository-merge-conflict-dual-source-picker")

      let content: RepositoryMergeConflictContent = {
        switch dualColumnSource {
        case .ours: return conflict.ours
        case .theirs: return conflict.theirs
        case .base: return conflict.base
        }
      }()

      let subtitle: LocalizedStringKey = {
        switch dualColumnSource {
        case .ours: return "Git stage 2 / 本地修改"
        case .theirs: return "Git stage 3 / 远程修改"
        case .base: return "Git stage 1 / 共同基线"
        }
      }()

      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)

      mergeReadOnlyText(
        content,
        identifier: "repository-merge-conflict-read-only"
      )
      .frame(minHeight: 220, maxHeight: 420)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func baselineSection(for conflict: RepositoryMergeConflict) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("共同基线（stage 1）内容：")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            isBaseSheetPresented = true
          } label: {
            Label("在独立窗口查看完整基线", systemImage: "arrow.up.forward.app")
          }
          .buttonStyle(.borderless)
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.documentForeground)
          .accessibilityIdentifier("repository-merge-conflict-open-base-sheet")
        }

        mergeReadOnlyText(
          conflict.base,
          identifier: "repository-merge-conflict-base"
        )
        .frame(minHeight: 80, maxHeight: 180)
      }
    } label: {
      HStack {
        Label("查看共同基线（stage 1）", systemImage: "arrow.triangle.branch")
          .font(.caption.weight(.medium))
        Spacer()
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
          .accessibilityLabel("最终合并版编辑区")
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

  private func prepare(
    _ choice: RepositoryMergeConflictDraftChoice,
    for conflict: RepositoryMergeConflict
  ) {
    guard
      let text = RepositoryMergeConflictDraftPolicy.preparedText(
        for: choice,
        conflict: conflict
      )
    else {
      feedbackMessage = String(
        localized: "该选择不能安全转换为文本文件，已保留当前最终版。"
      )
      feedbackSeverity = .warning
      return
    }
    finalTexts[conflict.repositoryPath] = text
    feedbackMessage =
      choice == .manualMerge
      ? String(localized: "已准备无 Git 标记的合并草稿；请审阅后再应用。")
      : String(localized: "已将所选版本装入最终编辑区；尚未写入或暂存。")
    feedbackSeverity = .info
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
          feedbackSeverity = .success
        }
      } catch {
        await MainActor.run {
          resolvingPath = nil
          feedbackMessage = "处理失败：\(error.localizedDescription)"
          feedbackSeverity = .error
        }
      }
    }
  }
}

private struct RepositoryMergeBaseSheet: View {
  @Environment(\.dismiss) private var dismiss
  let path: String
  let baseContent: RepositoryMergeConflictContent
  @State private var copyFeedback = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("共同基线（stage 1）- \(path)", systemImage: "arrow.triangle.branch")
          .font(.headline)
        Spacer()
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(baseContent.displayText, forType: .string)
          copyFeedback = true
          Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copyFeedback = false
          }
        } label: {
          Label(
            copyFeedback ? "已复制" : "复制全文",
            systemImage: copyFeedback ? "checkmark" : "doc.on.doc"
          )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(14)

      Divider()

      ScrollView {
        Text(verbatim: baseContent.displayText)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(16)
      }
      .background(WorkbenchBackgroundStyle.control)
    }
    .frame(minWidth: 700, idealWidth: 840, minHeight: 500, idealHeight: 650)
    .accessibilityLabel("共同基线查看窗口")
  }
}

private struct RepositoryMergeMaximizedSheet: View {
  @Environment(\.dismiss) private var dismiss
  let conflict: RepositoryMergeConflict
  @Binding var layoutMode: ConflictViewLayoutMode
  @Binding var dualColumnSource: DualColumnSource
  @Binding var finalText: String
  let resolvingPath: String?
  let onChoose: (RepositoryMergeConflictDraftChoice) -> Void
  let onResolve: () -> Void
  let onOpenBaseSheet: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Label("冲突合并 - \(conflict.repositoryPath)", systemImage: "arrow.left.arrow.right.square")
            .font(.headline)
          Text("在此独立大窗口中比对并编辑最终合并内容。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()

        Picker("视图模式", selection: $layoutMode) {
          ForEach(ConflictViewLayoutMode.allCases) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 180)

        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(14)

      Divider()

      VStack(spacing: 12) {
        if layoutMode == .threeWay {
          HStack(alignment: .top, spacing: 12) {
            columnBox(
              title: "本地版本 (Ours)",
              subtitle: "Git stage 2",
              content: conflict.ours.displayText
            )
            columnBox(
              title: "远程版本 (Theirs)",
              subtitle: "Git stage 3",
              content: conflict.theirs.displayText
            )
            editorBox
          }
        } else {
          HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
              Picker("对比源版本", selection: $dualColumnSource) {
                ForEach(DualColumnSource.allCases) { src in
                  Text(src.rawValue).tag(src)
                }
              }
              .pickerStyle(.segmented)

              let text = {
                switch dualColumnSource {
                case .ours: return conflict.ours.displayText
                case .theirs: return conflict.theirs.displayText
                case .base: return conflict.base.displayText
                }
              }()
              columnBox(title: "参考源版本", subtitle: dualColumnSource.rawValue, content: text)
            }
            editorBox
          }
        }
      }
      .padding(14)
      .frame(maxHeight: .infinity)

      RepositoryMergeQuickChoiceBar(conflict: conflict, choose: onChoose)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)

      Divider()

      HStack {
        Button {
          onOpenBaseSheet()
        } label: {
          Label("查看共同基线", systemImage: "arrow.triangle.branch")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Spacer()

        Button {
          onResolve()
          dismiss()
        } label: {
          Label("应用最终版本并暂存", systemImage: "checkmark.circle")
        }
        .workbenchProminentActionStyle()
        .disabled(!conflict.canResolve || resolvingPath != nil)
      }
      .padding(14)
    }
    .frame(minWidth: 960, idealWidth: 1100, minHeight: 640, idealHeight: 780)
    .accessibilityLabel("最大化冲突合并窗口")
  }

  private func columnBox(title: String, subtitle: String, content: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.callout.weight(.semibold))
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
      ScrollView {
        Text(verbatim: content)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(8)
      }
      .background(
        WorkbenchBackgroundStyle.control,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }

  private var editorBox: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("最终合并版")
        .font(.callout.weight(.semibold))
      Text("仅此列可编辑")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextEditor(text: $finalText)
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(
          WorkbenchBackgroundStyle.control,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
        .disabled(!conflict.canResolve)
        .accessibilityLabel("全屏最终合并版编辑区")
        .accessibilityIdentifier("repository-merge-maximized-final-editor")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}
