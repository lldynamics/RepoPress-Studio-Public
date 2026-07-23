import Foundation

struct KnowledgeWebSanitizedContent: Sendable {
  var title: String?
  var authors: [String]
  var language: String?
  var summary: String
  var sections: [KnowledgeExtractedSection]
  var removedNoiseBlockCount: Int
  var selectedMainContent: Bool
}

/// Extracts durable reading text from HTML without executing or loading page resources.
///
/// The sanitizer prefers semantic `article`/`main` roots, removes common chrome and
/// interaction blocks, and keeps headings and paragraphs as separate sections for
/// chunking. The original HTML remains untouched in the library blob store.
struct KnowledgeWebContentSanitizer: Sendable {
  func sanitize(data: Data, sourceName: String) throws -> KnowledgeWebSanitizedContent {
    let html = decodedHTMLSource(from: data)
    guard !html.isEmpty else { throw KnowledgeLibraryError.unreadableSource(sourceName) }
    return sanitize(html: html)
  }

  func sanitize(html: String) -> KnowledgeWebSanitizedContent {
    let title = metadataValue(
      in: html,
      names: ["og:title", "twitter:title"]
    ) ?? firstCapture(in: html, pattern: "<title\\b[^>]*>([\\s\\S]*?)</title>")
      .map { normalizedInline(stripTags($0)) }
      .flatMap(\.nilIfEmpty)
    let authors = metadataValues(
      in: html,
      names: ["author", "article:author", "byl"]
    )
    let summary = metadataValue(
      in: html,
      names: ["description", "og:description", "twitter:description"]
    ) ?? ""
    let language = firstCapture(
      in: html,
      pattern: "<html\\b[^>]*\\blang\\s*=\\s*[\\\"']([^\\\"']+)[\\\"']"
    )?.trimmedForPublishing.nilIfEmpty

    let rootSelection = selectReadingRoot(in: html)
    var body = rootSelection.html
    var removedNoiseBlockCount = 0
    body = removePattern("<!--[\\s\\S]*?-->", from: body, count: &removedNoiseBlockCount)

    let ignoredTags = [
      "script", "style", "noscript", "template", "svg", "canvas", "iframe",
      "object", "embed", "form", "nav", "footer", "aside", "dialog",
    ]
    for tag in ignoredTags {
      body = removePattern(
        "<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>",
        from: body,
        count: &removedNoiseBlockCount
      )
    }

    let noiseTokens = "nav|menu|sidebar|footer|advert(?:isement)?|ads?|promo|cookie|consent|share|social|related|recommend(?:ed|ation)?|comment|popup|modal|newsletter|subscribe|paywall|breadcrumb|toolbar|(?:engagement|interaction|reaction)[-_ ]?(?:bar|count|metrics|stats|summary)|action[-_ ]?bar|(?:view|reply|like|repost|retweet)[-_ ]?count|(?:post|tweet)[-_ ]?(?:actions?|stats?)"
    let attributedNoisePattern = "<(div|section|ul|ol|p|button)\\b[^>]*(?:id|class|role|aria-label)\\s*=\\s*[\\\"'][^\\\"']*(?:\(noiseTokens))[^\\\"']*[\\\"'][^>]*>[\\s\\S]*?</\\1\\s*>"
    for _ in 0..<4 {
      let before = body
      body = removePattern(attributedNoisePattern, from: body, count: &removedNoiseBlockCount)
      if body == before { break }
    }
    body = removePattern(
      "<(div|section|ul|ol|p)\\b[^>]*(?:hidden(?:\\s|=|>)|aria-hidden\\s*=\\s*[\\\"']?true)[^>]*>[\\s\\S]*?</\\1\\s*>",
      from: body,
      count: &removedNoiseBlockCount
    )
    body = removePattern(
      "<(div|section|button|a)\\b[^>]*data-testid\\s*=\\s*[\\\"'][^\\\"']*(?:reply|retweet|like|bookmark|view[-_ ]?count|social[-_ ]?context)[^\\\"']*[\\\"'][^>]*>[\\s\\S]*?</\\1\\s*>",
      from: body,
      count: &removedNoiseBlockCount
    )

    let markdown = htmlToReadingMarkdown(body)
    let cleanedText = normalizeExtractedText(markdown)
    return KnowledgeWebSanitizedContent(
      title: title.map(decodeHTMLEntities),
      authors: authors,
      language: language,
      summary: decodeHTMLEntities(summary).trimmedForPublishing,
      sections: sections(from: cleanedText),
      removedNoiseBlockCount: removedNoiseBlockCount,
      selectedMainContent: rootSelection.selectedMainContent
    )
  }

