import SwiftUI

/// Scene commands register the shortcut even when the toolbar's menu has
/// never been opened. Scenes without an editor retain the writing-list route.
struct MarkdownEditorVersionHistoryMenuCommand: View {
  let writingDraftActions: WritingDraftCommandActions?
  let draftID: UUID?
  @FocusedValue(\.markdownEditorVersionHistoryCommandAction)
  private var editorAction

  var body: some View {
    Button(String(localized: "文章版本历史")) {
      if let editorAction {
        editorAction.open()
      } else {
        writingDraftActions?.openVersionHistory()
      }
    }
    .keyboardShortcut("h", modifiers: [.command, .option, .control])
    .disabled(editorAction == nil && (writingDraftActions == nil || draftID == nil))
  }
}
