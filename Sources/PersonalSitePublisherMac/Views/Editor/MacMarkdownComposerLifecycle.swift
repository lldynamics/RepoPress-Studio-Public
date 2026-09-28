import Foundation
import PublishingWorkbenchCore

extension MacMarkdownComposerView {
  /// AppKit-hosted test and preview composers do not receive a workspace
  /// window session. They still need a stable owner for Front Matter recovery,
  /// without granting that fallback identity any selection authority.
  var frontMatterRecoveryOwnerID: UUID {
    workspaceWindowSession?.windowID ?? sceneCommandOwnerID
  }

  func handleComposerDisappear() {
    let recoveryOwnerID = frontMatterRecoveryOwnerID
    let windowID = workspaceWindowSession?.windowID
    sceneCommandRouter.unregisterMarkdownEditor(owner: sceneCommandOwnerID)
    cancelFindMatchRefresh()
    editorSessionState.findReplacePlanningCoordinator.cancel()
    editorSessionSaveTask?.cancel()
    editorSessionSaveTask = nil
    markdownAnalysisTask?.cancel()
    markdownAnalysisTask = nil
    cancelAttachmentImport()
    persistEditorSession(for: draft.id)
    MarkdownFrontMatterRecoveryWindowRegistry.shared.unregister(recoveryOwnerID)
    cancelSelectionAIAction()
    cancelInlineGhostText()
    cancelAIPromptClipboardTask()
    externalBrowserPreviewCoordinator.cancelPendingOpen()
    guard workspaceWindowIsKey, let windowID else { return }
    store.clearActiveEditorSelection(
      for: draft.id, windowID: windowID
    )
  }
}

extension MarkdownFrontMatterEditingIssue {
  var workbenchMessage: String {
    switch self {
    case .invalidDelimiter:
      return String(localized: "起止分隔符缺失或与当前站点的 Front Matter 格式不匹配。")
    case .concurrentBodyChange:
      return String(localized: "另一窗口已修改正文；恢复原文仍保留，未覆盖另一窗口的内容。")
    case .malformedLine(let line):
      return String(localized: "第 \(line) 行不是有效的键值格式。")
    case .missingDate:
      return String(localized: "缺少必需的 date 字段。")
    case .invalidDate:
      return String(localized: "date 字段不是有效日期。")
    case .invalidDraftFlag:
      return String(localized: "draft 字段必须使用有效的布尔值。")
    case .invalidVisibility:
      return String(localized: "visibility 字段不是受支持的可见性值。")
    }
  }
}
