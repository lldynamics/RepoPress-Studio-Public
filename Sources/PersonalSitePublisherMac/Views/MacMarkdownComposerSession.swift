import AppKit
import PublishingWorkbenchCore
import SwiftUI

extension MacMarkdownComposerView {
  var commandActions: MarkdownEditorCommandActions {
    MarkdownEditorCommandActions(
      draftID: draft.id,
      canRewriteSelection: !selectedText(in: editorBody).trimmedForPublishing.isEmpty,
      canUseFindReplace: canUseFindReplace,
      showFindReplace: showFindReplace,
      showKeyboardShortcuts: {
        isShortcutHelpPresented = true
      },
      showSnippets: {
        isSnippetLibraryPresented = true
      },
      findPrevious: findPrevious,
      findNext: findNext,
      replaceCurrentOrNext: replaceCurrentOrNext,
      replaceAll: replaceAll,
      applyFormatting: applyMarkdownFormatting,
      insertImages: {
        insertImageReferences(ImageSelectionPanel.chooseImages())
      },
      runPreflight: runPreflightForCurrentDraft,
      rewriteSelection: rewriteSelectedText,
      openAIAssistant: showAIContextInspector,
      copyAIPrompt: pasteAIPromptToClipboard
    )
  }

  var canUseFindReplace: Bool {
    guard !findQuery.isEmpty else { return false }
    return findMatchSnapshot.errorMessage == nil
  }

  func updateSynchronizedScroll(
    source: MarkdownScrollSyncSource,
    progress: Double
  ) {
    let normalizedProgress = min(max(progress.isFinite ? progress : 0, 0), 1)
    switch source {
    case .editor:
      editorScrollProgress = normalizedProgress
      if isSynchronizedScrollingEnabled {
        previewScrollProgress = normalizedProgress
      }
    case .preview:
      previewScrollProgress = normalizedProgress
      if isSynchronizedScrollingEnabled {
        editorScrollProgress = normalizedProgress
      }
    }
    saveCurrentEditorSession()

    guard isSynchronizedScrollingEnabled else { return }
    scrollSyncUpdate = MarkdownScrollSyncUpdate(source: source, progress: normalizedProgress)
  }

  func restoreEditorSession(for draftID: UUID) {
    let bodyUTF16Count = (editorBody as NSString).length
    let editorSession = store.markdownEditorSessionState(for: draftID)
      .normalized(bodyUTF16Count: bodyUTF16Count)

    selectedRange = editorSession.selectedRange(bodyUTF16Count: bodyUTF16Count)
    isFindReplacePresented = editorSession.isFindReplacePresented
    findQuery = editorSession.findQuery
    replacementText = editorSession.replacementText
    isFindCaseSensitive = editorSession.isFindCaseSensitive
    isFindWholeWord = editorSession.isFindWholeWord
    isFindRegularExpression = editorSession.isFindRegularExpression
    editorScrollProgress = editorSession.editorScrollProgress
    previewScrollProgress = editorSession.previewScrollProgress
    scrollSyncUpdate = nil
    editorScrollRestorationUpdate = MarkdownScrollSyncUpdate(
      source: .editor,
      progress: editorSession.editorScrollProgress
    )
    previewScrollRestorationUpdate = MarkdownScrollSyncUpdate(
      source: .preview,
      progress: editorSession.previewScrollProgress
    )
    findReplaceMessage = findQuery.isEmpty && isFindReplacePresented
      ? "输入查找内容。"
      : ""
    refreshFindMatchSnapshot()
  }

  func currentEditorSessionState() -> MarkdownEditorSessionState {
    MarkdownEditorSessionState(
      selectedRange: selectedRange,
      editorScrollProgress: editorScrollProgress,
      previewScrollProgress: previewScrollProgress,
      isFindReplacePresented: isFindReplacePresented,
      findQuery: findQuery,
      replacementText: replacementText,
      isFindCaseSensitive: isFindCaseSensitive,
      isFindWholeWord: isFindWholeWord,
      isFindRegularExpression: isFindRegularExpression
    )
  }

  func saveCurrentEditorSession() {
    persistEditorSession(for: draft.id)
  }

  func persistEditorSession(for draftID: UUID) {
    store.updateMarkdownEditorSessionState(
      currentEditorSessionState(),
      for: draftID,
      bodyUTF16Count: (editorBody as NSString).length
    )
  }

  var findOptions: MarkdownFindOptions {
    MarkdownFindOptions(
      caseSensitive: isFindCaseSensitive,
      wholeWord: isFindWholeWord,
      usesRegularExpression: isFindRegularExpression
    )
  }

  var findMatchStatus: String {
    guard !findQuery.isEmpty else { return "0/0" }
    guard findMatchSnapshot.errorMessage == nil else {
      return "—/—"
    }
    let position = findMatchSnapshot.position(selectedRange: selectedRange)
    return "\(position.currentNumber ?? 0)/\(position.total)"
  }

  var findReplaceFeedbackMessage: String {
    guard !findQuery.isEmpty else { return findReplaceMessage }
    return findMatchSnapshot.errorMessage ?? findReplaceMessage
  }

  static func makeFindMatchSnapshot(
    text: String,
    query: String,
    options: MarkdownFindOptions
  ) -> MarkdownFindMatchSnapshot {
    guard !query.isEmpty else { return .empty }
    do {
      return MarkdownFindMatchSnapshot(
        ranges: try MarkdownFindReplaceService().matches(
          in: text,
          query: query,
          options: options
        ),
        errorMessage: nil
      )
    } catch {
      return MarkdownFindMatchSnapshot(ranges: [], errorMessage: error.localizedDescription)
    }
  }

  func refreshFindMatchSnapshot() {
    findMatchSnapshot = Self.makeFindMatchSnapshot(
      text: editorBody,
      query: findQuery,
      options: findOptions
    )
  }
}
