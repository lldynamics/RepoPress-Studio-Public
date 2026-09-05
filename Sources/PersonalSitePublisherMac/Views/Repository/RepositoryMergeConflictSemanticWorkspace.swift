import PublishingMarkdownCore
import SwiftUI

/// Shared by the inline resolver and its maximized sheet so both surfaces edit
/// the exact same parent-owned `RepositoryMergeConflictSemanticDraft`.
struct RepositoryMergeConflictSemanticWorkspace: View {
  let state: RepositoryMergeConflictSemanticDraft
  let isDisabled: Bool
  let selectMode: (RepositoryMergeConflictSemanticMode) -> Void
  let selectFrontMatterChoice: (String, MarkdownThreeWayMergeFieldChoice) -> Void
  let selectBodyChoice: (Int, MarkdownThreeWayMergeBodyChoice) -> Void
  let copySemanticResultToSource: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      modeSelector
      semanticWorkspace
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityIdentifier("repository-merge-semantic-workspace")
  }

  private var modeSelector: some View {
    HStack(spacing: 8) {
      modeButton(
        "逐块协调", image: "rectangle.split.2x1", mode: .semantic,
        enabled: state.canUseSemanticMode)
      modeButton(
        "完整源码", image: "chevron.left.forwardslash.chevron.right", mode: .source,
        enabled: true)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("合并方式")
  }

  private func modeButton(
    _ title: LocalizedStringKey,
    image: String,
    mode: RepositoryMergeConflictSemanticMode,
    enabled: Bool
  ) -> some View {
    let selected = state.mode == mode
    return Button {
      selectMode(mode)
    } label: {
      Label(title, systemImage: image).frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(selected ? .accentColor : nil)
    .disabled(isDisabled || !enabled)
    .accessibilityValue(selected ? "已选择" : "未选择")
    .accessibilityIdentifier("repository-merge-semantic-mode-\(mode.rawValue)")
  }

  @ViewBuilder
  private var semanticWorkspace: some View {
    if let plan = state.semanticPlan {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 5) {
          Label("安全三方合并", systemImage: "checkmark.shield")
            .font(.callout.weight(.semibold))
          Text(
            String(
              format: String(localized: "已自动合并 %d 个元数据字段和 %d 个正文片段。"),
              plan.autoMergedFrontMatterFieldCount,
              plan.autoMergedBodyHunkCount
            )
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if state.unresolvedSemanticCount > 0 {
            Text(
              String(
                format: String(localized: "还需逐块协调 %d 处；完成前不能应用最终版本。"),
                state.unresolvedSemanticCount
              )
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
            .accessibilityIdentifier("repository-merge-semantic-unresolved-count")
          }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))

        ForEach(plan.frontMatterConflicts) { frontMatterCard($0) }
        ForEach(plan.bodyConflicts) { bodyCard($0) }
        semanticCompletion(plan)
      }
    } else {
      RepositoryMergeConflictSemanticUnavailableBanner(
        reason: state.semanticUnavailableReason
      )
    }
  }

  private func frontMatterCard(_ conflict: MarkdownThreeWayMergeFieldConflict) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Label("Front Matter 字段", systemImage: "list.bullet.rectangle")
          .font(.caption.weight(.semibold))
        Text(verbatim: conflict.key).font(.caption.monospaced().weight(.semibold))
        Spacer()
        selectionStatus(state.frontMatterChoices[conflict.id] != nil)
      }
      sourceBlock("共同基线", text: conflict.base, color: .secondary)
      sourceBlock("我的修改", text: conflict.local, color: .blue)
      sourceBlock("远端版本", text: conflict.remote, color: .green)
      HStack(spacing: 8) {
        fieldChoiceButton("使用我的字段", choice: .local, conflict: conflict)
        fieldChoiceButton("使用远端字段", choice: .remote, conflict: conflict)
      }
    }
    .semanticCard()
    .accessibilityIdentifier("repository-merge-front-matter-\(conflict.id)")
  }

  private func fieldChoiceButton(
    _ title: LocalizedStringKey,
    choice: MarkdownThreeWayMergeFieldChoice,
    conflict: MarkdownThreeWayMergeFieldConflict
  ) -> some View {
    let selected = state.frontMatterChoices[conflict.id] == choice
    return Button {
      selectFrontMatterChoice(conflict.id, choice)
    } label: {
      Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(selected ? .accentColor : nil)
    .disabled(isDisabled)
  }

  private func bodyCard(_ conflict: MarkdownThreeWayMergeBodyConflict) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Label(bodyConflictTitle(conflict), systemImage: "text.alignleft")
          .font(.caption.weight(.semibold))
        Spacer()
        selectionStatus(state.bodyChoices[conflict.id] != nil)
      }
      sourceBlock("共同基线", text: conflict.base, color: .secondary)
      sourceBlock("我的修改", text: conflict.local, color: .blue)
      sourceBlock("远端版本", text: conflict.remote, color: .green)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { bodyChoiceButtons(conflict) }
        VStack(spacing: 8) { bodyChoiceButtons(conflict) }
      }
    }
    .semanticCard()
    .accessibilityIdentifier("repository-merge-body-hunk-\(conflict.id)")
  }

  @ViewBuilder
  private func bodyChoiceButtons(_ conflict: MarkdownThreeWayMergeBodyConflict) -> some View {
    bodyChoiceButton("使用我的段落", choice: .local, conflict: conflict)
    bodyChoiceButton("使用远端段落", choice: .remote, conflict: conflict)
    bodyChoiceButton("两个段落都保留", choice: .both, conflict: conflict)
  }

  private func bodyChoiceButton(
    _ title: LocalizedStringKey,
    choice: MarkdownThreeWayMergeBodyChoice,
    conflict: MarkdownThreeWayMergeBodyConflict
  ) -> some View {
    let selected = state.bodyChoices[conflict.id] == choice
    return Button {
      selectBodyChoice(conflict.id, choice)
    } label: {
      Label(title, systemImage: selected ? "checkmark.circle.fill" : "circle")
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(selected ? .accentColor : nil)
    .disabled(isDisabled)
  }

  @ViewBuilder
  private func semanticCompletion(_ plan: MarkdownThreeWayMergePlan) -> some View {
    if let document = state.semanticResolvedDocument {
      VStack(alignment: .leading, spacing: 8) {
        Label("所有冲突块已协调，可以应用最终版本。", systemImage: "checkmark.circle.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.green)
        DisclosureGroup("预览最终合并源码") {
          ScrollView {
            Text(verbatim: document)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .topLeading)
              .padding(8)
          }
          .frame(minHeight: 100, maxHeight: 240)
          .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
        }
        Button {
          copySemanticResultToSource()
        } label: {
          Label("转到完整源码继续编辑", systemImage: "square.and.pencil")
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled)
      }
    } else if plan.frontMatterConflicts.isEmpty, plan.bodyConflicts.isEmpty {
      Label("正在生成安全合并结果。", systemImage: "hourglass")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func sourceBlock(_ title: LocalizedStringKey, text: String?, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption2.weight(.semibold)).foregroundStyle(color)
      ScrollView(.vertical) {
        Text(verbatim: text ?? "（此版本没有该内容）")
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(7)
      }
      .frame(minHeight: 40, maxHeight: 140)
      .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
  }

  private func selectionStatus(_ resolved: Bool) -> some View {
    Label(
      resolved ? "已选择" : "待选择", systemImage: resolved ? "checkmark.circle.fill" : "circle.dashed"
    )
    .font(.caption2.weight(.semibold))
    .foregroundStyle(resolved ? Color.green : Color.orange)
  }

  private func bodyConflictTitle(_ conflict: MarkdownThreeWayMergeBodyConflict) -> String {
    if conflict.baseEndLine < conflict.baseStartLine {
      return String(
        format: String(localized: "正文插入点 · 基线第 %d 行前"),
        conflict.baseStartLine
      )
    }
    return String(
      format: String(localized: "正文冲突 · 基线第 %d–%d 行"),
      conflict.baseStartLine,
      conflict.baseEndLine
    )
  }
}

struct RepositoryMergeConflictSemanticUnavailableBanner: View {
  let reason: RepositoryMergeConflictSemanticUnavailableReason?

  var body: some View {
    Label(message, systemImage: "exclamationmark.triangle")
      .font(.caption)
      .foregroundStyle(.orange)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
      .accessibilityIdentifier("repository-merge-semantic-unavailable")
  }

  private var message: String {
    switch reason {
    case .nonMarkdown:
      return String(localized: "仅 Markdown 文件支持逐块协调，已使用完整源码。")
    case .missingTextVersion:
      return String(localized: "共同基线、本地或远端版本不可读取为文本，已使用完整源码。")
    case .unsupported(.unsupportedFrontMatterSyntax), .unsupported(.malformedFrontMatter):
      return String(localized: "Front Matter 包含复杂或未闭合结构，已使用完整源码以保留原文。")
    case .unsupported:
      return String(localized: "此文件无法安全逐块合并，已使用完整源码。")
    case nil:
      return String(localized: "此文件无法安全逐块合并，已使用完整源码。")
    }
  }
}

extension View {
  fileprivate func semanticCard() -> some View {
    padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(WorkbenchBackgroundStyle.control, in: RoundedRectangle(cornerRadius: 8))
  }
}