  func sanitizeExtractedText(_ text: String) -> [KnowledgeExtractedSection] {
    sections(from: normalizeExtractedText(text))
  }

  func sanitizeExtractedReadingText(_ text: String) -> String {
    normalizeExtractedText(text)
  }

  /// Builds a readable, non-executing view of a stored HTML/MHTML archive
  /// without applying interface or social-interaction cleanup.
  func readableOriginalText(from data: Data) -> String? {
    var html = decodedHTMLSource(from: data)
    guard !html.isEmpty else { return nil }
    var ignoredRemovalCount = 0
    html = removePattern("<!--[\\s\\S]*?-->", from: html, count: &ignoredRemovalCount)
    for tag in ["script", "style", "noscript", "template", "svg", "canvas"] {
      html = removePattern(
        "<\\s*\(tag)\\b[^>]*>[\\s\\S]*?<\\s*/\\s*\(tag)\\s*>",
        from: html,
        count: &ignoredRemovalCount
      )
    }
    return normalizeOriginalReadingText(htmlToReadingMarkdown(html)).nilIfEmpty
  }

  private func selectReadingRoot(in html: String) -> (html: String, selectedMainContent: Bool) {
    var candidates: [String] = []
    candidates += captures(
      in: html,
      pattern: "<(article|main)\\b[^>]*>[\\s\\S]*?</\\1\\s*>",
      captureIndex: 0
    )
    candidates += captures(
      in: html,
      pattern: "<(div|section)\\b[^>]*role\\s*=\\s*[\\\"']main[\\\"'][^>]*>[\\s\\S]*?</\\1\\s*>",
      captureIndex: 0
    )

    if let best = candidates.max(by: { visibleCharacterCount($0) < visibleCharacterCount($1) }),
       visibleCharacterCount(best) >= 40 {
      return (best, true)
    }
    if let body = firstCapture(in: html, pattern: "<body\\b[^>]*>([\\s\\S]*?)</body>") {
      return (body, false)
    }
    return (html, false)
  }

  private func decodedHTMLSource(from data: Data) -> String {
    let source = String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
      ?? ""
    let loweredPrefix = source.prefix(2_048).lowercased()
    guard loweredPrefix.contains("content-type: multipart/related"),
          let payload = htmlPayloadFromMHTML(source) else {
      return source
    }
    return payload
  }

  private func htmlPayloadFromMHTML(_ source: String) -> String? {
    let normalized = source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    guard let headerEnd = normalized.range(of: "\n\n") else { return nil }
    let headers = String(normalized[..<headerEnd.lowerBound])
    guard let boundary = firstCapture(
      in: headers,
      pattern: "boundary\\s*=\\s*(?:[\\\"']([^\\\"']+)[\\\"']|([^;\\s]+))"
    )?.nilIfEmpty else { return nil }

    for part in normalized[headerEnd.upperBound...].components(separatedBy: "--\(boundary)") {
      let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let partHeaderEnd = trimmedPart.range(of: "\n\n") else { continue }
      let partHeaders = String(trimmedPart[..<partHeaderEnd.lowerBound]).lowercased()
      guard partHeaders.contains("content-type: text/html") else { continue }
      var body = String(trimmedPart[partHeaderEnd.upperBound...])
      if body.hasSuffix("--") { body.removeLast(2) }
      if partHeaders.contains("content-transfer-encoding: base64"),
         let decoded = Data(base64Encoded: body, options: [.ignoreUnknownCharacters]) {
        return String(data: decoded, encoding: .utf8)
          ?? String(data: decoded, encoding: .isoLatin1)
      }
      if partHeaders.contains("content-transfer-encoding: quoted-printable") {
        let decoded = decodeQuotedPrintable(body)
        return String(data: decoded, encoding: .utf8)
          ?? String(data: decoded, encoding: .isoLatin1)
      }
      return body
    }
    return nil
  }

