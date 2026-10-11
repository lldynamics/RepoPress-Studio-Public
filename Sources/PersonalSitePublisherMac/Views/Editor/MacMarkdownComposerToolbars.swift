import PublishingWorkbenchCore
import SwiftUI

struct MacMarkdownEditorToolbar: View {
  @Binding var title: String
  @Binding var isFocusModeActive: Bool
  let titleFocusRequestID: UUID?
  let store: WorkbenchStore
  let draftID: UUID
  let markdownPath: String
  let isSelectionAIActionRunning: Bool
  let actions: MarkdownEditorToolbarActions
  let articleInformationToggle: MacMarkdownArticleInformationToggle?
  let formattingToolbar: MacMarkdownFormattingToolbar
  @EnvironmentObject private var zenModeController: ZenModeController
  @Environment(\.openSettings) private var openSettings
  @Environment(\.settingsWorkspaceCommandAction) private var settingsWorkspaceCommandAction
  @ObservedObject private var codexConnection = CodexConnectionController.shared
  @AppStorage(MarkdownEditorComfortPreferences.bodyWidthKey)
  private var bodyWidth = MarkdownEditorComfortConfiguration.defaultBodyWidth
  @AppStorage(MarkdownEditorComfortPreferences.warmPaperBackgroundEnabledKey)
  private var usesWarmPaper = MarkdownEditorComfortConfiguration.defaultWarmPaperBackgroundEnabled
  @State private var selectedPublishAssets = AIPublishingAssetKind.defaultSelection
  @State var isPublishAssetPickerPresented = false
  @State private var isVersionHistoryPresented = false

  init(
    title: Binding<String>,
    isFocusModeActive: Binding<Bool>,
    titleFocusRequestID: UUID? = nil,
    store: WorkbenchStore,
    draftID: UUID,
    markdownPath: String,
    isSelectionAIActionRunning: Bool,
    actions: MarkdownEditorToolbarActions,
    articleInformationToggle: MacMarkdownArticleInformationToggle? = nil,
    formattingToolbar: MacMarkdownFormattingToolbar
  ) {
    _title = title
    _isFocusModeActive = isFocusModeActive
    self.titleFocusRequestID = titleFocusRequestID
    self.store = store
    self.draftID = draftID
    self.markdownPath = markdownPath
    self.isSelectionAIActionRunning = isSelectionAIActionRunning
    self.actions = actions
    self.articleInformationToggle = articleInformationToggle
    self.formattingToolbar = formattingToolbar
  }

