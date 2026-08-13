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
    let equalityTolerance = 0.001
    var didChange = false
    switch source {
    case .editor:
      if abs(editorScrollProgress - normalizedProgress) >= equalityTolerance {
        editorScrollProgress = normalizedProgress
        didChange = true
      }
      if isSynchronizedScrollingEnabled {
        if abs(previewScrollProgress - normalizedProgress) >= equalityTolerance {
          previewScrollProgress = normalizedProgress
          didChange = true
        }
      }
    case .preview:
      if abs(previewScrollProgress - normalizedProgress) >= equalityTolerance {
        previewScrollProgress = normalizedProgress
        didChange = true
      }
      if isSynchronizedScrollingEnabled {
        if abs(editorScrollProgress - normalizedProgress) >= equalityTolerance {
          editorScrollProgress = normalizedProgress
          didChange = true
        }
      }
    }
    guard didChange else { return }
    saveCurrentEditorSession()

    guard isSynchronizedScrollingEnabled else { return }
    if let scrollSyncUpdate,
      scrollSyncUpdate.source == source,
      abs(scrollSyncUpdate.progress - normalizedProgress) < equalityTolerance
    {
      return
    }
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
    findReplaceMessage =
      findQuery.isEmpty && isFindReplacePresented
      ? "输入查找内容。"
      : ""
    refreshFindMatchSnapshot()
    refreshMarkdownCursorContextSnapshot()
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
    editorSessionSaveGeneration &+= 1
    let generation = editorSessionSaveGeneration
    guard editorSessionSaveTask == nil else { return }
    let draftID = draft.id
    editorSessionSaveTask = Task { @MainActor in
      var observedGeneration = generation
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: .milliseconds(220))
        } catch {
          return
        }
        let currentGeneration = self.editorSessionSaveGeneration
        if currentGeneration != observedGeneration {
          observedGeneration = currentGeneration
          continue
        }
        self.persistEditorSession(for: draftID)
        self.editorSessionSaveTask = nil
        return
      }
    }
  }

  func flushEditorSessionSave(for draftID: UUID) {
    editorSessionSaveGeneration &+= 1
    editorSessionSaveTask?.cancel()
    editorSessionSaveTask = nil
    persistEditorSession(for: draftID)
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
