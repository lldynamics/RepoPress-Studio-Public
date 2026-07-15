import AppKit
import PublishingWorkbenchCore
import SwiftUI

struct PublishingConsoleCommands: Commands {
  @ObservedObject var store: WorkbenchStore
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

      Button("快速隐藏工作台") {
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
          ForEach(WorkspaceNavigationPresentation.secondaryEntryItems) { item in
            Button(workspaceNavigationLocalizedKey(item.displayNameLocalizationKey)) {
              store.selectSection(item.section)
            }
            .disabled(!canUseProtectedWorkbench)
          }
        }
      }

      Divider()

      Button(markdownEditorCommands == nil ? "搜索草稿" : "查找/替换当前文章") {
        if let markdownEditorCommands {
          markdownEditorCommands.showFindReplace()
        } else {
          writingDraftCommands?.focusSearch()
        }
      }
      .keyboardShortcut("f")
      .disabled(!canUseProtectedWorkbench || (markdownEditorCommands == nil && writingDraftCommands == nil))

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
          store.refreshBatchPublishPlan()
          store.selectSection(.sync)
        }
        .disabled(!canUseProtectedWorkbench)

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
      }

      Button("发布当前文章…") {
        openPublishDrawerForCommandDraft(message: "请在统一发布流程中确认检查、Diff、写入方式、远端策略和部署状态。")
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
  }

  private var canUseProtectedWorkbench: Bool {
    store.canUseProtectedWorkbench
  }

  private var commandDraftID: UUID? {
    markdownEditorCommands?.draftID ?? store.selectedDraftID
  }

  private var supportsInspector: Bool {
    switch store.selectedSection {
    case .writing, .sync, .images, .contentHealth, .ai:
      return true
    case .siteStarter, .generalDrafts, .maintenance, .releaseHistory:
      return false
    }
  }

  private func focusCommandDraft(section: WorkspaceSection? = nil) {
    guard let draftID = commandDraftID else {
      return
    }
    _ = store.focusDraft(draftID, section: section)
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
