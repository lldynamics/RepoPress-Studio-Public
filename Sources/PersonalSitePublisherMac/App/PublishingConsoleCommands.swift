import AppKit
import PublishingKnowledgeCore
import PublishingWorkbenchCore
import SwiftUI

struct PublishingConsoleCommands: Commands {
  let store: WorkbenchStore
  @ObservedObject private var presentation: WorkbenchCommandPresentationFeatureFacade
  @FocusedObject private var commandRouter: WorkspaceSceneCommandRouter?
  @Environment(\.openSettings) private var openSettings
  @Environment(\.openWindow) private var openWindow

  init(store: WorkbenchStore) {
    self.store = store
    _presentation = ObservedObject(wrappedValue: store.commandPresentation)
  }

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button(String(localized: "新建窗口")) {
        openWindow(id: "main-workbench")
      }
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Divider()

      Button(String(localized: "新建文章")) {
        if writingDraftCommands != nil {
          commandRouter?.writingDraftCommandActions?.createDraft()
        } else {
          store.createDraft()
        }
      }
      .keyboardShortcut("n")
    }

    CommandGroup(replacing: .saveItem) {
      Button(saveCommandTitle) {
        saveCurrentContent()
      }
      .keyboardShortcut("s")
      .disabled(!canSaveCurrentContent)
    }

    CommandGroup(replacing: .printItem) {
      Button(String(localized: "打印…")) {
        markdownEditorCommands?.printDocument()
      }
      .keyboardShortcut("p")
      .disabled(markdownEditorCommands == nil)
    }

    CommandGroup(after: .importExport) {
      if knowledgeLibraryCommands != nil {
        Button(String(localized: "导入资料…")) {
          commandRouter?.knowledgeLibraryCommandActions?.importSources()
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
      }

      Menu(String(localized: "站点仓库")) {
        Button(String(localized: "选择站点仓库…")) {
          chooseSiteRepository()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])

        Button(String(localized: "从站点仓库导入文章…")) {
          importArticlesFromSiteRepository()
        }

        Button(String(localized: "复制同步建议命令")) {
          copyRepositorySyncCommands()
        }
      }
    }

    CommandGroup(after: .pasteboard) {
      Menu(String(localized: "查找与搜索")) {
        findAndSearchCommands
      }
    }

    PublishingConsoleMarkdownCommands(
      store: store,
      installSoftwareGuides: { installSoftwareGuidesFromHelp() },
      exportRedactedDiagnostics: { exportRedactedDiagnostics() }
    )

    CommandGroup(replacing: .sidebar) {
      Button(
        commandRouter?.workspaceSidebarCommandAction?.title
          ?? String(localized: "显示侧栏")
      ) {
        commandRouter?.workspaceSidebarCommandAction?.toggle()
      }
      .keyboardShortcut("s", modifiers: [.command, .control])
      .disabled(
        commandRouter?.workspaceSidebarCommandAction?.canToggle != true
      )

      Divider()

      Button(
        workspaceFocusModeCommandAction?.isActive == true
          ? String(localized: "退出专注模式")
          : String(localized: "专注模式")
      ) {
        workspaceFocusModeCommandAction?.toggle()
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .disabled(workspaceFocusModeCommandAction?.canToggle != true)

      if let workspaceInspectorCommandAction {
        Button(workspaceInspectorCommandAction.title) {
          workspaceInspectorCommandAction.toggle()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(!workspaceInspectorCommandAction.canToggle)
      } else if supportsInspector {
        Button(
          presentation.isInspectorPresented
            ? String(localized: "隐藏详情栏")
            : String(localized: "显示详情栏")
        ) {
          store.setInspectorPresented(!presentation.isInspectorPresented)
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
      }
    }

    CommandMenu(String(localized: "前往")) {
      Button(
        workspaceFirstRunSetupCommandAction == nil
          ? String(localized: "首次设置…")
          : String(localized: "打开设置向导…")
      ) {
        workspaceFirstRunSetupCommandAction?.open()
      }
      .disabled(workspaceFirstRunSetupCommandAction == nil)

      Button(String(localized: "设置…")) {
        presentSettings(destination: nil)
      }

      Button(String(localized: "任务中心…")) {
        commandRouter?.showTaskCenter?()
      }
      .keyboardShortcut("l", modifiers: [.command, .option])
      .disabled(commandRouter?.showTaskCenter == nil)

      Divider()

      Button(String(localized: "命令面板与快速打开")) {
        workspaceCommandPaletteAction?.open()
      }
      .keyboardShortcut("k", modifiers: [.command, .shift])
      .disabled(workspaceCommandPaletteAction == nil)

      Menu(String(localized: "切换工作区")) {
        ForEach(WorkspaceNavigationPresentation.commandMenuItems) { item in
          Button(workspaceNavigationLocalizedKey(item.displayNameLocalizationKey)) {
            store.selectSection(item.section)
          }
          .keyboardShortcut(KeyEquivalent(item.keyboardShortcutKey), modifiers: [.command])
        }
      }

      Divider()

      Menu(String(localized: "文章导航")) {
        articleNavigationCommands
      }

      Button(workspaceNavigationLocalizedKey("workspace.maintenance")) {
        workspaceCommandPaletteAction?.openMaintenance()
      }
      .keyboardShortcut("7")
      .disabled(workspaceCommandPaletteAction == nil)
    }

    CommandMenu(String(localized: "发布")) {
      Button(String(localized: "发布所有变更…")) {
        openPublishDrawerForAllChanges(
          message: String(localized: "发布中心已打开；默认操作为发布所有变更，也可以仅发布当前文章。")
        )
      }
      .keyboardShortcut("p", modifiers: [.command, .option])
      .disabled(publishDrawerCommandAction == nil)

      Button(String(localized: "运行发布检查")) {
        runPreflightForCommandDraft()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])

      Divider()

      Menu(String(localized: "本地预览")) {
        Button(
          markdownEditorCommands == nil
            ? String(localized: "打开本地预览")
            : String(localized: "在浏览器打开当前文章")
        ) {
          openLocalPreview()
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])

        Button(String(localized: "停止本地预览")) {
          store.stopLocalSitePreview()
        }
        .disabled(!presentation.isLocalSitePreviewRunning)
      }

      Button(workspaceNavigationLocalizedKey("workspace.releaseHistory")) {
        workspaceCommandPaletteAction?.openReleaseHistory()
      }
      .keyboardShortcut("8")
      .disabled(workspaceCommandPaletteAction == nil)
    }

    CommandMenu(String(localized: "AI")) {
      Button(
        isAIChatPanelVisible
          ? String(localized: "关闭 AI 助手")
          : String(localized: "打开 AI 助手")
      ) {
        toggleAIChatWorkspaceForCommandContext()
      }
      .keyboardShortcut("a", modifiers: [.command, .option])

      Divider()

      Button(String(localized: "改写选中文本")) {
        markdownEditorCommands?.rewriteSelection()
      }
      .keyboardShortcut("r", modifiers: [.command, .option])
      .disabled(markdownEditorCommands?.canRewriteSelection != true)

      Button(String(localized: "复制上下文 Prompt")) {
        markdownEditorCommands?.copyAIPrompt()
      }
      .disabled(markdownEditorCommands == nil)
    }

  }

  private var markdownEditorCommands: MarkdownEditorCommandActions? {
    commandRouter?.markdownEditorCommandActions
  }

  private var publishDrawerCommandAction: PublishDrawerCommandAction? {
    commandRouter?.publishDrawerCommandAction
  }

  private var localSitePreviewCommandAction: LocalSitePreviewCommandAction? {
    commandRouter?.localSitePreviewCommandAction
  }

  private var writingDraftCommands: WritingDraftCommandActions? {
    commandRouter?.writingDraftCommandActions
  }

  private var workspaceCommandPaletteAction: WorkspaceCommandPaletteAction? {
    commandRouter?.workspaceCommandPaletteAction
  }

  private var draftFullTextSearchAction: DraftFullTextSearchAction? {
    commandRouter?.draftFullTextSearchAction
  }

  private var knowledgeLibraryCommands: KnowledgeLibraryCommandActions? {
    commandRouter?.knowledgeLibraryCommandActions
  }

  private var workspaceFocusModeCommandAction: WorkspaceFocusModeCommandAction? {
    commandRouter?.workspaceFocusModeCommandAction
  }

  private var workspaceInspectorCommandAction: WorkspaceInspectorCommandAction? {
    commandRouter?.workspaceInspectorCommandAction
  }

  private var workspaceFirstRunSetupCommandAction: WorkspaceFirstRunSetupCommandAction? {
    commandRouter?.workspaceFirstRunSetupCommandAction
  }

  private var settingsWorkspaceCommandAction: SettingsWorkspaceCommandAction? {
    commandRouter?.settingsWorkspaceCommandAction
  }

  private var rssReaderCommands: RSSReaderCommandActions? {
    commandRouter?.rssReaderCommandActions
  }

  private func presentSettings(destination: SettingsDestination?) {
    if let settingsWorkspaceCommandAction {
      settingsWorkspaceCommandAction.open(destination)
    } else {
      SettingsNavigation.open(destination: destination) {
        openSettings()
      }
    }
  }

  private var saveCommandTitle: String {
    String(localized: "保存工作台")
  }

  private var canSaveCurrentContent: Bool {
    true
  }

  @ViewBuilder
  private var findAndSearchCommands: some View {
    Button(searchCommandTitle) {
      if let rssReaderCommands {
        rssReaderCommands.focusSearch()
      } else if let knowledgeLibraryCommands {
        knowledgeLibraryCommands.focusSearch()
      } else if let markdownEditorCommands {
        markdownEditorCommands.showFindReplace()
      } else {
        writingDraftCommands?.focusSearch()
      }
    }
    .keyboardShortcut("f")
    .disabled(
      knowledgeLibraryCommands == nil
        && markdownEditorCommands == nil
        && writingDraftCommands == nil
        && rssReaderCommands == nil
    )

    Button(String(localized: "搜索文章")) {
      draftFullTextSearchAction?.open()
    }
    .keyboardShortcut("f", modifiers: [.command, .option])
    .disabled(draftFullTextSearchAction == nil)

    Button(String(localized: "搜索草稿列表")) {
      writingDraftCommands?.focusSearch()
    }
    .disabled(writingDraftCommands == nil)

    Divider()

    Button(String(localized: "查找下一个")) {
      markdownEditorCommands?.findNext()
    }
    .keyboardShortcut("g")
    .disabled(
      markdownEditorCommands?.canUseFindReplace != true
    )

    Button(String(localized: "查找上一个")) {
      markdownEditorCommands?.findPrevious()
    }
    .keyboardShortcut("g", modifiers: [.command, .shift])
    .disabled(
      markdownEditorCommands?.canUseFindReplace != true
    )

    Button(String(localized: "替换当前匹配")) {
      markdownEditorCommands?.replaceCurrentOrNext()
    }
    .disabled(markdownEditorCommands?.canUseFindReplace != true)

    Button(String(localized: "全部替换")) {
      markdownEditorCommands?.replaceAll()
    }
    .keyboardShortcut("e", modifiers: [.command, .option])
    .disabled(markdownEditorCommands?.canUseFindReplace != true)
  }

  @ViewBuilder
  private var articleNavigationCommands: some View {
    if let rssReaderCommands {
      Button(String(localized: "上一条 RSS 文章")) {
        commandRouter?.rssReaderCommandActions?.navigatePrevious()
      }
      .keyboardShortcut(.leftArrow, modifiers: [.command, .control])
      .disabled(!rssReaderCommands.canNavigatePrevious)

      Button(String(localized: "下一条 RSS 文章")) {
        commandRouter?.rssReaderCommandActions?.navigateNext()
      }
      .keyboardShortcut(.rightArrow, modifiers: [.command, .control])
      .disabled(!rssReaderCommands.canNavigateNext)

      Divider()

      Button(String(localized: "收藏/取消收藏 RSS 文章")) {
        commandRouter?.rssReaderCommandActions?.toggleStarred()
      }
      .keyboardShortcut("b", modifiers: [.command, .control])
      .disabled(!rssReaderCommands.canActOnArticle)

      Button(String(localized: "标记 RSS 文章已读/未读")) {
        commandRouter?.rssReaderCommandActions?.toggleRead()
      }
      .keyboardShortcut("u", modifiers: [.command, .control])
      .disabled(!rssReaderCommands.canActOnArticle)

      Button(String(localized: "打开 RSS 原文")) {
        commandRouter?.rssReaderCommandActions?.openOriginal()
      }
      .keyboardShortcut("o", modifiers: [.command, .control])
      .disabled(!rssReaderCommands.canActOnArticle)

      Button(String(localized: "高亮所选 RSS 文本")) {
        commandRouter?.rssReaderCommandActions?.createHighlight()
      }
      .keyboardShortcut("h", modifiers: [.command, .control])
      .disabled(!rssReaderCommands.canActOnArticle)

      Button(String(localized: "为 RSS 高亮添加批注")) {
        commandRouter?.rssReaderCommandActions?.addNote()
      }
      .keyboardShortcut("n", modifiers: [.command, .control])
      .disabled(!rssReaderCommands.canActOnArticle)

      Button(String(localized: "编辑 RSS 文章标签")) {
        commandRouter?.rssReaderCommandActions?.editTags()
      }
      .keyboardShortcut("t", modifiers: [.command, .control])
      .disabled(!rssReaderCommands.canActOnArticle)

      Divider()
    }

    Button(String(localized: "文章版本历史")) {
      writingDraftCommands?.openVersionHistory()
    }
    .disabled(writingDraftCommands == nil || commandDraftID == nil)

    Divider()

    Button(String(localized: "文章后退")) {
      navigateDraftHistoryBackward()
    }
    .keyboardShortcut("[", modifiers: [.command])
    .disabled(!presentation.canNavigateBackwardInDraftHistory)

    Button(String(localized: "文章前进")) {
      navigateDraftHistoryForward()
    }
    .keyboardShortcut("]", modifiers: [.command])
    .disabled(!presentation.canNavigateForwardInDraftHistory)

    if knowledgeLibraryCommands != nil || writingDraftCommands != nil {
      Divider()

      Button(
        knowledgeLibraryCommands == nil
          ? String(localized: "上一个草稿")
          : String(localized: "上一条资料")
      ) {
        if let knowledgeLibraryCommands {
          knowledgeLibraryCommands.selectPreviousDocument()
        } else {
          writingDraftCommands?.selectPreviousDraft()
        }
      }
      .keyboardShortcut(.upArrow, modifiers: [.command, .option])

      Button(
        knowledgeLibraryCommands == nil
          ? String(localized: "下一个草稿")
          : String(localized: "下一条资料")
      ) {
        if let knowledgeLibraryCommands {
          knowledgeLibraryCommands.selectNextDocument()
        } else {
          writingDraftCommands?.selectNextDraft()
        }
      }
      .keyboardShortcut(.downArrow, modifiers: [.command, .option])
    }
  }

  private var searchCommandTitle: String {
    if rssReaderCommands != nil { return String(localized: "搜索 RSS 文章") }
    if knowledgeLibraryCommands != nil { return String(localized: "搜索资料库") }
    return markdownEditorCommands == nil
      ? String(localized: "搜索草稿")
      : String(localized: "查找/替换当前文章")
  }

  private var commandDraftID: UUID? {
    return markdownEditorCommands?.draftID ?? presentation.selectedDraftID
  }

  private var supportsInspector: Bool {
    WorkspaceInspectorPresentation.supportsInspector(for: presentation.selectedSection)
  }

  private func saveCurrentContent() {
    store.save()
  }

  private func chooseSiteRepository() {
    store.selectSection(.sync)
    Task {
      guard let url = await RepositorySelectionPanel.chooseDirectory() else { return }
      await store.repository.rememberRootAsync(url)
    }
  }

  private func importArticlesFromSiteRepository() {
    store.selectSection(.sync)
    Task {
      await store.importDraftsFromLocalRepositoryAsync()
    }
  }

  private func openLocalPreview() {
    if let markdownEditorCommands {
      markdownEditorCommands.openExternalBrowserPreview()
      return
    }
    if let localSitePreviewCommandAction {
      localSitePreviewCommandAction.open()
      return
    }
    store.selectSection(.sync)
    store.startLocalSitePreview()
  }

  private func installSoftwareGuidesFromHelp() {
    let addedCount = store.installSoftwareGuides()
    let message =
      addedCount == 0
      ? String(localized: "使用指南已经全部存在。")
      : String(localized: "已添加缺少的使用指南，工作台正在保存。")
    EditorAccessibilityAnnouncementCenter.announce(message, priority: .high)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = message
    alert.addButton(withTitle: String(localized: "关闭"))
    Task { _ = await WindowSheetPresenter.response(to: alert) }
  }

  private func exportRedactedDiagnostics() {
    Task {
      guard let directoryURL = await WorkbenchDiagnosticsSelectionPanel.chooseExportDirectory()
      else { return }
      do {
        let archiveURL = try store.exportRedactedDiagnostics(
          to: directoryURL,
          appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String
            ?? "unknown",
          buildVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "unknown"
        )
        NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "脱敏诊断包已导出")
        alert.informativeText = archiveURL.lastPathComponent
        alert.addButton(withTitle: String(localized: "关闭"))
        _ = await WindowSheetPresenter.response(to: alert)
      } catch {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "导出脱敏诊断包失败")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "关闭"))
        _ = await WindowSheetPresenter.response(to: alert)
      }
    }
  }

  private func navigateDraftHistoryBackward() {
    guard store.navigateBackwardInDraftHistory(), let draft = store.selectedDraft else { return }
    EditorAccessibilityAnnouncementCenter.announce(
      String(localized: "已返回文章：\(draft.title)"),
      priority: .high
    )
  }

  private func navigateDraftHistoryForward() {
    guard store.navigateForwardInDraftHistory(), let draft = store.selectedDraft else { return }
    EditorAccessibilityAnnouncementCenter.announce(
      String(localized: "已前进到文章：\(draft.title)"),
      priority: .high
    )
  }

  private func runPreflightForCommandDraft() {
    if let markdownEditorCommands {
      markdownEditorCommands.runPreflight()
      return
    }

    store.runPreflight()
    store.selectSection(.contentHealth)
  }

  private func openAIChatWorkspaceForCommandContext() {
    store.ai.openChatWorkspace(for: commandDraftID)
  }

  private var isAIChatPanelVisible: Bool {
    presentation.isAIAssistantPresented && presentation.isInspectorPresented
  }

  private func toggleAIChatWorkspaceForCommandContext() {
    if isAIChatPanelVisible {
      store.ai.closeAssistantPanel()
    } else {
      openAIChatWorkspaceForCommandContext()
    }
  }

  private func openPublishDrawerForAllChanges(message: String) {
    if let publishDrawerCommandAction {
      publishDrawerCommandAction.open(message)
    }
  }

  private func copyRepositorySyncCommands() {
    guard let plan = store.repositorySyncCommandPlan else {
      store.setPublishActionMessage(
        String(localized: "选择本地仓库后才能生成同步建议命令。"),
        status: .warning
      )
      return
    }
    copyToPasteboard(plan.commandText, successMessage: String(localized: "已复制同步建议命令。"))
  }

  private func copyToPasteboard(_ value: String, successMessage: String) {
    ClipboardWriter.copy(value, successMessage: successMessage) { message, status in
      store.setPublishActionMessage(message, status: status)
    }
  }
}

