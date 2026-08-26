import Foundation

/// The translation implementation selected by an RSS reader integration.
///
/// The core planning layer deliberately does not import Apple's Translation
/// framework. The macOS target can use this value to select its provider while
/// keeping the article parsing and HTML reconstruction code platform-neutral.
public enum RSSArticleTranslationBackend: String, Codable, CaseIterable, Hashable, Sendable {
  case apple
  case ai
}

/// One visible piece of article text that a translation provider should
/// translate. The identifier is scoped to one plan and is stable for the
/// source title/body ordering used to create that plan.
public struct RSSArticleTranslationTextRequest: Identifiable, Hashable, Sendable {
  public let id: String
  public let sourceText: String

  public init(id: String, sourceText: String) {
    self.id = id
    self.sourceText = sourceText
  }
}

/// A provider-independent translation plan for one RSS article.
///
/// The plan contains only visible text requests. The original HTML is kept
/// privately so that a result can replace translated text nodes without
/// allowing provider output to become markup or to alter links/attributes.
public struct RSSArticleSystemTranslationPlan: Hashable, Sendable {
  public let articleID: String
  public let target: RSSArticleTranslationTarget
  public let requests: [RSSArticleTranslationTextRequest]
  public let sourceCharacterCount: Int
  public let wasInputTruncated: Bool

  private let sourceContentHTML: String
  private let bodyReplacements: [BodyReplacement]

  fileprivate init(
    articleID: String,
    target: RSSArticleTranslationTarget,
    requests: [RSSArticleTranslationTextRequest],
    sourceCharacterCount: Int,
    wasInputTruncated: Bool,
    sourceContentHTML: String,
    bodyReplacements: [BodyReplacement]
  ) {
    self.articleID = articleID
    self.target = target
    self.requests = requests
    self.sourceCharacterCount = sourceCharacterCount
    self.wasInputTruncated = wasInputTruncated
    self.sourceContentHTML = sourceContentHTML
    self.bodyReplacements = bodyReplacements
  }

  /// Reassembles a complete result from provider translations.
  ///
  /// Every request in the plan must have a non-empty translation. Provider
  /// output is HTML-escaped before it is inserted into a text node; the
  /// original source is retained for nodes that were outside the safety limit.
  public func makeResult(
    translationsByRequestID: [String: String],
    providerName: String,
    model: String
  ) throws -> RSSArticleTranslationResult {
    guard let translatedTitle = translationsByRequestID[Self.titleRequestID],
          !translatedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw RSSArticleTranslationError.invalidResponse
    }

    var translatedContentHTML = sourceContentHTML
    for replacement in bodyReplacements.reversed() {
      guard let translatedText = translationsByRequestID[replacement.requestID],
            !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw RSSArticleTranslationError.invalidResponse
      }

      let start = translatedContentHTML.index(
        translatedContentHTML.startIndex,
        offsetBy: replacement.startOffset
      )
      let end = translatedContentHTML.index(
        translatedContentHTML.startIndex,
        offsetBy: replacement.endOffset
      )
      translatedContentHTML.replaceSubrange(
        start..<end,
        with: Self.escapedHTMLText(translatedText)
      )
    }

    return RSSArticleTranslationResult(
      articleID: articleID,
      target: target,
      translatedTitle: translatedTitle.trimmingCharacters(in: .whitespacesAndNewlines),
      translatedContentHTML: translatedContentHTML,
      providerName: providerName,
      model: model,
      sourceCharacterCount: sourceCharacterCount,
      wasInputTruncated: wasInputTruncated
    )
  }

  private static let titleRequestID = "title"

  fileprivate struct BodyReplacement: Hashable, Sendable {
    let requestID: String
    let startOffset: Int
    let endOffset: Int
  }

  private static func escapedHTMLText(_ value: String) -> String {
    value.reduce(into: "") { result, character in
      switch character {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "'": result += "&#39;"
      default: result.append(character)
      }
    }
  }
}

/// Builds a safe, platform-independent request plan for an RSS article.
public enum RSSArticleSystemTranslationPlanningService {
  /// The same total source safety bound used by the existing AI translator.
  public static let maximumSourceCharacterCount = 60_000

  private static let titleCharacterLimit = 500

