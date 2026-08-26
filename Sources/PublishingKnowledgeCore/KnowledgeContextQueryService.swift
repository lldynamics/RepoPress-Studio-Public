import Foundation
import PublishingCoreSupport

/// Narrow editor projection used to build a local knowledge retrieval query.
/// Keeping this value independent from Workbench draft models prevents the
/// knowledge domain from depending on the composition layer.
public struct KnowledgeContextQueryInput: Hashable, Sendable {
  public let title: String
  public let summary: String
  public let tags: [String]
  public let bodyMarkdown: String

  public init(
    title: String,
    summary: String,
    tags: [String],
    bodyMarkdown: String
  ) {
    self.title = title
    self.summary = summary
    self.tags = tags
    self.bodyMarkdown = bodyMarkdown
  }
}

/// Builds a small, local-only retrieval query from the editor context. It keeps
/// the query bounded so typing never sends the whole article through the index.
public enum KnowledgeContextQueryService {
  private static let maximumContextCharacters = 12_000
  private static let headingScanCharacters = 16_000
  private static let paragraphWindowUTF16Length = 4_800
  private static let paragraphSeparator: NSRegularExpression? = {
    do {
      return try NSRegularExpression(
        pattern: "(?:\\r\\n|[\\n\\r])[\\t ]*(?:\\r\\n|[\\n\\r])"
      )
    } catch {
      // A fixed pattern should always compile. If Foundation rejects it,
      // continue with the bounded window instead of failing query generation.
      return nil
    }
  }()

  public static func query(
    input: KnowledgeContextQueryInput,
    selectedRange: NSRange? = nil,
    maximumCharacters: Int = 3_600
  ) -> String {
    let body = input.bodyMarkdown
    let contextLimit = normalizedContextLimit(maximumCharacters)
    let headings = boundedHeadings(in: body)

    let bodyContext = boundedBodyContext(body, maximumCharacters: contextLimit)
    let paragraphContext: String?
    if let selectedRange {
      paragraphContext = Self.currentParagraph(in: body, selectedRange: selectedRange)
        .map { boundedBodyContext($0, maximumCharacters: 1_200) }
    } else {
      paragraphContext = nil
    }

    var parts: [String] = []
    if let title = input.title.trimmedForPublishing.nilIfEmpty {
      parts.append("标题：\(title)")
    }
    if let summary = input.summary.trimmedForPublishing.nilIfEmpty {
      parts.append("摘要：\(summary)")
    }
    let tags = input.tags.joined(separator: "、").trimmedForPublishing
    if let tags = tags.nilIfEmpty {
      parts.append("标签：\(tags)")
    }
    if !headings.isEmpty {
      parts.append("章节：\(headings.joined(separator: "、"))")
    }
    if let paragraphContext {
      parts.append("当前段落：\(paragraphContext)")
    }
    if let bodyContext = bodyContext.nilIfEmpty {
      parts.append("正文上下文：\(bodyContext)")
    }
    return parts.joined(separator: "\n")
  }

  /// Returns the Markdown paragraph containing the caret or selection.
  ///
  /// Markdown paragraphs are separated by a blank line, which is more useful
  /// for retrieval than `NSString.paragraphRange` (which only understands
  /// individual lines). The range is expressed in UTF-16 offsets to match the
  /// AppKit text editor state.
  public static func currentParagraph(
    in bodyMarkdown: String,
    selectedRange: NSRange
  ) -> String? {
    let source = bodyMarkdown as NSString
    let bodyLength = source.length
    let location = min(max(selectedRange.location, 0), bodyLength)
    let selectionLength = min(max(0, selectedRange.length), bodyLength - location)
    let selectionEnd = location + selectionLength
    let windowStart = max(0, location - paragraphWindowUTF16Length)
    let windowEnd = min(bodyLength, selectionEnd + paragraphWindowUTF16Length)
    let precedingRange = scalarAlignedRange(
      NSRange(
        location: windowStart,
        length: max(0, location - windowStart)
      ),
      in: source
    )
    let precedingDelimiter = paragraphSeparator?
      .matches(in: bodyMarkdown, options: [], range: precedingRange)
      .last?.range
    let paragraphStart = precedingDelimiter.map(NSMaxRange) ?? windowStart
    let followingRange = scalarAlignedRange(
      NSRange(
        location: selectionEnd,
        length: max(0, windowEnd - selectionEnd)
      ),
      in: source
    )
    let followingDelimiter = paragraphSeparator?.firstMatch(
      in: bodyMarkdown,
      options: [],
      range: followingRange
    )?.range
    let paragraphEnd = followingDelimiter?.location ?? windowEnd
    let selectedContextEnd = min(selectionEnd, location + 600)
    let excerptStart = max(paragraphStart, location - 600)
    let excerptEnd = min(paragraphEnd, selectedContextEnd + 600)
    let paragraphRange = scalarAlignedRange(
      NSRange(
        location: excerptStart,
        length: max(0, excerptEnd - excerptStart)
      ),
      in: source
    )
    let normalized = compacted(source.substring(with: paragraphRange))
    guard !normalized.isEmpty else { return nil }
    return boundedCompactedContext(
      normalized,
      maximumCharacters: min(1_200, maximumContextCharacters)
    )
  }

