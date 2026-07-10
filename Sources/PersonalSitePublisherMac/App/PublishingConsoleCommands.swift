import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PublishingConsoleCommands: Commands {
  @ObservedObject var store: WorkbenchStore
  @Environment(\.openWindow) private var openWindow
  @FocusedValue(\.markdownEditorCommandActions) private var markdownEditorCommands
  @FocusedValue(\.publishDrawerCommandAction) private var publishDrawerCommandAction
  @FocusedValue(\.writingDraftCommandActions) private var writingDraftCommands

  var body: some Commands {
    CommandMenu("发布控制台") {
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

      Button("显示隐私遮罩") {
        store.lockPrivacy(reason: "已手动显示隐私界面遮罩。")
      }
      .keyboardShortcut("l", modifiers: [.command, .control])
      .disabled(store.isPrivacyLocked)

      Button("移除隐私遮罩") {
        store.unlockPrivacy()
      }
      .disabled(!store.isPrivacyLocked)

      Divider()

      Button("在新窗口打开当前文章") {
        if let draftID = commandDraftID {
          openWindow(value: draftID)
        }
      }
      .keyboardShortcut(.return, modifiers: [.command, .shift])
      .disabled(!canUseProtectedWorkbench || commandDraftID == nil)

      Menu("切换工作区") {
        ForEach(WorkspaceNavigationPresentation.commandMenuItems) { item in
          Button(item.displayName) {
            store.selectSection(item.section)
          }
          .keyboardShortcut(KeyEquivalent(item.keyboardShortcutKey), modifiers: [.command])
          .disabled(!canUseProtectedWorkbench)
        }

        Divider()

        Menu("站点工具") {
          ForEach(WorkspaceNavigationPresentation.secondaryEntryItems) { item in
            Button(item.displayName) {
              store.selectSection(item.section)
            }
            .disabled(!canUseProtectedWorkbench)
          }
        }
      }

      Menu("诊断") {
        Button("上架门禁") {
          store.selectSection(.releaseReadiness)
        }
        .disabled(!canUseProtectedWorkbench)
      }

      Divider()

      Button(store.selectedSection == .writing ? "搜索草稿" : "查找/替换当前文章") {
        if store.selectedSection == .writing {
          writingDraftCommands?.focusSearch()
        } else {
          markdownEditorCommands?.showFindReplace()
        }
      }
      .keyboardShortcut("f")
      .disabled(!canUseProtectedWorkbench || (store.selectedSection == .writing && writingDraftCommands == nil) || (store.selectedSection != .writing && markdownEditorCommands == nil))

      if let writingDraftCommands {
        Button("上一个草稿") {
          writingDraftCommands.selectPreviousDraft()
        }
        .keyboardShortcut(.upArrow)
        .disabled(!canUseProtectedWorkbench)

        Button("下一个草稿") {
          writingDraftCommands.selectNextDraft()
        }
        .keyboardShortcut(.downArrow)
        .disabled(!canUseProtectedWorkbench)
      }

      Button("查找下一个") {
        markdownEditorCommands?.findNext()
      }
      .keyboardShortcut("g")
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canUseFindReplace != true)

      Button("替换当前匹配") {
        markdownEditorCommands?.replaceCurrentOrNext()
      }
      .keyboardShortcut("e", modifiers: [.command])
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

      Button("查看会话历史") {
        markdownEditorCommands?.showRevisionHistory()
      }
      .keyboardShortcut("z", modifiers: [.option, .command])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Button("撤销会话快照") {
        markdownEditorCommands?.undoRevision()
      }
      .keyboardShortcut("z", modifiers: [.command, .option, .shift])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canUndoRevision != true)

      Button("恢复会话快照") {
        markdownEditorCommands?.redoRevision()
      }
      .keyboardShortcut("z", modifiers: [.command, .option, .shift, .control])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands?.canRedoRevision != true)

      Button("插入图片到当前文章") {
        markdownEditorCommands?.insertImages()
      }
      .keyboardShortcut("i", modifiers: [.command, .shift])
      .disabled(!canUseProtectedWorkbench || markdownEditorCommands == nil)

      Menu("AI 对话") {
        Button("打开 AI 对话") {
          openAIChatWorkspaceForCommandDraft()
        }
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
        store.importDraftsFromLocalRepository()
      }
      .disabled(!canUseProtectedWorkbench)

      Button("复制同步建议命令") {
        focusCommandDraft(section: .sync)
        copyRepositorySyncCommands()
      }
      .disabled(!canUseProtectedWorkbench)

      Button("刷新待发布队列") {
        focusCommandDraft(section: .sync)
        store.refreshBatchPublishPlan()
        store.selectSection(.sync)
      }
      .disabled(!canUseProtectedWorkbench)

      Button("批量写入可发布文章") {
        focusCommandDraft(section: .sync)
        store.writeBatchReadyDraftsToLocalRepository()
        store.selectSection(.sync)
      }
      .keyboardShortcut("b", modifiers: [.command, .shift])
      .disabled(!canUseProtectedWorkbench)

      Button("打开批量 PR/MR 创建页") {
        focusCommandDraft(section: .sync)
        if let url = store.batchRemoteReviewDraft?.webURL {
          ExternalURLOpener.open(url)
        } else {
          store.setPublishActionMessage("填写仓库 owner/name 后才能打开批量 PR/MR 创建页。")
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

      Button("按 Profile 策略发布") {
        openPublishDrawerForCommandDraft(message: "请在发布流程中确认检查结果、Diff 和写入方式后，再按 Profile 策略发布。")
      }
      .disabled(!canUseProtectedWorkbench || commandDraftID == nil)

      Button("直接提交到当前分支") {
        openPublishDrawerForCommandDraft(message: "请在发布流程中确认检查结果和 Diff 后，再选择直接提交。")
      }
      .disabled(!canUseProtectedWorkbench || commandDraftID == nil)

      Button("创建发布分支并提交") {
        openPublishDrawerForCommandDraft(message: "请在发布流程中确认检查结果、Diff 和 PR/MR 描述后，再创建发布分支。")
      }
      .disabled(!canUseProtectedWorkbench || commandDraftID == nil)

      Divider()

      Button(store.isInspectorPresented ? "隐藏 Inspector" : "显示 Inspector") {
        store.setInspectorPresented(!store.isInspectorPresented)
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .disabled(!canUseProtectedWorkbench)
    }
  }

  private var canUseProtectedWorkbench: Bool {
    store.canUseProtectedWorkbench
  }

  private var commandDraftID: UUID? {
    markdownEditorCommands?.draftID ?? store.selectedDraftID
  }

  private func focusCommandDraft(section: WorkspaceSection? = nil) {
    guard let draftID = commandDraftID else {
      return
    }
    store.focusDraft(draftID, section: section)
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
      store.setPublishActionMessage("选择本地仓库后才能生成同步建议命令。")
      return
    }
    copyToPasteboard(plan.commandText)
    store.setPublishActionMessage("已复制同步建议命令。")
  }

  private func copyToPasteboard(_ value: String) {
    ClipboardWriter.copy(value, successMessage: "已复制到剪贴板。") { store.setPublishActionMessage($0) }
  }
}
