import AppKit
import ImageIO
import PublishingDomainContracts
import PublishingWorkbenchCore
import UniformTypeIdentifiers

/// Paint-only state for an editable Markdown inline attachment.
///
/// The source Markdown remains authoritative. This value only describes the
/// derived card that the text view paints for one visible source range. Keeping
/// the stable key and image value here lets viewport reconciliation reuse the
/// same presentation without creating an AppKit child view per attachment.
struct MarkdownInlineAttachmentDrawing: Equatable {
  struct RenderingAttributesSnapshot {
    let range: NSRange
    let attributes: [NSAttributedString.Key: Any]
  }

  enum Content: Equatable {
    case image(path: String, accessibilityText: String)
    case formula(
      source: String,
      displayMode: MarkdownFormulaDisplayMode,
      fontSize: CGFloat
    )
  }

  let key: String
  let content: Content
  let documentRange: NSRange
  let sourceText: String
  let frame: NSRect
  let renderingAttributesSnapshots: [RenderingAttributesSnapshot]
  let originalParagraphStyle: NSParagraphStyle?
  let minimumLineHeight: CGFloat
  let image: NSImage?
  let isImageLoading: Bool

  // Rendering attributes are dictionaries containing non-Equatable AppKit
  // values. The snapshot is deliberately excluded from identity comparison:
  // it belongs to the source range being painted and should not cause an
  // otherwise reusable drawing to be recreated.
  static func == (
    lhs: MarkdownInlineAttachmentDrawing,
    rhs: MarkdownInlineAttachmentDrawing
  ) -> Bool {
    lhs.key == rhs.key
      && lhs.content == rhs.content
      && lhs.documentRange == rhs.documentRange
      && lhs.sourceText == rhs.sourceText
      && lhs.frame == rhs.frame
      && lhs.minimumLineHeight == rhs.minimumLineHeight
      && lhs.image === rhs.image
      && lhs.isImageLoading == rhs.isImageLoading
  }
}

/// The layout reservation outlives an on-screen drawing.  Attachment cards are
/// intentionally viewport-scoped, but their Markdown line still occupies space
/// in the document while the card is off screen.  Keeping that small piece of
/// state separate prevents a viewport repaint from changing the scrollable
/// height of unrelated text.
struct MarkdownInlineAttachmentGeometryReservation {
  let content: MarkdownInlineAttachmentDrawing.Content
  let documentRange: NSRange
  let sourceText: String
  let originalParagraphStyle: NSParagraphStyle?
  let minimumLineHeight: CGFloat
}

/// Accessibility-only representation of a paint-only inline attachment.
///
/// Editable images and formulas no longer own an AppKit child view, but they
/// still appear as children of the text view to VoiceOver. The stable key lets
/// image completion update presentation without replacing the accessibility
/// object.
@MainActor
final class MarkdownInlineAttachmentAccessibilityElement: NSAccessibilityElement {
  let drawingKey: String

  init(
    drawing: MarkdownInlineAttachmentDrawing,
    parent: DroppableMarkdownTextView
  ) {
    drawingKey = drawing.key
    super.init()
    setAccessibilityElement(true)
    setAccessibilityParent(parent)
    update(with: drawing)
  }

  required init?(coder: NSCoder) {
    nil
  }

  func update(with drawing: MarkdownInlineAttachmentDrawing) {
    setAccessibilityFrameInParentSpace(drawing.frame)
    switch drawing.content {
    case .image(_, let accessibilityText):
      setAccessibilityRole(.image)
      setAccessibilityLabel(accessibilityText)
      setAccessibilityValue(nil)
    case .formula(let source, _, _):
      setAccessibilityRole(.staticText)
      setAccessibilityLabel("数学公式")
      setAccessibilityValue(source)
    }
  }
}

enum MarkdownInlineAttachmentDrawingLayoutMode {
  case block
  case inline
}

enum MarkdownInlineAttachmentDrawingLayout {
  static func frame(
    sourceRect: NSRect,
    textViewBounds: NSRect,
    horizontalInset: CGFloat,
    mode: MarkdownInlineAttachmentDrawingLayoutMode,
    preferredWidth: CGFloat?,
    preferredHeight: CGFloat
  ) -> NSRect? {
    let bounds = textViewBounds.standardized
    guard bounds.width > 0, bounds.height > 0 else { return nil }

    // A narrow editor window must never produce a frame wider than the text
    // container. Keep at least one point for the content area while clamping
    // the inset itself when the window is narrower than the normal gutter.
    let safeInset = min(
      max(0, horizontalInset),
      max(0, (bounds.width - 1) / 2)
    )
    let contentMinX = bounds.minX + safeInset
    let contentMaxX = bounds.maxX - safeInset
    let availableWidth = max(1, contentMaxX - contentMinX)

    switch mode {
    case .block:
      let height = max(preferredHeight, sourceRect.height - 12)
      return NSRect(
        x: contentMinX,
        y: sourceRect.midY - (height / 2),
        width: availableWidth,
        height: height
      )
    case .inline:
      let sourceWidth = sourceRect.width
      guard sourceWidth > 0 else { return nil }

      // Inline drawings are painted above the Markdown source. If their
      // presentation needs more width than the source span reserved by
      // TextKit, extending the frame would cover the next glyph. Returning
      // nil makes the caller restore the source instead of obscuring text.
      let requestedWidth = max(1, preferredWidth ?? sourceWidth)
      let tolerance: CGFloat = 0.5
      guard requestedWidth <= sourceWidth + tolerance else { return nil }

      let x = min(max(contentMinX, sourceRect.minX), contentMaxX)
      let availableInlineWidth = max(0, contentMaxX - x)
      let visibleSourceWidth = max(0, sourceRect.maxX - x)
      guard requestedWidth <= availableInlineWidth + tolerance,
        requestedWidth <= visibleSourceWidth + tolerance
      else {
        // A partially visible or narrow source span cannot safely host the
        // complete formula presentation. Keep the Markdown source visible.
        return nil
      }

      let width = min(requestedWidth, min(availableInlineWidth, visibleSourceWidth))
      guard width > 0 else { return nil }
      let height = max(preferredHeight, sourceRect.height + 4)
      return NSRect(
        x: x,
        y: sourceRect.midY - (height / 2),
        width: width,
        height: height
      )
    }
  }
}

