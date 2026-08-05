import AppKit
import Foundation
import OSLog
import PublishingWorkbenchCore

extension MacMarkdownTextView.Coordinator {
  func invalidateHighlightedTextCache() {
    highlightedTextCache = nil
    pendingSyntaxHighlightPlan = nil
    syntaxCodeBlockRanges = nil
    syntaxHighlightDebouncer.cancel()
    cancelPendingSyntaxAttributeApplication()
  }

  func scheduleFullStatistics(for text: String) {
    statisticsTask?.cancel()
    statisticsGeneration += 1
    let generation = statisticsGeneration
    let delay = statisticsDelay
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
    plan: MarkdownSyntaxHighlightPlan? = nil
  ) {
    cancelPendingSyntaxAttributeApplication()
    guard highlightedTextCache != text else { return }

    self.textView = textView
    let requestedPlan = plan ?? .fullDocument(for: text)
    pendingSyntaxHighlightPlan = requestedPlan
    syntaxCodeBlockRanges = requestedPlan.codeBlockRanges
    let syntaxHighlightParser = self.syntaxHighlightParser
    let bodyUTF16Offset = self.bodyUTF16Offset
    let delay = MarkdownSyntaxHighlightSchedulingPolicy.delay(
      for: requestedPlan,
      documentUTF16Length: (text as NSString).length
    )
    let priorityRange = visibleSyntaxHighlightRange(
      in: textView,
      snapshotRange: requestedPlan.range
    ) ?? selectionSyntaxHighlightRange(
      in: text,
      selectedRange: textView.selectedRange(),
      snapshotRange: requestedPlan.range
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
            range: resolvedPlan.range
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
        let applicationSnapshots =
          MarkdownSyntaxHighlightApplicationPlanner
          .applicationSnapshots(
            for: snapshot,
            prioritizing: priorityRange
          )
        return MarkdownSyntaxHighlightComputation(
          text: text,
          plan: resolvedPlan,
          snapshot: snapshot,
          applicationSnapshots: applicationSnapshots
        )
      },
      onValue: { [weak self] computation in
        self?.applyMarkdownSyntaxHighlighting(
          text: computation.text,
          plan: computation.plan,
          snapshot: computation.snapshot,
          applicationSnapshots: computation.applicationSnapshots
        )
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
    onStatisticsChanged(updatedStatistics)
  }

  func applyMarkdownSyntaxHighlighting(
    text: String,
    plan: MarkdownSyntaxHighlightPlan,
    snapshot: MarkdownSyntaxHighlightSnapshot,
    applicationSnapshots: [MarkdownSyntaxHighlightSnapshot]
  ) {
    guard highlightedTextCache != text else { return }
    guard let textView else { return }
    guard textView.string == text else { return }
    guard snapshot.range == plan.range else { return }

    let currentPriorityRange = visibleSyntaxHighlightRange(
      in: textView,
      snapshotRange: snapshot.range
    )
    let prioritizedApplicationSnapshots =
      MarkdownSyntaxHighlightApplicationPlanner
      .prioritizing(
        applicationSnapshots,
        around: currentPriorityRange
      )
    cancelPendingSyntaxAttributeApplication()
    syntaxAttributeApplicationGeneration &+= 1
    let generation = syntaxAttributeApplicationGeneration
    syntaxAttributeApplicationTask = Task { @MainActor [weak self] in
      await self?.applyMarkdownSyntaxHighlighting(
        text: text,
        plan: plan,
        snapshot: snapshot,
        applicationSnapshots: prioritizedApplicationSnapshots,
        generation: generation
      )
    }
  }

  private func applyMarkdownSyntaxHighlighting(
    text: String,
    plan: MarkdownSyntaxHighlightPlan,
    snapshot: MarkdownSyntaxHighlightSnapshot,
    applicationSnapshots: [MarkdownSyntaxHighlightSnapshot],
    generation: UInt64
  ) async {
    guard syntaxAttributeApplicationGeneration == generation,
      !Task.isCancelled,
      let textView,
      textView.string == text
    else {
      return
    }

    let selectedRange = textView.selectedRange()
    guard let textStorage = textView.textStorage else { return }
    let signpostID = syntaxHighlightSignposter.makeSignpostID()
    let intervalState = syntaxHighlightSignposter.beginInterval(
      "ApplyAttributes",
      id: signpostID,
      "rangeLength: \(snapshot.range.length, privacy: .public), runCount: \(snapshot.runs.count, privacy: .public), chunkCount: \(applicationSnapshots.count, privacy: .public)"
    )
    var appliedChunkCount = 0
    defer {
      syntaxHighlightSignposter.endInterval(
        "ApplyAttributes",
        intervalState,
        "textStorageLength: \(textStorage.length, privacy: .public), completedChunks: \(appliedChunkCount, privacy: .public)"
      )
    }

    let expectedTextStorageLength = (text as NSString).length
    for (index, applicationSnapshot) in applicationSnapshots.enumerated() {
      guard syntaxAttributeApplicationGeneration == generation,
        !Task.isCancelled,
        textView.string == text,
        textStorage.length == expectedTextStorageLength
      else {
        return
      }
      textStorage.beginEditing()
      MarkdownSyntaxHighlightAttributeApplier.apply(
        applicationSnapshot,
        to: textStorage,
        defaultAttributes: syntaxHighlightPalette.defaultAttributes,
        styleAttributes: syntaxHighlightPalette.styleAttributes
      )
      textStorage.endEditing()
      appliedChunkCount += 1
      if index < applicationSnapshots.count - 1 {
        await Task.yield()
      }
    }

    guard syntaxAttributeApplicationGeneration == generation,
      !Task.isCancelled,
      textView.string == text
    else {
      return
    }
    if !hasLoggedSyntaxTelemetryActivation {
      syntaxHighlightLogger.info(
        "Syntax telemetry active: documentLength=\(textStorage.length, privacy: .public), rangeLength=\(snapshot.range.length, privacy: .public), runCount=\(snapshot.runs.count, privacy: .public), chunkCount=\(applicationSnapshots.count, privacy: .public)"
      )
      hasLoggedSyntaxTelemetryActivation = true
    }
    (textView.enclosingScrollView as? MarkdownEditorScrollView)?.invalidateDocumentHeight()
    textView.setSelectedRange(Self.clamped(selectedRange, length: (text as NSString).length))
    refreshCachedTypingAttributes(in: textView)
    updateCurrentParagraphHighlight(in: textView, force: true)
    updateDiagnosticOverlays(in: textView, force: true)
    highlightedTextCache = text
    syntaxCodeBlockRanges = plan.codeBlockRanges
    pendingSyntaxHighlightPlan = nil
    syntaxAttributeApplicationTask = nil
  }

  private func cancelPendingSyntaxAttributeApplication() {
    syntaxAttributeApplicationTask?.cancel()
    syntaxAttributeApplicationTask = nil
    syntaxAttributeApplicationGeneration &+= 1
  }

  private func visibleSyntaxHighlightRange(
    in textView: NSTextView,
    snapshotRange: NSRange
  ) -> NSRange? {
    guard let layoutManager = textView.layoutManager,
      let textContainer = textView.textContainer
    else {
      return nil
    }
    let inset = textView.textContainerInset
    let textContainerVisibleRect = textView.visibleRect.offsetBy(
      dx: -inset.width,
      dy: -inset.height
    )
    let glyphRange = layoutManager.glyphRange(
      forBoundingRect: textContainerVisibleRect,
      in: textContainer
    )
    let characterRange = layoutManager.characterRange(
      forGlyphRange: glyphRange,
      actualGlyphRange: nil
    )
    let paddedRange = MarkdownSyntaxHighlightRangeService.paddedLineRange(
      in: textView.string,
      visibleRange: characterRange
    )
    let intersection = NSIntersectionRange(snapshotRange, paddedRange)
    return intersection.length > 0 ? intersection : nil
  }

  private func selectionSyntaxHighlightRange(
    in text: String,
    selectedRange: NSRange,
    snapshotRange: NSRange
  ) -> NSRange? {
    let source = text as NSString
    let selection = Self.clamped(selectedRange, length: source.length)
    let lineRange = source.lineRange(for: selection)
    let intersection = NSIntersectionRange(snapshotRange, lineRange)
    return intersection.length > 0 ? intersection : nil
  }

  func updateCurrentParagraphHighlight(
    in textView: NSTextView,
    force: Bool = false
  ) {
    guard let layoutManager = textView.layoutManager else { return }
    let length = (textView.string as NSString).length
    let paragraphRange = MarkdownEditorOverlayService.currentParagraphRange(
      in: textView.string,
      selectedRange: textView.selectedRange(),
      isEnabled: comfortConfiguration.currentParagraphHighlightEnabled
    )
    guard force || paragraphRange != appliedParagraphHighlightRange else { return }

    if let appliedParagraphHighlightRange,
      let removableRange = MarkdownEditorOverlayService.clampedNonEmptyRange(
        appliedParagraphHighlightRange,
        length: length
      )
    {
      layoutManager.removeTemporaryAttribute(
        .backgroundColor,
        forCharacterRange: removableRange
      )
    }
    if let paragraphRange {
      layoutManager.addTemporaryAttribute(
        .backgroundColor,
        value: NSColor.controlAccentColor.withAlphaComponent(0.07),
        forCharacterRange: paragraphRange
      )
    }
    appliedParagraphHighlightRange = paragraphRange
  }

  func updateDiagnosticOverlays(
    in textView: NSTextView,
    force: Bool = false
  ) {
    guard let layoutManager = textView.layoutManager else { return }
    let documentDiagnostics = diagnostics.map { diagnostic in
      var updated = diagnostic
      updated.range.location += bodyUTF16Offset
      return updated
    }
    let overlays = MarkdownEditorOverlayService.diagnosticOverlays(
      in: textView.string,
      diagnostics: documentDiagnostics
    )
    guard force || overlays != appliedDiagnosticOverlays else { return }

    let length = (textView.string as NSString).length
    for overlay in appliedDiagnosticOverlays {
      guard
        let removableRange = MarkdownEditorOverlayService.clampedNonEmptyRange(
          overlay.range,
          length: length
        )
      else { continue }
      layoutManager.removeTemporaryAttribute(
        .underlineStyle,
        forCharacterRange: removableRange
      )
      layoutManager.removeTemporaryAttribute(
        .underlineColor,
        forCharacterRange: removableRange
      )
    }

    let underlineStyle = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
    for overlay in overlays {
      let color: NSColor = overlay.severity == .error ? .systemRed : .systemOrange
      layoutManager.addTemporaryAttributes(
        [
          .underlineStyle: underlineStyle,
          .underlineColor: color,
        ],
        forCharacterRange: overlay.range
      )
    }
    appliedDiagnosticOverlays = overlays
  }

  private func updateStatistics(afterEditing updatedText: String) {
    defer { pendingTextEdit = nil }
    guard let pendingTextEdit,
      let previousStatisticsText = statisticsText,
      previousStatisticsText == pendingTextEdit.previousText
    else {
      scheduleFullStatistics(for: updatedText)
      return
    }

    let insertedLength = max(
      0,
      (updatedText as NSString).length - (previousStatisticsText as NSString).length
        + pendingTextEdit.replacedRange.length
    )
    let insertedRange = NSRange(
      location: pendingTextEdit.replacedRange.location, length: insertedLength)
    statistics = statistics.applying(
      replacing: pendingTextEdit.replacedRange,
      in: previousStatisticsText,
      with: insertedRange,
      in: updatedText
    )
    statisticsText = updatedText
    scheduleStatisticsDelivery()
  }

  private func scheduleStatisticsDelivery() {
    statisticsTask?.cancel()
    statisticsGeneration += 1
    let generation = statisticsGeneration
    let delay = statisticsDelay
    statisticsTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let self, self.statisticsGeneration == generation else { return }
      self.statisticsTask = nil
      self.onStatisticsChanged(self.statistics)
    }
  }

  private static func clamped(_ range: NSRange, length: Int) -> NSRange {
    let location = min(max(range.location, 0), length)
    let maxLength = max(0, length - location)
    return NSRange(location: location, length: min(range.length, maxLength))
  }
}