  public static func makePlan(
    article: RSSArticle,
    target: RSSArticleTranslationTarget
  ) throws -> RSSArticleSystemTranslationPlan {
    let title = article.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let sourceHTML = article.contentHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? article.summaryHTML
      : article.contentHTML
    let body = sourceHTML.trimmingCharacters(in: .whitespacesAndNewlines)

    guard !title.isEmpty, !body.isEmpty, !target.displayName.isEmpty else {
      throw RSSArticleTranslationError.emptyArticle
    }

    let limitedTitle = String(title.prefix(titleCharacterLimit))
    let availableBodyCharacterCount = max(
      0,
      maximumSourceCharacterCount - limitedTitle.count
    )
    let parsedNodes = RSSArticleHTMLTranslationParser.visibleTextNodes(in: body)
    let wasInputTruncated = title.count > titleCharacterLimit
      || body.count > availableBodyCharacterCount

    var requests = [RSSArticleTranslationTextRequest(
      id: "title",
      sourceText: RSSArticleHTMLTranslationParser.decodeHTMLEntities(limitedTitle)
    )]
    var replacements = [RSSArticleSystemTranslationPlan.BodyReplacement]()
    var visibleNodeIndex = 0

    for node in parsedNodes {
      defer { visibleNodeIndex += 1 }
      guard node.endOffset <= availableBodyCharacterCount else { continue }

      let requestID = "body.\(visibleNodeIndex)"
      requests.append(
        RSSArticleTranslationTextRequest(
          id: requestID,
          sourceText: node.decodedText
        )
      )
      replacements.append(
        RSSArticleSystemTranslationPlan.BodyReplacement(
          requestID: requestID,
          startOffset: node.startOffset,
          endOffset: node.endOffset
        )
      )
    }

    return RSSArticleSystemTranslationPlan(
      articleID: article.id,
      target: target,
      requests: requests,
      sourceCharacterCount: limitedTitle.count + body.count,
      wasInputTruncated: wasInputTruncated,
      sourceContentHTML: body,
      bodyReplacements: replacements
    )
  }
}

private struct RSSArticleHTMLTextNode: Sendable {
  let startOffset: Int
  let endOffset: Int
  let decodedText: String
}

private enum RSSArticleHTMLTranslationParser {
  private static let excludedElementNames: Set<String> = [
    "script", "style", "noscript", "pre", "code", "textarea", "svg", "math",
  ]

