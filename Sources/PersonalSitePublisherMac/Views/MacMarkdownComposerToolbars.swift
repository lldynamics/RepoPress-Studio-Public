import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownEditorToolbar: View {
  @Binding var title: String
  let markdownPath: String
  let lastSaveStatus: String
  let hasUnsavedChanges: Bool
  let editorDisplayMode: EditorDisplayMode
  let isSelectionAIActionRunning: Bool
  let writingToolDensity: MarkdownWritingToolDensity
  let availableWritingContextPanels: [MarkdownWritingContextPanel]
  let actions: MarkdownEditorToolbarActions
  @State private var selectedPublishAssets = AIPublishingAssetKind.defaultSelection

  var body: some View {
    HStack(spacing: 8) {
      titleArea

      Spacer(minLength: 8)

      ViewThatFits(in: .horizontal) {
        expandedToolbarControls
        compactToolbarControls(showsPrepareTitle: true)
        compactToolbarControls(showsPrepareTitle: false)
      }
    }
    .padding(.horizontal, WorkbenchSpacing.section)
    .padding(.vertical, 9)
  }

  private var titleArea: some View {
    VStack(alignment: .leading, spacing: 2) {
      TextField("文章标题", text: $title)
        .textFieldStyle(.plain)
        .font(.headline)
        .lineLimit(1)
        .help(title.nilIfEmpty ?? String(localized: "未命名文章"))
        .accessibilityLabel("文章标题")
        .accessibilityValue(title.nilIfEmpty ?? String(localized: "未命名文章"))

      Text(markdownPath)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .workbenchTruncatedIdentity(markdownPath)
    }
    .frame(minWidth: 220, idealWidth: 320, maxWidth: 460, alignment: .leading)
  }

  private var expandedToolbarControls: some View {
    HStack(spacing: 5) {
      expandedSaveStatus
      editorDisplayModeControl
      writingToolDensityControl
      preparePublishButton(showsTitle: true)
      expandedEditorActions
    }
  }

  private func compactToolbarControls(showsPrepareTitle: Bool) -> some View {
    HStack(spacing: 4) {
      compactSaveStatus
      compactEditorDisplayModeControl
      preparePublishButton(showsTitle: showsPrepareTitle)
      compactEditorActionsMenu
    }
  }

  private var expandedSaveStatus: some View {
    HStack(spacing: 5) {
      if hasUnsavedChanges {
        Image(systemName: "circle.fill")
          .font(.system(size: 6))
          .foregroundStyle(WorkbenchTheme.warning)
          .accessibilityHidden(true)
      }
      Text(lastSaveStatus)
        .font(.caption)
        .foregroundStyle(
          hasUnsavedChanges
            ? AnyShapeStyle(WorkbenchTheme.warning)
            : AnyShapeStyle(.tertiary)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
    .accessibilityLabel("保存状态")
    .accessibilityValue(lastSaveStatus)
  }

  private var compactSaveStatus: some View {
    Image(systemName: hasUnsavedChanges ? "circle.fill" : "checkmark.circle")
      .font(hasUnsavedChanges ? .system(size: 7) : .caption)
      .foregroundStyle(
        hasUnsavedChanges
          ? AnyShapeStyle(WorkbenchTheme.warning)
          : AnyShapeStyle(.tertiary)
      )
      .frame(minWidth: 18, minHeight: 30)
      .help(lastSaveStatus)
      .accessibilityLabel("保存状态")
      .accessibilityValue(lastSaveStatus)
  }

  @ViewBuilder
  private func preparePublishButton(showsTitle: Bool) -> some View {
    Button {
      actions.onPreparePublish()
    } label: {
      if showsTitle {
        Label("准备发布", systemImage: "paperplane")
      } else {
        Image(systemName: "paperplane")
          .accessibilityHidden(true)
      }
    }
    .workbenchProminentActionStyle()
    .help(String(localized: "检查当前文章并打开发布准备"))
    .accessibilityLabel("准备发布")
    .accessibilityIdentifier("markdown-prepare-publish")
  }

  private var compactEditorDisplayModeControl: some View {
    Menu {
      ForEach(EditorDisplayMode.allCases) { mode in
        Button {
          actions.onSetEditorDisplayMode(mode)
        } label: {
          if editorDisplayMode == mode {
            Label(mode.localizedDisplayName, systemImage: "checkmark")
          } else {
            Label(mode.localizedDisplayName, systemImage: mode.systemImage)
          }
        }
        .accessibilityValue(
          editorDisplayMode == mode ? String(localized: "已选择") : String(localized: "未选择")
        )
        .accessibilityAddTraits(editorDisplayMode == mode ? .isSelected : [])
      }
    } label: {
      Image(systemName: editorDisplayMode.systemImage)
        .accessibilityHidden(true)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: false))
    .help(String(localized: "编辑器模式：\(editorDisplayMode.localizedDisplayName)"))
    .accessibilityLabel(
      String(localized: "编辑器模式：\(editorDisplayMode.localizedDisplayName)")
    )
    .accessibilityValue(editorDisplayMode.localizedDisplayName)
    .accessibilityIdentifier("markdown-editor-display-mode-menu")
  }

  private var compactEditorActionsMenu: some View {
    Menu {
      Button {
        actions.onShowFindReplace()
      } label: {
        Label("查找与替换", systemImage: "magnifyingglass")
      }

      Button {
        actions.onShowOutline()
      } label: {
        Label("文章大纲", systemImage: "list.bullet.indent")
      }
      .keyboardShortcut("o", modifiers: [.command, .option])
      .accessibilityIdentifier("markdown-outline-button")

      Menu {
        contextPanelActions
      } label: {
        Label("上下文面板", systemImage: "sidebar.right")
      }
      .accessibilityLabel("写作上下文面板")
      .accessibilityValue(availableWritingContextPanels.map(\.title).joined(separator: "、"))
      .accessibilityIdentifier("markdown-writing-context-panel-menu")

      Button {
        actions.onShowShortcutHelp()
      } label: {
        Label("快捷键说明", systemImage: "keyboard")
      }

      Menu {
        exportActions
      } label: {
        Label("导出文章", systemImage: "square.and.arrow.up")
      }
      .accessibilityLabel("导出文章")
      .accessibilityIdentifier("markdown-document-export-menu")

      Divider()

      Menu {
        writingToolDensityActions
      } label: {
        Label("写作工具密度", systemImage: "slider.horizontal.3")
      }
      .accessibilityLabel("写作工具密度")
      .accessibilityValue(writingToolDensity.title)
      .accessibilityIdentifier("markdown-writing-tool-density")

      Menu {
        aiActions
      } label: {
        Label("AI 常用操作", systemImage: "sparkles")
      }
      .accessibilityLabel("AI 常用操作")
      .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")
    } label: {
      Image(systemName: "ellipsis.circle")
        .accessibilityHidden(true)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: false))
    .help(String(localized: "更多编辑器操作"))
    .accessibilityLabel("更多编辑器操作")
    .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")
    .accessibilityIdentifier("markdown-editor-more-actions-menu")
  }

  private var expandedEditorActions: some View {
    editorActionGroup(showsTitle: false)
    .accessibilityElement(children: .contain)
  }

  private func editorActionGroup(showsTitle: Bool) -> some View {
    HStack(spacing: 4) {
      Button {
        actions.onShowFindReplace()
      } label: {
        editorActionLabel(String(localized: "查找与替换"), systemName: "magnifyingglass", showsTitle: showsTitle)
      }
      .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
      .help(String(localized: "查找与替换（⌘F）"))
      .accessibilityLabel("查找与替换")

      Button {
        actions.onShowOutline()
      } label: {
        editorActionLabel(String(localized: "文章大纲"), systemName: "list.bullet.indent", showsTitle: showsTitle)
      }
      .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
      .keyboardShortcut("o", modifiers: [.command, .option])
      .help(String(localized: "文章大纲（⌥⌘O）"))
      .accessibilityLabel("文章大纲")
      .accessibilityIdentifier("markdown-outline-button")

      contextPanelMenu(showsTitle: showsTitle)

      Button {
        actions.onShowShortcutHelp()
      } label: {
        editorActionLabel(String(localized: "快捷键说明"), systemName: "keyboard", showsTitle: showsTitle)
      }
      .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
      .help(String(localized: "快捷键说明（⌥⌘/）"))
      .accessibilityLabel("快捷键说明")

      Menu {
        exportActions
      } label: {
        editorActionLabel(String(localized: "导出文章"), systemName: "square.and.arrow.up", showsTitle: showsTitle)
      }
      .menuIndicator(.hidden)
      .help(String(localized: "导出、打印或分享当前文章"))
      .accessibilityLabel("导出文章")
      .accessibilityIdentifier("markdown-document-export-menu")

      Divider()
        .frame(height: 18)

      Menu {
        aiActions
      } label: {
        editorActionLabel("AI 常用操作", systemName: "sparkles", showsTitle: showsTitle)
      }
      .menuIndicator(.hidden)
      .help("AI 常用操作")
      .accessibilityLabel("AI 常用操作")
      .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")
    }
  }

  private var writingToolDensityControl: some View {
    Menu {
      writingToolDensityActions
    } label: {
      Label(writingToolDensity.title, systemImage: "slider.horizontal.3")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .help(String(localized: "切换基础写作或专业 Markdown 工具密度"))
    .accessibilityLabel("写作工具密度")
    .accessibilityValue(writingToolDensity.title)
    .accessibilityIdentifier("markdown-writing-tool-density")
  }

  private func contextPanelMenu(showsTitle: Bool) -> some View {
    Menu {
      contextPanelActions
    } label: {
      editorActionLabel("上下文面板", systemName: "sidebar.right", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .help(String(localized: "在选区工具、AI 审阅、图片信息和文章大纲之间切换"))
    .accessibilityLabel("写作上下文面板")
    .accessibilityValue(availableWritingContextPanels.map(\.title).joined(separator: "、"))
    .accessibilityIdentifier("markdown-writing-context-panel-menu")
  }

  @ViewBuilder
  private var writingToolDensityActions: some View {
    ForEach(MarkdownWritingToolDensity.allCases) { density in
      Button {
        actions.onSetWritingToolDensity(density)
      } label: {
        if density == writingToolDensity {
          Label(density.title, systemImage: "checkmark")
        } else {
          Label(density.title, systemImage: density.systemImage)
        }
      }
    }
  }

  @ViewBuilder
  private var contextPanelActions: some View {
    ForEach(MarkdownWritingContextPanel.allCases) { panel in
      Button {
        actions.onOpenWritingContextPanel(panel)
      } label: {
        Label(panel.title, systemImage: panel.systemImage)
      }
      .disabled(!availableWritingContextPanels.contains(panel))
    }
  }

  @ViewBuilder
  private var exportActions: some View {
    exportButton("Markdown…", systemImage: "doc.plaintext", format: .markdown)
    exportButton("HTML…", systemImage: "chevron.left.forwardslash.chevron.right", format: .html)
    exportButton("PDF…", systemImage: "doc.richtext", format: .pdf)
    Divider()
    exportButton("打印…", systemImage: "printer", format: .print)
    exportButton("分享…", systemImage: "square.and.arrow.up", format: .share)
  }

  @ViewBuilder
  private var aiActions: some View {
    articleAIActionButton(.continueWriting, kind: .continueArticle)
    convergedRewriteAction
    convergedPublishAssetPackAction

    Menu {
      selectionAIActionButton(.translate, kind: .translateSelectionToChinese)
      selectionAIActionButton(.translate, kind: .translateSelectionToEnglish)
    } label: {
      Label(
        AIPublishingDefaultCapability.translate.localizedDisplayName,
        systemImage: AIPublishingDefaultCapability.translate.systemImage
      )
    }

    convergedReviewAction
    articleAIActionButton(.citeKnowledge, kind: .draftReferencesSection)

    Button {
      actions.onOpenAIContextInspector()
    } label: {
      Label(
        AIPublishingDefaultCapability.askAnything.localizedDisplayName,
        systemImage: AIPublishingDefaultCapability.askAnything.systemImage
      )
    }

    Divider()

    Button {
      actions.onOpenAITemplateLibrary()
    } label: {
      Label("搜索模板库…", systemImage: "magnifyingglass")
    }

    Button {
      actions.onPasteAIPromptToClipboard()
    } label: {
      Label("复制上下文 Prompt", systemImage: "doc.on.doc")
    }
  }

  private var convergedRewriteAction: some View {
    Menu {
      Section("风格") {
        ForEach(AIPublishingRewriteStyle.allCases) { style in
          Button {
            actions.onPerformConvergedSelectionAIAction(
              .rewriteSelection(AIPublishingRewriteConfiguration(style: style))
            )
          } label: {
            Label(style.displayName, systemImage: style == .balanced ? "wand.and.stars" : "textformat")
          }
          .disabled(!actions.selectionAIActionAvailability(.rewriteSelection).isEnabled)
        }
      }

      Divider()

      Section("处理") {
        ForEach(AIPublishingRewriteOperation.allCases.filter { $0 != .rewrite }) { operation in
          Button {
            actions.onPerformConvergedSelectionAIAction(
              .rewriteSelection(AIPublishingRewriteConfiguration(operation: operation))
            )
          } label: {
            Label(operation.displayName, systemImage: "wand.and.stars")
          }
          .disabled(!actions.selectionAIActionAvailability(.rewriteSelection).isEnabled)
        }
      }
    } label: {
      Label("改写", systemImage: "wand.and.stars")
    }
    .help("对选中文本执行改写、润色、扩写、压缩或简化")
    .accessibilityIdentifier("ai-converged-rewrite-menu")
  }

  private var convergedPublishAssetPackAction: some View {
    Menu {
      Section("选择发布资产") {
        ForEach(AIPublishingAssetKind.allCases) { asset in
          Toggle(isOn: publishAssetBinding(for: asset)) {
            Label(asset.displayName, systemImage: "checkmark.square")
          }
        }
      }

      Divider()

      Button {
        actions.onPerformConvergedArticleAIAction(
          .publishAssetPack(AIPublishingAssetPackConfiguration(assets: selectedPublishAssets))
        )
      } label: {
        Label("生成已选择的 \(selectedPublishAssets.count) 项", systemImage: "play.fill")
      }
      .disabled(
        selectedPublishAssets.isEmpty
          || !actions.articleAIActionAvailability(.draftPublishAssetPack).isEnabled
      )
    } label: {
      Label("发布资产包", systemImage: "shippingbox")
    }
    .help("勾选多个发布资产，一次生成完整发布包")
    .accessibilityIdentifier("ai-converged-publish-asset-pack-menu")
  }

  private var convergedReviewAction: some View {
    Button {
      actions.onPerformConvergedArticleAIAction(
        .contentReview(AIPublishingReviewConfiguration())
      )
    } label: {
      Label("内容审查", systemImage: "checkmark.shield")
    }
    .disabled(!actions.articleAIActionAvailability(.publishingReadiness).isEnabled)
    .help("一次检查内容缺口、事实边界、隐私、链接、SEO、可读性和技术准确性")
    .accessibilityIdentifier("ai-converged-content-review")
  }

  private func publishAssetBinding(for asset: AIPublishingAssetKind) -> Binding<Bool> {
    Binding(
      get: { selectedPublishAssets.contains(asset) },
      set: { isSelected in
        if isSelected {
          selectedPublishAssets.insert(asset)
        } else {
          selectedPublishAssets.remove(asset)
        }
      }
    )
  }

  private var editorDisplayModeControl: some View {
    editorDisplayModeControl(showsTitle: false)
  }

  private func editorDisplayModeControl(showsTitle: Bool) -> some View {
    HStack(spacing: 2) {
      ForEach(EditorDisplayMode.allCases) { mode in
        Button {
          actions.onSetEditorDisplayMode(mode)
        } label: {
          editorActionLabel(
            mode.localizedDisplayName,
            systemName: mode.systemImage,
            showsTitle: showsTitle
          )
        }
        .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
        .foregroundStyle(editorDisplayMode == mode ? WorkbenchTheme.navigationSelection : Color.secondary)
        .background(
          RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
            .fill(
              editorDisplayMode == mode
                ? WorkbenchTheme.navigationSelection.opacity(WorkbenchOpacity.selectionBackground)
                : Color.clear
            )
        )
        .accessibilityLabel(String(localized: "编辑器模式：\(mode.localizedDisplayName)"))
        .accessibilityValue(
          editorDisplayMode == mode ? String(localized: "已选择") : String(localized: "未选择")
        )
        .accessibilityAddTraits(editorDisplayMode == mode ? .isSelected : [])
        .help(String(localized: "切换到\(mode.localizedDisplayName)模式"))
      }
    }
    .padding(2)
    .background(WorkbenchBackgroundStyle.badge, in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control))
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func editorActionLabel(
    _ title: String,
    systemName: String,
    showsTitle: Bool
  ) -> some View {
    if showsTitle {
      Label(title, systemImage: systemName)
        .labelStyle(.titleAndIcon)
    } else {
      Image(systemName: systemName)
        .accessibilityHidden(true)
    }
  }

  private func articleAIActionButton(
    _ capability: AIPublishingDefaultCapability,
    kind: AIPublishingActionKind
  ) -> some View {
    let availability = actions.articleAIActionAvailability(kind)
    return Button {
      actions.onPerformArticleAIAction(kind)
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
    let availability = actions.selectionAIActionAvailability(kind)
    return Button {
      actions.onPerformSelectionAIAction(kind)
    } label: {
      Label(
        capability == .translate ? kind.localizedDisplayName : capability.localizedDisplayName,
        systemImage: capability.systemImage
      )
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? capability.localizedDisplayName)
  }

  private func exportButton(
    _ title: LocalizedStringKey,
    systemImage: String,
    format: MarkdownDocumentExportFormat
  ) -> some View {
    Button {
      actions.onExportDocument(format)
    } label: {
      Label(title, systemImage: systemImage)
    }
  }
}

private struct MarkdownEditorToolbarButtonStyle: ButtonStyle {
  let showsTitle: Bool

  @Environment(\.isFocused) private var isFocused

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.workbenchButtonLabel)
      .padding(.horizontal, showsTitle ? 8 : 6)
      .frame(minWidth: showsTitle ? nil : 30, minHeight: 30)
      .fixedSize(horizontal: showsTitle, vertical: false)
      .background(
        Color.primary.opacity(configuration.isPressed ? 0.10 : 0.04),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .stroke(
            isFocused ? Color.accentColor : Color.clear,
            lineWidth: isFocused ? 2 : 0
          )
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
  let cursorPosition: MarkdownCursorPosition?
  let fenceMatch: MarkdownFenceMatch?
  let completion: MarkdownCompletionContext?
  let writingToolDensity: MarkdownWritingToolDensity
  let onApplyMarkdownFormatting: (MarkdownFormattingCommand) -> Void
  let onApplyAdvancedFormatting: (MarkdownAdvancedFormattingCommand) -> Void
  let onEditLines: (MarkdownLineEditingCommand) -> Void
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
  let onJumpToLine: (Int) -> Void
  let onJumpToCounterpartFence: () -> Void
  let onApplyCompletion: (MarkdownCompletionCandidate) -> Void
  let onInsertCompletionTrigger: (MarkdownCompletionTrigger) -> Void

  var body: some View {
    Group {
      if writingToolDensity == .basic {
        ViewThatFits(in: .horizontal) {
          basicRow(showsTitle: true)
          basicRow(showsTitle: false)
        }
      } else {
        ViewThatFits(in: .horizontal) {
          expandedRow(showsTitle: true)
          compactRows(showsTitle: true)
          expandedRow(showsTitle: false)
          compactRows(showsTitle: false)
        }
      }
    }
    .buttonStyle(WorkbenchFocusRingButtonStyle())
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private func basicRow(showsTitle: Bool) -> some View {
    HStack(spacing: 5) {
      headingButton(level: 1, title: "一级标题", showsTitle: showsTitle)
      headingButton(level: 2, title: "二级标题", showsTitle: showsTitle)
      toolbarDivider
      toolbarButton(title: "粗体", systemName: "bold", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.bold)
      }
      toolbarButton(title: "斜体", systemName: "italic", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.italic)
      }
      toolbarDivider
      toolbarButton(title: "链接", systemName: "link", showsTitle: showsTitle) {
        onInsertInternalLink()
      }
      toolbarButton(title: "插图", systemName: "photo", showsTitle: showsTitle) {
        onInsertImage()
      }
      Spacer(minLength: 8)
      trailingControls(showsTitle: showsTitle)
    }
  }

  private func expandedRow(showsTitle: Bool) -> some View {
    HStack(spacing: 5) {
      headingButtons(showsTitle: showsTitle)
      toolbarDivider
      inlineStyleButtons(showsTitle: showsTitle)
      toolbarDivider
      blockButtons(showsTitle: showsTitle)
      toolbarDivider
      insertionButtons(showsTitle: showsTitle)
      Spacer(minLength: 8)
      trailingControls(showsTitle: showsTitle)
    }
  }

  private func compactRows(showsTitle: Bool) -> some View {
    VStack(spacing: 5) {
      HStack(spacing: 5) {
        headingButtons(showsTitle: showsTitle)
        toolbarDivider
        inlineStyleButtons(showsTitle: showsTitle)
        toolbarDivider
        quoteAndCodeBlockButtons(showsTitle: showsTitle)
        Spacer(minLength: 0)
      }

      Divider()

      HStack(spacing: 5) {
        listButtons(showsTitle: showsTitle)
        toolbarDivider
        insertionButtons(showsTitle: showsTitle)
        Spacer(minLength: 8)
        trailingControls(showsTitle: showsTitle)
      }
    }
  }

  @ViewBuilder
  private func headingButtons(showsTitle: Bool) -> some View {
    headingButton(level: 1, title: "一级标题", showsTitle: showsTitle)
    headingButton(level: 2, title: "二级标题", showsTitle: showsTitle)
    headingButton(level: 3, title: "三级标题", showsTitle: showsTitle)
  }

  @ViewBuilder
  private func inlineStyleButtons(showsTitle: Bool) -> some View {
    toolbarButton(title: "粗体", systemName: "bold", showsTitle: showsTitle) {
      onApplyMarkdownFormatting(.bold)
    }
    toolbarButton(title: "斜体", systemName: "italic", showsTitle: showsTitle) {
      onApplyMarkdownFormatting(.italic)
    }
    toolbarButton(
      title: "行内代码",
      systemName: "chevron.left.forwardslash.chevron.right",
      showsTitle: showsTitle
    ) {
      onApplyAdvancedFormatting(.inlineCode)
    }
  }

  @ViewBuilder
  private func blockButtons(showsTitle: Bool) -> some View {
    quoteAndCodeBlockButtons(showsTitle: showsTitle)
    listButtons(showsTitle: showsTitle)
  }

  @ViewBuilder
  private func quoteAndCodeBlockButtons(showsTitle: Bool) -> some View {
    toolbarButton(title: "引用", systemName: "text.quote", showsTitle: showsTitle) {
      onApplyAdvancedFormatting(.blockquote)
    }
    toolbarButton(title: "代码块", systemName: "curlybraces.square", showsTitle: showsTitle) {
      onInsertCodeBlock()
    }
  }

  @ViewBuilder
  private func listButtons(showsTitle: Bool) -> some View {
    toolbarButton(title: "无序列表", systemName: "list.bullet", showsTitle: showsTitle) {
      onApplyAdvancedFormatting(.unorderedList)
    }
    toolbarButton(title: "有序列表", systemName: "list.number", showsTitle: showsTitle) {
      onApplyAdvancedFormatting(.orderedList)
    }
    toolbarButton(title: "任务列表", systemName: "checklist", showsTitle: showsTitle) {
      onApplyAdvancedFormatting(.taskList)
    }
  }

  @ViewBuilder
  private func insertionButtons(showsTitle: Bool) -> some View {
    toolbarButton(title: "链接", systemName: "link", showsTitle: showsTitle) {
      onInsertInternalLink()
    }
    toolbarButton(title: "插图", systemName: "photo", showsTitle: showsTitle) {
      onInsertImage()
    }

    Menu {
      Section("高级格式") {
        Button {
          onApplyAdvancedFormatting(.strikethrough)
        } label: {
          Label("删除线", systemImage: "strikethrough")
        }
        Button {
          onApplyAdvancedFormatting(.removeFormatting)
        } label: {
          Label("清除 Markdown 格式", systemImage: "textformat")
        }
      }

      Section("行与任务") {
        Button {
          onEditLines(.moveUp)
        } label: {
          Label("行上移", systemImage: "arrow.up")
        }
        Button {
          onEditLines(.moveDown)
        } label: {
          Label("行下移", systemImage: "arrow.down")
        }
        Button {
          onEditLines(.duplicateBelow)
        } label: {
          Label("复制当前行", systemImage: "plus.square.on.square")
        }
        Button {
          onEditLines(.toggleTaskCompletion)
        } label: {
          Label("切换任务完成状态", systemImage: "checkmark.square")
        }
      }

      Divider()

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
        Label("组件与片段", systemImage: "rectangle.3.group")
      }
      Button {
        onInsertVideo()
      } label: {
        Label("插入视频", systemImage: "video")
      }
    } label: {
      toolbarLabel("更多插入选项", systemName: "ellipsis.circle", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("更多插入选项")
    .accessibilityLabel("更多插入选项")
  }

  @ViewBuilder
  private func trailingControls(showsTitle: Bool) -> some View {
    Button {
      onShowDiagnostics()
    } label: {
      ZStack(alignment: .topTrailing) {
        toolbarLabel(
          "正文诊断",
          systemName: diagnosticCount == 0 ? "checkmark.circle" : "waveform.badge.exclamationmark",
          showsTitle: showsTitle
        )
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
    .help(
      diagnosticCount == 0
        ? String(localized: "正文诊断：未发现问题")
        : String(localized: "正文诊断：\(diagnosticCount) 项")
    )
    .accessibilityLabel("正文诊断")
    .accessibilityValue(
      diagnosticCount == 0
        ? String(localized: "没有问题")
        : String(localized: "\(diagnosticCount) 项")
    )
    MarkdownEditorComfortControl(showsTitle: showsTitle)
    toolbarDivider
    MarkdownCursorWorkflowControls(
      position: cursorPosition,
      lineCount: lineCount,
      fenceMatch: fenceMatch,
      completion: completion,
      showsTitle: showsTitle,
      onJumpToLine: onJumpToLine,
      onJumpToCounterpartFence: onJumpToCounterpartFence,
      onApplyCompletion: onApplyCompletion,
      onInsertCompletionTrigger: onInsertCompletionTrigger
    )
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
      .help(
        String(
          localized: "\(hanCharacterCount) 汉字 · \(wordCount) 西文词 · \(characterCount) 字符 · \(lineCount) 行 · 约 \(readingMinutes) 分钟 · 目标 \(writingGoal) 字/词"
        )
      )
      .accessibilityLabel("文章统计")
      .accessibilityValue(
        String(
          localized: "\(hanCharacterCount) 个汉字，\(wordCount) 个西文词，合计 \(writingUnitCount) 字词，\(lineCount) 行，预计阅读 \(readingMinutes) 分钟，写作目标 \(writingGoal) 字词，已完成 \(writingGoalProgressPercent)%"
        )
      )
  }

  private var statisticsSummary: String {
    String(
      localized: "⏱️ 约 \(readingMinutes) 分钟 · \(writingUnitCount) 字/词"
    )
  }

  private var writingGoalProgressPercent: Int {
    guard writingGoal > 0 else { return 0 }
    return min(100, Int(Double(writingUnitCount) / Double(writingGoal) * 100))
  }

  private func headingButton(
    level: Int,
    title: LocalizedStringKey,
    showsTitle: Bool
  ) -> some View {
    Button {
      onApplyMarkdownFormatting(.heading(level: level))
    } label: {
      if showsTitle {
        Label {
          Text(title)
        } icon: {
          Text("H\(level)")
            .font(.workbenchMetadata.weight(.semibold))
            .monospaced()
        }
      } else {
        Text("H\(level)")
          .font(.workbenchMetadata.weight(.semibold))
          .monospaced()
          .frame(width: 28, height: 28)
      }
    }
    .foregroundStyle(.secondary)
    .help(title)
    .accessibilityLabel(Text(title))
  }

  private func toolbarButton(
    title: LocalizedStringKey,
    systemName: String,
    showsTitle: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      toolbarLabel(title, systemName: systemName, showsTitle: showsTitle)
    }
    .foregroundStyle(.secondary)
    .help(title)
    .accessibilityLabel(Text(title))
  }

  @ViewBuilder
  private func toolbarLabel(
    _ title: LocalizedStringKey,
    systemName: String,
    showsTitle: Bool
  ) -> some View {
    if showsTitle {
      Label(title, systemImage: systemName)
        .labelStyle(.titleAndIcon)
        .font(.workbenchButtonLabel)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 6)
        .frame(minHeight: 28)
    } else {
      Image(systemName: systemName)
        .frame(width: 28, height: 28)
    }
  }

}
