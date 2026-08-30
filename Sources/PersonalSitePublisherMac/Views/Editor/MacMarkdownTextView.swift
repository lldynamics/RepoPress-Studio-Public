import AppKit
import OSLog
import PublishingWorkbenchCore
import SwiftUI

struct MarkdownTextEditRequest: Equatable {
  let id: UUID
  let expectedText: String
  let edit: MarkdownSmartEdit

  init(expectedText: String, edit: MarkdownSmartEdit) {
    id = UUID()
    self.expectedText = expectedText
    self.edit = edit
  }
}

struct MarkdownTextEditRequestOutcome: Equatable {
  let id: UUID
  let wasApplied: Bool
}

struct MarkdownTextFocusRequest: Equatable {
  let id: UUID
  let selectedRange: NSRange
}

/// Immutable, paint-only input for the editor's current structured-review
/// hunk. The text storage remains the source Markdown and is never decorated.
struct MarkdownEditorInlineAIReviewPresentation: Equatable {
  let hunkID: String
  let bodyRange: NSRange
  let replacementText: String
}

enum MarkdownGhostTextCommandPolicy {
  static func shouldAccept(
    ghostText: String,
    selectedRange: NSRange,
    bodyUTF16Offset: Int,
    hasMarkedText: Bool
  ) -> Bool {
    !hasMarkedText && !ghostText.isEmpty && selectedRange.length == 0
      && selectedRange.location >= bodyUTF16Offset
  }

  static func shouldDismiss(ghostText: String, hasMarkedText: Bool) -> Bool {
    !hasMarkedText && !ghostText.isEmpty
  }
}

struct MarkdownSyntaxHighlightComputation: Sendable {
  let text: String
  let revision: UInt64
  let plan: MarkdownSyntaxHighlightPlan
  let snapshot: MarkdownSyntaxHighlightSnapshot
  let runIndex: MarkdownSyntaxHighlightRunIndex
  let synchronizedTree: Bool
  let parserMetrics: MarkdownSyntaxHighlightParserMetrics
}

enum MarkdownSyntaxViewportRepaintReason: Equatable, Sendable {
  case content
  case viewport
  case selection
  case appearance

  var requiresFullRepaint: Bool {
    self == .appearance
  }

  var preservesInlineAttachmentDrawings: Bool {
    self == .viewport || self == .selection
  }
}

struct MacMarkdownTextView: NSViewRepresentable {
  @Binding var text: String
  var bodyMarkdown: String
  var bodyUTF16Offset: Int
  var allowsLiveBodyChanges: Bool = true
  @Binding var selectedRange: NSRange
  @Binding var isFrontMatterSelection: Bool
  var comfortConfiguration: MarkdownEditorComfortConfiguration
  var diagnostics: [MarkdownInlineDiagnostic]
  var attachments: [DraftAttachment]
  var readOnlyNativePresentationEnabled =
    MarkdownTextKit2ReadOnlyPresentationPolicy.isEnabled
  var editRequest: MarkdownTextEditRequest?
  var focusRequest: MarkdownTextFocusRequest?
  var inlineAIReviewPresentation: MarkdownEditorInlineAIReviewPresentation? = nil
  var ghostText: String
  var ssgSnippets: [MarkdownSnippet]
  var scrollSyncUpdate: MarkdownScrollSyncUpdate?
  var scrollRestorationUpdate: MarkdownScrollSyncUpdate?
  var onStatisticsChanged: (MarkdownEditorStatistics) -> Void
  var onFileDropTargetChanged: (Bool) -> Void
  var onPasteMessage: (String) -> Void
  var onEditRequestHandled: (MarkdownTextEditRequestOutcome) -> Void
  var onGhostTextAccepted: (String) -> Void
  var onGhostTextDismissed: () -> Void
  var onInlineAICompletionRequested: () -> Void
  var onSSGSnippetShortcut: (MarkdownCompletionCandidate) -> Void
  var onSlashCommandKey: (MarkdownSlashCommandKey) -> Bool = { _ in false }
  var onLiveBodyChange: (String, String) -> Void = { _, _ in }
  var onScrollPositionChanged: (MarkdownScrollSyncPosition) -> Void
  var onDroppedFiles: ([URL]) -> Void
  var onDroppedMarkdown: (String, NSRange, KnowledgeCitation?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      text: $text,
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset,
      allowsLiveBodyChanges: allowsLiveBodyChanges,
      selectedRange: $selectedRange,
      isFrontMatterSelection: $isFrontMatterSelection,
      comfortConfiguration: comfortConfiguration,
      diagnostics: diagnostics,
      attachments: attachments,
      readOnlyNativePresentationEnabled: readOnlyNativePresentationEnabled,
      ghostText: ghostText,
      inlineAIReviewPresentation: inlineAIReviewPresentation,
      ssgSnippets: ssgSnippets,
      onStatisticsChanged: onStatisticsChanged,
      onPasteMessage: onPasteMessage,
      onGhostTextAccepted: onGhostTextAccepted,
      onGhostTextDismissed: onGhostTextDismissed,
      onSSGSnippetShortcut: onSSGSnippetShortcut,
      onLiveBodyChange: onLiveBodyChange,
      onScrollPositionChanged: onScrollPositionChanged,
      onDroppedFiles: onDroppedFiles,
      onDroppedMarkdown: onDroppedMarkdown
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = MarkdownEditorScrollView()
    let editorBackgroundColor = WorkbenchWritingSurface.nsColor(
      usesWarmPaper: comfortConfiguration.warmPaperBackgroundEnabled
    )
    scrollView.preferredBodyWidth = CGFloat(comfortConfiguration.bodyWidth)
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = true
    scrollView.backgroundColor = editorBackgroundColor

    let textView = DroppableMarkdownTextView.makeTextKit2(
      containerSize: NSSize(
        width: max(scrollView.contentSize.width, 1),
        height: CGFloat.greatestFiniteMagnitude
      )
    )
    precondition(
      textView.textLayoutManager != nil,
      "Markdown editor requires a TextKit 2 layout manager"
    )
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.heightTracksTextView = false
    Self.configureAccessibility(for: textView)
    textView.fileDropTargetChangedHandler = onFileDropTargetChanged
    textView.fileDropHandler = { urls, dropRange in
      context.coordinator.handleDroppedFiles(urls, at: dropRange)
    }
    textView.knowledgeMarkdownDropHandler = { markdown, dropRange, citation in
      context.coordinator.handleDroppedMarkdown(markdown, at: dropRange, citation: citation)
    }
    textView.smartPasteHandler = { textView, pasteboard in
      context.coordinator.handlePaste(in: textView, pasteboard: pasteboard)
    }
    textView.markdownFormattingHandler = { textView, command in
      context.coordinator.handleFormatting(command, in: textView)
    }
    textView.markdownLineEditingHandler = { textView, command in
      context.coordinator.handleLineEditing(command, in: textView)
    }
    textView.markdownTableContextProvider = { textView in
      context.coordinator.tableContext(in: textView)
    }
    textView.markdownTableEditingHandler = { textView, command in
      context.coordinator.handleTableEditing(command, in: textView)
    }
    textView.slashCommandKeyHandler = onSlashCommandKey
    textView.inlineAIRequestHandler = onInlineAICompletionRequested
    textView.string = text
    let initialSelection =
      isFrontMatterSelection
      ? Self.clamped(selectedRange, length: (text as NSString).length)
      : documentRange(
        forBodyRange: selectedRange,
        bodyUTF16Offset: bodyUTF16Offset,
        documentLength: (text as NSString).length
      )
    textView.setSelectedRange(initialSelection)
    // Install the delegate only after the represented text and selection are
    // synchronized. AppKit emits selection callbacks while assigning the
    // initial string; writing those values back into @Published bindings from
    // makeNSView would publish during SwiftUI's current update transaction.
    textView.delegate = context.coordinator
    textView.isEditable = true
    textView.isSelectable = true
    textView.isRichText = true
    textView.importsGraphics = false
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isContinuousSpellCheckingEnabled = comfortConfiguration.spellCheckEnabled
    textView.allowsUndo = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    textView.textColor = NSColor.labelColor
    textView.insertionPointColor = NSColor.controlAccentColor
    textView.backgroundColor = editorBackgroundColor
    textView.drawsBackground = true
    context.coordinator.applyCachedSyntaxAppearance(in: textView)
    textView.textContainerInset = NSSize(width: 16, height: 16)
    textView.frame = NSRect(
      origin: .zero,
      size: NSSize(
        width: max(scrollView.contentSize.width, 1), height: max(scrollView.contentSize.height, 1))
    )
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [NSView.AutoresizingMask.width]
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false

    context.coordinator.installGhostTextOverlay(on: textView)
    context.coordinator.configureReadOnlyPresentationFocusBridge(on: textView)
    scrollView.documentView = textView
    context.coordinator.observeScrolling(in: scrollView)
    context.coordinator.scheduleFullStatistics(for: bodyMarkdown, isInitialLoad: true)
    context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    context.coordinator.updateDiagnostics(diagnostics, in: textView, force: true)
    context.coordinator.updateCurrentParagraphHighlight(in: textView, force: true)
    context.coordinator.updateGhostText(ghostText, in: textView)
    context.coordinator.scheduleReadOnlyPresentationIfNeeded(in: textView)
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? NSTextView else { return }
    let presentationContextChanged =
      context.coordinator.bodyMarkdown != bodyMarkdown
      || context.coordinator.bodyUTF16Offset != bodyUTF16Offset
      || context.coordinator.attachments != attachments
      || context.coordinator.comfortConfiguration != comfortConfiguration
      || context.coordinator.inlineAIReviewPresentation != inlineAIReviewPresentation
    let didReceiveChangedText = context.coordinator.updateRepresentedText(text)
    let hasPendingEditRequest =
      editRequest.map {
        $0.id != context.coordinator.lastAppliedEditRequestID
      } ?? false
    let hasPendingFocusRequest =
      focusRequest.map {
        $0.id != context.coordinator.lastAppliedFocusRequestID
      } ?? false
    context.coordinator.updateReadOnlyPresentationPolicy(
      isEnabled: readOnlyNativePresentationEnabled,
      in: textView
    )
    if context.coordinator.isShowingReadOnlyPresentation,
      didReceiveChangedText
        || presentationContextChanged
        || hasPendingEditRequest
        || hasPendingFocusRequest
    {
      context.coordinator.restoreEditableMarkdown(in: textView)
    }
    context.coordinator.updateDocumentContext(
      bodyMarkdown: bodyMarkdown,
      bodyUTF16Offset: bodyUTF16Offset,
      allowsLiveBodyChanges: allowsLiveBodyChanges,
      attachments: attachments,
      in: textView
    )
    context.coordinator.ssgSnippets = ssgSnippets
    context.coordinator.onGhostTextAccepted = onGhostTextAccepted
    context.coordinator.onGhostTextDismissed = onGhostTextDismissed
    context.coordinator.updateInlineAIReviewPresentation(
      inlineAIReviewPresentation,
      in: textView
    )
    context.coordinator.onSSGSnippetShortcut = onSSGSnippetShortcut
    context.coordinator.applyComfortConfiguration(
      comfortConfiguration,
      in: textView
    )
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      context.coordinator.configureReadOnlyPresentationFocusBridge(on: droppableTextView)
      droppableTextView.fileDropTargetChangedHandler = onFileDropTargetChanged
      droppableTextView.knowledgeMarkdownDropHandler = { markdown, dropRange, citation in
        context.coordinator.handleDroppedMarkdown(markdown, at: dropRange, citation: citation)
      }
      droppableTextView.smartPasteHandler = { textView, pasteboard in
        context.coordinator.handlePaste(in: textView, pasteboard: pasteboard)
      }
      droppableTextView.markdownFormattingHandler = { textView, command in
        context.coordinator.handleFormatting(command, in: textView)
      }
      droppableTextView.markdownLineEditingHandler = { textView, command in
        context.coordinator.handleLineEditing(command, in: textView)
      }
      droppableTextView.markdownTableContextProvider = { textView in
        context.coordinator.tableContext(in: textView)
      }
      droppableTextView.markdownTableEditingHandler = { textView, command in
        context.coordinator.handleTableEditing(command, in: textView)
      }
      droppableTextView.slashCommandKeyHandler = onSlashCommandKey
      droppableTextView.inlineAIRequestHandler = onInlineAICompletionRequested
      // NSTextViewDelegate.doCommandBy is the sole ghost command owner. A
      // second keyDown route would schedule duplicate completion insertions.
      droppableTextView.ghostTextAcceptHandler = nil
      droppableTextView.ghostTextDismissHandler = nil
    }

