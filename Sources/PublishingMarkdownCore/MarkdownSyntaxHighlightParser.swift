import Foundation
import OSLog
import SwiftTreeSitter
import SwiftTreeSitterLayer
import TreeSitterMarkdown
import TreeSitterMarkdownInline

public enum MarkdownSyntaxHighlightStyle: String, Hashable, Sendable {
  case heading
  case heading1
  case heading2
  case heading3
  case heading4
  case heading5
  case heading6
  case codeBlock
  case link
  case list
  case quote
  case bold
  case italic
  case inlineCode
  case strikethrough
  case html
}

public struct MarkdownSyntaxHighlightRun: Hashable, Sendable {
  public var style: MarkdownSyntaxHighlightStyle
  public var range: NSRange

  public init(style: MarkdownSyntaxHighlightStyle, range: NSRange) {
    self.style = style
    self.range = range
  }
}

public struct MarkdownSyntaxHighlightSnapshot: Hashable, Sendable {
  public var range: NSRange
  public var runs: [MarkdownSyntaxHighlightRun]

  public init(range: NSRange, runs: [MarkdownSyntaxHighlightRun]) {
    self.range = range
    self.runs = runs
  }
}

public enum MarkdownSyntaxHighlightSnapshotMode: Sendable {
  case synchronized
  case lightweight
}

public struct MarkdownSyntaxHighlightEdit: Hashable, Sendable {
  public var previousText: String
  public var replacedRange: NSRange
  public var previousRevision: UInt64?

  public init(
    previousText: String,
    replacedRange: NSRange,
    previousRevision: UInt64? = nil
  ) {
    self.previousText = previousText
    self.replacedRange = replacedRange
    self.previousRevision = previousRevision
  }
}

/// Collapses any number of sequential edits into one replacement relative to
/// the last parsed source. Only the unchanged prefix and suffix lengths are
/// tracked, so accumulation is independent of document size.
public struct MarkdownSyntaxHighlightEditAccumulator: Hashable, Sendable {
  public private(set) var baseText: String
  public private(set) var baseRevision: UInt64
  public private(set) var currentRevision: UInt64
  public private(set) var replacedRange: NSRange
  public private(set) var replacementRange: NSRange

  public init?(
    previousText: String,
    currentText: String,
    replacedRange: NSRange,
    previousRevision: UInt64,
    currentRevision: UInt64
  ) {
    let previousLength = (previousText as NSString).length
    let currentLength = (currentText as NSString).length
    guard Self.isValid(replacedRange, length: previousLength) else { return nil }
    let insertedLength = currentLength - (previousLength - replacedRange.length)
    guard insertedLength >= 0 else { return nil }
    baseText = previousText
    baseRevision = previousRevision
    self.currentRevision = currentRevision
    self.replacedRange = replacedRange
    replacementRange = NSRange(
      location: replacedRange.location,
      length: insertedLength
    )
  }

  public func accumulating(
    previousText: String,
    currentText: String,
    replacedRange nextRange: NSRange,
    previousRevision: UInt64,
    currentRevision: UInt64
  ) -> Self? {
    let previousLength = (previousText as NSString).length
    let currentLength = (currentText as NSString).length
    guard previousRevision == self.currentRevision,
      previousLength == NSMaxRange(replacementRange)
        + ((baseText as NSString).length - NSMaxRange(replacedRange)),
      Self.isValid(nextRange, length: previousLength)
    else {
      return nil
    }
    let insertedLength = currentLength - (previousLength - nextRange.length)
    guard insertedLength >= 0 else { return nil }

    let baseLength = (baseText as NSString).length
    let unchangedPrefixLength = min(replacedRange.location, nextRange.location)
    let unchangedSuffixLength = min(
      baseLength - NSMaxRange(replacedRange),
      previousLength - NSMaxRange(nextRange)
    )
    var result = self
    result.currentRevision = currentRevision
    result.replacedRange = NSRange(
      location: unchangedPrefixLength,
      length: baseLength - unchangedPrefixLength - unchangedSuffixLength
    )
    result.replacementRange = NSRange(
      location: unchangedPrefixLength,
      length: currentLength - unchangedPrefixLength - unchangedSuffixLength
    )
    return result
  }

