import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownEditorToolbar: View {
  @Binding var title: String
  let store: WorkbenchStore
  let markdownPath: String
  let lastSaveStatus: String
  let hasUnsavedChanges: Bool
  let editorDisplayMode: EditorDisplayMode
  let isSelectionAIActionRunning: Bool
  let canOpenAIChat: Bool
  let aiChatUnavailableReason: String?
  @Binding var isAutomaticInlineAICompletionEnabled: Bool
  let writingToolDensity: MarkdownWritingToolDensity
  let availableWritingContextPanels: [MarkdownWritingContextPanel]
  let actions: MarkdownEditorToolbarActions
  @EnvironmentObject private var localPreviewState: WorkbenchLocalSitePreviewFeatureFacade
  @State private var isLocalPreviewPopoverPresented = false
  @State private var selectedPublishAssets = AIPublishingAssetKind.defaultSelection
  @AppStorage("workspace.customToolbarConfig") private var customToolbarConfigRawValue = ""
  @State private var isCustomizationSheetPresented = false
  @Namespace private var editorModeNamespace

  private var toolbarConfiguration: Binding<MarkdownToolbarConfiguration> {
    Binding(
      get: {
        MarkdownToolbarConfiguration.decodeFromJSON(customToolbarConfigRawValue)
      },
      set: { newConfig in
        customToolbarConfigRawValue = newConfig.normalized.encodeToJSON()
      }
    )
  }

  init(
    title: Binding<String>,
    store: WorkbenchStore,
    markdownPath: String,
    lastSaveStatus: String,
    hasUnsavedChanges: Bool,
    editorDisplayMode: EditorDisplayMode,
    isSelectionAIActionRunning: Bool,
    canOpenAIChat: Bool,
    aiChatUnavailableReason: String?,
    isAutomaticInlineAICompletionEnabled: Binding<Bool>,
    writingToolDensity: MarkdownWritingToolDensity,
    availableWritingContextPanels: [MarkdownWritingContextPanel],
    actions: MarkdownEditorToolbarActions
  ) {
    _title = title
    self.store = store
    self.markdownPath = markdownPath
    self.lastSaveStatus = lastSaveStatus
    self.hasUnsavedChanges = hasUnsavedChanges
    self.editorDisplayMode = editorDisplayMode
    self.isSelectionAIActionRunning = isSelectionAIActionRunning
    self.canOpenAIChat = canOpenAIChat
    self.aiChatUnavailableReason = aiChatUnavailableReason
    _isAutomaticInlineAICompletionEnabled = isAutomaticInlineAICompletionEnabled
    self.writingToolDensity = writingToolDensity
    self.availableWritingContextPanels = availableWritingContextPanels
    self.actions = actions
  }

  var body: some View {
    HStack(spacing: 8) {
      titleArea

      Spacer(minLength: 8)

      configuredIconToolbarControls
    }
    .padding(.horizontal, WorkbenchSpacing.section)
    .padding(.vertical, 9)
    .contextMenu {
      Button {
        isCustomizationSheetPresented = true
      } label: {
        Label("自定义工具栏…", systemImage: "slider.horizontal.3")
      }
    }
    .sheet(isPresented: $isCustomizationSheetPresented) {
      MacMarkdownToolbarCustomizationView(
        configuration: toolbarConfiguration,
        onDismiss: { isCustomizationSheetPresented = false }
      )
    }
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

      InteractiveBreadcrumbView(
        markdownPath: markdownPath,
        fileURL: nil
      )
    }
    .frame(minWidth: 220, idealWidth: 320, maxWidth: 460, alignment: .leading)
  }

  private var enabledHeaderItemIDs: [MarkdownToolbarItemID] {
    MarkdownToolbarConfiguration.decodeFromJSON(customToolbarConfigRawValue).headerItemIDs
  }

  /// The medium and compact layouts keep the controls that are most useful
  /// while editing in the main row. All other enabled controls remain
  /// reachable from the overflow menu; hidden controls never leak into it.
  private var mediumHeaderItemIDs: [MarkdownToolbarItemID] {
    let mediumPriority: Set<MarkdownToolbarItemID> = [
      .saveStatus,
      .editorDisplayMode,
      .writingToolDensity,
      .findReplace,
      .autoInlineAI,
      .aiChat,
      .preparePublish,
    ]
    return enabledHeaderItemIDs.filter(mediumPriority.contains)
  }

  private var compactHeaderItemIDs: [MarkdownToolbarItemID] {
    let compactPriority: Set<MarkdownToolbarItemID> = [
      .saveStatus,
      .editorDisplayMode,
      .autoInlineAI,
      .aiChat,
      .preparePublish,
    ]
    return enabledHeaderItemIDs.filter(compactPriority.contains)
  }

  private var configuredIconToolbarControls: some View {
    ViewThatFits(in: .horizontal) {
      // 1. 完整展开模式
      HStack(spacing: 5) {
        ForEach(enabledHeaderItemIDs) { item in
          headerItem(item, showsTitle: false)
        }
      }

      // 2. 中度折叠模式
      HStack(spacing: 5) {
        ForEach(mediumHeaderItemIDs) { item in
          headerItem(item, showsTitle: false)
        }
        overflowMenu(reservedIDs: mediumHeaderItemIDs)
      }

      // 3. 紧凑折叠模式
      HStack(spacing: 5) {
        ForEach(compactHeaderItemIDs) { item in
          headerItem(item, showsTitle: false)
        }
        overflowMenu(reservedIDs: compactHeaderItemIDs)
      }
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .frame(minHeight: 34)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("写作工具栏")
  }

  @ViewBuilder
  private func headerItem(_ item: MarkdownToolbarItemID, showsTitle: Bool) -> some View {
    switch item {
    case .saveStatus:
      iconSaveStatus
    case .editorDisplayMode:
      editorDisplayModeControl(showsTitle: showsTitle)
    case .writingToolDensity:
      writingToolDensityControl(showsTitle: showsTitle)
    case .findReplace:
      findReplaceButton(showsTitle: showsTitle)
    case .outline:
      outlineButton(showsTitle: showsTitle)
    case .contextPanelMenu:
      contextPanelMenu(showsTitle: showsTitle)
    case .shortcutHelp:
      shortcutHelpButton(showsTitle: showsTitle)
    case .exportMenu:
      exportMenuButton(showsTitle: showsTitle)
    case .aiActions:
      aiActionsMenuButton(showsTitle: showsTitle)
    case .autoInlineAI:
      automaticInlineAICompletionButton(showsTitle: showsTitle)
    case .aiChat:
      aiChatButton(showsTitle: showsTitle)
    case .localPreview:
      localSitePreviewButton(showsTitle: showsTitle)
    case .preparePublish:
      preparePublishButton(showsTitle: showsTitle)
    case .copyRichText:
      copyRichTextButton(showsTitle: showsTitle)
    default:
      EmptyView()
    }
  }

  private func overflowMenu(reservedIDs: [MarkdownToolbarItemID]) -> some View {
    Menu {
      let reserved = Set(reservedIDs)
      ForEach(enabledHeaderItemIDs.filter { !reserved.contains($0) }) { item in
        headerItem(item, showsTitle: true)
      }
      Divider()
      Button {
        isCustomizationSheetPresented = true
      } label: {
        Label("自定义工具栏…", systemImage: "slider.horizontal.3")
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .accessibilityHidden(true)
    }
    .menuIndicator(.hidden)
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: false))
    .help("更多工具栏操作")
    .accessibilityLabel("更多工具栏操作")
    .accessibilityIdentifier("markdown-toolbar-overflow-menu")
  }

  private func findReplaceButton(showsTitle: Bool) -> some View {
    Button {
      actions.onShowFindReplace()
    } label: {
      editorActionLabel(
        String(localized: "查找与替换"), systemName: "magnifyingglass", showsTitle: showsTitle)
    }
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .help(String(localized: "查找与替换（⌘F）"))
    .accessibilityLabel("查找与替换")
  }

  private func outlineButton(showsTitle: Bool) -> some View {
    Button {
      actions.onShowOutline()
    } label: {
      editorActionLabel(
        String(localized: "文章大纲"), systemName: "list.bullet.indent", showsTitle: showsTitle)
    }
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .keyboardShortcut("o", modifiers: [.command, .option])
    .help(String(localized: "文章大纲（⌥⌘O）"))
    .accessibilityLabel("文章大纲")
    .accessibilityIdentifier("markdown-outline-button")
  }

  private func shortcutHelpButton(showsTitle: Bool) -> some View {
    Button {
      actions.onShowShortcutHelp()
    } label: {
      editorActionLabel(
        String(localized: "快捷键说明"), systemName: "keyboard", showsTitle: showsTitle)
    }
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .help(String(localized: "快捷键说明（⌥⌘/）"))
    .accessibilityLabel("快捷键说明")
  }

  private func exportMenuButton(showsTitle: Bool) -> some View {
    Menu {
      exportActions
    } label: {
      editorActionLabel(
        String(localized: "导出文章"), systemName: "square.and.arrow.up", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .help(String(localized: "导出、打印或分享当前文章"))
    .accessibilityLabel("导出文章")
    .accessibilityIdentifier("markdown-document-export-menu")
  }

  private func aiActionsMenuButton(showsTitle: Bool) -> some View {
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


  private var editorToolbarDivider: some View {
    Divider()
      .frame(height: 18)
  }

  private var iconSaveStatus: some View {
    Group {
      if hasUnsavedChanges {
        Circle()
          .fill(WorkbenchTheme.warning)
          .frame(width: 7, height: 7)
          .shadow(color: WorkbenchTheme.warning.opacity(0.6), radius: 3)
      } else {
        Image(systemName: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(WorkbenchTheme.success)
      }
    }
    .frame(minWidth: 18, minHeight: 30)
    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hasUnsavedChanges)
    .help(lastSaveStatus)
    .accessibilityLabel("保存状态")
    .accessibilityValue(lastSaveStatus)
  }

  private var editorActions: some View {
    editorActionGroup(showsTitle: false)
      .accessibilityElement(children: .contain)
  }

  private func automaticInlineAICompletionButton(showsTitle: Bool) -> some View {
    Button {
      isAutomaticInlineAICompletionEnabled.toggle()
    } label: {
      if showsTitle {
        Label("自动 AI 续写", systemImage: "wand.and.stars")
      } else {
        Image(systemName: "wand.and.stars")
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(
      MarkdownEditorToolbarButtonStyle(
        showsTitle: showsTitle,
        isSelected: isAutomaticInlineAICompletionEnabled
      )
    )
    .foregroundStyle(
      isAutomaticInlineAICompletionEnabled
        ? Color.purple
        : Color.secondary
    )
    .background(
      RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
        .fill(
          isAutomaticInlineAICompletionEnabled
            ? AnyShapeStyle(LinearGradient(
                colors: [Color.purple.opacity(0.18), Color.indigo.opacity(0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
              ))
            : AnyShapeStyle(Color.clear)
        )
    )
    .help(String(localized: "自动 AI 续写"))
    .accessibilityLabel(String(localized: "自动 AI 续写"))
    .accessibilityValue(
      isAutomaticInlineAICompletionEnabled
        ? String(localized: "开启")
        : String(localized: "关闭")
    )
    .accessibilityAddTraits(
      isAutomaticInlineAICompletionEnabled ? .isSelected : []
    )
    .accessibilityIdentifier("markdown-automatic-inline-ai-completion")
  }

  private func aiChatButton(showsTitle: Bool) -> some View {
    Button {
      actions.onOpenAIContextInspector()
    } label: {
      if showsTitle {
        Label("AI 对话", systemImage: "sparkles")
      } else {
        Image(systemName: "sparkles")
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .foregroundStyle(Color.purple)
    .disabled(!canOpenAIChat)
    .opacity(isSelectionAIActionRunning ? 0.45 : 1.0)
    .animation(
      isSelectionAIActionRunning
        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
        : .default,
      value: isSelectionAIActionRunning
    )
    .help(
      aiChatUnavailableReason
        ?? String(localized: "在右侧继续当前文章的 AI 对话")
    )
    .accessibilityLabel(String(localized: "AI 对话"))
    .accessibilityValue(
      isSelectionAIActionRunning ? String(localized: "AI 正在生成回复") : ""
    )
    .accessibilityIdentifier("markdown-ai-assistant-entry")
  }

  private func localSitePreviewButton(showsTitle: Bool) -> some View {
    let isRunning = localPreviewState.runtimeStatus.isRunning
    let isReady = localPreviewState.plan?.diagnostics.isReadyToStart == true
    let title = isRunning ? "打开预览" : "本地预览"

    return Button {
      isLocalPreviewPopoverPresented.toggle()
    } label: {
      if showsTitle {
        Label(title, systemImage: isRunning ? "safari" : "play.rectangle")
      } else {
        Image(systemName: isRunning ? "safari" : "play.rectangle")
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .help(
      isRunning
        ? String(localized: "管理本地站点预览")
        : String(localized: "在写作界面启动本地站点预览")
    )
    .accessibilityLabel(isRunning ? "打开本地站点预览" : "本地站点预览")
    .accessibilityValue(
      isRunning
        ? String(localized: "预览正在运行")
        : (isReady ? String(localized: "可以启动") : String(localized: "需要先配置站点仓库"))
    )
    .accessibilityIdentifier("markdown-local-site-preview")
    .popover(isPresented: $isLocalPreviewPopoverPresented, arrowEdge: .top) {
      MacMarkdownLocalPreviewPopover(
        currentArticleURL: store.selectedDraft.flatMap { store.localSitePreviewURL(for: $0) }
      )
    }
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

  private func copyRichTextButton(showsTitle: Bool) -> some View {
    Button {
      actions.onCopyForWeChatAndZhihu?()
    } label: {
      if showsTitle {
        Label("复制到公众号/知乎", systemImage: "doc.on.doc.fill")
      } else {
        Image(systemName: "doc.on.doc.fill")
          .accessibilityHidden(true)
      }
    }
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .help("将当前文章以精美内联样式复制为富文本（适配微信公众号、知乎后台）")
    .accessibilityLabel("复制到公众号/知乎富文本")
  }

  private func editorActionGroup(showsTitle: Bool) -> some View {
    HStack(spacing: 4) {
      Button {
        actions.onShowFindReplace()
      } label: {
        editorActionLabel(
          String(localized: "查找与替换"), systemName: "magnifyingglass", showsTitle: showsTitle)
      }
      .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
      .help(String(localized: "查找与替换（⌘F）"))
      .accessibilityLabel("查找与替换")

      contextPanelMenu(showsTitle: showsTitle)

      Button {
        actions.onShowShortcutHelp()
      } label: {
        editorActionLabel(
          String(localized: "快捷键说明"), systemName: "keyboard", showsTitle: showsTitle)
      }
      .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
      .help(String(localized: "快捷键说明（⌥⌘/）"))
      .accessibilityLabel("快捷键说明")

      Menu {
        exportActions
      } label: {
        editorActionLabel(
          String(localized: "导出文章"), systemName: "square.and.arrow.up", showsTitle: showsTitle)
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

  private func writingToolDensityControl(showsTitle: Bool) -> some View {
    Menu {
      writingToolDensityActions
    } label: {
      editorActionLabel(
        "写作工具密度",
        systemName: "slider.horizontal.3",
        showsTitle: showsTitle
      )
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
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
    Button {
      actions.onCopyForWeChatAndZhihu?()
    } label: {
      Label("复制到公众号/知乎富文本", systemImage: "doc.on.doc.fill")
    }

    Divider()

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
            Label(
              style.localizedDisplayName,
              systemImage: style == .balanced ? "wand.and.stars" : "textformat"
            )
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
            Label(operation.localizedDisplayName, systemImage: "wand.and.stars")
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
            Label(asset.localizedDisplayName, systemImage: "checkmark.square")
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
          withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
            actions.onSetEditorDisplayMode(mode)
          }
        } label: {
          editorActionLabel(
            mode.localizedDisplayName,
            systemName: mode.systemImage,
            showsTitle: showsTitle
          )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, showsTitle ? 8 : 6)
        .frame(minWidth: showsTitle ? nil : 30, minHeight: 28)
        .foregroundStyle(
          editorDisplayMode == mode ? Color.primary : Color.secondary
        )
        .background {
          if editorDisplayMode == mode {
            RoundedRectangle(cornerRadius: 6)
              .fill(Color(nsColor: .controlBackgroundColor))
              .shadow(color: Color.black.opacity(0.12), radius: 2, x: 0, y: 1)
              .matchedGeometryEffect(id: "activeModeSegment", in: editorModeNamespace)
          }
        }
        .accessibilityLabel(String(localized: "编辑器模式：\(mode.localizedDisplayName)"))
        .accessibilityValue(
          editorDisplayMode == mode ? String(localized: "已选择") : String(localized: "未选择")
        )
        .accessibilityAddTraits(editorDisplayMode == mode ? .isSelected : [])
        .help(String(localized: "切换到\(mode.localizedDisplayName)模式"))
      }
    }
    .padding(2)
    .background(
      Color.primary.opacity(0.06),
      in: RoundedRectangle(cornerRadius: 8)
    )
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
  var isSelected = false

  @Environment(\.isFocused) private var isFocused

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.workbenchButtonLabel)
      .padding(.horizontal, showsTitle ? 8 : 6)
      .frame(minWidth: showsTitle ? nil : 30, minHeight: 30)
      .fixedSize(horizontal: showsTitle, vertical: false)
      .background(
        isSelected
          ? WorkbenchTheme.navigationSelection.opacity(configuration.isPressed ? 0.18 : 0.10)
          : Color.primary.opacity(configuration.isPressed ? 0.10 : 0.04),
        in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkbenchCornerRadius.control)
          .stroke(
            isFocused
              ? Color.accentColor
              : (isSelected
                ? WorkbenchTheme.navigationSelection.opacity(0.70)
                : Color.clear),
            lineWidth: isFocused ? 2 : (isSelected ? 1 : 0)
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
  var onFormatChineseTypography: (() -> Void)? = nil
  var onCopyForWeChatAndZhihu: (() -> Void)? = nil
  @AppStorage("workspace.customToolbarConfig") private var customToolbarConfigRawValue = ""
  @AppStorage("workspace.editorTargetWordCount") private var targetWordCount: Int = 0
  @State private var isStatsPopoverPresented = false

  private var toolbarConfiguration: MarkdownToolbarConfiguration {
    MarkdownToolbarConfiguration.decodeFromJSON(customToolbarConfigRawValue)
  }

  private var configuredFormattingItemIDs: [MarkdownToolbarItemID] {
    toolbarConfiguration.formattingItemIDs
  }

  private var basicFormattingItemIDs: [MarkdownToolbarItemID] {
    let basicItems: Set<MarkdownToolbarItemID> = [
      .headingMenu,
      .heading1,
      .heading2,
      .bold,
      .italic,
      .listMenu,
      .unorderedList,
      .link,
      .image,
      .formatChineseTypography,
    ]
    return configuredFormattingItemIDs.filter(basicItems.contains)
  }

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      Group {
        if writingToolDensity == .basic {
          formattingRow(itemIDs: basicFormattingItemIDs, showsTitle: false)
        } else {
          formattingRow(itemIDs: configuredFormattingItemIDs, showsTitle: false)
        }
      }
      .fixedSize(horizontal: true, vertical: false)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .frame(minHeight: 34)
    .buttonStyle(WorkbenchFocusRingButtonStyle())
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.bar)
  }

  private func formattingRow(
    itemIDs: [MarkdownToolbarItemID],
    showsTitle: Bool
  ) -> some View {
    HStack(spacing: 5) {
      ForEach(itemIDs) { item in
        formattingItem(item, showsTitle: showsTitle)
      }
      Spacer(minLength: 8)
      fixedTrailingControls(showsTitle: showsTitle)
    }
  }

  @ViewBuilder
  private func formattingItem(
    _ item: MarkdownToolbarItemID,
    showsTitle: Bool
  ) -> some View {
    switch item {
    case .headingMenu:
      headingMenuButton(showsTitle: showsTitle)
    case .listMenu:
      listMenuButton(showsTitle: showsTitle)
    case .heading1:
      headingButton(level: 1, title: "一级标题", showsTitle: showsTitle)
    case .heading2:
      headingButton(level: 2, title: "二级标题", showsTitle: showsTitle)
    case .heading3:
      headingButton(level: 3, title: "三级标题", showsTitle: showsTitle)
    case .bold:
      toolbarButton(title: "粗体", systemName: "bold", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.bold)
      }
    case .italic:
      toolbarButton(title: "斜体", systemName: "italic", showsTitle: showsTitle) {
        onApplyMarkdownFormatting(.italic)
      }
    case .inlineCode:
      toolbarButton(
        title: "行内代码",
        systemName: "chevron.left.forwardslash.chevron.right",
        showsTitle: showsTitle
      ) {
        onApplyAdvancedFormatting(.inlineCode)
      }
    case .blockquote:
      toolbarButton(title: "引用", systemName: "text.quote", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.blockquote)
      }
    case .codeBlock:
      toolbarButton(title: "代码块", systemName: "curlybraces.square", showsTitle: showsTitle) {
        onInsertCodeBlock()
      }
    case .unorderedList:
      toolbarButton(title: "无序列表", systemName: "list.bullet", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.unorderedList)
      }
    case .orderedList:
      toolbarButton(title: "有序列表", systemName: "list.number", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.orderedList)
      }
    case .taskList:
      toolbarButton(title: "任务列表", systemName: "checklist", showsTitle: showsTitle) {
        onApplyAdvancedFormatting(.taskList)
      }
    case .link:
      toolbarButton(title: "链接", systemName: "link", showsTitle: showsTitle) {
        onInsertInternalLink()
      }
    case .image:
      toolbarButton(title: "插图", systemName: "photo", showsTitle: showsTitle) {
        onInsertImage()
      }
    case .moreInsertions:
      moreInsertionsMenu(showsTitle: showsTitle)
    case .diagnostics:
      diagnosticButton(showsTitle: showsTitle)
    case .formatChineseTypography:
      toolbarButton(title: "中英文排版", systemName: "textformat", showsTitle: showsTitle) {
        onFormatChineseTypography?()
      }
    default:
      EmptyView()
    }
  }

  @ViewBuilder
  private func moreInsertionsMenu(showsTitle: Bool) -> some View {
    Menu {
      Button {
        onApplyAdvancedFormatting(.strikethrough)
      } label: {
        Label("删除线", systemImage: "strikethrough")
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
  private func diagnosticButton(showsTitle: Bool) -> some View {
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
  }

  @ViewBuilder
  private func fixedTrailingControls(showsTitle: Bool) -> some View {
    ZenModeToggleButton(showsTitle: showsTitle)
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
    Button {
      isStatsPopoverPresented.toggle()
    } label: {
      HStack(spacing: 5) {
        if targetWordCount > 0 {
          let ratio = min(1.0, Double(writingUnitCount) / Double(targetWordCount))
          let percent = Int((Double(writingUnitCount) / Double(targetWordCount)) * 100)
          ProgressView(value: ratio)
            .progressViewStyle(.linear)
            .frame(width: 36)
            .tint(ratio >= 1.0 ? WorkbenchTheme.success : WorkbenchTheme.primary)
          Text("\(writingUnitCount)/\(targetWordCount) (\(percent)%)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(ratio >= 1.0 ? WorkbenchTheme.success : .primary)
        } else {
          Text(statisticsSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 4)
          .fill(isStatsPopoverPresented ? Color.secondary.opacity(0.12) : Color.clear)
      )
    }
    .buttonStyle(.plain)
    .help("点击查看详细统计与设定目标字数")
    .accessibilityLabel("文章统计")
    .accessibilityValue(statisticsAccessibilityValue)
    .popover(isPresented: $isStatsPopoverPresented, arrowEdge: .bottom) {
      statisticsDetailPopover
    }
  }

  private var statisticsDetailPopover: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("文章统计与目标", systemImage: "chart.bar.doc.horizontal")
          .font(.headline)
        Spacer()
        Text("⏱️ 约 \(readingMinutes) 分钟")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
        GridRow {
          statCard(title: "中文字数", value: "\(hanCharacterCount)")
          statCard(title: "西文单词", value: "\(wordCount)")
        }
        GridRow {
          statCard(title: "合计字词", value: "\(writingUnitCount)")
          statCard(title: "全部字符", value: "\(characterCount)")
        }
        GridRow {
          statCard(title: "正文行数", value: "\(lineCount)")
          statCard(title: "预估阅读", value: "\(readingMinutes) 分钟")
        }
      }

      Divider()

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Label("目标字数", systemImage: "target")
            .font(.subheadline.weight(.medium))
          Spacer()
          if targetWordCount > 0 {
            let ratio = Double(writingUnitCount) / Double(targetWordCount)
            let percent = Int(ratio * 100)
            Text("\(percent)%")
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(ratio >= 1.0 ? WorkbenchTheme.success : WorkbenchTheme.primary)
          }
        }

        if targetWordCount > 0 {
          let ratio = min(1.0, Double(writingUnitCount) / Double(targetWordCount))
          ProgressView(value: ratio)
            .progressViewStyle(.linear)
            .tint(ratio >= 1.0 ? WorkbenchTheme.success : WorkbenchTheme.primary)

          if writingUnitCount >= targetWordCount {
            Text("🎉 已达成目标字数！（超出 \(writingUnitCount - targetWordCount) 字）")
              .font(.caption)
              .foregroundStyle(WorkbenchTheme.success)
          } else {
            Text("还需 \(targetWordCount - writingUnitCount) 字达成目标")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack(spacing: 5) {
          ForEach([0, 500, 1000, 2000, 3000, 5000], id: \.self) { goal in
            Button {
              targetWordCount = goal
            } label: {
              Text(goal == 0 ? "无" : "\(goal)")
                .font(.workbenchMetadata)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                  RoundedRectangle(cornerRadius: 4)
                    .fill(targetWordCount == goal ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                )
                .foregroundStyle(targetWordCount == goal ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
          }
        }
      }

      if onFormatChineseTypography != nil || onCopyForWeChatAndZhihu != nil {
        Divider()

        HStack(spacing: 8) {
          if let onFormatChineseTypography {
            Button {
              isStatsPopoverPresented = false
              onFormatChineseTypography()
            } label: {
              Label("排版优化", systemImage: "textformat")
                .font(.caption)
            }
          }

          if let onCopyForWeChatAndZhihu {
            Button {
              isStatsPopoverPresented = false
              onCopyForWeChatAndZhihu()
            } label: {
              Label("复制公众号", systemImage: "doc.on.doc")
                .font(.caption)
            }
          }
        }
      }
    }
    .padding(14)
    .frame(width: 270)
  }

  private func statCard(title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.workbenchMetadata)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.monospacedDigit().weight(.semibold))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statisticsSummary: String {
    String(
      localized: "⏱️ 约 \(readingMinutes) 分钟 · \(writingUnitCount) 字/词"
    )
  }

  private var statisticsAccessibilityValue: String {
    guard targetWordCount > 0 else { return statisticsSummary }
    let percent = Int((Double(writingUnitCount) / Double(targetWordCount)) * 100)
    return "\(statisticsSummary) · \(writingUnitCount)/\(targetWordCount) (\(percent)%)"
  }

  @ViewBuilder
  private func headingMenuButton(showsTitle: Bool) -> some View {
    Menu {
      ForEach(1...6, id: \.self) { level in
        Button {
          onApplyMarkdownFormatting(.heading(level: level))
        } label: {
          Label("\(level) 级标题 (H\(level))", systemImage: "textformat.size")
        }
      }
    } label: {
      if showsTitle {
        Label("标题", systemImage: "textformat.size")
      } else {
        HStack(spacing: 2) {
          Text("H")
            .font(.workbenchMetadata.weight(.semibold))
            .monospaced()
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 28, minHeight: 28)
      }
    }
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("插入或切换标题 (H1-H6)")
    .accessibilityLabel("标题层级")
  }

  @ViewBuilder
  private func listMenuButton(showsTitle: Bool) -> some View {
    Menu {
      Button {
        onApplyAdvancedFormatting(.unorderedList)
      } label: {
        Label("无序列表", systemImage: "list.bullet")
      }
      Button {
        onApplyAdvancedFormatting(.orderedList)
      } label: {
        Label("有序列表", systemImage: "list.number")
      }
      Button {
        onApplyAdvancedFormatting(.taskList)
      } label: {
        Label("任务列表", systemImage: "checklist")
      }
    } label: {
      if showsTitle {
        Label("列表", systemImage: "list.bullet")
      } else {
        HStack(spacing: 2) {
          Image(systemName: "list.bullet")
            .font(.system(size: 13, weight: .regular))
          Image(systemName: "chevron.down")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.secondary)
        }
        .frame(minWidth: 28, minHeight: 28)
      }
    }
    .menuIndicator(.hidden)
    .foregroundStyle(.secondary)
    .help("插入或切换列表（无序、有序、任务列表）")
    .accessibilityLabel("列表")
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

private struct ZenModeToggleButton: View {
  @EnvironmentObject private var zenModeController: ZenModeController
  let showsTitle: Bool

  var body: some View {
    Button {
      zenModeController.toggleZenMode()
    } label: {
      if showsTitle {
        Label(
          zenModeController.isZenModeActive ? "退出沉浸" : "沉浸模式",
          systemImage: zenModeController.isZenModeActive ? "leaf.fill" : "leaf"
        )
      } else {
        Image(systemName: zenModeController.isZenModeActive ? "leaf.fill" : "leaf")
          .frame(width: 28, height: 28)
      }
    }
    .foregroundStyle(
      zenModeController.isZenModeActive ? WorkbenchTheme.navigationSelection : Color.secondary
    )
    .help(zenModeController.isZenModeActive ? "退出沉浸模式" : "开启沉浸模式（打字时自动淡出工具栏）")
    .accessibilityLabel("沉浸模式")
  }
}