    if context.coordinator.isShowingReadOnlyPresentation {
      textView.isEditable = false
      textView.isSelectable = true
      textView.usesFindBar = false
      textView.isIncrementalSearchingEnabled = false
      context.coordinator.applyReadOnlyPresentationSelection(
        selectedRange: selectedRange,
        isFrontMatterSelection: isFrontMatterSelection,
        in: textView
      )
      context.coordinator.suspendGhostTextOverlay(ghostText, in: textView)
      return
    }

    textView.isEditable = true
    textView.isSelectable = true
    textView.usesFindBar = true
    textView.isIncrementalSearchingEnabled = true
    let didReplaceText = didReceiveChangedText && textView.string != text
    if didReplaceText {
      let currentDocumentRange = textView.selectedRange()
      context.coordinator.syntaxDocumentRevision &+= 1
      context.coordinator.pendingSyntaxParserEdit = nil
      context.coordinator.isApplyingRepresentedText = true
      textView.string = text
      context.coordinator.isApplyingRepresentedText = false
      (nsView as? MarkdownEditorScrollView)?.invalidateDocumentHeight(immediately: true)
      let replacementRange =
        isFrontMatterSelection
        ? clamped(currentDocumentRange, length: (text as NSString).length)
        : documentRange(
          forBodyRange: selectedRange,
          bodyUTF16Offset: bodyUTF16Offset,
          documentLength: (text as NSString).length
        )
      textView.setSelectedRange(replacementRange)
      context.coordinator.invalidateHighlightedTextCache(in: textView)
      context.coordinator.scheduleFullStatistics(for: bodyMarkdown)
      context.coordinator.scheduleMarkdownSyntaxHighlighting(for: textView, text: text)
    }

    let shouldApplyRepresentedSelection = context.coordinator.shouldApplyRepresentedSelection(
      selectedRange: selectedRange,
      isFrontMatterSelection: isFrontMatterSelection,
      in: textView
    )
    if shouldApplyRepresentedSelection, !isFrontMatterSelection {
      let range = documentRange(
        forBodyRange: selectedRange,
        bodyUTF16Offset: bodyUTF16Offset,
        documentLength: (textView.string as NSString).length
      )
      if textView.selectedRange() != range {
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
      }
    }
    context.coordinator.updateDiagnostics(
      diagnostics,
      in: textView,
      force: didReplaceText
    )
    context.coordinator.updateCurrentParagraphHighlight(
      in: textView,
      force: didReplaceText
    )

