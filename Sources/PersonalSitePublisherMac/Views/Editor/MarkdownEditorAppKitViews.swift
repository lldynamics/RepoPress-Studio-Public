import AppKit
import OSLog
import PublishingWorkbenchCore

final class MarkdownEditorScrollView: NSScrollView {
  private var cachedLayoutWidth: CGFloat = 0
  private var cachedTextHeight: CGFloat?
  private var heightInvalidationWorkItem: DispatchWorkItem?
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  private enum PerformanceAutoScrollPattern: String {
    case forward
    case pingPong = "ping-pong"
    case loop
  }

  private struct PerformanceAutoTypingEdit {
    let range: NSRange
    let replacement: String
    let operation: String
    let unicodeClass: String
  }

  private static let performanceAutoScrollEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL"
  private static let performanceAutoScrollDurationEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL_DURATION_SECONDS"
  private static let performanceAutoScrollStartDelayEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL_START_DELAY_SECONDS"
  private static let performanceAutoScrollPatternEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL_PATTERN"
  private static let performanceAutoScrollCyclesEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_SCROLL_CYCLES"
  private static let performanceAutoTypingEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING"
  private static let performanceAutoTypingStartDelayEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING_START_DELAY_SECONDS"
  private static let performanceAutoTypingIntervalEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING_INTERVAL_MILLISECONDS"
  private static let performanceAutoTypingEditsEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING_EDITS"
  private static let performanceAutoTypingSettleDelayEnvironmentKey =
    "PERSONAL_SITE_PUBLISHER_PERFORMANCE_AUTO_TYPING_SETTLE_DELAY_SECONDS"
  private static let performanceSignposter = OSSignposter(
    subsystem: "com.jinfang.PersonalSitePublisherMac",
    category: "MarkdownPerformanceHarness"
  )
  private var performanceScrollStartWorkItem: DispatchWorkItem?
  private var performanceScrollTimer: Timer?
  private var performanceScrollIntervalState: OSSignpostIntervalState?
  private var performanceScrollStartTime: TimeInterval?
  private var performanceScrollStepCount = 0
  private var performanceScrollTargetLocation = 0
  private var performanceScrollPattern = PerformanceAutoScrollPattern.pingPong
  private var performanceScrollCycleCount = 1
  private var performanceScrollCompletedCycleCount = 0
  private var performanceTypingStartWorkItem: DispatchWorkItem?
  private var performanceTypingTimer: Timer?
  private var performanceTypingIntervalState: OSSignpostIntervalState?
  private var performanceTypingStopWorkItem: DispatchWorkItem?
  private var performanceTypingEditCount = 0
  private var performanceTypingRequestedEditCount = 0
  private var performanceTypingHasStarted = false
#endif
  var preferredBodyWidth = CGFloat(MarkdownEditorComfortConfiguration.defaultBodyWidth) {
    didSet {
      guard abs(oldValue - preferredBodyWidth) > 0.5 else { return }
      cachedLayoutWidth = 0
      invalidateDocumentHeight(immediately: true)
    }
  }