  public var parserEdit: MarkdownSyntaxHighlightEdit {
    MarkdownSyntaxHighlightEdit(
      previousText: baseText,
      replacedRange: replacedRange,
      previousRevision: baseRevision
    )
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }
}

public struct MarkdownSyntaxHighlightParserMetrics: Equatable, Sendable {
  public var initialParseCount: Int
  public var incrementalParseCount: Int
  public var fallbackParseCount: Int
  public var editHintParseCount: Int
  public var lightweightSnapshotCount: Int
  public var treeSynchronizationCount: Int
  /// Number of highlight captures returned by the most recent synchronized
  /// Tree-sitter query. A zero value means that the request used the
  /// lightweight/fallback path or produced no captures.
  public var lastTreeSitterCaptureCount: Int
  public var lastChangedRange: NSRange?
  public var lastFallbackReason: String?
  /// The source range that requested the most recent Tree-sitter fallback.
  /// This remains observable even when the fallback returns a valid lexical
  /// snapshot, so callers can distinguish a local fallback from a full one.
  public var lastFallbackRange: NSRange?

  public init(
    initialParseCount: Int = 0,
    incrementalParseCount: Int = 0,
    fallbackParseCount: Int = 0,
    editHintParseCount: Int = 0,
    lightweightSnapshotCount: Int = 0,
    treeSynchronizationCount: Int = 0,
    lastTreeSitterCaptureCount: Int = 0,
    lastChangedRange: NSRange? = nil,
    lastFallbackReason: String? = nil,
    lastFallbackRange: NSRange? = nil
  ) {
    self.initialParseCount = initialParseCount
    self.incrementalParseCount = incrementalParseCount
    self.fallbackParseCount = fallbackParseCount
    self.editHintParseCount = editHintParseCount
    self.lightweightSnapshotCount = lightweightSnapshotCount
    self.treeSynchronizationCount = treeSynchronizationCount
    self.lastTreeSitterCaptureCount = lastTreeSitterCaptureCount
    self.lastChangedRange = lastChangedRange
    self.lastFallbackReason = lastFallbackReason
    self.lastFallbackRange = lastFallbackRange
  }
}

