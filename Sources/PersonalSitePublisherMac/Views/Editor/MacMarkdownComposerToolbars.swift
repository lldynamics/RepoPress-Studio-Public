import PublishingWorkbenchCore
import SwiftUI

enum MarkdownEditorToolbarLayoutVariant: Equatable {
  case full
  case medium
  case compact
}

enum MarkdownEditorToolbarLayoutPlanner {
  private static let controlWidth: CGFloat = 30
  private static let itemSpacing: CGFloat = 5
  private static let groupDividerWidth: CGFloat = 11

  static func variant(
    availableWidth: CGFloat,
    fullItemIDs: [MarkdownToolbarItemID],
    mediumItemIDs: [MarkdownToolbarItemID],
    compactItemIDs: [MarkdownToolbarItemID]
  ) -> MarkdownEditorToolbarLayoutVariant {
    if availableWidth >= requiredWidth(for: fullItemIDs, showsOverflow: false) {
      return .full
    }
    if availableWidth >= requiredWidth(for: mediumItemIDs, showsOverflow: true) {
      return .medium
    }
    return .compact
  }

  static func requiredWidth(
    for itemIDs: [MarkdownToolbarItemID],
    showsOverflow: Bool
  ) -> CGFloat {
    let itemCount = itemIDs.count + (showsOverflow ? 1 : 0)
    guard itemCount > 0 else { return 0 }
    let containsGroupDivider = itemIDs.contains(where: \.isAIGroupItem)
    let dividerCount = containsGroupDivider ? 1 : 0
    let childCount = itemCount + dividerCount
    return CGFloat(itemCount) * controlWidth
      + CGFloat(max(0, childCount - 1)) * itemSpacing
      + CGFloat(dividerCount) * groupDividerWidth
  }
}

/// The workspace toolbar already owns navigation to AI chat, preview, and
/// publication. Keep the article toolbar focused on writing actions while
/// preserving its direct, high-frequency AI utilities.
enum MarkdownArticleToolbarScope {
  private static let workspaceOwnedItems: Set<MarkdownToolbarItemID> = [
    .aiChat,
    .localPreview,
    .preparePublish,
  ]

  static func articleItemIDs(from itemIDs: [MarkdownToolbarItemID]) -> [MarkdownToolbarItemID] {
    itemIDs.filter { !workspaceOwnedItems.contains($0) }
  }

  static func isWorkspaceOwned(_ item: MarkdownToolbarItemID) -> Bool {
    workspaceOwnedItems.contains(item)
  }
}

struct MacMarkdownEditorToolbar: View {
  @Binding var title: String
  let store: WorkbenchStore
  let draftID: UUID
  let markdownPath: String
  let isSelectionAIActionRunning: Bool
  let canOpenAIChat: Bool
  let aiChatUnavailableReason: String?
  @ObservedObject var externalBrowserPreviewCoordinator: ExternalBrowserPreviewCoordinator
  let writingToolDensity: MarkdownWritingToolDensity
  let availableWritingContextPanels: [MarkdownWritingContextPanel]
  let actions: MarkdownEditorToolbarActions
  @EnvironmentObject private var zenModeController: ZenModeController
  @State private var selectedPublishAssets = AIPublishingAssetKind.defaultSelection
  @AppStorage("workspace.customToolbarConfig") private var customToolbarConfigRawValue = ""
  @State private var isCustomizationSheetPresented = false

  // Keep the chat symbol in one place. The previous multi-bubble sparkle
  // symbol is not available in the macOS 14 SF Symbols set.
  private static let aiChatSystemImage = "bubble.left"

  private var currentToolbarConfig: MarkdownToolbarConfiguration {
    MarkdownToolbarConfiguration.decodeFromJSON(customToolbarConfigRawValue)
  }

  private var toolbarConfiguration: Binding<MarkdownToolbarConfiguration> {
    Binding(
      get: {
        currentToolbarConfig
      },
      set: { newConfig in
        customToolbarConfigRawValue = newConfig.normalized.encodeToJSON()
      }
    )
  }

