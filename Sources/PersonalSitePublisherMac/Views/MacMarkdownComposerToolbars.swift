import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownEditorToolbar: View {
  @Binding var title: String
  let markdownPath: String
  let lastSaveStatus: String
  let hasUnsavedChanges: Bool
  let editorDisplayMode: EditorDisplayMode
  let isSelectionAIActionRunning: Bool
  @Binding var isOutlinePresented: Bool
  let outlineItems: [MarkdownOutlineItem]
  let onSetEditorDisplayMode: (EditorDisplayMode) -> Void
  let onShowFindReplace: () -> Void
  let onShowOutline: () -> Void
  let onSelectOutlineItem: (MarkdownOutlineItem) -> Void
  let onPerformOutlineAction: (MarkdownOutlineSectionAction, MarkdownOutlineItem) -> Void
  let onShowShortcutHelp: () -> Void
  let onOpenAIContextInspector: () -> Void
  let recommendedAIActionMenuItems: [AIPublishingActionMenuItem]
  let moreAIActionMenuItems: [AIPublishingActionMenuItem]
  let isSelectionAIAction: (AIPublishingActionKind) -> Bool
  let selectionAIActionAvailability: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let articleAIActionAvailability: (AIPublishingActionKind) -> AIPublishingActionAvailabilityPresentation
  let onPerformSelectionAIAction: (AIPublishingActionKind) -> Void
  let onPerformArticleAIAction: (AIPublishingActionKind) -> Void
  let onPasteAIPromptToClipboard: () -> Void

  var body: some View {
    HStack(spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        TextField("文章标题", text: $title)
          .textFieldStyle(.plain)
          .font(.headline)
          .lineLimit(1)
          .help(title.nilIfEmpty ?? String(localized: "未命名文章"))
          .accessibilityLabel("文章标题")
          .accessibilityValue(title.nilIfEmpty ?? "未命名文章")

        Text(markdownPath)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .workbenchTruncatedIdentity(markdownPath)
      }
      .frame(minWidth: 220, idealWidth: 320, maxWidth: 460, alignment: .leading)

      Spacer()

      HStack(spacing: 5) {
        if hasUnsavedChanges {
          Image(systemName: "circle.fill")
            .font(.system(size: 6))
            .foregroundStyle(WorkbenchTheme.warning)
            .accessibilityHidden(true)
        }
        if hasUnsavedChanges {
          Text(lastSaveStatus)
            .font(.caption)
            .foregroundStyle(WorkbenchTheme.warning)
            .lineLimit(1)
        } else {
          Text(lastSaveStatus)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
      .accessibilityLabel("保存状态")
      .accessibilityValue(lastSaveStatus)

      editorDisplayModeControl

      expandedEditorActions
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private var expandedEditorActions: some View {
    HStack(spacing: 2) {
      Button {
        onShowFindReplace()
      } label: {
        editorActionIcon("magnifyingglass")
      }
      .help("查找与替换")
      .accessibilityLabel("查找与替换")

      Button {
        onShowOutline()
      } label: {
        editorActionIcon("list.bullet.indent")
      }
      .keyboardShortcut("o", modifiers: [.command, .option])
      .help("文章大纲（⌥⌘O）")
      .accessibilityLabel("文章大纲")
      .accessibilityIdentifier("markdown-outline-button")
      .popover(isPresented: $isOutlinePresented, arrowEdge: .top) {
        MarkdownOutlinePopover(
          items: outlineItems,
          onSelect: onSelectOutlineItem,
          onAction: onPerformOutlineAction
        )
      }

      Button {
        onShowShortcutHelp()
      } label: {
        editorActionIcon("keyboard")
      }
      .help("快捷键说明")
      .accessibilityLabel("快捷键说明")

      Divider()
        .frame(height: 18)

      Menu {
        ForEach(recommendedAIActionMenuItems) { item in
          aiActionButton(item)
        }

        Divider()

        Menu("更多指令") {
          ForEach(AIPublishingQuickPromptGroup.allCases) { group in
            let groupItems = moreAIActionMenuItems.filter {
              $0.kind.promptLibraryGroup == group
            }
            if !groupItems.isEmpty {
              Menu {
                ForEach(groupItems) { item in
                  aiActionButton(item)
                }
              } label: {
                Label(aiActionGroupTitle(group), systemImage: group.systemImage)
              }
            }
          }

          Divider()

          Button {
            onOpenAIContextInspector()
          } label: {
            Label("打开 AI 对话", systemImage: "bubble.left.and.text.bubble.right")
          }

          Button {
            onPasteAIPromptToClipboard()
          } label: {
            Label("复制上下文 Prompt", systemImage: "doc.on.doc")
          }
        }
      } label: {
        editorActionIcon("sparkles")
      }
      .help("AI 推荐指令")
      .accessibilityLabel("AI 推荐指令")
      .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")
    }
    .buttonStyle(.borderless)
    .accessibilityElement(children: .contain)
  }

  private var editorDisplayModeControl: some View {
    HStack(spacing: 2) {
      ForEach(EditorDisplayMode.allCases) { mode in
        Button {
          onSetEditorDisplayMode(mode)
        } label: {
          Image(systemName: mode.systemImage)
            .font(.system(size: 13, weight: .medium))
            .frame(width: 26, height: 22)
            .contentShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
        }
        .buttonStyle(.plain)
        .foregroundStyle(editorDisplayMode == mode ? WorkbenchTheme.navigationSelection : Color.secondary)
        .background(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .fill(
              editorDisplayMode == mode
                ? WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground)
                : Color.clear
            )
        )
        .accessibilityLabel("编辑器模式：\(mode.localizedDisplayName)")
        .accessibilityValue(editorDisplayMode == mode ? "已选择" : "未选择")
        .accessibilityAddTraits(editorDisplayMode == mode ? .isSelected : [])
        .help("切换到\(mode.localizedDisplayName)模式")
      }
    }
    .padding(2)
    .frame(width: 92, height: 28)
    .background(WorkbenchBackgroundStyle.badge, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
  }

  private func editorActionIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 13, weight: .medium))
      .frame(width: 24, height: 22)
      .contentShape(Rectangle())
  }

  private func aiActionGroupTitle(_ group: AIPublishingQuickPromptGroup) -> LocalizedStringKey {
    switch group {
    case .writing:
      return "写作生成"
    case .editing:
      return "选区编辑"
    case .publishing:
      return "发布检查"
    case .distribution:
      return "分发素材"
    case .maintenance:
      return "内容维护"
    }
  }

  private func articleAIActionButton(_ item: AIPublishingActionMenuItem) -> some View {
    let availability = articleAIActionAvailability(item.kind)
    return Button {
      onPerformArticleAIAction(item.kind)
    } label: {
      Label(item.kind.localizedDisplayName, systemImage: item.systemImage)
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? item.kind.localizedDisplayName)
  }

  private func selectionAIActionButton(_ item: AIPublishingActionMenuItem) -> some View {
    let availability = selectionAIActionAvailability(item.kind)
    return Button {
      onPerformSelectionAIAction(item.kind)
    } label: {
      Label(item.kind.localizedDisplayName, systemImage: item.systemImage)
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? item.kind.localizedDisplayName)
  }

  @ViewBuilder
  private func aiActionButton(_ item: AIPublishingActionMenuItem) -> some View {
    if isSelectionAIAction(item.kind) {
      selectionAIActionButton(item)
    } else {
      articleAIActionButton(item)
    }
  }
}