  override var acceptsFirstResponder: Bool { false }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    if window == nil {
      stopPerformanceAutoScroll()
      stopPerformanceAutoTyping()
    } else {
      schedulePerformanceInteractionIfNeeded()
    }
#endif
  }

  func invalidateDocumentHeight(immediately: Bool = false) {
    heightInvalidationWorkItem?.cancel()
    if immediately {
      cachedTextHeight = nil
      needsLayout = true
      return
    }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.cachedTextHeight = nil
      self.needsLayout = true
    }
    heightInvalidationWorkItem = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.075, execute: workItem)
  }

  override func layout() {
    super.layout()
    guard let textView = documentView as? NSTextView else { return }

    let contentHeight = contentSize.height
    let contentWidth = max(contentSize.width, 1)
    let availableBodyWidth = max(contentWidth - 32, 1)
    let bodyWidth = min(preferredBodyWidth, availableBodyWidth)
    let horizontalInset: CGFloat = 16
    let layoutWidth = bodyWidth
    let widthChanged = abs(cachedLayoutWidth - layoutWidth) > 0.5
    if widthChanged {
      textView.textContainer?.containerSize = NSSize(
        width: layoutWidth,
        height: CGFloat.greatestFiniteMagnitude
      )
      cachedTextHeight = nil
      cachedLayoutWidth = layoutWidth
    }
    let textContainerInset = NSSize(width: horizontalInset, height: 16)
    if textView.textContainerInset != textContainerInset {
      textView.textContainerInset = textContainerInset
    }
    let textHeight =
      textView.textLayoutManager.map { textLayoutManager in
        if let cachedTextHeight {
          return cachedTextHeight
        }
        let measuredHeight =
          textLayoutManager.usageBoundsForTextContainer.height
          + textView.textContainerInset.height * 2
        cachedTextHeight = measuredHeight
        return measuredHeight
      } ?? contentHeight

    let documentSize = NSSize(
      width: contentWidth,
      height: max(contentHeight, textHeight, 1)
    )
    if textView.frame.size != documentSize {
      textView.setFrameSize(documentSize)
    }
#if DEBUG || SCREENSHOT_CAPTURE_BUILD
    schedulePerformanceInteractionIfNeeded()
#endif
  }

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  private static var isPerformanceAutoScrollEnabled: Bool {
    let value = (ProcessInfo.processInfo.environment[performanceAutoScrollEnvironmentKey] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return value == "1" || value == "true" || value == "yes"
  }

  private static var isPerformanceAutoTypingEnabled: Bool {
    let value = (ProcessInfo.processInfo.environment[performanceAutoTypingEnvironmentKey] ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    return value == "1" || value == "true" || value == "yes"
  }

  private static var performanceAutoScrollDuration: TimeInterval {
    let configured = ProcessInfo.processInfo.environment[
      performanceAutoScrollDurationEnvironmentKey
    ].flatMap(Double.init)
    return min(max(configured ?? 12, 1), 120)
  }

  private static var performanceAutoScrollStartDelay: TimeInterval {
    let configured = ProcessInfo.processInfo.environment[
      performanceAutoScrollStartDelayEnvironmentKey
    ].flatMap(Double.init)
    return min(max(configured ?? 4, 0.5), 15)
  }

  private static var performanceAutoScrollPattern: PerformanceAutoScrollPattern {
    let configured = ProcessInfo.processInfo.environment[
      performanceAutoScrollPatternEnvironmentKey
    ]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return PerformanceAutoScrollPattern(rawValue: configured ?? "") ?? .pingPong
  }

  private static var performanceAutoScrollCycles: Int {
    let configured = ProcessInfo.processInfo.environment[
      performanceAutoScrollCyclesEnvironmentKey
    ].flatMap(Int.init)
    return min(max(configured ?? 4, 1), 32)
  }

  private static var performanceAutoTypingStartDelay: TimeInterval {
    let configured = ProcessInfo.processInfo.environment[
      performanceAutoTypingStartDelayEnvironmentKey
    ].flatMap(Double.init)
    return min(max(configured ?? 4, 0.5), 15)
  }

  private static var performanceAutoTypingInterval: TimeInterval {
    let configured = ProcessInfo.processInfo.environment[
      performanceAutoTypingIntervalEnvironmentKey
    ].flatMap(Double.init)
    return min(max((configured ?? 120) / 1_000, 0.016), 2)
  }

  private static var performanceAutoTypingEdits: Int {
    let configured = ProcessInfo.processInfo.environment[
      performanceAutoTypingEditsEnvironmentKey
    ].flatMap(Int.init)
    return min(max(configured ?? 24, 6), 240)
  }

  private static var performanceAutoTypingSettleDelay: TimeInterval {
    let configured = ProcessInfo.processInfo.environment[
      performanceAutoTypingSettleDelayEnvironmentKey
    ].flatMap(Double.init)
    return min(max(configured ?? 0.5, 0.1), 2)
  }

  private func schedulePerformanceInteractionIfNeeded() {
    guard !(Self.isPerformanceAutoScrollEnabled && Self.isPerformanceAutoTypingEnabled) else {
      return
    }
    if Self.isPerformanceAutoTypingEnabled {
      schedulePerformanceAutoTypingIfNeeded()
    } else {
      schedulePerformanceAutoScrollIfNeeded()
    }
  }

  private func schedulePerformanceAutoScrollIfNeeded() {
    guard Self.isPerformanceAutoScrollEnabled,
      window != nil,
      performanceScrollTimer == nil,
      performanceScrollStartWorkItem == nil,
      performanceScrollableDocumentLength > 1
    else {
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.startPerformanceAutoScroll()
    }
    performanceScrollStartWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.performanceAutoScrollStartDelay,
      execute: workItem
    )
  }

  private func schedulePerformanceAutoTypingIfNeeded() {
    guard Self.isPerformanceAutoTypingEnabled,
      window != nil,
      performanceTypingTimer == nil,
      performanceTypingStartWorkItem == nil,
      !performanceTypingHasStarted,
      performanceScrollableDocumentLength > 1
    else {
      return
    }

    let workItem = DispatchWorkItem { [weak self] in
      self?.startPerformanceAutoTyping()
    }
    performanceTypingStartWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.performanceAutoTypingStartDelay,
      execute: workItem
    )
  }

  private func startPerformanceAutoScroll() {
    performanceScrollStartWorkItem = nil
    guard Self.isPerformanceAutoScrollEnabled,
      window != nil,
      performanceScrollTimer == nil,
      performanceScrollableDocumentLength > 1
    else {
      return
    }

    let signpostID = Self.performanceSignposter.makeSignpostID()
    performanceScrollPattern = Self.performanceAutoScrollPattern
    performanceScrollCycleCount = performanceScrollPattern == .forward
      ? 1
      : Self.performanceAutoScrollCycles
    performanceScrollCompletedCycleCount = 0
    performanceScrollIntervalState = Self.performanceSignposter.beginInterval(
      "AutoScroll",
      id: signpostID,
      "documentLength: \(self.performanceScrollableDocumentLength, privacy: .public), viewportHeight: \(self.contentView.bounds.height, privacy: .public), pattern: \(self.performanceScrollPattern.rawValue, privacy: .public), cycles: \(self.performanceScrollCycleCount, privacy: .public)"
    )
    performanceScrollStepCount = 0
    performanceScrollTargetLocation = 0
    performanceScrollStartTime = ProcessInfo.processInfo.systemUptime
    if MarkdownTextKit2ReadOnlyPresentationPolicy.isEnabled,
      let textView = documentView as? NSTextView
    {
      // Cycle the derived document after Instruments has attached so the
      // native presentation install is observable inside the AutoScroll
      // interval. The ordinary app never enters this capture-only branch.
      _ = window?.makeFirstResponder(textView)
      _ = window?.makeFirstResponder(nil)
    }
    let interval: TimeInterval = 1.0 / 30.0
    let timer = Timer(
      timeInterval: interval,
      target: self,
      selector: #selector(performPerformanceAutoScrollStep),
      userInfo: nil,
      repeats: true
    )
    performanceScrollTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  @objc private func performPerformanceAutoScrollStep() {
    guard window != nil,
      let textView = documentView as? NSTextView
    else {
      stopPerformanceAutoScroll()
      return
    }
    let documentLength = (textView.string as NSString).length
    guard documentLength > 1,
      let startTime = performanceScrollStartTime
    else {
      stopPerformanceAutoScroll()
      return
    }
    let elapsed = max(0, ProcessInfo.processInfo.systemUptime - startTime)
    let progress = min(elapsed / Self.performanceAutoScrollDuration, 1)
    let cycleProgress = min(
      progress * Double(performanceScrollCycleCount),
      Double(performanceScrollCycleCount)
    )
    performanceScrollCompletedCycleCount = min(
      performanceScrollCycleCount,
      Int(cycleProgress.rounded(.down))
    )
    let cycleIndex = min(
      max(Int(cycleProgress.rounded(.down)), 0),
      performanceScrollCycleCount - 1
    )
    let fraction = cycleProgress >= Double(performanceScrollCycleCount)
      ? 1
      : cycleProgress - Double(cycleIndex)
    let movesForward: Bool
    switch performanceScrollPattern {
    case .forward, .loop:
      movesForward = true
    case .pingPong:
      movesForward = cycleIndex.isMultiple(of: 2)
    }
    let normalizedProgress = movesForward ? fraction : 1 - fraction
    performanceScrollTargetLocation = min(
      documentLength - 1,
      max(0, Int(Double(documentLength - 1) * normalizedProgress))
    )
    // Trackpad, wheel, and scrollbar interactions move the clip view in
    // document coordinates. Resolving a far-away character range on every
    // 30 Hz harness tick instead asks TextKit to synchronously bridge all
    // intervening layout fragments, which measures an artificial seek path
    // rather than viewport scrolling.
    let maximumOffset = max(0, textView.frame.height - contentView.bounds.height)
    let recordsMeasuredStep = (performanceScrollStepCount + 1).isMultiple(of: 15)
    let measuredStepInterval = recordsMeasuredStep
      ? Self.performanceSignposter.beginInterval(
        "AutoScrollStep",
        id: Self.performanceSignposter.makeSignpostID()
      )
      : nil
    contentView.scroll(
      to: NSPoint(
        x: contentView.bounds.minX,
        y: maximumOffset * normalizedProgress
      )
    )
    reflectScrolledClipView(contentView)
    performanceScrollStepCount += 1
    if let measuredStepInterval {
      Self.performanceSignposter.endInterval(
        "AutoScrollStep",
        measuredStepInterval,
        "stepIndex: \(self.performanceScrollStepCount, privacy: .public)"
      )
    }
    if progress >= 1 {
      stopPerformanceAutoScroll()
    }
  }

  private func startPerformanceAutoTyping() {
    performanceTypingStartWorkItem = nil
    guard Self.isPerformanceAutoTypingEnabled,
      window != nil,
      performanceTypingTimer == nil,
      !performanceTypingHasStarted,
      performanceScrollableDocumentLength > 1
    else {
      return
    }

    performanceTypingHasStarted = true
    performanceTypingEditCount = 0
    performanceTypingRequestedEditCount = Self.performanceAutoTypingEdits
    if let textView = documentView as? NSTextView {
      _ = window?.makeFirstResponder(textView)
    }
    let signpostID = Self.performanceSignposter.makeSignpostID()
    performanceTypingIntervalState = Self.performanceSignposter.beginInterval(
      "AutoTyping",
      id: signpostID,
      "documentLength: \(self.performanceScrollableDocumentLength, privacy: .public), requestedEdits: \(self.performanceTypingRequestedEditCount, privacy: .public), mode: programmatic, imeComposition: false"
    )
    let timer = Timer(
      timeInterval: Self.performanceAutoTypingInterval,
      target: self,
      selector: #selector(performPerformanceAutoTypingStep),
      userInfo: nil,
      repeats: true
    )
    performanceTypingTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  @objc private func performPerformanceAutoTypingStep() {
    guard window != nil,
      let textView = documentView as? NSTextView,
      performanceTypingEditCount < performanceTypingRequestedEditCount
    else {
      stopPerformanceAutoTyping()
      return
    }
    guard let edit = performanceAutoTypingEdit(
      at: performanceTypingEditCount,
      in: textView.string
    ),
      NSMaxRange(edit.range) <= (textView.string as NSString).length
    else {
      stopPerformanceAutoTyping()
      return
    }

    let editIndex = performanceTypingEditCount + 1
    let stepIntervalState = Self.performanceSignposter.beginInterval(
      "AutoTypingStep",
      id: Self.performanceSignposter.makeSignpostID(),
      "editIndex: \(editIndex, privacy: .public), operation: \(edit.operation, privacy: .public), replacedUTF16Length: \(edit.range.length, privacy: .public), replacementUTF16Length: \((edit.replacement as NSString).length, privacy: .public), unicode: \(edit.unicodeClass, privacy: .public)"
    )
    textView.insertText(edit.replacement, replacementRange: edit.range)
    Self.performanceSignposter.endInterval(
      "AutoTypingStep",
      stepIntervalState,
      "editIndex: \(editIndex, privacy: .public), completed: true"
    )
    let selectedLocation = min(
      edit.range.location + (edit.replacement as NSString).length,
      (textView.string as NSString).length
    )
    textView.setSelectedRange(NSRange(location: selectedLocation, length: 0))
    performanceTypingEditCount += 1
    if performanceTypingEditCount >= performanceTypingRequestedEditCount {
      schedulePerformanceAutoTypingStop()
    }
  }

  private func schedulePerformanceAutoTypingStop() {
    performanceTypingTimer?.invalidate()
    performanceTypingTimer = nil
    performanceTypingStopWorkItem?.cancel()
    let workItem = DispatchWorkItem { [weak self] in
      self?.stopPerformanceAutoTyping()
    }
    performanceTypingStopWorkItem = workItem
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.performanceAutoTypingSettleDelay,
      execute: workItem
    )
  }

  private func performanceAutoTypingEdit(
    at index: Int,
    in text: String
  ) -> PerformanceAutoTypingEdit? {
    let source = text as NSString
    let marker = source.range(of: "offscreen attribute writes bounded")
    guard marker.location != NSNotFound else { return nil }
    let insertionLocation = NSMaxRange(marker)
    let searchRange = NSRange(
      location: insertionLocation,
      length: max(0, source.length - insertionLocation)
    )
    switch index % 6 {
    case 0:
      return PerformanceAutoTypingEdit(
        range: NSRange(location: insertionLocation, length: 0),
        replacement: "增量",
        operation: "insert-chinese",
        unicodeClass: "chinese"
      )
    case 1:
      return PerformanceAutoTypingEdit(
        range: NSRange(location: insertionLocation, length: 0),
        replacement: "🚀",
        operation: "insert-emoji",
        unicodeClass: "emoji"
      )
    case 2:
      let range = source.range(of: "增量", options: [], range: searchRange)
      guard range.location != NSNotFound else { return nil }
      return PerformanceAutoTypingEdit(
        range: range,
        replacement: "局部",
        operation: "replace-chinese",
        unicodeClass: "chinese"
      )
    case 3:
      let range = source.range(of: "🚀", options: [], range: searchRange)
      guard range.location != NSNotFound else { return nil }
      return PerformanceAutoTypingEdit(
        range: range,
        replacement: "",
        operation: "delete-emoji",
        unicodeClass: "emoji"
      )
    case 4:
      let range = source.range(of: "局部", options: [], range: searchRange)
      guard range.location != NSNotFound else { return nil }
      return PerformanceAutoTypingEdit(
        range: range,
        replacement: "增量",
        operation: "replace-chinese",
        unicodeClass: "chinese"
      )
    default:
      let range = source.range(of: "增量", options: [], range: searchRange)
      guard range.location != NSNotFound else { return nil }
      return PerformanceAutoTypingEdit(
        range: range,
        replacement: "",
        operation: "delete-chinese",
        unicodeClass: "chinese"
      )
    }
  }

  private func stopPerformanceAutoScroll() {
    performanceScrollStartWorkItem?.cancel()
    performanceScrollStartWorkItem = nil
    performanceScrollTimer?.invalidate()
    performanceScrollTimer = nil
    performanceScrollStartTime = nil
    guard let intervalState = performanceScrollIntervalState else { return }
    Self.performanceSignposter.endInterval(
      "AutoScroll",
      intervalState,
      "stepCount: \(self.performanceScrollStepCount, privacy: .public), completedCycles: \(self.performanceScrollCompletedCycleCount, privacy: .public), finalOffset: \(self.contentView.bounds.minY, privacy: .public)"
    )
    performanceScrollIntervalState = nil
  }

  private func stopPerformanceAutoTyping() {
    performanceTypingStartWorkItem?.cancel()
    performanceTypingStartWorkItem = nil
    performanceTypingStopWorkItem?.cancel()
    performanceTypingStopWorkItem = nil
    performanceTypingTimer?.invalidate()
    performanceTypingTimer = nil
    guard let intervalState = performanceTypingIntervalState else { return }
    Self.performanceSignposter.endInterval(
      "AutoTyping",
      intervalState,
      "completedEdits: \(self.performanceTypingEditCount, privacy: .public), requestedEdits: \(self.performanceTypingRequestedEditCount, privacy: .public), mode: programmatic, imeComposition: false"
    )
    performanceTypingIntervalState = nil
  }

  private var performanceScrollableDocumentLength: Int {
    guard let textView = documentView as? NSTextView else { return 0 }
    return (textView.string as NSString).length
  }
#endif
}
final class DroppableMarkdownTextView: NSTextView {
  static func makeTextKit2(
    frame: NSRect = .zero,
    containerSize: NSSize
  ) -> DroppableMarkdownTextView {
    let textView = DroppableMarkdownTextView(usingTextLayoutManager: true)
    textView.frame = frame
    textView.textContainer?.containerSize = containerSize
    textView.registerMarkdownDraggedTypes()
    return textView
  }

