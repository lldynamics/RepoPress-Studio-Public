import Foundation
import OSLog

public enum MarkdownSyntaxHighlightStyle: String, Hashable, Sendable {
  case heading
  case codeBlock
  case link
  case list
  case quote
  case bold
  case italic
  case inlineCode
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

public actor MarkdownSyntaxHighlightParser {
  private let signposter = OSSignposter(
    subsystem: "com.jinfang.PersonalSitePublisherMac",
    category: "MarkdownSyntax"
  )
  private let headingRegex: NSRegularExpression?
  private let boldRegex: NSRegularExpression?
  private let italicRegex: NSRegularExpression?
  private let listRegex: NSRegularExpression?
  private let quoteRegex: NSRegularExpression?
  private let linkRegex: NSRegularExpression?
  private let htmlRegex: NSRegularExpression?

  public init() {
    headingRegex = Self.compilePattern(
      "^(#{1,6})\\s+.*$",
      options: .anchorsMatchLines
    )
    boldRegex = Self.compilePattern("\\*\\*[^\\n\\*]+\\*\\*")
    italicRegex = Self.compilePattern("(?<!\\*)\\*(?!\\*)([^\\n\\*]+?)\\*(?!\\*)")
    listRegex = Self.compilePattern(
      "^\\s*(?:[-*+]|\\d+\\.)\\s+.*$",
      options: .anchorsMatchLines
    )
    quoteRegex = Self.compilePattern("^> .*+$", options: .anchorsMatchLines)
    linkRegex = Self.compilePattern(#"\[[^\]]+\]\([^)]+\)"#)
    htmlRegex = Self.compilePattern(#"<!--[\s\S]*?-->|</?[A-Za-z][^<>\n]*?>"#)
  }

  public func snapshot(
    in markdown: String,
    range requestedRange: NSRange? = nil
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

    let substring = source.substring(with: range)
    let codeRanges = MarkdownCodeRangeScanner.scan(substring)
    let localCodeBlockRanges = codeRanges.blockRanges
    let localInlineCodeRanges = codeRanges.inlineRanges
    guard !Task.isCancelled else { return nil }

    var runs: [MarkdownSyntaxHighlightRun] = []
    appendRuns(
      for: headingRegex,
      style: .heading,
      in: substring,
      offset: range.location,
      excluding: localCodeBlockRanges,
      to: &runs
    )
    guard !Task.isCancelled else { return nil }
    append(localCodeBlockRanges, style: .codeBlock, offset: range.location, to: &runs)
    appendRuns(
      for: htmlRegex,
      style: .html,
      in: substring,
      offset: range.location,
      excluding: (localCodeBlockRanges + localInlineCodeRanges).sorted { $0.location < $1.location },
      to: &runs
    )
    appendRuns(
      for: linkRegex,
      style: .link,
      in: substring,
      offset: range.location,
      excluding: localCodeBlockRanges,
      to: &runs
    )
    guard !Task.isCancelled else { return nil }
    appendRuns(
      for: listRegex,
      style: .list,
      in: substring,
      offset: range.location,
      excluding: localCodeBlockRanges,
      to: &runs
    )
    guard !Task.isCancelled else { return nil }
    appendRuns(
      for: quoteRegex,
      style: .quote,
      in: substring,
      offset: range.location,
      excluding: localCodeBlockRanges,
      to: &runs
    )
    guard !Task.isCancelled else { return nil }
    appendRuns(
      for: boldRegex,
      style: .bold,
      in: substring,
      offset: range.location,
      excluding: localCodeBlockRanges,
      to: &runs
    )
    guard !Task.isCancelled else { return nil }
    appendRuns(
      for: italicRegex,
      style: .italic,
      in: substring,
      offset: range.location,
      excluding: localCodeBlockRanges,
      to: &runs
    )
    guard !Task.isCancelled else { return nil }
    append(localInlineCodeRanges, style: .inlineCode, offset: range.location, to: &runs)
    guard !Task.isCancelled else { return nil }
    completionState = 1
    emittedRunCount = runs.count
    return MarkdownSyntaxHighlightSnapshot(range: range, runs: runs)
  }

  private func appendRuns(
    for regex: NSRegularExpression?,
    style: MarkdownSyntaxHighlightStyle,
    in text: String,
    offset: Int,
    excluding excludedRanges: [NSRange],
    to runs: inout [MarkdownSyntaxHighlightRun]
  ) {
    let matchingRanges = Self.excludingOverlaps(
      from: ranges(for: regex, in: text),
      excludedBy: excludedRanges
    )
    append(matchingRanges, style: style, offset: offset, to: &runs)
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
          || NSMaxRange(excludedRange) <= range.location {
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
    runs.append(contentsOf: ranges.map { range in
      MarkdownSyntaxHighlightRun(
        style: style,
        range: NSRange(location: offset + range.location, length: range.length)
      )
    })
  }

  private func ranges(for regex: NSRegularExpression?, in text: String) -> [NSRange] {
    guard let regex else { return [] }
    let fullRange = NSRange(location: 0, length: (text as NSString).length)
    return regex.matches(in: text, options: [], range: fullRange).map(\.range)
  }

  private static func isValid(_ range: NSRange, length: Int) -> Bool {
    range.location != NSNotFound
      && range.location >= 0
      && range.length >= 0
      && range.location <= length
      && range.length <= length - range.location
  }

  private static func compilePattern(
    _ pattern: String,
    options: NSRegularExpression.Options = []
  ) -> NSRegularExpression? {
    try? NSRegularExpression(pattern: pattern, options: options)
  }
}