  var body: some View {
    VStack(spacing: WorkbenchSpacing.content) {
      editingTools
      titleArea
        .frame(maxWidth: CGFloat(bodyWidth), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
    }
    .padding(.horizontal, WorkbenchSpacing.content)
    .padding(.vertical, WorkbenchSpacing.control)
    .background(WorkbenchWritingSurface.color(usesWarmPaper: usesWarmPaper))
    .sheet(isPresented: $isVersionHistoryPresented) {
      DraftLifecycleCenterView(store: store, presentation: .articleHistory(draftID: draftID))
    }
    .focusedSceneValue(
      \.markdownEditorVersionHistoryCommandAction,
      versionHistoryCommandAction
    )
    .onChange(of: draftID) { _, _ in
      isVersionHistoryPresented = false
    }
    .popover(isPresented: $isPublishAssetPickerPresented) {
      MacMarkdownPublishAssetPickerPopover(
        selectedAssets: $selectedPublishAssets,
        isGenerationEnabled: aiConfigurationDestination == nil
          && actions.articleAIActionAvailability(.draftPublishAssetPack).isEnabled,
        onGenerate: {
          actions.onPerformConvergedArticleAIAction(
            .publishAssetPack(AIPublishingAssetPackConfiguration(assets: selectedPublishAssets))
          )
          isPublishAssetPickerPresented = false
        }
      )
    }
    .task(id: aiProviderConfig.preset == .codexAppServer) {
      if aiProviderConfig.preset == .codexAppServer {
        await codexConnection.refresh()
      }
    }
    .onKeyPress(.tab) {
      zenModeController.beginKeyboardNavigation()
      return .ignored
    }
    .onKeyPress(.leftArrow) {
      zenModeController.beginKeyboardNavigation()
      return .ignored
    }
    .onKeyPress(.rightArrow) {
      zenModeController.beginKeyboardNavigation()
      return .ignored
    }
    .onKeyPress(.upArrow) {
      zenModeController.beginKeyboardNavigation()
      return .ignored
    }
    .onKeyPress(.downArrow) {
      zenModeController.beginKeyboardNavigation()
      return .ignored
    }
    .onExitCommand {
      zenModeController.endKeyboardNavigation()
    }
    .onDisappear {
      zenModeController.endKeyboardNavigation()
    }
  }

  private var titleArea: some View {
    MacMarkdownEditorTitleArea(
      title: $title,
      focusRequestID: titleFocusRequestID,
      store: store,
      draftID: draftID,
      markdownPath: markdownPath,
      articleInformationToggle: articleInformationToggle
    )
  }

  private var editingTools: some View {
    ViewThatFits(in: .horizontal) {
      editingToolsRow(formattingLayout: .compact, collapsesWritingTools: false)
        .fixedSize(horizontal: true, vertical: false)
      editingToolsRow(formattingLayout: .compact, collapsesWritingTools: true)
        .fixedSize(horizontal: true, vertical: false)
      editingToolsRow(formattingLayout: .scrollable, collapsesWritingTools: true)
    }
    .padding(WorkbenchSpacing.tight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("编辑器工具栏")
    .accessibilityIdentifier("markdown-editor-floating-toolbar")
    .workbenchGlassSurface(
      material: .regularMaterial,
      in: RoundedRectangle(cornerRadius: WorkbenchCornerRadius.panel, style: .continuous)
    )
    .shadow(
      color: Color(nsColor: .shadowColor).opacity(WorkbenchOpacity.noticeBackground),
      radius: WorkbenchSpacing.tight, x: 0, y: 1
    )
    .frame(maxWidth: .infinity, alignment: .center)
  }

  private func editingToolsRow(
    formattingLayout: MarkdownFormattingToolbarLayout,
    collapsesWritingTools: Bool
  ) -> some View {
    HStack(spacing: WorkbenchSpacing.tight) {
      formattingTools(layout: formattingLayout)
        .layoutPriority(1)
      Divider().frame(height: WorkbenchIconSize.prominent)
      writingTools(isCollapsed: collapsesWritingTools)
    }
  }

  private var versionHistoryButton: some View {
    Button {
      versionHistoryCommandAction.open()
    } label: {
      Label("历史版本", systemImage: "clock.arrow.circlepath")
        .fixedSize()
    }
    .help("查看当前文章的历史版本并比较差异（⌃⌥⌘H）")
    .accessibilityLabel("历史版本")
    .accessibilityIdentifier("markdown-version-history-button")
  }

  private var versionHistoryCommandAction: MarkdownEditorVersionHistoryCommandAction {
    MarkdownEditorVersionHistoryCommandAction(
      draftID: draftID,
      prepare: actions.onPrepareVersionHistory,
      present: { isVersionHistoryPresented = true }
    )
  }

  private var aiProviderConfig: AIProviderConfig {
    guard let draft = store.drafts.first(where: { $0.id == draftID }) else {
      return store.aiProviderConfig(for: store.activeProfile)
    }
    return store.aiProviderConfig(for: store.profile(for: draft))
  }

  var aiConfigurationDestination: SettingsDestination? {
    MarkdownEditorAIConfigurationPresentation.destination(
      for: aiProviderConfig,
      isAIEnabled: actions.isAIEnabled,
      hasAuthenticatedChatGPTAccount: codexConnection.accountStatus?.isAuthenticated == true
    )
  }

  func openAIConfiguration(_ destination: SettingsDestination) {
    SettingsNavigation.present(
      destination: destination,
      workspaceAction: settingsWorkspaceCommandAction
    ) {
      openSettings()
    }
  }

  @ViewBuilder
  private func formattingTools(layout: MarkdownFormattingToolbarLayout) -> some View {
    switch layout {
    case .scrollable:
      formattingToolbar.withLayout(layout)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .automatic, .compact:
      formattingToolbar.withLayout(layout)
    }
  }

  private func writingTools(isCollapsed: Bool) -> some View {
    HStack(spacing: 4) {
      if isCollapsed {
        writingToolsMenu
      } else {
        findReplaceButton(showsTitle: false)
        outlineButton(showsTitle: false)
        imageInfoButton(showsTitle: false)
        Divider().frame(height: 18)
        aiActionsMenuButton(showsTitle: false)
        moreActionsMenuButton(showsTitle: false)
      }
    }
    .fixedSize(horizontal: true, vertical: false)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("写作工具栏")
    .accessibilityIdentifier("markdown-editor-toolbar")
  }

  private var writingToolsMenu: some View {
    Menu {
      findReplaceButton(showsTitle: true)
      outlineButton(showsTitle: true)
      imageInfoButton(showsTitle: true)
      Divider()
      aiActionsMenuButton(showsTitle: true)
      Divider()
      moreActionsMenuButton(showsTitle: true)
    } label: {
      Label("写作工具", systemImage: "wrench.and.screwdriver")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("写作工具")
    }
    .menuIndicator(.hidden)
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: true))
    .help("查找、大纲、AI、专注模式、导出与快捷键")
    .accessibilityLabel("写作工具")
    .accessibilityIdentifier("markdown-writing-tools-menu")
  }

