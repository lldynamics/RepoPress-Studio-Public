import PublishingMarkdownCore
import SwiftUI

struct RemoteConflictSemanticMergeWorkspace: View {
  let state: RemoteConflictMergeDraft
  let isDisabled: Bool
  let selectMode: (RemoteConflictMergeMode) -> Void
  let selectFrontMatterChoice: (String, MarkdownThreeWayMergeFieldChoice) -> Void
  let selectBodyChoice: (Int, MarkdownThreeWayMergeBodyChoice) -> Void
  let updateSource: (String) -> Void
  let confirmSource: () -> Void
  let copySemanticResultToSource: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      modeSelector
      switch state.mode {
      case .semantic:
        semanticWorkspace
      case .source:
        sourceWorkspace
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityIdentifier("remote-conflict-merge-workspace")
  }

  private var modeSelector: some View {
    HStack(spacing: 8) {
      modeButton(
        title: "逐块协调",
        systemImage: "rectangle.split.2x1",
        mode: .semantic,
        enabled: state.canUseSemanticMode
      )
      modeButton(
        title: "完整源码",
        systemImage: "chevron.left.forwardslash.chevron.right",
        mode: .source,
        enabled: true
      )
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("合并方式")
  }

  private func modeButton(
    title: LocalizedStringKey,
    systemImage: String,
    mode: RemoteConflictMergeMode,
    enabled: Bool
  ) -> some View {
    let isSelected = state.mode == mode
    return Button {
      selectMode(mode)
    } label: {
      Label(title, systemImage: systemImage)
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(isSelected ? .accentColor : nil)
    .disabled(isDisabled || !enabled)
    .accessibilityValue(isSelected ? "已选择" : "未选择")
    .accessibilityIdentifier("remote-conflict-merge-mode-\(mode.rawValue)")
  }

  @ViewBuilder
  private var semanticWorkspace: some View {
    if let plan = state.semanticPlan {
      VStack(alignment: .leading, spacing: 12) {
        semanticSummary(plan)
        ForEach(plan.frontMatterConflicts) { conflict in
          frontMatterConflictCard(conflict)
        }
        ForEach(plan.bodyConflicts) { conflict in
          bodyConflictCard(conflict)
        }
        semanticCompletion(plan)
      }
    } else {
      unavailableBanner
    }
  }

  private func semanticSummary(_ plan: MarkdownThreeWayMergePlan) -> some View {
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
            format: String(localized: "还需逐块协调 %d 处；完成前不会生成可发布文档。"),
            state.unresolvedSemanticCount
          )
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.orange)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      Color.accentColor.opacity(0.08),
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
    )
  }

  private func frontMatterConflictCard(
    _ conflict: MarkdownThreeWayMergeFieldConflict
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Front Matter 字段", systemImage: "list.bullet.rectangle")
          .font(.caption.weight(.semibold))
        Text(verbatim: conflict.key)
          .font(.caption.monospaced().weight(.semibold))
        Spacer()
        selectionStatus(state.frontMatterChoices[conflict.id] != nil)
      }
      sourceBlock(title: "共同基线", text: conflict.base, tint: .secondary)
      sourceBlock(title: "我的修改", text: conflict.local, tint: .blue)
      sourceBlock(title: "远端版本", text: conflict.remote, tint: .green)
      HStack(spacing: 8) {
        fieldChoiceButton(
          title: "使用我的字段",
          choice: .local,
          conflict: conflict
        )
        fieldChoiceButton(
          title: "使用远端字段",
          choice: .remote,
          conflict: conflict
        )
      }
    }
    .semanticConflictCard()
    .accessibilityIdentifier("remote-conflict-front-matter-\(conflict.id)")
  }

  private func fieldChoiceButton(
    title: LocalizedStringKey,
    choice: MarkdownThreeWayMergeFieldChoice,
    conflict: MarkdownThreeWayMergeFieldConflict
  ) -> some View {
    let isSelected = state.frontMatterChoices[conflict.id] == choice
    return Button {
      selectFrontMatterChoice(conflict.id, choice)
    } label: {
      HStack {
        Text(title)
        Spacer(minLength: 4)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(isSelected ? .accentColor : nil)
    .disabled(isDisabled)
    .accessibilityValue(isSelected ? "已选择" : "未选择")
  }

  private func bodyConflictCard(_ conflict: MarkdownThreeWayMergeBodyConflict) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(bodyConflictTitle(conflict), systemImage: "text.alignleft")
          .font(.caption.weight(.semibold))
        Spacer()
        selectionStatus(state.bodyChoices[conflict.id] != nil)
      }
      sourceBlock(title: "共同基线", text: conflict.base, tint: .secondary)
      sourceBlock(title: "我的修改", text: conflict.local, tint: .blue)
      sourceBlock(title: "远端版本", text: conflict.remote, tint: .green)
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { bodyChoiceButtons(conflict) }
        VStack(spacing: 8) { bodyChoiceButtons(conflict) }
      }
    }
    .semanticConflictCard()
    .accessibilityIdentifier("remote-conflict-body-hunk-\(conflict.id)")
  }

  @ViewBuilder
  private func bodyChoiceButtons(_ conflict: MarkdownThreeWayMergeBodyConflict) -> some View {
    bodyChoiceButton(title: "使用我的段落", choice: .local, conflict: conflict)
    bodyChoiceButton(title: "使用远端段落", choice: .remote, conflict: conflict)
    bodyChoiceButton(title: "两个段落都保留", choice: .both, conflict: conflict)
  }

  private func bodyChoiceButton(
    title: LocalizedStringKey,
    choice: MarkdownThreeWayMergeBodyChoice,
    conflict: MarkdownThreeWayMergeBodyConflict
  ) -> some View {
    let isSelected = state.bodyChoices[conflict.id] == choice
    return Button {
      selectBodyChoice(conflict.id, choice)
    } label: {
      HStack {
        Text(title)
        Spacer(minLength: 4)
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered)
    .tint(isSelected ? .accentColor : nil)
    .disabled(isDisabled)
    .accessibilityValue(isSelected ? "已选择" : "未选择")
  }

  @ViewBuilder
  private func semanticCompletion(_ plan: MarkdownThreeWayMergePlan) -> some View {
    if let document = state.semanticResolvedDocument {
      VStack(alignment: .leading, spacing: 8) {
        Label("所有冲突块已协调，可以加入本次事务。", systemImage: "checkmark.circle.fill")
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
          .background(
            WorkbenchBackgroundStyle.control,
            in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          )
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

  private var sourceWorkspace: some View {
    VStack(alignment: .leading, spacing: 8) {
      if state.semanticPlan == nil {
        unavailableBanner
      } else {
        Text("完整源码模式会保留你的手工稿；可随时返回逐块协调，已做出的选择不会丢失。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      TextEditor(text: sourceBinding)
        .font(.system(.body, design: .monospaced))
        .scrollContentBackground(.hidden)
        .padding(6)
        .background(
          WorkbenchBackgroundStyle.control,
          in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        )
        .disabled(isDisabled)
        .frame(minHeight: 320)
        .accessibilityLabel("最终合并版")
        .accessibilityIdentifier("remote-conflict-final-editor")
      HStack {
        if state.sourceReviewed {
          Label("完整源码已确认", systemImage: "checkmark.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.green)
        } else {
          Text("请检查并确认完整源码；确认前不会加入发布事务。")
            .font(.caption)
            .foregroundStyle(.orange)
        }
        Spacer()
        Button("确认源码已协调") { confirmSource() }
          .buttonStyle(.bordered)
          .disabled(isDisabled || state.sourceReviewed)
          .accessibilityIdentifier("remote-conflict-confirm-source")
      }
    }
  }

  private var unavailableBanner: some View {
    Label(semanticUnavailableMessage, systemImage: "exclamationmark.triangle")
      .font(.caption)
      .foregroundStyle(.orange)
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Color.orange.opacity(0.08),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .accessibilityIdentifier("remote-conflict-semantic-unavailable")
  }

  private var sourceBinding: Binding<String> {
    Binding(
      get: { state.sourceDraft },
      set: { updateSource($0) }
    )
  }

  private var semanticUnavailableMessage: String {
    guard let reason = state.semanticUnavailableReason else {
      return String(localized: "此文件无法安全逐块合并，请在完整源码中手工协调。")
    }
    switch reason {
    case .missingTextVersion:
      return String(localized: "共同基线、本地或远端版本不可读取，已切换到完整源码。")
    case .unsupported(.documentTooLarge):
      return String(localized: "文件超过安全大小限制，已切换到完整源码。")
    case .unsupported(.inconsistentLineEndings):
      return String(localized: "三个版本的换行格式不一致，已切换到完整源码。")
    case .unsupported(.tooManyLines), .unsupported(.diffTooComplex):
      return String(localized: "正文差异过于复杂，已切换到完整源码。")
    case .unsupported(.frontMatterPresenceOrDelimiterDiffers):
      return String(localized: "三个版本的 Front Matter 格式不一致，已切换到完整源码。")
    case .unsupported(.malformedFrontMatter):
      return String(localized: "Front Matter 未正确闭合，已切换到完整源码。")
    case .unsupported(.unsupportedFrontMatterSyntax):
      return String(localized: "Front Matter 包含注释或复杂结构，已切换到完整源码以保留原文。")
    case .unsupported(.unsupportedFrontMatterKey(let key)):
      return String(
        format: String(localized: "Front Matter 字段“%@”不能无损往返，已切换到完整源码。"),
        key
      )
    case .unsupported(.duplicateFrontMatterKey(let key)):
      return String(
        format: String(localized: "Front Matter 字段“%@”重复，已切换到完整源码。"),
        key
      )
    case .unsupported(.tooManyFrontMatterFields):
      return String(localized: "Front Matter 字段过多，已切换到完整源码。")
    }
  }

  private func sourceBlock(title: LocalizedStringKey, text: String?, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tint)
      ScrollView(.vertical) {
        Text(verbatim: text ?? String(localized: "（此版本没有该内容）"))
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(7)
      }
      .frame(minHeight: 40, maxHeight: 160)
      .background(
        tint.opacity(0.07),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
    }
  }

  private func selectionStatus(_ isResolved: Bool) -> some View {
    Label(
      isResolved ? "已选择" : "待选择",
      systemImage: isResolved ? "checkmark.circle.fill" : "circle.dashed"
    )
    .font(.caption2.weight(.semibold))
    .foregroundStyle(isResolved ? Color.green : Color.orange)
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

extension View {
  fileprivate func semanticConflictCard() -> some View {
    padding(10)
      .background(
        WorkbenchBackgroundStyle.card,
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .strokeBorder(.separator.opacity(0.45))
      }
  }
}
