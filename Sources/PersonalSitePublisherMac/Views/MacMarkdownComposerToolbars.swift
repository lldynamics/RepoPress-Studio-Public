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
  let onOpenAITemplateLibrary: () -> Void
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
        Text(lastSaveStatus)
          .font(.caption)
          .foregroundStyle(hasUnsavedChanges ? AnyShapeStyle(WorkbenchTheme.warning) : AnyShapeStyle(.tertiary))
          .lineLimit(1)
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
      .help("查找与替换（⌘F）")
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
      .help("快捷键说明（⌘/）")
      .accessibilityLabel("快捷键说明")

      if DistributionFeaturePolicy.allowsExternalAIProviders {
        Divider()
          .frame(height: 18)

        Menu {
          articleAIActionButton(.continueWriting, kind: .continueArticle)
          selectionAIActionButton(.rewrite, kind: .rewriteSelection)
          selectionAIActionButton(.condense, kind: .condenseSelection)

          Menu {
            selectionAIActionButton(.translate, kind: .translateSelectionToChinese)
            selectionAIActionButton(.translate, kind: .translateSelectionToEnglish)
          } label: {
            Label(
              AIPublishingDefaultCapability.translate.localizedDisplayName,
              systemImage: AIPublishingDefaultCapability.translate.systemImage
            )
          }

          articleAIActionButton(.generateMetadata, kind: .draftFrontMatterPack)
          articleAIActionButton(.publishingCheck, kind: .publishingReadiness)
          articleAIActionButton(.citeKnowledge, kind: .draftReferencesSection)

          Button {
            onOpenAIContextInspector()
          } label: {
            Label(
              AIPublishingDefaultCapability.askAnything.localizedDisplayName,
              systemImage: AIPublishingDefaultCapability.askAnything.systemImage
            )
          }

          Divider()

          Button {
            onOpenAITemplateLibrary()
          } label: {
            Label("搜索模板库…", systemImage: "magnifyingglass")
          }

          Button {
            onPasteAIPromptToClipboard()
          } label: {
            Label("复制上下文 Prompt", systemImage: "doc.on.doc")
          }
        } label: {
          editorActionIcon("sparkles")
        }
        .menuIndicator(.hidden)
        .help("AI 常用操作")
        .accessibilityLabel("AI 常用操作")
        .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")
      }
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
            .frame(width: 28, height: 28)
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
    .frame(width: 92, height: 32)
    .background(WorkbenchBackgroundStyle.badge, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
  }

  private func editorActionIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 14, weight: .medium))
      .frame(width: 30, height: 30)
      .contentShape(RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
  }

  private func articleAIActionButton(
    _ capability: AIPublishingDefaultCapability,
    kind: AIPublishingActionKind
  ) -> some View {
    let availability = articleAIActionAvailability(kind)
    return Button {
      onPerformArticleAIAction(kind)
    } label: {
      Label(capability.localizedDisplayName, systemImage: capability.systemImage)
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? capability.localizedDisplayName)
  }

  private func selectionAIActionButton(
    _ capability: AIPublishingDefaultCapability,
    kind: AIPublishingActionKind
  ) -> some View {
    let availability = selectionAIActionAvailability(kind)
    return Button {
      onPerformSelectionAIAction(kind)
    } label: {
      Label(
        capability == .translate ? kind.localizedDisplayName : capability.localizedDisplayName,
        systemImage: capability.systemImage
      )
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? capability.localizedDisplayName)
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
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
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
            .font(.workbenchMetadata.weight(.bold))
            .padding(.horizontal, 3)
            .background(WorkbenchTheme.warningActionFill, in: Capsule())
            .foregroundStyle(.white)
            .offset(x: 4, y: -3)
        }
      }
    }
    .foregroundStyle(diagnosticCount == 0 ? Color.secondary : WorkbenchTheme.warning)
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
        .font(.workbenchMetadata.weight(.semibold))
        .monospaced()
        .frame(width: 28, height: 28)
    }
    .foregroundStyle(.secondary)
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
    .foregroundStyle(.secondary)
    .help(title)
    .accessibilityLabel(Text(title))
  }

  private func toolbarIcon(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .frame(width: 28, height: 28)
  }

}