    context.coordinator.refreshCachedTypingAttributes(in: textView)
    context.coordinator.updateGhostText(ghostText, in: textView)
    if let outcome = context.coordinator.handle(editRequest, in: textView) {
      DispatchQueue.main.async {
        onEditRequestHandled(outcome)
      }
    }
    context.coordinator.requestKeyboardFocus(focusRequest, in: textView)
    context.coordinator.applySynchronizedScroll(scrollSyncUpdate, in: nsView)
    context.coordinator.applyRestoredScroll(scrollRestorationUpdate, in: nsView)
    context.coordinator.scheduleReadOnlyPresentationIfNeeded(in: textView)
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.flushPendingBindingWrites()
    coordinator.inlineAttachmentDrawingApplicationTask?.cancel()
    coordinator.cancelReadOnlyPresentationTasks()
    if let textView = nsView.documentView as? DroppableMarkdownTextView {
      textView.willBecomeFirstResponderHandler = nil
      textView.didResignFirstResponderHandler = nil
      textView.inlineAIRequestHandler = nil
      textView.delegate = nil
    } else {
      (nsView.documentView as? NSTextView)?.delegate = nil
    }
    coordinator.scrollSyncBridge.invalidate()
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    @Binding var isFrontMatterSelection: Bool
    var bodyMarkdown: String
    var bodyUTF16Offset: Int
    var requiresFrontMatterEnvelope: Bool
    var hasValidDocumentBodyMapping: Bool
    var allowsLiveBodyChanges: Bool
    var isAwaitingDocumentValidation = false
    var bodyLineUTF16Offsets: [Int]
    var representedText: String
    let onStatisticsChanged: (MarkdownEditorStatistics) -> Void
    let onPasteMessage: (String) -> Void
    var onGhostTextAccepted: (String) -> Void
    var onGhostTextDismissed: () -> Void
    var onSSGSnippetShortcut: (MarkdownCompletionCandidate) -> Void
    let onScrollPositionChanged: (MarkdownScrollSyncPosition) -> Void
    let onDroppedFiles: ([URL]) -> Void
    let onDroppedMarkdown: (String, NSRange, KnowledgeCitation?) -> Void
    let onLiveBodyChange: (String, String) -> Void
    weak var textView: NSTextView?
    let syntaxHighlightDebouncer = MarkdownSyntaxHighlightDebouncer()
    let syntaxTreeSynchronizationDebouncer = MarkdownSyntaxHighlightDebouncer()
    var syntaxAttributeApplicationTask: Task<Void, Never>?
    var syntaxAttributeApplicationGeneration: UInt64 = 0
    var inlineAttachmentDrawingApplicationTask: Task<Void, Never>?
    var inlineAttachmentDrawingApplicationGeneration: UInt64 = 0
    var syntaxParsedSnapshotCache: MarkdownSyntaxHighlightSnapshot?
    var syntaxParsedRunIndex: MarkdownSyntaxHighlightRunIndex?
    var syntaxPaintedDocumentRevision: UInt64?
    var paintedSyntaxViewportRange: NSRange?
    var paintedSyntaxSelectionRange: NSRange?
    var collapsedSyntaxMarkerRanges: [NSRange] = []
    var pendingSyntaxHighlightPlan: MarkdownSyntaxHighlightPlan?
    var syntaxCodeBlockRanges: [NSRange]?
    var syntaxDocumentRevision: UInt64 = 0
    var syntaxParsedDocumentRevision: UInt64?
    var syntaxTreeDocumentRevision: UInt64?
    var pendingSyntaxParserEdit: MarkdownSyntaxHighlightEditAccumulator?
    let syntaxHighlightParser = MarkdownSyntaxHighlightParser()
    let syntaxHighlightSignposter = OSSignposter(
      subsystem: "com.jinfang.PersonalSitePublisherMac",
      category: "MarkdownSyntax"
    )
    let syntaxHighlightLogger = Logger(
      subsystem: "com.jinfang.PersonalSitePublisherMac",
      category: "MarkdownSyntax"
    )
    var hasLoggedSyntaxTelemetryActivation = false
    var loggedSyntaxFallbackCount = 0
    var statisticsTask: Task<Void, Never>?
    var statisticsGeneration = 0
    var statisticsText: String?
    var statistics = MarkdownEditorStatistics.empty
    // These counters make the editor's update path observable in focused
    // AppKit tests. They are intentionally kept on the coordinator so tests
    // can distinguish a local delta from a scheduled document-wide scan.
    var statisticsFullScanCount = 0
    var statisticsIncrementalUpdateCount = 0
    var pendingTextEdit: MarkdownTextEdit?
    var pendingTextEditRequiresInference = false
    var isApplyingRepresentedText = false
    var lastCommittedText: String
    var lastCommittedSelectedRange: NSRange
    var lastCommittedIsFrontMatterSelection: Bool
    var pendingTextBindingValue: String?
    var pendingSelectedRangeBindingValue: NSRange?
    var pendingFrontMatterBindingValue: Bool?
    var bindingFlushTask: Task<Void, Never>?
    var lastAppliedEditRequestID: UUID?
    var pendingFocusRequest: MarkdownTextFocusRequest?
    var lastAppliedFocusRequestID: UUID?
    var focusRequestTask: Task<Void, Never>?
    var ghostText = ""
    var inlineAIReviewPresentation: MarkdownEditorInlineAIReviewPresentation?
    var ssgSnippets: [MarkdownSnippet]
    weak var ghostTextOverlayView: MarkdownGhostTextOverlayView?
    var comfortConfiguration: MarkdownEditorComfortConfiguration
    var syntaxHighlightPalette: MarkdownTextViewSyntaxPalette
    var diagnostics: [MarkdownInlineDiagnostic]
    var attachments: [DraftAttachment]
    var readOnlyNativePresentationEnabled: Bool
    var readOnlyPresentationDocument: MarkdownTextKit2PresentationDocument?
    var readOnlyPresentationSourceSelection: NSRange?
    var readOnlyPresentationEditableAttributedSnapshot: NSAttributedString?
    var readOnlyPresentationCachedOutput: MarkdownTextKit2ReadOnlyPresentationFactory.Output?
    var readOnlyPresentationCachedBodyMarkdown: String?
    var readOnlyPresentationCachedBodyUTF16Offset: Int?
    var readOnlyPresentationCachedAttachments: [DraftAttachment] = []
    var readOnlyPresentationCachedAvailableWidth: CGFloat?
    var readOnlyPresentationCachedBaseFontSize: CGFloat?
    var readOnlyPresentationTask: Task<Void, Never>?
    var readOnlyPresentationImageTasks: [Task<Void, Never>] = []
    var inlineAttachmentDrawingDescriptors: [String: MarkdownInlineAttachmentDrawing] = [:]
    var inlineAttachmentImageTasks: [String: Task<Void, Never>] = [:]
    var inlineAttachmentPaintedRanges: [NSRange] = []
    var inlineAttachmentFailedImagePaths: Set<String> = []
    var inlineAttachmentImageURLCache: [String: URL] = [:]
    var inlineAttachmentUnsupportedImagePaths: Set<String> = []
    var inlineAttachmentPlan: MarkdownInlineAttachmentPlan?
    var inlineAttachmentPlanDocumentRevision: UInt64?
    var inlineAttachmentPlanBodyUTF16Offset: Int?
    var inlineAttachmentPlanComputationCount = 0
    var inlineAttachmentPlanIncrementalUpdateCount = 0
    var inlineAttachmentReferenceLookupCache: [String: DraftAttachment]?
    var appliedParagraphHighlightRange: NSRange?
    var appliedDiagnosticOverlays: [MarkdownEditorDiagnosticOverlay] = []
    var cachedDocumentDiagnosticOverlays: [MarkdownEditorDiagnosticOverlay] = []
    var cachedDiagnosticOverlayRevision: UInt64?
    var cachedDiagnosticOverlayBodyUTF16Offset: Int?
    var cachedDiagnosticOverlayDocumentLength: Int?
    let scrollSyncBridge: MarkdownScrollViewSyncBridge
    let smartEditingService = MarkdownSmartEditingService()
    let smartPasteService = MarkdownSmartPasteService()
    let richTextPasteService = MarkdownRichTextPasteService()
    let formattingService = MarkdownFormattingService()
    let advancedEditingService = MarkdownAdvancedEditingService()
    let tableEditingService = MarkdownTableEditingService()
    let pastedImageFileStore = PastedImageFileStore()
    // Keep SwiftUI-facing publications on trailing idle edges instead of the
    // 120 ms input cadence used by the performance scenario. Matching that
    // cadence made binding flushes race the next AppKit edit, while the old
    // 180 ms statistics delivery could start a second window-wide layout.
    // The live body channel above still stages every accepted edit immediately.
    let bindingFlushDelay: TimeInterval = 0.24
    let statisticsDelay = MarkdownEditorStatisticsDelayPolicy.incrementalDeliveryDelay
    var isApplyingAutomaticPairing = false

