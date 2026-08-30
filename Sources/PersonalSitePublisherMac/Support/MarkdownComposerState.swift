import Combine
import Foundation
import PublishingWorkbenchCore

struct MarkdownFindMatchSnapshot: Equatable {
  var ranges: [NSRange]
  var errorMessage: String?

  static let empty = MarkdownFindMatchSnapshot(ranges: [], errorMessage: nil)

  func position(selectedRange: NSRange) -> MarkdownFindPosition {
    guard !ranges.isEmpty else {
      return MarkdownFindPosition(currentNumber: nil, total: 0)
    }
    let currentIndex: Int?
    if let exact = ranges.firstIndex(where: { NSEqualRanges($0, selectedRange) }) {
      currentIndex = exact
    } else {
      currentIndex = ranges.firstIndex(where: { NSIntersectionRange($0, selectedRange).length > 0 })
    }
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
      } else if let nextIndex = ranges.firstIndex(where: {
        $0.location >= NSMaxRange(selectedRange)
      }) {
        target = (nextIndex, false)
      } else {
        target = (0, true)
      }
    case .previous:
      if let currentIndex {
        let previousIndex = currentIndex == 0 ? ranges.count - 1 : currentIndex - 1
        target = (previousIndex, previousIndex >= currentIndex)
      } else if let previousIndex = ranges.lastIndex(where: {
        NSMaxRange($0) <= selectedRange.location
      }) {
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
  /// The cursor service lives for the lifetime of the editor session so
  /// selection changes can reuse the index for the current body revision.
  /// Body replacement explicitly invalidates it because revisions are local
  /// to a draft and can repeat when switching drafts.
  let markdownCursorContextService = MarkdownCursorContextService()

  @Published var editorBody: String {
    didSet {
      markdownCursorContextService.prepareForBodyChange()
    }
  }
  @Published var editorDocument: String
  @Published var isFrontMatterSelection = false
  @Published var frontMatterIssue: MarkdownFrontMatterEditingIssue?
  @Published var ignoredCanonicalFrontMatter: String?
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
  @Published var editorScrollRestorationUpdate: MarkdownScrollSyncUpdate?
  /// Scroll persistence is consumed by AppKit and the debounced session save;
  /// it does not affect the composer's SwiftUI layout. Keeping it outside the
  /// published editor session avoids rebuilding the complete composer during
  /// a scroll while preserving the latest value for restoration.
  var editorScrollProgress: Double
  @Published var editorBodyRevision: UInt64
  /// The body and revision most recently staged from the live NSTextView.
  /// These stay out of SwiftUI publication so keyboard input can reach the
  /// Store before the coalesced editor Binding is committed.
  var liveBodyMarkdown: String
  var liveBodyRevision: UInt64
  var invalidFrontMatterBaseBodyMarkdown: String?
  var invalidFrontMatterBaseBodyRevision: UInt64?
  @Published var markdownCursorContextSnapshot: MarkdownCursorContextSnapshot?
  @Published var markdownCursorCompletionSnapshot: MarkdownCompletionContext?

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
    editorScrollProgress: Double,
    editorBodyRevision: UInt64,
    liveBodyMarkdown: String? = nil,
    liveBodyRevision: UInt64? = nil,
    invalidFrontMatterBaseBodyMarkdown: String? = nil,
    invalidFrontMatterBaseBodyRevision: UInt64? = nil,
    markdownCursorContextSnapshot: MarkdownCursorContextSnapshot? = nil,
    markdownCursorCompletionSnapshot: MarkdownCompletionContext? = nil
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
    self.editorScrollProgress = editorScrollProgress
    self.editorBodyRevision = editorBodyRevision
    self.liveBodyMarkdown = liveBodyMarkdown ?? editorBody
    self.liveBodyRevision = liveBodyRevision ?? editorBodyRevision
    self.invalidFrontMatterBaseBodyMarkdown = invalidFrontMatterBaseBodyMarkdown
    self.invalidFrontMatterBaseBodyRevision = invalidFrontMatterBaseBodyRevision
    self.markdownCursorContextSnapshot = markdownCursorContextSnapshot
    self.markdownCursorCompletionSnapshot = markdownCursorCompletionSnapshot
  }
}

