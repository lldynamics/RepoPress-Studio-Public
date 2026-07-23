import Foundation
import PublishingWorkbenchCore

struct MarkdownFindMatchSnapshot: Equatable {
  var ranges: [NSRange]
  var errorMessage: String?

  static let empty = MarkdownFindMatchSnapshot(ranges: [], errorMessage: nil)

  func position(selectedRange: NSRange) -> MarkdownFindPosition {
    let currentIndex = ranges.firstIndex { NSEqualRanges($0, selectedRange) }
    return MarkdownFindPosition(
      currentNumber: currentIndex.map { $0 + 1 },
      total: ranges.count
    )
  }

  func result(
    selectedRange: NSRange,
    direction: MarkdownFindDirection
  ) -> MarkdownFindResult? {
    guard !ranges.isEmpty else { return nil }
    let currentIndex = ranges.firstIndex { NSEqualRanges($0, selectedRange) }
    let target: (index: Int, didWrap: Bool)
    switch direction {
    case .next:
      if let currentIndex {
        let nextIndex = (currentIndex + 1) % ranges.count
        target = (nextIndex, nextIndex <= currentIndex)
      } else if let nextIndex = ranges.firstIndex(where: { $0.location >= NSMaxRange(selectedRange) }) {
        target = (nextIndex, false)
      } else {
        target = (0, true)
      }
    case .previous:
      if let currentIndex {
        let previousIndex = currentIndex == 0 ? ranges.count - 1 : currentIndex - 1
        target = (previousIndex, previousIndex >= currentIndex)
      } else if let previousIndex = ranges.lastIndex(where: { NSMaxRange($0) <= selectedRange.location }) {
        target = (previousIndex, false)
      } else {
        target = (ranges.count - 1, true)
      }
    }
    return MarkdownFindResult(
      range: ranges[target.index],
      didWrap: target.didWrap,
      currentNumber: target.index + 1,
      total: ranges.count
    )
  }
}

struct MarkdownComposerEditorSessionState {
  var editorBody: String
  var editorDocument: String
  var isFrontMatterSelection = false
  var frontMatterIssue: MarkdownFrontMatterEditingIssue?
  var ignoredCanonicalFrontMatter: String?
  var editorStatistics = MarkdownEditorStatistics.empty
  var selectedRange: NSRange
  var isFindReplacePresented: Bool
  var findQuery: String
  var replacementText: String
  var isFindCaseSensitive: Bool
  var isFindWholeWord: Bool
  var isFindRegularExpression: Bool
  var findReplaceMessage = ""
  var findMatchSnapshot: MarkdownFindMatchSnapshot
  var editorEditRequest: MarkdownTextEditRequest?
  var markdownTextFocusRequest: MarkdownTextFocusRequest?
  var scrollSyncUpdate: MarkdownScrollSyncUpdate?
  var editorScrollRestorationUpdate: MarkdownScrollSyncUpdate?
  var previewScrollRestorationUpdate: MarkdownScrollSyncUpdate?
  var editorScrollProgress: Double
  var previewScrollProgress: Double
  var editorBodyRevision: UInt64
}

struct MarkdownComposerAttachmentState {
  var isImageDropTargeted = false
  var insertedImageMetadataDrafts: [InsertedImageMetadataDraft] = []
  var activeInsertedImageMetadataID: UUID?
}

struct MarkdownComposerSelectionActionState {
  var activeSelectionAIAction: AIPublishingActionKind?
  var selectionAIActionTask: Task<Void, Never>?
  var selectionAIActionRequestID: UUID?
  var aiPromptClipboardTask: Task<Void, Never>?
  var aiPromptClipboardRequestID: UUID?
  var selectionActionMessage = ""
  var selectionEditPreview: AIPublishingSelectionEditPreview?
}

struct MarkdownComposerPresentationState {
  var isShortcutHelpPresented = false
  var isOutlinePresented = false
  var isInternalLinkPickerPresented = false
  var isDiagnosticsPresented = false
  var isSnippetLibraryPresented = false
  var isAITemplateLibraryPresented = false
}