    init(
      text: Binding<String>,
      bodyMarkdown: String,
      bodyUTF16Offset: Int,
      allowsLiveBodyChanges: Bool = true,
      selectedRange: Binding<NSRange>,
      isFrontMatterSelection: Binding<Bool>,
      comfortConfiguration: MarkdownEditorComfortConfiguration,
      diagnostics: [MarkdownInlineDiagnostic],
      attachments: [DraftAttachment] = [],
      readOnlyNativePresentationEnabled: Bool = false,
      ghostText: String,
      inlineAIReviewPresentation: MarkdownEditorInlineAIReviewPresentation? = nil,
      ssgSnippets: [MarkdownSnippet],
      onStatisticsChanged: @escaping (MarkdownEditorStatistics) -> Void,
      onPasteMessage: @escaping (String) -> Void,
      onGhostTextAccepted: @escaping (String) -> Void,
      onGhostTextDismissed: @escaping () -> Void,
      onSSGSnippetShortcut: @escaping (MarkdownCompletionCandidate) -> Void,
      onLiveBodyChange: @escaping (String, String) -> Void = { _, _ in },
      onScrollPositionChanged: @escaping (MarkdownScrollSyncPosition) -> Void,
      onDroppedFiles: @escaping ([URL]) -> Void,
      onDroppedMarkdown: @escaping (String, NSRange, KnowledgeCitation?) -> Void
    ) {
      _text = text
      self.bodyMarkdown = bodyMarkdown
      self.bodyUTF16Offset = bodyUTF16Offset
      let hasDelimitedFrontMatter = Self.documentParts(in: text.wrappedValue) != nil
      requiresFrontMatterEnvelope = bodyUTF16Offset > 0 || hasDelimitedFrontMatter
      hasValidDocumentBodyMapping = !requiresFrontMatterEnvelope || hasDelimitedFrontMatter
      self.allowsLiveBodyChanges = allowsLiveBodyChanges
      bodyLineUTF16Offsets = Self.lineUTF16Offsets(in: bodyMarkdown)
      representedText = text.wrappedValue
      _selectedRange = selectedRange
      _isFrontMatterSelection = isFrontMatterSelection
      lastCommittedText = text.wrappedValue
      lastCommittedSelectedRange = selectedRange.wrappedValue
      lastCommittedIsFrontMatterSelection = isFrontMatterSelection.wrappedValue
      self.onLiveBodyChange = onLiveBodyChange
      self.comfortConfiguration = comfortConfiguration
      syntaxHighlightPalette = MarkdownTextViewSyntaxPalette(
        configuration: comfortConfiguration
      )
      self.diagnostics = diagnostics
      self.attachments = attachments
      self.readOnlyNativePresentationEnabled = readOnlyNativePresentationEnabled
      self.onStatisticsChanged = onStatisticsChanged
      self.onPasteMessage = onPasteMessage
      self.onGhostTextAccepted = onGhostTextAccepted
      self.onGhostTextDismissed = onGhostTextDismissed
      self.onSSGSnippetShortcut = onSSGSnippetShortcut
      self.onScrollPositionChanged = onScrollPositionChanged
      self.onDroppedFiles = onDroppedFiles
      self.onDroppedMarkdown = onDroppedMarkdown
      self.ghostText = ghostText
      self.inlineAIReviewPresentation = inlineAIReviewPresentation
      self.ssgSnippets = ssgSnippets
      scrollSyncBridge = MarkdownScrollViewSyncBridge(
        source: .editor,
        onPositionChanged: onScrollPositionChanged
      )
    }

    convenience init(
      text: Binding<String>,
      bodyMarkdown: String,
      bodyUTF16Offset: Int,
      selectedRange: Binding<NSRange>,
      isFrontMatterSelection: Binding<Bool>,
      comfortConfiguration: MarkdownEditorComfortConfiguration,
      diagnostics: [MarkdownInlineDiagnostic],
      onStatisticsChanged: @escaping (MarkdownEditorStatistics) -> Void,
      onPasteMessage: @escaping (String) -> Void,
      onLiveBodyChange: @escaping (String, String) -> Void = { _, _ in },
      onScrollPositionChanged: @escaping (MarkdownScrollSyncPosition) -> Void,
      onDroppedFiles: @escaping ([URL]) -> Void
    ) {
      self.init(
        text: text,
        bodyMarkdown: bodyMarkdown,
        bodyUTF16Offset: bodyUTF16Offset,
        selectedRange: selectedRange,
        isFrontMatterSelection: isFrontMatterSelection,
        comfortConfiguration: comfortConfiguration,
        diagnostics: diagnostics,
        ghostText: "",
        ssgSnippets: [],
        onStatisticsChanged: onStatisticsChanged,
        onPasteMessage: onPasteMessage,
        onGhostTextAccepted: { _ in },
        onGhostTextDismissed: {},
        onSSGSnippetShortcut: { _ in },
        onLiveBodyChange: onLiveBodyChange,
        onScrollPositionChanged: onScrollPositionChanged,
        onDroppedFiles: onDroppedFiles,
        onDroppedMarkdown: { _, _, _ in }
      )
    }

    func updateDocumentContext(
      bodyMarkdown: String,
      bodyUTF16Offset: Int,
      allowsLiveBodyChanges: Bool,
      attachments: [DraftAttachment],
      in textView: NSTextView
    ) {
      if self.bodyMarkdown != bodyMarkdown {
        bodyLineUTF16Offsets = Self.lineUTF16Offsets(in: bodyMarkdown)
      }
      let attachmentsChanged = self.attachments != attachments
      let bodyOffsetChanged = self.bodyUTF16Offset != bodyUTF16Offset
      self.bodyMarkdown = bodyMarkdown
      self.bodyUTF16Offset = bodyUTF16Offset
      let hasDelimitedFrontMatter = Self.documentParts(in: representedText) != nil
      requiresFrontMatterEnvelope =
        requiresFrontMatterEnvelope || bodyUTF16Offset > 0 || hasDelimitedFrontMatter
      hasValidDocumentBodyMapping =
        !requiresFrontMatterEnvelope || hasDelimitedFrontMatter
      self.allowsLiveBodyChanges = allowsLiveBodyChanges
      if !allowsLiveBodyChanges {
        isAwaitingDocumentValidation = true
      } else if pendingTextBindingValue == nil {
        isAwaitingDocumentValidation = false
      }
      self.attachments = attachments
      if bodyOffsetChanged {
        cachedDiagnosticOverlayRevision = nil
      }
      if attachmentsChanged {
        invalidateInlineAttachmentCaches()
        repaintVisibleSyntaxViewport(in: textView, reason: .appearance)
      }
    }

    private static func lineUTF16Offsets(in text: String) -> [Int] {
      let source = text as NSString
      var offsets = [0]
      var searchLocation = 0
      while searchLocation < source.length {
        let newlineRange = source.range(
          of: "\n",
          range: NSRange(location: searchLocation, length: source.length - searchLocation)
        )
        guard newlineRange.location != NSNotFound else { break }
        searchLocation = NSMaxRange(newlineRange)
        offsets.append(searchLocation)
      }
      return offsets
    }

    func installGhostTextOverlay(on textView: NSTextView) {
      let overlay = MarkdownGhostTextOverlayView(frame: textView.bounds)
      overlay.autoresizingMask = [.width, .height]
      overlay.textView = textView
      overlay.ghostText = ghostText
      overlay.isHidden = ghostText.isEmpty
      overlay.setAccessibilityLabel("AI 预测续写")
      overlay.setAccessibilityHelp("按 Tab 采纳预测内容，按 Escape 忽略预测内容")
      overlay.setAccessibilityValue(ghostText)
      textView.addSubview(overlay)
      ghostTextOverlayView = overlay
    }

    func updateGhostText(_ text: String, in textView: NSTextView) {
      let didChange = ghostText != text
      ghostText = text
      if ghostTextOverlayView == nil {
        installGhostTextOverlay(on: textView)
      }
      guard let overlay = ghostTextOverlayView else { return }
      overlay.textView = textView
      if didChange { overlay.ghostText = text }
      // Restoring from a read-only presentation may supply the same value;
      // visibility is state in its own right and must be resumed explicitly.
      overlay.isHidden = text.isEmpty
      overlay.setAccessibilityValue(text)
    }

    func updateInlineAIReviewPresentation(
      _ presentation: MarkdownEditorInlineAIReviewPresentation?,
      in textView: NSTextView
    ) {
      guard let editor = textView as? DroppableMarkdownTextView else { return }
      let documentRange = presentation.map {
        NSRange(location: bodyUTF16Offset + $0.bodyRange.location, length: $0.bodyRange.length)
      }
      guard
        inlineAIReviewPresentation != presentation
          || editor.markdownInlineAIReviewRange != documentRange
      else { return }
      inlineAIReviewPresentation = presentation
      editor.markdownInlineAIReviewRange = documentRange
      if let documentRange {
        editor.scrollRangeToVisible(documentRange)
      }
    }

    func updateRepresentedText(_ text: String) -> Bool {
      if let pendingTextBindingValue {
        if text == pendingTextBindingValue || text == lastCommittedText {
          return false
        }
        cancelPendingBindingWrites()
      }
      guard representedText != text else { return false }
      representedText = text
      lastCommittedText = text
      return true
    }

