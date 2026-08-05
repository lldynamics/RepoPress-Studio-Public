import Combine
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

@MainActor
final class MarkdownComposerEditorSessionState: ObservableObject {
  @Published var editorBody: String
  @Published var editorDocument: String
  @Published var isFrontMatterSelection = false
  @Published var frontMatterIssue: MarkdownFrontMatterEditingIssue?
  @Published var ignoredCanonicalFrontMatter: String?
  @Published var editorStatistics = MarkdownEditorStatistics.empty
  @Published var selectedRange: NSRange
  @Published var isFindReplacePresented: Bool
  @Published var findQuery: String
  @Published var replacementText: String
  @Published var isFindCaseSensitive: Bool
  @Published var isFindWholeWord: Bool
  @Published var isFindRegularExpression: Bool
  @Published var findReplaceMessage = ""
  @Published var findMatchSnapshot: MarkdownFindMatchSnapshot
  @Published var editorEditRequest: MarkdownTextEditRequest?
  @Published var markdownTextFocusRequest: MarkdownTextFocusRequest?
  @Published var scrollSyncUpdate: MarkdownScrollSyncUpdate?
  @Published var editorScrollRestorationUpdate: MarkdownScrollSyncUpdate?
  @Published var previewScrollRestorationUpdate: MarkdownScrollSyncUpdate?
  @Published var editorScrollProgress: Double
  @Published var previewScrollProgress: Double
  @Published var editorBodyRevision: UInt64

  init(
    editorBody: String,
    editorDocument: String,
    selectedRange: NSRange,
    isFindReplacePresented: Bool,
    findQuery: String,
    replacementText: String,
    isFindCaseSensitive: Bool,
    isFindWholeWord: Bool,
    isFindRegularExpression: Bool,
    findMatchSnapshot: MarkdownFindMatchSnapshot,
    editorScrollRestorationUpdate: MarkdownScrollSyncUpdate?,
    previewScrollRestorationUpdate: MarkdownScrollSyncUpdate?,
    editorScrollProgress: Double,
    previewScrollProgress: Double,
    editorBodyRevision: UInt64
  ) {
    self.editorBody = editorBody
    self.editorDocument = editorDocument
    self.selectedRange = selectedRange
    self.isFindReplacePresented = isFindReplacePresented
    self.findQuery = findQuery
    self.replacementText = replacementText
    self.isFindCaseSensitive = isFindCaseSensitive
    self.isFindWholeWord = isFindWholeWord
    self.isFindRegularExpression = isFindRegularExpression
    self.findMatchSnapshot = findMatchSnapshot
    self.editorScrollRestorationUpdate = editorScrollRestorationUpdate
    self.previewScrollRestorationUpdate = previewScrollRestorationUpdate
    self.editorScrollProgress = editorScrollProgress
    self.previewScrollProgress = previewScrollProgress
    self.editorBodyRevision = editorBodyRevision
  }
}

struct MarkdownComposerAttachmentState {
  var isImageDropTargeted = false
  var insertedImageMetadataDrafts: [InsertedImageMetadataDraft] = []
  var activeInsertedImageMetadataID: UUID?
  var importTask: Task<Void, Never>?
  var importRequestID: UUID?
}

struct MarkdownComposerSelectionActionState {
  var activeSelectionAIAction: AIPublishingActionKind?
  var selectionAIActionTask: Task<Void, Never>?
  var selectionAIActionRequestID: UUID?
  var isInlineSelectionAIAction = false
  var isInlineSelectionPaletteDismissed = false
  var inlineGhostText = ""
  var inlineGhostTask: Task<Void, Never>?
  var inlineGhostRequestID: UUID?
  var aiPromptClipboardTask: Task<Void, Never>?
  var aiPromptClipboardRequestID: UUID?
  var selectionActionMessage = ""
  var selectionEditPreview: AIPublishingSelectionEditPreview?
}

enum MarkdownWritingContextPanel: String, CaseIterable, Identifiable {
  case selectionTools
  case aiReview
  case imageInfo
  case outline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .selectionTools:
      return String(localized: "选区工具")
    case .aiReview:
      return String(localized: "AI 审阅")
    case .imageInfo:
      return String(localized: "图片信息")
    case .outline:
      return String(localized: "文章大纲")
    }
  }

  var systemImage: String {
    switch self {
    case .selectionTools:
      return "text.cursor"
    case .aiReview:
      return "sparkles.rectangle.stack"
    case .imageInfo:
      return "photo.badge.checkmark"
    case .outline:
      return "list.bullet.indent"
    }
  }
}

enum MarkdownWritingToolDensity: String, CaseIterable, Identifiable {
  case basic
  case professional

  var id: String { rawValue }

  var title: String {
    switch self {
    case .basic:
      return String(localized: "基础写作")
    case .professional:
      return String(localized: "专业 Markdown")
    }
  }

  var systemImage: String {
    switch self {
    case .basic:
      return "pencil.line"
    case .professional:
      return "chevron.left.forwardslash.chevron.right"
    }
  }
}

struct MarkdownComposerPresentationState {
  var isShortcutHelpPresented = false
  var activeWritingContextPanel: MarkdownWritingContextPanel?
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

  var attachmentImportTask: Task<Void, Never>? {
    get { attachmentState.importTask }
    nonmutating set { attachmentState.importTask = newValue }
  }

  var attachmentImportRequestID: UUID? {
    get { attachmentState.importRequestID }
    nonmutating set { attachmentState.importRequestID = newValue }
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

  var isInlineSelectionAIAction: Bool {
    get { selectionActionState.isInlineSelectionAIAction }
    nonmutating set { selectionActionState.isInlineSelectionAIAction = newValue }
  }

  var isInlineSelectionPaletteDismissed: Bool {
    get { selectionActionState.isInlineSelectionPaletteDismissed }
    nonmutating set { selectionActionState.isInlineSelectionPaletteDismissed = newValue }
  }

  var inlineGhostText: String {
    get { selectionActionState.inlineGhostText }
    nonmutating set { selectionActionState.inlineGhostText = newValue }
  }

  var inlineGhostTask: Task<Void, Never>? {
    get { selectionActionState.inlineGhostTask }
    nonmutating set { selectionActionState.inlineGhostTask = newValue }
  }

  var inlineGhostRequestID: UUID? {
    get { selectionActionState.inlineGhostRequestID }
    nonmutating set { selectionActionState.inlineGhostRequestID = newValue }
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

  var activeWritingContextPanel: MarkdownWritingContextPanel? {
    get { presentationState.activeWritingContextPanel }
    nonmutating set { presentationState.activeWritingContextPanel = newValue }
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