  var fileDropTargetChangedHandler: ((Bool) -> Void)?
  var fileDropHandler: (([URL], NSRange) -> Void)?
  var knowledgeMarkdownDropHandler: ((String, NSRange, KnowledgeCitation?) -> Void)?
  var smartPasteHandler: ((NSTextView, any MarkdownPasteboardSource) -> Bool)?
  var pasteboardProvider: () -> any MarkdownPasteboardSource = { NSPasteboard.general }
  var fileDropImageURLsProvider: (NSPasteboard) -> [URL] = {
    MarkdownPasteboardReader.imageFileURLs(from: $0)
  }
  var knowledgeMarkdownProvider: (NSPasteboard) -> String? = { pasteboard in
    guard
      let data = pasteboard.data(
        forType: KnowledgeArticleInsertionService.knowledgeMarkdownPasteboardType
      )
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ).nilIfEmpty
  }
  var knowledgeCitationProvider: (NSPasteboard) -> KnowledgeCitation? = {
    KnowledgeArticleInsertionService.citation(from: $0)
  }
  var markdownFormattingHandler: ((NSTextView, MarkdownFormattingCommand) -> Bool)?
  var markdownLineEditingHandler: ((NSTextView, MarkdownLineEditingCommand) -> Bool)?
  var markdownTableContextProvider: ((NSTextView) -> MarkdownTableEditingContext?)?
  var markdownTableEditingHandler: ((NSTextView, MarkdownTableEditingCommand) -> Bool)?
  var slashCommandKeyHandler: ((MarkdownSlashCommandKey) -> Bool)?
  var ghostTextAcceptHandler: (() -> Bool)?
  var ghostTextDismissHandler: (() -> Bool)?
  var inlineAIRequestHandler: (() -> Void)?
  /// Visible block markers are painted by the text view itself. Keeping this
  /// as value state avoids one AppKit child view (and one Core Animation
  /// commit) for every list/quote/task marker in the viewport.
  var markdownBlockMarkerDrawings: [MarkdownBlockMarkerDrawing] = [] {
    didSet {
      guard oldValue != markdownBlockMarkerDrawings else { return }
      updateMarkdownTaskCheckboxAccessibilityElements()
      needsDisplay = true
    }
  }
  private(set) var markdownTaskCheckboxAccessibilityElements:
    [MarkdownTaskCheckboxAccessibilityElement] = []
  var markdownBlockMarkerFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
  var markdownBlockMarkerTaskToggleHandler: ((NSRange, Bool) -> Void)?
  /// Paint-only image and formula cards keyed by their source location.
  /// Updating this value invalidates only changed frames and keeps the
  /// NSTextView hierarchy constant while scrolling or editing.
  var markdownInlineAttachmentDrawings: [String: MarkdownInlineAttachmentDrawing] = [:] {
    didSet {
      guard oldValue != markdownInlineAttachmentDrawings else { return }
      updateMarkdownInlineAttachmentAccessibilityElements()
      let changedKeys = Set(oldValue.keys).union(markdownInlineAttachmentDrawings.keys).filter {
        oldValue[$0] != markdownInlineAttachmentDrawings[$0]
      }
      let invalidatedRect = changedKeys.reduce(NSRect.null) { result, key in
        let oldFrame = oldValue[key]?.frame ?? .null
        let newFrame = markdownInlineAttachmentDrawings[key]?.frame ?? .null
        return result.union(oldFrame).union(newFrame)
      }
      if invalidatedRect.isNull || invalidatedRect.isEmpty {
        needsDisplay = true
      } else {
        setNeedsDisplay(invalidatedRect)
      }
    }
  }
  private(set) var markdownInlineAttachmentAccessibilityElements:
    [MarkdownInlineAttachmentAccessibilityElement] = []
  private var markdownInlineAttachmentAccessibilityElementsByKey:
    [String: MarkdownInlineAttachmentAccessibilityElement] = [:]
  /// The current paragraph spotlight is painted in drawBackground(in:) so it
  /// does not enter TextKit's rendering-attribute invalidation path.
  var markdownParagraphHighlightRect: NSRect? {
    didSet {
      guard oldValue != markdownParagraphHighlightRect else { return }
      let invalidatedRect = oldValue?.union(markdownParagraphHighlightRect ?? .null)
      if let invalidatedRect, !invalidatedRect.isNull, !invalidatedRect.isEmpty {
        setNeedsDisplay(invalidatedRect)
      } else {
        needsDisplay = true
      }
    }
  }
  var markdownParagraphHighlightColor = NSColor.controlAccentColor.withAlphaComponent(0.07)
  /// Paint-only current hunk decoration.  This is intentionally not a text
  /// storage attribute, so review state cannot leak into saved Markdown.
  var markdownInlineAIReviewRange: NSRange? {
    didSet {
      guard oldValue != markdownInlineAIReviewRange else { return }
      needsDisplay = true
    }
  }
  /// Called once when AppKit begins a new first-responder cycle for this view.
  ///
  /// The editor coordinator uses this narrow bridge to restore the editable
  /// Markdown projection before focus returns to the text view.  It is not
  /// called when the text view is already the window's first responder.
  var willBecomeFirstResponderHandler: (() -> Void)?
  /// Called once after this view successfully resigns first responder.
  ///
  /// The editor coordinator uses this to install its read-only presentation
  /// projection only after AppKit has completed the focus transition.
  var didResignFirstResponderHandler: (() -> Void)?
  private var isFileDropTargeted = false
  private var isPreparingFirstResponder = false
  private var isResigningFirstResponder = false
  private var hasPreparedCurrentFocusCycle = false
  private var hasAnnouncedResignationForCurrentFocus = false

  override func accessibilityChildren() -> [Any]? {
    let existingChildren = super.accessibilityChildren() ?? []
    let markdownChildren: [Any] = markdownTaskCheckboxAccessibilityElements.map { $0 as Any }
      + markdownInlineAttachmentAccessibilityElements.map { $0 as Any }
    guard !markdownChildren.isEmpty else {
      return existingChildren.isEmpty ? nil : existingChildren
    }
    return existingChildren + markdownChildren
  }

  private func updateMarkdownTaskCheckboxAccessibilityElements() {
    markdownTaskCheckboxAccessibilityElements = markdownBlockMarkerDrawings.compactMap {
      drawing in
      guard case .taskList(let isChecked) = drawing.marker.presentation else {
        return nil
      }
      return MarkdownTaskCheckboxAccessibilityElement(
        markerRange: drawing.marker.range,
        frame: drawing.frame,
        isChecked: isChecked,
        parent: self,
        onPress: { [weak self] markerRange, checked in
          self?.markdownBlockMarkerTaskToggleHandler?(markerRange, checked)
        }
      )
    }
  }

  private func updateMarkdownInlineAttachmentAccessibilityElements() {
    var nextElementsByKey: [String: MarkdownInlineAttachmentAccessibilityElement] = [:]
    var nextElements: [MarkdownInlineAttachmentAccessibilityElement] = []
    for drawing in markdownInlineAttachmentDrawings.values.sorted(by: {
      $0.documentRange.location < $1.documentRange.location
    }) {
      let element = markdownInlineAttachmentAccessibilityElementsByKey[drawing.key]
        ?? MarkdownInlineAttachmentAccessibilityElement(drawing: drawing, parent: self)
      element.update(with: drawing)
      nextElementsByKey[drawing.key] = element
      nextElements.append(element)
    }
    markdownInlineAttachmentAccessibilityElementsByKey = nextElementsByKey
    markdownInlineAttachmentAccessibilityElements = nextElements
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    registerMarkdownDraggedTypes()
  }

  private func registerMarkdownDraggedTypes() {
    registerForDraggedTypes([
      .fileURL,
      KnowledgeArticleInsertionService.knowledgeMarkdownPasteboardType,
      KnowledgeArticleInsertionService.knowledgeCitationPasteboardType,
    ])
  }

  override var acceptsFirstResponder: Bool { true }

  override var canBecomeKeyView: Bool { true }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    true
  }

  override func drawBackground(in dirtyRect: NSRect) {
    super.drawBackground(in: dirtyRect)
    if let highlightRect = markdownParagraphHighlightRect {
      let clippedRect = highlightRect.intersection(dirtyRect)
      if !clippedRect.isNull, !clippedRect.isEmpty {
        markdownParagraphHighlightColor.setFill()
        clippedRect.fill()
      }
    }
    if let range = markdownInlineAIReviewRange,
      let rect = MarkdownTextKit2RangeAdapter.rect(for: range, in: self),
      rect.intersects(dirtyRect)
    {
      NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
      var decorationRect = rect.insetBy(dx: -2, dy: -1)
      if decorationRect.width < 4 { decorationRect.size.width = 4 }
      NSBezierPath(roundedRect: decorationRect, xRadius: 4, yRadius: 4).fill()
    }
    drawMarkdownBlockMarkers(in: dirtyRect)
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    drawMarkdownInlineAttachments(in: dirtyRect)
  }

  private func drawMarkdownInlineAttachments(in dirtyRect: NSRect) {
    for drawing in markdownInlineAttachmentDrawings.values
      where drawing.frame.intersects(dirtyRect)
    {
      NSGraphicsContext.saveGraphicsState()
      let displayMode: MarkdownFormulaDisplayMode? = {
        guard case .formula(_, let mode, _) = drawing.content else { return nil }
        return mode
      }()
      let cornerRadius: CGFloat = displayMode == .inline ? 5 : 10
      let backgroundAlpha: CGFloat = displayMode == .inline ? 0.68 : 0.86
      let cardPath = NSBezierPath(
        roundedRect: drawing.frame,
        xRadius: cornerRadius,
        yRadius: cornerRadius
      )
      NSColor.textBackgroundColor.withAlphaComponent(backgroundAlpha).setFill()
      cardPath.fill()
      NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
      cardPath.lineWidth = 1
      cardPath.stroke()

      switch drawing.content {
      case .image:
        let contentRect = drawing.frame.insetBy(dx: 8, dy: 8)
        if let image = drawing.image, image.size.width > 0, image.size.height > 0 {
          let scale = min(
            contentRect.width / image.size.width,
            contentRect.height / image.size.height
          )
          let size = NSSize(
            width: image.size.width * scale,
            height: image.size.height * scale
          )
          let imageRect = NSRect(
            x: contentRect.midX - size.width / 2,
            y: contentRect.midY - size.height / 2,
            width: size.width,
            height: size.height
          )
          image.draw(
            in: imageRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
          )
        } else if let placeholder = NSImage(
          systemSymbolName: "photo",
          accessibilityDescription: nil
        )?.withSymbolConfiguration(
          NSImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        ) {
          let placeholderRect = NSRect(
            x: contentRect.midX - placeholder.size.width / 2,
            y: contentRect.midY - placeholder.size.height / 2,
            width: placeholder.size.width,
            height: placeholder.size.height
          )
          placeholder.draw(in: placeholderRect)
        }
      case .formula(let source, _, let fontSize):
        let contentRect = drawing.frame.insetBy(dx: 12, dy: 4)
        MarkdownInlineFormulaPresentation.attributedString(
          for: source,
          fontSize: fontSize
        ).draw(
          with: contentRect,
          options: [
            .usesLineFragmentOrigin,
            .usesFontLeading,
            .truncatesLastVisibleLine,
          ]
        )
      }
      NSGraphicsContext.restoreGraphicsState()
    }
  }

  override func becomeFirstResponder() -> Bool {
    guard !isPreparingFirstResponder else {
      return true
    }

    isPreparingFirstResponder = true
    defer { isPreparingFirstResponder = false }
    if !hasPreparedCurrentFocusCycle {
      // NSWindow may already expose this view as `firstResponder` by the time
      // AppKit enters this override. Track the focus cycle locally instead of
      // consulting window state, otherwise the source-restoration hook is
      // skipped on every ordinary `makeFirstResponder` transition.
      hasPreparedCurrentFocusCycle = true
      willBecomeFirstResponderHandler?()
    }

    let didBecomeFirstResponder = super.becomeFirstResponder()
    if didBecomeFirstResponder {
      hasAnnouncedResignationForCurrentFocus = false
    } else {
      hasPreparedCurrentFocusCycle = false
    }
    return didBecomeFirstResponder
  }

  override func resignFirstResponder() -> Bool {
    guard !isResigningFirstResponder else {
      return true
    }

    let wasFirstResponder = window?.firstResponder === self
    // AppKit's NSTextView implementation expects `super` to be called only
    // from the active responder transition. Treat duplicate/manual resigns
    // after that transition as an idempotent no-op.
    guard wasFirstResponder else { return true }
    isResigningFirstResponder = true
    defer { isResigningFirstResponder = false }
    let didResignFirstResponder = super.resignFirstResponder()
    guard
      didResignFirstResponder,
      wasFirstResponder,
      !hasAnnouncedResignationForCurrentFocus
    else {
      return didResignFirstResponder
    }

    // Mark before invoking user code so a handler that synchronously asks
    // AppKit to resign again cannot produce a duplicate notification.
    hasPreparedCurrentFocusCycle = false
    hasAnnouncedResignationForCurrentFocus = true
    didResignFirstResponderHandler?()
    return didResignFirstResponder
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if handleMarkdownBlockMarkerClick(at: point) { return }
    super.mouseDown(with: event)
    if window?.firstResponder !== self {
      window?.makeFirstResponder(self)
    }
  }

  override func keyDown(with event: NSEvent) {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    let shortcutModifiers = event.modifierFlags.intersection([
      .command, .control, .option, .shift,
    ])
    if let slashCommandKey = MarkdownSlashCommandKey.from(
      keyCode: event.keyCode,
      modifiers: event.modifierFlags
    ), slashCommandKeyHandler?(slashCommandKey) == true {
      return
    }

    // Keyboard line operations: Move, Duplicate, Delete, Comment
    if event.keyCode == 126 {  // Up arrow
      if modifiers == .option {
        if markdownLineEditingHandler?(self, .moveUp) == true { return }
      } else if modifiers == [.shift, .option] {
        if markdownLineEditingHandler?(self, .duplicateAbove) == true { return }
      }
    } else if event.keyCode == 125 {  // Down arrow
      if modifiers == .option {
        if markdownLineEditingHandler?(self, .moveDown) == true { return }
      } else if modifiers == [.shift, .option] {
        if markdownLineEditingHandler?(self, .duplicateBelow) == true { return }
      }
    } else if event.keyCode == 40 {  // 'K' key
      if modifiers == [.command, .shift] {
        if markdownLineEditingHandler?(self, .deleteLine) == true { return }
      }
    } else if event.keyCode == 44 || event.characters == "/" {  // '/' key
      if modifiers == .command {
        if markdownLineEditingHandler?(self, .toggleComment) == true { return }
      }
    }

    // kVK_ANSI_Backslash (0x2A): Option + backslash explicitly requests
    // inline AI. Consume repeats without issuing another network request.
    if !hasMarkedText(),
      event.keyCode == 0x2A,
      shortcutModifiers == .option,
      let inlineAIRequestHandler
    {
      if !event.isARepeat {
        inlineAIRequestHandler()
      }
      return
    }

    if !hasMarkedText(), event.keyCode == 48 {  // Tab key
      if modifiers.isEmpty, ghostTextAcceptHandler?() == true {
        return
      }
      if modifiers.contains(.control) {
        if modifiers.contains(.shift) {
          window?.selectPreviousKeyView(self)
        } else {
          window?.selectNextKeyView(self)
        }
        return
      }
    } else if !hasMarkedText(), event.keyCode == 53 {  // Esc key
      if modifiers.isEmpty, ghostTextDismissHandler?() == true {
        return
      }
    }

    super.keyDown(with: event)
  }

  override func paste(_ sender: Any?) {
    guard smartPasteHandler?(self, pasteboardProvider()) == true else {
      super.paste(sender)
      return
    }
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    guard let context = markdownTableContextProvider?(self) else {
      return super.menu(for: event)
    }

    let menu = super.menu(for: event) ?? NSMenu()
    if !menu.items.isEmpty, menu.items.last?.isSeparatorItem != true {
      menu.addItem(.separator())
    }

    let tableMenu = NSMenu(title: String(localized: "Markdown 表格"))
    tableMenu.autoenablesItems = false
    tableMenu.addItem(
      tableMenuItem(
        title: String(localized: "格式化表格"),
        action: #selector(formatMarkdownTable(_:))
      ))
    tableMenu.addItem(.separator())
    tableMenu.addItem(
      tableMenuItem(
        title: String(localized: "在上方插入行"),
        action: #selector(insertMarkdownTableRowAbove(_:))
      ))
    tableMenu.addItem(
      tableMenuItem(
        title: String(localized: "在下方插入行"),
        action: #selector(insertMarkdownTableRowBelow(_:))
      ))
    tableMenu.addItem(
      tableMenuItem(
        title: String(localized: "删除当前行"),
        action: #selector(deleteMarkdownTableRow(_:)),
        isEnabled: context.canDeleteRow
      ))
    tableMenu.addItem(.separator())
    tableMenu.addItem(
      tableMenuItem(
        title: String(localized: "在左侧插入列"),
        action: #selector(insertMarkdownTableColumnBefore(_:))
      ))
    tableMenu.addItem(
      tableMenuItem(
        title: String(localized: "在右侧插入列"),
        action: #selector(insertMarkdownTableColumnAfter(_:))
      ))
    tableMenu.addItem(
      tableMenuItem(
        title: String(localized: "删除当前列"),
        action: #selector(deleteMarkdownTableColumn(_:)),
        isEnabled: context.canDeleteColumn
      ))

    let tableMenuItem = NSMenuItem(
      title: String(localized: "Markdown 表格"),
      action: nil,
      keyEquivalent: ""
    )
    tableMenuItem.submenu = tableMenu
    menu.addItem(tableMenuItem)
    return menu
  }

  private func tableMenuItem(
    title: String,
    action: Selector,
    isEnabled: Bool = true
  ) -> NSMenuItem {
    let item = NSMenuItem(
      title: title,
      action: action,
      keyEquivalent: ""
    )
    item.target = self
    item.isEnabled = isEnabled
    return item
  }

  @objc(formatMarkdownTable:)
  private func formatMarkdownTable(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .format)
  }

  @objc(insertMarkdownTableRowAbove:)
  private func insertMarkdownTableRowAbove(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .insertRowAbove)
  }

  @objc(insertMarkdownTableRowBelow:)
  private func insertMarkdownTableRowBelow(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .insertRowBelow)
  }

  @objc(deleteMarkdownTableRow:)
  private func deleteMarkdownTableRow(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .deleteRow)
  }

  @objc(insertMarkdownTableColumnBefore:)
  private func insertMarkdownTableColumnBefore(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .insertColumnBefore)
  }

  @objc(insertMarkdownTableColumnAfter:)
  private func insertMarkdownTableColumnAfter(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .insertColumnAfter)
  }

  @objc(deleteMarkdownTableColumn:)
  private func deleteMarkdownTableColumn(_ sender: Any?) {
    _ = markdownTableEditingHandler?(self, .deleteColumn)
  }

  @objc(applyMarkdownBold:)
  private func applyMarkdownBold(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .bold)
  }

  @objc(applyMarkdownItalic:)
  private func applyMarkdownItalic(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .italic)
  }

  @objc(applyMarkdownLink:)
  private func applyMarkdownLink(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .link)
  }

  @objc(applyMarkdownHeading1:)
  private func applyMarkdownHeading1(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .heading(level: 1))
  }

  @objc(applyMarkdownHeading2:)
  private func applyMarkdownHeading2(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .heading(level: 2))
  }

  @objc(applyMarkdownHeading3:)
  private func applyMarkdownHeading3(_ sender: Any?) {
    _ = markdownFormattingHandler?(self, .heading(level: 3))
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateFileDropTarget(using: sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateFileDropTarget(using: sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    setFileDropTargeted(false)
  }

  override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
    !imageFileURLs(from: sender.draggingPasteboard).isEmpty
      || knowledgeMarkdown(from: sender.draggingPasteboard) != nil
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { setFileDropTargeted(false) }
    let urls = imageFileURLs(from: sender.draggingPasteboard)
    if !urls.isEmpty {
      let dropRange = insertionRange(for: sender)
      setSelectedRange(dropRange)
      fileDropHandler?(urls, dropRange)
      return true
    }

    guard let markdown = knowledgeMarkdown(from: sender.draggingPasteboard) else {
      return false
    }
    let dropRange = insertionRange(for: sender)
    setSelectedRange(dropRange)
    knowledgeMarkdownDropHandler?(
      markdown,
      dropRange,
      knowledgeCitationProvider(sender.draggingPasteboard)
    )
    return true
  }

  override func concludeDragOperation(_ sender: NSDraggingInfo?) {
    setFileDropTargeted(false)
  }

  private func insertionRange(for sender: NSDraggingInfo) -> NSRange {
    let location = convert(sender.draggingLocation, from: nil)
    let insertionIndex = characterIndexForInsertion(at: location)
    let maxLength = (string as NSString).length
    return NSRange(location: min(max(insertionIndex, 0), maxLength), length: 0)
  }

  private func updateFileDropTarget(using sender: NSDraggingInfo) -> NSDragOperation {
    let acceptsImages = !imageFileURLs(from: sender.draggingPasteboard).isEmpty
    let acceptsKnowledgeMarkdown = knowledgeMarkdown(from: sender.draggingPasteboard) != nil
    let acceptsDrop = acceptsImages || acceptsKnowledgeMarkdown
    setFileDropTargeted(acceptsDrop)
    return acceptsDrop ? .copy : []
  }

  private func setFileDropTargeted(_ isTargeted: Bool) {
    guard isFileDropTargeted != isTargeted else { return }
    isFileDropTargeted = isTargeted
    fileDropTargetChangedHandler?(isTargeted)
  }

  private func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    fileDropImageURLsProvider(pasteboard)
  }

  private func knowledgeMarkdown(from pasteboard: NSPasteboard) -> String? {
    knowledgeMarkdownProvider(pasteboard)
  }
}

enum MarkdownFormattingResponderBridge {
  @MainActor
  static func perform(_ command: MarkdownFormattingCommand) -> Bool {
    let selectorName: String
    switch command {
    case .bold:
      selectorName = "applyMarkdownBold:"
    case .italic:
      selectorName = "applyMarkdownItalic:"
    case .link:
      selectorName = "applyMarkdownLink:"
    case .heading(let level):
      guard (1...3).contains(level) else { return false }
      selectorName = "applyMarkdownHeading\(level):"
    }
    return NSApp.sendAction(NSSelectorFromString(selectorName), to: nil, from: nil)
  }
}