    func shouldApplyRepresentedSelection(
      selectedRange incomingRange: NSRange,
      isFrontMatterSelection incomingFrontMatterSelection: Bool,
      in textView: NSTextView
    ) -> Bool {
      guard
        pendingTextBindingValue != nil
          || pendingSelectedRangeBindingValue != nil
          || pendingFrontMatterBindingValue != nil
      else {
        return true
      }

      let isPendingEcho =
        pendingSelectedRangeBindingValue.map { NSEqualRanges($0, incomingRange) } == true
        && pendingFrontMatterBindingValue == incomingFrontMatterSelection
      if isPendingEcho {
        return false
      }

      let isCommittedEcho =
        NSEqualRanges(lastCommittedSelectedRange, incomingRange)
        && lastCommittedIsFrontMatterSelection == incomingFrontMatterSelection
      if isCommittedEcho {
        // SwiftUI can re-render with the committed cursor while AppKit is
        // already ahead of it. Keep the live NSTextView cursor intact until
        // the coalesced binding write reaches SwiftUI.
        return textView.selectedRange() == incomingRange
      }

      pendingSelectedRangeBindingValue = nil
      pendingFrontMatterBindingValue = nil
      lastCommittedSelectedRange = incomingRange
      lastCommittedIsFrontMatterSelection = incomingFrontMatterSelection
      rescheduleBindingFlushIfNeeded()
      return true
    }