  private static let voidElementNames: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
    "param", "source", "track", "wbr",
  ]

  private struct OpenElement {
    let name: String
    let excluded: Bool
  }

  static func visibleTextNodes(in source: String) -> [RSSArticleHTMLTextNode] {
    var nodes = [RSSArticleHTMLTextNode]()
    var openElements = [OpenElement]()
    var cursor = source.startIndex

    while cursor < source.endIndex {
      if source[cursor] != "<" {
        let textStart = cursor
        while cursor < source.endIndex, source[cursor] != "<" {
          cursor = source.index(after: cursor)
        }
        appendTextNode(
          from: source,
          start: textStart,
          end: cursor,
          isExcluded: openElements.contains { $0.excluded },
          to: &nodes
        )
        continue
      }

      if source[cursor...].hasPrefix("<!--") {
        cursor = endOfDelimitedToken(
          in: source,
          from: cursor,
          delimiter: "-->"
        )
        continue
      }
      if source[cursor...].hasPrefix("<![CDATA[") {
        cursor = endOfDelimitedToken(
          in: source,
          from: cursor,
          delimiter: "]]>"
        )
        continue
      }
      if source[cursor...].hasPrefix("<!") || source[cursor...].hasPrefix("<?") {
        cursor = tagTokenEnd(in: source, from: cursor) ?? source.endIndex
        continue
      }

      guard looksLikeTagStart(in: source, at: cursor),
            let tokenEnd = tagTokenEnd(in: source, from: cursor),
            let tag = parseTag(String(source[cursor..<tokenEnd]))
      else {
        // A less-than sign that is not a tag is ordinary visible text. It is
        // represented separately so a translated value is escaped safely.
        let next = source.index(after: cursor)
        appendTextNode(
          from: source,
          start: cursor,
          end: next,
          isExcluded: openElements.contains { $0.excluded },
          to: &nodes
        )
        cursor = next
        continue
      }

      if tag.isClosing {
        close(tag.name, in: &openElements)
      } else if !tag.isSelfClosing, !voidElementNames.contains(tag.name) {
        openElements.append(
          OpenElement(
            name: tag.name,
            excluded: excludedElementNames.contains(tag.name)
          )
        )
      }
      cursor = tokenEnd
    }

    return nodes
  }

  private static func appendTextNode(
    from source: String,
    start: String.Index,
    end: String.Index,
    isExcluded: Bool,
    to nodes: inout [RSSArticleHTMLTextNode]
  ) {
    guard !isExcluded, start < end else { return }
    let rawText = String(source[start..<end])
    let decodedText = decodeHTMLEntities(rawText)
    guard !decodedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }
    let startOffset = source.distance(from: source.startIndex, to: start)
    let endOffset = source.distance(from: source.startIndex, to: end)
    if let previous = nodes.last, previous.endOffset == startOffset {
      nodes[nodes.count - 1] = RSSArticleHTMLTextNode(
        startOffset: previous.startOffset,
        endOffset: endOffset,
        decodedText: previous.decodedText + decodedText
      )
    } else {
      nodes.append(
        RSSArticleHTMLTextNode(
          startOffset: startOffset,
          endOffset: endOffset,
          decodedText: decodedText
        )
      )
    }
  }

  private struct ParsedTag {
    let name: String
    let isClosing: Bool
    let isSelfClosing: Bool
  }

  private static func parseTag(_ rawTag: String) -> ParsedTag? {
    var cursor = rawTag.startIndex
    guard cursor < rawTag.endIndex, rawTag[cursor] == "<" else { return nil }
    cursor = rawTag.index(after: cursor)

    var isClosing = false
    if cursor < rawTag.endIndex, rawTag[cursor] == "/" {
      isClosing = true
      cursor = rawTag.index(after: cursor)
    }

    while cursor < rawTag.endIndex, rawTag[cursor].isWhitespace {
      cursor = rawTag.index(after: cursor)
    }
    let nameStart = cursor
    while cursor < rawTag.endIndex {
      let character = rawTag[cursor]
      guard character.isLetter || character.isNumber || character == ":"
        || character == "-" || character == "_"
      else { break }
      cursor = rawTag.index(after: cursor)
    }
    guard nameStart < cursor else { return nil }

    let name = String(rawTag[nameStart..<cursor]).lowercased()
    let endWithoutWhitespace = rawTag[..<rawTag.index(before: rawTag.endIndex)]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let isSelfClosing = !isClosing && endWithoutWhitespace.hasSuffix("/")
    return ParsedTag(name: name, isClosing: isClosing, isSelfClosing: isSelfClosing)
  }

  private static func close(_ name: String, in stack: inout [OpenElement]) {
    guard let match = stack.lastIndex(where: { $0.name == name }) else { return }
    stack.removeSubrange(match..<stack.endIndex)
  }

  private static func looksLikeTagStart(in source: String, at index: String.Index) -> Bool {
    let next = source.index(after: index)
    guard next < source.endIndex else { return false }
    switch source[next] {
    case "!", "?", "/": return true
    default: return source[next].isLetter || source[next] == "_"
    }
  }

  private static func tagTokenEnd(in source: String, from start: String.Index) -> String.Index? {
    var cursor = source.index(after: start)
    var quote: Character?
    while cursor < source.endIndex {
      let character = source[cursor]
      if let currentQuote = quote {
        if character == currentQuote { quote = nil }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == ">" {
        return source.index(after: cursor)
      }
      cursor = source.index(after: cursor)
    }
    return nil
  }

  private static func endOfDelimitedToken(
    in source: String,
    from start: String.Index,
    delimiter: String
  ) -> String.Index {
    let searchStart = source.index(start, offsetBy: min(delimiter.count == 3 ? 4 : 9, source.distance(from: start, to: source.endIndex)))
    guard searchStart < source.endIndex,
          let range = source.range(of: delimiter, range: searchStart..<source.endIndex)
    else {
      return source.endIndex
    }
    return range.upperBound
  }

  private static let namedEntities: [String: String] = [
    "amp": "&", "apos": "'", "gt": ">", "lt": "<", "quot": "\"",
    "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
    "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’",
    "ldquo": "“", "rdquo": "”", "hellip": "…", "copy": "©", "reg": "®",
    "trade": "™", "bull": "•", "middot": "·", "laquo": "«", "raquo": "»",
    "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "deg": "°",
    "plusmn": "±", "times": "×", "divide": "÷", "frac12": "½", "frac14": "¼",
    "frac34": "¾", "para": "¶", "sect": "§", "micro": "µ", "le": "≤",
    "ge": "≥", "ne": "≠", "not": "¬", "and": "∧", "or": "∨",
  ]

  fileprivate static func decodeHTMLEntities(_ source: String) -> String {
    var output = ""
    var cursor = source.startIndex
    while cursor < source.endIndex {
      guard source[cursor] == "&" else {
        output.append(source[cursor])
        cursor = source.index(after: cursor)
        continue
      }

      let afterAmpersand = source.index(after: cursor)
      guard afterAmpersand < source.endIndex,
            let semicolon = source[afterAmpersand...].firstIndex(of: ";"),
            source.distance(from: afterAmpersand, to: semicolon) <= 32
      else {
        output.append("&")
        cursor = afterAmpersand
        continue
      }

      let entityBody = String(source[afterAmpersand..<semicolon])
      guard let decoded = decodeEntityBody(entityBody) else {
        output.append("&")
        cursor = afterAmpersand
        continue
      }
      output.append(contentsOf: decoded)
      cursor = source.index(after: semicolon)
    }
    return output
  }

  private static func decodeEntityBody(_ body: String) -> String? {
    if body.hasPrefix("#x") || body.hasPrefix("#X") {
      guard let value = UInt32(body.dropFirst(2), radix: 16) else { return nil }
      return validUnicodeScalar(value)
    }
    if body.hasPrefix("#") {
      guard let value = UInt32(body.dropFirst(), radix: 10) else { return nil }
      return validUnicodeScalar(value)
    }
    return namedEntities[body.lowercased()]
  }

  private static func validUnicodeScalar(_ value: UInt32) -> String? {
    guard value != 0, value <= 0x10FFFF,
          !(0xD800...0xDFFF).contains(value),
          let scalar = UnicodeScalar(value)
    else { return nil }
    return String(scalar)
  }
}