  @ViewBuilder
  private func imageInfoButton(showsTitle: Bool) -> some View {
    if let onShowImageInfo = actions.onShowImageInfo {
      Button(action: onShowImageInfo) {
        editorActionLabel("图片信息", systemName: "photo", showsTitle: showsTitle)
      }
      .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
      .help("图片信息")
      .accessibilityLabel("图片信息")
      .accessibilityIdentifier("markdown-image-info-action")
    }
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

  private func moreActionsMenuButton(showsTitle: Bool) -> some View {
    Menu {
      MarkdownFocusModeToggles(isActive: $isFocusModeActive)
      MarkdownEditorComfortControl(showsTitle: true)
      Divider()
      versionHistoryButton
      exportMenuButton(showsTitle: true)
      shortcutHelpButton(showsTitle: true)
    } label: {
      editorActionLabel("更多…", systemName: "ellipsis.circle", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .help(String(localized: "更多操作：专注模式、编辑器设置、历史版本、导出、打印、分享与快捷键说明"))
    .accessibilityLabel(String(localized: "更多操作"))
    .accessibilityIdentifier("markdown-editor-more-actions-menu")
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
  func editorActionLabel(
    _ title: String,
    systemName: String,
    showsTitle: Bool
  ) -> some View {
    if showsTitle {
      Label(title, systemImage: systemName)
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    } else {
      Image(systemName: systemName)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
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

extension MacMarkdownEditorToolbar {
  func aiActionsMenuButton(showsTitle: Bool) -> some View {
    Menu {
      aiActions
    } label: {
      editorActionLabel("AI 操作", systemName: "wand.and.sparkles", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .help("AI 操作")
    .accessibilityLabel("AI 操作")
    .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")
    .accessibilityIdentifier("markdown-editor-ai-actions-menu")

  }

  private func inlineAICompletionButton(showsTitle: Bool) -> some View {
    Button {
      actions.onRequestInlineAICompletion()
    } label: {
      editorActionLabel("行内续写（⌥\\）", systemName: "text.append", showsTitle: showsTitle)
    }
    .buttonStyle(
      MarkdownEditorToolbarButtonStyle(
        showsTitle: showsTitle,
        isSelected: false
      )
    )
    .foregroundStyle(Color.secondary)
    .help(String(localized: "请求 AI 续写（Option + 反斜杠）"))
    .accessibilityLabel(String(localized: "AI 操作：续写"))
    .accessibilityValue(String(localized: "按需触发"))
    .accessibilityIdentifier("markdown-inline-ai-completion")
    .disabled(!actions.canRequestInlineAICompletion)
  }

  @ViewBuilder
  private var aiActions: some View {
    if let aiConfigurationDestination {
      Button {
        openAIConfiguration(aiConfigurationDestination)
      } label: {
        Label("去配置", systemImage: "gearshape")
      }
      .accessibilityIdentifier("markdown-ai-configure-action")
      Divider()
    }

    Section("选区") {
      convergedRewriteAction
      Menu {
        selectionAIActionButton(.translate, kind: .translateSelectionToChinese)
        selectionAIActionButton(.translate, kind: .translateSelectionToEnglish)
      } label: {
        Label(
          AIPublishingDefaultCapability.translate.localizedDisplayName,
          systemImage: AIPublishingDefaultCapability.translate.systemImage
        )
      }
      .disabled(!actions.isBodySelectionActive)
    }
    .disabled(aiConfigurationDestination != nil)

    Section("全文") {
      articleAIActionButton(.continueWriting, kind: .continueArticle)
      inlineAICompletionButton(showsTitle: true)
      convergedReviewAction
      articleAIActionButton(.citeKnowledge, kind: .draftReferencesSection)
    }
    .disabled(aiConfigurationDestination != nil)

    Section("发布") {
      articleAIActionButton(
        String(localized: "摘要"), systemImage: "text.alignleft", kind: .suggestSummary
      )
      articleAIActionButton(
        String(localized: "标题"), systemImage: "textformat", kind: .suggestTitles
      )
      articleAIActionButton(
        String(localized: "社交文案"), systemImage: "bubble.left.and.bubble.right",
        kind: .draftSocialShare
      )
      convergedPublishAssetPackAction
    }
    .disabled(aiConfigurationDestination != nil)

    Divider()

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
    let isRewriteEnabled = actions.selectionAvailability(for: .rewriteSelection).isEnabled
    return Menu {
      Section("风格") {
        ForEach(AIPublishingRewriteStyle.allCases) { style in
          Button {
            actions.onPerformConvergedSelectionAIAction(
              .rewriteSelection(AIPublishingRewriteConfiguration(style: style))
            )
          } label: {
            Label(
              style.localizedDisplayName,
              systemImage: "sparkles"
            )
          }
          .disabled(!isRewriteEnabled)
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
            Label(operation.localizedDisplayName, systemImage: operation.systemImage)
          }
          .disabled(!isRewriteEnabled)
        }
      }
    } label: {
      Label("改写", systemImage: "wand.and.sparkles")
    }
    .disabled(!isRewriteEnabled)
    .help("对选中文本执行改写、润色、扩写、压缩或简化")
    .accessibilityIdentifier("ai-converged-rewrite-menu")
  }

  private var convergedPublishAssetPackAction: some View {
    Button {
      isPublishAssetPickerPresented = true
    } label: {
      Label("发布资产包", systemImage: "shippingbox")
    }
    .help("勾选多个发布资产，一次生成完整发布包")
    .disabled(!actions.articleAIActionAvailability(.draftPublishAssetPack).isEnabled)
    .accessibilityIdentifier("ai-converged-publish-asset-pack")
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

  private func articleAIActionButton(
    _ capability: AIPublishingDefaultCapability,
    kind: AIPublishingActionKind
  ) -> some View {
    articleAIActionButton(
      capability.localizedDisplayName,
      systemImage: capability.systemImage,
      kind: kind
    )
  }

  private func articleAIActionButton(
    _ title: String,
    systemImage: String,
    kind: AIPublishingActionKind
  ) -> some View {
    let availability = actions.articleAIActionAvailability(kind)
    return Button {
      actions.onPerformArticleAIAction(kind)
    } label: {
      Label(title, systemImage: systemImage)
    }
    .disabled(!availability.isEnabled)
    .help(availability.unavailableReason ?? kind.localizedDisplayName)
  }

}