private struct MarkdownInlineAttachmentDrawingCandidate {
  let content: MarkdownInlineAttachmentDrawing.Content
  let sourceURL: URL?
  let documentRange: NSRange
  let layout: MarkdownInlineAttachmentDrawingLayoutMode
  let preferredWidth: CGFloat?
  let preferredHeight: CGFloat
  let minimumLineHeight: CGFloat
}

extension MacMarkdownTextView.Coordinator {
  private static let inlineAttachmentImageURLCacheLimit = 128

  /// Invalidates attachment-derived caches without touching active drawings.
  /// The caller subsequently schedules a full viewport repaint, which restores
  /// source attributes and removes those drawings through the normal teardown
  /// path.
  func invalidateInlineAttachmentCaches() {
    inlineAttachmentImageURLCache.removeAll(keepingCapacity: false)
    inlineAttachmentUnsupportedImagePaths.removeAll(keepingCapacity: false)
    inlineAttachmentFailedImagePaths.removeAll(keepingCapacity: false)
    inlineAttachmentReferenceLookupCache = nil
  }

  func clearInlineAttachmentDrawings(
    in textView: NSTextView? = nil,
    preservingGeometry: Bool = false
  ) {
    let targetTextView = textView ?? self.textView
    let paintedDescriptors = Array(inlineAttachmentDrawingDescriptors.values)
    let paintedRanges = inlineAttachmentPaintedRanges
    for task in inlineAttachmentImageTasks.values {
      task.cancel()
    }
    inlineAttachmentImageTasks.removeAll()
    inlineAttachmentDrawingDescriptors.removeAll()
    inlineAttachmentPaintedRanges.removeAll()

    if let droppableTextView = targetTextView as? DroppableMarkdownTextView {
      droppableTextView.markdownInlineAttachmentDrawings = [:]
    }
    guard let targetTextView else {
      inlineAttachmentGeometryReservations.removeAll()
      return
    }
    let documentLength = (targetTextView.string as NSString).length
    var restoredRanges = Set<NSRange>()
    let descriptorRanges = Set(paintedDescriptors.map(\.documentRange))
    for descriptor in paintedDescriptors
    where descriptor.documentRange.location != NSNotFound
      && descriptor.documentRange.location >= 0
      && descriptor.documentRange.location < documentLength
    {
      guard
        inlineAttachmentDrawingMatchesCurrentReservation(
          descriptor,
          in: targetTextView
        )
      else {
        if !preservingGeometry {
          // A full cleanup cannot leave a stale card's transparent rendering
          // attributes behind. Do not replay its old snapshot or paragraph
          // style onto a range that may now contain different source text.
          restoreInlineAttachmentRendering(
            in: NSIntersectionRange(
              descriptor.documentRange,
              NSRange(location: 0, length: documentLength)
            ),
            textView: targetTextView,
            restoringGeometry: false
          )
        }
        continue
      }
      restoreInlineAttachmentRendering(
        in: descriptor.documentRange,
        textView: targetTextView,
        renderingAttributesSnapshots: descriptor.renderingAttributesSnapshots,
        originalParagraphStyle: descriptor.originalParagraphStyle,
        restoringGeometry:
          !preservingGeometry
          && inlineAttachmentGeometryReservations[descriptor.key] == nil
      )
      restoredRanges.insert(descriptor.documentRange)
    }

    // Keep the cleanup path defensive for a partially installed drawing. A
    // descriptor is normally present for every painted range, but restoring a
    // remaining range is safer than leaving the source permanently hidden.
    for range in paintedRanges
    where !restoredRanges.contains(range)
      && !descriptorRanges.contains(range)
      && range.location != NSNotFound
      && range.location >= 0
      && range.location < documentLength
    {
      restoreInlineAttachmentRendering(
        in: NSIntersectionRange(range, NSRange(location: 0, length: documentLength)),
        textView: targetTextView,
        restoringGeometry: !preservingGeometry
      )
    }
    guard !preservingGeometry else { return }
    for reservation in inlineAttachmentGeometryReservations.values {
      restoreInlineAttachmentGeometry(reservation, in: targetTextView)
    }
    inlineAttachmentGeometryReservations.removeAll()
  }

