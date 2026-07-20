import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PublishingConsoleCommands: Commands {
  @ObservedObject var store: WorkbenchStore
  @FocusedValue(\.markdownEditorCommandActions) private var markdownEditorCommands
  @FocusedValue(\.publishDrawerCommandAction) private var publishDrawerCommandAction
  @FocusedValue(\.writingDraftCommandActions) private var writingDraftCommands
  @FocusedValue(\.workspaceCommandPaletteAction) private var workspaceCommandPaletteAction
  @FocusedValue(\.draftFullTextSearchAction) private var draftFullTextSearchAction
  @FocusedValue(\.knowledgeLibraryCommandActions) private var knowledgeLibraryCommands

  var body: some Commands {
    CommandMenu("发布控制台") {
      Button("命令面板与快速打开") {
        workspaceCommandPaletteAction?.open()
      }
      .keyboardShortcut("p")
      .disabled(!canUseProtectedWorkbench || workspaceCommandPaletteAction == nil)

      Divider()

      Button("新建文章") {
        if let writingDraftCommands {
          writingDraftCommands.createDraft()
        } else {
          store.createDraft()
        }
      }
      .keyboardShortcut("n")
      .disabled(!canUseProtectedWorkbench)

      Button("保存工作台") {
        store.save()
      }
      .keyboardShortcut("s")
      .disabled(!canUseProtectedWorkbench)

      Button(String(localized: "立即锁定软件")) {
        store.lockPrivacy(reason: "已手动快速隐藏工作台内容。")
      }
      .keyboardShortcut("l", modifiers: [.command, .control])
      .disabled(store.isPrivacyLocked)

      Button("返回工作台") {
        store.unlockPrivacy()
      }
      .disabled(!store.isPrivacyLocked)

      Divider()

      Menu("切换工作区") {
        ForEach(WorkspaceNavigationPresentation.commandMenuItems) { item in
          Button(workspaceNavigationLocalizedKey(item.displayNameLocalizationKey)) {
            store.selectSection(item.section)
          }
          .keyboardShortcut(KeyEquivalent(item.keyboardShortcutKey), modifiers: [.command])
          .disabled(!canUseProtectedWorkbench)
        }

        Divider()

        Menu("高级工具") {
          ForEach(WorkspaceNavigationPresentation.commandMenuAdvancedItems) { item in
            Button(workspaceNavigationLocalizedKey(item.displayNameLocalizationKey)) {
              store.selectSection(item.section)
            }
            .keyboardShortcut(KeyEquivalent(item.keyboardShortcutKey), modifiers: [.command])
            .disabled(!canUseProtectedWorkbench)
          }
        }
      }

      Divider()

      Button(searchCommandTitle) {
        if let knowledgeLibraryCommands {
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
          || (knowledgeLibraryCommands == nil
            && markdownEditorCommands == nil
            && writingDraftCommands == nil)
      )

      Button("跨文章全文搜索") {
        draftFullTextSearchAction?.open()
      }
      .keyboardShortcut("f", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench || draftFullTextSearchAction == nil)

      Button("搜索草稿列表") {
        writingDraftCommands?.focusSearch()
      }
      .disabled(!canUseProtectedWorkbench || writingDraftCommands == nil)

      Button("文章版本历史") {
        writingDraftCommands?.openVersionHistory()
      }
      .disabled(!canUseProtectedWorkbench || writingDraftCommands == nil || commandDraftID == nil)

      Button("文章后退") {
        navigateDraftHistoryBackward()
      }
      .keyboardShortcut("[", modifiers: [.command])
      .disabled(!canUseProtectedWorkbench || !store.canNavigateBackwardInDraftHistory)

      Button("文章前进") {
        navigateDraftHistoryForward()
      }
      .keyboardShortcut("]", modifiers: [.command])
      .disabled(!canUseProtectedWorkbench || !store.canNavigateForwardInDraftHistory)

      if knowledgeLibraryCommands != nil || writingDraftCommands != nil {
        Button(knowledgeLibraryCommands == nil ? "上一个草稿" : "上一条资料") {
          if let knowledgeLibraryCommands {
            knowledgeLibraryCommands.selectPreviousDocument()
          } else {
            writingDraftCommands?.selectPreviousDraft()
          }
        }
        .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        .disabled(!canUseProtectedWorkbench)

        Button(knowledgeLibraryCommands == nil ? "下一个草稿" : "下一条资料") {
          if let knowledgeLibraryCommands {
            knowledgeLibraryCommands.selectNextDocument()
          } else {
            writingDraftCommands?.selectNextDraft()
          }
        }
        .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        .disabled(!canUseProtectedWorkbench)
      }

      Button("查找下一个") {
        markdownEditorCommands?.findNext()
      }
      .keyboardShortcut("g")
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canUseFindReplace != true)

      Button("查找上一个") {
        markdownEditorCommands?.findPrevious()
      }
      .keyboardShortcut("g", modifiers: [.command, .shift])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canUseFindReplace != true)

      Button("替换当前匹配") {
        markdownEditorCommands?.replaceCurrentOrNext()
      }
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canUseFindReplace != true)

      Button("全部替换") {
        markdownEditorCommands?.replaceAll()
      }
      .keyboardShortcut("e", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canUseFindReplace != true)

      Divider()

      Button("查看快捷键说明") {
        markdownEditorCommands?.showKeyboardShortcuts()
      }
      .keyboardShortcut("/", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Button("Markdown 加粗") {
        markdownEditorCommands?.applyFormatting(.bold)
      }
      .keyboardShortcut("b", modifiers: [.command])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Button("Markdown 斜体") {
        markdownEditorCommands?.applyFormatting(.italic)
      }
      .keyboardShortcut("i", modifiers: [.command])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Button("插入 Markdown 链接") {
        markdownEditorCommands?.applyFormatting(.link)
      }
      .keyboardShortcut("k", modifiers: [.command])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Menu("Markdown 标题") {
        Button("一级标题") {
          markdownEditorCommands?.applyFormatting(.heading(level: 1))
        }
        .keyboardShortcut("1", modifiers: [.command, .option])

        Button("二级标题") {
          markdownEditorCommands?.applyFormatting(.heading(level: 2))
        }
        .keyboardShortcut("2", modifiers: [.command, .option])

        Button("三级标题") {
          markdownEditorCommands?.applyFormatting(.heading(level: 3))
        }
        .keyboardShortcut("3", modifiers: [.command, .option])
      }
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Button(knowledgeLibraryCommands == nil ? "插入图片到当前文章" : "导入资料…") {
        if let knowledgeLibraryCommands {
          knowledgeLibraryCommands.importSources()
        } else {
          markdownEditorCommands?.insertImages()
        }
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .disabled(
        !canUseProtectedWorkbench
          || (knowledgeLibraryCommands == nil && markdownEditorCommands == nil)
      )

      Button("模板与片段") {
        markdownEditorCommands?.showSnippets()
      }
      .keyboardShortcut("s", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Menu("AI 对话") {
        Button(isAIChatPanelVisible ? "关闭 AI 对话" : "打开 AI 对话") {
          toggleAIChatWorkspaceForCommandDraft()
        }
        .keyboardShortcut("a", modifiers: [.command, .option])
        .disabled(!canUseProtectedWorkbench || commandDraftID == nil)

        Divider()

        Button("改写选中文本") {
          markdownEditorCommands?.rewriteSelection()
        }
        .keyboardShortcut("r", modifiers: [.command, .option])
        .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canRewriteSelection != true)

        Button("复制上下文 Prompt") {
          markdownEditorCommands?.copyAIPrompt()
        }
        .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)
      }

      Divider()

      Button("运行发布检查") {
        runPreflightForCommandDraft()
      }
      .keyboardShortcut("r", modifiers: [.command, .shift])
      .disabled(!canUseProtectedWorkbench)

      Menu("仓库与批量发布") {
        Button("打开本地预览") {
        focusCommandDraft(section: .sync)
        store.startLocalSitePreview()
        if let url = store.localSitePreviewPlan?.previewURL {
          ExternalURLOpener.open(url)
        }
        }
        .keyboardShortcut("p", modifiers: [.command, .shift])
        .disabled(!canUseProtectedWorkbench)

        Button("停止本地预览") {
          store.stopLocalSitePreview()
        }
        .disabled(!canUseProtectedWorkbench || !store.localSitePreviewRuntimeStatus.isRunning)

        Divider()

        Button("选择本地仓库...") {
          focusCommandDraft(section: .sync)
          if let url = RepositorySelectionPanel.chooseDirectory() {
            Task {
              await store.repository.rememberRootAsync(url)
            }
          }
        }
        .keyboardShortcut("o", modifiers: [.command, .shift])
        .disabled(!canUseProtectedWorkbench)

        Button("从本地仓库导入文章") {
          focusCommandDraft(section: .sync)
          Task {
            await store.importDraftsFromLocalRepositoryAsync()
          }
        }
        .disabled(!canUseProtectedWorkbench)

        Button("复制同步建议命令") {
          focusCommandDraft(section: .sync)
          copyRepositorySyncCommands()
        }
        .disabled(!canUseProtectedWorkbench)

        Divider()

        Button("刷新待发布队列") {
          focusCommandDraft(section: .sync)
          Task {
            await store.refreshBatchPublishPlanAsync()
          }
          store.selectSection(.sync)
        }
        .disabled(!canUseProtectedWorkbench || store.isBatchPublishPlanRefreshing)

        Button("批量写入可发布文章") {
          focusCommandDraft(section: .sync)
          Task {
            await store.writeBatchReadyDraftsToLocalRepository()
          }
          store.selectSection(.sync)
        }
        .keyboardShortcut("b", modifiers: [.command, .shift])
        .disabled(!canUseProtectedWorkbench || store.isLocalRepositoryMutationRunning)

        Button("打开批量 PR/MR 创建页") {
          focusCommandDraft(section: .sync)
          if let url = store.batchRemoteReviewDraft?.webURL {
            ExternalURLOpener.open(url)
          } else {
            store.setPublishActionMessage(String(localized: "填写仓库 owner/name 后才能打开批量 PR/MR 创建页。"))
          }
        }
        .disabled(!canUseProtectedWorkbench)

        Button("打开 PR/MR 创建页") {
          focusCommandDraft(section: .sync)
          if let url = store.remoteReviewDraft?.webURL {
            ExternalURLOpener.open(url)
          }
        }
        .keyboardShortcut("p", modifiers: [.command, .option])
        .disabled(!canUseProtectedWorkbench || commandDraftID == nil)
      }

      Button("发布当前文章…") {
        openPublishDrawerForCommandDraft(message: "请在统一发布流程中确认检查、差异、写入方式、远端策略和部署状态。")
      }
      .disabled(!canUseProtectedWorkbench || commandDraftID == nil)

      Divider()

      if supportsInspector {
        Button(store.isInspectorPresented ? "隐藏 Inspector" : "显示 Inspector") {
          store.setInspectorPresented(!store.isInspectorPresented)
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(!canUseProtectedWorkbench)
      }
    }

    CommandGroup(after: .help) {
      Button("添加软件使用指南") {
        installSoftwareGuidesFromHelp()
      }
      .disabled(!canUseProtectedWorkbench)
    }
  }

  private var canUseProtectedWorkbench: Bool {
    store.canUseProtectedWorkbench
  }

  private var searchCommandTitle: String {
    if knowledgeLibraryCommands != nil { return "搜索资料库" }
    return markdownEditorCommands == nil ? "搜索草稿" : "查找/替换当前文章"
  }

  private var commandDraftID: UUID? {
    markdownEditorCommands?.draftID ?? store.selectedDraftID
  }

  private var supportsInspector: Bool {
    WorkspaceInspectorPresentation.supportsInspector(for: store.selectedSection)
  }

  private func focusCommandDraft(section: WorkspaceSection? = nil) {
    guard let draftID = commandDraftID else {
      return
    }
    _ = store.focusDraft(draftID, section: section)
  }

  private func installSoftwareGuidesFromHelp() {
    let addedCount = store.installSoftwareGuides()
    let message = addedCount == 0
      ? String(localized: "使用指南已经全部存在。")
      : String(localized: "已添加缺少的使用指南，工作台正在保存。")
    EditorAccessibilityAnnouncementCenter.announce(message, priority: .high)

    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = message
    alert.addButton(withTitle: String(localized: "关闭"))
    alert.runModal()
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

  private func openAIChatWorkspaceForCommandDraft() {
    guard let draftID = commandDraftID else {
      return
    }
    store.ai.openChatWorkspace(for: draftID)
  }

  private var isAIChatPanelVisible: Bool {
    store.isAIPublishingAssistantPresented && store.isInspectorPresented
  }

  private func toggleAIChatWorkspaceForCommandDraft() {
    if isAIChatPanelVisible {
      store.ai.closeAssistantPanel()
    } else {
      openAIChatWorkspaceForCommandDraft()
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
      store.setPublishActionMessage(message)
    }
  }

  private func copyRepositorySyncCommands() {
    guard let plan = store.repositorySyncCommandPlan else {
      store.setPublishActionMessage(String(localized: "选择本地仓库后才能生成同步建议命令。"))
      return
    }
    copyToPasteboard(plan.commandText)
    store.setPublishActionMessage(String(localized: "已复制同步建议命令。"))
  }

  private func copyToPasteboard(_ value: String) {
    ClipboardWriter.copy(value, successMessage: "已复制到剪贴板。") { store.setPublishActionMessage($0) }
  }
}