  private static func boundedBodyContext(
    _ body: String,
    maximumCharacters: Int
  ) -> String {
    let limit = normalizedContextLimit(maximumCharacters)
    let rawBudget = min(maximumContextCharacters * 4, max(limit + 1, limit * 4))
    let headEnd = body.index(
      body.startIndex,
      offsetBy: rawBudget,
      limitedBy: body.endIndex
    ) ?? body.endIndex
    guard headEnd != body.endIndex else {
      return boundedCompactedContext(
        compacted(body),
        maximumCharacters: limit
      )
    }

    let tailStart = body.index(
      body.endIndex,
      offsetBy: -rawBudget,
      limitedBy: body.startIndex
    ) ?? body.startIndex
    if headEnd >= tailStart {
      return boundedCompactedContext(
        compacted(body),
        maximumCharacters: limit
      )
    }

    let headLength = max(1, limit * 2 / 3)
    let tailLength = max(1, limit - headLength)
    let head = String(compacted(String(body[..<headEnd])).prefix(headLength))
    let tail = String(compacted(String(body[tailStart...])).suffix(tailLength))
    if head.isEmpty { return tail }
    if tail.isEmpty { return head }
    return "\(head) … \(tail)"
  }

  private static func boundedHeadings(in body: String) -> [String] {
    let end = body.index(
      body.startIndex,
      offsetBy: headingScanCharacters,
      limitedBy: body.endIndex
    ) ?? body.endIndex
    var headings: [String] = []
    for rawLine in body[..<end].split(
      omittingEmptySubsequences: false,
      whereSeparator: \Character.isNewline
    ) {
      let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
      let hashes = line.prefix { $0 == "#" }.count
      guard (1...6).contains(hashes) else { continue }
      let contentStart = line.index(line.startIndex, offsetBy: hashes)
      guard contentStart < line.endIndex, line[contentStart] == " " else { continue }
      headings.append(line)
      if headings.count == 12 { break }
    }
    return headings
  }

  private static func compacted(_ fragment: String) -> String {
    fragment
      .replacingOccurrences(of: "```", with: " ")
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func boundedCompactedContext(
    _ compact: String,
    maximumCharacters: Int
  ) -> String {
    let limit = normalizedContextLimit(maximumCharacters)
    guard compact.count > limit else { return compact }
    let headLength = max(1, limit * 2 / 3)
    let tailLength = max(1, limit - headLength)
    return "\(compact.prefix(headLength)) … \(compact.suffix(tailLength))"
  }

  private static func normalizedContextLimit(_ requested: Int) -> Int {
    min(max(600, requested), maximumContextCharacters)
  }

  private static func scalarAlignedRange(_ range: NSRange, in source: NSString) -> NSRange {
    var lowerBound = min(max(0, range.location), source.length)
    var upperBound = min(max(lowerBound, NSMaxRange(range)), source.length)
    if lowerBound > 0,
      lowerBound < source.length,
      isLowSurrogate(source.character(at: lowerBound)),
      isHighSurrogate(source.character(at: lowerBound - 1))
    {
      lowerBound -= 1
    }
    if upperBound > 0,
      upperBound < source.length,
      isHighSurrogate(source.character(at: upperBound - 1)),
      isLowSurrogate(source.character(at: upperBound))
    {
      upperBound += 1
    }
    return NSRange(location: lowerBound, length: upperBound - lowerBound)
  }

  private static func isHighSurrogate(_ value: unichar) -> Bool {
    (0xD800...0xDBFF).contains(Int(value))
  }

  private static func isLowSurrogate(_ value: unichar) -> Bool {
    (0xDC00...0xDFFF).contains(Int(value))
  }
}
