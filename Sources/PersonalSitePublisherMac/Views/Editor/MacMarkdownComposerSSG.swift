import Foundation
import PublishingWorkbenchCore

struct MarkdownComposerSSGDerivedDataKey: Hashable {
  let bodyRevision: UInt64
  let draftID: UUID
  let siteProfileID: UUID
  let title: String
  let slug: String
  let customSnippets: [MarkdownSnippet]
}

struct MarkdownComposerSSGDerivedData: Sendable {
  let key: MarkdownComposerSSGDerivedDataKey?
  let snippets: [MarkdownSnippet]
  let occurrences: [MarkdownSSGComponentOccurrence]

  static let empty = Self(key: nil, snippets: [], occurrences: [])

  static func make(
    key: MarkdownComposerSSGDerivedDataKey,
    draft: ArticleDraft,
    customSnippets: [MarkdownSnippet]
  ) -> Self {
    let snippets = MarkdownSnippetLibraryService.availableSnippets(
      for: draft.siteProfileID,
      customSnippets: customSnippets
    ).map { snippet in
      var expanded = snippet
      expanded.markdown = MarkdownSnippetLibraryService.expandedMarkdown(
        for: snippet,
        draft: draft
      )
      return expanded
    }
    return Self(
      key: key,
      snippets: snippets,
      occurrences: MarkdownSSGComponentLibraryService.occurrences(
        in: draft.bodyMarkdown
      )
    )
  }
}

extension MacMarkdownComposerView {
  var markdownSSGDerivedDataKey: MarkdownComposerSSGDerivedDataKey {
    MarkdownComposerSSGDerivedDataKey(
      bodyRevision: editorBodyRevision,
      draftID: draft.id,
      siteProfileID: draft.siteProfileID,
      title: draft.title,
      slug: draft.slug,
      customSnippets: editorState.customMarkdownSnippets
    )
  }

  var markdownSSGSnippets: [MarkdownSnippet] {
    guard markdownSSGDerivedData.key == markdownSSGDerivedDataKey else { return [] }
    return markdownSSGDerivedData.snippets
  }

  var markdownSSGComponentOccurrences: [MarkdownSSGComponentOccurrence] {
    guard markdownSSGDerivedData.key == markdownSSGDerivedDataKey else { return [] }
    return markdownSSGDerivedData.occurrences
  }

  @MainActor
  func refreshMarkdownSSGDerivedData(
    for key: MarkdownComposerSSGDerivedDataKey
  ) async {
    do {
      try await Task.sleep(
        for: MarkdownEditorAutomationPolicy.automaticWorkIdleDelay
      )
    } catch {
      return
    }
    guard !Task.isCancelled else { return }

    let requestedDraft = previewDraft
    let derivedData = await Task.detached(priority: .utility) {
      MarkdownComposerSSGDerivedData.make(
        key: key,
        draft: requestedDraft,
        customSnippets: key.customSnippets
      )
    }.value

    guard !Task.isCancelled, markdownSSGDerivedDataKey == key else { return }
    markdownSSGDerivedData = derivedData
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
    selectedRange = occurrence.sourceRange
    markdownTextFocusRequest = MarkdownTextFocusRequest(
      id: UUID(),
      selectedRange: occurrence.sourceRange
    )
    selectionActionMessage = "已定位到第 \(occurrence.lineNumber) 行的\(occurrence.title)。"
  }
}
