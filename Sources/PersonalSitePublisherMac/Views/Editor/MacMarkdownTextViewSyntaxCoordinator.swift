import AppKit
import Foundation
import OSLog
import PublishingWorkbenchCore

private struct MarkdownSyntaxSnapshotMergeResult: Sendable {
  let snapshot: MarkdownSyntaxHighlightSnapshot
  let runIndex: MarkdownSyntaxHighlightRunIndex
}

private enum MarkdownSyntaxSnapshotMerger {
  static func merge(
    current: MarkdownSyntaxHighlightSnapshot,
    previous: MarkdownSyntaxHighlightSnapshot?,
    previousText: String?,
    replacedRange: NSRange?,
    currentText: String
  ) -> MarkdownSyntaxSnapshotMergeResult {
    guard let previous,
      let previousText,
      let replacedRange,
      contains(replacedRange, in: previous.range)
    else {
      return MarkdownSyntaxSnapshotMergeResult(
        snapshot: current,
        runIndex: MarkdownSyntaxHighlightRunIndex(runs: current.runs)
      )
    }

    let previousLength = (previousText as NSString).length
    let currentLength = (currentText as NSString).length
    guard contains(replacedRange, in: NSRange(location: 0, length: previousLength)) else {
      return MarkdownSyntaxSnapshotMergeResult(
        snapshot: current,
        runIndex: MarkdownSyntaxHighlightRunIndex(runs: current.runs)
      )
    }
    let insertedLength = currentLength - (previousLength - replacedRange.length)
    guard insertedLength >= 0 else {
      return MarkdownSyntaxSnapshotMergeResult(
        snapshot: current,
        runIndex: MarkdownSyntaxHighlightRunIndex(runs: current.runs)
      )
    }
    let delta = insertedLength - replacedRange.length
    let oldEditEnd = NSMaxRange(replacedRange)

    let retainedRuns = previous.runs.compactMap { run -> MarkdownSyntaxHighlightRun? in
      let transformedRange: NSRange
      if NSMaxRange(run.range) <= replacedRange.location {
        transformedRange = run.range
      } else if run.range.location >= oldEditEnd {
        transformedRange = NSRange(
          location: run.range.location + delta,
          length: run.range.length
        )
      } else {
        return nil
      }
      guard transformedRange.location >= 0,
        NSMaxRange(transformedRange) <= currentLength,
        NSIntersectionRange(transformedRange, current.range).length == 0
      else {
        return nil
      }
      return MarkdownSyntaxHighlightRun(style: run.style, range: transformedRange)
    }

    let transformedPreviousRange = NSRange(
      location: min(previous.range.location, currentLength),
      length: min(
        currentLength - min(previous.range.location, currentLength),
        max(0, previous.range.length + delta)
      )
    )
    let mergedRange = NSUnionRange(transformedPreviousRange, current.range)
    let mergedRuns = (retainedRuns + current.runs).sorted { lhs, rhs in
      if lhs.range.location == rhs.range.location {
        return lhs.range.length < rhs.range.length
      }
      return lhs.range.location < rhs.range.location
    }
    return MarkdownSyntaxSnapshotMergeResult(
      snapshot: MarkdownSyntaxHighlightSnapshot(range: mergedRange, runs: mergedRuns),
      runIndex: MarkdownSyntaxHighlightRunIndex(locationSortedRuns: mergedRuns)
    )
  }

  private static func contains(_ inner: NSRange, in outer: NSRange) -> Bool {
    inner.location != NSNotFound
      && outer.location != NSNotFound
      && inner.location >= outer.location
      && NSMaxRange(inner) <= NSMaxRange(outer)
  }
}

enum MarkdownSyntaxSelectionInvalidationPlan {
  static func ranges(
    in text: String,
    runIndex: MarkdownSyntaxHighlightRunIndex,
    previousSelection: NSRange?,
    currentSelection: NSRange,
    paintedRange: NSRange
  ) -> [NSRange] {
    guard paintedRange.location != NSNotFound, paintedRange.length > 0 else { return [] }
    let previousRuns = Set(
      previousSelection.flatMap {
        scopedSelection($0, paintedRange: paintedRange)
      }.map(runIndex.runs(touchedBy:)) ?? [])
    let currentRuns = Set(
      scopedSelection(currentSelection, paintedRange: paintedRange)
        .map(runIndex.runs(touchedBy:)) ?? []
    )
    let changedRuns = previousRuns.symmetricDifference(currentRuns)
    guard !changedRuns.isEmpty else { return [] }

    let markers = MarkdownSyntaxMarkerRangeService.markerRanges(
      in: text,
      snapshot: MarkdownSyntaxHighlightSnapshot(
        range: paintedRange,
        runs: Array(changedRuns)
      )
    )
    return normalized(
      markers.compactMap { markerRange in
        let intersection = NSIntersectionRange(markerRange, paintedRange)
        return intersection.length > 0 ? intersection : nil
      }
    )
  }

  private static func scopedSelection(
    _ selection: NSRange,
    paintedRange: NSRange
  ) -> NSRange? {
    guard selection.location != NSNotFound, selection.location >= 0 else { return nil }
    if selection.length == 0 {
      guard selection.location >= paintedRange.location,
        selection.location <= NSMaxRange(paintedRange)
      else { return nil }
      return selection
    }
    let intersection = NSIntersectionRange(selection, paintedRange)
    return intersection.length > 0 ? intersection : nil
  }

  private static func normalized(_ ranges: [NSRange]) -> [NSRange] {
    ranges.sorted {
      $0.location == $1.location
        ? $0.length < $1.length
        : $0.location < $1.location
    }.reduce(into: []) { result, range in
      guard let last = result.last else {
        result.append(range)
        return
      }
      if range.location <= NSMaxRange(last) {
        result[result.count - 1] = NSUnionRange(last, range)
      } else {
        result.append(range)
      }
    }
  }
}

enum MarkdownSyntaxPaintedRangeTransform {
  static func range(
    _ range: NSRange,
    previousLength: Int,
    currentLength: Int,
    replacedRange: NSRange
  ) -> NSRange? {
    guard isValid(range, length: previousLength),
      isValid(replacedRange, length: previousLength)
    else { return nil }
    let insertedLength = currentLength - (previousLength - replacedRange.length)
    guard insertedLength >= 0 else { return nil }
    let delta = insertedLength - replacedRange.length
    let editEnd = NSMaxRange(replacedRange)
    let insertedEnd = replacedRange.location + insertedLength
    let transformedStart: Int
    let transformedEnd: Int

    if NSMaxRange(range) <= replacedRange.location {
      transformedStart = range.location
      transformedEnd = NSMaxRange(range)
    } else if range.location >= editEnd {
      transformedStart = range.location + delta
      transformedEnd = NSMaxRange(range) + delta
    } else {
      transformedStart = min(range.location, replacedRange.location)
      transformedEnd = max(insertedEnd, NSMaxRange(range) + delta)
    }

    let start = min(max(0, transformedStart), currentLength)
    let end = min(max(start, transformedEnd), currentLength)
    guard end > start else { return nil }
    return NSRange(location: start, length: end - start)
  }

