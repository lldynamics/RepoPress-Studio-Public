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
    let codeBlockRanges = knownCodeBlockRanges
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
    let headingRuns = captureRuns.headings.isEmpty
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
    let boldRanges = lexicalStyles.contains(.bold)
      ? lexicalRuns.bold
      : captureRuns.bold
    append(
      boldRanges,
      style: .bold,
      offset: 0,
      to: &runs
    )
    let italicRanges = lexicalStyles.contains(.italic)
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

  private static func captureRuns(
    from highlights: [NamedRange],
    source: NSString,
    requestedRange: NSRange
  ) -> MarkdownSyntaxCaptureRuns {
    var result = MarkdownSyntaxCaptureRuns()
    var referenceCaptures: [NSRange] = []
    var uriCaptures: [NSRange] = []

    for highlight in highlights {
      guard let range = boundedCaptureRange(
        highlight.range,
        source: source,
        requestedRange: requestedRange
      ) else {
        continue
      }

      switch highlight.name {
      case "text.title":
        guard let level = atxHeadingLevel(in: source, at: range.location),
          let lineRange = boundedLineRange(
            in: source,
            at: range.location,
            requestedRange: requestedRange
          )
        else {
          continue
        }
        result.headings.append(
          MarkdownSyntaxHighlightRun(
            style: headingStyle(for: level),
            range: lineRange
          )
        )
      case "text.emphasis":
        result.italic.append(range)
      case "text.strong":
        result.bold.append(range)
      case "text.reference":
        referenceCaptures.append(highlight.range)
      case "text.uri":
        uriCaptures.append(highlight.range)
      case "punctuation.special":
        guard let lineRange = boundedLineRange(
          in: source,
          at: range.location,
          requestedRange: requestedRange
        ) else {
          continue
        }
        if isListLine(in: source, lineRange: lineRange) {
          result.lists.append(lineRange)
        } else if isQuoteLine(in: source, lineRange: lineRange) {
          result.quotes.append(lineRange)
        }
      default:
        continue
      }
    }

    result.links = captureLinkRanges(
      referenceCaptures: referenceCaptures,
      uriCaptures: uriCaptures,
      source: source,
      requestedRange: requestedRange
    )
    result.headings = normalizedRuns(result.headings)
    result.links = normalizedRanges(result.links)
    result.lists = normalizedRanges(result.lists)
    result.quotes = normalizedRanges(result.quotes)
    result.bold = normalizedRanges(result.bold)
    result.italic = normalizedRanges(result.italic)
    return result
  }

  private static func lexicalFallbackStyles(
    mode: MarkdownSyntaxHighlightSnapshotMode,
    treeSitterHighlights: [NamedRange],
    captureRuns: MarkdownSyntaxCaptureRuns,
    source: NSString,
    requestedRange: NSRange,
    literalRanges: [NSRange]
  ) -> MarkdownSyntaxLexicalStyles {
    guard case .synchronized = mode, !treeSitterHighlights.isEmpty else {
      return .all
    }

    var styles: MarkdownSyntaxLexicalStyles = [.html, .strikethrough]
    if captureRuns.headings.isEmpty
      || hasUncapturedLineStyle(
        in: source,
        requestedRange: requestedRange,
        capturedRanges: captureRuns.headings.map(\.range),
        predicate: { atxHeadingLevel(in: $0, at: $1.location) != nil }
      )
    {
      styles.insert(.headings)
    }
    if captureRuns.links.isEmpty
      || hasUncapturedInlineLink(
        in: source,
        requestedRange: requestedRange,
        capturedRanges: captureRuns.links,
        literalRanges: literalRanges
      )
    {
      styles.insert(.links)
    }
    if captureRuns.lists.isEmpty
      || hasUncapturedLineStyle(
        in: source,
        requestedRange: requestedRange,
        capturedRanges: captureRuns.lists,
        predicate: isListLine
      )
    {
      styles.insert(.lists)
    }
    if captureRuns.quotes.isEmpty
      || hasUncapturedLineStyle(
        in: source,
        requestedRange: requestedRange,
        capturedRanges: captureRuns.quotes,
        predicate: isQuoteLine
      )
    {
      styles.insert(.quotes)
    }
    if captureRuns.bold.isEmpty { styles.insert(.bold) }
    if captureRuns.italic.isEmpty { styles.insert(.italic) }
    if containsUnresolvedTripleAsterisk(
      in: source,
      requestedRange: requestedRange,
      literalRanges: literalRanges
    ) {
      styles.insert([.bold, .italic])
    }
    return styles
  }

  private static func hasUncapturedLineStyle(
    in source: NSString,
    requestedRange: NSRange,
    capturedRanges: [NSRange],
    predicate: (NSString, NSRange) -> Bool
  ) -> Bool {
    var location = requestedRange.location
    let upperBound = NSMaxRange(requestedRange)
    while location < upperBound {
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      source.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0)
      )
      let fullLine = NSRange(
        location: lineStart,
        length: max(0, contentsEnd - lineStart)
      )
      let candidate = NSIntersectionRange(fullLine, requestedRange)
      if candidate.length > 0,
        predicate(source, fullLine),
        !capturedRanges.contains(where: {
          NSIntersectionRange($0, candidate).length > 0
        })
      {
        return true
      }
      location = max(lineEnd, location + 1)
    }
    return false
  }

  private static func hasUncapturedInlineLink(
    in source: NSString,
    requestedRange: NSRange,
    capturedRanges: [NSRange],
    literalRanges: [NSRange]
  ) -> Bool {
    let expandedRange = source.lineRange(for: requestedRange)
    var cursor = expandedRange.location
    let upperBound = min(NSMaxRange(expandedRange), source.length)
    while cursor < upperBound {
      guard source.character(at: cursor) == 91,
        !isEscaped(source, at: cursor),
        let closing = closingBracket(after: cursor + 1, source: source)
      else {
        cursor += 1
        continue
      }
      let destinationStart = closing + 1
      guard destinationStart < upperBound,
        source.character(at: destinationStart) == 40,
        let ending = closingParenthesis(after: destinationStart + 1, source: source)
      else {
        cursor = closing + 1
        continue
      }
      let candidate = NSRange(
        location: cursor,
        length: ending + 1 - cursor
      )
      let requestedCandidate = NSIntersectionRange(candidate, requestedRange)
      if requestedCandidate.length > 0,
        !literalRanges.contains(where: {
          NSIntersectionRange($0, requestedCandidate).length > 0
        }),
        !capturedRanges.contains(where: {
          NSIntersectionRange($0, requestedCandidate).length > 0
        })
      {
        return true
      }
      cursor = ending + 1
    }
    return false
  }

  private static func containsUnresolvedTripleAsterisk(
    in source: NSString,
    requestedRange: NSRange,
    literalRanges: [NSRange]
  ) -> Bool {
    var searchStart = requestedRange.location
    let upperBound = NSMaxRange(requestedRange)
    while searchStart < upperBound {
      let remaining = NSRange(location: searchStart, length: upperBound - searchStart)
      let marker = source.range(of: "***", options: [], range: remaining)
      guard marker.location != NSNotFound else { return false }
      if !literalRanges.contains(where: { NSIntersectionRange($0, marker).length > 0 }) {
        return true
      }
      searchStart = NSMaxRange(marker)
    }
    return false
  }

  private static func boundedCaptureRange(
    _ captureRange: NSRange,
    source: NSString,
    requestedRange: NSRange
  ) -> NSRange? {
    guard isValid(captureRange, length: source.length) else { return nil }
    let intersection = NSIntersectionRange(captureRange, requestedRange)
    return intersection.length > 0 ? intersection : nil
  }

  private static func boundedLineRange(
    in source: NSString,
    at location: Int,
    requestedRange: NSRange
  ) -> NSRange? {
    guard location >= 0, location <= source.length else { return nil }
    var lineStart = 0
    var lineEnd = 0
    var contentsEnd = 0
    source.getLineStart(
      &lineStart,
      end: &lineEnd,
      contentsEnd: &contentsEnd,
      for: NSRange(location: min(location, source.length), length: 0)
    )
    let lineRange = NSRange(
      location: lineStart,
      length: max(0, contentsEnd - lineStart)
    )
    let intersection = NSIntersectionRange(lineRange, requestedRange)
    return intersection.length > 0 ? intersection : nil
  }

  private static func atxHeadingLevel(in source: NSString, at location: Int) -> Int? {
    guard location >= 0, location < source.length else { return nil }
    let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    var count = 0
    while cursor < end, source.character(at: cursor) == 35, count < 6 {
      count += 1
      cursor += 1
    }
    guard (1...6).contains(count), cursor < end,
      source.character(at: cursor) == 32 || source.character(at: cursor) == 9
    else {
      return nil
    }
    return count
  }

  private static func headingStyle(for level: Int) -> MarkdownSyntaxHighlightStyle {
    switch level {
    case 1: return .heading1
    case 2: return .heading2
    case 3: return .heading3
    case 4: return .heading4
    case 5: return .heading5
    case 6: return .heading6
    default: return .heading
    }
  }

  private static func isListLine(in source: NSString, lineRange: NSRange) -> Bool {
    var cursor = lineRange.location
    let end = NSMaxRange(lineRange)
    while cursor < end, source.character(at: cursor) == 32 || source.character(at: cursor) == 9 {
      cursor += 1
    }
    guard cursor < end else { return false }
    let marker = source.character(at: cursor)
    if marker == 45 || marker == 42 || marker == 43 {
      cursor += 1
    } else if marker >= 48, marker <= 57 {
      repeat { cursor += 1 } while cursor < end
        && source.character(at: cursor) >= 48
        && source.character(at: cursor) <= 57
      guard cursor < end, source.character(at: cursor) == 46 else { return false }
      cursor += 1
    } else {
      return false
    }
    guard cursor < end else { return false }
    return source.character(at: cursor) == 32 || source.character(at: cursor) == 9
  }

  private static func isQuoteLine(in source: NSString, lineRange: NSRange) -> Bool {
    lineRange.length > 2
      && source.character(at: lineRange.location) == 62
      && source.character(at: lineRange.location + 1) == 32
  }

  private static func captureLinkRanges(
    referenceCaptures: [NSRange],
    uriCaptures: [NSRange],
    source: NSString,
    requestedRange: NSRange
  ) -> [NSRange] {
    var ranges: [NSRange] = []
    for reference in referenceCaptures {
      guard isValid(reference, length: source.length), reference.length > 0,
        let openingBracket = openingBracket(
          before: reference.location,
          source: source
        ),
        let closingBracket = closingBracket(
          after: NSMaxRange(reference),
          source: source
        )
      else {
        continue
      }
      var destinationStart = closingBracket + 1
      guard destinationStart < source.length,
        source.character(at: destinationStart) == 40
      else {
        continue
      }
      destinationStart += 1
      guard let uri = uriCaptures.first(where: { uriRange in
        isValid(uriRange, length: source.length)
          && uriRange.location >= destinationStart
          && uriRange.location < source.length
      }), let closingParenthesis = closingParenthesis(
        after: NSMaxRange(uri),
        source: source
      )
      else {
        continue
      }
      let linkRange = NSRange(
        location: openingBracket,
        length: closingParenthesis + 1 - openingBracket
      )
      if let bounded = boundedCaptureRange(
        linkRange,
        source: source,
        requestedRange: requestedRange
      ) {
        ranges.append(bounded)
      }
    }
    return ranges
  }

  private static func openingBracket(before location: Int, source: NSString) -> Int? {
    guard location > 0 else { return nil }
    let lineRange = source.lineRange(for: NSRange(location: location - 1, length: 0))
    var cursor = location - 1
    while cursor >= lineRange.location {
      if source.character(at: cursor) == 91,
        !isEscaped(source, at: cursor)
      {
        return cursor
      }
      cursor -= 1
    }
    return nil
  }

  private static func closingBracket(after location: Int, source: NSString) -> Int? {
    guard location < source.length else { return nil }
    let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
    var cursor = location
    while cursor < NSMaxRange(lineRange) {
      if source.character(at: cursor) == 93,
        !isEscaped(source, at: cursor)
      {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func closingParenthesis(after location: Int, source: NSString) -> Int? {
    guard location < source.length else { return nil }
    let lineRange = source.lineRange(for: NSRange(location: location, length: 0))
    var cursor = location
    while cursor < NSMaxRange(lineRange) {
      if source.character(at: cursor) == 41,
        !isEscaped(source, at: cursor)
      {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
    var cursor = location
    var slashCount = 0
    while cursor > 0, source.character(at: cursor - 1) == 92 {
      slashCount += 1
      cursor -= 1
    }
    return slashCount.isMultiple(of: 2) == false
  }

  private static func normalizedRuns(
    _ runs: [MarkdownSyntaxHighlightRun]
  ) -> [MarkdownSyntaxHighlightRun] {
    runs.sorted {
      if $0.range.location == $1.range.location {
        return $0.range.length < $1.range.length
      }
      return $0.range.location < $1.range.location
    }.reduce(into: []) { result, run in
      if result.last != run { result.append(run) }
    }
  }

  private static func normalizedRanges(_ ranges: [NSRange]) -> [NSRange] {
    ranges.sorted {
      if $0.location == $1.location { return $0.length < $1.length }
      return $0.location < $1.location
    }.reduce(into: []) { result, range in
      if result.last != range { result.append(range) }
    }
  }

  static func excludingOverlaps(
    from orderedRanges: [NSRange],
    excludedBy orderedExcludedRanges: [NSRange]
  ) -> [NSRange] {
    guard !orderedRanges.isEmpty, !orderedExcludedRanges.isEmpty else {
      return orderedRanges
    }

    var includedRanges: [NSRange] = []
    includedRanges.reserveCapacity(orderedRanges.count)
    var excludedIndex = 0
    for range in orderedRanges {
      guard range.length > 0 else {
        includedRanges.append(range)
        continue
      }

      while excludedIndex < orderedExcludedRanges.count {
        let excludedRange = orderedExcludedRanges[excludedIndex]
        if excludedRange.location == NSNotFound
          || excludedRange.length == 0
          || NSMaxRange(excludedRange) <= range.location
        {
          excludedIndex += 1
        } else {
          break
        }
      }

      guard excludedIndex < orderedExcludedRanges.count else {
        includedRanges.append(range)
        continue
      }
      if orderedExcludedRanges[excludedIndex].location >= NSMaxRange(range) {
        includedRanges.append(range)
      }
    }
    return includedRanges
  }

  private func append(
    _ ranges: [NSRange],
    style: MarkdownSyntaxHighlightStyle,
    offset: Int,
    to runs: inout [MarkdownSyntaxHighlightRun]
  ) {
    runs.append(
      contentsOf: ranges.map { range in
        MarkdownSyntaxHighlightRun(
          style: style,
          range: NSRange(location: offset + range.location, length: range.length)
        )
      })
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }
}

/// Ranges that can be emitted directly from tree-sitter highlight captures.
///
/// The Markdown queries intentionally expose punctuation captures rather than
/// editor-level constructs for headings, lists, and block quotes. Those three
/// styles therefore use a tiny line-prefix interpretation below to expand the
/// capture to the same source range the editor has historically applied. HTML
/// and strikethrough are not covered by the vendored queries and remain
/// explicit lightweight-lexer fallbacks.
private struct MarkdownSyntaxCaptureRuns {
  var headings: [MarkdownSyntaxHighlightRun] = []
  var links: [NSRange] = []
  var lists: [NSRange] = []
  var quotes: [NSRange] = []
  var bold: [NSRange] = []
  var italic: [NSRange] = []
}

private struct MarkdownSyntaxLexicalStyles: OptionSet {
  let rawValue: UInt8

  static let headings = Self(rawValue: 1 << 0)
  static let links = Self(rawValue: 1 << 1)
  static let lists = Self(rawValue: 1 << 2)
  static let quotes = Self(rawValue: 1 << 3)
  static let bold = Self(rawValue: 1 << 4)
  static let italic = Self(rawValue: 1 << 5)
  static let strikethrough = Self(rawValue: 1 << 6)
  static let html = Self(rawValue: 1 << 7)
  static let all: Self = [
    .headings,
    .links,
    .lists,
    .quotes,
    .bold,
    .italic,
    .strikethrough,
    .html,
  ]
}

private final class MarkdownTreeSitterEngine {
  private let layer: LanguageLayer
  private var source = ""
  private var sourceRevision: UInt64?
  private var lineIndex = MarkdownTreeSitterLineIndex(text: "")
  private(set) var initialParseCount = 0
  private(set) var incrementalParseCount = 0
  private(set) var editHintParseCount = 0
  private(set) var lastChangedRange: NSRange?

  init() throws {
    let markdown = try Self.languageConfiguration(
      Language(tree_sitter_markdown()),
      name: "Markdown",
      bundleName: "TreeSitterMarkdown_TreeSitterMarkdown"
    )
    let configuration = LanguageLayer.Configuration(
      maximumLanguageDepth: 1,
      languageProvider: { name in
        guard name == "markdown_inline" else { return nil }
        return try? Self.languageConfiguration(
          Language(tree_sitter_markdown_inline()),
          name: "MarkdownInline",
          bundleName: "TreeSitterMarkdown_TreeSitterMarkdownInline"
        )
      }
    )
    layer = try LanguageLayer(
      languageConfig: markdown,
      configuration: configuration
    )
  }

  private static func languageConfiguration(
    _ language: Language,
    name: String,
    bundleName: String
  ) throws -> LanguageConfiguration {
    let fileManager = FileManager.default
    let bundleDirectoryName = "\(bundleName).bundle"
    var searchRoots: [URL] = []
    let bundles =
      [Bundle.main, Bundle(for: MarkdownTreeSitterBundleMarker.self)]
      + Bundle.allBundles + Bundle.allFrameworks
    for bundle in bundles {
      searchRoots.append(bundle.bundleURL)
      if let resourceURL = bundle.resourceURL {
        searchRoots.append(resourceURL)
      }
      var ancestor = bundle.bundleURL.deletingLastPathComponent()
      for _ in 0..<4 {
        searchRoots.append(ancestor)
        ancestor.deleteLastPathComponent()
      }
    }

    for root in searchRoots {
      let bundleRoot = root.appendingPathComponent(bundleDirectoryName, isDirectory: true)
      for relativePath in ["queries", "Contents/Resources/queries"] {
        let queriesURL = bundleRoot.appendingPathComponent(relativePath, isDirectory: true)
        var queries: [Query.Definition: Query] = [:]
        for definition in [Query.Definition.injections, .highlights] {
          let queryURL = queriesURL.appendingPathComponent(definition.filename)
          guard fileManager.isReadableFile(atPath: queryURL.path) else { continue }
          queries[definition] = try Query(language: language, url: queryURL)
        }
        if !queries.isEmpty {
          return LanguageConfiguration(language, name: name, queries: queries)
        }
      }
    }
    return try LanguageConfiguration(language, name: name, bundleName: bundleName)
  }

  func highlights(
    in newSource: String,
    source newSourceUTF16: NSString,
    range: NSRange,
    revision: UInt64?,
    edit: MarkdownSyntaxHighlightEdit?
  ) throws -> [NamedRange] {
    try updateSource(
      to: newSource,
      source: newSourceUTF16,
      revision: revision,
      edit: edit
    )
    return try layer.highlights(
      in: range,
      provider: Self.textProvider(for: newSourceUTF16)
    )
  }

  func synchronize(
    in newSource: String,
    source newSourceUTF16: NSString,
    revision: UInt64?,
    edit: MarkdownSyntaxHighlightEdit?
  ) throws {
    try updateSource(
      to: newSource,
      source: newSourceUTF16,
      revision: revision,
      edit: edit
    )
  }

  private func updateSource(
    to newSource: String,
    source newSourceUTF16: NSString,
    revision: UInt64?,
    edit: MarkdownSyntaxHighlightEdit?
  ) throws {
    if let revision, revision == sourceRevision {
      lastChangedRange = nil
      return
    }
    if revision == nil, newSource == source {
      lastChangedRange = nil
      return
    }
    if initialParseCount == 0 {
      let newIndex = MarkdownTreeSitterLineIndex(text: newSource)
      let changed = layer.replaceContent(
        with: newSource,
        transformer: { newIndex.point(at: $0) }
      )
      source = newSource
      sourceRevision = revision
      lineIndex = newIndex
      initialParseCount += 1
      lastChangedRange = Self.coveringRange(changed)
      return
    }

    let revisionMatchedEdit: MarkdownSyntaxHighlightEdit?
    if let edit, let previousRevision = edit.previousRevision {
      revisionMatchedEdit = previousRevision == sourceRevision ? edit : nil
    } else {
      revisionMatchedEdit = edit
    }
    let editRange: (oldRange: NSRange, newRange: NSRange)
    if let hintedRange = Self.editRange(
      from: source,
      to: newSource,
      edit: revisionMatchedEdit
    ) {
      editRange = hintedRange
      editHintParseCount += 1
    } else {
      editRange = Self.singleEditRange(from: source, to: newSource)
    }
    let previousIndex = lineIndex
    let oldSourceUTF16 = source as NSString
    let editTouchesLineBreak =
      Self.containsLineBreak(oldSourceUTF16, in: editRange.oldRange)
      || Self.containsLineBreak(newSourceUTF16, in: editRange.newRange)
    let lineOffsetsAreUnchanged = editRange.oldRange.length == editRange.newRange.length
      && !editTouchesLineBreak
    let newIndex = lineOffsetsAreUnchanged
      ? previousIndex
      : previousIndex.applying(
        replacedRange: editRange.oldRange,
        insertedLength: editRange.newRange.length,
        newText: newSource
      )
    let inputEdit = InputEdit(
      startByte: editRange.oldRange.location * 2,
      oldEndByte: NSMaxRange(editRange.oldRange) * 2,
      newEndByte: NSMaxRange(editRange.newRange) * 2,
      startPoint: previousIndex.point(at: editRange.oldRange.location),
      oldEndPoint: previousIndex.point(at: NSMaxRange(editRange.oldRange)),
      newEndPoint: newIndex.point(at: NSMaxRange(editRange.newRange))
    )
    let changed = layer.didChangeContent(
      Self.content(for: newSourceUTF16),
      using: inputEdit,
      resolveSublayers: !lineOffsetsAreUnchanged
    )
    source = newSource
    sourceRevision = revision
    lineIndex = newIndex
    incrementalParseCount += 1
    if !editTouchesLineBreak {
      lastChangedRange = newSourceUTF16.lineRange(for: editRange.newRange)
    } else {
      lastChangedRange = Self.coveringRange(changed)
    }
  }

  /// SwiftTreeSitter's default String reader converts UTF-16 byte offsets back
  /// through `String.Index` for every chunk. That lookup grows with the offset
  /// in a large document. NSTextView already speaks UTF-16, so use NSString's
  /// direct coordinates for both parser reads and query predicate slices.
  private static func content(for source: NSString) -> LanguageLayer.Content {
    let readHandler: Parser.ReadBlock = { byteOffset, _ in
      let location = byteOffset / MemoryLayout<unichar>.size
      guard byteOffset.isMultiple(of: MemoryLayout<unichar>.size),
        location >= 0,
        location < source.length
      else {
        return nil
      }
      let length = min(1_024, source.length - location)
      var characters = [unichar](repeating: 0, count: length)
      source.getCharacters(
        &characters,
        range: NSRange(location: location, length: length)
      )
      return characters.withUnsafeBytes { Data($0) }
    }
    return LanguageLayer.Content(
      readHandler: readHandler,
      textProvider: textProvider(for: source)
    )
  }

  private static func textProvider(
    for source: NSString
  ) -> SwiftTreeSitter.Predicate.TextProvider {
    { range, _ in
      guard range.location != NSNotFound,
        range.location >= 0,
        range.length >= 0,
        range.location <= source.length,
        range.length <= source.length - range.location
      else {
        return nil
      }
      return source.substring(with: range)
    }
  }

  private static func containsLineBreak(_ source: NSString, in range: NSRange) -> Bool {
    guard range.length > 0 else { return false }
    return source.range(
      of: "\n",
      options: [],
      range: range
    ).location != NSNotFound
      || source.range(
        of: "\r",
        options: [],
        range: range
      ).location != NSNotFound
  }

  private static func editRange(
    from oldText: String,
    to newText: String,
    edit: MarkdownSyntaxHighlightEdit?
  ) -> (oldRange: NSRange, newRange: NSRange)? {
    guard let edit else { return nil }
    if edit.previousRevision == nil {
      guard edit.previousText == oldText else { return nil }
    }
    let oldLength = (oldText as NSString).length
    let newLength = (newText as NSString).length
    let oldRange = edit.replacedRange
    guard oldRange.location != NSNotFound,
      oldRange.location >= 0,
      oldRange.length >= 0,
      oldRange.location <= oldLength,
      oldRange.length <= oldLength - oldRange.location
    else {
      return nil
    }
    let insertedLength = newLength - (oldLength - oldRange.length)
    guard insertedLength >= 0 else { return nil }
    return (
      oldRange,
      NSRange(location: oldRange.location, length: insertedLength)
    )
  }

  private static func singleEditRange(
    from oldText: String,
    to newText: String
  ) -> (oldRange: NSRange, newRange: NSRange) {
    let old = oldText as NSString
    let new = newText as NSString
    let commonLimit = min(old.length, new.length)
    var prefix = 0
    while prefix < commonLimit, old.character(at: prefix) == new.character(at: prefix) {
      prefix += 1
    }
    if prefix > 0, prefix < old.length, prefix < new.length,
      Self.isHighSurrogate(old.character(at: prefix - 1))
    {
      prefix -= 1
    }

    var suffix = 0
    while suffix < old.length - prefix,
      suffix < new.length - prefix,
      old.character(at: old.length - suffix - 1)
        == new.character(at: new.length - suffix - 1)
    {
      suffix += 1
    }
    if suffix > 0,
      old.length - suffix > prefix,
      new.length - suffix > prefix,
      Self.isLowSurrogate(old.character(at: old.length - suffix))
    {
      suffix -= 1
    }

    return (
      NSRange(location: prefix, length: old.length - prefix - suffix),
      NSRange(location: prefix, length: new.length - prefix - suffix)
    )
  }

  private static func coveringRange(_ set: IndexSet) -> NSRange? {
    guard let first = set.first, let last = set.last else { return nil }
    return NSRange(location: first, length: last - first + 1)
  }

  private static func isHighSurrogate(_ value: unichar) -> Bool {
    (0xD800...0xDBFF).contains(value)
  }

  private static func isLowSurrogate(_ value: unichar) -> Bool {
    (0xDC00...0xDFFF).contains(value)
  }
}

private final class MarkdownTreeSitterBundleMarker: NSObject {}

private struct MarkdownTreeSitterLineIndex {
  private var starts: [Int]

  init(text: String) {
    starts = Self.lineStarts(in: text as NSString)
  }

  func point(at location: Int) -> Point {
    let safeLocation = max(0, location)
    var lower = 0
    var upper = starts.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if starts[middle] <= safeLocation {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    let line = max(0, lower - 1)
    return Point(row: line, column: (safeLocation - starts[line]) * 2)
  }

  func applying(
    replacedRange: NSRange,
    insertedLength: Int,
    newText: String
  ) -> Self {
    let delta = insertedLength - replacedRange.length
    let oldEnd = NSMaxRange(replacedRange)
    let startLineIndex = max(0, starts.partitioningIndex { $0 > replacedRange.location } - 1)
    let rebuildStart = starts[startLineIndex]
    let resumeIndex = starts.partitioningIndex { $0 > oldEnd }
    let oldResume = resumeIndex < starts.count ? starts[resumeIndex] : nil
    let newResume = oldResume.map { $0 + delta }
    let text = newText as NSString
    let scanEnd = min(max(rebuildStart, newResume ?? text.length), text.length)

    var nextStarts = Array(starts[..<startLineIndex])
    nextStarts.append(rebuildStart)
    var location = rebuildStart
    while location < scanEnd {
      let newline = text.range(
        of: "\n",
        range: NSRange(location: location, length: scanEnd - location)
      )
      guard newline.location != NSNotFound else { break }
      location = NSMaxRange(newline)
      if location <= scanEnd, nextStarts.last != location {
        nextStarts.append(location)
      }
    }
    if let newResume {
      for oldStart in starts.dropFirst(resumeIndex) {
        let shifted = oldStart + delta
        if shifted >= newResume, shifted <= text.length, nextStarts.last != shifted {
          nextStarts.append(shifted)
        }
      }
    }
    var result = self
    result.starts = nextStarts
    return result
  }

  private static func lineStarts(in text: NSString) -> [Int] {
    var result = [0]
    var location = 0
    while location < text.length {
      let newline = text.range(
        of: "\n",
        range: NSRange(location: location, length: text.length - location)
      )
      guard newline.location != NSNotFound else { break }
      location = NSMaxRange(newline)
      result.append(location)
    }
    return result
  }
}

extension Array where Element == Int {
  fileprivate func partitioningIndex(where predicate: (Int) -> Bool) -> Int {
    var lower = 0
    var upper = count
    while lower < upper {
      let middle = (lower + upper) / 2
      if predicate(self[middle]) {
        upper = middle
      } else {
        lower = middle + 1
      }
    }
    return lower
  }
}

private struct MarkdownSyntaxLexicalRuns {
  var heading1: [NSRange] = []
  var heading2: [NSRange] = []
  var heading3: [NSRange] = []
  var heading4: [NSRange] = []
  var heading5: [NSRange] = []
  var heading6: [NSRange] = []
  var html: [NSRange] = []
  var links: [NSRange] = []
  var lists: [NSRange] = []
  var quotes: [NSRange] = []
  var bold: [NSRange] = []
  var italic: [NSRange] = []
  var strikethrough: [NSRange] = []
}

/// A small UTF-16 lexer for the source-editor highlighting subset.
///
/// Code ranges are resolved first because fenced code carries state across
/// lines. The remaining constructs are found in three linear passes: block
/// prefixes, inline delimiters/links, and HTML. This keeps AppKit-compatible
/// coordinates without allocating one `String` per match or running seven
/// independent regular-expression engines.
private enum MarkdownSyntaxLightweightLexer {
  private static let backslash: unichar = 92
  private static let carriageReturn: unichar = 13
  private static let lineFeed: unichar = 10
  private static let space: unichar = 32
  private static let tab: unichar = 9
  private static let asterisk: unichar = 42
  private static let tilde: unichar = 126

  static func scan(
    _ source: NSString,
    in scanRange: NSRange,
    blockRanges: [NSRange],
    literalRanges: [NSRange],
    styles: MarkdownSyntaxLexicalStyles = .all
  ) -> MarkdownSyntaxLexicalRuns? {
    var result = MarkdownSyntaxLexicalRuns()
    if styles.contains(.headings) || styles.contains(.lists) || styles.contains(.quotes) {
      guard scanLinePrefixes(
        source,
        in: scanRange,
        excluding: blockRanges,
        styles: styles,
        into: &result
      ) else {
        return nil
      }
    }
    if styles.contains(.links)
      || styles.contains(.bold)
      || styles.contains(.italic)
      || styles.contains(.strikethrough)
    {
      guard scanInline(
        source,
        in: scanRange,
        excluding: literalRanges,
        styles: styles,
        into: &result
      ) else {
        return nil
      }
    }
    if styles.contains(.html) {
      guard scanHTML(
        source,
        in: scanRange,
        excluding: literalRanges,
        into: &result
      ) else {
        return nil
      }
    }
    return result
  }

  private static func scanLinePrefixes(
    _ source: NSString,
    in scanRange: NSRange,
    excluding excludedRanges: [NSRange],
    styles: MarkdownSyntaxLexicalStyles,
    into result: inout MarkdownSyntaxLexicalRuns
  ) -> Bool {
    let upperBound = NSMaxRange(scanRange)
    var location = scanRange.location
    var excludedIndex = 0
    var nextCancellationCheck = 0
    while location < upperBound {
      if location >= nextCancellationCheck {
        if Task.isCancelled { return false }
        nextCancellationCheck = location + 4_096
      }
      var lineStart = 0
      var lineEnd = 0
      var contentsEnd = 0
      source.getLineStart(
        &lineStart,
        end: &lineEnd,
        contentsEnd: &contentsEnd,
        for: NSRange(location: location, length: 0)
      )
      let boundedLineStart = max(lineStart, scanRange.location)
      let boundedContentsEnd = min(contentsEnd, upperBound)
      let lineRange = NSRange(
        location: boundedLineStart,
        length: max(0, boundedContentsEnd - boundedLineStart)
      )
      if containingRange(
        at: boundedLineStart,
        in: excludedRanges,
        index: &excludedIndex
      ) == nil {
        if styles.contains(.headings) {
          switch headingLevel(source, range: lineRange) {
          case 1: result.heading1.append(lineRange)
          case 2: result.heading2.append(lineRange)
          case 3: result.heading3.append(lineRange)
          case 4: result.heading4.append(lineRange)
          case 5: result.heading5.append(lineRange)
          case 6: result.heading6.append(lineRange)
          default: break
          }
        }
        if styles.contains(.lists), isList(source, range: lineRange) {
          result.lists.append(lineRange)
        }
        if styles.contains(.quotes), isQuote(source, range: lineRange) {
          result.quotes.append(lineRange)
        }
      }
      location = max(lineEnd, location + 1)
    }
    return true
  }

  private static func scanInline(
    _ source: NSString,
    in scanRange: NSRange,
    excluding excludedRanges: [NSRange],
    styles: MarkdownSyntaxLexicalStyles,
    into result: inout MarkdownSyntaxLexicalRuns
  ) -> Bool {
    let lowerBound = scanRange.location
    let upperBound = NSMaxRange(scanRange)
    var cursor = lowerBound
    var excludedIndex = 0
    var labelStart: Int?
    var linkStart: Int?
    var destinationStart: Int?
    var boldStart: Int?
    var italicStart: Int?
    var strikethroughStart: Int?
    var nextCancellationCheck = 0

    while cursor < upperBound {
      if cursor >= nextCancellationCheck {
        if Task.isCancelled { return false }
        nextCancellationCheck = cursor + 4_096
      }
      if let excluded = containingRange(
        at: cursor,
        in: excludedRanges,
        index: &excludedIndex
      ) {
        cursor = NSMaxRange(excluded)
        labelStart = nil
        linkStart = nil
        destinationStart = nil
        boldStart = nil
        italicStart = nil
        strikethroughStart = nil
        continue
      }

      let character = source.character(at: cursor)
      if (character == lineFeed || character == carriageReturn)
        && (styles.contains(.bold)
          || styles.contains(.italic)
          || styles.contains(.strikethrough))
      {
        boldStart = nil
        italicStart = nil
        strikethroughStart = nil
      }

      if styles.contains(.links) {
        if linkStart != nil {
          if character == 41, !isEscaped(source, at: cursor),
            let start = linkStart,
            let destination = destinationStart,
            cursor > destination
          {
            result.links.append(NSRange(location: start, length: cursor + 1 - start))
            linkStart = nil
            destinationStart = nil
          }
        } else if character == 91, !isEscaped(source, at: cursor) {
          if labelStart == nil { labelStart = cursor }
        } else if character == 93, !isEscaped(source, at: cursor) {
          if let start = labelStart,
            cursor > start + 1,
            cursor + 1 < upperBound,
            source.character(at: cursor + 1) == 40
          {
            linkStart = start
            destinationStart = cursor + 2
            labelStart = nil
          } else {
            labelStart = nil
          }
        }
      }

      if (styles.contains(.bold) || styles.contains(.italic)),
        character == asterisk,
        !isEscaped(source, at: cursor)
      {
        var runEnd = cursor + 1
        while runEnd < upperBound, source.character(at: runEnd) == asterisk {
          runEnd += 1
        }
        let runLength = runEnd - cursor
        if runLength == 1, styles.contains(.italic) {
          pairDelimiter(
            source,
            start: cursor,
            end: runEnd,
            upperBound: upperBound,
            opening: &italicStart,
            ranges: &result.italic
          )
        } else if runLength == 2, styles.contains(.bold) {
          pairDelimiter(
            source,
            start: cursor,
            end: runEnd,
            upperBound: upperBound,
            opening: &boldStart,
            ranges: &result.bold
          )
        } else if runLength == 3 {
          if styles.contains(.bold) {
            pairDelimiter(
              source,
              start: cursor,
              end: runEnd,
              upperBound: upperBound,
              opening: &boldStart,
              ranges: &result.bold
            )
          }
          if styles.contains(.italic) {
            pairDelimiter(
              source,
              start: cursor,
              end: runEnd,
              upperBound: upperBound,
              opening: &italicStart,
              ranges: &result.italic
            )
          }
        }
        cursor = runEnd
        continue
      }

      if styles.contains(.strikethrough),
        character == tilde,
        !isEscaped(source, at: cursor)
      {
        var runEnd = cursor + 1
        while runEnd < upperBound, source.character(at: runEnd) == tilde {
          runEnd += 1
        }
        let runLength = runEnd - cursor
        if runLength == 2 {
          pairDelimiter(
            source,
            start: cursor,
            end: runEnd,
            upperBound: upperBound,
            opening: &strikethroughStart,
            ranges: &result.strikethrough
          )
        } else {
          // A run of three or more tildes belongs to fence syntax or is an
          // otherwise ambiguous delimiter. Never let it pair with a prior
          // `~~` across the run.
          strikethroughStart = nil
        }
        cursor = runEnd
        continue
      }
      cursor += 1
    }
    return true
  }

  private static func scanHTML(
    _ source: NSString,
    in scanRange: NSRange,
    excluding excludedRanges: [NSRange],
    into result: inout MarkdownSyntaxLexicalRuns
  ) -> Bool {
    let upperBound = NSMaxRange(scanRange)
    var cursor = scanRange.location
    var excludedIndex = 0
    var commentStart: Int?
    var nextCancellationCheck = 0
    while cursor < upperBound {
      if cursor >= nextCancellationCheck {
        if Task.isCancelled { return false }
        nextCancellationCheck = cursor + 4_096
      }
      if let excluded = containingRange(
        at: cursor,
        in: excludedRanges,
        index: &excludedIndex
      ) {
        cursor = NSMaxRange(excluded)
        commentStart = nil
        continue
      }

      if let start = commentStart {
        if hasCharacters([45, 45, 62], in: source, at: cursor) {
          result.html.append(NSRange(location: start, length: cursor + 3 - start))
          commentStart = nil
          cursor += 3
        } else {
          cursor += 1
        }
        continue
      }

      guard source.character(at: cursor) == 60 else {
        cursor += 1
        continue
      }
      if hasCharacters([60, 33, 45, 45], in: source, at: cursor) {
        commentStart = cursor
        cursor += 4
        continue
      }
      if let end = htmlTagEnd(in: source, startingAt: cursor, upperBound: upperBound) {
        let overlapsLiteral =
          excludedIndex < excludedRanges.count
          && excludedRanges[excludedIndex].location < end
        if !overlapsLiteral {
          result.html.append(NSRange(location: cursor, length: end - cursor))
        }
        cursor = end
      } else {
        cursor += 1
      }
    }
    return true
  }

  private static func headingLevel(_ source: NSString, range: NSRange) -> Int {
    var cursor = range.location
    let end = NSMaxRange(range)
    while cursor < end, source.character(at: cursor) == 35, cursor - range.location < 7 {
      cursor += 1
    }
    let count = cursor - range.location
    guard (1...6).contains(count), cursor < end,
      isWhitespace(source.character(at: cursor))
    else {
      return 0
    }
    return count
  }

  private static func isList(_ source: NSString, range: NSRange) -> Bool {
    var cursor = range.location
    let end = NSMaxRange(range)
    while cursor < end, isWhitespace(source.character(at: cursor)) { cursor += 1 }
    guard cursor < end else { return false }

    let marker = source.character(at: cursor)
    if marker == 45 || marker == asterisk || marker == 43 {
      cursor += 1
    } else if isDigit(marker) {
      repeat { cursor += 1 } while cursor < end && isDigit(source.character(at: cursor))
      guard cursor < end, source.character(at: cursor) == 46 else { return false }
      cursor += 1
    } else {
      return false
    }
    return cursor < end && isWhitespace(source.character(at: cursor))
  }

  private static func isQuote(_ source: NSString, range: NSRange) -> Bool {
    range.length > 2
      && source.character(at: range.location) == 62
      && source.character(at: range.location + 1) == space
  }

  private static func pairDelimiter(
    _ source: NSString,
    start: Int,
    end: Int,
    upperBound: Int,
    opening: inout Int?,
    ranges: inout [NSRange]
  ) {
    let canClose = start > 0 && !isWhitespace(source.character(at: start - 1))
    let canOpen = end < upperBound && !isWhitespace(source.character(at: end))
    if let openingLocation = opening,
      canClose,
      start > openingLocation + (end - start)
    {
      ranges.append(NSRange(location: openingLocation, length: end - openingLocation))
      opening = nil
    } else if canOpen {
      opening = start
    }
  }

  private static func htmlTagEnd(
    in source: NSString,
    startingAt start: Int,
    upperBound: Int
  ) -> Int? {
    var cursor = start + 1
    guard cursor < upperBound else { return nil }
    if source.character(at: cursor) == 47 { cursor += 1 }
    guard cursor < upperBound, isASCIILetter(source.character(at: cursor)) else {
      return nil
    }
    cursor += 1
    while cursor < upperBound {
      let character = source.character(at: cursor)
      if character == 62 { return cursor + 1 }
      if character == 60 || character == lineFeed { return nil }
      cursor += 1
    }
    return nil
  }

  private static func containingRange(
    at location: Int,
    in ranges: [NSRange],
    index: inout Int
  ) -> NSRange? {
    while index < ranges.count, NSMaxRange(ranges[index]) <= location { index += 1 }
    guard index < ranges.count,
      ranges[index].location <= location,
      location < NSMaxRange(ranges[index])
    else {
      return nil
    }
    return ranges[index]
  }

  private static func isEscaped(_ source: NSString, at location: Int) -> Bool {
    var cursor = location
    var count = 0
    while cursor > 0, source.character(at: cursor - 1) == backslash {
      count += 1
      cursor -= 1
    }
    return count.isMultiple(of: 2) == false
  }

  private static func hasCharacters(
    _ characters: [unichar],
    in source: NSString,
    at location: Int
  ) -> Bool {
    guard location <= source.length - characters.count else { return false }
    for (offset, character) in characters.enumerated()
    where source.character(at: location + offset) != character {
      return false
    }
    return true
  }

  private static func isWhitespace(_ character: unichar) -> Bool {
    character == space || character == tab
  }

  private static func isDigit(_ character: unichar) -> Bool {
    character >= 48 && character <= 57
  }

  private static func isASCIILetter(_ character: unichar) -> Bool {
    (character >= 65 && character <= 90) || (character >= 97 && character <= 122)
  }

}