public actor MarkdownSyntaxHighlightParser {
  private let signposter = OSSignposter(
    subsystem: "com.jinfang.PersonalSitePublisherMac",
    category: "MarkdownSyntax"
  )
  private var treeSitterEngine: MarkdownTreeSitterEngine?
  private var treeSitterInitializationFailed = false
  private var parserMetrics = MarkdownSyntaxHighlightParserMetrics()

  public init() {}

  /// Internal seam used by core tests to exercise the lexical fallback path
  /// deterministically without depending on a missing packaged query bundle.
  init(disablingTreeSitterForTesting: Bool) {
    treeSitterInitializationFailed = disablingTreeSitterForTesting
  }

  public func metrics() -> MarkdownSyntaxHighlightParserMetrics {
    parserMetrics
  }

  public func snapshot(
    in markdown: String,
    range requestedRange: NSRange? = nil,
    revision: UInt64? = nil,
    edit: MarkdownSyntaxHighlightEdit? = nil,
    mode: MarkdownSyntaxHighlightSnapshotMode = .synchronized,
    knownCodeBlockRanges: [NSRange]? = nil
  ) -> MarkdownSyntaxHighlightSnapshot? {
    guard !Task.isCancelled else { return nil }
    let source = markdown as NSString
    let range = requestedRange ?? NSRange(location: 0, length: source.length)
    guard Self.isValid(range, length: source.length) else { return nil }

    let signpostID = signposter.makeSignpostID()
    let intervalState = signposter.beginInterval(
      "SyntaxParse",
      id: signpostID,
      "documentLength: \(source.length, privacy: .public), rangeLength: \(range.length, privacy: .public)"
    )
    var completionState = 0
    var emittedRunCount = 0
    defer {
      signposter.endInterval(
        "SyntaxParse",
        intervalState,
        "completed: \(completionState, privacy: .public), runCount: \(emittedRunCount, privacy: .public)"
      )
    }

    let treeSitterHighlights: [NamedRange]
    switch mode {
    case .synchronized:
      treeSitterHighlights = self.treeSitterHighlights(
        in: markdown,
        source: source,
        range: range,
        revision: revision,
        edit: edit
      )
    case .lightweight:
      parserMetrics.lightweightSnapshotCount += 1
      parserMetrics.lastTreeSitterCaptureCount = 0
      treeSitterHighlights = []
    }
    let scannedCodeRanges = MarkdownCodeRangeScanner.scan(source, in: range)
    let knownCodeBlockRanges = knownCodeBlockRanges?.compactMap { codeRange in
      let intersection = NSIntersectionRange(codeRange, range)
      return intersection.length > 0 ? intersection : nil
    }
    let codeBlockRanges =
      knownCodeBlockRanges
      ?? scannedCodeRanges.blockRanges
    // The vendored highlight query intentionally omits fenced content and
    // does not expose every CommonMark fence/indent boundary as one capture.
    // Keep the dedicated range scanner as the source of truth for literal
    // exclusion while Tree-sitter drives the covered semantic styles.
    let candidateInlineCodeRanges = scannedCodeRanges.inlineRanges
    let inlineCodeRanges = Self.excludingOverlaps(
      from: candidateInlineCodeRanges,
      excludedBy: codeBlockRanges
    )
    guard !Task.isCancelled else { return nil }

    let captureRuns = Self.captureRuns(
      from: treeSitterHighlights,
      source: source,
      requestedRange: range
    )

    let literalRanges = MarkdownCodeRangeScanResult(
      blockRanges: codeBlockRanges,
      inlineRanges: inlineCodeRanges
    ).allRanges
    let lexicalStyles = Self.lexicalFallbackStyles(
      mode: mode,
      treeSitterHighlights: treeSitterHighlights,
      captureRuns: captureRuns,
      source: source,
      requestedRange: range,
      literalRanges: literalRanges
    )
    guard
      let lexicalRuns = MarkdownSyntaxLightweightLexer.scan(
        source,
        in: range,
        blockRanges: codeBlockRanges,
        literalRanges: literalRanges,
        styles: lexicalStyles
      )
    else {
      return nil
    }

    var runs: [MarkdownSyntaxHighlightRun] = []
    let lexicalHeadingRuns = [
      (.heading1, lexicalRuns.heading1),
      (.heading2, lexicalRuns.heading2),
      (.heading3, lexicalRuns.heading3),
      (.heading4, lexicalRuns.heading4),
      (.heading5, lexicalRuns.heading5),
      (.heading6, lexicalRuns.heading6),
    ].flatMap { style, ranges in
      ranges.map { MarkdownSyntaxHighlightRun(style: style, range: $0) }
    }.sorted { $0.range.location < $1.range.location }
    let headingRuns =
      captureRuns.headings.isEmpty
      ? lexicalHeadingRuns
      : captureRuns.headings
    let sortedHeadingRuns = headingRuns.sorted {
      $0.range.location < $1.range.location
    }
    runs.append(contentsOf: sortedHeadingRuns)
    append(codeBlockRanges, style: .codeBlock, offset: 0, to: &runs)
    append(lexicalRuns.html, style: .html, offset: 0, to: &runs)
    let linkRanges = captureRuns.links.isEmpty ? lexicalRuns.links : captureRuns.links
    append(
      linkRanges,
      style: .link,
      offset: 0,
      to: &runs
    )
    let listRanges = captureRuns.lists.isEmpty ? lexicalRuns.lists : captureRuns.lists
    append(
      listRanges,
      style: .list,
      offset: 0,
      to: &runs
    )
    let quoteRanges = captureRuns.quotes.isEmpty ? lexicalRuns.quotes : captureRuns.quotes
    append(
      quoteRanges,
      style: .quote,
      offset: 0,
      to: &runs
    )
    let boldRanges =
      lexicalStyles.contains(.bold)
      ? lexicalRuns.bold
      : captureRuns.bold
    append(
      boldRanges,
      style: .bold,
      offset: 0,
      to: &runs
    )
    let italicRanges =
      lexicalStyles.contains(.italic)
      ? lexicalRuns.italic
      : captureRuns.italic
    append(
      italicRanges,
      style: .italic,
      offset: 0,
      to: &runs
    )
    append(
      inlineCodeRanges,
      style: .inlineCode,
      offset: 0,
      to: &runs
    )
    append(lexicalRuns.strikethrough, style: .strikethrough, offset: 0, to: &runs)
    guard !Task.isCancelled else { return nil }
    completionState = 1
    emittedRunCount = runs.count
    return MarkdownSyntaxHighlightSnapshot(range: range, runs: runs)
  }

  @discardableResult
  public func synchronizeTree(
    in markdown: String,
    revision: UInt64? = nil,
    edit: MarkdownSyntaxHighlightEdit? = nil
  ) -> Bool {
    guard !Task.isCancelled else { return false }
    let documentRange = NSRange(location: 0, length: (markdown as NSString).length)
    guard !treeSitterInitializationFailed else {
      recordFallback(
        reason: Self.treeSitterUnavailableFallbackReason,
        range: documentRange
      )
      return false
    }
    do {
      let engine: MarkdownTreeSitterEngine
      if let treeSitterEngine {
        engine = treeSitterEngine
      } else {
        engine = try MarkdownTreeSitterEngine()
        treeSitterEngine = engine
      }
      try engine.synchronize(
        in: markdown,
        source: markdown as NSString,
        revision: revision,
        edit: edit
      )
      updateMetrics(from: engine)
      parserMetrics.treeSynchronizationCount += 1
      return true
    } catch {
      recordFallback(
        reason: "\(Self.treeSitterErrorFallbackReason): \(error)",
        range: documentRange
      )
      if treeSitterEngine == nil {
        treeSitterInitializationFailed = true
      }
      return false
    }
  }

  private func treeSitterHighlights(
    in markdown: String,
    source: NSString,
    range: NSRange,
    revision: UInt64?,
    edit: MarkdownSyntaxHighlightEdit?
  ) -> [NamedRange] {
    guard !treeSitterInitializationFailed else {
      recordFallback(
        reason: Self.treeSitterUnavailableFallbackReason,
        range: range
      )
      return []
    }
    do {
      let engine: MarkdownTreeSitterEngine
      if let treeSitterEngine {
        engine = treeSitterEngine
      } else {
        engine = try MarkdownTreeSitterEngine()
        treeSitterEngine = engine
      }
      let result = try engine.highlights(
        in: markdown,
        source: source,
        range: range,
        revision: revision,
        edit: edit
      )
      updateMetrics(from: engine)
      parserMetrics.lastTreeSitterCaptureCount = result.count
      // SwiftTreeSitter's `NamedRange.range` already converts the parser's
      // UTF-16 byte offsets to Foundation UTF-16 coordinates. Converting the
      // byte range a second time halves every capture location and length.
      return result
    } catch {
      recordFallback(
        reason: "\(Self.treeSitterErrorFallbackReason): \(error)",
        range: range
      )
      if treeSitterEngine == nil {
        treeSitterInitializationFailed = true
      }
      return []
    }
  }

  private static let treeSitterUnavailableFallbackReason = "tree-sitter-unavailable"
  private static let treeSitterErrorFallbackReason = "tree-sitter-error"

  private func recordFallback(reason: String, range: NSRange) {
    parserMetrics.fallbackParseCount += 1
    parserMetrics.lastFallbackReason = reason
    parserMetrics.lastFallbackRange = range
    parserMetrics.lastTreeSitterCaptureCount = 0
  }

  private func updateMetrics(from engine: MarkdownTreeSitterEngine) {
    parserMetrics.initialParseCount = engine.initialParseCount
    parserMetrics.incrementalParseCount = engine.incrementalParseCount
    parserMetrics.editHintParseCount = engine.editHintParseCount
    parserMetrics.lastChangedRange = engine.lastChangedRange
  }

}