/// Kept in its own Commands value so the main scene command builder stays
/// within SwiftUI's top-level command count limit.
struct PublishingConsoleMarkdownCommands: Commands {
  let store: WorkbenchStore
  let installSoftwareGuides: () -> Void
  let exportRedactedDiagnostics: () -> Void
  @ObservedObject private var presentation: WorkbenchCommandPresentationFeatureFacade
  @FocusedObject private var commandRouter: WorkspaceSceneCommandRouter?

  init(
    store: WorkbenchStore,
    installSoftwareGuides: @escaping () -> Void,
    exportRedactedDiagnostics: @escaping () -> Void
  ) {
    self.store = store
    self.installSoftwareGuides = installSoftwareGuides
    self.exportRedactedDiagnostics = exportRedactedDiagnostics
    _presentation = ObservedObject(wrappedValue: store.commandPresentation)
  }

  var body: some Commands {
    CommandMenu(String(localized: "格式")) {
      markdownEditingCommands
        .disabled(markdownEditorCommands == nil)
    }

    CommandGroup(after: .help) {
      Button(String(localized: "查看快捷键说明")) {
        if let showShortcutHelp = commandRouter?.showShortcutHelp {
          showShortcutHelp()
        } else {
          markdownEditorCommands?.showKeyboardShortcuts()
        }
      }
      .keyboardShortcut("/", modifiers: [.command, .option])
      .disabled(commandRouter?.showShortcutHelp == nil && markdownEditorCommands == nil)

      Divider()

      Button(String(localized: "添加软件使用指南")) {
        installSoftwareGuides()
      }

      Button(String(localized: "导出脱敏诊断包…")) {
        exportRedactedDiagnostics()
      }
    }
  }