  func applyInlineAttachmentDrawings(
    in textView: NSTextView,
    applicationRange: NSRange,
    preservingExisting: Bool = false
  ) {
    guard let droppableTextView = textView as? DroppableMarkdownTextView else { return }
    self.textView = textView
    if !preservingExisting {
      clearInlineAttachmentDrawings(in: textView, preservingGeometry: true)
    }
    let document = textView.string as NSString
    guard bodyUTF16Offset >= 0, bodyUTF16Offset <= document.length else { return }
    guard
      let rangeResolver = MarkdownTextKit2RangeAdapter.rangeResolver(
        for: applicationRange,
        in: textView
      )
    else {
      return
    }
    let plan = cachedInlineAttachmentPlan(in: document)
    reconcileInlineAttachmentGeometryReservations(
      in: document,
      plan: plan,
      textView: textView
    )

    let selection = textView.selectedRange()
    restoreSelectedInlineAttachmentGeometry(
      for: selection,
      in: document,
      plan: plan,
      textView: textView
    )
    let attachmentByReference = attachmentReferenceLookup()
    var desiredCandidates: [String: MarkdownInlineAttachmentDrawingCandidate] = [:]
    var desiredKeys = Set<String>()
    for item in visibleInlineAttachmentItems(in: plan, applicationRange: applicationRange) {
      let documentRange = NSRange(
        location: bodyUTF16Offset + item.range.location,
        length: item.range.length
      )
      guard NSIntersectionRange(documentRange, applicationRange).length > 0,
        !Self.selection(selection, touches: documentRange)
      else { continue }

      let key = inlineAttachmentDrawingKey(for: documentRange)
      switch item.kind {
      case .image(let reference, let altText):
        let attachment = Self.referenceVariants(reference).compactMap {
          attachmentByReference[$0]
        }.first
        let sourcePath = attachment?.sourceFilePath?.nilIfEmpty
        let sourceURL = sourcePath.flatMap(resolvedInlineAttachmentImageURL)
        guard
          let attachment,
          let sourcePath,
          !inlineAttachmentFailedImagePaths.contains(sourcePath),
          let sourceURL
        else { continue }
        let accessibilityText =
          altText.nilIfEmpty
          ?? attachment.altText.nilIfEmpty
          ?? attachment.originalFilename
        desiredKeys.insert(key)
        desiredCandidates[key] =
          MarkdownInlineAttachmentDrawingCandidate(
            content: .image(path: sourceURL.path, accessibilityText: accessibilityText),
            sourceURL: sourceURL,
            documentRange: documentRange,
            layout: .block,
            preferredWidth: nil,
            preferredHeight: 164,
            minimumLineHeight: 180
          )
      case .formula(let source, let displayMode):
        let isMultiline = source.contains("\n") || source.contains("\r")
        let fontSize =
          displayMode == .inline
          ? syntaxHighlightPalette.baseFont.pointSize
          : max(19, syntaxHighlightPalette.baseFont.pointSize)
        let renderedSize = MarkdownInlineFormulaPresentation.attributedString(
          for: source,
          fontSize: fontSize
        ).size()
        let isInline = displayMode == .inline
        desiredKeys.insert(key)
        desiredCandidates[key] =
          MarkdownInlineAttachmentDrawingCandidate(
            content: .formula(
              source: source,
              displayMode: displayMode,
              fontSize: fontSize
            ),
            sourceURL: nil,
            documentRange: documentRange,
            layout: isInline ? .inline : .block,
            preferredWidth: isInline ? ceil(renderedSize.width) + 24 : nil,
            preferredHeight: isInline
              ? max(28, ceil(renderedSize.height) + 8)
              : (isMultiline ? 68 : max(52, ceil(renderedSize.height) + 12)),
            minimumLineHeight: isInline
              ? max(32, ceil(renderedSize.height) + 10)
              : (isMultiline ? 24 : 64)
          )
      }
    }

    let obsoleteKeys = inlineAttachmentDrawingDescriptors.keys.filter { key in
      guard let desired = desiredCandidates[key],
        let current = inlineAttachmentDrawingDescriptors[key]
      else { return !desiredKeys.contains(key) }
      return current.content != desired.content || current.documentRange != desired.documentRange
    }
    for key in obsoleteKeys {
      let currentRange =
        inlineAttachmentDrawingDescriptors[key]?.documentRange
        ?? NSRange(location: NSNotFound, length: 0)
      // A selected card is deliberately shown as editable Markdown.  Its
      // geometry must be restored immediately, unlike a card merely leaving
      // the viewport.
      let isLeavingViewport = NSIntersectionRange(currentRange, applicationRange).length == 0
      let preservesGeometry =
        isLeavingViewport
        && inlineAttachmentGeometryIsCurrent(
          forKey: key,
          in: document,
          plan: plan
        )
      removeInlineAttachmentDrawing(
        forKey: key,
        in: textView,
        preservingGeometry: preservesGeometry
      )
    }

    var didMutateDrawings = !obsoleteKeys.isEmpty
    for (key, candidate) in desiredCandidates {
      if let current = inlineAttachmentDrawingDescriptors[key],
        current.content == candidate.content,
        current.documentRange == candidate.documentRange
      {
        // Keep the loaded image and task identity; all visible frames are
        // remeasured together once paragraph styles have settled below.
        applyInlineAttachmentDrawingRendering(current, in: textView)
        continue
      }
      installInlineAttachmentDrawing(
        candidate: candidate,
        key: key,
        in: textView,
        rangeResolver: rangeResolver
      )
      if inlineAttachmentDrawingDescriptors[key] != nil {
        didMutateDrawings = true
      }
    }
    // A newly expanded card can shift every following card. Measure only
    // after all visible paragraph styles are installed, independent of the
    // dictionary iteration order used above.
    rangeResolver.manager.ensureLayout(for: rangeResolver.baseTextRange)
    for (key, candidate) in desiredCandidates {
      guard let current = inlineAttachmentDrawingDescriptors[key],
        let frame = inlineAttachmentDrawingFrame(
          for: candidate, in: textView, rangeResolver: rangeResolver),
        frame != current.frame
      else { continue }
      inlineAttachmentDrawingDescriptors[key] = MarkdownInlineAttachmentDrawing(
        key: current.key,
        content: current.content,
        documentRange: current.documentRange,
        sourceText: current.sourceText,
        frame: frame,
        renderingAttributesSnapshots: current.renderingAttributesSnapshots,
        originalParagraphStyle: current.originalParagraphStyle,
        minimumLineHeight: current.minimumLineHeight,
        image: current.image,
        isImageLoading: current.isImageLoading
      )
      didMutateDrawings = true
    }
    inlineAttachmentPaintedRanges = inlineAttachmentDrawingDescriptors.values
      .map(\.documentRange)
      .sorted { $0.location < $1.location }
    droppableTextView.markdownInlineAttachmentDrawings = inlineAttachmentDrawingDescriptors
    // The syntax pass paints list markers before this deferred attachment
    // pass. Expanded cards can move the following lists, so refresh only the
    // already-visible markers against the settled paragraph geometry.
    if !droppableTextView.markdownBlockMarkerDrawings.isEmpty {
      applyBlockMarkerDrawings(
        droppableTextView.markdownBlockMarkerDrawings.map(\.marker),
        in: textView,
        rangeResolver: rangeResolver
      )
    }
    if didMutateDrawings {
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
    }
  }

