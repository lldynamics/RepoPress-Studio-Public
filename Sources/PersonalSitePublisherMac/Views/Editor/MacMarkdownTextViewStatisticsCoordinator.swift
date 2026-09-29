import Foundation

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
  func scheduleFullStatistics(for text: String, isInitialLoad: Bool = false) {
    statisticsFullScanCount += 1
    statisticsTask?.cancel()
    statisticsDocumentRevision = nil
    statisticsBodyUTF16Offset = nil
    statisticsGeneration += 1
    let generation = statisticsGeneration
    let documentRevision = syntaxDocumentRevision
    let bodyOffset = bodyUTF16Offset
    let contextGeneration = statisticsContextGeneration
    let delay = MarkdownEditorStatisticsDelayPolicy.fullScanDelay(
      for: text,
      isInitialLoad: isInitialLoad
    )
    let clock = statisticsClock
    statisticsTask = Task.detached(priority: .userInitiated) { [weak self, text] in
      do {
        try await clock.sleep(for: .seconds(delay))
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      let updatedStatistics = MarkdownEditorStatistics.make(for: text)
      await self?.applyFullStatistics(
        updatedStatistics,
        for: text,
        generation: generation,
        documentRevision: documentRevision,
        bodyOffset: bodyOffset,
        contextGeneration: contextGeneration
      )
    }
  }

  func updateStatistics(
    afterEditing updatedText: String,
    edit: MarkdownTextEdit?,
    previousDocumentRevision: UInt64? = nil
  ) {
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
    let hasContinuousDocumentRevision =
      previousDocumentRevision.map {
        statisticsDocumentRevision == $0
          && syntaxDocumentRevision == $0 &+ 1
          && statisticsBodyUTF16Offset == bodyUTF16Offset
          && hasValidDocumentBodyMapping
          && (previousStatisticsText as NSString).length
            == previousDocument.length - bodyUTF16Offset
      } ?? false
    let previousBody: String
    if hasContinuousDocumentRevision {
      // The cache belongs to the immediately preceding document and body
      // mapping. Reuse it without copying or comparing the entire document.
      previousBody = previousStatisticsText
    } else {
      previousBody = previousDocument.substring(from: bodyUTF16Offset)
      // Preserve the prior canonical-equivalence behavior when no continuous
      // edit proof is available (for example inferred IME edits).
      let statisticsTextMatchesPreviousBody =
        previousStatisticsText.compare(previousBody, options: .literal) == .orderedSame
        || previousStatisticsText == previousBody
      guard statisticsTextMatchesPreviousBody else {
        scheduleFullStatistics(for: updatedText)
        return
      }
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
    // Local word statistics are safe and cheap for ordinary typing. Large
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
    // A non-continuous cache can be canonically equivalent while using a
    // different UTF-16 spelling (for example `e + combining acute` versus
    // `é`). Its counts belong to `previousBody`, which was validated above;
    // use that spelling for the bounded delta instead of forcing a scan.
    let incrementalBaseText =
      hasContinuousDocumentRevision ? previousStatisticsText : previousBody
    guard
      let updatedStatistics = statistics.applyingBounded(
        replacing: bodyReplacedRange,
        in: incrementalBaseText,
        with: insertedRange,
        in: updatedText
      )
    else {
      // A bounded failure has no exact delta. Keep the last published value
      // and use the delayed detached scanner; never compute an approximation
      // or resume a document-wide scan on this edit callback.
      // The cached text no longer describes the current body. Clearing it also
      // prevents the next keystroke from comparing or slicing the whole stale
      // document while a newer full scan is pending.
      statisticsText = nil
      scheduleFullStatistics(for: updatedText)
      return
    }
    statistics = updatedStatistics
    statisticsText = updatedText
    let canCertifyCurrentDocument =
      previousDocumentRevision.map { syntaxDocumentRevision == $0 &+ 1 } == true
      && hasValidDocumentBodyMapping
    statisticsDocumentRevision = canCertifyCurrentDocument ? syntaxDocumentRevision : nil
    statisticsBodyUTF16Offset = canCertifyCurrentDocument ? bodyUTF16Offset : nil
    statisticsIncrementalUpdateCount += 1
    if hasContinuousDocumentRevision {
      statisticsRevisionValidatedUpdateCount += 1
    }
    scheduleStatisticsDelivery()
  }

  func waitForPendingStatisticsDelivery() async {
    await statisticsTask?.value
  }

  private static let incrementalStatisticsMaximumEditLength = 4_096

  private func applyFullStatistics(
    _ updatedStatistics: MarkdownEditorStatistics,
    for text: String,
    generation: Int,
    documentRevision: UInt64,
    bodyOffset: Int,
    contextGeneration: Int
  ) {
    guard statisticsGeneration == generation,
      syntaxDocumentRevision == documentRevision,
      bodyUTF16Offset == bodyOffset
    else { return }
    statistics = updatedStatistics
    statisticsText = text
    let matchesCurrentDocument =
      hasValidDocumentBodyMapping && statisticsContextGeneration == contextGeneration
    statisticsDocumentRevision = matchesCurrentDocument ? documentRevision : nil
    statisticsBodyUTF16Offset = matchesCurrentDocument ? bodyOffset : nil
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

  private func scheduleStatisticsDelivery() {
    statisticsTask?.cancel()
    statisticsGeneration += 1
    let generation = statisticsGeneration
    let delay = statisticsDelay
    let clock = statisticsClock
    statisticsTask = Task { [weak self] in
      do {
        try await clock.sleep(for: .seconds(delay))
      } catch {
        return
      }
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
}
