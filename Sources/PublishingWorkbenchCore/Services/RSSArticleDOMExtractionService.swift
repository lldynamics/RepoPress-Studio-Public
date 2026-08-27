import CoreFoundation
import Foundation
import PublishingMarkdownCore

/// The result of extracting a readable article from a downloaded HTML document.
///
/// The extractor deliberately returns both the rich HTML and its plain-text
/// projection.  Callers can persist the result independently of the RSS
/// payload, while the `extractorIdentifier` and `extractorVersion` fields make
/// a future re-extraction/migration explicit.
public struct RSSArticleDOMExtractionResult: Equatable, Sendable {
  public let title: String?
  public let author: String?
  public let contentHTML: String
  public let plainText: String
  public let sourceURL: URL
  public let confidence: Double
  public let extractorIdentifier: String
  public let extractorVersion: String

  public init(
    title: String?,
    author: String?,
    contentHTML: String,
    plainText: String,
    sourceURL: URL,
    confidence: Double,
    extractorIdentifier: String,
    extractorVersion: String
  ) {
    self.title = title
    self.author = author
    self.contentHTML = contentHTML
    self.plainText = plainText
    self.sourceURL = sourceURL
    self.confidence = confidence
    self.extractorIdentifier = extractorIdentifier
    self.extractorVersion = extractorVersion
  }
}

public enum RSSArticleDOMExtractionError: Error, Equatable, Sendable {
  case invalidSourceURL
  case emptyHTML
  case unsupportedEncoding(String)
  case invalidHTML
  case documentTooComplex
  case noReadableContent

  public var localizedDescription: String {
    switch self {
    case .invalidSourceURL:
      return "全文提取需要有效的 HTTP(S) 原文链接。"
    case .emptyHTML:
      return "原文网页为空。"
    case let .unsupportedEncoding(encoding):
      return "原文网页使用了当前平台不支持的字符编码：\(encoding)。"
    case .invalidHTML:
      return "原文网页不是可解析的 HTML。"
    case .documentTooComplex:
      return "原文网页结构过于复杂，已停止全文提取。"
    case .noReadableContent:
      return "未能从原文网页中提取到可读的正文内容。"
    }
  }
}

extension RSSArticleDOMExtractionError: LocalizedError {
  public var errorDescription: String? { localizedDescription }
}

/// A local, deterministic Readability-style extractor for RSS article pages.
///
/// This service has no network or UI concerns.  It consumes an already
/// downloaded response, removes page chrome, scores DOM candidates, converts
/// the selected semantic HTML through the existing Markdown rich-text
/// pipeline, and returns a safe preview HTML representation.
public struct RSSArticleDOMExtractionService: Sendable {
  public static let extractorIdentifier = "rss.dom.readability"
  public static let extractorVersion = "1"

  private let richTextPasteService: MarkdownRichTextPasteService

  public init() {
    self.richTextPasteService = MarkdownRichTextPasteService()
  }

  public func extract(
    data: Data,
    sourceURL: URL,
    expectedTitle: String? = nil,
    textEncodingName: String? = nil
  ) throws -> RSSArticleDOMExtractionResult {
    guard let scheme = sourceURL.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          sourceURL.host?.isEmpty == false else {
      throw RSSArticleDOMExtractionError.invalidSourceURL
    }

    guard data.count <= Self.maximumHTMLByteCount else {
      throw RSSArticleDOMExtractionError.documentTooComplex
    }

    let html = try decodeHTML(data, textEncodingName: textEncodingName)
    guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RSSArticleDOMExtractionError.emptyHTML
    }