  private func installInlineAttachmentDrawing(
    candidate: MarkdownInlineAttachmentDrawingCandidate,
    key: String,
    in textView: NSTextView,
    rangeResolver: MarkdownTextKit2RangeAdapter.RangeResolver
  ) {
    // Resolve once before changing rendering attributes so an unsafe inline
    // source span remains visible. The final frame is deliberately measured
    // again after the attachment line-height takes part in TextKit layout.
    guard
      inlineAttachmentDrawingFrame(
        for: candidate,
        in: textView,
        rangeResolver: rangeResolver
      ) != nil
    else {
      return
    }

    let renderingAttributesSnapshots = captureRenderingAttributes(
      for: candidate.documentRange,
      in: textView,
      rangeResolver: rangeResolver
    )
    let originalParagraphStyle =
      textView.textStorage?.attribute(
        .paragraphStyle,
        at: candidate.documentRange.location,
        effectiveRange: nil
      ) as? NSParagraphStyle
    let sourceText = (textView.string as NSString).substring(
      with: candidate.documentRange
    )
    reserveInlineAttachmentGeometry(
      key: key,
      candidate: candidate,
      originalParagraphStyle: originalParagraphStyle,
      in: textView
    )
    let provisionalDrawing = MarkdownInlineAttachmentDrawing(
      key: key,
      content: candidate.content,
      documentRange: candidate.documentRange,
      sourceText: sourceText,
      frame: .zero,
      renderingAttributesSnapshots: renderingAttributesSnapshots,
      originalParagraphStyle: originalParagraphStyle,
      minimumLineHeight: candidate.minimumLineHeight,
      image: nil,
      isImageLoading: candidate.sourceURL != nil
    )
    applyInlineAttachmentDrawingRendering(provisionalDrawing, in: textView)
    rangeResolver.manager.ensureLayout(for: rangeResolver.baseTextRange)
    guard
      let frame = inlineAttachmentDrawingFrame(
        for: candidate,
        in: textView,
        rangeResolver: rangeResolver
      )
    else {
      restoreInlineAttachmentRendering(
        in: candidate.documentRange,
        textView: textView,
        renderingAttributesSnapshots: renderingAttributesSnapshots,
        originalParagraphStyle: originalParagraphStyle
      )
      return
    }
    let drawing = MarkdownInlineAttachmentDrawing(
      key: key,
      content: candidate.content,
      documentRange: candidate.documentRange,
      sourceText: sourceText,
      frame: frame,
      renderingAttributesSnapshots: renderingAttributesSnapshots,
      originalParagraphStyle: originalParagraphStyle,
      minimumLineHeight: candidate.minimumLineHeight,
      image: nil,
      isImageLoading: candidate.sourceURL != nil
    )
    inlineAttachmentDrawingDescriptors[key] = drawing
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.markdownInlineAttachmentDrawings = inlineAttachmentDrawingDescriptors
    }