  private var markdownEditorCommands: MarkdownEditorCommandActions? {
    commandRouter?.markdownEditorCommandActions
  }

  @ViewBuilder
  private var markdownEditingCommands: some View {
    Button(String(localized: "Markdown 加粗")) {
      markdownEditorCommands?.applyFormatting(.bold)
    }
    .keyboardShortcut("b", modifiers: [.command])

    Button(String(localized: "Markdown 斜体")) {
      markdownEditorCommands?.applyFormatting(.italic)
    }
    .keyboardShortcut("i", modifiers: [.command])

    Button(String(localized: "插入 Markdown 链接")) {
      markdownEditorCommands?.applyFormatting(.link)
    }
    .keyboardShortcut("k", modifiers: [.command])

    Menu(String(localized: "Markdown 标题")) {
      Button(String(localized: "一级标题")) {
        markdownEditorCommands?.applyFormatting(.heading(level: 1))
      }
      .keyboardShortcut("1", modifiers: [.command, .option])

      Button(String(localized: "二级标题")) {
        markdownEditorCommands?.applyFormatting(.heading(level: 2))
      }
      .keyboardShortcut("2", modifiers: [.command, .option])

      Button(String(localized: "三级标题")) {
        markdownEditorCommands?.applyFormatting(.heading(level: 3))
      }
      .keyboardShortcut("3", modifiers: [.command, .option])
    }

    Divider()

    Button(String(localized: "插入图片到当前文章")) {
      markdownEditorCommands?.insertImages()
    }
    .keyboardShortcut("i", modifiers: [.command, .shift])

    Button(String(localized: "模板与片段")) {
      markdownEditorCommands?.showSnippets()
    }
    .keyboardShortcut("s", modifiers: [.command, .option])
  }
}

struct PublishingConsoleSettingsCommands: Commands {
  @Environment(\.openSettings) private var openSettings

  var body: some Commands {
    // ⌘, follows the macOS convention and always opens the Settings window;
    // site configuration is reached from the site menu in the main window.
    CommandGroup(replacing: .appSettings) {
      Button(String(localized: "设置…")) {
        SettingsNavigation.open(destination: nil) {
          openSettings()
        }
      }
      .keyboardShortcut(",", modifiers: [.command])
    }
  }
}