struct MarkdownComposerAnalysisState {
  var markdownAnalysis = MarkdownEditorAnalysisSnapshot.empty
  var markdownAnalysisGeneration: UInt64 = 0
  var appliedMarkdownAnalysisGeneration: UInt64 = 0
  var markdownAnalysisTask: Task<Void, Never>?
}

extension MacMarkdownComposerView {
  var editorBody: String {
    get { editorSessionState.editorBody }
    nonmutating set { editorSessionState.editorBody = newValue }
  }

  var editorDocument: String {
    get { editorSessionState.editorDocument }
    nonmutating set { editorSessionState.editorDocument = newValue }
  }

  var isFrontMatterSelection: Bool {
    get { editorSessionState.isFrontMatterSelection }
    nonmutating set { editorSessionState.isFrontMatterSelection = newValue }
  }

  var frontMatterIssue: MarkdownFrontMatterEditingIssue? {
    get { editorSessionState.frontMatterIssue }
    nonmutating set { editorSessionState.frontMatterIssue = newValue }
  }

  var ignoredCanonicalFrontMatter: String? {
    get { editorSessionState.ignoredCanonicalFrontMatter }
    nonmutating set { editorSessionState.ignoredCanonicalFrontMatter = newValue }
  }

  var editorStatistics: MarkdownEditorStatistics {
    get { editorSessionState.editorStatistics }
    nonmutating set { editorSessionState.editorStatistics = newValue }
  }

  var selectedRange: NSRange {
    get { editorSessionState.selectedRange }
    nonmutating set { editorSessionState.selectedRange = newValue }
  }

  var isFindReplacePresented: Bool {
    get { editorSessionState.isFindReplacePresented }
    nonmutating set { editorSessionState.isFindReplacePresented = newValue }
  }

  var findQuery: String {
    get { editorSessionState.findQuery }
    nonmutating set { editorSessionState.findQuery = newValue }
  }

  var replacementText: String {
    get { editorSessionState.replacementText }
    nonmutating set { editorSessionState.replacementText = newValue }
  }

  var isFindCaseSensitive: Bool {
    get { editorSessionState.isFindCaseSensitive }
    nonmutating set { editorSessionState.isFindCaseSensitive = newValue }
  }

  var isFindWholeWord: Bool {
    get { editorSessionState.isFindWholeWord }
    nonmutating set { editorSessionState.isFindWholeWord = newValue }
  }

  var isFindRegularExpression: Bool {
    get { editorSessionState.isFindRegularExpression }
    nonmutating set { editorSessionState.isFindRegularExpression = newValue }
  }

  var findReplaceMessage: String {
    get { editorSessionState.findReplaceMessage }
    nonmutating set { editorSessionState.findReplaceMessage = newValue }
  }

  var findMatchSnapshot: MarkdownFindMatchSnapshot {
    get { editorSessionState.findMatchSnapshot }
    nonmutating set { editorSessionState.findMatchSnapshot = newValue }
  }

  var editorEditRequest: MarkdownTextEditRequest? {
    get { editorSessionState.editorEditRequest }
    nonmutating set { editorSessionState.editorEditRequest = newValue }
  }

  var markdownTextFocusRequest: MarkdownTextFocusRequest? {
    get { editorSessionState.markdownTextFocusRequest }
    nonmutating set { editorSessionState.markdownTextFocusRequest = newValue }
  }

  var scrollSyncUpdate: MarkdownScrollSyncUpdate? {
    get { editorSessionState.scrollSyncUpdate }
    nonmutating set { editorSessionState.scrollSyncUpdate = newValue }
  }

  var editorScrollRestorationUpdate: MarkdownScrollSyncUpdate? {
    get { editorSessionState.editorScrollRestorationUpdate }
    nonmutating set { editorSessionState.editorScrollRestorationUpdate = newValue }
  }

  var previewScrollRestorationUpdate: MarkdownScrollSyncUpdate? {
    get { editorSessionState.previewScrollRestorationUpdate }
    nonmutating set { editorSessionState.previewScrollRestorationUpdate = newValue }
  }

  var editorScrollProgress: Double {
    get { editorSessionState.editorScrollProgress }
    nonmutating set { editorSessionState.editorScrollProgress = newValue }
  }

  var previewScrollProgress: Double {
    get { editorSessionState.previewScrollProgress }
    nonmutating set { editorSessionState.previewScrollProgress = newValue }
  }