  static func retainedMarkerRanges(
    _ ranges: [NSRange],
    previousLength: Int,
    currentLength: Int,
    replacedRange: NSRange
  ) -> [NSRange] {
    ranges.compactMap { range in
      guard !selection(replacedRange, touches: range) else { return nil }
      return self.range(
        range,
        previousLength: previousLength,
        currentLength: currentLength,
        replacedRange: replacedRange
      )
    }
  }

  static func selectionRange(
    _ selection: NSRange,
    previousLength: Int,
    currentLength: Int,
    replacedRange: NSRange
  ) -> NSRange? {
    guard isValid(selection, length: previousLength),
      isValid(replacedRange, length: previousLength)
    else { return nil }
    let insertedLength = currentLength - (previousLength - replacedRange.length)
    guard insertedLength >= 0 else { return nil }
    let delta = insertedLength - replacedRange.length
    let editEnd = NSMaxRange(replacedRange)

    if NSMaxRange(selection) <= replacedRange.location {
      return selection
    }
    if selection.location >= editEnd {
      let shiftedLocation = selection.location + delta
      guard shiftedLocation >= 0,
        shiftedLocation <= currentLength,
        selection.length <= currentLength - shiftedLocation
      else { return nil }
      return NSRange(location: shiftedLocation, length: selection.length)
    }
    return nil
  }

  private static func selection(_ selection: NSRange, touches range: NSRange) -> Bool {
    if selection.length == 0 {
      return selection.location >= range.location && selection.location <= NSMaxRange(range)
    }
    return NSIntersectionRange(selection, range).length > 0
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }
}

struct MarkdownDiagnosticOverlayUpdateMetrics: Equatable, Sendable {
  let removedCount: Int
  let appliedCount: Int

  static let unchanged = MarkdownDiagnosticOverlayUpdateMetrics(
    removedCount: 0,
    appliedCount: 0
  )
}

/// Idle delays for document-wide statistics scans. Incremental updates remain
/// on the normal short delivery edge; only a long-document fallback scan is
/// deliberately moved farther from the typing hot path.
enum MarkdownEditorStatisticsDelayPolicy {
  static let initialFullScanDelay: TimeInterval = 0.5
  static let incrementalDeliveryDelay: TimeInterval = 0.5
  static let longDocumentFullScanDelay: TimeInterval = 2.5
  static let longDocumentUTF16Threshold = 5_000

  static func fullScanDelay(for text: String, isInitialLoad: Bool) -> TimeInterval {
    guard !isInitialLoad,
      (text as NSString).length > longDocumentUTF16Threshold
    else {
      return initialFullScanDelay
    }
    return longDocumentFullScanDelay
  }
}