struct MarkdownComposerAttachmentState {
  var isImageDropTargeted = false
  var insertedImageMetadataDrafts: [InsertedImageMetadataDraft] = []
  var activeInsertedImageMetadataID: UUID?
  var importTask: Task<Void, Never>?
  var importRequestID: UUID?
  var automaticImageImportToast: MarkdownAutomaticImageImportToast?
  var automaticImageImportToastTask: Task<Void, Never>?
}

struct MarkdownAutomaticImageImportToast: Equatable, Identifiable {
  let id: UUID
  let message: String

  init(id: UUID = UUID(), message: String) {
    self.id = id
    self.message = message
  }
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

/// Value state for the delayed selection bubble presentation.
///
/// The view owns the actual cancellation-aware task; this type only records
/// the latest selection and whether its delay has completed. Keeping the
/// transition rules here makes rapid selection changes deterministic without
/// making tests depend on wall-clock scheduling.
struct MarkdownSelectionBubblePresentationState: Equatable {
  static let presentationDelay: Duration = .milliseconds(200)

  private(set) var activeSelection: NSRange?
  private(set) var isVisible = false
  private(set) var selectionGeneration: UInt64 = 0

  @discardableResult
  mutating func selectionDidChange(to selection: NSRange) -> UInt64? {
    guard selection.length > 0 else {
      reset()
      return nil
    }

    if let activeSelection, NSEqualRanges(activeSelection, selection) {
      return selectionGeneration
    }

    selectionGeneration &+= 1
    activeSelection = selection
    isVisible = false
    return selectionGeneration
  }

  mutating func reset() {
    selectionGeneration &+= 1
    activeSelection = nil
    isVisible = false
  }

  @discardableResult
  mutating func revealIfCurrentSelection(
    _ selection: NSRange,
    generation: UInt64? = nil
  ) -> Bool {
    guard
      selection.length > 0,
      generation == nil || generation == selectionGeneration,
      let activeSelection,
      NSEqualRanges(activeSelection, selection)
    else {
      return false
    }

    isVisible = true
    return true
  }

  func shouldRender(for selection: NSRange) -> Bool {
    guard
      isVisible,
      selection.length > 0,
      let activeSelection
    else {
      return false
    }
    return NSEqualRanges(activeSelection, selection)
  }
}

/// Stable identity for the cancellation-aware selection presentation task.
/// The draft ID prevents a restored selection in another document from
/// inheriting a previous document's pending or visible bubble.
struct MarkdownSelectionBubbleTaskID: Equatable {
  let draftID: UUID
  let location: Int
  let length: Int

  init(draftID: UUID, selectedRange: NSRange) {
    self.draftID = draftID
    location = selectedRange.location
    length = selectedRange.length
  }
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

  var editorScrollRestorationUpdate: MarkdownScrollSyncUpdate? {
    get { editorSessionState.editorScrollRestorationUpdate }
    nonmutating set { editorSessionState.editorScrollRestorationUpdate = newValue }
  }

  var editorScrollProgress: Double {
    get { editorSessionState.editorScrollProgress }
    nonmutating set { editorSessionState.editorScrollProgress = newValue }
  }

  var editorBodyRevision: UInt64 {
    get { editorSessionState.editorBodyRevision }
    nonmutating set { editorSessionState.editorBodyRevision = newValue }
  }

  var markdownCursorContextSnapshot: MarkdownCursorContextSnapshot? {
    get { editorSessionState.markdownCursorContextSnapshot }
    nonmutating set { editorSessionState.markdownCursorContextSnapshot = newValue }
  }

  var markdownCursorCompletionSnapshot: MarkdownCompletionContext? {
    get { editorSessionState.markdownCursorCompletionSnapshot }
    nonmutating set { editorSessionState.markdownCursorCompletionSnapshot = newValue }
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

  var automaticImageImportToast: MarkdownAutomaticImageImportToast? {
    get { attachmentState.automaticImageImportToast }
    nonmutating set { attachmentState.automaticImageImportToast = newValue }
  }

  var automaticImageImportToastTask: Task<Void, Never>? {
    get { attachmentState.automaticImageImportToastTask }
    nonmutating set { attachmentState.automaticImageImportToastTask = newValue }
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
