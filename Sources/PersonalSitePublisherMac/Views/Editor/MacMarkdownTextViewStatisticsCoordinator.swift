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
  var statisticsDocumentContext: MarkdownEditorStatisticsSession.DocumentContext {
    .init(
      documentRevision: syntaxDocumentRevision,
      bodyUTF16Offset: bodyUTF16Offset,
      hasValidDocumentBodyMapping: hasValidDocumentBodyMapping
    )
  }

  func scheduleFullStatistics(for text: String, isInitialLoad: Bool = false) {
    statisticsSession.scheduleFullStatistics(
      for: text, isInitialLoad: isInitialLoad, context: statisticsDocumentContext
    )
  }

  func updateStatistics(
    afterEditing updatedText: String,
    edit: MarkdownTextEdit?,
    previousDocumentRevision: UInt64? = nil
  ) {
    statisticsSession.updateStatistics(
      afterEditing: updatedText,
      edit: edit,
      previousDocumentRevision: previousDocumentRevision,
      context: statisticsDocumentContext
    )
  }

  func waitForPendingStatisticsDelivery() async {
    await statisticsSession.waitForPendingStatisticsDelivery()
  }

  func deliverStatistics(_ statistics: MarkdownEditorStatistics) {
    let signpostState = syntaxHighlightSignposter.beginInterval("DeliverEditorStatistics")
    defer {
      syntaxHighlightSignposter.endInterval("DeliverEditorStatistics", signpostState)
    }
    onStatisticsChanged(statistics)
  }

  // Preserve the observable coordinator surface used by AppKit regression
  // tests; the session remains the single owner of cache and task state.
  var statisticsTask: Task<Void, Never>? {
    get { statisticsSession.statisticsTask }
    set { statisticsSession.statisticsTask = newValue }
  }
  var statisticsGeneration: Int {
    get { statisticsSession.statisticsGeneration }
    set { statisticsSession.statisticsGeneration = newValue }
  }
  var statisticsContextGeneration: Int {
    get { statisticsSession.statisticsContextGeneration }
    set { statisticsSession.statisticsContextGeneration = newValue }
  }
  var statisticsText: String? {
    get { statisticsSession.statisticsText }
    set { statisticsSession.statisticsText = newValue }
  }
  var statisticsDocumentRevision: UInt64? {
    get { statisticsSession.statisticsDocumentRevision }
    set { statisticsSession.statisticsDocumentRevision = newValue }
  }
  var statisticsBodyUTF16Offset: Int? {
    get { statisticsSession.statisticsBodyUTF16Offset }
    set { statisticsSession.statisticsBodyUTF16Offset = newValue }
  }
  var statistics: MarkdownEditorStatistics {
    get { statisticsSession.statistics }
    set { statisticsSession.statistics = newValue }
  }
  var statisticsFullScanCount: Int {
    get { statisticsSession.statisticsFullScanCount }
    set { statisticsSession.statisticsFullScanCount = newValue }
  }
  var statisticsIncrementalUpdateCount: Int {
    get { statisticsSession.statisticsIncrementalUpdateCount }
    set { statisticsSession.statisticsIncrementalUpdateCount = newValue }
  }
  var statisticsRevisionValidatedUpdateCount: Int {
    get { statisticsSession.statisticsRevisionValidatedUpdateCount }
    set { statisticsSession.statisticsRevisionValidatedUpdateCount = newValue }
  }
}