extension MacMarkdownTextView.Coordinator {
  /// Stops source-only rendering work while the text storage temporarily hosts
  /// the derived read-only presentation, without discarding the parser snapshot
  /// that still belongs to the unchanged Markdown source.
  func suspendSyntaxHighlightingForReadOnlyPresentation(in textView: NSTextView) {
    cancelPendingInlineAttachmentDrawingApplication()
    clearInlineAttachmentDrawings(in: textView)
    clearBlockMarkerDrawings(in: textView)
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.markdownParagraphHighlightRect = nil
    }
    appliedParagraphHighlightRange = nil
    syntaxHighlightDebouncer.cancel()
    syntaxTreeSynchronizationDebouncer.cancel()
    cancelPendingSyntaxAttributeApplication()
  }

  func invalidateHighlightedTextCache(in textView: NSTextView? = nil) {
    cancelPendingInlineAttachmentDrawingApplication()
    clearInlineAttachmentDrawings(in: textView)
    clearBlockMarkerDrawings(in: textView)
    if let textView {
      removePaintedSyntaxAttributes(in: textView)
    }
    syntaxParsedSnapshotCache = nil
    syntaxParsedRunIndex = nil
    syntaxParsedDocumentRevision = nil
    syntaxTreeDocumentRevision = nil
    pendingSyntaxParserEdit = nil
    syntaxPaintedDocumentRevision = nil
    paintedSyntaxViewportRange = nil
    paintedSyntaxSelectionRange = nil
    pendingSyntaxHighlightPlan = nil
    syntaxCodeBlockRanges = nil
    inlineAttachmentPlan = nil
    inlineAttachmentPlanDocumentRevision = nil
    inlineAttachmentPlanBodyUTF16Offset = nil
    syntaxHighlightDebouncer.cancel()
    syntaxTreeSynchronizationDebouncer.cancel()
    cancelPendingSyntaxAttributeApplication()
  }

  func removePaintedSyntaxAttributes(in textView: NSTextView) {
    restoreCollapsedSyntaxMarkerLayout(in: textView)
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.markdownParagraphHighlightRect = nil
    }
    appliedParagraphHighlightRange = nil
    guard syntaxPaintedDocumentRevision == syntaxDocumentRevision,
      let paintedSyntaxViewportRange
    else {
      syntaxPaintedDocumentRevision = nil
      self.paintedSyntaxViewportRange = nil
      paintedSyntaxSelectionRange = nil
      return
    }
    MarkdownTextKit2RangeAdapter.removeRenderingAttributes(
      syntaxRenderingAttributeKeys,
      for: paintedSyntaxViewportRange,
      in: textView
    )
    syntaxPaintedDocumentRevision = nil
    self.paintedSyntaxViewportRange = nil
    paintedSyntaxSelectionRange = nil
  }

  func preparePaintedSyntaxForEdit(
    in textView: NSTextView,
    affectedRange: NSRange
  ) {
    cancelPendingSyntaxAttributeApplication()
    guard syntaxPaintedDocumentRevision == syntaxDocumentRevision else { return }
    let touchedMarkerRanges = collapsedSyntaxMarkerRanges.filter {
      Self.syntaxEditRange(affectedRange, touches: $0)
    }
    guard !touchedMarkerRanges.isEmpty else { return }
    restoreCollapsedSyntaxMarkerLayout(
      in: textView,
      intersecting: touchedMarkerRanges
    )
    for markerRange in touchedMarkerRanges {
      MarkdownTextKit2RangeAdapter.removeRenderingAttributes(
        syntaxRenderingAttributeKeys,
        for: markerRange,
        in: textView
      )
    }
    let touchedSet = Set(touchedMarkerRanges)
    collapsedSyntaxMarkerRanges.removeAll { touchedSet.contains($0) }
  }

  @discardableResult
  func reconcilePaintedSyntaxState(
    after edit: MarkdownTextEdit?,
    plan: MarkdownSyntaxHighlightPlan,
    previousRevision: UInt64,
    currentText: String,
    in textView: NSTextView
  ) -> Bool {
    guard let edit,
      syntaxPaintedDocumentRevision == previousRevision,
      let parsedSnapshot = syntaxParsedSnapshotCache,
      let parsedRevision = syntaxParsedDocumentRevision
    else {
      discardPaintedSyntaxStateAfterEdit(currentText: currentText, in: textView)
      return false
    }
    let accumulatedEdit = pendingSyntaxParserEdit
    let canMergeParsedSnapshot =
      (parsedRevision == previousRevision
        && Self.contains(edit.replacedRange, in: parsedSnapshot.range))
      || (accumulatedEdit?.baseRevision == parsedRevision
        && accumulatedEdit.map {
          Self.contains($0.replacedRange, in: parsedSnapshot.range)
        } == true)
    guard canMergeParsedSnapshot else {
      discardPaintedSyntaxStateAfterEdit(currentText: currentText, in: textView)
      return false
    }

    let previousLength = (edit.previousText as NSString).length
    let currentLength = (currentText as NSString).length
    let fullDocumentRange = NSRange(location: 0, length: currentLength)
    let isLocalStablePlan =
      plan.codeBlockRanges != nil
      && !plan.requiresCodeBlockResynchronization
      && plan.range != fullDocumentRange
    guard isLocalStablePlan,
      let paintedRange = paintedSyntaxViewportRange.flatMap({
        MarkdownSyntaxPaintedRangeTransform.range(
          $0,
          previousLength: previousLength,
          currentLength: currentLength,
          replacedRange: edit.replacedRange
        )
      })
    else {
      discardPaintedSyntaxStateAfterEdit(currentText: currentText, in: textView)
      return false
    }

    paintedSyntaxViewportRange = paintedRange
    collapsedSyntaxMarkerRanges = MarkdownSyntaxPaintedRangeTransform.retainedMarkerRanges(
      collapsedSyntaxMarkerRanges,
      previousLength: previousLength,
      currentLength: currentLength,
      replacedRange: edit.replacedRange
    )
    paintedSyntaxSelectionRange = paintedSyntaxSelectionRange.flatMap {
      MarkdownSyntaxPaintedRangeTransform.selectionRange(
        $0,
        previousLength: previousLength,
        currentLength: currentLength,
        replacedRange: edit.replacedRange
      )
    }
    syntaxPaintedDocumentRevision = syntaxDocumentRevision
    return true
  }

  private func discardPaintedSyntaxStateAfterEdit(
    currentText: String,
    in textView: NSTextView
  ) {
    let currentLength = (currentText as NSString).length
    paintedSyntaxViewportRange =
      currentLength > 0
      ? NSRange(location: 0, length: currentLength)
      : nil
    syntaxPaintedDocumentRevision = syntaxDocumentRevision
    if paintedSyntaxViewportRange != nil {
      removePaintedSyntaxAttributes(in: textView)
    } else {
      restoreCollapsedSyntaxMarkerLayout(in: textView)
      syntaxPaintedDocumentRevision = nil
      paintedSyntaxSelectionRange = nil
    }
  }

  func scheduleFullStatistics(for text: String, isInitialLoad: Bool = false) {
    statisticsFullScanCount += 1
    statisticsTask?.cancel()
    statisticsGeneration += 1
    let generation = statisticsGeneration
    let delay = MarkdownEditorStatisticsDelayPolicy.fullScanDelay(
      for: text,
      isInitialLoad: isInitialLoad
    )
    statisticsTask = Task.detached(priority: .userInitiated) { [weak self, text] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      let updatedStatistics = MarkdownEditorStatistics.make(for: text)
      await self?.applyFullStatistics(
        updatedStatistics,
        for: text,
        generation: generation
      )
    }
  }

  func scheduleMarkdownSyntaxHighlighting(
    for textView: NSTextView,
    text: String,
    plan: MarkdownSyntaxHighlightPlan? = nil,
    repaintReason: MarkdownSyntaxViewportRepaintReason = .content
  ) {
    cancelPendingSyntaxAttributeApplication()
    if repaintReason.requiresFullRepaint {
      cancelPendingInlineAttachmentDrawingApplication()
    }

    self.textView = textView
    let requestedPlan = plan ?? .fullDocument(for: text)
    let requestedRevision = syntaxDocumentRevision
    pendingSyntaxHighlightPlan = requestedPlan
    syntaxCodeBlockRanges = requestedPlan.codeBlockRanges

    if syntaxParsedDocumentRevision == requestedRevision,
      let cachedSnapshot = syntaxParsedSnapshotCache,
      Self.contains(requestedPlan.range, in: cachedSnapshot.range)
    {
      pendingSyntaxHighlightPlan = nil
      repaintVisibleSyntaxViewport(
        in: textView,
        reason: repaintReason,
        contentInvalidatedRange: requestedPlan.range
      )
      return
    }

    let syntaxHighlightParser = self.syntaxHighlightParser
    let bodyUTF16Offset = self.bodyUTF16Offset
    let accumulatedEdit = pendingSyntaxParserEdit
    let canMergePreviousSnapshot =
      accumulatedEdit?.baseRevision
      == syntaxParsedDocumentRevision
    let previousSnapshot = canMergePreviousSnapshot ? syntaxParsedSnapshotCache : nil
    let previousText = previousSnapshot == nil ? nil : accumulatedEdit?.baseText
    let replacedRange = previousSnapshot == nil ? nil : accumulatedEdit?.replacedRange
    let parserEdit = accumulatedEdit?.parserEdit
    let synchronizesTree =
      parserEdit != nil
      || syntaxTreeDocumentRevision == nil
      || requestedPlan.codeBlockRanges == nil
      || requestedPlan.requiresCodeBlockResynchronization
    if synchronizesTree {
      syntaxTreeSynchronizationDebouncer.cancel()
    } else if syntaxTreeDocumentRevision != requestedRevision {
      scheduleMarkdownSyntaxTreeSynchronization(
        text: text,
        revision: requestedRevision,
        edit: parserEdit
      )
    }
    let delay = MarkdownSyntaxHighlightSchedulingPolicy.delay(
      for: requestedPlan,
      documentUTF16Length: (text as NSString).length
    )
    syntaxHighlightDebouncer.schedule(
      delay: delay,
      operation: { [text] () async -> MarkdownSyntaxHighlightComputation? in
        let resolvedPlan = MarkdownSyntaxHighlightRangeService.resolvingCodeBlockRanges(
          in: text,
          plan: requestedPlan
        )
        guard !Task.isCancelled else { return nil }
        guard
          let parsedSnapshot = await syntaxHighlightParser.snapshot(
            in: text,
            range: resolvedPlan.range,
            revision: requestedRevision,
            edit: synchronizesTree ? parserEdit : nil,
            mode: synchronizesTree ? .synchronized : .lightweight,
            knownCodeBlockRanges: resolvedPlan.codeBlockRanges
          )
        else {
          return nil
        }
        let snapshot = MarkdownSyntaxHighlightSnapshot(
          range: parsedSnapshot.range,
          runs: parsedSnapshot.runs.filter { run in
            run.style != .html || run.range.location >= bodyUTF16Offset
          }
        )
        guard !Task.isCancelled else { return nil }
        let mergedResult = MarkdownSyntaxSnapshotMerger.merge(
          current: snapshot,
          previous: previousSnapshot,
          previousText: previousText,
          replacedRange: replacedRange,
          currentText: text
        )
        guard !Task.isCancelled else { return nil }
        let parserMetrics = await syntaxHighlightParser.metrics()
        return MarkdownSyntaxHighlightComputation(
          text: text,
          revision: requestedRevision,
          plan: resolvedPlan,
          snapshot: mergedResult.snapshot,
          runIndex: mergedResult.runIndex,
          synchronizedTree: synchronizesTree,
          parserMetrics: parserMetrics
        )
      },
      onValue: { [weak self] computation in
        guard let self, let textView = self.textView else { return }
        guard self.syntaxDocumentRevision == computation.revision else { return }
        self.syntaxParsedSnapshotCache = computation.snapshot
        self.syntaxParsedRunIndex = computation.runIndex
        self.syntaxParsedDocumentRevision = computation.revision
        if computation.synchronizedTree {
          self.syntaxTreeDocumentRevision = computation.revision
          self.pendingSyntaxParserEdit = nil
        }
        if computation.parserMetrics.fallbackParseCount > self.loggedSyntaxFallbackCount {
          let fallbackReason = computation.parserMetrics.lastFallbackReason ?? "unknown"
          let fallbackRange =
            computation.parserMetrics.lastFallbackRange
            ?? NSRange(
              location: NSNotFound,
              length: 0
            )
          self.syntaxHighlightLogger.error(
            "Tree-sitter fallback: reason=\(fallbackReason, privacy: .public), rangeLocation=\(fallbackRange.location, privacy: .public), rangeLength=\(fallbackRange.length, privacy: .public), count=\(computation.parserMetrics.fallbackParseCount, privacy: .public)"
          )
          for fallbackCount
            in (self.loggedSyntaxFallbackCount + 1)...computation.parserMetrics.fallbackParseCount
          {
            self.syntaxHighlightSignposter.emitEvent(
              "TreeSitterFallback",
              "reason: \(fallbackReason, privacy: .public), rangeLocation: \(fallbackRange.location, privacy: .public), rangeLength: \(fallbackRange.length, privacy: .public), count: \(fallbackCount, privacy: .public)"
            )
          }
          self.loggedSyntaxFallbackCount = computation.parserMetrics.fallbackParseCount
        }
        self.syntaxCodeBlockRanges = computation.plan.codeBlockRanges
        self.pendingSyntaxHighlightPlan = nil
        self.repaintVisibleSyntaxViewport(
          in: textView,
          snapshot: computation.snapshot,
          text: computation.text,
          reason: repaintReason,
          contentInvalidatedRange: computation.plan.range
        )
      }
    )
  }

  private func scheduleMarkdownSyntaxTreeSynchronization(
    text: String,
    revision: UInt64,
    edit: MarkdownSyntaxHighlightEdit?
  ) {
    let syntaxHighlightParser = self.syntaxHighlightParser
    syntaxTreeSynchronizationDebouncer.schedule(
      delay: MarkdownSyntaxHighlightSchedulingPolicy.idleTreeSynchronizationDelay,
      operation: { [text] () async -> UInt64? in
        guard !Task.isCancelled else { return nil }
        let synchronized = await syntaxHighlightParser.synchronizeTree(
          in: text,
          revision: revision,
          edit: edit
        )
        guard synchronized, !Task.isCancelled else { return nil }
        return revision
      },
      onValue: { [weak self] synchronizedRevision in
        guard let self,
          self.syntaxDocumentRevision == synchronizedRevision
        else {
          return
        }
        self.syntaxTreeDocumentRevision = synchronizedRevision
        self.pendingSyntaxParserEdit = nil
      }
    )
  }

  private func applyFullStatistics(
    _ updatedStatistics: MarkdownEditorStatistics,
    for text: String,
    generation: Int
  ) {
    guard statisticsGeneration == generation else { return }
    statistics = updatedStatistics
    statisticsText = text
    statisticsTask = nil
    let signpostState = syntaxHighlightSignposter.beginInterval("DeliverEditorStatistics")
    defer {
      syntaxHighlightSignposter.endInterval(
        "DeliverEditorStatistics",
        signpostState
      )
    }
    onStatisticsChanged(updatedStatistics)
  }

  func repaintVisibleSyntaxViewport(
    in textView: NSTextView,
    snapshot: MarkdownSyntaxHighlightSnapshot? = nil,
    text: String? = nil,
    reason: MarkdownSyntaxViewportRepaintReason = .content,
    contentInvalidatedRange: NSRange? = nil
  ) {
    let currentText = text ?? textView.string
    guard let snapshot = snapshot ?? syntaxParsedSnapshotCache,
      syntaxParsedDocumentRevision == syntaxDocumentRevision
    else {
      return
    }
    guard let visibleRange = MarkdownTextKit2RangeAdapter.visibleRange(in: textView) else {
      return
    }
    let paddedRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: currentText,
      visibleRange: visibleRange
    )
    guard paddedRange.length > 0 else { return }
    guard Self.contains(paddedRange, in: snapshot.range) else {
      scheduleMarkdownSyntaxHighlighting(
        for: textView,
        text: currentText,
        plan: MarkdownSyntaxHighlightPlan(
          range: paddedRange,
          codeBlockRanges: syntaxCodeBlockRanges
        ),
        repaintReason: reason
      )
      return
    }

    cancelPendingSyntaxAttributeApplication()
    if reason.requiresFullRepaint {
      cancelPendingInlineAttachmentDrawingApplication()
    }
    syntaxAttributeApplicationGeneration &+= 1
    let generation = syntaxAttributeApplicationGeneration
    syntaxAttributeApplicationTask = Task { @MainActor [weak self, weak textView] in
      await Task.yield()
      guard let self, let textView else { return }
      self.applyMarkdownSyntaxHighlighting(
        text: currentText,
        snapshot: snapshot,
        generation: generation,
        repaintReason: reason,
        contentInvalidatedRange: contentInvalidatedRange,
        in: textView
      )
    }
  }

  private func applyMarkdownSyntaxHighlighting(
    text: String,
    snapshot: MarkdownSyntaxHighlightSnapshot,
    generation: UInt64,
    repaintReason: MarkdownSyntaxViewportRepaintReason,
    contentInvalidatedRange: NSRange?,
    in textView: NSTextView
  ) {
    guard syntaxAttributeApplicationGeneration == generation,
      !Task.isCancelled,
      syntaxParsedDocumentRevision == syntaxDocumentRevision
    else {
      return
    }

    guard let visibleRange = MarkdownTextKit2RangeAdapter.visibleRange(in: textView) else {
      return
    }
    let paddedRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: text,
      visibleRange: visibleRange
    )
    let applicationRange = NSIntersectionRange(snapshot.range, paddedRange)
    guard applicationRange.length > 0 else { return }

    let runIndex =
      syntaxParsedRunIndex
      ?? MarkdownSyntaxHighlightRunIndex(runs: snapshot.runs)
    let viewportSnapshot = MarkdownSyntaxHighlightSnapshot(
      range: applicationRange,
      runs: runIndex.runs(
        intersecting: applicationRange,
        clippingToIntersection: true
      )
    )
    let signpostID = syntaxHighlightSignposter.makeSignpostID()
    let intervalState = syntaxHighlightSignposter.beginInterval(
      "ApplyAttributes",
      id: signpostID,
      "rangeLength: \(applicationRange.length, privacy: .public), runCount: \(viewportSnapshot.runs.count, privacy: .public)"
    )
    let canReusePaintedState = syntaxPaintedDocumentRevision == syntaxDocumentRevision
    let renderPlan: MarkdownSyntaxViewportRenderPlan
    let canApplyIncrementalUpdate: Bool
    switch repaintReason {
    case .appearance:
      canApplyIncrementalUpdate = false
      renderPlan = MarkdownSyntaxViewportRenderPlan.make(
        previousPaintedRange: paintedSyntaxViewportRange,
        currentSnapshot: viewportSnapshot,
        requiresFullRepaint: true
      )
    case .viewport:
      canApplyIncrementalUpdate = canReusePaintedState
      renderPlan = MarkdownSyntaxViewportRenderPlan.make(
        previousPaintedRange: canReusePaintedState ? paintedSyntaxViewportRange : nil,
        currentSnapshot: viewportSnapshot,
        requiresFullRepaint: !canReusePaintedState
      )
    case .content:
      var dirtyRanges = contentInvalidatedRange.map { [$0] } ?? []
      if canReusePaintedState {
        dirtyRanges.append(
          contentsOf: MarkdownSyntaxSelectionInvalidationPlan.ranges(
            in: text,
            runIndex: runIndex,
            previousSelection: paintedSyntaxSelectionRange,
            currentSelection: textView.selectedRange(),
            paintedRange: applicationRange
          )
        )
      }
      canApplyIncrementalUpdate = canReusePaintedState && !dirtyRanges.isEmpty
      renderPlan =
        canApplyIncrementalUpdate
        ? incrementalSyntaxRenderPlan(
          previousPaintedRange: paintedSyntaxViewportRange,
          currentSnapshot: viewportSnapshot,
          invalidatedRanges: dirtyRanges,
          runIndex: runIndex
        )
        : MarkdownSyntaxViewportRenderPlan.make(
          previousPaintedRange: paintedSyntaxViewportRange,
          currentSnapshot: viewportSnapshot,
          requiresFullRepaint: true
        )
    case .selection:
      let selectionInvalidatedRanges =
        canReusePaintedState
        ? MarkdownSyntaxSelectionInvalidationPlan.ranges(
          in: text,
          runIndex: runIndex,
          previousSelection: paintedSyntaxSelectionRange,
          currentSelection: textView.selectedRange(),
          paintedRange: applicationRange
        )
        : []
      canApplyIncrementalUpdate = canReusePaintedState
      renderPlan =
        canReusePaintedState
        ? incrementalSyntaxRenderPlan(
          previousPaintedRange: paintedSyntaxViewportRange,
          currentSnapshot: viewportSnapshot,
          invalidatedRanges: selectionInvalidatedRanges,
          runIndex: runIndex
        )
        : MarkdownSyntaxViewportRenderPlan.make(
          previousPaintedRange: paintedSyntaxViewportRange,
          currentSnapshot: viewportSnapshot,
          requiresFullRepaint: true
        )
    }
    let renderingAttributesID = syntaxHighlightSignposter.makeSignpostID()
    let renderingAttributesInterval = syntaxHighlightSignposter.beginInterval(
      "ApplyRenderingAttributes",
      id: renderingAttributesID
    )
    let preserveInlineAttachmentDrawings = repaintReason.preservesInlineAttachmentDrawings
    if !canApplyIncrementalUpdate, !preserveInlineAttachmentDrawings {
      clearInlineAttachmentDrawings(in: textView)
    }
    if canApplyIncrementalUpdate {
      restoreCollapsedSyntaxMarkerLayout(
        in: textView,
        intersecting: renderPlan.removalRanges
      )
      for removalRange in renderPlan.removalRanges {
        MarkdownTextKit2RangeAdapter.removeRenderingAttributes(
          syntaxRenderingAttributeKeys,
          for: removalRange,
          in: textView
        )
      }
    } else {
      removePaintedSyntaxAttributes(in: textView)
    }
    var appliedRunCount = 0
    for applicationSnapshot in renderPlan.applicationSnapshots {
      appliedRunCount += MarkdownTextKit2RangeAdapter.applySyntaxHighlighting(
        applicationSnapshot,
        defaultAttributes: syntaxHighlightPalette.defaultAttributes,
        styleAttributes: syntaxHighlightPalette.styleAttributes,
        in: textView
      )
    }
    syntaxHighlightSignposter.endInterval(
      "ApplyRenderingAttributes",
      renderingAttributesInterval
    )
    let markerAttributesID = syntaxHighlightSignposter.makeSignpostID()
    let markerAttributesInterval = syntaxHighlightSignposter.beginInterval(
      "ApplyMarkerAttributes",
      id: markerAttributesID
    )
    let inactiveMarkers = MarkdownSyntaxMarkerRangeService.markers(
      in: text,
      snapshot: MarkdownSyntaxHighlightSnapshot(
        range: snapshot.range,
        runs: runIndex.runs(
          intersecting: applicationRange,
          clippingToIntersection: false
        )
      ),
      activeSelection: textView.selectedRange()
    ).compactMap { marker -> MarkdownSyntaxMarker? in
      let intersection = NSIntersectionRange(marker.range, applicationRange)
      guard intersection.length > 0 else { return nil }
      return MarkdownSyntaxMarker(range: intersection, presentation: marker.presentation)
    }
    let markerApplicationRanges = renderPlan.applicationSnapshots.map(\.range)
    let markersToApply = inactiveMarkers.flatMap { marker in
      markerApplicationRanges.compactMap { range -> MarkdownSyntaxMarker? in
        let intersection = NSIntersectionRange(marker.range, range)
        guard intersection.length > 0 else { return nil }
        return MarkdownSyntaxMarker(
          range: intersection,
          presentation: marker.presentation
        )
      }
    }
    let applicationRangeResolver = MarkdownTextKit2RangeAdapter.rangeResolver(
      for: applicationRange,
      in: textView
    )
    let textStorage = textView.textStorage
    textStorage?.beginEditing()
    for marker in markersToApply {
      if let applicationRangeResolver {
        MarkdownTextKit2RangeAdapter.addRenderingAttributes(
          syntaxHighlightPalette.inactiveMarkerAttributes,
          for: marker.range,
          using: applicationRangeResolver
        )
      }
      switch marker.presentation {
      case .hidden:
        textStorage?.addAttribute(
          .font,
          value: syntaxHighlightPalette.inactiveMarkerLayoutFont,
          range: marker.range
        )
      case .taskList:
        textStorage?.addAttribute(
          .font,
          value: syntaxHighlightPalette.inactiveTaskMarkerLayoutFont,
          range: marker.range
        )
      case .unorderedList, .orderedList, .quote:
        break
      }
    }
    textStorage?.endEditing()
    collapsedSyntaxMarkerRanges = inactiveMarkers.compactMap { marker in
      switch marker.presentation {
      case .hidden, .taskList:
        marker.range
      case .unorderedList, .orderedList, .quote:
        nil
      }
    }
    syntaxHighlightSignposter.endInterval(
      "ApplyMarkerAttributes",
      markerAttributesInterval
    )
    let blockMarkerID = syntaxHighlightSignposter.makeSignpostID()
    let blockMarkerInterval = syntaxHighlightSignposter.beginInterval(
      "ApplyBlockMarkerDrawings",
      id: blockMarkerID
    )
    let visibleBlockMarkers = inactiveMarkers.compactMap { marker -> MarkdownSyntaxMarker? in
      let intersection = NSIntersectionRange(marker.range, visibleRange)
      guard intersection.length > 0 else { return nil }
      return MarkdownSyntaxMarker(range: intersection, presentation: marker.presentation)
    }
    applyBlockMarkerDrawings(
      visibleBlockMarkers,
      in: textView,
      rangeResolver: MarkdownTextKit2RangeAdapter.rangeResolver(
        for: visibleRange,
        in: textView
      )
    )
    syntaxHighlightSignposter.endInterval(
      "ApplyBlockMarkerDrawings",
      blockMarkerInterval
    )
    scheduleInlineAttachmentDrawingApplication(
      in: textView,
      // Syntax highlighting keeps 50 context lines warm, but image and formula
      // drawings are only useful inside the actual viewport. Avoid measuring
      // cards for the padded context during attachment-heavy scrolling.
      applicationRange: visibleRange,
      preservingExisting: preserveInlineAttachmentDrawings,
      documentRevision: syntaxDocumentRevision
    )
    syntaxPaintedDocumentRevision = syntaxDocumentRevision
    paintedSyntaxViewportRange = applicationRange
    paintedSyntaxSelectionRange = textView.selectedRange()

    if !hasLoggedSyntaxTelemetryActivation {
      syntaxHighlightLogger.info(
        "Viewport syntax telemetry active: documentLength=\((text as NSString).length, privacy: .public), rangeLength=\(applicationRange.length, privacy: .public), runCount=\(appliedRunCount, privacy: .public)"
      )
      hasLoggedSyntaxTelemetryActivation = true
    }
    refreshCachedTypingAttributes(in: textView)
    let editorOverlaysID = syntaxHighlightSignposter.makeSignpostID()
    let editorOverlaysInterval = syntaxHighlightSignposter.beginInterval(
      "ApplyEditorOverlays",
      id: editorOverlaysID
    )
    let overlayInvalidatedRanges = renderPlan.applicationSnapshots.map(\.range)
    let didRefreshParagraph = updateCurrentParagraphHighlight(
      in: textView,
      force: !canApplyIncrementalUpdate,
      invalidatedRanges: overlayInvalidatedRanges
    )
    let diagnosticMetrics = updateDiagnosticOverlays(
      in: textView,
      applicationRange: applicationRange,
      force: !canApplyIncrementalUpdate,
      invalidatedRanges: overlayInvalidatedRanges
    )
    syntaxHighlightSignposter.endInterval(
      "ApplyEditorOverlays",
      editorOverlaysInterval
    )
    syntaxHighlightSignposter.endInterval(
      "ApplyAttributes",
      intervalState,
      "documentLength: \((text as NSString).length, privacy: .public), affectedLength: \(renderPlan.affectedUTF16Length, privacy: .public), appliedRuns: \(appliedRunCount, privacy: .public), paragraphRefreshed: \(didRefreshParagraph, privacy: .public), diagnosticRemoved: \(diagnosticMetrics.removedCount, privacy: .public), diagnosticApplied: \(diagnosticMetrics.appliedCount, privacy: .public)"
    )
    syntaxAttributeApplicationTask = nil
  }

  private func incrementalSyntaxRenderPlan(
    previousPaintedRange: NSRange?,
    currentSnapshot: MarkdownSyntaxHighlightSnapshot,
    invalidatedRanges: [NSRange],
    runIndex: MarkdownSyntaxHighlightRunIndex
  ) -> MarkdownSyntaxViewportRenderPlan {
    let viewportPlan = MarkdownSyntaxViewportRenderPlan.make(
      previousPaintedRange: previousPaintedRange,
      currentSnapshot: currentSnapshot,
      requiresFullRepaint: false
    )
    let dirtyRanges = invalidatedRanges.compactMap { range -> NSRange? in
      let intersection = NSIntersectionRange(range, currentSnapshot.range)
      return intersection.length > 0 ? intersection : nil
    }
    let removalRanges = Self.normalizedSyntaxMutationRanges(
      viewportPlan.removalRanges + dirtyRanges
    )
    let applicationRanges = Self.normalizedSyntaxMutationRanges(
      viewportPlan.applicationSnapshots.map(\.range) + dirtyRanges
    )
    let applicationSnapshots = applicationRanges.map { range in
      MarkdownSyntaxHighlightSnapshot(
        range: range,
        runs: runIndex.runs(
          intersecting: range,
          clippingToIntersection: true
        )
      )
    }
    return MarkdownSyntaxViewportRenderPlan(
      removalRanges: removalRanges,
      applicationSnapshots: applicationSnapshots
    )
  }

  private static func normalizedSyntaxMutationRanges(_ ranges: [NSRange]) -> [NSRange] {
    ranges.filter {
      $0.location != NSNotFound && $0.location >= 0 && $0.length > 0
    }.sorted {
      $0.location == $1.location
        ? $0.length < $1.length
        : $0.location < $1.location
    }.reduce(into: []) { result, range in
      guard let last = result.last else {
        result.append(range)
        return
      }
      if range.location <= NSMaxRange(last) {
        result[result.count - 1] = NSUnionRange(last, range)
      } else {
        result.append(range)
      }
    }
  }

  private func cancelPendingSyntaxAttributeApplication() {
    syntaxAttributeApplicationTask?.cancel()
    syntaxAttributeApplicationTask = nil
    syntaxAttributeApplicationGeneration &+= 1
  }

  private func scheduleInlineAttachmentDrawingApplication(
    in textView: NSTextView,
    applicationRange: NSRange,
    preservingExisting: Bool,
    documentRevision: UInt64
  ) {
    if preservingExisting, inlineAttachmentDrawingApplicationTask != nil {
      return
    }
    cancelPendingInlineAttachmentDrawingApplication()
    let generation = inlineAttachmentDrawingApplicationGeneration
    inlineAttachmentDrawingApplicationTask = Task { @MainActor [weak self, weak textView] in
      await MainRunLoopUpdateDeferral.waitForNextDefaultModeCycle()
      guard let self else { return }
      defer {
        if self.inlineAttachmentDrawingApplicationGeneration == generation {
          self.inlineAttachmentDrawingApplicationTask = nil
        }
      }
      guard let textView, !Task.isCancelled,
        self.inlineAttachmentDrawingApplicationGeneration == generation,
        self.syntaxDocumentRevision == documentRevision
      else {
        return
      }
      let currentVisibleRange =
        MarkdownTextKit2RangeAdapter.visibleRange(in: textView)
        ?? applicationRange
      let inlineAttachmentID = self.syntaxHighlightSignposter.makeSignpostID()
      let inlineAttachmentInterval = self.syntaxHighlightSignposter.beginInterval(
        "ApplyInlineAttachmentDrawings",
        id: inlineAttachmentID
      )
      self.applyInlineAttachmentDrawings(
        in: textView,
        applicationRange: currentVisibleRange,
        preservingExisting: preservingExisting
      )
      self.syntaxHighlightSignposter.endInterval(
        "ApplyInlineAttachmentDrawings",
        inlineAttachmentInterval
      )
    }
  }

  private func cancelPendingInlineAttachmentDrawingApplication() {
    inlineAttachmentDrawingApplicationTask?.cancel()
    inlineAttachmentDrawingApplicationTask = nil
    inlineAttachmentDrawingApplicationGeneration &+= 1
  }

  private func restoreCollapsedSyntaxMarkerLayout(in textView: NSTextView) {
    let ranges = collapsedSyntaxMarkerRanges
    collapsedSyntaxMarkerRanges.removeAll(keepingCapacity: true)
    guard let textStorage = textView.textStorage else { return }
    textStorage.beginEditing()
    for range in ranges where NSMaxRange(range) <= textStorage.length {
      textStorage.addAttribute(
        .font,
        value: syntaxHighlightPalette.baseFont,
        range: range
      )
    }
    textStorage.endEditing()
  }

  private func restoreCollapsedSyntaxMarkerLayout(
    in textView: NSTextView,
    intersecting ranges: [NSRange]
  ) {
    guard !ranges.isEmpty, let textStorage = textView.textStorage else { return }
    textStorage.beginEditing()
    for collapsedRange in collapsedSyntaxMarkerRanges {
      for range in ranges {
        let intersection = NSIntersectionRange(collapsedRange, range)
        guard intersection.length > 0, NSMaxRange(intersection) <= textStorage.length else {
          continue
        }
        textStorage.addAttribute(
          .font,
          value: syntaxHighlightPalette.baseFont,
          range: intersection
        )
      }
    }
    textStorage.endEditing()
  }

  private var syntaxRenderingAttributeKeys: [NSAttributedString.Key] {
    var keys = Set(syntaxHighlightPalette.defaultAttributes.keys)
    for attributes in syntaxHighlightPalette.styleAttributes.values {
      keys.formUnion(attributes.keys)
    }
    keys.formUnion(syntaxHighlightPalette.inactiveMarkerAttributes.keys)
    return Array(keys)
  }

  private static func contains(_ inner: NSRange, in outer: NSRange) -> Bool {
    inner.location != NSNotFound
      && outer.location != NSNotFound
      && inner.location >= outer.location
      && NSMaxRange(inner) <= NSMaxRange(outer)
  }

  private static func syntaxEditRange(_ editRange: NSRange, touches range: NSRange) -> Bool {
    if editRange.length == 0 {
      return editRange.location >= range.location && editRange.location <= NSMaxRange(range)
    }
    return NSIntersectionRange(editRange, range).length > 0
  }

  @discardableResult
  func updateCurrentParagraphHighlight(
    in textView: NSTextView,
    force: Bool = false,
    invalidatedRanges: [NSRange] = []
  ) -> Bool {
    guard textView.textLayoutManager != nil else { return false }
    let paragraphRange = MarkdownEditorOverlayService.currentParagraphRange(
      in: textView.string,
      selectedRange: textView.selectedRange(),
      isEnabled: comfortConfiguration.currentParagraphHighlightEnabled
    )
    let wasInvalidated =
      paragraphRange.map { paragraphRange in
        invalidatedRanges.contains {
          NSIntersectionRange($0, paragraphRange).length > 0
        }
      } ?? false
    guard force || paragraphRange != appliedParagraphHighlightRange || wasInvalidated else {
      return false
    }

    let paragraphRect = paragraphRange.flatMap {
      MarkdownTextKit2RangeAdapter.rect(for: $0, in: textView)
    }
    if let droppableTextView = textView as? DroppableMarkdownTextView {
      droppableTextView.markdownParagraphHighlightRect = paragraphRect
    }
    appliedParagraphHighlightRange = paragraphRange
    return true
  }

  @discardableResult
  func updateDiagnosticOverlays(
    in textView: NSTextView,
    applicationRange: NSRange? = nil,
    force: Bool = false,
    invalidatedRanges: [NSRange] = []
  ) -> MarkdownDiagnosticOverlayUpdateMetrics {
    guard textView.textLayoutManager != nil else { return .unchanged }
    let length = (textView.string as NSString).length
    let viewportRange =
      applicationRange
      ?? diagnosticOverlayViewportRange(
        in: textView
      )
    let overlays = visibleDiagnosticOverlays(
      in: textView,
      applicationRange: viewportRange
    )
    let previousSet = Set(appliedDiagnosticOverlays)
    let desiredSet = Set(overlays)
    let overlaysToRemove =
      force
      ? appliedDiagnosticOverlays
      : appliedDiagnosticOverlays.filter { !desiredSet.contains($0) }
    var overlaysToApply =
      force
      ? overlays
      : overlays.filter { !previousSet.contains($0) }
    if !force, !invalidatedRanges.isEmpty {
      overlaysToApply.append(
        contentsOf: overlays.filter { overlay in
          previousSet.contains(overlay)
            && invalidatedRanges.contains {
              NSIntersectionRange($0, overlay.range).length > 0
            }
        })
    }
    guard
      !overlaysToRemove.isEmpty || !overlaysToApply.isEmpty
        || overlays != appliedDiagnosticOverlays
    else { return .unchanged }

    for overlay in overlaysToRemove {
      guard
        let removableRange = MarkdownEditorOverlayService.clampedNonEmptyRange(
          overlay.range,
          length: length
        )
      else { continue }
      MarkdownTextKit2RangeAdapter.removeRenderingAttribute(
        .underlineStyle,
        for: removableRange,
        in: textView
      )
      MarkdownTextKit2RangeAdapter.removeRenderingAttribute(
        .underlineColor,
        for: removableRange,
        in: textView
      )
    }

    let underlineStyle = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
    for overlay in overlaysToApply {
      let color: NSColor = overlay.severity == .error ? .systemRed : .systemOrange
      MarkdownTextKit2RangeAdapter.addRenderingAttributes(
        [
          .underlineStyle: underlineStyle,
          .underlineColor: color,
        ],
        for: overlay.range,
        in: textView
      )
    }
    appliedDiagnosticOverlays = overlays
    return MarkdownDiagnosticOverlayUpdateMetrics(
      removedCount: overlaysToRemove.count,
      appliedCount: overlaysToApply.count
    )
  }

  private func diagnosticOverlayViewportRange(
    in textView: NSTextView
  ) -> NSRange {
    guard let visibleRange = MarkdownTextKit2RangeAdapter.visibleRange(in: textView) else {
      return paintedSyntaxViewportRange
        ?? NSRange(location: 0, length: 0)
    }
    return MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: textView.string,
      visibleRange: visibleRange
    )
  }

  private func visibleDiagnosticOverlays(
    in textView: NSTextView,
    applicationRange: NSRange
  ) -> [MarkdownEditorDiagnosticOverlay] {
    let documentOverlays = cachedDiagnosticOverlays(in: textView)
    guard !documentOverlays.isEmpty, applicationRange.length > 0 else { return [] }
    return documentOverlays.compactMap { overlay in
      let intersection = NSIntersectionRange(overlay.range, applicationRange)
      guard intersection.length > 0 else { return nil }
      return MarkdownEditorDiagnosticOverlay(
        range: intersection,
        severity: overlay.severity
      )
    }
  }

  private func cachedDiagnosticOverlays(
    in textView: NSTextView
  ) -> [MarkdownEditorDiagnosticOverlay] {
    let documentLength = (textView.string as NSString).length
    if cachedDiagnosticOverlayRevision == syntaxDocumentRevision,
      cachedDiagnosticOverlayBodyUTF16Offset == bodyUTF16Offset,
      cachedDiagnosticOverlayDocumentLength == documentLength
    {
      return cachedDocumentDiagnosticOverlays
    }
    let documentDiagnostics = diagnostics.map { diagnostic in
      var updated = diagnostic
      updated.range.location += bodyUTF16Offset
      return updated
    }
    let overlays = MarkdownEditorOverlayService.diagnosticOverlays(
      in: textView.string,
      diagnostics: documentDiagnostics
    ).sorted { lhs, rhs in
      if lhs.range.location == rhs.range.location {
        return lhs.range.length < rhs.range.length
      }
      return lhs.range.location < rhs.range.location
    }
    cachedDocumentDiagnosticOverlays = overlays
    cachedDiagnosticOverlayRevision = syntaxDocumentRevision
    cachedDiagnosticOverlayBodyUTF16Offset = bodyUTF16Offset
    cachedDiagnosticOverlayDocumentLength = documentLength
    return overlays
  }

  func updateStatistics(afterEditing updatedText: String, edit: MarkdownTextEdit?) {
    guard let edit,
      edit.replacedRange.location >= bodyUTF16Offset,
      let previousStatisticsText = statisticsText
    else {
      scheduleFullStatistics(for: updatedText)
      return
    }

    let previousDocument = edit.previousText as NSString
    guard bodyUTF16Offset <= previousDocument.length else {
      scheduleFullStatistics(for: updatedText)
      return
    }
    let previousBody = previousDocument.substring(from: bodyUTF16Offset)
    guard previousStatisticsText == previousBody else {
      scheduleFullStatistics(for: updatedText)
      return
    }

    let bodyReplacedRange = NSRange(
      location: edit.replacedRange.location - bodyUTF16Offset,
      length: edit.replacedRange.length
    )
    let previousBodyLength = (previousBody as NSString).length
    let updatedBodyLength = (updatedText as NSString).length
    let insertedLength = max(
      0,
      updatedBodyLength - previousBodyLength + bodyReplacedRange.length
    )
    let isSmallRelativeEdit =
      previousBodyLength <= Self.incrementalStatisticsMaximumEditLength
      || (bodyReplacedRange.length * 4 <= previousBodyLength
        && insertedLength * 4 <= max(updatedBodyLength, 1))
    // Local word statistics are safe and cheap for ordinary typing.  Large
    // replacements (paste, replace-all, or a stale range) deliberately use
    // the full scanner so a broad edit cannot accumulate drift.
    guard bodyReplacedRange.location >= 0,
      NSMaxRange(bodyReplacedRange) <= previousBodyLength,
      insertedLength <= Self.incrementalStatisticsMaximumEditLength,
      bodyReplacedRange.length <= Self.incrementalStatisticsMaximumEditLength,
      isSmallRelativeEdit
    else {
      scheduleFullStatistics(for: updatedText)
      return
    }

    let insertedRange = NSRange(
      location: bodyReplacedRange.location, length: insertedLength)
    statistics = statistics.applying(
      replacing: bodyReplacedRange,
      in: previousStatisticsText,
      with: insertedRange,
      in: updatedText
    )
    statisticsText = updatedText
    statisticsIncrementalUpdateCount += 1
    scheduleStatisticsDelivery()
  }

  private static let incrementalStatisticsMaximumEditLength = 4_096

  private func scheduleStatisticsDelivery() {
    statisticsTask?.cancel()
    statisticsGeneration += 1
    let generation = statisticsGeneration
    let delay = statisticsDelay
    statisticsTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self, self.statisticsGeneration == generation else { return }
      self.statisticsTask = nil
      let signpostState = self.syntaxHighlightSignposter.beginInterval("DeliverEditorStatistics")
      defer {
        self.syntaxHighlightSignposter.endInterval(
          "DeliverEditorStatistics",
          signpostState
        )
      }
      self.onStatisticsChanged(self.statistics)
    }
  }

  private static func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }
}