    let normalizedHTML = normalizedHTMLForDOM(html)
    let document: XMLDocument
    do {
      document = try XMLDocument(
        xmlString: normalizedHTML,
        options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]
      )
    } catch {
      throw RSSArticleDOMExtractionError.invalidHTML
    }
    guard let root = document.rootElement() else {
      throw RSSArticleDOMExtractionError.invalidHTML
    }

    try validateDOMShape(root)

    let documentTitle = firstMetadataTitle(in: root)
    let documentAuthor = firstMetadataAuthor(in: root)

    let analysisBudget = AnalysisBudget(limit: Self.maximumAnalysisWork)
    try removeNoise(from: root, budget: analysisBudget)

    let body = firstDescendant(named: "body", in: root) ?? root
    let candidates = try collectCandidates(in: body, budget: analysisBudget)
    let bodyCandidate = Candidate(
      element: body,
      stats: try stats(for: body, budget: analysisBudget),
      semantic: false
    )
    let chosen = chooseCandidate(
      from: candidates,
      body: bodyCandidate,
      expectedTitle: expectedTitle
    )

    guard chosen.stats.visibleCharacterCount > 0 else {
      throw RSSArticleDOMExtractionError.noReadableContent
    }

    let candidateTitle = extractTitle(from: root, candidate: chosen.element)
    let pageTitle = preferredTitle(
      documentTitle: documentTitle,
      candidateTitle: candidateTitle,
      expectedTitle: expectedTitle
    )
    let author = documentAuthor ?? extractAuthor(from: root, candidate: chosen.element)
    let expectedTitleSimilarity: Double?
    if let expectedTitle {
      expectedTitleSimilarity = titleSimilarity(between: expectedTitle, and: pageTitle)
    } else {
      expectedTitleSimilarity = nil
    }
    let confidence = confidenceScore(
      for: chosen,
      titleSimilarity: expectedTitleSimilarity
    )

    if isObviousShell(
      text: chosen.stats.visibleText,
      title: pageTitle,
      expectedTitle: expectedTitle,
      stats: chosen.stats
    ) {
      throw RSSArticleDOMExtractionError.noReadableContent
    }

    let selectedHTML = serializedHTML(for: chosen.element)
    guard let conversion = richTextPasteService.conversion(
      fromHTML: selectedHTML,
      baseURL: sourceURL
    ) else {
      throw RSSArticleDOMExtractionError.noReadableContent
    }

    let contentHTML = MarkdownHTMLRenderingService
      .renderPreviewBodyAllowingSanitizedHTML(conversion.markdown)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !contentHTML.isEmpty else {
      throw RSSArticleDOMExtractionError.noReadableContent
    }

    let plainText = RSSHTMLTextSanitizer
      .plainText(from: contentHTML)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !plainText.isEmpty else {
      throw RSSArticleDOMExtractionError.noReadableContent
    }

    return RSSArticleDOMExtractionResult(
      title: pageTitle,
      author: author,
      contentHTML: contentHTML,
      plainText: plainText,
      sourceURL: sourceURL,
      confidence: confidence,
      extractorIdentifier: Self.extractorIdentifier,
      extractorVersion: Self.extractorVersion
    )
  }
}

private extension RSSArticleDOMExtractionService {
  // These limits are deliberately independent: the byte limit bounds parser
  // input, the DOM limits bound the shape libxml creates, and the analysis
  // budget bounds repeated candidate scoring on adversarial nesting.
  static let maximumHTMLByteCount = 4 * 1024 * 1024
  static let maximumDOMNodeCount = 100_000
  static let maximumDOMDepth = 256
  static let maximumAnalysisWork = 750_000
  static let maximumCandidateCount = 2_048
  static let encodingProbeByteCount = 32 * 1024

  final class AnalysisBudget {
    private var remaining: Int

    init(limit: Int) {
      self.remaining = limit
    }

    func consume(_ amount: Int = 1) throws {
      guard amount >= 0, remaining >= amount else {
        throw RSSArticleDOMExtractionError.documentTooComplex
      }
      remaining -= amount
    }
  }

  struct Candidate {
    let element: XMLElement
    let stats: CandidateStats
    let semantic: Bool
  }

  struct CandidateStats {
    var visibleText: String
    var visibleCharacterCount: Int
    var paragraphCount: Int
    var headingCount: Int
    var listItemCount: Int
    var codeBlockCount: Int
    var punctuationCount: Int
    var anchorCharacterCount: Int
    var linkCount: Int
    var positiveHintCount: Int
    var negativeHintCount: Int
    var headingText: String?

    var linkDensity: Double {
      guard visibleCharacterCount > 0 else { return 0 }
      return Double(anchorCharacterCount) / Double(visibleCharacterCount)
    }
  }

  enum DetectedEncoding {
    case ascii
    case utf8
    case utf16
    case isoLatin1
    case windowsCP1252
    case gb18030
    case gbk
    case shiftJIS

    var name: String {
      switch self {
      case .ascii: "US-ASCII"
      case .utf8: "UTF-8"
      case .utf16: "UTF-16"
      case .isoLatin1: "ISO-8859-1"
      case .windowsCP1252: "Windows-1252"
      case .gb18030: "GB18030"
      case .gbk: "GBK"
      case .shiftJIS: "Shift_JIS"
      }
    }

