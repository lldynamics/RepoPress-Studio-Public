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
  @State private var selectedPublishAssets = AIPublishingAssetKind.defaultSelection
  @State private var isPublishAssetPickerPresented = false

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
    VStack(alignment: .leading, spacing: 10) {
      titleArea
      editingTools
    }
    .padding(.horizontal, WorkbenchSpacing.section)
    .padding(.vertical, 9)
    .background(.bar)
    .popover(isPresented: $isPublishAssetPickerPresented) {
      MacMarkdownPublishAssetPickerPopover(
        selectedAssets: $selectedPublishAssets,
        isGenerationEnabled: actions.articleAIActionAvailability(.draftPublishAssetPack).isEnabled,
        onGenerate: {
          actions.onPerformConvergedArticleAIAction(
            .publishAssetPack(AIPublishingAssetPackConfiguration(assets: selectedPublishAssets))
          )
          isPublishAssetPickerPresented = false
        }
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
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func editingToolsRow(
    formattingLayout: MarkdownFormattingToolbarLayout,
    collapsesWritingTools: Bool
  ) -> some View {
    HStack(spacing: 8) {
      formattingToolbar.withLayout(formattingLayout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
      writingTools(isCollapsed: collapsesWritingTools)
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

  private func aiActionsMenuButton(showsTitle: Bool) -> some View {
    Menu {
      aiActions
    } label: {
      editorActionLabel("AI 操作", systemName: "sparkles", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .help("AI 操作")
    .accessibilityLabel("AI 操作")
    .accessibilityValue(isSelectionAIActionRunning ? "AI 处理中" : "")

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
  }

  private func moreActionsMenuButton(showsTitle: Bool) -> some View {
    Menu {
      MarkdownFocusModeToggles(isActive: $isFocusModeActive)
      MarkdownEditorComfortControl(showsTitle: true)
      Divider()
      exportMenuButton(showsTitle: true)
      shortcutHelpButton(showsTitle: true)
    } label: {
      editorActionLabel("更多…", systemName: "ellipsis.circle", showsTitle: showsTitle)
    }
    .menuIndicator(.hidden)
    .help(String(localized: "更多操作：专注模式、编辑器设置、导出、打印、分享与快捷键说明"))
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
  private var aiActions: some View {
    articleAIActionButton(.continueWriting, kind: .continueArticle)
    inlineAICompletionButton(showsTitle: true)
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
      Label("AI 操作", systemImage: "sparkles")
    }
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

private struct MacMarkdownPublishAssetPickerPopover: View {
  @Binding var selectedAssets: Set<AIPublishingAssetKind>
  let isGenerationEnabled: Bool
  let onGenerate: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("选择发布资产")
          .font(.headline)
        Text("勾选后一次生成所选资产。")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(AIPublishingAssetKind.allCases) { asset in
            Toggle(asset.localizedDisplayName, isOn: selectionBinding(for: asset))
          }
        }
      }
      .frame(maxHeight: 280)

      HStack {
        Text("已选择 \(selectedAssets.count) 项")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("生成所选资产") {
          onGenerate()
        }
        .workbenchProminentActionStyle()
        .disabled(selectedAssets.isEmpty || !isGenerationEnabled)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(16)
    .frame(width: 320, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("选择发布资产")
    .accessibilityIdentifier("ai-publish-asset-picker")
  }

  private func selectionBinding(for asset: AIPublishingAssetKind) -> Binding<Bool> {
    Binding(
      get: { selectedAssets.contains(asset) },
      set: { isSelected in
        if isSelected {
          selectedAssets.insert(asset)
        } else {
          selectedAssets.remove(asset)
        }
      }
    )
  }
}

/// Keeps persistence-state invalidation inside the title area instead of
/// rebuilding and remeasuring the complete adaptive toolbar.
private struct MacMarkdownEditorTitleArea: View {
  @Binding var title: String
  let focusRequestID: UUID?
  let draftID: UUID
  let markdownPath: String
  let articleInformationToggle: MacMarkdownArticleInformationToggle?
  @StateObject private var saveStatus: WorkbenchMarkdownEditorSaveStatusFeatureFacade

  @FocusState private var isTitleFocused: Bool

  init(
    title: Binding<String>,
    focusRequestID: UUID?,
    store: WorkbenchStore,
    draftID: UUID,
    markdownPath: String,
    articleInformationToggle: MacMarkdownArticleInformationToggle?
  ) {
    _title = title
    self.focusRequestID = focusRequestID
    self.draftID = draftID
    self.markdownPath = markdownPath
    self.articleInformationToggle = articleInformationToggle
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
        "文章标题",
        text: Binding(
          get: { title },
          set: { value in
            // The field may wrap visually, while article metadata remains a single title.
            title = value.replacingOccurrences(of: "\r\n", with: " ")
              .replacingOccurrences(of: "\n", with: " ")
              .replacingOccurrences(of: "\r", with: " ")
          }
        ),
        prompt: Text("未命名文章").italic().foregroundColor(.secondary),
        axis: .vertical
      )
      .textFieldStyle(.plain)
      .labelsHidden()
      .focused($isTitleFocused)
      .onChange(of: focusRequestID) { _, requestID in
        if requestID != nil { isTitleFocused = true }
      }
      .font(.title2.weight(.semibold))
      // Unsaved state is shown by the save-status control; recoloring the
      // title duplicated it and made the heading flicker while typing.
      .accessibilityLabel("文章标题")
      .accessibilityValue(title.nilIfEmpty ?? String(localized: "未命名文章"))
      .lineLimit(1...3)
      .help(title.nilIfEmpty ?? String(localized: "未命名文章"))

      HStack(spacing: 10) {
        InteractiveBreadcrumbView(
          markdownPath: markdownPath,
          fileURL: nil
        )
        if let articleInformationToggle {
          articleInformationToggle
            .fixedSize()
        }
      }

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
    .frame(maxWidth: .infinity, alignment: .leading)
    .onChange(of: draftID) { _, updatedDraftID in
      saveStatus.trackDraft(updatedDraftID)
    }
  }
}
