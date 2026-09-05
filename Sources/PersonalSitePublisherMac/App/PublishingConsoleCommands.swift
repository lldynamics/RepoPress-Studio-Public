import AppKit
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
      .disabled(!canUseProtectedWorkbench)
    }

    CommandGroup(replacing: .saveItem) {
      Button(saveCommandTitle) {
        saveCurrentContent()
      }
      .keyboardShortcut("s")
      .disabled(!canSaveCurrentContent)

      if repositorySourceEditorCommands != nil {
        Button(String(localized: "重新载入 HTML 源文件")) {
          commandRouter?.repositorySourceEditorCommandActions?.reload()
        }
        .disabled(
          !canUseProtectedWorkbench
            || commandRouter?.repositorySourceEditorCommandActions?.hasDocument != true
        )
      }
    }

    CommandGroup(replacing: .printItem) {}

    CommandGroup(after: .importExport) {
      if knowledgeLibraryCommands != nil {
        Button(String(localized: "导入资料…")) {
          commandRouter?.knowledgeLibraryCommandActions?.importSources()
        }
        .keyboardShortcut("i", modifiers: [.command, .shift])
        .disabled(!canUseProtectedWorkbench)
      }

      Menu(String(localized: "站点仓库")) {
        Button(String(localized: "选择站点仓库…")) {
          chooseSiteRepository()
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(!canUseProtectedWorkbench)

        Button(String(localized: "从站点仓库导入文章…")) {
          importArticlesFromSiteRepository()
        }
        .disabled(!canUseProtectedWorkbench)

        Button(String(localized: "复制同步建议命令")) {
          copyRepositorySyncCommands()
        }
        .disabled(!canUseProtectedWorkbench)
      }
    }

    CommandGroup(after: .pasteboard) {
      Menu(String(localized: "查找与搜索")) {
        findAndSearchCommands
      }

      Menu(String(localized: "Markdown 编辑")) {
        markdownEditingCommands
      }
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)
    }

    CommandGroup(after: .sidebar) {
      Button(
        workspaceFocusModeCommandAction?.isActive == true
          ? String(localized: "退出禅意专注")
          : String(localized: "禅意专注写作")
      ) {
        workspaceFocusModeCommandAction?.toggle()
      }
      .keyboardShortcut("f", modifiers: [.command, .shift])
      .disabled(
        !canUseProtectedWorkbench
          || workspaceFocusModeCommandAction?.canToggle != true
      )

      if let workspaceInspectorCommandAction {
        Button(workspaceInspectorCommandAction.title) {
          workspaceInspectorCommandAction.toggle()
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(!canUseProtectedWorkbench || !workspaceInspectorCommandAction.canToggle)
      } else if supportsInspector {
        Button(
          presentation.isInspectorPresented
            ? String(localized: "隐藏 Inspector")
            : String(localized: "显示 Inspector")
        ) {
          store.setInspectorPresented(!presentation.isInspectorPresented)
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(!canUseProtectedWorkbench)
      }

      Divider()

      Button(
        presentation.isQuickHideActive
          ? String(localized: "返回工作台")
          : String(localized: "快速隐藏")
      ) {
        if presentation.isQuickHideActive {
          store.deactivateQuickHide()
        } else {
          store.activateQuickHide(reason: "已手动快速隐藏工作台内容。")
        }
      }
      .keyboardShortcut("l", modifiers: [.command, .control])
    }

    CommandMenu(String(localized: "前往")) {
      Button(
        workspaceFirstRunSetupCommandAction == nil
          ? String(localized: "首次设置…")
          : String(localized: "打开设置向导…")
      ) {
        workspaceFirstRunSetupCommandAction?.open()
      }
      .disabled(!canUseProtectedWorkbench || workspaceFirstRunSetupCommandAction == nil)

      Button(String(localized: "设置…")) {
        presentSettings(destination: nil)
      }
      .disabled(!canUseProtectedWorkbench && settingsWorkspaceCommandAction != nil)

      Button(String(localized: "活动记录…")) {
        openWindow(id: "operation-log")
      }
      .keyboardShortcut("l", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench)

      Divider()

      Button(String(localized: "命令面板与快速打开")) {
        workspaceCommandPaletteAction?.open()
      }
      .keyboardShortcut("p")
      .disabled(!canUseProtectedWorkbench || workspaceCommandPaletteAction == nil)

      Menu(String(localized: "切换工作区")) {
        ForEach(WorkspaceNavigationPresentation.commandMenuItems) { item in
          Button(workspaceNavigationLocalizedKey(item.displayNameLocalizationKey)) {
            store.selectSection(item.section)
          }
          .keyboardShortcut(KeyEquivalent(item.keyboardShortcutKey), modifiers: [.command])
          .disabled(!canUseProtectedWorkbench)
        }

        Divider()

        ForEach(WorkspaceNavigationPresentation.secondaryEntryItems) { item in
          Button(workspaceNavigationLocalizedKey(item.displayNameLocalizationKey)) {
            store.selectSection(item.section)
          }
          .keyboardShortcut(KeyEquivalent(item.keyboardShortcutKey), modifiers: [.command])
          .disabled(!canUseProtectedWorkbench)
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
      .disabled(!canUseProtectedWorkbench || workspaceCommandPaletteAction == nil)
    }

    CommandMenu(String(localized: "发布")) {
      Button(String(localized: "发布所有变更…")) {
        openPublishDrawerForCommandDraft(
          message: String(localized: "发布中心已打开；默认操作为发布所有变更，也可以仅发布当前文章。")
        )
      }
      .keyboardShortcut("p", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench || commandDraftID == nil)

      Button(String(localized: "运行发布检查")) {
        runPreflightForCommandDraft()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(!canUseProtectedWorkbench)

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
        .disabled(!canUseProtectedWorkbench)

        Button(String(localized: "停止本地预览")) {
          store.stopLocalSitePreview()
        }
        .disabled(!canUseProtectedWorkbench || !presentation.isLocalSitePreviewRunning)
      }

      Button(workspaceNavigationLocalizedKey("workspace.releaseHistory")) {
        workspaceCommandPaletteAction?.openReleaseHistory()
      }
      .keyboardShortcut("8")
      .disabled(!canUseProtectedWorkbench || workspaceCommandPaletteAction == nil)
    }

    CommandMenu(String(localized: "AI")) {
      Button(
        isAIChatPanelVisible
          ? String(localized: "关闭 AI 对话")
          : String(localized: "打开 AI 对话")
      ) {
        toggleAIChatWorkspaceForCommandContext()
      }
      .keyboardShortcut("a", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench)

      Divider()

      Button(String(localized: "改写选中文本")) {
        markdownEditorCommands?.rewriteSelection()
      }
      .keyboardShortcut("r", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canRewriteSelection != true)

      Button(String(localized: "复制上下文 Prompt")) {
        markdownEditorCommands?.copyAIPrompt()
      }
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)
    }

    CommandGroup(after: .help) {
      Button(String(localized: "查看快捷键说明")) {
        markdownEditorCommands?.showKeyboardShortcuts()
      }
      .keyboardShortcut("/", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Divider()

      Button(String(localized: "添加软件使用指南")) {
        installSoftwareGuidesFromHelp()
      }
      .disabled(!canUseProtectedWorkbench)

      Button(String(localized: "导出脱敏诊断包…")) {
        exportRedactedDiagnostics()
      }
      .disabled(!canUseProtectedWorkbench)

    }
  }

  private var canUseProtectedWorkbench: Bool {
    presentation.canUseProtectedWorkbench
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

  private var repositorySourceEditorCommands: RepositorySourceEditorCommandActions? {
    commandRouter?.repositorySourceEditorCommandActions
  }

  private var repositorySourceSessionCommands: RepositorySourceSessionCommandActions? {
    commandRouter?.repositorySourceSessionCommandActions
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
    repositorySourceEditorCommands == nil
      && repositorySourceSessionCommands?.hasUnsavedChanges != true
      ? String(localized: "保存工作台")
      : String(localized: "保存 HTML 源文件")
  }

  private var canSaveCurrentContent: Bool {
    canUseProtectedWorkbench
      && (repositorySourceEditorCommands == nil
        || repositorySourceEditorCommands?.canSave == true)
  }

  @ViewBuilder
  private var findAndSearchCommands: some View {
    Button(searchCommandTitle) {
      if let rssReaderCommands {
        rssReaderCommands.focusSearch()
      } else if let repositorySourceEditorCommands {
        repositorySourceEditorCommands.showFind()
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
      !canUseProtectedWorkbench
        || (repositorySourceEditorCommands != nil
          && repositorySourceEditorCommands?.hasDocument != true)
        || (repositorySourceEditorCommands == nil
          && knowledgeLibraryCommands == nil
          && markdownEditorCommands == nil
          && writingDraftCommands == nil
          && rssReaderCommands == nil)
    )

    Button(String(localized: "跨文章全文搜索")) {
      draftFullTextSearchAction?.open()
    }
    .keyboardShortcut("f", modifiers: [.command, .option])
    .disabled(!canUseProtectedWorkbench || draftFullTextSearchAction == nil)

    Button(String(localized: "搜索草稿列表")) {
      writingDraftCommands?.focusSearch()
    }
    .disabled(!canUseProtectedWorkbench || writingDraftCommands == nil)

    Divider()

    Button(String(localized: "查找下一个")) {
      if let repositorySourceEditorCommands {
        repositorySourceEditorCommands.findNext()
      } else {
        markdownEditorCommands?.findNext()
      }
    }
    .keyboardShortcut("g")
    .disabled(
      !canUseProtectedWorkbench
        || (repositorySourceEditorCommands != nil
          && repositorySourceEditorCommands?.hasDocument != true)
        || (repositorySourceEditorCommands == nil
          && markdownEditorCommands?.canUseFindReplace != true)
    )

    Button(String(localized: "查找上一个")) {
      if let repositorySourceEditorCommands {
        repositorySourceEditorCommands.findPrevious()
      } else {
        markdownEditorCommands?.findPrevious()
      }
    }
    .keyboardShortcut("g", modifiers: [.command, .shift])
    .disabled(
      !canUseProtectedWorkbench
        || (repositorySourceEditorCommands != nil
          && repositorySourceEditorCommands?.hasDocument != true)
        || (repositorySourceEditorCommands == nil
          && markdownEditorCommands?.canUseFindReplace != true)
    )

    Button(String(localized: "替换当前匹配")) {
      markdownEditorCommands?.replaceCurrentOrNext()
    }
    .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canUseFindReplace != true)

    Button(String(localized: "全部替换")) {
      markdownEditorCommands?.replaceAll()
    }
    .keyboardShortcut("e", modifiers: [.command, .option])
    .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canUseFindReplace != true)
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
      .keyboardShortcut("s", modifiers: [.command, .control])
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
    .disabled(!canUseProtectedWorkbench || writingDraftCommands == nil || commandDraftID == nil)

    Divider()

    Button(String(localized: "文章后退")) {
      navigateDraftHistoryBackward()
    }
    .keyboardShortcut("[", modifiers: [.command])
    .disabled(!canUseProtectedWorkbench || !presentation.canNavigateBackwardInDraftHistory)

    Button(String(localized: "文章前进")) {
      navigateDraftHistoryForward()
    }
    .keyboardShortcut("]", modifiers: [.command])
    .disabled(!canUseProtectedWorkbench || !presentation.canNavigateForwardInDraftHistory)

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
      .disabled(!canUseProtectedWorkbench)

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
      .disabled(!canUseProtectedWorkbench)
    }
  }

  private var searchCommandTitle: String {
    if rssReaderCommands != nil { return String(localized: "搜索 RSS 文章") }
    if repositorySourceEditorCommands != nil { return String(localized: "查找 HTML 源码") }
    if knowledgeLibraryCommands != nil { return String(localized: "搜索资料库") }
    return markdownEditorCommands == nil
      ? String(localized: "搜索草稿")
      : String(localized: "查找/替换当前文章")
  }

  private var commandDraftID: UUID? {
    guard repositorySourceEditorCommands == nil else { return nil }
    return markdownEditorCommands?.draftID ?? presentation.selectedDraftID
  }

  private var supportsInspector: Bool {
    WorkspaceInspectorPresentation.supportsInspector(for: presentation.selectedSection)
  }

  private func focusCommandDraft(section: WorkspaceSection? = nil) {
    guard let draftID = commandDraftID else {
      return
    }
    _ = store.focusDraft(draftID, section: section)
  }

  private func saveCurrentContent() {
    if let repositorySourceEditorCommands {
      repositorySourceEditorCommands.save()
    } else if let repositorySourceSessionCommands,
      repositorySourceSessionCommands.hasUnsavedChanges
    {
      if repositorySourceSessionCommands.save() {
        Task { await store.repository.scanAsync() }
        EditorAccessibilityAnnouncementCenter.announce(
          String(localized: "HTML 源文件已保存。"),
          priority: .high
        )
      } else {
        EditorAccessibilityAnnouncementCenter.announce(
          repositorySourceSessionCommands.lastErrorMessage()
            ?? String(localized: "未能保存 HTML 源文件。"),
          priority: .high
        )
      }
    } else {
      store.save()
    }
  }

  private func chooseSiteRepository() {
    store.selectSection(.sync)
    if let url = RepositorySelectionPanel.chooseDirectory() {
      Task {
        await store.repository.rememberRootAsync(url)
      }
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
    alert.runModal()
  }

  private func exportRedactedDiagnostics() {
    guard let directoryURL = WorkbenchDiagnosticsSelectionPanel.chooseExportDirectory() else {
      return
    }
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
      alert.runModal()
    } catch {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = String(localized: "导出脱敏诊断包失败")
      alert.informativeText = error.localizedDescription
      alert.addButton(withTitle: String(localized: "关闭"))
      alert.runModal()
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

  private func openPublishDrawerForCommandDraft(message: String) {
    guard commandDraftID != nil else {
      return
    }
    focusCommandDraft()
    if let publishDrawerCommandAction {
      publishDrawerCommandAction.open(message)
    } else {
      store.runPreflight()
      store.setPublishActionMessage(message, status: .information)
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
    copyToPasteboard(plan.commandText, successMessage: "已复制同步建议命令。")
  }

  private func copyToPasteboard(_ value: String, successMessage: String) {
    ClipboardWriter.copy(value, successMessage: successMessage) { message, status in
      store.setPublishActionMessage(message, status: status)
    }
  }
}

struct PublishingConsoleSettingsCommands: Commands {
  @FocusedObject private var commandRouter: WorkspaceSceneCommandRouter?
  @Environment(\.openSettings) private var openSettings

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button(String(localized: "设置…")) {
        if let action = commandRouter?.settingsWorkspaceCommandAction {
          action.open(nil)
        } else {
          SettingsNavigation.open(destination: nil) {
            openSettings()
          }
        }
      }
      .keyboardShortcut(",", modifiers: [.command])
    }
  }
}
