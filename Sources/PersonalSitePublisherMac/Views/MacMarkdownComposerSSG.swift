import Foundation
import PublishingWorkbenchCore

extension MacMarkdownComposerView {
  var markdownSSGSnippets: [MarkdownSnippet] {
    MarkdownSnippetLibraryService.availableSnippets(
      for: draft.siteProfileID,
      customSnippets: store.customMarkdownSnippets
    ).map { snippet in
      var expanded = snippet
      expanded.markdown = MarkdownSnippetLibraryService.expandedMarkdown(
        for: snippet,
        draft: previewDraft
      )
      return expanded
    }
  }

  var markdownSSGComponentOccurrences: [MarkdownSSGComponentOccurrence] {
    MarkdownSSGComponentLibraryService.occurrences(in: editorBody)
  }

  func handleAutomaticSSGSnippetShortcut(_ candidate: MarkdownCompletionCandidate) {
    Task { @MainActor in
      guard !isFrontMatterSelection,
            MarkdownCursorCompletionService().edit(
              applying: candidate,
              in: editorBody
            ) != nil else {
        return
      }
      applyMarkdownCompletion(candidate)
    }
  }

  func focusSSGComponentOccurrence(_ occurrence: MarkdownSSGComponentOccurrence) {
    guard requireBodyEditingContext() else { return }
    if editorState.editorDisplayMode == .preview {
      store.setEditorDisplayMode(.split)
    }
    selectedRange = occurrence.sourceRange
    markdownTextFocusRequest = MarkdownTextFocusRequest(
      id: UUID(),
      selectedRange: occurrence.sourceRange
    )
    selectionActionMessage = "已定位到第 \(occurrence.lineNumber) 行的\(occurrence.title)。"
  }
}