    private func scheduleBindingFlush() {
      bindingFlushTask?.cancel()
      let delay = bindingFlushDelay
      bindingFlushTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: .seconds(delay))
        } catch {
          return
        }
        guard !Task.isCancelled else { return }
        self?.flushPendingBindingWrites()
      }
    }

    private func rescheduleBindingFlushIfNeeded() {
      if pendingTextBindingValue != nil
        || pendingSelectedRangeBindingValue != nil
        || pendingFrontMatterBindingValue != nil
      {
        scheduleBindingFlush()
      } else {
        bindingFlushTask?.cancel()
        bindingFlushTask = nil
      }
    }

    private func cancelPendingBindingWrites() {
      pendingTextBindingValue = nil
      pendingSelectedRangeBindingValue = nil
      pendingFrontMatterBindingValue = nil
      bindingFlushTask?.cancel()
      bindingFlushTask = nil
    }

    private func enqueueTextBindingWrite(_ value: String) {
      representedText = value
      pendingTextBindingValue = value
      scheduleBindingFlush()
    }

    private func enqueueSelectionBindingWrite(
      range: NSRange,
      isFrontMatterSelection: Bool
    ) {
      let rangeChanged = !NSEqualRanges(selectedRange, range)
      let frontMatterChanged = self.isFrontMatterSelection != isFrontMatterSelection
      guard
        rangeChanged || frontMatterChanged
          || pendingSelectedRangeBindingValue != nil
          || pendingFrontMatterBindingValue != nil
      else {
        return
      }
      pendingSelectedRangeBindingValue = range
      pendingFrontMatterBindingValue = isFrontMatterSelection
      scheduleBindingFlush()
    }

    func flushPendingBindingWrites() {
      let signpostState = syntaxHighlightSignposter.beginInterval("FlushEditorBindings")
      defer {
        syntaxHighlightSignposter.endInterval(
          "FlushEditorBindings",
          signpostState
        )
      }
      let nextText = pendingTextBindingValue
      let nextSelectedRange = pendingSelectedRangeBindingValue
      let nextFrontMatterSelection = pendingFrontMatterBindingValue
      pendingTextBindingValue = nil
      pendingSelectedRangeBindingValue = nil
      pendingFrontMatterBindingValue = nil
      bindingFlushTask?.cancel()
      bindingFlushTask = nil

      if let nextText {
        representedText = nextText
        lastCommittedText = nextText
        if text != nextText {
          text = nextText
        }
      }
      if let nextSelectedRange {
        lastCommittedSelectedRange = nextSelectedRange
        if !NSEqualRanges(selectedRange, nextSelectedRange) {
          selectedRange = nextSelectedRange
        }
      }
      if let nextFrontMatterSelection {
        lastCommittedIsFrontMatterSelection = nextFrontMatterSelection
        if isFrontMatterSelection != nextFrontMatterSelection {
          isFrontMatterSelection = nextFrontMatterSelection
        }
      }
    }

    func handleDroppedFiles(_ urls: [URL], at documentRange: NSRange) {
      guard documentRange.location >= bodyUTF16Offset else { return }
      enqueueSelectionBindingWrite(
        range: bodyRange(from: documentRange),
        isFrontMatterSelection: false
      )
      onDroppedFiles(urls)
    }

    func handleDroppedMarkdown(
      _ markdown: String,
      at documentRange: NSRange,
      citation: KnowledgeCitation?
    ) {
      guard documentRange.location >= bodyUTF16Offset else { return }
      let range = bodyRange(from: documentRange)
      enqueueSelectionBindingWrite(range: range, isFrontMatterSelection: false)
      onDroppedMarkdown(markdown, range, citation)
    }

    private func documentRange(from bodyRange: NSRange) -> NSRange {
      NSRange(
        location: bodyUTF16Offset + bodyRange.location,
        length: bodyRange.length
      )
    }

    private func bodyRange(from documentRange: NSRange) -> NSRange {
      let bodyLength = (bodyMarkdown as NSString).length
      let location = min(
        max(documentRange.location - bodyUTF16Offset, 0),
        bodyLength
      )
      let maxLength = max(0, bodyLength - location)
      return NSRange(location: location, length: min(documentRange.length, maxLength))
    }

    func updateSelectionBinding(from documentRange: NSRange) {
      if documentRange.location < bodyUTF16Offset {
        let nextRange = NSRange(location: 0, length: 0)
        enqueueSelectionBindingWrite(
          range: nextRange,
          isFrontMatterSelection: true
        )
      } else {
        let nextRange = bodyRange(from: documentRange)
        enqueueSelectionBindingWrite(
          range: nextRange,
          isFrontMatterSelection: false
        )
      }
    }

    private struct DocumentParts {
      let bodyMarkdown: String
      let bodyUTF16Offset: Int
    }

    private static func documentParts(in source: String) -> DocumentParts? {
      let sourceText = source as NSString
      guard sourceText.length > 0 else { return nil }

      var firstLineStart = 0
      var firstLineEnd = 0
      var firstContentsEnd = 0
      sourceText.getLineStart(
        &firstLineStart,
        end: &firstLineEnd,
        contentsEnd: &firstContentsEnd,
        for: NSRange(location: 0, length: 0)
      )
      let delimiter = sourceText.substring(
        with: NSRange(location: firstLineStart, length: firstContentsEnd - firstLineStart)
      ).trimmedForPublishing
      guard delimiter == "---" || delimiter == "+++" else { return nil }

      var location = firstLineEnd
      while location < sourceText.length {
        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        sourceText.getLineStart(
          &lineStart,
          end: &lineEnd,
          contentsEnd: &contentsEnd,
          for: NSRange(location: location, length: 0)
        )
        let line = sourceText.substring(
          with: NSRange(location: lineStart, length: contentsEnd - lineStart)
        )
        guard line.trimmedForPublishing == delimiter else {
          location = max(lineEnd, location + 1)
          continue
        }

        var bodyOffset = lineEnd
        if bodyOffset < sourceText.length {
          var nextLineStart = 0
          var nextLineEnd = 0
          var nextContentsEnd = 0
          sourceText.getLineStart(
            &nextLineStart,
            end: &nextLineEnd,
            contentsEnd: &nextContentsEnd,
            for: NSRange(location: bodyOffset, length: 0)
          )
          if nextContentsEnd == nextLineStart {
            bodyOffset = nextLineEnd
          }
        }
        return DocumentParts(
          bodyMarkdown: sourceText.substring(from: bodyOffset),
          bodyUTF16Offset: bodyOffset
        )
      }
      return nil
    }

    func applyComfortConfiguration(
      _ configuration: MarkdownEditorComfortConfiguration,
      in textView: NSTextView
    ) {
      guard configuration != comfortConfiguration else { return }
      let shouldRebuildSyntaxPalette = !syntaxHighlightPalette.matches(configuration)
      comfortConfiguration = configuration
      if shouldRebuildSyntaxPalette {
        syntaxHighlightPalette = MarkdownTextViewSyntaxPalette(configuration: configuration)
        applyCachedSyntaxAppearance(in: textView)
      }
      textView.isContinuousSpellCheckingEnabled = configuration.spellCheckEnabled
      let editorBackgroundColor = WorkbenchWritingSurface.nsColor(
        usesWarmPaper: configuration.warmPaperBackgroundEnabled
      )
      textView.backgroundColor = editorBackgroundColor
      textView.enclosingScrollView?.backgroundColor = editorBackgroundColor
      if let scrollView = textView.enclosingScrollView as? MarkdownEditorScrollView {
        scrollView.preferredBodyWidth = CGFloat(configuration.bodyWidth)
      }
      if shouldRebuildSyntaxPalette {
        invalidateHighlightedTextCache(in: textView)
        invalidateInlineAttachmentCaches()
        scheduleMarkdownSyntaxHighlighting(for: textView, text: textView.string)
      }
      updateCurrentParagraphHighlight(in: textView)
    }

    func applyCachedSyntaxAppearance(in textView: NSTextView) {
      textView.font = syntaxHighlightPalette.baseFont
      refreshCachedTypingAttributes(in: textView)
    }

    func refreshCachedTypingAttributes(in textView: NSTextView) {
      let desiredAttributes = syntaxHighlightPalette.defaultAttributes
      guard !(textView.typingAttributes as NSDictionary).isEqual(to: desiredAttributes) else {
        return
      }
      textView.typingAttributes = desiredAttributes
    }

    func updateDiagnostics(
      _ diagnostics: [MarkdownInlineDiagnostic],
      in textView: NSTextView,
      force: Bool = false
    ) {
      if self.diagnostics != diagnostics {
        cachedDiagnosticOverlayRevision = nil
      }
      self.diagnostics = diagnostics
      updateDiagnosticOverlays(in: textView, force: force)
    }

    deinit {
      syntaxAttributeApplicationTask?.cancel()
      inlineAttachmentDrawingApplicationTask?.cancel()
      inlineAttachmentImageTasks.values.forEach { $0.cancel() }
      readOnlyPresentationTask?.cancel()
      readOnlyPresentationImageTasks.forEach { $0.cancel() }
      statisticsTask?.cancel()
      focusRequestTask?.cancel()
      bindingFlushTask?.cancel()
    }

    func textView(
      _ textView: NSTextView,
      shouldChangeTextIn affectedCharRange: NSRange,
      replacementString: String?
    ) -> Bool {
      guard !isShowingReadOnlyPresentation else { return false }
      if !isApplyingAutomaticPairing,
        comfortConfiguration.automaticPairingEnabled,
        !textView.hasMarkedText(),
        let replacementString,
        !replacementString.isEmpty,
        affectedCharRange.location >= bodyUTF16Offset,
        let pairingEdit = automaticPairingEdit(
          in: textView,
          affectedDocumentRange: affectedCharRange,
          typedText: replacementString
        )
      {
        isApplyingAutomaticPairing = true
        defer { isApplyingAutomaticPairing = false }
        apply(pairingEdit, in: textView)
        return false
      }
      if pendingTextEdit != nil || pendingTextEditRequiresInference {
        // Some input methods issue several should-change callbacks before one
        // did-change notification. Those ranges belong to different document
        // revisions, so retain neither partial painted state nor the newest
        // hint; infer one cumulative UTF-16 edit from representedText instead.
        pendingTextEditRequiresInference = true
        removePaintedSyntaxAttributes(in: textView)
      } else {
        preparePaintedSyntaxForEdit(
          in: textView,
          affectedRange: affectedCharRange
        )
        pendingTextEdit = MarkdownTextEdit(
          previousText: textView.string,
          replacedRange: affectedCharRange
        )
      }
      return true
    }

    private func automaticPairingEdit(
      in textView: NSTextView,
      affectedDocumentRange: NSRange,
      typedText: String
    ) -> MarkdownSmartEdit? {
      guard
        typedText.utf16.count <= 3,
        !typedText.contains(where: \.isNewline)
      else {
        return nil
      }
      let document = textView.string as NSString
      guard
        bodyUTF16Offset <= document.length,
        NSMaxRange(affectedDocumentRange) <= document.length
      else {
        return nil
      }
      let body = document.substring(from: bodyUTF16Offset)
      let bodyRange = NSRange(
        location: affectedDocumentRange.location - bodyUTF16Offset,
        length: affectedDocumentRange.length
      )

      if typedText == "\"" || typedText == "'",
        bodyRange.length == 0,
        bodyRange.location > 0
      {
        let bodySource = body as NSString
        let previous = bodySource.substring(
          with: NSRange(location: bodyRange.location - 1, length: 1)
        )
        if previous.unicodeScalars.allSatisfy(
          CharacterSet.alphanumerics.contains
        ) {
          return nil
        }
      }

      guard
        let bodyEdit = advancedEditingService.pairingEdit(
          in: body,
          selectedRange: bodyRange,
          typedText: typedText
        )
      else {
        return nil
      }
      return MarkdownSmartEdit(
        replacedRange: NSRange(
          location: bodyUTF16Offset + bodyEdit.replacedRange.location,
          length: bodyEdit.replacedRange.length
        ),
        replacement: bodyEdit.replacement,
        selectedRange: NSRange(
          location: bodyUTF16Offset + bodyEdit.selectedRange.location,
          length: bodyEdit.selectedRange.length
        )
      )
    }

    func handlePaste(
      in textView: NSTextView,
      pasteboard: any MarkdownPasteboardSource
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else { return false }
      let imageURLs = MarkdownPasteboardReader.imageFileURLs(from: pasteboard)
      if !imageURLs.isEmpty {
        updateSelectionBinding(from: textView.selectedRange())
        onDroppedFiles(imageURLs)
        return true
      }

      if let pngData = MarkdownPasteboardReader.pngData(from: pasteboard) {
        do {
          let imageURL = try pastedImageFileStore.storePNG(pngData)
          updateSelectionBinding(from: textView.selectedRange())
          onDroppedFiles([imageURL])
        } catch {
          onPasteMessage("粘贴图片失败：\(error.localizedDescription)")
          NSSound.beep()
        }
        return true
      }

      if let pastedText = pasteboard.string(forType: .string),
        let edit = smartPasteService.linkEdit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          pastedText: pastedText
        )
      {
        apply(edit, in: textView)
        return true
      }

      guard let richContent = MarkdownPasteboardReader.richTextContent(from: pasteboard),
        let conversion = richTextPasteService.conversion(
          fromHTML: richContent.html,
          baseURL: richContent.baseURL
        ),
        MarkdownPasteboardReader.shouldPreferRichConversion(
          conversion.markdown,
          over: pasteboard.string(forType: .string)
        ),
        let edit = richTextPasteService.edit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          conversion: conversion
        )
      else {
        return false
      }

      apply(edit, in: textView)
      if conversion.removedTrackingParameterCount > 0 {
        onPasteMessage(
          "已将富文本转换为 Markdown，并移除 \(conversion.removedTrackingParameterCount) 个跟踪参数。"
        )
      } else {
        onPasteMessage("已将富文本转换为 Markdown。")
      }
      return true
    }

    func handleFormatting(
      _ command: MarkdownFormattingCommand,
      in textView: NSTextView
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else {
        NSSound.beep()
        return true
      }
      guard
        let edit = formattingService.edit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          command: command
        )
      else {
        return false
      }
      apply(edit, in: textView)
      return true
    }

    func handleLineEditing(
      _ command: MarkdownLineEditingCommand,
      in textView: NSTextView
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else {
        NSSound.beep()
        return true
      }
      guard
        let edit = advancedEditingService.lineEdit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          command: command
        )
      else {
        return false
      }
      apply(edit, in: textView)
      return true
    }

    func tableContext(in textView: NSTextView) -> MarkdownTableEditingContext? {
      guard textView.selectedRange().location >= bodyUTF16Offset else { return nil }
      return tableEditingService.context(
        in: textView.string,
        selectedRange: textView.selectedRange()
      )
    }

    func handleTableEditing(
      _ command: MarkdownTableEditingCommand,
      in textView: NSTextView
    ) -> Bool {
      guard textView.selectedRange().location >= bodyUTF16Offset else { return false }
      guard
        let edit = tableEditingService.edit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          command: command
        )
      else {
        return false
      }
      apply(edit, in: textView)
      return true
    }

    private func apply(_ edit: MarkdownSmartEdit, in textView: NSTextView) {
      if edit.changesText {
        textView.insertText(edit.replacement, replacementRange: edit.replacedRange)
      }
      textView.setSelectedRange(edit.selectedRange)
      updateSelectionBinding(from: edit.selectedRange)
    }

    @discardableResult
    func handle(
      _ request: MarkdownTextEditRequest?,
      in textView: NSTextView
    ) -> MarkdownTextEditRequestOutcome? {
      guard let request,
        request.id != lastAppliedEditRequestID
      else {
        return nil
      }

      lastAppliedEditRequestID = request.id
      guard bodyMarkdown == request.expectedText else {
        return MarkdownTextEditRequestOutcome(id: request.id, wasApplied: false)
      }

      let textLength = (bodyMarkdown as NSString).length
      guard request.edit.replacedRange.location >= 0,
        NSMaxRange(request.edit.replacedRange) <= textLength
      else {
        return MarkdownTextEditRequestOutcome(id: request.id, wasApplied: false)
      }

      let documentEdit = MarkdownSmartEdit(
        replacedRange: documentRange(from: request.edit.replacedRange),
        replacement: request.edit.replacement,
        selectedRange: documentRange(from: request.edit.selectedRange)
      )
      apply(documentEdit, in: textView)
      return MarkdownTextEditRequestOutcome(id: request.id, wasApplied: true)
    }

    func requestKeyboardFocus(
      _ request: MarkdownTextFocusRequest?,
      in textView: NSTextView
    ) {
      guard let request else {
        pendingFocusRequest = nil
        focusRequestTask?.cancel()
        focusRequestTask = nil
        return
      }
      guard request.id != lastAppliedFocusRequestID else { return }
      guard pendingFocusRequest != request || focusRequestTask == nil else { return }

      pendingFocusRequest = request
      focusRequestTask?.cancel()
      focusRequestTask = Task { @MainActor [weak self, weak textView] in
        let retryDelays = [0, 60, 160, 320]
        for delay in retryDelays {
          if delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
          }
          guard !Task.isCancelled,
            let self,
            let textView,
            self.pendingFocusRequest?.id == request.id
          else {
            return
          }
          guard let window = textView.window,
            window.attachedSheet == nil
          else {
            continue
          }

          self.restoreEditableMarkdown(in: textView)

          let bodyRange = MacMarkdownTextView.clamped(
            request.selectedRange,
            length: (self.bodyMarkdown as NSString).length
          )
          let range = self.documentRange(from: bodyRange)
          textView.setSelectedRange(range)
          self.scrollToRange(
            range,
            in: textView
          )
          let didFocus =
            window.firstResponder === textView
            || window.makeFirstResponder(textView)
          guard didFocus else { continue }

          self.enqueueSelectionBindingWrite(
            range: bodyRange,
            isFrontMatterSelection: false
          )
          self.lastAppliedFocusRequestID = request.id
          self.pendingFocusRequest = nil
          self.focusRequestTask = nil
          NSAccessibility.post(
            element: textView,
            notification: .focusedUIElementChanged
          )
          return
        }

        guard self?.pendingFocusRequest?.id == request.id else { return }
        self?.focusRequestTask = nil
      }
    }

    func scrollToRange(
      _ range: NSRange,
      in textView: NSTextView
    ) {
      textView.scrollRangeToVisible(range)
    }

    func observeScrolling(in scrollView: NSScrollView) {
      scrollSyncBridge.observe(
        scrollView,
        sourceLineProvider: { [weak self] scrollView in
          self?.topVisibleSourceLine(in: scrollView)
        },
        sourceLineApplier: { [weak self] sourceLine, scrollView in
          self?.scroll(toSourceLine: sourceLine, in: scrollView) == true
        },
        onViewportChanged: { [weak self] in
          guard let self, let textView = self.textView else { return }
          self.repaintVisibleSyntaxViewport(in: textView, reason: .viewport)
        }
      )
    }

    private func topVisibleSourceLine(in scrollView: NSScrollView) -> Int? {
      guard let textView = scrollView.documentView as? NSTextView else { return nil }
      let point = NSPoint(
        x: textView.textContainerInset.width + 1,
        y: scrollView.documentVisibleRect.minY + textView.textContainerInset.height + 1
      )
      let documentLocation = textView.characterIndexForInsertion(at: point)
      let bodyLocation = max(0, documentLocation - bodyUTF16Offset)

      var lowerBound = 0
      var upperBound = bodyLineUTF16Offsets.count
      while lowerBound < upperBound {
        let middle = (lowerBound + upperBound) / 2
        if bodyLineUTF16Offsets[middle] <= bodyLocation {
          lowerBound = middle + 1
        } else {
          upperBound = middle
        }
      }
      return max(1, lowerBound)
    }

    private func scroll(toSourceLine sourceLine: Int, in scrollView: NSScrollView) -> Bool {
      guard let textView = scrollView.documentView as? NSTextView,
        !bodyLineUTF16Offsets.isEmpty
      else {
        return false
      }
      let lineIndex = min(max(sourceLine - 1, 0), bodyLineUTF16Offsets.count - 1)
      let documentLength = (textView.string as NSString).length
      let characterLocation = min(
        max(0, bodyUTF16Offset + bodyLineUTF16Offsets[lineIndex]),
        documentLength
      )
      guard documentLength > 0 else {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return true
      }
      let characterRange = NSRange(
        location: min(characterLocation, documentLength - 1),
        length: 1
      )
      guard
        let lineRect = MarkdownTextKit2RangeAdapter.rect(
          for: characterRange,
          in: textView
        )
      else {
        return false
      }
      let maximumY = max(0, textView.frame.height - scrollView.contentView.bounds.height)
      let targetY = min(
        max(0, lineRect.minY + textView.textContainerInset.height),
        maximumY
      )
      scrollView.contentView.scroll(
        to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY)
      )
      scrollView.reflectScrolledClipView(scrollView.contentView)
      return true
    }

    func applySynchronizedScroll(
      _ update: MarkdownScrollSyncUpdate?,
      in scrollView: NSScrollView,
      allowDeferredRetry: Bool = true
    ) {
      scrollSyncBridge.apply(update, allowDeferredRetry: allowDeferredRetry)
    }

    func applyRestoredScroll(
      _ update: MarkdownScrollSyncUpdate?,
      in scrollView: NSScrollView
    ) {
      scrollSyncBridge.restore(update)
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      guard !isApplyingRepresentedText else { return }
      guard !isShowingReadOnlyPresentation else { return }
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
      let updatedText = textView.string
      let previousBodyMarkdown = bodyMarkdown
      let previousBodyUTF16Offset = bodyUTF16Offset
      let requiresInferredTextEdit = pendingTextEditRequiresInference
      pendingTextEditRequiresInference = false
      let syntaxHighlightEdit =
        (requiresInferredTextEdit ? nil : pendingTextEdit)
        ?? MarkdownTextEdit.inferred(
          previousText: representedText,
          currentText: updatedText
        )
      pendingTextEdit = nil
      let previousSyntaxRevision = syntaxDocumentRevision
      syntaxDocumentRevision &+= 1
      if let syntaxHighlightEdit {
        pendingSyntaxParserEdit =
          pendingSyntaxParserEdit?.accumulating(
            previousText: syntaxHighlightEdit.previousText,
            currentText: updatedText,
            replacedRange: syntaxHighlightEdit.replacedRange,
            previousRevision: previousSyntaxRevision,
            currentRevision: syntaxDocumentRevision
          )
          ?? MarkdownSyntaxHighlightEditAccumulator(
            previousText: syntaxHighlightEdit.previousText,
            currentText: updatedText,
            replacedRange: syntaxHighlightEdit.replacedRange,
            previousRevision: previousSyntaxRevision,
            currentRevision: syntaxDocumentRevision
          )
      } else {
        pendingSyntaxParserEdit = nil
      }
      let syntaxHighlightPlan: MarkdownSyntaxHighlightPlan
      if let syntaxHighlightEdit {
        syntaxHighlightPlan = MarkdownSyntaxHighlightRangeService.plan(
          accumulating: pendingSyntaxHighlightPlan,
          previousText: syntaxHighlightEdit.previousText,
          currentText: updatedText,
          replacedRange: syntaxHighlightEdit.replacedRange,
          knownCodeBlockRanges: syntaxCodeBlockRanges
        )
      } else {
        syntaxHighlightPlan = .fullDocument(for: updatedText)
      }
      reconcilePaintedSyntaxState(
        after: syntaxHighlightEdit,
        plan: syntaxHighlightPlan,
        previousRevision: previousSyntaxRevision,
        currentText: updatedText,
        in: textView
      )
      pendingSyntaxHighlightPlan = syntaxHighlightPlan
      syntaxCodeBlockRanges = syntaxHighlightPlan.codeBlockRanges
      let updatedSource = updatedText as NSString
      let editIsBodyOnly =
        !requiresFrontMatterEnvelope
        || syntaxHighlightEdit.map {
          $0.replacedRange.location >= previousBodyUTF16Offset
        } == true
      if !editIsBodyOnly {
        isAwaitingDocumentValidation = true
      }
      let canPublishBodyChange: Bool
      if hasValidDocumentBodyMapping,
        let syntaxHighlightEdit,
        let incrementallyUpdatedBody = Self.bodyMarkdown(
          byApplying: syntaxHighlightEdit,
          to: previousBodyMarkdown,
          bodyUTF16Offset: previousBodyUTF16Offset,
          updatedDocument: updatedSource
        )
      {
        bodyMarkdown = incrementallyUpdatedBody
        canPublishBodyChange = true
      } else if let parts = Self.documentParts(in: updatedText) {
        bodyMarkdown = parts.bodyMarkdown
        bodyUTF16Offset = parts.bodyUTF16Offset
        requiresFrontMatterEnvelope = true
        hasValidDocumentBodyMapping = true
        canPublishBodyChange = true
      } else if requiresFrontMatterEnvelope {
        // A broken or missing delimiter makes the body boundary ambiguous.
        // Keep the last valid body/offset and publish only the complete
        // document binding so the composer can persist its recovery copy.
        hasValidDocumentBodyMapping = false
        canPublishBodyChange = false
      } else {
        bodyMarkdown = updatedText
        bodyUTF16Offset = 0
        hasValidDocumentBodyMapping = true
        canPublishBodyChange = true
      }
      if canPublishBodyChange, editIsBodyOnly, let syntaxHighlightEdit {
        incrementallyUpdateInlineAttachmentPlan(
          previousBodyMarkdown: previousBodyMarkdown,
          currentBodyMarkdown: bodyMarkdown,
          documentEdit: syntaxHighlightEdit,
          previousBodyUTF16Offset: previousBodyUTF16Offset,
          previousRevision: previousSyntaxRevision
        )
      }
      enqueueTextBindingWrite(updatedText)
      let documentSelection = textView.selectedRange()
      updateSelectionBinding(from: documentSelection)
      if documentSelection.location >= bodyUTF16Offset,
        documentSelection.length == 0,
        let shortcutCandidate = MarkdownCursorCompletionService().automaticShortcutCandidate(
          in: bodyMarkdown,
          selectedRange: bodyRange(from: documentSelection),
          snippets: ssgSnippets
        )
      {
        onSSGSnippetShortcut(shortcutCandidate)
      }
      updateGhostText(ghostText, in: textView)
      // `pendingTextEdit` is consumed above by syntax highlighting. Keep the
      // same explicit edit value for statistics instead of looking it up from
      // the now-cleared coordinator slot; otherwise every ordinary keystroke
      // falls back to the delayed full-document scanner.
      updateStatistics(afterEditing: bodyMarkdown, edit: syntaxHighlightEdit)
      if canPublishBodyChange,
        editIsBodyOnly,
        allowsLiveBodyChanges,
        !isAwaitingDocumentValidation,
        previousBodyMarkdown != bodyMarkdown
      {
        onLiveBodyChange(previousBodyMarkdown, bodyMarkdown)
      }
      scheduleMarkdownSyntaxHighlighting(
        for: textView,
        text: updatedText,
        plan: syntaxHighlightPlan
      )
      updateCurrentParagraphHighlight(in: textView)
    }

    static func bodyMarkdown(
      byApplying edit: MarkdownTextEdit,
      to previousBodyMarkdown: String,
      bodyUTF16Offset: Int,
      updatedDocument: NSString
    ) -> String? {
      guard edit.replacedRange.location >= bodyUTF16Offset else { return nil }
      let previousDocument = edit.previousText as NSString
      let previousDocumentLength = previousDocument.length
      let replacementLength =
        updatedDocument.length - previousDocumentLength + edit.replacedRange.length
      guard replacementLength >= 0 else { return nil }

      let bodyRange = NSRange(
        location: edit.replacedRange.location - bodyUTF16Offset,
        length: edit.replacedRange.length
      )
      let currentReplacementRange = NSRange(
        location: edit.replacedRange.location,
        length: replacementLength
      )
      let previousBody = previousBodyMarkdown as NSString
      guard
        bodyUTF16Offset <= previousDocumentLength,
        previousBody.length == previousDocumentLength - bodyUTF16Offset,
        NSMaxRange(bodyRange) <= previousBody.length,
        NSMaxRange(edit.replacedRange) <= previousDocumentLength,
        NSMaxRange(currentReplacementRange) <= updatedDocument.length,
        previousBody.substring(with: bodyRange)
          == previousDocument.substring(with: edit.replacedRange)
      else {
        // IME composition can deliver more than one should-change callback before
        // the matching did-change notification. In that case the newest pending
        // range may no longer describe `bodyMarkdown`; fall back to parsing the
        // current document instead of applying a stale delta.
        return nil
      }

      let updatedBody = NSMutableString(string: previousBodyMarkdown)
      updatedBody.replaceCharacters(
        in: bodyRange,
        with: updatedDocument.substring(with: currentReplacementRange)
      )
      return updatedBody as String
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      guard !isApplyingRepresentedText else { return }
      if let readOnlyPresentationDocument,
        let sourceRange = readOnlyPresentationDocument.sourceRange(
          forPresentationRange: textView.selectedRange()
        )
      {
        readOnlyPresentationSourceSelection = sourceRange
        updateSelectionBinding(from: sourceRange)
        return
      }
      updateSelectionBinding(from: textView.selectedRange())
      updateGhostText(ghostText, in: textView)
      repaintVisibleSyntaxViewport(in: textView, reason: .selection)
      performTypewriterScrollIfNeeded(in: textView)
      updateCurrentParagraphHighlight(in: textView)
    }

    func performTypewriterScrollIfNeeded(in textView: NSTextView) {
      guard comfortConfiguration.typewriterModeEnabled,
        let lineRect = MarkdownTextKit2RangeAdapter.rect(
          for: textView.selectedRange(),
          in: textView
        ),
        let clipView = textView.enclosingScrollView?.contentView
      else { return }

      let targetY = lineRect.midY - (clipView.bounds.height / 2.2)
      let clampedY = max(0, min(targetY, textView.bounds.height - clipView.bounds.height))

      clipView.setBoundsOrigin(NSPoint(x: 0, y: clampedY))
      textView.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    func textView(
      _ textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      // An active input-method composition owns command routing.  In
      // particular, Tab/Escape must reach the IME instead of accepting a
      // completion, dismissing it, or falling through to smart indentation.
      guard !textView.hasMarkedText() else { return false }
      if commandSelector == #selector(NSResponder.insertTab(_:)),
        MarkdownGhostTextCommandPolicy.shouldAccept(
          ghostText: ghostText,
          selectedRange: textView.selectedRange(),
          bodyUTF16Offset: bodyUTF16Offset,
          hasMarkedText: textView.hasMarkedText()
        )
      {
        let acceptedText = ghostText
        // The SwiftUI owner schedules one undoable NSTextView edit. Inserting
        // here as well would duplicate completion text.
        ghostText = ""
        ghostTextOverlayView?.ghostText = ""
        onGhostTextAccepted(acceptedText)
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)),
        MarkdownGhostTextCommandPolicy.shouldDismiss(
          ghostText: ghostText,
          hasMarkedText: textView.hasMarkedText()
        )
      {
        ghostText = ""
        ghostTextOverlayView?.ghostText = ""
        onGhostTextDismissed()
        return true
      }
      guard textView.selectedRange().location >= bodyUTF16Offset else {
        return false
      }
      let edit: MarkdownSmartEdit?
      switch commandSelector {
      case #selector(NSResponder.insertNewline(_:)):
        edit = smartEditingService.newlineEdit(
          in: textView.string,
          selectedRange: textView.selectedRange()
        )
      case #selector(NSResponder.insertTab(_:)):
        if handleTableEditing(.navigateForward, in: textView) {
          return true
        }
        edit = smartEditingService.indentationEdit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          direction: .indent
        )
      case #selector(NSResponder.insertBacktab(_:)):
        if handleTableEditing(.navigateBackward, in: textView) {
          return true
        }
        edit = smartEditingService.indentationEdit(
          in: textView.string,
          selectedRange: textView.selectedRange(),
          direction: .outdent
        )
      default:
        return false
      }

      guard let edit else { return false }
      apply(edit, in: textView)
      return true
    }

  }
}
