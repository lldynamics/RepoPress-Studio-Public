import AppKit
import OSLog
import PublishingDomainContracts
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
  var isFrontMatterFolded: Bool = false
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
  /// Consumers that persist only normalized progress can explicitly disable
  /// the exact AppKit source-line lookup. The default preserves existing
  /// source-line reporting for other callers.
  var reportsScrollSourceLine = true
  var scrollSyncUpdate: MarkdownScrollSyncUpdate?
  var scrollRestorationUpdate: MarkdownScrollSyncUpdate?
  var onStatisticsChanged: (MarkdownEditorStatistics) -> Void
  var onFileDropTargetChanged: (Bool) -> Void
  var onPasteMessage: (String) -> Void
  var onEditRequestHandled: (MarkdownTextEditRequestOutcome) -> Void
  var onEditRequestWillApply: ((MarkdownTextEditRequest) -> Bool)? = nil
  var onGhostTextAccepted: (String) -> Void
  var onGhostTextDismissed: () -> Void
  var onInlineAICompletionRequested: () -> Void
  var onSSGSnippetShortcut: (MarkdownCompletionCandidate) -> Void
  var onSlashCommandKey: (MarkdownSlashCommandKey, @escaping (String) -> Bool) -> Bool = {
    _, _ in false
  }
  var onLiveBodyChange: (String, String) -> Void = { _, _ in }
  var onDocumentTextCommitted: (String, String) -> Void = { _, _ in }
  var onContextualAnchorChanged: (MarkdownContextualPopoverAnchor?) -> Void = { _ in }
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
      onDocumentTextCommitted: onDocumentTextCommitted,
      onContextualAnchorChanged: onContextualAnchorChanged,
      onScrollPositionChanged: onScrollPositionChanged,
      onDroppedFiles: onDroppedFiles,
      onDroppedMarkdown: onDroppedMarkdown
    )
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = MarkdownEditorScrollView()
    scrollView.contentView = MarkdownFrontMatterClipView()
    scrollView.foldedFrontMatterBodyOffset = isFrontMatterFolded ? bodyUTF16Offset : 0
    context.coordinator.isFrontMatterFolded = isFrontMatterFolded
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
    configureSlashCommandHandler(on: textView, coordinator: context.coordinator)
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
    // MarkdownEditorScrollView owns the document frame. AppKit's automatic
    // fitting can briefly shrink it during TextKit 2 attribute updates and
    // clamp the user's viewport before the next measured layout restores it.
    textView.isVerticallyResizable = false
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [NSView.AutoresizingMask.width]
    textView.textContainer?.containerSize = NSSize(
      width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false

    context.coordinator.installGhostTextOverlay(on: textView)
    context.coordinator.configureReadOnlyPresentationFocusBridge(on: textView)
    scrollView.documentView = textView
    context.coordinator.observeScrolling(
      in: scrollView,
      reportsSourceLine: reportsScrollSourceLine
    )
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
    context.coordinator.setReportsScrollSourceLine(reportsScrollSourceLine)
    context.coordinator.isFrontMatterFolded = isFrontMatterFolded
    (nsView as? MarkdownEditorScrollView)?.foldedFrontMatterBodyOffset =
      isFrontMatterFolded ? bodyUTF16Offset : 0
    if isFrontMatterFolded, textView.selectedRange().location < bodyUTF16Offset {
      textView.setSelectedRange(
        MarkdownFrontMatterFoldSelection.visibleRange(
          textView.selectedRange(), bodyOffset: bodyUTF16Offset,
          documentLength: (textView.string as NSString).length
        ))
    }
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
    context.coordinator.onDocumentTextCommitted = onDocumentTextCommitted
    context.coordinator.onContextualAnchorChanged = onContextualAnchorChanged
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
      configureSlashCommandHandler(on: droppableTextView, coordinator: context.coordinator)
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
      context.coordinator.replaceDocumentTextFromExternalUpdate(text, in: textView)
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
    if let editRequest, let onEditRequestWillApply {
      // Attachment admission commits metadata only after live TextKit checks.
      // Run outside representable updates so that commit may publish state.
      DispatchQueue.main.async {
        if let outcome = context.coordinator.handle(
          editRequest, in: textView, beforeApply: onEditRequestWillApply
        ) {
          onEditRequestHandled(outcome)
        }
      }
    } else if let outcome = context.coordinator.handle(editRequest, in: textView) {
      DispatchQueue.main.async {
        onEditRequestHandled(outcome)
      }
    }
    context.coordinator.requestKeyboardFocus(focusRequest, in: textView)
    context.coordinator.publishContextualAnchor(in: textView)
    context.coordinator.applySynchronizedScroll(scrollSyncUpdate, in: nsView)
    context.coordinator.applyRestoredScroll(scrollRestorationUpdate, in: nsView)
    context.coordinator.scheduleReadOnlyPresentationIfNeeded(in: textView)
  }

  private func configureSlashCommandHandler(
    on textView: DroppableMarkdownTextView,
    coordinator: Coordinator
  ) {
    let handler = onSlashCommandKey
    textView.slashCommandKeyHandler = { [weak textView, weak coordinator] key in
      guard let textView, let coordinator, !textView.hasMarkedText() else { return false }
      return handler(key) { [weak textView, weak coordinator] snippet in
        guard let textView, let coordinator else { return false }
        return coordinator.applySlashCommand(snippet, in: textView)
      }
    }
  }

  static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
    coordinator.flushPendingBindingWrites(notifyingDocumentCommit: true)
    coordinator.invalidateContextualAnchorPublication()
    MacMarkdownEditorTerminationFlushRegistry.unregister(coordinator)
    coordinator.inlineAttachmentDrawingApplicationTask?.cancel()
    coordinator.cancelReadOnlyPresentationTasks()
    if let textView = nsView.documentView as? DroppableMarkdownTextView {
      textView.willBecomeFirstResponderHandler = nil
      textView.didResignFirstResponderHandler = nil
      textView.inlineAIRequestHandler = nil
      textView.slashCommandKeyHandler = nil
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
    var isFrontMatterFolded = false
    var requiresFrontMatterEnvelope: Bool
    var hasValidDocumentBodyMapping: Bool
    var allowsLiveBodyChanges: Bool
    var isAwaitingDocumentValidation = false
    var bodyLineUTF16Offsets: [Int]
    var representedText: String
    var documentEnvelopeRevision: UInt64 = 0
    var cachedDocumentEnvelope: (revision: UInt64, bodyUTF16Offset: Int?)?
    let onStatisticsChanged: (MarkdownEditorStatistics) -> Void
    let onPasteMessage: (String) -> Void
    var onGhostTextAccepted: (String) -> Void
    var onGhostTextDismissed: () -> Void
    var onSSGSnippetShortcut: (MarkdownCompletionCandidate) -> Void
    var onContextualAnchorChanged: (MarkdownContextualPopoverAnchor?) -> Void
    private var contextualAnchorPublicationTask: Task<Void, Never>?
    private var pendingContextualAnchor: MarkdownContextualPopoverAnchor?
    private var lastPublishedContextualAnchor: MarkdownContextualPopoverAnchor?
    private var hasPublishedContextualAnchor = false
    private var isContextualAnchorPublicationInvalidated = false
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
    var statisticsContextGeneration = 0
    var statisticsText: String?
    var statisticsDocumentRevision: UInt64?
    var statisticsBodyUTF16Offset: Int?
    var statistics = MarkdownEditorStatistics.empty
    // These counters make the editor's update path observable in focused
    // AppKit tests. They are intentionally kept on the coordinator so tests
    // can distinguish a local delta from a scheduled document-wide scan.
    var statisticsFullScanCount = 0
    var statisticsIncrementalUpdateCount = 0
    var statisticsRevisionValidatedUpdateCount = 0
    var pendingTextEdit: MarkdownTextEdit?
    var pendingTextEditRequiresInference = false
    var isApplyingRepresentedText = false
    var lastCommittedText: String
    var lastCommittedSelectedRange: NSRange
    var lastCommittedIsFrontMatterSelection: Bool
    var pendingTextBindingValue: String?
    var onDocumentTextCommitted: (String, String) -> Void
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
    var inlineAttachmentGeometryReservations:
      [String: MarkdownInlineAttachmentGeometryReservation] = [:]
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
    var appliedParagraphHighlightGeometryRange: NSRange?
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
      onDocumentTextCommitted: @escaping (String, String) -> Void = { _, _ in },
      onContextualAnchorChanged: @escaping (MarkdownContextualPopoverAnchor?) -> Void = { _ in },
      onScrollPositionChanged: @escaping (MarkdownScrollSyncPosition) -> Void,
      onDroppedFiles: @escaping ([URL]) -> Void,
      onDroppedMarkdown: @escaping (String, NSRange, KnowledgeCitation?) -> Void
    ) {
      _text = text
      self.bodyMarkdown = bodyMarkdown
      self.bodyUTF16Offset = bodyUTF16Offset
      let delimitedBodyUTF16Offset = Self.delimitedBodyUTF16Offset(in: text.wrappedValue)
      cachedDocumentEnvelope = (
        revision: 0,
        bodyUTF16Offset: delimitedBodyUTF16Offset
      )
      let hasDelimitedFrontMatter = delimitedBodyUTF16Offset != nil
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
      self.onDocumentTextCommitted = onDocumentTextCommitted
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
      self.onContextualAnchorChanged = onContextualAnchorChanged
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
      super.init()
      MacMarkdownEditorTerminationFlushRegistry.register(self)
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
        onDocumentTextCommitted: { _, _ in },
        onContextualAnchorChanged: { _ in },
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
      let bodyChanged = self.bodyMarkdown != bodyMarkdown
      if bodyChanged {
        bodyLineUTF16Offsets = Self.lineUTF16Offsets(in: bodyMarkdown)
      }
      let attachmentsChanged = self.attachments != attachments
      let bodyOffsetChanged = self.bodyUTF16Offset != bodyUTF16Offset
      if bodyChanged || bodyOffsetChanged {
        // An in-flight scan must not certify a different represented context.
        // An already certified live document remains valid across a body echo:
        // actual text replacements advance syntaxDocumentRevision separately.
        statisticsContextGeneration += 1
      }
      if bodyOffsetChanged {
        statisticsDocumentRevision = nil
        statisticsBodyUTF16Offset = nil
      }
      self.bodyMarkdown = bodyMarkdown
      self.bodyUTF16Offset = bodyUTF16Offset
      let hasDelimitedFrontMatter = cachedDelimitedBodyUTF16Offset(in: representedText) != nil
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
        (editor.enclosingScrollView as? MarkdownEditorScrollView)?.cancelPendingSelectionReveal()
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
      invalidateDocumentEnvelopeCache()
      lastCommittedText = text
      return true
    }

    /// SwiftUI can replace the complete Markdown document after a structured
    /// metadata edit or another editor writes the same draft. NSTextView's
    /// undo manager stores UTF-16 ranges, so retaining local edit actions
    /// across a differently-shaped document can make Undo target unrelated
    /// Front Matter. An external replacement is therefore an explicit undo
    /// boundary: it clears only the stale local history before installing the
    /// new source.
    func replaceDocumentTextFromExternalUpdate(_ text: String, in textView: NSTextView) {
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.cancelPendingSelectionReveal()
      textView.undoManager?.removeAllActions()
      isApplyingRepresentedText = true
      textView.string = text
      isApplyingRepresentedText = false
    }

    func shouldApplyRepresentedSelection(
      selectedRange incomingRange: NSRange,
      isFrontMatterSelection incomingFrontMatterSelection: Bool,
      in textView: NSTextView
    ) -> Bool {
      let isCommittedEcho =
        NSEqualRanges(lastCommittedSelectedRange, incomingRange)
        && lastCommittedIsFrontMatterSelection == incomingFrontMatterSelection
      if isCommittedEcho {
        // A binding flush clears pending values before SwiftUI redraws. The
        // native caret can already be ahead of the committed selection even
        // in that gap, before its final selection notification arrives.
        let representedDocumentRange =
          incomingFrontMatterSelection ? incomingRange : documentRange(from: incomingRange)
        return textView.selectedRange() == representedDocumentRange
      }

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

    func flushPendingBindingWrites(notifyingDocumentCommit: Bool = false) {
      let signpostState = syntaxHighlightSignposter.beginInterval("FlushEditorBindings")
      defer {
        syntaxHighlightSignposter.endInterval(
          "FlushEditorBindings",
          signpostState
        )
      }
      let nextText = pendingTextBindingValue
      let previousText = lastCommittedText
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
        if notifyingDocumentCommit, previousText != nextText {
          onDocumentTextCommitted(previousText, nextText)
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

    private func invalidateDocumentEnvelopeCache() {
      documentEnvelopeRevision &+= 1
      cachedDocumentEnvelope = nil
    }

    private func cachedDelimitedBodyUTF16Offset(in source: String) -> Int? {
      if let cachedDocumentEnvelope,
        cachedDocumentEnvelope.revision == documentEnvelopeRevision
      {
        return cachedDocumentEnvelope.bodyUTF16Offset
      }
      let bodyUTF16Offset = Self.delimitedBodyUTF16Offset(in: source)
      cachedDocumentEnvelope = (
        revision: documentEnvelopeRevision,
        bodyUTF16Offset: bodyUTF16Offset
      )
      return bodyUTF16Offset
    }

    private func documentParts(in source: String) -> DocumentParts? {
      let sourceText = source as NSString
      guard let bodyUTF16Offset = cachedDelimitedBodyUTF16Offset(in: source) else { return nil }
      return DocumentParts(
        bodyMarkdown: sourceText.substring(from: bodyUTF16Offset),
        bodyUTF16Offset: bodyUTF16Offset
      )
    }

    private static func delimitedBodyUTF16Offset(in source: String) -> Int? {
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
        return bodyOffset
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
        if shouldRebuildSyntaxPalette { scrollView.invalidateFrontMatterFoldGeometry() }
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
      contextualAnchorPublicationTask?.cancel()
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
      // Backspace at the first visible character must never erase a hidden
      // delimiter. Undo remains free to restore its original document range.
      if isFrontMatterFolded, affectedCharRange.location < bodyUTF16Offset,
        textView.undoManager?.isUndoing != true, textView.undoManager?.isRedoing != true
      {
        return false
      }
      if !isApplyingAutomaticPairing,
        comfortConfiguration.automaticPairingEnabled,
        !textView.hasMarkedText(),
        let replacementString,
        !replacementString.isEmpty,
        MarkdownAdvancedEditingService.isAutomaticPairingCandidate(replacementString),
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

    func textView(
      _ textView: NSTextView,
      willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
      toCharacterRange newSelectedCharRange: NSRange
    ) -> NSRange {
      guard isFrontMatterFolded else { return newSelectedCharRange }
      return MarkdownFrontMatterFoldSelection.visibleRange(
        newSelectedCharRange, bodyOffset: bodyUTF16Offset,
        documentLength: (textView.string as NSString).length
      )
    }

    func textView(
      _ textView: NSTextView,
      willChangeSelectionFromCharacterRanges oldSelectedCharRanges: [NSValue],
      toCharacterRanges newSelectedCharRanges: [NSValue]
    ) -> [NSValue] {
      guard isFrontMatterFolded else { return newSelectedCharRanges }
      return newSelectedCharRanges.map {
        NSValue(
          range: MarkdownFrontMatterFoldSelection.visibleRange(
            $0.rangeValue, bodyOffset: bodyUTF16Offset,
            documentLength: (textView.string as NSString).length
          ))
      }
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

    /// Keyboard acceptance must finish its native edit before the next input
    /// event. SwiftUI supplies the chosen snippet; the coordinator resolves
    /// the replacement against the live text and owns its undo/selection.
    func applySlashCommand(_ snippet: String, in textView: NSTextView) -> Bool {
      let selection = textView.selectedRange()
      guard allowsLiveBodyChanges, !isShowingReadOnlyPresentation,
        selection.length == 0, selection.location >= bodyUTF16Offset,
        let range = MarkdownSlashCommandText.replacementRange(
          in: bodyMarkdown,
          caretUTF16Location: selection.location - bodyUTF16Offset
        )
      else { return false }
      let edit = MarkdownSmartEdit(
        replacedRange: range,
        replacement: snippet,
        selectedRange: NSRange(
          location: range.location + (snippet as NSString).length, length: 0
        )
      )
      return handle(MarkdownTextEditRequest(expectedText: bodyMarkdown, edit: edit), in: textView)?
        .wasApplied == true
    }

    @discardableResult
    func handle(
      _ request: MarkdownTextEditRequest?,
      in textView: NSTextView,
      beforeApply: (MarkdownTextEditRequest) -> Bool = { _ in true }
    ) -> MarkdownTextEditRequestOutcome? {
      guard let request,
        request.id != lastAppliedEditRequestID
      else {
        return nil
      }

      lastAppliedEditRequestID = request.id
      // Explicit edits must match the actual text storage as well as the
      // represented cache. Live keystrokes can precede a coalesced Binding
      // update; an old preview must never overwrite those keystrokes.
      let document = textView.string as NSString
      let expectedLength = (request.expectedText as NSString).length
      guard !textView.hasMarkedText(),
        bodyUTF16Offset >= 0, bodyUTF16Offset <= document.length,
        document.length - bodyUTF16Offset == expectedLength,
        document.compare(
          request.expectedText, options: .literal,
          range: NSRange(location: bodyUTF16Offset, length: expectedLength)
        ) == .orderedSame,
        bodyMarkdown == request.expectedText
      else {
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
      guard beforeApply(request) else {
        return MarkdownTextEditRequestOutcome(id: request.id, wasApplied: false)
      }
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

    func observeScrolling(
      in scrollView: NSScrollView,
      reportsSourceLine: Bool = true
    ) {
      scrollSyncBridge.observe(
        scrollView,
        sourceLineProvider: { [weak self] scrollView in
          self?.topVisibleSourceLine(in: scrollView)
        },
        sourceLineApplier: { [weak self] sourceLine, scrollView in
          self?.scroll(toSourceLine: sourceLine, in: scrollView) == true
        },
        reportsSourceLine: reportsSourceLine,
        onViewportChanged: { [weak self] in
          guard let self, let textView = self.textView else { return }
          self.repaintVisibleSyntaxViewport(in: textView, reason: .viewport)
          _ = self.updateCurrentParagraphHighlight(in: textView)
          self.publishContextualAnchor(in: textView)
        }
      )
    }

    func setReportsScrollSourceLine(_ reportsSourceLine: Bool) {
      scrollSyncBridge.setReportsSourceLine(reportsSourceLine)
    }

    func publishContextualAnchor(in textView: NSTextView) {
      let documentSelection = textView.selectedRange()
      let documentLength = (textView.string as NSString).length
      let bodyLength = (bodyMarkdown as NSString).length
      guard
        let geometryRange = MarkdownTextKit2RangeAdapter.visibleGeometryRange(
          for: documentSelection,
          in: textView
        )
      else {
        enqueueContextualAnchorPublication(nil)
        return
      }
      guard
        let selection = MarkdownContextualPopoverAnchorResolver.selection(
          forDocumentRange: documentSelection,
          documentUTF16Length: documentLength,
          bodyUTF16Offset: bodyUTF16Offset,
          bodyUTF16Length: bodyLength
        ),
        let textRect = contextualTextRect(
          for: geometryRange,
          documentLength: documentLength,
          in: textView
        ),
        let scrollView = textView.enclosingScrollView
      else {
        enqueueContextualAnchorPublication(nil)
        return
      }
      let visibleRect = scrollView.documentVisibleRect
      let viewport = CGRect(origin: .zero, size: scrollView.contentView.bounds.size)
      enqueueContextualAnchorPublication(
        MarkdownContextualPopoverAnchorResolver.anchor(
          selection: selection,
          textRect: textRect,
          visibleTextRect: visibleRect,
          viewport: viewport
        )
      )
    }

    func enqueueContextualAnchorPublication(_ anchor: MarkdownContextualPopoverAnchor?) {
      guard !isContextualAnchorPublicationInvalidated else { return }
      pendingContextualAnchor = anchor
      guard contextualAnchorPublicationTask == nil else { return }
      guard !hasPublishedContextualAnchor || lastPublishedContextualAnchor != anchor else {
        return
      }
      // updateNSView also measures the anchor. Writing its callback into
      // SwiftUI State inline can leave the current render with the old value.
      // Deliver once after that update, keeping only the latest geometry,
      // including a nil that clears an anchor which has left the viewport.
      contextualAnchorPublicationTask = Task { @MainActor [weak self] in
        guard !Task.isCancelled, let self,
          !self.isContextualAnchorPublicationInvalidated
        else { return }
        self.contextualAnchorPublicationTask = nil
        let latest = self.pendingContextualAnchor
        self.pendingContextualAnchor = nil
        guard !self.hasPublishedContextualAnchor || self.lastPublishedContextualAnchor != latest
        else {
          return
        }
        self.hasPublishedContextualAnchor = true
        self.lastPublishedContextualAnchor = latest
        self.onContextualAnchorChanged(latest)
      }
    }

    func invalidateContextualAnchorPublication() {
      isContextualAnchorPublicationInvalidated = true
      contextualAnchorPublicationTask?.cancel()
      contextualAnchorPublicationTask = nil
      pendingContextualAnchor = nil
      onContextualAnchorChanged = { _ in }
    }

    private func contextualTextRect(
      for documentRange: NSRange,
      documentLength: Int,
      in textView: NSTextView
    ) -> NSRect? {
      if let rect = MarkdownTextKit2RangeAdapter.rect(for: documentRange, in: textView),
        !rect.isNull,
        !rect.isInfinite,
        rect.height > 0
      {
        return normalizedContextualRect(rect, for: documentRange)
      }
      guard documentRange.length == 0 else { return nil }

      if documentRange.location < documentLength,
        let followingRect = MarkdownTextKit2RangeAdapter.rect(
          for: NSRange(location: documentRange.location, length: 1),
          in: textView
        )
      {
        return NSRect(
          x: followingRect.minX,
          y: followingRect.minY,
          width: 1,
          height: max(1, followingRect.height)
        )
      }
      if documentRange.location > 0,
        let precedingRect = MarkdownTextKit2RangeAdapter.rect(
          for: NSRange(location: documentRange.location - 1, length: 1),
          in: textView
        )
      {
        return NSRect(
          x: max(precedingRect.minX, precedingRect.maxX - 1),
          y: precedingRect.minY,
          width: 1,
          height: max(1, precedingRect.height)
        )
      }
      let origin = textView.textContainerOrigin
      return NSRect(
        x: origin.x,
        y: origin.y,
        width: 1,
        height: max(1, textView.font?.pointSize ?? NSFont.systemFontSize)
      )
    }

    private func normalizedContextualRect(_ rect: NSRect, for range: NSRange) -> NSRect {
      MarkdownContextualPopoverAnchorResolver.normalizedTextRect(rect, for: range)
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
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight(
        immediately: true, revealingSelection: true)
      let updatedText = textView.string
      invalidateDocumentEnvelopeCache()
      let previousBodyMarkdown = bodyMarkdown
      let previousBodyUTF16Offset = bodyUTF16Offset
      let requiresInferredTextEdit = pendingTextEditRequiresInference
      let hasExplicitStatisticsEdit =
        pendingTextEdit != nil && !requiresInferredTextEdit && !textView.hasMarkedText()
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
      } else if let parts = documentParts(in: updatedText) {
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
      updateStatistics(
        afterEditing: bodyMarkdown,
        edit: syntaxHighlightEdit,
        previousDocumentRevision:
          hasExplicitStatisticsEdit && canPublishBodyChange && editIsBodyOnly
          && previousBodyUTF16Offset == bodyUTF16Offset ? previousSyntaxRevision : nil
      )
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
        enqueueContextualAnchorPublication(nil)
        return
      }
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.requestSelectionReveal()
      updateSelectionBinding(from: textView.selectedRange())
      publishContextualAnchor(in: textView)
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