struct MacMarkdownFormattingToolbar: View {
  let characterCount: Int
  let hanCharacterCount: Int
  let wordCount: Int
  let writingUnitCount: Int
  let lineCount: Int
  let readingMinutes: Int
  let writingGoal: Int
  let onApplyMarkdownFormatting: (MarkdownFormattingCommand) -> Void
  let onWrapSelection: (String, String, String) -> Void
  let onPrefixCurrentLine: (String) -> Void
  let onInsertCodeBlock: () -> Void
  let onInsertTable: () -> Void
  let onInsertHorizontalRule: () -> Void
  let onInsertInternalLink: () -> Void
  let onShowSnippets: () -> Void
  let onShowDiagnostics: () -> Void
  let diagnosticCount: Int
  let onInsertImage: () -> Void
  let onInsertVideo: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      expandedRow
      compactRows
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private var expandedRow: some View {
    HStack(spacing: 5) {
      headingButtons
      toolbarDivider
      inlineStyleButtons
      toolbarDivider
      blockButtons
      toolbarDivider
      insertionButtons
      Spacer(minLength: 8)
      trailingControls
    }
  }

  private var compactRows: some View {
    VStack(spacing: 5) {
      HStack(spacing: 5) {
        headingButtons
        toolbarDivider
        inlineStyleButtons
        toolbarDivider
        quoteAndCodeBlockButtons
        Spacer(minLength: 0)
      }

      Divider()

      HStack(spacing: 5) {
        listButtons
        toolbarDivider
        insertionButtons
        Spacer(minLength: 8)
        trailingControls
      }
    }
  }

  @ViewBuilder
  private var headingButtons: some View {
    headingButton(level: 1, title: "一级标题")
    headingButton(level: 2, title: "二级标题")
    headingButton(level: 3, title: "三级标题")
  }