    guard let sourceURL = candidate.sourceURL else { return }
    inlineAttachmentImageTasks[key]?.cancel()
    inlineAttachmentImageTasks[key] = Task { @MainActor [weak self, weak textView] in
      let payload = await MarkdownInlineAttachmentImageCache.shared.image(at: sourceURL)
      guard let self, let textView, !Task.isCancelled,
        let current = self.inlineAttachmentDrawingDescriptors[key],
        current.content == candidate.content
      else { return }
      guard self.inlineAttachmentDrawingMatchesCurrentReservation(current, in: textView) else {
        self.removeInlineAttachmentDrawing(forKey: key, in: textView)
        return
      }
      guard let payload else {
        self.inlineAttachmentFailedImagePaths.insert(sourceURL.path)
        self.removeInlineAttachmentDrawing(forKey: key, in: textView)
        return
      }
      let updated = MarkdownInlineAttachmentDrawing(
        key: current.key,
        content: current.content,
        documentRange: current.documentRange,
        sourceText: current.sourceText,
        frame: current.frame,
        renderingAttributesSnapshots: current.renderingAttributesSnapshots,
        originalParagraphStyle: current.originalParagraphStyle,
        minimumLineHeight: current.minimumLineHeight,
        image: NSImage(cgImage: payload.image, size: .zero),
        isImageLoading: false
      )
      self.inlineAttachmentDrawingDescriptors[key] = updated
      self.inlineAttachmentImageTasks[key] = nil
      if let droppableTextView = textView as? DroppableMarkdownTextView {
        droppableTextView.markdownInlineAttachmentDrawings =
          self
          .inlineAttachmentDrawingDescriptors
      }
    }
  }

  private func applyInlineAttachmentDrawingRendering(
    _ drawing: MarkdownInlineAttachmentDrawing,
    in textView: NSTextView
  ) {
    MarkdownTextKit2RangeAdapter.addRenderingAttributes(
      [
        .foregroundColor: NSColor.clear,
        .underlineColor: NSColor.clear,
      ],
      for: drawing.documentRange,
      in: textView
    )
    let paragraphStyle =
      (syntaxHighlightPalette.defaultAttributes[.paragraphStyle] as? NSParagraphStyle)?
      .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = drawing.minimumLineHeight
    guard let storage = textView.textStorage else { return }
    var needsParagraphUpdate = false
    storage.enumerateAttribute(.paragraphStyle, in: drawing.documentRange) { value, _, stop in
      if (value as? NSParagraphStyle)?.isEqual(paragraphStyle) != true {
        needsParagraphUpdate = true
        stop.pointee = true
      }
    }
    if needsParagraphUpdate {
      storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: drawing.documentRange)
    }
  }

  private func cachedInlineAttachmentPlan(in document: NSString) -> MarkdownInlineAttachmentPlan {
    if inlineAttachmentPlanDocumentRevision == syntaxDocumentRevision,
      inlineAttachmentPlanBodyUTF16Offset == bodyUTF16Offset,
      let inlineAttachmentPlan
    {
      return inlineAttachmentPlan
    }
    // NSTextView edits arrive before SwiftUI republishes the draft body. Plan
    // from the live TextKit document so an attachment does not miss the edit
    // that introduced it while keeping Front Matter out of attachment parsing.
    let currentBodyMarkdown = document.substring(from: bodyUTF16Offset)
    let plan = MarkdownInlineAttachmentPlanService.plan(in: currentBodyMarkdown)
    inlineAttachmentPlanComputationCount += 1
    inlineAttachmentPlan = plan
    inlineAttachmentPlanDocumentRevision = syntaxDocumentRevision
    inlineAttachmentPlanBodyUTF16Offset = bodyUTF16Offset
    return plan
  }

  func incrementallyUpdateInlineAttachmentPlan(
    previousBodyMarkdown: String,
    currentBodyMarkdown: String,
    documentEdit: MarkdownTextEdit,
    previousBodyUTF16Offset: Int,
    previousRevision: UInt64
  ) {
    guard bodyUTF16Offset == previousBodyUTF16Offset,
      documentEdit.replacedRange.location >= previousBodyUTF16Offset
    else {
      conservativelyClearInlineAttachmentGeometryReservations(after: documentEdit)
      return
    }

    // Geometry range relocation does not depend on the attachment planner
    // accepting the edit. Structural attachment edits intentionally make that
    // planner fall back, but unrelated cards must still move or be restored.
    relocateInlineAttachmentGeometryReservations(
      previousBodyMarkdown: previousBodyMarkdown,
      currentBodyMarkdown: currentBodyMarkdown,
      documentEdit: documentEdit,
      previousBodyUTF16Offset: previousBodyUTF16Offset
    )

    guard inlineAttachmentPlanDocumentRevision == previousRevision,
      inlineAttachmentPlanBodyUTF16Offset == previousBodyUTF16Offset,
      let inlineAttachmentPlan
    else { return }

    let bodyReplacedRange = NSRange(
      location: documentEdit.replacedRange.location - previousBodyUTF16Offset,
      length: documentEdit.replacedRange.length
    )
    guard
      let updatedPlan = MarkdownInlineAttachmentPlanService.incrementallyUpdatedPlan(
        inlineAttachmentPlan,
        previousMarkdown: previousBodyMarkdown,
        currentMarkdown: currentBodyMarkdown,
        replacedRange: bodyReplacedRange
      )
    else {
      return
    }
    self.inlineAttachmentPlan = updatedPlan
    inlineAttachmentPlanDocumentRevision = syntaxDocumentRevision
    inlineAttachmentPlanBodyUTF16Offset = bodyUTF16Offset
    inlineAttachmentPlanIncrementalUpdateCount += 1
  }

  private func inlineAttachmentDrawingKey(for range: NSRange) -> String {
    "attachment:\(range.location)"
  }

  private func visibleInlineAttachmentItems(
    in plan: MarkdownInlineAttachmentPlan,
    applicationRange: NSRange
  ) -> ArraySlice<MarkdownInlineAttachmentItem> {
    let documentStart = max(applicationRange.location, bodyUTF16Offset)
    let documentEnd = max(documentStart, NSMaxRange(applicationRange))
    let bodyRange = NSRange(
      location: documentStart - bodyUTF16Offset,
      length: documentEnd - documentStart
    )
    var lowerBound = 0
    var upperBound = plan.items.count
    while lowerBound < upperBound {
      let midpoint = lowerBound + ((upperBound - lowerBound) / 2)
      if NSMaxRange(plan.items[midpoint].range) <= bodyRange.location {
        lowerBound = midpoint + 1
      } else {
        upperBound = midpoint
      }
    }
    var end = lowerBound
    let bodyEnd = NSMaxRange(bodyRange)
    while end < plan.items.count, plan.items[end].range.location < bodyEnd {
      end += 1
    }
    return plan.items[lowerBound..<end]
  }

  private func inlineAttachmentDrawingFrame(
    for candidate: MarkdownInlineAttachmentDrawingCandidate,
    in textView: NSTextView,
    rangeResolver: MarkdownTextKit2RangeAdapter.RangeResolver
  ) -> NSRect? {
    guard
      let sourceRect = MarkdownTextKit2RangeAdapter.rect(
        for: candidate.documentRange,
        using: rangeResolver,
        in: textView,
        ensuringLayout: false
      )
    else { return nil }
    let horizontalInset = textView.textContainerInset.width + 6
    let containerSize = textView.textContainer?.containerSize ?? .zero
    // Unit tests and the initial TextKit construction can have a zero-sized
    // view frame while the text container already has its real width. Use the
    // container as a geometry fallback without weakening the production
    // bounds clamp.
    let viewBounds = NSRect(
      x: textView.bounds.minX,
      y: textView.bounds.minY,
      width: textView.bounds.width > 0 ? textView.bounds.width : containerSize.width,
      height: textView.bounds.height > 0 ? textView.bounds.height : containerSize.height
    )
    return MarkdownInlineAttachmentDrawingLayout.frame(
      sourceRect: sourceRect,
      textViewBounds: viewBounds,
      horizontalInset: horizontalInset,
      mode: candidate.layout,
      preferredWidth: candidate.preferredWidth,
      preferredHeight: candidate.preferredHeight
    )
  }

  private func captureRenderingAttributes(
    for range: NSRange,
    in textView: NSTextView,
    rangeResolver: MarkdownTextKit2RangeAdapter.RangeResolver
  ) -> [MarkdownInlineAttachmentDrawing.RenderingAttributesSnapshot] {
    guard let manager = textView.textLayoutManager,
      let textRange = rangeResolver.textRange(for: range)
    else {
      return []
    }

    let renderingKeys: Set<NSAttributedString.Key> = [
      .foregroundColor,
      .underlineColor,
    ]
    var snapshots: [MarkdownInlineAttachmentDrawing.RenderingAttributesSnapshot] = []
    manager.enumerateRenderingAttributes(from: textRange.location, reverse: false) {
      _, attributes, renderingRange in
      guard
        let fullRenderingRange = MarkdownTextKit2RangeAdapter.range(
          for: renderingRange,
          in: textView
        )
      else {
        return true
      }
      let intersection = NSIntersectionRange(fullRenderingRange, range)
      guard intersection.length > 0 else {
        return NSMaxRange(fullRenderingRange) <= range.location
      }
      let selectedAttributes = attributes.filter { renderingKeys.contains($0.key) }
      if !selectedAttributes.isEmpty {
        snapshots.append(
          MarkdownInlineAttachmentDrawing.RenderingAttributesSnapshot(
            range: intersection,
            attributes: selectedAttributes
          )
        )
      }
      return NSMaxRange(fullRenderingRange) < NSMaxRange(range)
    }
    return snapshots
  }

  private func removeInlineAttachmentDrawing(
    forKey key: String,
    in textView: NSTextView,
    preservingGeometry: Bool = false
  ) {
    inlineAttachmentImageTasks[key]?.cancel()
    inlineAttachmentImageTasks[key] = nil
    guard let descriptor = inlineAttachmentDrawingDescriptors.removeValue(forKey: key) else {
      return
    }
    if inlineAttachmentDrawingMatchesCurrentReservation(descriptor, in: textView) {
      restoreInlineAttachmentRendering(
        in: descriptor.documentRange,
        textView: textView,
        renderingAttributesSnapshots: descriptor.renderingAttributesSnapshots,
        originalParagraphStyle: descriptor.originalParagraphStyle,
        restoringGeometry:
          !preservingGeometry && inlineAttachmentGeometryReservations[key] == nil
      )
      if !preservingGeometry,
        let reservation = inlineAttachmentGeometryReservations.removeValue(forKey: key)
      {
        restoreInlineAttachmentGeometry(reservation, in: textView)
      }
    }
    inlineAttachmentPaintedRanges.removeAll { $0 == descriptor.documentRange }
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.markdownInlineAttachmentDrawings = inlineAttachmentDrawingDescriptors
    }
  }

  private func restoreInlineAttachmentRendering(
    in range: NSRange,
    textView: NSTextView,
    renderingAttributesSnapshots: [MarkdownInlineAttachmentDrawing.RenderingAttributesSnapshot] =
      [],
    originalParagraphStyle: NSParagraphStyle? = nil,
    restoringGeometry: Bool = true
  ) {
    let documentLength = (textView.string as NSString).length
    guard range.location != NSNotFound, NSMaxRange(range) <= documentLength else { return }
    MarkdownTextKit2RangeAdapter.removeRenderingAttributes(
      [.foregroundColor, .underlineColor],
      for: range,
      in: textView
    )

    if renderingAttributesSnapshots.isEmpty {
      MarkdownTextKit2RangeAdapter.addRenderingAttributes(
        syntaxHighlightPalette.defaultAttributes,
        for: range,
        in: textView
      )
    } else if let manager = textView.textLayoutManager {
      for snapshot in renderingAttributesSnapshots {
        guard
          let textRange = MarkdownTextKit2RangeAdapter.textRange(
            for: snapshot.range,
            in: textView
          )
        else {
          continue
        }
        manager.setRenderingAttributes(snapshot.attributes, for: textRange)
      }
    }

    guard restoringGeometry else { return }
    if let originalParagraphStyle {
      textView.textStorage?.addAttribute(
        .paragraphStyle,
        value: originalParagraphStyle,
        range: range
      )
    } else if let paragraphStyle = syntaxHighlightPalette.defaultAttributes[.paragraphStyle] {
      textView.textStorage?.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
    }
  }

  private func reserveInlineAttachmentGeometry(
    key: String,
    candidate: MarkdownInlineAttachmentDrawingCandidate,
    originalParagraphStyle: NSParagraphStyle?,
    in textView: NSTextView
  ) {
    let document = textView.string as NSString
    guard candidate.documentRange.location != NSNotFound,
      NSMaxRange(candidate.documentRange) <= document.length
    else { return }
    let sourceText = document.substring(with: candidate.documentRange)
    if let existing = inlineAttachmentGeometryReservations[key],
      existing.documentRange == candidate.documentRange,
      existing.content == candidate.content,
      existing.sourceText == sourceText,
      existing.minimumLineHeight == candidate.minimumLineHeight
    {
      return
    }
    if let existing = inlineAttachmentGeometryReservations.removeValue(forKey: key) {
      restoreInlineAttachmentGeometry(existing, in: textView)
    }
    inlineAttachmentGeometryReservations[key] = MarkdownInlineAttachmentGeometryReservation(
      content: candidate.content,
      documentRange: candidate.documentRange,
      sourceText: sourceText,
      originalParagraphStyle: originalParagraphStyle,
      minimumLineHeight: candidate.minimumLineHeight
    )
  }

  private func restoreInlineAttachmentGeometry(
    _ reservation: MarkdownInlineAttachmentGeometryReservation,
    in textView: NSTextView
  ) {
    let document = textView.string as NSString
    guard reservation.documentRange.location != NSNotFound,
      NSMaxRange(reservation.documentRange) <= document.length,
      document.substring(with: reservation.documentRange) == reservation.sourceText
    else { return }
    if let originalParagraphStyle = reservation.originalParagraphStyle {
      textView.textStorage?.addAttribute(
        .paragraphStyle,
        value: originalParagraphStyle,
        range: reservation.documentRange
      )
    } else if let paragraphStyle = syntaxHighlightPalette.defaultAttributes[.paragraphStyle] {
      textView.textStorage?.addAttribute(
        .paragraphStyle,
        value: paragraphStyle,
        range: reservation.documentRange
      )
    }
  }

  private func inlineAttachmentGeometryIsCurrent(
    forKey key: String,
    in document: NSString,
    plan: MarkdownInlineAttachmentPlan
  ) -> Bool {
    guard let reservation = inlineAttachmentGeometryReservations[key],
      reservation.documentRange.location != NSNotFound,
      NSMaxRange(reservation.documentRange) <= document.length,
      document.substring(with: reservation.documentRange) == reservation.sourceText
    else { return false }
    let bodyRange = NSRange(
      location: reservation.documentRange.location - bodyUTF16Offset,
      length: reservation.documentRange.length
    )
    guard bodyRange.location >= 0,
      let item = plan.items.first(where: { $0.range == bodyRange })
    else { return false }
    switch (reservation.content, item.kind) {
    case (.formula(let source, let displayMode, _), .formula(let itemSource, let itemDisplayMode)):
      return source == itemSource && displayMode == itemDisplayMode
    case (.image(let path, _), .image(let reference, _)):
      let attachment = Self.referenceVariants(reference).compactMap {
        attachmentReferenceLookup()[$0]
      }.first
      return attachment?.sourceFilePath.flatMap(resolvedInlineAttachmentImageURL)?.path == path
    default:
      return false
    }
  }

  private func reconcileInlineAttachmentGeometryReservations(
    in document: NSString,
    plan: MarkdownInlineAttachmentPlan,
    textView: NSTextView
  ) {
    for key in Array(inlineAttachmentGeometryReservations.keys) {
      guard !inlineAttachmentGeometryIsCurrent(forKey: key, in: document, plan: plan),
        let reservation = inlineAttachmentGeometryReservations[key]
      else { continue }
      if inlineAttachmentDrawingDescriptors[key] != nil {
        removeInlineAttachmentDrawing(forKey: key, in: textView)
        continue
      }
      inlineAttachmentGeometryReservations.removeValue(forKey: key)
      if reservationSourceMatchesDocument(reservation, document: document) {
        restoreInlineAttachmentGeometry(reservation, in: textView)
      } else {
        resetInlineAttachmentGeometry(at: reservation.documentRange, in: textView)
      }
    }
  }

  private func relocateInlineAttachmentGeometryReservations(
    previousBodyMarkdown: String,
    currentBodyMarkdown: String,
    documentEdit: MarkdownTextEdit,
    previousBodyUTF16Offset: Int
  ) {
    guard bodyUTF16Offset == previousBodyUTF16Offset else {
      conservativelyClearInlineAttachmentGeometryReservations(after: documentEdit)
      return
    }
    let previousLength = previousBodyMarkdown.utf16.count + previousBodyUTF16Offset
    let currentLength = currentBodyMarkdown.utf16.count + bodyUTF16Offset
    guard (documentEdit.previousText as NSString).length == previousLength else {
      conservativelyClearInlineAttachmentGeometryReservations(after: documentEdit)
      return
    }
    let currentBody = currentBodyMarkdown as NSString
    var relocated: [String: MarkdownInlineAttachmentGeometryReservation] = [:]
    var needsEditedParagraphReset = false
    var resetRanges: [NSRange] = []
    for reservation in inlineAttachmentGeometryReservations.values {
      let transformedRange = MarkdownSyntaxPaintedRangeTransform.range(
        reservation.documentRange,
        previousLength: previousLength,
        currentLength: currentLength,
        replacedRange: documentEdit.replacedRange
      )
      guard !editRange(documentEdit.replacedRange, touches: reservation.documentRange),
        let transformedRange,
        transformedRange.location >= bodyUTF16Offset
      else {
        needsEditedParagraphReset = true
        if let transformedRange {
          resetRanges.append(transformedRange)
        }
        continue
      }
      let bodyRange = NSRange(
        location: transformedRange.location - bodyUTF16Offset,
        length: transformedRange.length
      )
      guard NSMaxRange(bodyRange) <= currentBody.length,
        currentBody.substring(with: bodyRange) == reservation.sourceText
      else {
        needsEditedParagraphReset = true
        resetRanges.append(transformedRange)
        continue
      }
      let key = inlineAttachmentDrawingKey(for: transformedRange)
      guard relocated[key] == nil else {
        needsEditedParagraphReset = true
        resetRanges.append(transformedRange)
        continue
      }
      relocated[key] = MarkdownInlineAttachmentGeometryReservation(
        content: reservation.content,
        documentRange: transformedRange,
        sourceText: reservation.sourceText,
        originalParagraphStyle: reservation.originalParagraphStyle,
        minimumLineHeight: reservation.minimumLineHeight
      )
    }
    inlineAttachmentGeometryReservations = relocated
    if let textView {
      for range in resetRanges {
        resetInlineAttachmentGeometry(in: range, in: textView)
      }
    }
    if needsEditedParagraphReset {
      resetInlineAttachmentGeometryAroundEdit(documentEdit, in: textView)
    }
  }

  private func resetInlineAttachmentGeometryAroundEdit(
    _ edit: MarkdownTextEdit,
    in textView: NSTextView?
  ) {
    guard let textView,
      let storage = textView.textStorage,
      (textView.string as NSString).length > 0
    else { return }
    let document = textView.string as NSString
    let location = min(max(edit.replacedRange.location, 0), max(document.length - 1, 0))
    let paragraphRange = document.paragraphRange(for: NSRange(location: location, length: 0))
    guard let paragraphStyle = syntaxHighlightPalette.defaultAttributes[.paragraphStyle] else {
      return
    }
    storage.addAttribute(.paragraphStyle, value: paragraphStyle, range: paragraphRange)
  }

  private func resetInlineAttachmentGeometry(at range: NSRange, in textView: NSTextView) {
    let document = textView.string as NSString
    guard range.location != NSNotFound,
      range.location >= 0,
      range.location < document.length
    else { return }
    resetInlineAttachmentGeometry(
      in: NSRange(location: range.location, length: min(1, document.length - range.location)),
      in: textView
    )
  }

  private func resetInlineAttachmentGeometry(in range: NSRange, in textView: NSTextView) {
    let document = textView.string as NSString
    guard range.location != NSNotFound,
      range.location >= 0,
      range.location < document.length
    else { return }
    let boundedRange = NSIntersectionRange(
      range,
      NSRange(location: 0, length: document.length)
    )
    guard boundedRange.length > 0 else { return }
    let paragraphRange = document.paragraphRange(for: boundedRange)
    guard let paragraphStyle = syntaxHighlightPalette.defaultAttributes[.paragraphStyle] else {
      return
    }
    textView.textStorage?.addAttribute(
      .paragraphStyle, value: paragraphStyle, range: paragraphRange)
  }

  private func reservationSourceMatchesDocument(
    _ reservation: MarkdownInlineAttachmentGeometryReservation,
    document: NSString
  ) -> Bool {
    reservation.documentRange.location != NSNotFound
      && NSMaxRange(reservation.documentRange) <= document.length
      && document.substring(with: reservation.documentRange) == reservation.sourceText
  }

  private func inlineAttachmentDrawingMatchesCurrentReservation(
    _ drawing: MarkdownInlineAttachmentDrawing,
    in textView: NSTextView
  ) -> Bool {
    let document = textView.string as NSString
    guard drawing.documentRange.location != NSNotFound,
      NSMaxRange(drawing.documentRange) <= document.length,
      document.substring(with: drawing.documentRange) == drawing.sourceText
    else { return false }
    guard let reservation = inlineAttachmentGeometryReservations[drawing.key] else {
      // A partially installed drawing may have lost its reservation while an
      // image task was being cancelled. Its own source check still makes the
      // defensive source restoration safe.
      return true
    }
    return reservation.content == drawing.content
      && reservation.documentRange == drawing.documentRange
      && reservationSourceMatchesDocument(reservation, document: document)
  }

  private func restoreSelectedInlineAttachmentGeometry(
    for selection: NSRange,
    in document: NSString,
    plan: MarkdownInlineAttachmentPlan,
    textView: NSTextView
  ) {
    for key in Array(inlineAttachmentGeometryReservations.keys) {
      guard let reservation = inlineAttachmentGeometryReservations[key],
        inlineAttachmentDrawingDescriptors[key] == nil,
        Self.selection(selection, touches: reservation.documentRange),
        inlineAttachmentGeometryIsCurrent(forKey: key, in: document, plan: plan)
      else {
        continue
      }
      inlineAttachmentGeometryReservations.removeValue(forKey: key)
      restoreInlineAttachmentGeometry(reservation, in: textView)
    }
  }

  private func conservativelyClearInlineAttachmentGeometryReservations(after edit: MarkdownTextEdit)
  {
    guard !inlineAttachmentGeometryReservations.isEmpty else { return }
    if let textView {
      let document = textView.string as NSString
      for reservation in inlineAttachmentGeometryReservations.values {
        if reservationSourceMatchesDocument(reservation, document: document) {
          restoreInlineAttachmentGeometry(reservation, in: textView)
        } else {
          // We cannot safely reattach the old style to a transformed range,
          // but leaving its 64/180pt paragraph behind is worse. Reset the
          // current paragraph conservatively; the syntax pass reapplies any
          // non-attachment styling immediately afterwards.
          resetInlineAttachmentGeometry(at: reservation.documentRange, in: textView)
        }
      }
    }
    resetInlineAttachmentGeometryAroundEdit(edit, in: textView)
    inlineAttachmentGeometryReservations.removeAll()
  }

  private func editRange(_ editRange: NSRange, touches range: NSRange) -> Bool {
    if editRange.length == 0 {
      return editRange.location >= range.location && editRange.location <= NSMaxRange(range)
    }
    return NSIntersectionRange(editRange, range).length > 0
  }

  private func attachmentReferenceLookup() -> [String: DraftAttachment] {
    if let inlineAttachmentReferenceLookupCache {
      return inlineAttachmentReferenceLookupCache
    }
    var result: [String: DraftAttachment] = [:]
    for attachment in attachments {
      for reference in [attachment.relativePublishPath, attachment.repositoryPath]
        .flatMap(Self.referenceVariants)
      where result[reference] == nil {
        result[reference] = attachment
      }
    }
    inlineAttachmentReferenceLookupCache = result
    return result
  }

  private static func referenceVariants(_ value: String) -> [String] {
    var normalized =
      value
      .removingPercentEncoding?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.hasPrefix("<"), normalized.hasSuffix(">"), normalized.count > 2 {
      normalized.removeFirst()
      normalized.removeLast()
    }
    while normalized.hasPrefix("./") { normalized.removeFirst(2) }
    guard !normalized.isEmpty else { return [] }
    let variants =
      normalized.hasPrefix("/")
      ? [normalized, String(normalized.dropFirst())]
      : [normalized, "/" + normalized]
    return Array(Set(variants))
  }

  private static func supportedImageURL(for path: String) -> URL? {
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard FileManager.default.isReadableFile(atPath: url.path),
      CGImageSourceCreateWithURL(url as CFURL, nil) != nil
    else {
      return nil
    }
    return url
  }

  private func resolvedInlineAttachmentImageURL(for path: String) -> URL? {
    if let cached = inlineAttachmentImageURLCache[path] {
      return cached
    }
    guard !inlineAttachmentUnsupportedImagePaths.contains(path) else {
      return nil
    }
    guard let resolved = Self.supportedImageURL(for: path) else {
      if inlineAttachmentUnsupportedImagePaths.count
        >= Self.inlineAttachmentImageURLCacheLimit
      {
        inlineAttachmentUnsupportedImagePaths.removeAll(keepingCapacity: true)
      }
      inlineAttachmentUnsupportedImagePaths.insert(path)
      return nil
    }
    if inlineAttachmentImageURLCache.count >= Self.inlineAttachmentImageURLCacheLimit {
      inlineAttachmentImageURLCache.removeAll(keepingCapacity: true)
    }
    inlineAttachmentImageURLCache[path] = resolved
    return resolved
  }

  private static func selection(_ selection: NSRange, touches range: NSRange) -> Bool {
    guard selection.location != NSNotFound else { return false }
    if selection.length == 0 {
      return selection.location >= range.location && selection.location <= NSMaxRange(range)
    }
    return NSIntersectionRange(selection, range).length > 0
  }
}
