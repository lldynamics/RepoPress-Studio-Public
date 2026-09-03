import AppKit
import ImageIO
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
      && lhs.frame == rhs.frame
      && lhs.minimumLineHeight == rhs.minimumLineHeight
      && lhs.image === rhs.image
      && lhs.isImageLoading == rhs.isImageLoading
  }
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

/// Geometry policy for the paint-only image card.  It intentionally uses the
/// source pixel dimensions rather than a decoded `NSImage`, so viewport layout
/// does not force a potentially expensive full image decode.
enum MarkdownInlineAttachmentImageLayout {
  static let minimumCardHeight: CGFloat = 120
  static let maximumCardHeight: CGFloat = 360
  static let verticalChrome: CGFloat = 16
  static let horizontalChrome: CGFloat = 16
  static let fallbackCardHeight: CGFloat = 164

  static func cardHeight(
    imageSize: CGSize?,
    availableWidth: CGFloat
  ) -> CGFloat {
    guard
      let imageSize,
      imageSize.width > 0,
      imageSize.height > 0,
      availableWidth > 0
    else {
      return fallbackCardHeight
    }

    let imageWidth = max(1, availableWidth - horizontalChrome)
    let naturalHeight = imageWidth * imageSize.height / imageSize.width
    return min(
      maximumCardHeight,
      max(minimumCardHeight, ceil(naturalHeight + verticalChrome))
    )
  }

  static func minimumLineHeight(forCardHeight cardHeight: CGFloat) -> CGFloat {
    // Keep a small breathing gap around the card so the source paragraph does
    // not collide with neighbouring lines after TextKit recomputes layout.
    max(cardHeight + verticalChrome, minimumCardHeight + verticalChrome)
  }
}

/// Pure geometry for the small hit target painted above a hovered image.
enum MarkdownInlineAttachmentOpenOriginalControl {
  static let size = NSSize(width: 88, height: 24)
  static let inset: CGFloat = 8

  static func frame(in imageCardFrame: NSRect) -> NSRect? {
    let card = imageCardFrame.standardized
    guard card.width > inset * 2 + 28, card.height > inset * 2 + 16 else {
      return nil
    }
    let width = min(size.width, card.width - inset * 2)
    return NSRect(
      x: card.maxX - inset - width,
      y: card.maxY - inset - size.height,
      width: width,
      height: size.height
    )
  }

  static func contains(_ point: NSPoint, in imageCardFrame: NSRect) -> Bool {
    frame(in: imageCardFrame)?.contains(point) == true
  }
}

enum MarkdownInlineAttachmentDrawingLayout {
  static func availableBlockWidth(
    textViewBounds: NSRect,
    horizontalInset: CGFloat
  ) -> CGFloat? {
    let bounds = textViewBounds.standardized
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let safeInset = min(
      max(0, horizontalInset),
      max(0, (bounds.width - 1) / 2)
    )
    return max(1, bounds.width - safeInset * 2)
  }

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
  private static var inlineAttachmentImageDimensionsByPath: [String: CGSize] = [:]
  private static var inlineAttachmentUnreadableImageDimensionPaths: Set<String> = []

  /// Invalidates attachment-derived caches without touching active drawings.
  /// The caller subsequently schedules a full viewport repaint, which restores
  /// source attributes and removes those drawings through the normal teardown
  /// path.
  func invalidateInlineAttachmentCaches() {
    inlineAttachmentImageURLCache.removeAll(keepingCapacity: false)
    inlineAttachmentUnsupportedImagePaths.removeAll(keepingCapacity: false)
    inlineAttachmentFailedImagePaths.removeAll(keepingCapacity: false)
    Self.inlineAttachmentImageDimensionsByPath.removeAll(keepingCapacity: false)
    Self.inlineAttachmentUnreadableImageDimensionPaths.removeAll(keepingCapacity: false)
    inlineAttachmentReferenceLookupCache = nil
  }