  private func decodeQuotedPrintable(_ source: String) -> Data {
    let bytes = Array(source.utf8)
    var output: [UInt8] = []
    var index = 0
    while index < bytes.count {
      if bytes[index] == 61 {
        if index + 1 < bytes.count, bytes[index + 1] == 10 {
          index += 2
          continue
        }
        if index + 2 < bytes.count,
           let high = hexadecimalValue(bytes[index + 1]),
           let low = hexadecimalValue(bytes[index + 2]) {
          output.append(high * 16 + low)
          index += 3
          continue
        }
      }
      output.append(bytes[index])
      index += 1
    }
    return Data(output)
  }

  private func hexadecimalValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 48...57: byte - 48
    case 65...70: byte - 55
    case 97...102: byte - 87
    default: nil
    }
  }

  private func metadataValue(in html: String, names: [String]) -> String? {
    metadataValues(in: html, names: names).first
  }

  private func metadataValues(in html: String, names: [String]) -> [String] {
    captures(in: html, pattern: "<meta\\b[^>]*>", captureIndex: 0).compactMap { tag in
      let attributes = parsedAttributes(tag)
      guard let name = (attributes["name"] ?? attributes["property"])?.lowercased(),
            names.contains(name),
            let content = attributes["content"]?.nilIfEmpty else { return nil }
      return decodeHTMLEntities(content).trimmedForPublishing.nilIfEmpty
    }
  }

  private func parsedAttributes(_ tag: String) -> [String: String] {
    let pattern = "([A-Za-z_:][-A-Za-z0-9_:.]*)\\s*=\\s*(?:\\\"([^\\\"]*)\\\"|'([^']*)'|([^\\s>]+))"
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [:] }
    let range = NSRange(tag.startIndex..<tag.endIndex, in: tag)
    var output: [String: String] = [:]
    for match in expression.matches(in: tag, range: range) {
      guard let nameRange = Range(match.range(at: 1), in: tag) else { continue }
      let name = String(tag[nameRange]).lowercased()
      for captureIndex in 2...4 {
        guard let valueRange = Range(match.range(at: captureIndex), in: tag) else { continue }
        output[name] = String(tag[valueRange])
        break
      }
    }
    return output
  }

  private func htmlToReadingMarkdown(_ source: String) -> String {
    var text = source
    text = transformMatches("<pre\\b[^>]*>([\\s\\S]*?)</pre>", in: text) { captures in
      let code = decodeHTMLEntities(stripTags(captures[0]))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return code.isEmpty ? "" : "\n\n```\n\(code)\n```\n\n"
    }
    text = transformMatches("<h([1-6])\\b[^>]*>([\\s\\S]*?)</h\\1\\s*>", in: text) { captures in
      let level = Int(captures[0]) ?? 2
      let heading = normalizedInline(stripTags(captures[1]))
      return heading.isEmpty ? "" : "\n\n\(String(repeating: "#", count: level)) \(decodeHTMLEntities(heading))\n\n"
    }
    text = transformMatches("<a\\b([^>]*)>([\\s\\S]*?)</a>", in: text) { captures in
      let label = decodeHTMLEntities(normalizedInline(stripTags(captures[1])))
      guard let destination = parsedAttributes(captures[0])["href"],
            isSafeLinkDestination(destination),
            !label.isEmpty else { return label }
      return "[\(label)](\(destination))"
    }
    text = transformMatches("<blockquote\\b[^>]*>([\\s\\S]*?)</blockquote>", in: text) { captures in
      let quote = normalizeExtractedText(stripTags(captures[0]))
      guard !quote.isEmpty else { return "" }
      return "\n\n" + quote.split(separator: "\n", omittingEmptySubsequences: false)
        .map { "> \($0)" }
        .joined(separator: "\n") + "\n\n"
    }
    text = transformMatches("<li\\b[^>]*>([\\s\\S]*?)</li>", in: text) { captures in
      let item = decodeHTMLEntities(normalizedInline(stripTags(captures[0])))
      return item.isEmpty ? "" : "\n- \(item)"
    }
    text = text.replacingOccurrences(
      of: "<br\\s*/?>|<hr\\b[^>]*>",
      with: "\n",
      options: [.regularExpression, .caseInsensitive]
    )
    text = text.replacingOccurrences(
      of: "</(?:p|div|section|article|main|header|figure|figcaption|ul|ol|dl|table|tr)>|<(?:p|div|section|article|main|header|figure|figcaption|ul|ol|dl|table|tr)\\b[^>]*>",
      with: "\n\n",
      options: [.regularExpression, .caseInsensitive]
    )
    text = stripTags(text)
    return decodeHTMLEntities(text)
  }

  private func normalizeExtractedText(_ value: String) -> String {
    let normalizedNewlines = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\u{00a0}", with: " ")
    let rawLines = normalizedNewlines.components(separatedBy: "\n")
    let socialNoiseClassifier = KnowledgeSocialInteractionNoiseClassifier()
    let normalizedLines = rawLines.map {
      $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
    }
    let socialChromeLineIndexes = socialChromeLineIndexes(
      in: normalizedLines,
      classifier: socialNoiseClassifier
    )
    var output: [String] = []
    var previousNonEmpty: String?
    var pendingBlankLine = false
    var isInsideFencedCodeBlock = false

    for (lineIndex, normalizedLine) in normalizedLines.enumerated() {
      let isFence = normalizedLine.hasPrefix("```")
      let line = isInsideFencedCodeBlock
        ? normalizedLine
        : trimmingTrailingBloggerInterfaceNoise(from: normalizedLine)
      if line.isEmpty {
        pendingBlankLine = !output.isEmpty
        continue
      }
      if !isInsideFencedCodeBlock,
         !isFence,
         (isInterfaceNoiseLine(line)
           || socialNoiseClassifier.isNoiseLine(line)
           || socialChromeLineIndexes.contains(lineIndex)) {
        continue
      }
      guard line != previousNonEmpty else { continue }
      if pendingBlankLine, !output.isEmpty, output.last != "" { output.append("") }
      output.append(line)
      previousNonEmpty = line
      pendingBlankLine = false
      if isFence { isInsideFencedCodeBlock.toggle() }
    }
    return output.joined(separator: "\n").trimmedForPublishing
  }

  private func normalizeOriginalReadingText(_ value: String) -> String {
    let lines = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .replacingOccurrences(of: "\u{00a0}", with: " ")
      .components(separatedBy: "\n")
      .map {
        $0.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
          .trimmingCharacters(in: .whitespaces)
      }

    var output: [String] = []
    var previousNonEmpty: String?
    var pendingBlankLine = false
    for line in lines {
      if line.isEmpty {
        pendingBlankLine = !output.isEmpty
        continue
      }
      guard line != previousNonEmpty else { continue }
      if pendingBlankLine, output.last != "" { output.append("") }
      output.append(line)
      previousNonEmpty = line
      pendingBlankLine = false
    }
    return output.joined(separator: "\n").trimmedForPublishing
  }

  private func socialChromeLineIndexes(
    in lines: [String],
    classifier: KnowledgeSocialInteractionNoiseClassifier
  ) -> Set<Int> {
    var fencedLineIndexes = Set<Int>()
    var isInsideFence = false
    for (index, line) in lines.enumerated() {
      if line.hasPrefix("```") {
        fencedLineIndexes.insert(index)
        isInsideFence.toggle()
      } else if isInsideFence {
        fencedLineIndexes.insert(index)
      }
    }

    let explicitNoiseIndexes = Set(lines.indices.filter { index in
      !fencedLineIndexes.contains(index) && classifier.isNoiseLine(lines[index])
    })
    let standaloneCountIndexes = Set(lines.indices.filter { index in
      !fencedLineIndexes.contains(index)
        && classifier.isStandaloneInteractionCount(lines[index])
    })
    guard !standaloneCountIndexes.isEmpty else { return [] }

    var removable = Set<Int>()
    for index in standaloneCountIndexes {
      let neighboringIndexes = nearestNonEmptyLineIndexes(around: index, in: lines)
      let touchesExplicitChrome = neighboringIndexes.contains { explicitNoiseIndexes.contains($0) }
      if touchesExplicitChrome {
        removable.insert(index)
      }
    }
    var uncheckedCountIndexes = standaloneCountIndexes.subtracting(removable)
    while let start = uncheckedCountIndexes.first {
      var component: Set<Int> = [start]
      var frontier = [start]
      uncheckedCountIndexes.remove(start)
      while let index = frontier.popLast() {
        for neighbor in nearestNonEmptyLineIndexes(around: index, in: lines)
          where uncheckedCountIndexes.contains(neighbor) {
          uncheckedCountIndexes.remove(neighbor)
          component.insert(neighbor)
          frontier.append(neighbor)
        }
      }
      if component.count >= 3 {
        removable.formUnion(component)
      }
    }
    return removable
  }

  private func nearestNonEmptyLineIndexes(around index: Int, in lines: [String]) -> [Int] {
    var output: [Int] = []
    if index > 0,
       let previous = stride(from: index - 1, through: 0, by: -1)
        .first(where: { !lines[$0].isEmpty }) {
      output.append(previous)
    }
    if index + 1 < lines.count,
       let next = (index + 1..<lines.count).first(where: { !lines[$0].isEmpty }) {
      output.append(next)
    }
    return output
  }

  private func isInterfaceNoiseLine(_ line: String) -> Bool {
    let lowered = line.lowercased()
    let bloggerURLSignals = [
      "resources.blogblog.com/",
      "blogger.com/comment/frame/",
      "blogger.com/share-post",
    ]
    if bloggerURLSignals.contains(where: lowered.contains) || lowered.contains("blogthis!") {
      return true
    }
    guard line.count <= 180 else { return false }
    let exactPattern = "^(?:\\[|\\]|首页|主页|登录|注册|订阅|分享|打印|返回顶部|上一篇|下一篇|目录|菜单|搜索|关闭|同意|接受全部|拒绝|广告|没有评论[：:]?|发表评论|较新的博文|较早的博文|搜索此博客|博客归档|供稿人|博文评论(?:\\s*\\(Atom\\))?|近30天最高点击率|advertisement|sign in|log in|subscribe|share|print|back to top|menu|search|close|email this|post a comment|newer post|older post|blog archive|contributors)$"
    if line.range(of: exactPattern, options: [.regularExpression, .caseInsensitive]) != nil {
      return true
    }
    if ["隐私设置", "接受所有", "同意并继续"].contains(where: lowered.contains) {
      return true
    }
    let mentionsCookie = lowered.contains("cookie")
    let consentSignals = ["accept", "consent", "privacy settings", "manage", "we use"]
    return mentionsCookie && consentSignals.contains(where: lowered.contains)
  }

  private func trimmingTrailingBloggerInterfaceNoise(from line: String) -> String {
    guard !line.isEmpty else { return "" }
    let markers = [
      "![](https://resources.blogblog.com/",
      "通过电子邮件发送blogthis!",
      "通过电子邮件发送 blogthis!",
      "没有评论:",
      "没有评论：",
      "https://www.blogger.com/comment/frame/",
      "https://www.blogger.com/share-post",
      "较新的博文",
      "较早的博文",
      "订阅：帖子评论",
      "订阅: 帖子评论",
      "[主页](",
      "[首页](",
      "博文评论 (atom)",
      "博文评论(atom)",
      "订阅：博文评论",
      "订阅: 博文评论",
      "email thisblogthis!",
      "email this blogthis!",
      "post a comment",
      "newer post",
      "older post",
    ]
    var earliestIndex: String.Index?
    for marker in markers {
      guard let range = line.range(of: marker, options: [.caseInsensitive]) else { continue }
      if let currentEarliest = earliestIndex {
        if range.lowerBound < currentEarliest {
          earliestIndex = range.lowerBound
        }
      } else {
        earliestIndex = range.lowerBound
      }
    }
    guard let earliestIndex else { return line }
    return String(line[..<earliestIndex]).trimmedForPublishing
  }

  private func sections(from text: String) -> [KnowledgeExtractedSection] {
    guard !text.isEmpty else { return [] }
    var sections: [KnowledgeExtractedSection] = []
    var headingStack: [String] = []
    var currentHeadingPath: String?
    var buffer: [String] = []

    func flush() {
      let body = buffer.joined(separator: "\n").trimmedForPublishing
      if !body.isEmpty {
        sections.append(KnowledgeExtractedSection(headingPath: currentHeadingPath, text: body))
      }
      buffer.removeAll(keepingCapacity: true)
    }

    for line in text.components(separatedBy: "\n") {
      let headingPrefix = line.prefix { $0 == "#" }
      let remainder = line.dropFirst(headingPrefix.count)
      if (1...6).contains(headingPrefix.count),
         remainder.first?.isWhitespace == true {
        flush()
        let level = headingPrefix.count
        let heading = String(remainder).trimmedForPublishing
        if headingStack.count >= level {
          headingStack.removeSubrange((level - 1)..<headingStack.count)
        }
        while headingStack.count < level - 1 { headingStack.append("") }
        headingStack.append(heading)
        currentHeadingPath = headingStack.filter { !$0.isEmpty }.joined(separator: " › ")
      } else {
        buffer.append(line)
      }
    }
    flush()
    return sections
  }

  private func transformMatches(
    _ pattern: String,
    in source: String,
    transform: ([String]) -> String
  ) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive]
    ) else { return source }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    let matches = expression.matches(in: source, range: range)
    var output = source
    for match in matches.reversed() {
      guard let fullRange = Range(match.range(at: 0), in: output) else { continue }
      var captures: [String] = []
      if match.numberOfRanges > 1 {
        for index in 1..<match.numberOfRanges {
          if let captureRange = Range(match.range(at: index), in: source) {
            captures.append(String(source[captureRange]))
          } else {
            captures.append("")
          }
        }
      }
      output.replaceSubrange(fullRange, with: transform(captures))
    }
    return output
  }

  private func removePattern(
    _ pattern: String,
    from source: String,
    count: inout Int
  ) -> String {
    guard let expression = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive]
    ) else { return source }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    let matches = expression.matches(in: source, range: range)
    count += matches.count
    return expression.stringByReplacingMatches(in: source, range: range, withTemplate: " ")
  }

  private func firstCapture(in source: String, pattern: String) -> String? {
    captures(in: source, pattern: pattern, captureIndex: 1).first
  }

  private func captures(in source: String, pattern: String, captureIndex: Int) -> [String] {
    guard let expression = try? NSRegularExpression(
      pattern: pattern,
      options: [.caseInsensitive]
    ) else { return [] }
    let range = NSRange(source.startIndex..<source.endIndex, in: source)
    return expression.matches(in: source, range: range).compactMap { match in
      guard captureIndex < match.numberOfRanges,
            let captureRange = Range(match.range(at: captureIndex), in: source) else { return nil }
      return String(source[captureRange])
    }
  }

  private func visibleCharacterCount(_ html: String) -> Int {
    normalizedInline(decodeHTMLEntities(stripTags(html))).count
  }

  private func stripTags(_ value: String) -> String {
    value.replacingOccurrences(
      of: "<[^>]+>",
      with: " ",
      options: [.regularExpression, .caseInsensitive]
    )
  }

  private func normalizedInline(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
      .trimmedForPublishing
  }

  private func isSafeLinkDestination(_ value: String) -> Bool {
    let trimmed = value.trimmedForPublishing
    guard !trimmed.isEmpty else { return false }
    let lowered = trimmed.lowercased()
    return !["javascript:", "data:", "vbscript:", "file:"].contains { lowered.hasPrefix($0) }
  }

  private func decodeHTMLEntities(_ value: String) -> String {
    var decoded = value
    let named: [String: String] = [
      "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
      "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&ndash;": "–",
      "&mdash;": "—", "&hellip;": "…", "&middot;": "·", "&laquo;": "“",
      "&raquo;": "”", "&copy;": "©", "&reg;": "®",
    ]
    for (entity, replacement) in named {
      decoded = decoded.replacingOccurrences(
        of: entity,
        with: replacement,
        options: .caseInsensitive
      )
    }
    decoded = transformMatches("&#x([0-9a-f]+);", in: decoded) { captures in
      guard let value = UInt32(captures[0], radix: 16),
            let scalar = UnicodeScalar(value) else { return "" }
      return String(scalar)
    }
    decoded = transformMatches("&#([0-9]+);", in: decoded) { captures in
      guard let value = UInt32(captures[0]),
            let scalar = UnicodeScalar(value) else { return "" }
      return String(scalar)
    }
    return decoded
  }
}
