import AppKit
import ImageIO
import PublishingWorkbenchCore
import UniformTypeIdentifiers

/// Stable identity and geometry for a native attachment overlay. The
/// coordinator retains these separately from NSView instances so subsequent
/// viewport passes can compare presentation state without making the view the
/// source of truth.
struct MarkdownInlineAttachmentOverlayDescriptor: Equatable {
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

  let content: Content
  let documentRange: NSRange
  let frame: NSRect
  let renderingAttributesSnapshots: [RenderingAttributesSnapshot]
  let originalParagraphStyle: NSParagraphStyle?

  // Rendering attributes are dictionaries containing non-Equatable AppKit
  // values. The snapshot is deliberately excluded from identity comparison:
  // it belongs to the source range being painted and should not cause an
  // otherwise reusable overlay to be recreated.
  static func == (
    lhs: MarkdownInlineAttachmentOverlayDescriptor,
    rhs: MarkdownInlineAttachmentOverlayDescriptor
  ) -> Bool {
    lhs.content == rhs.content
      && lhs.documentRange == rhs.documentRange
      && lhs.frame == rhs.frame
  }
}

enum MarkdownInlineAttachmentOverlayLayoutMode {
  case block
  case inline
}

enum MarkdownInlineAttachmentOverlayLayout {
  static func frame(
    sourceRect: NSRect,
    textViewBounds: NSRect,
    horizontalInset: CGFloat,
    mode: MarkdownInlineAttachmentOverlayLayoutMode,
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

      // Inline overlays are painted above the Markdown source. If their
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

private struct MarkdownInlineAttachmentOverlayCandidate {
  let content: MarkdownInlineAttachmentOverlayDescriptor.Content
  let viewContent: MarkdownInlineAttachmentOverlayView.Content
  let sourceURL: URL?
  let documentRange: NSRange
  let layout: MarkdownInlineAttachmentOverlayLayoutMode
  let preferredWidth: CGFloat?
  let preferredHeight: CGFloat
  let minimumLineHeight: CGFloat
}

extension MacMarkdownTextView.Coordinator {
  private static let inlineAttachmentOverlayViewPoolLimit = 16
  private static let inlineAttachmentImageURLCacheLimit = 128

  /// Invalidates attachment-derived caches without touching active overlays.
  /// The caller subsequently schedules a full viewport repaint, which restores
  /// source attributes and removes those overlays through the normal teardown
  /// path. Dropping the pool here also prevents an attachment/appearance
  /// change from reusing a view with stale presentation state.
  func invalidateInlineAttachmentCaches() {
    inlineAttachmentOverlayViewPool.removeAll(keepingCapacity: false)
    inlineAttachmentImageURLCache.removeAll(keepingCapacity: false)
    inlineAttachmentUnsupportedImagePaths.removeAll(keepingCapacity: false)
    inlineAttachmentFailedImagePaths.removeAll(keepingCapacity: false)
    inlineAttachmentReferenceLookupCache = nil
  }

  func clearInlineAttachmentOverlays(in textView: NSTextView? = nil) {
    let paintedDescriptors = Array(inlineAttachmentOverlayDescriptors.values)
    let paintedRanges = inlineAttachmentPaintedRanges
    for task in inlineAttachmentImageTasks.values {
      task.cancel()
    }
    inlineAttachmentImageTasks.removeAll()
    for overlay in inlineAttachmentOverlayViews.values {
      recycleInlineAttachmentOverlayView(overlay)
    }
    inlineAttachmentOverlayViews.removeAll()
    inlineAttachmentOverlayDescriptors.removeAll()
    inlineAttachmentPaintedRanges.removeAll()

    guard let textView else { return }
    let documentLength = (textView.string as NSString).length
    var restoredRanges = Set<NSRange>()
    for descriptor in paintedDescriptors
      where descriptor.documentRange.location != NSNotFound
        && NSMaxRange(descriptor.documentRange) <= documentLength
    {
      restoreInlineAttachmentRendering(
        in: descriptor.documentRange,
        textView: textView,
        renderingAttributesSnapshots: descriptor.renderingAttributesSnapshots,
        originalParagraphStyle: descriptor.originalParagraphStyle
      )
      restoredRanges.insert(descriptor.documentRange)
    }

    // Keep the cleanup path defensive for a partially installed overlay. A
    // descriptor is normally present for every painted range, but restoring a
    // remaining range is safer than leaving the source permanently hidden.
    for range in paintedRanges
      where !restoredRanges.contains(range)
        && range.location != NSNotFound
        && NSMaxRange(range) <= documentLength
    {
      restoreInlineAttachmentRendering(in: range, textView: textView)
    }
  }

  func applyInlineAttachmentOverlays(
    in textView: NSTextView,
    applicationRange: NSRange,
    preservingExisting: Bool = false
  ) {
    if !preservingExisting {
      clearInlineAttachmentOverlays(in: textView)
    }
    let document = textView.string as NSString
    guard bodyUTF16Offset >= 0, bodyUTF16Offset <= document.length else { return }
    let plan = cachedInlineAttachmentPlan(in: document)

    let selection = textView.selectedRange()
    let attachmentByReference = attachmentReferenceLookup()
    var desiredCandidates: [String: MarkdownInlineAttachmentOverlayCandidate] = [:]
    var desiredKeys = Set<String>()
    for item in visibleInlineAttachmentItems(in: plan, applicationRange: applicationRange) {
      let documentRange = NSRange(
        location: bodyUTF16Offset + item.range.location,
        length: item.range.length
      )
      guard NSIntersectionRange(documentRange, applicationRange).length > 0,
        !Self.selection(selection, touches: documentRange)
      else { continue }

      let key = inlineAttachmentOverlayKey(for: documentRange)
      if preservingExisting,
        inlineAttachmentOverlayViews[key] != nil,
        let current = inlineAttachmentOverlayDescriptors[key],
        canReuseInlineAttachmentOverlay(
          current,
          item: item,
          documentRange: documentRange,
          attachmentByReference: attachmentByReference
        )
      {
        // A viewport scroll changes which candidates are visible, but it does
        // not change the document-space geometry of an unchanged overlay.
        // Keep the existing descriptor and view so TextKit does not have to
        // ensure layout and enumerate text segments again on every scroll.
        desiredKeys.insert(key)
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
        desiredKeys.insert(key)
        desiredCandidates[key] =
          MarkdownInlineAttachmentOverlayCandidate(
          content: .image(path: sourceURL.path, accessibilityText: accessibilityText),
          viewContent: .image(accessibilityText: accessibilityText),
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
          MarkdownInlineAttachmentOverlayCandidate(
          content: .formula(
            source: source,
            displayMode: displayMode,
            fontSize: fontSize
          ),
          viewContent: .formula(
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

    let obsoleteKeys = inlineAttachmentOverlayViews.keys.filter { key in
      guard let desired = desiredCandidates[key],
        let current = inlineAttachmentOverlayDescriptors[key]
      else { return !desiredKeys.contains(key) }
      return current.content != desired.content || current.documentRange != desired.documentRange
    }
    for key in obsoleteKeys {
      removeInlineAttachmentOverlay(forKey: key, in: textView)
    }

    var didMutateOverlays = !obsoleteKeys.isEmpty
    for (key, candidate) in desiredCandidates {
      if let overlay = inlineAttachmentOverlayViews[key],
        let current = inlineAttachmentOverlayDescriptors[key],
        current.content == candidate.content,
        current.documentRange == candidate.documentRange
      {
        guard let frame = inlineAttachmentOverlayFrame(for: candidate, in: textView) else {
          removeInlineAttachmentOverlay(forKey: key, in: textView)
          didMutateOverlays = true
          continue
        }
        overlay.frame = frame
        inlineAttachmentOverlayDescriptors[key] = MarkdownInlineAttachmentOverlayDescriptor(
          content: candidate.content,
          documentRange: candidate.documentRange,
          frame: frame,
          renderingAttributesSnapshots: current.renderingAttributesSnapshots,
          originalParagraphStyle: current.originalParagraphStyle
        )
        continue
      }
      installInlineAttachmentOverlay(candidate: candidate, key: key, in: textView)
      didMutateOverlays = true
    }
    inlineAttachmentPaintedRanges = inlineAttachmentOverlayDescriptors.values
      .map(\.documentRange)
      .sorted { $0.location < $1.location }
    if didMutateOverlays {
      (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
    }
  }

  private func installInlineAttachmentOverlay(
    candidate: MarkdownInlineAttachmentOverlayCandidate,
    key: String,
    in textView: NSTextView
  ) {
    // Resolve geometry before hiding the Markdown source. If the inline
    // presentation does not fit its source span or the current container,
    // the optional frame is nil and the source remains untouched.
    guard let frame = inlineAttachmentOverlayFrame(for: candidate, in: textView) else {
      return
    }

    let renderingAttributesSnapshots = captureRenderingAttributes(
      for: candidate.documentRange,
      in: textView
    )
    let originalParagraphStyle = textView.textStorage?.attribute(
      .paragraphStyle,
      at: candidate.documentRange.location,
      effectiveRange: nil
    ) as? NSParagraphStyle
    let paragraphStyle =
      (syntaxHighlightPalette.defaultAttributes[.paragraphStyle] as? NSParagraphStyle)?
      .mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
    paragraphStyle.minimumLineHeight = candidate.minimumLineHeight
    MarkdownTextKit2RangeAdapter.addRenderingAttributes(
      [
        .foregroundColor: NSColor.clear,
        .underlineColor: NSColor.clear,
      ],
      for: candidate.documentRange,
      in: textView
    )
    textView.textStorage?.addAttribute(
      .paragraphStyle,
      value: paragraphStyle,
      range: candidate.documentRange
    )
    let overlay = dequeueInlineAttachmentOverlayView(frame: frame)
    switch candidate.layout {
    case .block:
      overlay.autoresizingMask = [.width]
    case .inline:
      overlay.autoresizingMask = []
    }
    overlay.configure(candidate.viewContent)
    textView.addSubview(overlay)
    inlineAttachmentOverlayViews[key] = overlay
    inlineAttachmentOverlayDescriptors[key] = MarkdownInlineAttachmentOverlayDescriptor(
      content: candidate.content,
      documentRange: candidate.documentRange,
      frame: frame,
      renderingAttributesSnapshots: renderingAttributesSnapshots,
      originalParagraphStyle: originalParagraphStyle
    )

    guard let sourceURL = candidate.sourceURL else { return }
    inlineAttachmentImageTasks[key] = Task { @MainActor [weak self, weak textView, weak overlay] in
      let payload = await MarkdownInlineAttachmentImageCache.shared.image(at: sourceURL)
      guard let self, let textView, let overlay, !Task.isCancelled,
        self.inlineAttachmentOverlayViews[key] === overlay,
        self.inlineAttachmentOverlayDescriptors[key]?.content == candidate.content
      else { return }
      guard let payload else {
        self.inlineAttachmentFailedImagePaths.insert(sourceURL.path)
        self.removeInlineAttachmentOverlay(forKey: key, in: textView)
        return
      }
      overlay.setImage(NSImage(cgImage: payload.image, size: .zero))
      self.inlineAttachmentImageTasks[key] = nil
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

  private func inlineAttachmentOverlayKey(for range: NSRange) -> String {
    "attachment:\(range.location)"
  }

  private func canReuseInlineAttachmentOverlay(
    _ descriptor: MarkdownInlineAttachmentOverlayDescriptor,
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

  private func inlineAttachmentOverlayFrame(
    for candidate: MarkdownInlineAttachmentOverlayCandidate,
    in textView: NSTextView
  ) -> NSRect? {
    guard let sourceRect = MarkdownTextKit2RangeAdapter.rect(
      for: candidate.documentRange,
      in: textView
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
    return MarkdownInlineAttachmentOverlayLayout.frame(
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
    in textView: NSTextView
  ) -> [MarkdownInlineAttachmentOverlayDescriptor.RenderingAttributesSnapshot] {
    guard let manager = textView.textLayoutManager,
      let textRange = MarkdownTextKit2RangeAdapter.textRange(for: range, in: textView)
    else {
      return []
    }

    let renderingKeys: Set<NSAttributedString.Key> = [
      .foregroundColor,
      .underlineColor,
    ]
    manager.ensureLayout(for: textRange)
    var snapshots: [MarkdownInlineAttachmentOverlayDescriptor.RenderingAttributesSnapshot] = []
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
          MarkdownInlineAttachmentOverlayDescriptor.RenderingAttributesSnapshot(
            range: intersection,
            attributes: selectedAttributes
          )
        )
      }
      return NSMaxRange(fullRenderingRange) < NSMaxRange(range)
    }
    return snapshots
  }

  private func removeInlineAttachmentOverlay(forKey key: String, in textView: NSTextView) {
    inlineAttachmentImageTasks[key]?.cancel()
    inlineAttachmentImageTasks[key] = nil
    let overlay = inlineAttachmentOverlayViews.removeValue(forKey: key)
    guard let descriptor = inlineAttachmentOverlayDescriptors.removeValue(forKey: key) else {
      if let overlay {
        recycleInlineAttachmentOverlayView(overlay)
      }
      return
    }
    restoreInlineAttachmentRendering(
      in: descriptor.documentRange,
      textView: textView,
      renderingAttributesSnapshots: descriptor.renderingAttributesSnapshots,
      originalParagraphStyle: descriptor.originalParagraphStyle
    )
    inlineAttachmentPaintedRanges.removeAll { $0 == descriptor.documentRange }
    if let overlay {
      recycleInlineAttachmentOverlayView(overlay)
    }
  }

  private func dequeueInlineAttachmentOverlayView(
    frame: NSRect
  ) -> MarkdownInlineAttachmentOverlayView {
    let overlay = inlineAttachmentOverlayViewPool.popLast()
      ?? MarkdownInlineAttachmentOverlayView(frame: frame)
    overlay.prepareForReuse()
    overlay.frame = frame
    return overlay
  }

  private func recycleInlineAttachmentOverlayView(
    _ overlay: MarkdownInlineAttachmentOverlayView
  ) {
    overlay.removeFromSuperview()
    overlay.prepareForReuse()
    guard inlineAttachmentOverlayViewPool.count < Self.inlineAttachmentOverlayViewPoolLimit else {
      return
    }
    inlineAttachmentOverlayViewPool.append(overlay)
  }

  private func restoreInlineAttachmentRendering(
    in range: NSRange,
    textView: NSTextView,
    renderingAttributesSnapshots: [MarkdownInlineAttachmentOverlayDescriptor.RenderingAttributesSnapshot] = [],
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