  func clearInlineAttachmentDrawings(in textView: NSTextView? = nil) {
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
    guard let targetTextView else { return }
    let documentLength = (targetTextView.string as NSString).length
    var restoredRanges = Set<NSRange>()
    for descriptor in paintedDescriptors
      where descriptor.documentRange.location != NSNotFound
        && NSMaxRange(descriptor.documentRange) <= documentLength
    {
      restoreInlineAttachmentRendering(
        in: descriptor.documentRange,
        textView: targetTextView,
        renderingAttributesSnapshots: descriptor.renderingAttributesSnapshots,
        originalParagraphStyle: descriptor.originalParagraphStyle
      )
      restoredRanges.insert(descriptor.documentRange)
    }

    // Keep the cleanup path defensive for a partially installed drawing. A
    // descriptor is normally present for every painted range, but restoring a
    // remaining range is safer than leaving the source permanently hidden.
    for range in paintedRanges
      where !restoredRanges.contains(range)
        && range.location != NSNotFound
        && NSMaxRange(range) <= documentLength
    {
      restoreInlineAttachmentRendering(in: range, textView: targetTextView)
    }
  }

  func applyInlineAttachmentDrawings(
    in textView: NSTextView,
    applicationRange: NSRange,
    preservingExisting: Bool = false
  ) {
    guard let droppableTextView = textView as? DroppableMarkdownTextView else { return }
    if !preservingExisting {
      clearInlineAttachmentDrawings(in: textView)
    }
    let document = textView.string as NSString
    guard bodyUTF16Offset >= 0, bodyUTF16Offset <= document.length else { return }
    guard let rangeResolver = MarkdownTextKit2RangeAdapter.rangeResolver(
      for: applicationRange,
      in: textView
    ) else {
      return
    }
    let plan = cachedInlineAttachmentPlan(in: document)

    let selection = textView.selectedRange()
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
      if preservingExisting,
        let current = inlineAttachmentDrawingDescriptors[key],
        canReuseInlineAttachmentDrawing(
          current,
          item: item,
          documentRange: documentRange,
          attachmentByReference: attachmentByReference
        )
      {
        // A viewport scroll or selection repaint does not change the
        // document-space geometry of an unchanged drawing. Keep its value
        // identity and image task; only restore the source-hiding attributes
        // that a full syntax repaint may have removed.
        desiredKeys.insert(key)
        applyInlineAttachmentDrawingRendering(current, in: textView)
        continue
      }

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
        let imageCardHeight = MarkdownInlineAttachmentImageLayout.cardHeight(
          imageSize: inlineAttachmentImageDimensions(for: sourceURL),
          availableWidth: inlineAttachmentAvailableBlockWidth(in: textView)
        )
        desiredKeys.insert(key)
        desiredCandidates[key] =
          MarkdownInlineAttachmentDrawingCandidate(
          content: .image(path: sourceURL.path, accessibilityText: accessibilityText),
          sourceURL: sourceURL,
          documentRange: documentRange,
          layout: .block,
          preferredWidth: nil,
          preferredHeight: imageCardHeight,
          minimumLineHeight: MarkdownInlineAttachmentImageLayout.minimumLineHeight(
            forCardHeight: imageCardHeight
          )
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
      return current.content != desired.content
        || current.documentRange != desired.documentRange
        || current.minimumLineHeight != desired.minimumLineHeight
    }
    for key in obsoleteKeys {
      removeInlineAttachmentDrawing(forKey: key, in: textView)
    }

    var didMutateDrawings = !obsoleteKeys.isEmpty
    for (key, candidate) in desiredCandidates {
      if let current = inlineAttachmentDrawingDescriptors[key],
        current.content == candidate.content,
        current.documentRange == candidate.documentRange,
        current.minimumLineHeight == candidate.minimumLineHeight
      {
        // This branch is only reachable when a caller requested a fresh
        // candidate but the descriptor remained reusable. Preserve geometry,
        // image value, and task identity rather than re-measuring it.
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
    inlineAttachmentPaintedRanges = inlineAttachmentDrawingDescriptors.values
      .map(\.documentRange)
      .sorted { $0.location < $1.location }
    droppableTextView.markdownInlineAttachmentDrawings = inlineAttachmentDrawingDescriptors
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
    // Resolve geometry only from the already laid out viewport. If TextKit has
    // not produced a usable rect yet, leave the Markdown source visible and
    // let the next viewport pass retry.
    guard let frame = inlineAttachmentDrawingFrame(
      for: candidate,
      in: textView,
      rangeResolver: rangeResolver
    ) else {
      return
    }

    let renderingAttributesSnapshots = captureRenderingAttributes(
      for: candidate.documentRange,
      in: textView,
      rangeResolver: rangeResolver
    )
    let originalParagraphStyle = textView.textStorage?.attribute(
      .paragraphStyle,
      at: candidate.documentRange.location,
      effectiveRange: nil
    ) as? NSParagraphStyle
    let drawing = MarkdownInlineAttachmentDrawing(
      key: key,
      content: candidate.content,
      documentRange: candidate.documentRange,
      frame: frame,
      renderingAttributesSnapshots: renderingAttributesSnapshots,
      originalParagraphStyle: originalParagraphStyle,
      minimumLineHeight: candidate.minimumLineHeight,
      image: nil,
      isImageLoading: candidate.sourceURL != nil
    )
    applyInlineAttachmentDrawingRendering(drawing, in: textView)
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
      guard let payload else {
        self.inlineAttachmentFailedImagePaths.insert(sourceURL.path)
        self.removeInlineAttachmentDrawing(forKey: key, in: textView)
        return
      }
      let updated = MarkdownInlineAttachmentDrawing(
        key: current.key,
        content: current.content,
        documentRange: current.documentRange,
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
        droppableTextView.markdownInlineAttachmentDrawings = self
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
    textView.textStorage?.addAttribute(
      .paragraphStyle,
      value: paragraphStyle,
      range: drawing.documentRange
    )
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
      documentEdit.replacedRange.location >= previousBodyUTF16Offset,
      inlineAttachmentPlanDocumentRevision == previousRevision,
      inlineAttachmentPlanBodyUTF16Offset == previousBodyUTF16Offset,
      let inlineAttachmentPlan
    else { return }

    let bodyReplacedRange = NSRange(
      location: documentEdit.replacedRange.location - previousBodyUTF16Offset,
      length: documentEdit.replacedRange.length
    )
    guard let updatedPlan = MarkdownInlineAttachmentPlanService.incrementallyUpdatedPlan(
      inlineAttachmentPlan,
      previousMarkdown: previousBodyMarkdown,
      currentMarkdown: currentBodyMarkdown,
      replacedRange: bodyReplacedRange
    ) else { return }

    self.inlineAttachmentPlan = updatedPlan
    inlineAttachmentPlanDocumentRevision = syntaxDocumentRevision
    inlineAttachmentPlanBodyUTF16Offset = bodyUTF16Offset
    inlineAttachmentPlanIncrementalUpdateCount += 1
  }

  private func inlineAttachmentDrawingKey(for range: NSRange) -> String {
    "attachment:\(range.location)"
  }

  private func canReuseInlineAttachmentDrawing(
    _ descriptor: MarkdownInlineAttachmentDrawing,
    item: MarkdownInlineAttachmentItem,
    documentRange: NSRange,
    attachmentByReference: [String: DraftAttachment]
  ) -> Bool {
    guard descriptor.documentRange == documentRange else { return false }

    switch item.kind {
    case .image(let reference, let altText):
      guard case .image(let path, let accessibilityText) = descriptor.content,
        let attachment = Self.referenceVariants(reference).compactMap({
          attachmentByReference[$0]
        }).first,
        let sourcePath = attachment.sourceFilePath?.nilIfEmpty,
        !inlineAttachmentFailedImagePaths.contains(sourcePath)
      else {
        return false
      }
      let expectedAccessibilityText =
        altText.nilIfEmpty
        ?? attachment.altText.nilIfEmpty
        ?? attachment.originalFilename
      let expectedPath = URL(fileURLWithPath: sourcePath)
        .standardizedFileURL
        .resolvingSymlinksInPath()
        .path
      return path == expectedPath && accessibilityText == expectedAccessibilityText

    case .formula(let source, let displayMode):
      let fontSize =
        displayMode == .inline
        ? syntaxHighlightPalette.baseFont.pointSize
        : max(19, syntaxHighlightPalette.baseFont.pointSize)
      return descriptor.content == .formula(
        source: source,
        displayMode: displayMode,
        fontSize: fontSize
      )
    }
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
    guard let sourceRect = MarkdownTextKit2RangeAdapter.rect(
      for: candidate.documentRange,
      using: rangeResolver,
      in: textView,
      ensuringLayout: false
    ) else { return nil }
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

  private func inlineAttachmentAvailableBlockWidth(in textView: NSTextView) -> CGFloat {
    let containerSize = textView.textContainer?.containerSize ?? .zero
    let viewBounds = NSRect(
      x: textView.bounds.minX,
      y: textView.bounds.minY,
      width: textView.bounds.width > 0 ? textView.bounds.width : containerSize.width,
      height: textView.bounds.height > 0 ? textView.bounds.height : containerSize.height
    )
    return MarkdownInlineAttachmentDrawingLayout.availableBlockWidth(
      textViewBounds: viewBounds,
      horizontalInset: textView.textContainerInset.width + 6
    ) ?? 1
  }

  private func inlineAttachmentImageDimensions(for sourceURL: URL) -> CGSize? {
    let path = sourceURL.path
    if let cached = Self.inlineAttachmentImageDimensionsByPath[path] {
      return cached
    }
    guard !Self.inlineAttachmentUnreadableImageDimensionPaths.contains(path),
      let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
      width > 0,
      height > 0
    else {
      if Self.inlineAttachmentUnreadableImageDimensionPaths.count
        >= Self.inlineAttachmentImageURLCacheLimit
      {
        Self.inlineAttachmentUnreadableImageDimensionPaths.removeAll(keepingCapacity: true)
      }
      Self.inlineAttachmentUnreadableImageDimensionPaths.insert(path)
      return nil
    }
    if Self.inlineAttachmentImageDimensionsByPath.count >= Self.inlineAttachmentImageURLCacheLimit {
      Self.inlineAttachmentImageDimensionsByPath.removeAll(keepingCapacity: true)
    }
    let dimensions = CGSize(width: width, height: height)
    Self.inlineAttachmentImageDimensionsByPath[path] = dimensions
    return dimensions
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
      guard let fullRenderingRange = MarkdownTextKit2RangeAdapter.range(
        for: renderingRange,
        in: textView
      ) else {
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

  private func removeInlineAttachmentDrawing(forKey key: String, in textView: NSTextView) {
    inlineAttachmentImageTasks[key]?.cancel()
    inlineAttachmentImageTasks[key] = nil
    guard let descriptor = inlineAttachmentDrawingDescriptors.removeValue(forKey: key) else {
      return
    }
    restoreInlineAttachmentRendering(
      in: descriptor.documentRange,
      textView: textView,
      renderingAttributesSnapshots: descriptor.renderingAttributesSnapshots,
      originalParagraphStyle: descriptor.originalParagraphStyle
    )
    inlineAttachmentPaintedRanges.removeAll { $0 == descriptor.documentRange }
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.markdownInlineAttachmentDrawings = inlineAttachmentDrawingDescriptors
    }
  }

  private func restoreInlineAttachmentRendering(
    in range: NSRange,
    textView: NSTextView,
    renderingAttributesSnapshots: [MarkdownInlineAttachmentDrawing.RenderingAttributesSnapshot] = [],
    originalParagraphStyle: NSParagraphStyle? = nil
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
        guard let textRange = MarkdownTextKit2RangeAdapter.textRange(
          for: snapshot.range,
          in: textView
        ) else {
          continue
        }
        manager.setRenderingAttributes(snapshot.attributes, for: textRange)
      }
    }

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