  init(
    title: Binding<String>,
    store: WorkbenchStore,
    draftID: UUID,
    markdownPath: String,
    isSelectionAIActionRunning: Bool,
    canOpenAIChat: Bool,
    aiChatUnavailableReason: String?,
    externalBrowserPreviewCoordinator: ExternalBrowserPreviewCoordinator,
    writingToolDensity: MarkdownWritingToolDensity,
    availableWritingContextPanels: [MarkdownWritingContextPanel],
    actions: MarkdownEditorToolbarActions
  ) {
    _title = title
    self.store = store
    self.draftID = draftID
    self.markdownPath = markdownPath
    self.isSelectionAIActionRunning = isSelectionAIActionRunning
    self.canOpenAIChat = canOpenAIChat
    self.aiChatUnavailableReason = aiChatUnavailableReason
    _externalBrowserPreviewCoordinator = ObservedObject(
      wrappedValue: externalBrowserPreviewCoordinator
    )
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
      store: store,
      draftID: draftID,
      markdownPath: markdownPath
    )
  }

  private var enabledHeaderItemIDs: [MarkdownToolbarItemID] {
    MarkdownArticleToolbarScope.articleItemIDs(from: currentToolbarConfig.headerItemIDs)
  }

  /// 中度折叠时保留的项目：取 collapseOrder 小于等于阈值的所有已启用项。
  private var mediumHeaderItemIDs: [MarkdownToolbarItemID] {
    enabledHeaderItemIDs.filter { $0.collapseOrder <= 6 }
  }

  /// 紧凑折叠时保留的项目：取 collapseOrder 小于等于阈值的所有已启用项。
  private var compactHeaderItemIDs: [MarkdownToolbarItemID] {
    enabledHeaderItemIDs.filter { $0.collapseOrder <= 3 }
  }

  private var configuredIconToolbarControls: some View {
    GeometryReader { geometry in
      let variant = MarkdownEditorToolbarLayoutPlanner.variant(
        availableWidth: geometry.size.width,
        fullItemIDs: enabledHeaderItemIDs,
        mediumItemIDs: mediumHeaderItemIDs,
        compactItemIDs: compactHeaderItemIDs
      )
      Group {
        switch variant {
        case .full:
          toolbarItemRow(ids: enabledHeaderItemIDs, showsOverflow: false)
        case .medium:
          toolbarItemRow(
            ids: mediumHeaderItemIDs,
            showsOverflow: true,
            reservedIDs: mediumHeaderItemIDs
          )
        case .compact:
          toolbarItemRow(
            ids: compactHeaderItemIDs,
            showsOverflow: true,
            reservedIDs: compactHeaderItemIDs
          )
        }
      }
      .frame(
        maxWidth: .infinity,
        maxHeight: .infinity,
        alignment: .trailing
      )
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .frame(minHeight: 34, idealHeight: 34, maxHeight: 34)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("写作工具栏")
    .accessibilityIdentifier("markdown-editor-toolbar")
  }

  /// 渲染一行工具栏按钮，在文档工具组和 AI 工具组之间自动插入分隔线。
  @ViewBuilder
  private func toolbarItemRow(
    ids: [MarkdownToolbarItemID],
    showsOverflow: Bool,
    reservedIDs: [MarkdownToolbarItemID] = []
  ) -> some View {
    HStack(spacing: 5) {
      ForEach(ids) { item in
        // 在 AI 工具组第一项之前插入分隔线
        if item == ids.first(where: \.isAIGroupItem) {
          Divider().frame(height: 18)
        }
        headerItem(item, showsTitle: false)
      }
      if showsOverflow {
        overflowMenu(reservedIDs: reservedIDs)
      }
    }
  }

  @ViewBuilder
  private func headerItem(_ item: MarkdownToolbarItemID, showsTitle: Bool) -> some View {
    switch item {
    case .saveStatus:
      MacMarkdownEditorSaveStatusIcon(store: store, draftID: draftID)
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
      inlineAICompletionButton(showsTitle: showsTitle)
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

  private func inlineAICompletionButton(showsTitle: Bool) -> some View {
    Button {
      actions.onRequestInlineAICompletion()
    } label: {
      editorActionLabel("AI 续写", systemName: "wand.and.stars", showsTitle: showsTitle)
    }
    .buttonStyle(
      MarkdownEditorToolbarButtonStyle(
        showsTitle: showsTitle,
        isSelected: false
      )
    )
    .foregroundStyle(Color.secondary)
    .help(String(localized: "请求 AI 续写（Option + 反斜杠）"))
    .accessibilityLabel(String(localized: "AI 续写"))
    .accessibilityValue(String(localized: "按需触发"))
    .accessibilityIdentifier("markdown-inline-ai-completion")
  }

  private func aiChatButton(showsTitle: Bool) -> some View {
    Button {
      actions.onOpenAIContextInspector()
    } label: {
      if isSelectionAIActionRunning {
        if showsTitle {
          Label("AI 对话", systemImage: "hourglass")
        } else {
          Image(systemName: "hourglass")
            .accessibilityHidden(true)
        }
      } else {
        editorActionLabel("AI 对话", systemName: Self.aiChatSystemImage, showsTitle: showsTitle)
      }
    }
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .foregroundStyle(Color.accentColor)
    .disabled(!canOpenAIChat)
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
    MacMarkdownExternalBrowserPreviewControl(
      store: store,
      draftID: draftID,
      showsTitle: showsTitle,
      coordinator: externalBrowserPreviewCoordinator
    )
  }

  @ViewBuilder
  private func preparePublishButton(showsTitle: Bool) -> some View {
    Button {
      actions.onPreparePublish()
    } label: {
      editorActionLabel("准备发布", systemName: "paperplane", showsTitle: showsTitle)
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
      editorActionLabel("复制到公众号/知乎", systemName: "doc.on.doc.fill", showsTitle: showsTitle)
    }
    .buttonStyle(MarkdownEditorToolbarButtonStyle(showsTitle: showsTitle))
    .help("将当前文章以精美内联样式复制为富文本（适配微信公众号、知乎后台）")
    .accessibilityLabel("复制到公众号/知乎富文本")
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
    let isRewriteEnabled = actions.selectionAIActionAvailability(.rewriteSelection).isEnabled
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
              systemImage: style == .balanced ? "wand.and.stars" : "textformat"
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

/// Keeps persistence-state invalidation inside the title area instead of
/// rebuilding and remeasuring the complete adaptive toolbar.
private struct MacMarkdownEditorTitleArea: View {
  @Binding var title: String
  let draftID: UUID
  let markdownPath: String
  @StateObject private var saveStatus: WorkbenchMarkdownEditorSaveStatusFeatureFacade
  @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

  init(
    title: Binding<String>,
    store: WorkbenchStore,
    draftID: UUID,
    markdownPath: String
  ) {
    _title = title
    self.draftID = draftID
    self.markdownPath = markdownPath
    _saveStatus = StateObject(
      wrappedValue: WorkbenchMarkdownEditorSaveStatusFeatureFacade(
        store: store,
        draftID: draftID
      )
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      TextField(
        text: $title,
        prompt: Text("未命名文章").italic().foregroundColor(.secondary)
      ) {
        EmptyView()
      }
      .textFieldStyle(.plain)
      .font(.headline)
      .foregroundStyle(saveStatus.hasUnsavedChanges ? WorkbenchTheme.warning : Color.primary)
      .accessibilityLabel("文章标题")
      .accessibilityValue(title.nilIfEmpty ?? String(localized: "未命名文章"))
      .animation(
        WorkbenchMotion.animation(
          for: .statusChange,
          reduceMotion: accessibilityReduceMotion
        ),
        value: saveStatus.hasUnsavedChanges
      )
      .lineLimit(1)
      .help(title.nilIfEmpty ?? String(localized: "未命名文章"))

      InteractiveBreadcrumbView(
        markdownPath: markdownPath,
        fileURL: nil
      )

      if let failure = saveStatus.saveFailure {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Label(
            failure.scope == .project ? String(localized: "项目保存失败") : String(localized: "保存到软件失败"),
            systemImage: "exclamationmark.triangle.fill"
          )
          .font(.caption.weight(.semibold))
          .foregroundStyle(WorkbenchTheme.warning)

          Text(failure.message)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .help(failure.message)

          if failure.canRetry {
            Button("重试") {
              saveStatus.retrySave()
            }
            .controlSize(.small)
          }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("markdown-editor-save-failure")
      }
    }
    .frame(minWidth: 220, idealWidth: 320, maxWidth: 460, alignment: .leading)
    .onChange(of: draftID) { _, updatedDraftID in
      saveStatus.trackDraft(updatedDraftID)
    }
  }
}

/// The status symbol has a fixed footprint, so save transitions repaint only
/// this leaf and cannot invalidate `ViewThatFits` toolbar measurement.
private struct MacMarkdownEditorSaveStatusIcon: View {
  let draftID: UUID
  @StateObject private var saveStatus: WorkbenchMarkdownEditorSaveStatusFeatureFacade
  @State private var completionTrigger = 0

  init(store: WorkbenchStore, draftID: UUID) {
    self.draftID = draftID
    _saveStatus = StateObject(
      wrappedValue: WorkbenchMarkdownEditorSaveStatusFeatureFacade(
        store: store,
        draftID: draftID
      )
    )
  }

  var body: some View {
    Group {
      if saveStatus.hasUnsavedChanges {
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
    .frame(width: 18, height: 30)
    .workbenchTaskCompletionSymbolEffect(trigger: completionTrigger)
    .help(saveStatus.lastSaveStatus)
    .accessibilityLabel("保存状态")
    .accessibilityValue(saveStatus.lastSaveStatus)
    .onChange(of: draftID) { _, updatedDraftID in
      saveStatus.trackDraft(updatedDraftID)
    }
    .onChange(of: saveStatus.saveCompletionRevision) { _, _ in
      completionTrigger &+= 1
    }
  }
}

struct MarkdownEditorToolbarButtonStyle: ButtonStyle {
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