  @ViewBuilder
  private var inlineStyleButtons: some View {
    toolbarButton(title: "粗体", systemName: "bold") {
      onApplyMarkdownFormatting(.bold)
    }
    toolbarButton(title: "斜体", systemName: "italic") {
      onApplyMarkdownFormatting(.italic)
    }
    toolbarButton(
      title: "行内代码",
      systemName: "chevron.left.forwardslash.chevron.right"
    ) {
      onWrapSelection("`", "`", "code")
    }
  }

  @ViewBuilder
  private var blockButtons: some View {
    quoteAndCodeBlockButtons
    listButtons
  }

  @ViewBuilder
  private var quoteAndCodeBlockButtons: some View {
    toolbarButton(title: "引用", systemName: "text.quote") {
      onPrefixCurrentLine("> ")
    }
    toolbarButton(title: "代码块", systemName: "curlybraces.square") {
      onInsertCodeBlock()
    }
  }

  @ViewBuilder
  private var listButtons: some View {
    toolbarButton(title: "无序列表", systemName: "list.bullet") {
      onPrefixCurrentLine("- ")
    }
    toolbarButton(title: "有序列表", systemName: "list.number") {
      onPrefixCurrentLine("1. ")
    }
    toolbarButton(title: "任务列表", systemName: "checklist") {
      onPrefixCurrentLine("- [ ] ")
    }
  }

  @ViewBuilder
  private var insertionButtons: some View {
    toolbarButton(title: "链接", systemName: "link") {
      onInsertInternalLink()
    }
    toolbarButton(title: "插图", systemName: "photo") {
      onInsertImage()
    }

    Menu {
      Button {
        onInsertTable()
      } label: {
        Label("表格", systemImage: "tablecells")
      }
      Button {
        onInsertHorizontalRule()
      } label: {
        Label("分隔线", systemImage: "minus")
      }
      Button {
        onShowSnippets()
      } label: {
        Label("模板与片段", systemImage: "doc.on.clipboard")
      }
      Button {
        onInsertVideo()
      } label: {
        Label("插入视频", systemImage: "video")
      }
    } label: {
      toolbarIcon("ellipsis.circle")
    }
    .help("更多插入选项")
    .accessibilityLabel("更多插入选项")
  }

  @ViewBuilder
  private var trailingControls: some View {
    Button {
      onShowDiagnostics()
    } label: {
      ZStack(alignment: .topTrailing) {
        toolbarIcon(diagnosticCount == 0 ? "checkmark.circle" : "waveform.badge.exclamationmark")
        if diagnosticCount > 0 {
          Text("\(min(diagnosticCount, 99))")
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 3)
            .background(WorkbenchTheme.warningActionFill, in: Capsule())
            .foregroundStyle(.white)
            .offset(x: 4, y: -3)
        }
      }
    }
    .help(diagnosticCount == 0 ? "正文诊断：未发现问题" : "正文诊断：\(diagnosticCount) 项")
    .accessibilityLabel("正文诊断")
    .accessibilityValue(diagnosticCount == 0 ? "没有问题" : "\(diagnosticCount) 项")
    MarkdownEditorComfortControl()
    toolbarDivider
    statisticsLabel
  }

  private var toolbarDivider: some View {
    Divider()
      .frame(height: 18)
  }

  private var statisticsLabel: some View {
    Text(statisticsSummary)
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .fixedSize(horizontal: true, vertical: false)
      .help("\(hanCharacterCount) 汉字 · \(wordCount) 西文词 · \(characterCount) 字符 · \(lineCount) 行 · 约 \(readingMinutes) 分钟 · 目标 \(writingGoal) 字/词")
      .accessibilityLabel("文章统计")
      .accessibilityValue("\(hanCharacterCount) 个汉字，\(wordCount) 个西文词，合计 \(writingUnitCount) 字词，\(lineCount) 行，预计阅读 \(readingMinutes) 分钟，写作目标 \(writingGoal) 字词，已完成 \(writingGoalProgressPercent)%")
  }

  private var statisticsSummary: String {
    "\(writingUnitCount) 字/词 · 目标 \(writingGoalProgressPercent)%"
  }

  private var writingGoalProgressPercent: Int {
    guard writingGoal > 0 else { return 0 }
    return min(100, Int((Double(writingUnitCount) / Double(writingGoal) * 100).rounded()))
  }

  private func headingButton(level: Int, title: LocalizedStringKey) -> some View {
    Button {
      onApplyMarkdownFormatting(.heading(level: level))
    } label: {
      Text("H\(level)")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .frame(width: 22, height: 22)
    }
    .help(title)
    .accessibilityLabel(Text(title))
  }

  private func toolbarButton(
    title: LocalizedStringKey,
    systemName: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      toolbarIcon(systemName)
    }
    .help(title)
    .accessibilityLabel(Text(title))
  }

  private func toolbarIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .frame(width: 22, height: 22)
  }

}