    var foundationEncoding: String.Encoding {
      switch self {
      case .ascii:
        return .ascii
      case .utf8:
        return .utf8
      case .utf16:
        return .utf16
      case .isoLatin1:
        return .isoLatin1
      case .windowsCP1252:
        return .windowsCP1252
      case .gb18030:
        return String.Encoding(
          rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
          )
        )
      case .gbk:
        return String.Encoding(
          rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GBK_95.rawValue)
          )
        )
      case .shiftJIS:
        return .shiftJIS
      }
    }
  }

  struct EncodingCandidate {
    let encoding: DetectedEncoding
    let score: Double
    let order: Int
  }

  static let dangerousElementNames: Set<String> = [
    "applet", "base", "button", "canvas", "embed", "form", "head", "iframe",
    "input", "link", "meta", "noscript", "object", "option", "script", "select",
    "style", "svg", "template", "textarea", "video",
  ]

  static let semanticMarkerAttribute = "data-rss-original-tag"
  static let semanticHTMLTags = ["article", "main", "section", "nav", "aside", "footer", "header"]

  static let negativeHintFragments: [String] = [
    "advert", "banner", "breadcrumb", "captcha", "comment", "consent", "cookie",
    "error", "login", "modal", "nav", "newsletter", "notfound", "paywall", "popup",
    "promo", "recommend", "register", "related", "share", "sidebar", "signin",
    "signup", "social", "sponsor", "subscribe", "toc",
  ]

  static let positiveHintFragments: [String] = [
    "article", "body", "content", "entry", "main", "markdown", "post", "prose",
    "richtext", "story", "text",
  ]

  static let shellFragments: [String] = [
    "access denied", "captcha", "cookie settings", "enable javascript", "forbidden",
    "log in", "login", "not found", "page not found", "paywall", "please sign in",
    "register", "sign in", "subscribe to continue", "unauthorized",
    "验证", "登录", "登入", "注册", "访问被拒绝", "未找到页面", "验证码", "订阅后继续",
  ]

  func decodeHTML(_ data: Data, textEncodingName: String?) throws -> String {
    guard !data.isEmpty else { throw RSSArticleDOMExtractionError.emptyHTML }

    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      guard let value = String(data: data.dropFirst(3), encoding: .utf8) else {
        throw RSSArticleDOMExtractionError.unsupportedEncoding("UTF-8")
      }
      return value
    }
    if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
      guard let value = String(data: data, encoding: .utf16) else {
        throw RSSArticleDOMExtractionError.unsupportedEncoding("UTF-16")
      }
      return value
    }

    if let textEncodingName = textEncodingName?.trimmingCharacters(
      in: .whitespacesAndNewlines
    ), !textEncodingName.isEmpty {
      guard let encoding = encoding(for: textEncodingName) else {
        throw RSSArticleDOMExtractionError.unsupportedEncoding(textEncodingName)
      }
      guard let value = String(data: data, encoding: encoding.foundationEncoding) else {
        throw RSSArticleDOMExtractionError.unsupportedEncoding(encoding.name)
      }
      return value
    }

    let declaredName = declaredCharset(in: data)
    if let declaredName {
      guard let encoding = encoding(for: declaredName) else {
        throw RSSArticleDOMExtractionError.unsupportedEncoding(declaredName)
      }
      guard let value = String(data: data, encoding: encoding.foundationEncoding) else {
        throw RSSArticleDOMExtractionError.unsupportedEncoding(encoding.name)
      }
      return value
    }

    return try decodeUndeclaredHTML(data)
  }

  func decodeUndeclaredHTML(_ data: Data) throws -> String {
    // Single-byte encodings can decode almost every byte sequence, so trying
    // Windows-1252 first silently turns GBK/GB18030 and Shift_JIS pages into
    // mojibake. Rank a bounded probe instead, then decode the complete body
    // only with the most plausible candidates.
    let encodings: [DetectedEncoding] = [
      .utf8, .gb18030, .gbk, .shiftJIS, .windowsCP1252, .isoLatin1,
    ]
    let ranked = encodings.enumerated().compactMap { index, encoding -> EncodingCandidate? in
      guard let value = encodingProbeText(in: data, encoding: encoding),
            !value.isEmpty,
            looksLikeHTML(value) else {
        return nil
      }
      return EncodingCandidate(
        encoding: encoding,
        score: encodingPlausibilityScore(value, encoding: encoding),
        order: index
      )
    }.sorted { lhs, rhs in
      if lhs.score == rhs.score { return lhs.order < rhs.order }
      return lhs.score > rhs.score
    }

    for candidate in ranked {
      guard let value = String(data: data, encoding: candidate.encoding.foundationEncoding),
            !value.isEmpty,
            looksLikeHTML(value) else {
        continue
      }
      return value
    }
    throw RSSArticleDOMExtractionError.unsupportedEncoding("unknown")
  }

  func encodingProbeText(in data: Data, encoding: DetectedEncoding) -> String? {
    let prefixCount = min(Self.encodingProbeByteCount, data.count)
    var segments = [Data(data.prefix(prefixCount))]
    if data.count > prefixCount {
      segments.append(Data(data.suffix(Self.encodingProbeByteCount)))
    }
    let decoded = segments.compactMap {
      decodeProbeSegment($0, encoding: encoding.foundationEncoding)
    }
    guard !decoded.isEmpty else { return nil }
    return decoded.joined(separator: "\n")
  }

  func decodeProbeSegment(_ data: Data, encoding: String.Encoding) -> String? {
    // A bounded probe can begin or end halfway through a multibyte sequence
    // (the suffix is cut from an arbitrary byte offset). Trim at most four
    // bytes on either side rather than rejecting an otherwise valid candidate
    // because of an artificial boundary.
    for leadingTrim in 0...4 where leadingTrim <= data.count {
      let leading = Data(data.dropFirst(leadingTrim))
      for trailingTrim in 0...4 where trailingTrim <= leading.count {
        let count = leading.count - trailingTrim
        if let value = String(data: leading.prefix(count), encoding: encoding), !value.isEmpty {
          return value
        }
      }
    }
    return nil
  }

  func encodingPlausibilityScore(_ value: String, encoding: DetectedEncoding) -> Double {
    let scalars = value.unicodeScalars
    let lowercased = value.lowercased()
    let htmlMarkers = ["<html", "<head", "<body", "<article", "<main", "<p", "</p>"]
      .reduce(into: 0) { count, marker in
        if lowercased.contains(marker) { count += 1 }
      }
    let hanCount = scalars.reduce(into: 0) { count, scalar in
      if isHan(scalar) { count += 1 }
    }
    let kanaCount = scalars.reduce(into: 0) { count, scalar in
      if isJapaneseKana(scalar) { count += 1 }
    }
    let punctuationCount = scalars.reduce(into: 0) { count, scalar in
      if CharacterSet.punctuationCharacters.contains(scalar) { count += 1 }
    }
    let controlCount = scalars.reduce(into: 0) { count, scalar in
      if (0x80...0x9F).contains(scalar.value) { count += 1 }
    }
    let mojibakeCount = ["Ã", "Â", "â", "ð", "縺", "繧", "�"]
      .reduce(into: 0) { count, marker in count += value.filter { String($0) == marker }.count }

    var score = Double(htmlMarkers) * 2.0
    score += min(10.0, Double(hanCount) * 0.12)
    score += min(10.0, Double(kanaCount) * 0.20)
    score += min(3.0, Double(punctuationCount) * 0.04)
    score -= min(12.0, Double(controlCount) * 0.75)
    score -= min(8.0, Double(mojibakeCount) * 0.12)

    switch encoding {
    case .utf8:
      // A fully valid UTF-8 page is the most common and lossless case. Keep it
      // ahead of a legacy decoder when both happen to produce valid Unicode.
      score += 1.5
    case .gb18030, .gbk:
      score += min(3.0, Double(hanCount) * 0.18)
      score -= min(4.0, Double(kanaCount) * 0.10)
    case .shiftJIS:
      // Kana is a useful discriminator because GBK/GB18030 can otherwise
      // produce plausible-looking Han characters from some Shift_JIS bytes.
      score += min(5.0, Double(kanaCount) * 0.35)
    case .ascii, .isoLatin1, .windowsCP1252:
      score -= min(6.0, Double(hanCount + kanaCount) * 0.18)
    case .utf16:
      break
    }
    return score
  }

  func isHan(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    return (0x3400...0x4DBF).contains(value)
      || (0x4E00...0x9FFF).contains(value)
      || (0xF900...0xFAFF).contains(value)
  }

  func isJapaneseKana(_ scalar: UnicodeScalar) -> Bool {
    let value = scalar.value
    return (0x3040...0x309F).contains(value)
      || (0x30A0...0x30FF).contains(value)
      || (0x31F0...0x31FF).contains(value)
      || (0xFF66...0xFF9D).contains(value)
  }

  func declaredCharset(in data: Data) -> String? {
    // Charset declarations are ASCII even when the document body is not. Map
    // non-ASCII bytes to spaces so a legacy body cannot hide the declaration.
    let prefix = data.prefix(16 * 1_024).map { byte in
      byte < 0x80 ? byte : 0x20
    }
    guard let probe = String(bytes: prefix, encoding: .ascii) else { return nil }

    let patterns = [
      #"<meta\b[^>]*\bcharset\s*=\s*[\"']?\s*([A-Za-z0-9._:-]+)"#,
      #"<meta\b[^>]*\bcontent\s*=\s*[\"'][^\"']*?\bcharset\s*=\s*([A-Za-z0-9._:-]+)"#,
    ]
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(
        pattern: pattern,
        options: [.caseInsensitive]
      ) else { continue }
      let range = NSRange(probe.startIndex..., in: probe)
      guard let match = expression.firstMatch(in: probe, range: range),
            let valueRange = Range(match.range(at: 1), in: probe) else { continue }
      return String(probe[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return nil
  }

  func encoding(for rawName: String) -> DetectedEncoding? {
    let normalized = rawName
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "")
    switch normalized {
    case "us-ascii", "ascii":
      return .ascii
    case "utf-8", "utf8":
      return .utf8
    case "utf-16", "utf16", "unicode":
      return .utf16
    case "iso-8859-1", "iso8859-1", "iso88591", "latin1", "l1":
      return .isoLatin1
    case "windows-1252", "cp1252", "windows1252":
      return .windowsCP1252
    case "gb18030", "gb-18030", "gb18030-2000", "gb18030-2005":
      return .gb18030
    case "gbk", "x-gbk", "cp936", "ms936", "gb2312", "gb-2312", "gb-2312-80":
      return .gbk
    case "shift-jis", "shiftjis", "sjis", "x-sjis", "ms-kanji":
      return .shiftJIS
    default:
      return nil
    }
  }

  func looksLikeHTML(_ value: String) -> Bool {
    let lowercased = value.lowercased()
    return lowercased.contains("<html") || lowercased.contains("<body")
      || lowercased.contains("<article") || lowercased.contains("<div")
      || lowercased.contains("<section") || lowercased.contains("<p")
      || lowercased.contains("<h1") || lowercased.contains("<!doctype")
  }

  /// libxml's HTML tidy mode predates several HTML5 sectioning elements and
  /// can flatten them. Preserve their boundaries with ordinary `div` nodes so
  /// the DOM scorer still sees article/main/section/nav semantics. The marker
  /// is ignored by the Markdown conversion and never becomes visible output.
  func normalizedHTMLForDOM(_ html: String) -> String {
    var normalized = html
    for tag in Self.semanticHTMLTags {
      normalized = normalized.replacingOccurrences(
        of: "<\\s*\(tag)\\b",
        with: "<div \(Self.semanticMarkerAttribute)=\"\(tag)\"",
        options: [.regularExpression, .caseInsensitive]
      )
      normalized = normalized.replacingOccurrences(
        of: "<\\s*/\\s*\(tag)\\s*>",
        with: "</div>",
        options: [.regularExpression, .caseInsensitive]
      )
    }
    return normalized
  }

  func validateDOMShape(_ root: XMLElement) throws {
    var nodeCount = 0

    func visit(_ node: XMLNode, elementDepth: Int) throws {
      nodeCount += 1
      guard nodeCount <= Self.maximumDOMNodeCount else {
        throw RSSArticleDOMExtractionError.documentTooComplex
      }
      guard let element = node as? XMLElement else { return }
      guard elementDepth <= Self.maximumDOMDepth else {
        throw RSSArticleDOMExtractionError.documentTooComplex
      }
      for child in element.children ?? [] {
        try visit(
          child,
          elementDepth: child is XMLElement ? elementDepth + 1 : elementDepth
        )
      }
    }

    try visit(root, elementDepth: 0)
  }

  func removeNoise(from element: XMLElement, budget: AnalysisBudget) throws {
    for child in element.children ?? [] {
      try budget.consume()
      if child.kind == .comment {
        remove(child, from: element)
        continue
      }
      guard let childElement = child as? XMLElement else { continue }
      let name = elementName(childElement)
      if shouldRemove(childElement, name: name) {
        remove(child, from: element)
      } else {
        try removeNoise(from: childElement, budget: budget)
      }
    }
  }

  func remove(_ child: XMLNode, from parent: XMLElement) {
    guard let index = parent.children?.firstIndex(where: { $0 === child }) else { return }
    parent.removeChild(at: index)
  }

  func shouldRemove(_ element: XMLElement, name: String) -> Bool {
    let structuralName = structuralName(of: element)
    if Self.dangerousElementNames.contains(name)
      || ["aside", "footer", "nav"].contains(structuralName) {
      return true
    }
    if element.attribute(forName: "aria-hidden")?.stringValue?.lowercased() == "true"
      || element.attribute(forName: "hidden") != nil {
      return true
    }
    let inlineStyle = attributeValue("style", on: element)?
      .lowercased()
      .filter { !$0.isWhitespace }
    if inlineStyle?.contains("display:none") == true
      || inlineStyle?.contains("visibility:hidden") == true {
      return true
    }
    let role = attributeValue("role", on: element)?.lowercased()
    if ["banner", "complementary", "contentinfo", "navigation"].contains(role) {
      return true
    }

    let hints = hintText(for: element)
    if containsNegativeHint(hints) {
      return true
    }
    return false
  }

  func collectCandidates(in body: XMLElement, budget: AnalysisBudget) throws -> [Candidate] {
    var candidates: [Candidate] = []
    func visit(_ element: XMLElement) throws {
      try budget.consume()
      let name = elementName(element)
      let role = attributeValue("role", on: element)?.lowercased()
      let structuralName = self.structuralName(of: element)
      let semantic = structuralName == "article" || structuralName == "main" || role == "main"
      let isGeneric = name == "div" || name == "section"
      if semantic || isGeneric {
        let stats = try self.stats(for: element, budget: budget)
        let hasPositiveHint = stats.positiveHintCount > 0
        let hasParagraphs = stats.paragraphCount > 0 && stats.visibleCharacterCount >= 18
        if semantic || hasPositiveHint || hasParagraphs {
          guard candidates.count < Self.maximumCandidateCount else {
            throw RSSArticleDOMExtractionError.documentTooComplex
          }
          candidates.append(Candidate(element: element, stats: stats, semantic: semantic))
        }
      }
      for child in element.children ?? [] {
        if let childElement = child as? XMLElement {
          try visit(childElement)
        }
      }
    }
    try visit(body)
    return candidates
  }

  func chooseCandidate(
    from candidates: [Candidate],
    body: Candidate,
    expectedTitle: String?
  ) -> Candidate {
    guard !candidates.isEmpty else { return body }

    let ranked = candidates.sorted {
      candidateScore($0, expectedTitle: expectedTitle)
        > candidateScore($1, expectedTitle: expectedTitle)
    }
    guard let best = ranked.first else { return body }

    // Semantic containers get first refusal. A short article is still a valid
    // article; length is a confidence signal, not a hard 500-character gate.
    if best.semantic && best.stats.visibleCharacterCount >= 12 {
      return best
    }

    let bodyScore = candidateScore(body, expectedTitle: expectedTitle)
    let bestScore = candidateScore(best, expectedTitle: expectedTitle)
    return bestScore >= max(0.10, bodyScore * 0.70) ? best : body
  }

  func candidateScore(_ candidate: Candidate, expectedTitle: String?) -> Double {
    let stats = candidate.stats
    guard stats.visibleCharacterCount > 0 else { return 0 }

    let lengthScore = min(0.30, sqrt(Double(stats.visibleCharacterCount) / 600.0) * 0.30)
    let paragraphScore = min(0.22, Double(stats.paragraphCount) * 0.035)
    let punctuationScore = min(0.15, Double(stats.punctuationCount) / 34.0 * 0.15)
    let structureScore = min(
      0.13,
      Double(stats.headingCount) * 0.035
        + Double(stats.listItemCount) * 0.008
        + Double(stats.codeBlockCount) * 0.02
    )
    let semanticScore = candidate.semantic ? 0.16 : 0
    let positiveScore = min(0.14, Double(stats.positiveHintCount) * 0.035)
    let linkPenalty = min(0.40, max(0, stats.linkDensity - 0.12) * 0.62)
    let negativePenalty = min(0.40, Double(stats.negativeHintCount) * 0.09)

    var score = 0.04 + lengthScore + paragraphScore + punctuationScore + structureScore
      + semanticScore + positiveScore - linkPenalty - negativePenalty
    if let expectedTitle,
       !expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let headingOrText = stats.headingText ?? stats.visibleText
      let similarity = titleSimilarity(between: expectedTitle, and: headingOrText)
      if similarity < 0.20 {
        score -= 0.16
      } else if similarity > 0.65 {
        score += 0.06
      }
    }
    return min(1, max(0, score))
  }

  func confidenceScore(for candidate: Candidate, titleSimilarity: Double?) -> Double {
    var score = candidateScore(candidate, expectedTitle: nil)
    if let titleSimilarity {
      if titleSimilarity < 0.20 {
        score -= 0.20
      } else if titleSimilarity > 0.65 {
        score += 0.06
      }
    }
    return min(1, max(0, score))
  }

  func stats(for element: XMLElement, budget: AnalysisBudget) throws -> CandidateStats {
    var stats = CandidateStats(
      visibleText: "",
      visibleCharacterCount: 0,
      paragraphCount: 0,
      headingCount: 0,
      listItemCount: 0,
      codeBlockCount: 0,
      punctuationCount: 0,
      anchorCharacterCount: 0,
      linkCount: 0,
      positiveHintCount: 0,
      negativeHintCount: 0,
      headingText: nil
    )

    let hints = hintText(for: element)
    stats.positiveHintCount = positiveHintCount(in: hints)
    stats.negativeHintCount = negativeHintCount(in: hints)

    func visit(_ node: XMLNode, insideAnchor: Bool) throws {
      try budget.consume()
      guard node.kind != .comment else { return }
      if let child = node as? XMLElement {
        let name = elementName(child)
        let structuralName = self.structuralName(of: child)
        if Self.dangerousElementNames.contains(name) || ["aside", "footer", "nav"].contains(structuralName) {
          return
        }
        switch name {
        case "p": stats.paragraphCount += 1
        case "h1", "h2", "h3", "h4", "h5", "h6":
          stats.headingCount += 1
          if stats.headingText == nil {
            stats.headingText = normalizedText(child.stringValue ?? "").nilIfEmpty
          }
        case "li": stats.listItemCount += 1
        case "pre": stats.codeBlockCount += 1
        case "a":
          stats.linkCount += 1
          for childNode in child.children ?? [] {
            try visit(childNode, insideAnchor: true)
          }
          return
        default: break
        }
        for childNode in child.children ?? [] {
          try visit(childNode, insideAnchor: insideAnchor)
        }
      } else if node.kind == .text, let raw = node.stringValue {
        let text = normalizedText(raw)
        guard !text.isEmpty else { return }
        stats.visibleText += text + " "
        stats.visibleCharacterCount += text.count
        if insideAnchor {
          stats.anchorCharacterCount += text.count
        }
        stats.punctuationCount += text.unicodeScalars.reduce(into: 0) { count, scalar in
          if CharacterSet.punctuationCharacters.contains(scalar) {
            count += 1
          }
        }
      }
    }

    try visit(element, insideAnchor: false)
    stats.visibleText = normalizedText(stats.visibleText)
    return stats
  }

  func extractTitle(from root: XMLElement, candidate: XMLElement) -> String? {
    let metadataNames = ["og:title", "twitter:title", "title"]
    for name in metadataNames {
      if let value = firstMetaValue(named: name, in: root) {
        return value
      }
    }
    if let heading = firstHeadingText(in: candidate) {
      return heading
    }
    if let titleElement = firstDescendant(named: "title", in: root),
       let value = normalizedText(textContent(of: titleElement)).nilIfEmpty {
      return value
    }
    return nil
  }

  func preferredTitle(
    documentTitle: String?,
    candidateTitle: String?,
    expectedTitle: String?
  ) -> String? {
    guard let documentTitle else { return candidateTitle }
    guard let candidateTitle,
          let expectedTitle,
          !expectedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return documentTitle
    }
    let documentSimilarity = titleSimilarity(between: expectedTitle, and: documentTitle)
    let candidateSimilarity = titleSimilarity(between: expectedTitle, and: candidateTitle)
    return candidateSimilarity >= documentSimilarity + 0.15 ? candidateTitle : documentTitle
  }

  func firstMetadataTitle(in root: XMLElement) -> String? {
    for name in ["og:title", "twitter:title", "title"] {
      if let value = firstMetaValue(named: name, in: root) {
        return value
      }
    }
    if let titleElement = firstDescendant(named: "title", in: root) {
      return normalizedText(textContent(of: titleElement)).nilIfEmpty
    }
    return nil
  }

  func firstMetadataAuthor(in root: XMLElement) -> String? {
    for name in ["author", "article:author", "byl"] {
      if let value = firstMetaValue(named: name, in: root) {
        return value
      }
    }
    return nil
  }

  func extractAuthor(from root: XMLElement, candidate: XMLElement) -> String? {
    for name in ["author", "article:author", "byl"] {
      if let value = firstMetaValue(named: name, in: root) {
        return value
      }
    }
    let authorElement = firstElement(
      in: candidate,
      where: { element in
        let rel = attributeValue("rel", on: element)?.lowercased() ?? ""
        let itemProp = attributeValue("itemprop", on: element)?.lowercased() ?? ""
        let hints = hintText(for: element)
        return rel.split(separator: " ").contains("author")
          || itemProp.split(separator: " ").contains("author")
          || hints.split(separator: " ").contains("author")
      }
    )
    return authorElement.flatMap { normalizedText(textContent(of: $0)).nilIfEmpty }
  }

  func firstMetaValue(named name: String, in root: XMLElement) -> String? {
    let lowercasedName = name.lowercased()
    let candidates = descendants(of: root).compactMap { $0 as? XMLElement }
    for element in candidates where elementName(element) == "meta" {
      let key = attributeValue("name", on: element)?.lowercased()
        ?? attributeValue("property", on: element)?.lowercased()
      guard key == lowercasedName,
            let content = attributeValue("content", on: element) else { continue }
      if let value = normalizedText(content).nilIfEmpty { return value }
    }
    return nil
  }

  func firstHeadingText(in element: XMLElement) -> String? {
    for descendant in descendants(of: element) {
      guard let child = descendant as? XMLElement else { continue }
      let name = elementName(child)
      guard ["h1", "h2", "h3"].contains(name) else { continue }
      if let value = normalizedText(textContent(of: child)).nilIfEmpty {
        return value
      }
    }
    return nil
  }

  func firstElement(
    in root: XMLElement,
    where predicate: (XMLElement) -> Bool
  ) -> XMLElement? {
    for descendant in descendants(of: root) {
      if let element = descendant as? XMLElement, predicate(element) {
        return element
      }
    }
    return nil
  }

  func firstDescendant(named name: String, in root: XMLElement) -> XMLElement? {
    let wanted = name.lowercased()
    return firstElement(in: root) { elementName($0) == wanted }
  }

  func descendants(of root: XMLElement) -> [XMLNode] {
    var result: [XMLNode] = []
    func visit(_ element: XMLElement) {
      for child in element.children ?? [] {
        result.append(child)
        if let childElement = child as? XMLElement {
          visit(childElement)
        }
      }
    }
    visit(root)
    return result
  }

  func textContent(of node: XMLNode) -> String {
    var result = ""
    func visit(_ current: XMLNode) {
      guard current.kind != .comment else { return }
      if let element = current as? XMLElement {
        let name = elementName(element)
        let structuralName = self.structuralName(of: element)
        if Self.dangerousElementNames.contains(name) || ["aside", "footer", "nav"].contains(structuralName) {
          return
        }
        for child in element.children ?? [] {
          visit(child)
        }
      } else if current.kind == .text {
        result += current.stringValue ?? ""
        result += " "
      }
    }
    visit(node)
    return normalizedText(result)
  }

  func serializedHTML(for element: XMLElement) -> String {
    // XMLDocument's tidy parser normalizes malformed markup and escapes text;
    // all executable/noise elements have already been removed above.
    element.xmlString
  }

  func hintText(for element: XMLElement) -> String {
    [
      attributeValue("id", on: element),
      attributeValue("class", on: element),
      attributeValue("data-testid", on: element),
      attributeValue("data-component", on: element),
    ]
    .compactMap { $0?.lowercased() }
    .joined(separator: " ")
  }

  func containsNegativeHint(_ hints: String) -> Bool {
    let tokens = Set(hints.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    return Self.negativeHintFragments.contains { fragment in
      tokens.contains(fragment) || hints.contains(fragment)
    }
  }

  func positiveHintCount(in hints: String) -> Int {
    let tokens = Set(hints.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    return Self.positiveHintFragments.reduce(into: 0) { count, fragment in
      if tokens.contains(fragment) || hints.contains(fragment) { count += 1 }
    }
  }

  func negativeHintCount(in hints: String) -> Int {
    let tokens = Set(hints.split { !$0.isLetter && !$0.isNumber }.map(String.init))
    return Self.negativeHintFragments.reduce(into: 0) { count, fragment in
      if tokens.contains(fragment) || hints.contains(fragment) { count += 1 }
    }
  }

  func attributeValue(_ name: String, on element: XMLElement) -> String? {
    element.attribute(forName: name)?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func structuralName(of element: XMLElement) -> String {
    attributeValue(Self.semanticMarkerAttribute, on: element)?.lowercased()
      ?? elementName(element)
  }

  func elementName(_ element: XMLElement) -> String {
    element.name?.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
  }

  func normalizedText(_ source: String) -> String {
    source
      .replacingOccurrences(of: "\u{00A0}", with: " ")
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: .newlines)
      .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ") }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func titleSimilarity(between lhs: String, and rhs: String?) -> Double {
    guard let rhs,
          let left = normalizedTitle(lhs).nilIfEmpty,
          let right = normalizedTitle(rhs).nilIfEmpty else { return 0 }
    if left == right || left.contains(right) || right.contains(left) { return 1 }
    let leftCharacters = Set(left)
    let rightCharacters = Set(right)
    guard !leftCharacters.isEmpty, !rightCharacters.isEmpty else { return 0 }
    return Double(leftCharacters.intersection(rightCharacters).count)
      / Double(leftCharacters.union(rightCharacters).count)
  }

  func normalizedTitle(_ title: String) -> String {
    title
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  func isObviousShell(
    text: String,
    title: String?,
    expectedTitle: String?,
    stats: CandidateStats
  ) -> Bool {
    let normalized = text.lowercased()
    let shellHit = Self.shellFragments.contains { normalized.contains($0.lowercased()) }
    let short = stats.visibleCharacterCount < 18
    let linkHeavy = stats.linkDensity >= 0.70
    let titleLooksLikeShell = title.map { titleValue in
      Self.shellFragments.contains { titleValue.lowercased().contains($0.lowercased()) }
    } ?? false
    let mismatch = expectedTitle.map {
      titleSimilarity(between: $0, and: title) < 0.10
    } ?? false
    return titleLooksLikeShell || (shellHit && (short || linkHeavy || mismatch)) || (short && linkHeavy)
  }
}

private extension Optional where Wrapped == String {
  var nilIfEmpty: String? {
    guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
      return nil
    }
    return value
  }
}