  var editorBodyRevision: UInt64 {
    get { editorSessionState.editorBodyRevision }
    nonmutating set { editorSessionState.editorBodyRevision = newValue }
  }

  var isImageDropTargeted: Bool {
    get { attachmentState.isImageDropTargeted }
    nonmutating set { attachmentState.isImageDropTargeted = newValue }
  }

  var insertedImageMetadataDrafts: [InsertedImageMetadataDraft] {
    get { attachmentState.insertedImageMetadataDrafts }
    nonmutating set { attachmentState.insertedImageMetadataDrafts = newValue }
  }

  var activeInsertedImageMetadataID: UUID? {
    get { attachmentState.activeInsertedImageMetadataID }
    nonmutating set { attachmentState.activeInsertedImageMetadataID = newValue }
  }

  var activeSelectionAIAction: AIPublishingActionKind? {
    get { selectionActionState.activeSelectionAIAction }
    nonmutating set { selectionActionState.activeSelectionAIAction = newValue }
  }

  var selectionAIActionTask: Task<Void, Never>? {
    get { selectionActionState.selectionAIActionTask }
    nonmutating set { selectionActionState.selectionAIActionTask = newValue }
  }

  var selectionAIActionRequestID: UUID? {
    get { selectionActionState.selectionAIActionRequestID }
    nonmutating set { selectionActionState.selectionAIActionRequestID = newValue }
  }

  var aiPromptClipboardTask: Task<Void, Never>? {
    get { selectionActionState.aiPromptClipboardTask }
    nonmutating set { selectionActionState.aiPromptClipboardTask = newValue }
  }

  var aiPromptClipboardRequestID: UUID? {
    get { selectionActionState.aiPromptClipboardRequestID }
    nonmutating set { selectionActionState.aiPromptClipboardRequestID = newValue }
  }

  var selectionActionMessage: String {
    get { selectionActionState.selectionActionMessage }
    nonmutating set { selectionActionState.selectionActionMessage = newValue }
  }

  var selectionEditPreview: AIPublishingSelectionEditPreview? {
    get { selectionActionState.selectionEditPreview }
    nonmutating set { selectionActionState.selectionEditPreview = newValue }
  }

  var isShortcutHelpPresented: Bool {
    get { presentationState.isShortcutHelpPresented }
    nonmutating set { presentationState.isShortcutHelpPresented = newValue }
  }

  var isOutlinePresented: Bool {
    get { presentationState.isOutlinePresented }
    nonmutating set { presentationState.isOutlinePresented = newValue }
  }

  var isInternalLinkPickerPresented: Bool {
    get { presentationState.isInternalLinkPickerPresented }
    nonmutating set { presentationState.isInternalLinkPickerPresented = newValue }
  }

  var isDiagnosticsPresented: Bool {
    get { presentationState.isDiagnosticsPresented }
    nonmutating set { presentationState.isDiagnosticsPresented = newValue }
  }

  var isSnippetLibraryPresented: Bool {
    get { presentationState.isSnippetLibraryPresented }
    nonmutating set { presentationState.isSnippetLibraryPresented = newValue }
  }

  var isAITemplateLibraryPresented: Bool {
    get { presentationState.isAITemplateLibraryPresented }
    nonmutating set { presentationState.isAITemplateLibraryPresented = newValue }
  }

  var markdownAnalysis: MarkdownEditorAnalysisSnapshot {
    get { analysisState.markdownAnalysis }
    nonmutating set { analysisState.markdownAnalysis = newValue }
  }

  var markdownAnalysisGeneration: UInt64 {
    get { analysisState.markdownAnalysisGeneration }
    nonmutating set { analysisState.markdownAnalysisGeneration = newValue }
  }

  var appliedMarkdownAnalysisGeneration: UInt64 {
    get { analysisState.appliedMarkdownAnalysisGeneration }
    nonmutating set { analysisState.appliedMarkdownAnalysisGeneration = newValue }
  }

  var markdownAnalysisTask: Task<Void, Never>? {
    get { analysisState.markdownAnalysisTask }
    nonmutating set { analysisState.markdownAnalysisTask = newValue }
  }
}
