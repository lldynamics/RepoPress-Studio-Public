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
    guard !findMatchRefreshCoordinator.isPending else { return false }
    return findMatchSnapshot.errorMessage == nil
  }

  func updateEditorScrollPosition(_ position: MarkdownScrollSyncPosition) {
    let normalizedProgress = position.progress
    let equalityTolerance = 0.001
    guard abs(editorScrollProgress - normalizedProgress) >= equalityTolerance else { return }
    editorScrollProgress = normalizedProgress
    saveCurrentEditorSession()
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
    editorScrollRestorationUpdate = MarkdownScrollSyncUpdate(
      source: .editor,
      progress: editorSession.editorScrollProgress
    )
    restoreInvalidFrontMatterDocument(
      editorSession.invalidFrontMatterDocument,
      baseBodyMarkdown: editorSession.invalidFrontMatterBaseBodyMarkdown,
      baseBodyRevision: editorSession.invalidFrontMatterBaseBodyRevision
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
      isFindReplacePresented: isFindReplacePresented,
      findQuery: findQuery,
      replacementText: replacementText,
      isFindCaseSensitive: isFindCaseSensitive,
      isFindWholeWord: isFindWholeWord,
      isFindRegularExpression: isFindRegularExpression,
      invalidFrontMatterDocument: frontMatterIssue == nil ? nil : editorDocument,
      invalidFrontMatterBaseBodyMarkdown: frontMatterIssue == nil
        ? nil
        : (editorSessionState.invalidFrontMatterBaseBodyMarkdown ?? editorBody),
      invalidFrontMatterBaseBodyRevision: frontMatterIssue == nil
        ? nil
        : (editorSessionState.invalidFrontMatterBaseBodyRevision ?? editorBodyRevision)
    )
  }

  func restoreInvalidFrontMatterDocument(
    _ recoveredDocument: String?,
    baseBodyMarkdown: String? = nil,
    baseBodyRevision: UInt64? = nil
  ) {
    guard let recoveredDocument, !recoveredDocument.isEmpty else { return }
    editorSessionState.invalidFrontMatterBaseBodyMarkdown = baseBodyMarkdown ?? editorBody
    editorSessionState.invalidFrontMatterBaseBodyRevision = baseBodyRevision ?? editorBodyRevision
    guard recoveredDocument != editorDocument else { return }
    let previousDocument = editorDocument
    editorDocument = recoveredDocument
    applyEditorDocument(from: previousDocument, to: recoveredDocument)
    selectionActionMessage = String(
      localized: "已恢复上次未保存的 Front Matter 原文，请修正后再切换文章。"
    )
    EditorAccessibilityAnnouncementCenter.announce(selectionActionMessage)
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
    let state = currentEditorSessionState()
    editorSessionState.invalidFrontMatterBaseBodyMarkdown =
      state.invalidFrontMatterBaseBodyMarkdown
    editorSessionState.invalidFrontMatterBaseBodyRevision =
      state.invalidFrontMatterBaseBodyRevision
    store.updateMarkdownEditorSessionState(
      state,
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
    guard !findMatchRefreshCoordinator.isPending else { return "…/…" }
    guard findMatchSnapshot.errorMessage == nil else {
      return "—/—"
    }
    let position = findMatchSnapshot.position(selectedRange: selectedRange)
    return "\(position.currentNumber ?? 0)/\(position.total)"
  }

  var findReplaceFeedbackMessage: String {
    guard !findQuery.isEmpty else { return findReplaceMessage }
    if findMatchRefreshCoordinator.isPending {
      return String(localized: "正在搜索…")
    }
    return findMatchSnapshot.errorMessage ?? findReplaceMessage
  }

  func refreshFindMatchSnapshot() {
    let text = editorBody
    let query = findQuery
    let options = findOptions
    let bodyRevision = editorBodyRevision
    let session = editorSessionState

    // A new request invalidates the previous snapshot immediately. This keeps
    // find-next/replace from acting on a result for an older body or query
    // while the replacement scan is running in the background.
    findMatchSnapshot = .empty
    findMatchRefreshCoordinator.schedule(
      text: text,
      query: query,
      options: options
    ) { [weak session] result in
      guard let session else { return }
      guard session.editorBody == text,
        session.editorBodyRevision == bodyRevision,
        session.findQuery == query,
        MarkdownFindOptions(
          caseSensitive: session.isFindCaseSensitive,
          wholeWord: session.isFindWholeWord,
          usesRegularExpression: session.isFindRegularExpression
        ) == options
      else {
        return
      }
      session.findMatchSnapshot = MarkdownFindMatchSnapshot(
        ranges: result.ranges,
        errorMessage: result.errorMessage
      )
    }
  }

  func cancelFindMatchRefresh() {
    findMatchRefreshCoordinator.cancel()
  }
}
