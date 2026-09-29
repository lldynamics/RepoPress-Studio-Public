import AppKit
import PublishingMarkdownCore
import SwiftUI

struct MarkdownEditorCommandActions {
  var draftID: UUID
  var canRewriteSelection: Bool
  var canUseFindReplace: Bool
  var showFindReplace: () -> Void
  var showKeyboardShortcuts: () -> Void
  var showSnippets: () -> Void
  var findPrevious: () -> Void
  var findNext: () -> Void
  var replaceCurrentOrNext: () -> Void
  var replaceAll: () -> Void
  var applyFormatting: (MarkdownFormattingCommand) -> Void
  var insertImages: () -> Void
  var runPreflight: () -> Void
  var rewriteSelection: () -> Void
  var openAIAssistant: () -> Void
  var copyAIPrompt: () -> Void
  var openExternalBrowserPreview: () -> Void = {}
  var printDocument: () -> Void = {}
  var saveDocument: (() -> Void)? = nil
  var exportDocument: ((MarkdownDocumentExportFormat) -> Void)? = nil
}

enum MarkdownFormattingResponderBridge {
  @MainActor
  static func perform(_ command: MarkdownFormattingCommand) -> Bool {
    let selectorName: String
    switch command {
    case .bold:
      selectorName = "applyMarkdownBold:"
    case .italic:
      selectorName = "applyMarkdownItalic:"
    case .link:
      selectorName = "applyMarkdownLink:"
    case .heading(let level):
      guard (1...3).contains(level) else { return false }
      selectorName = "applyMarkdownHeading\(level):"
    }
    return NSApp.sendAction(NSSelectorFromString(selectorName), to: nil, from: nil)
  }
}
