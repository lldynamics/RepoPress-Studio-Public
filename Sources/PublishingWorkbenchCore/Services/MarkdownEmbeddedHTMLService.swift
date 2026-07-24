import Foundation

public struct MarkdownEmbeddedHTMLReplacement: Hashable, Sendable {
  public var token: String
  public var html: String
  public var isBlock: Bool

  public init(token: String, html: String, isBlock: Bool) {
    self.token = token
    self.html = html
    self.isBlock = isBlock
  }
}

public struct MarkdownEmbeddedHTMLIssue: Identifiable, Hashable, Sendable {
  public var id: String
  public var severity: MarkdownInlineDiagnosticSeverity
  public var title: String
  public var message: String
  public var range: NSRange

  public init(
    id: String,
    severity: MarkdownInlineDiagnosticSeverity,
    title: String,
    message: String,
    range: NSRange
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.message = message
    self.range = range
  }
}

public struct MarkdownEmbeddedHTMLPreparation: Hashable, Sendable {
  public var markdown: String
  public var replacements: [MarkdownEmbeddedHTMLReplacement]
  public var issues: [MarkdownEmbeddedHTMLIssue]

  public init(
    markdown: String,
    replacements: [MarkdownEmbeddedHTMLReplacement],
    issues: [MarkdownEmbeddedHTMLIssue]
  ) {
    self.markdown = markdown
    self.replacements = replacements
    self.issues = issues
  }
}

/// Prepares a conservative subset of embedded HTML for Markdown preview.
///
/// The Markdown renderer remains responsible for escaping every other tag. This service only
/// replaces explicitly allowed tags after removing executable attributes and unsafe URLs.
public enum MarkdownEmbeddedHTMLService {
  private static let maximumInputUTF16Length = 4 * 1_024 * 1_024
  private static let maximumTokenCount = 65_536
  private static let allowedTags: Set<String> = [
    "a", "abbr", "audio", "b", "br", "caption", "code", "col", "colgroup",
    "details", "div", "em", "figcaption", "figure", "hr", "i", "img", "kbd",
    "mark", "p", "pre", "s", "small", "source", "span", "strong", "sub",
    "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "time",
    "tr", "track", "video"
  ]

  private static let blockTags: Set<String> = [
    "audio", "caption", "colgroup", "details", "div", "figcaption", "figure",
    "hr", "p", "pre", "summary", "table", "tbody", "td", "tfoot", "th",
    "thead", "tr", "video"
  ]

  private static let voidTags: Set<String> = [
    "br", "col", "hr", "img", "source", "track"
  ]

  private static let globalAttributes: Set<String> = [
    "class", "dir", "id", "lang", "role", "title"
  ]

  private static let tagAttributes: [String: Set<String>] = [
    "a": ["href", "rel", "target"],
    "audio": ["controls", "loop", "muted", "preload", "src"],
    "col": ["span"],
    "details": ["open"],
    "img": ["alt", "decoding", "height", "loading", "src", "width"],
    "source": ["media", "src", "type"],
    "td": ["colspan", "rowspan"],
    "th": ["colspan", "rowspan", "scope"],
    "time": ["datetime"],
    "track": ["default", "kind", "label", "src", "srclang"],
    "video": ["controls", "height", "loop", "muted", "playsinline", "poster", "preload", "src", "width"]
  ]

  private static let booleanAttributes: Set<String> = [
    "controls", "default", "loop", "muted", "open", "playsinline"
  ]

  private static let URLAttributes: Set<String> = ["href", "poster", "src"]

  public static func prepare(markdown: String) -> MarkdownEmbeddedHTMLPreparation {
    let source = markdown as NSString
    guard source.length <= maximumInputUTF16Length else {
      return MarkdownEmbeddedHTMLPreparation(markdown: markdown, replacements: [], issues: [])
    }
    let protectedRanges = MarkdownCodeRangeScanner.scan(markdown).allRanges
    guard let scannedTokens = htmlTokens(in: markdown) else {
      return MarkdownEmbeddedHTMLPreparation(markdown: markdown, replacements: [], issues: [])
    }
    let tokens = scannedTokens.filter { token in
      !protectedRanges.contains { NSIntersectionRange($0, token.range).length > 0 }
    }
    guard !tokens.isEmpty else {
      return MarkdownEmbeddedHTMLPreparation(markdown: markdown, replacements: [], issues: [])
    }

    var replacements: [MarkdownEmbeddedHTMLReplacement] = []
    var issues: [MarkdownEmbeddedHTMLIssue] = []
    var edits: [(range: NSRange, replacement: String)] = []
    var consumedTokenIndices = Set<Int>()
    let closingIndices = matchingClosingIndices(in: tokens)
    let tokenNonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")

    for (index, token) in tokens.enumerated() where !consumedTokenIndices.contains(index) {
      switch token.kind {
      case .comment:
        // Comments remain in the Markdown input and are escaped by the default renderer.
        continue
      case .tag:
        guard allowedTags.contains(token.name) else {
          issues.append(unsupportedTagIssue(token: token))
          continue
        }
        guard !token.isClosing else {
          issues.append(unbalancedTagIssue(token: token))
          continue
        }

        if token.isSelfClosing, !voidTags.contains(token.name) {
          issues.append(unbalancedTagIssue(token: token))
          consumedTokenIndices.insert(index)
          continue
        }

        if voidTags.contains(token.name) {
          let isBlock = blockTags.contains(token.name)
          if isBlock,
             (!beginsStandaloneLine(token.range, source: source)
               || !endsStandaloneLine(token.range, source: source)) {
            issues.append(blockPlacementIssue(token: token))
            consumedTokenIndices.insert(index)
            continue
          }
          let result = sanitize(token: token)
          issues.append(contentsOf: result.issues)
          guard let html = result.html else { continue }
          let replacementToken = previewToken(
            index: replacements.count,
            block: isBlock,
            nonce: tokenNonce
          )
          replacements.append(MarkdownEmbeddedHTMLReplacement(
            token: replacementToken,
            html: html,
            isBlock: isBlock
          ))
          edits.append((token.range, replacementToken))
          consumedTokenIndices.insert(index)
          continue
        }

        guard let closingIndex = closingIndices[index] else {
          issues.append(unbalancedTagIssue(token: token))
          continue
        }
        let fragmentTokenIndices = index...closingIndex
        consumedTokenIndices.formUnion(fragmentTokenIndices)
        let fragmentRange = NSRange(
          location: token.range.location,
          length: NSMaxRange(tokens[closingIndex].range) - token.range.location
        )
        let isBlock = blockTags.contains(token.name)
        if isBlock,
           (!beginsStandaloneLine(token.range, source: source)
             || !endsStandaloneLine(fragmentRange, source: source)) {
          issues.append(blockPlacementIssue(token: token))
          continue
        }
        let sanitized = sanitizedFragment(
          source: source,
          range: fragmentRange,
          tokens: tokens,
          tokenIndices: fragmentTokenIndices,
          issues: &issues
        )
        guard sanitized.didRecognizeEveryTag else { continue }

        let replacementToken = previewToken(
          index: replacements.count,
          block: isBlock,
          nonce: tokenNonce
        )
        replacements.append(MarkdownEmbeddedHTMLReplacement(
          token: replacementToken,
          html: sanitized.html,
          isBlock: isBlock
        ))
        edits.append((fragmentRange, replacementToken))
      }
    }

    var prepared = markdown
    for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
      prepared = (prepared as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
    issues.append(contentsOf: unsupportedIssues(
      tokens: tokens,
      excluding: consumedTokenIndices,
      existingIssues: issues
    ))
    return MarkdownEmbeddedHTMLPreparation(
      markdown: prepared,
      replacements: replacements,
      issues: deduplicatedIssues(issues)
    )
  }

  public static func restore(
    renderedHTML: String,
    replacements: [MarkdownEmbeddedHTMLReplacement]
  ) -> String {
    var restored = renderedHTML
    for replacement in replacements where replacement.isBlock {
      restored = restored
        .replacingOccurrences(
          of: "<p>\(replacement.token)</p>\n",
          with: "\(replacement.html)\n"
        )
        .replacingOccurrences(
          of: "<p>\(replacement.token)</p>",
          with: replacement.html
        )
    }
    return restoreInlineTokens(
      in: restored,
      replacements: replacements.filter { !$0.isBlock }
    )
  }

  private static func restoreInlineTokens(
    in renderedHTML: String,
    replacements: [MarkdownEmbeddedHTMLReplacement]
  ) -> String {
    guard !replacements.isEmpty else { return renderedHTML }
    let source = renderedHTML as NSString
    var result = ""
    result.reserveCapacity(renderedHTML.utf8.count)
    var cursor = 0
    var ancestors: [String] = []

    while cursor < source.length {
      let remaining = NSRange(location: cursor, length: source.length - cursor)
      let opener = source.range(of: "<", options: [], range: remaining)
      guard opener.location != NSNotFound else {
        result += replacingInlineTokens(
          in: source.substring(from: cursor),
          replacements: replacements,
          mode: textRestoreMode(ancestors: ancestors)
        )
        break
      }

      if opener.location > cursor {
        result += replacingInlineTokens(
          in: source.substring(with: NSRange(
            location: cursor,
            length: opener.location - cursor
          )),
          replacements: replacements,
          mode: textRestoreMode(ancestors: ancestors)
        )
      }

      guard let tagEnd = renderedTagEnd(
        from: opener.location + 1,
        source: source
      ) else {
        result += replacingInlineTokens(
          in: source.substring(from: opener.location),
          replacements: replacements,
          mode: textRestoreMode(ancestors: ancestors)
        )
        break
      }
      let tagRange = NSRange(
        location: opener.location,
        length: tagEnd + 1 - opener.location
      )
      let rawTag = source.substring(with: tagRange)
      result += replacingInlineTokens(
        in: rawTag,
        replacements: replacements,
        mode: .attribute
      )
      updateAncestors(from: rawTag, ancestors: &ancestors)
      cursor = NSMaxRange(tagRange)
    }
    return result
  }

  private enum InlineTokenRestoreMode {
    case trustedText(insideAnchor: Bool)
    case literalText
    case attribute
  }

  private static func textRestoreMode(ancestors: [String]) -> InlineTokenRestoreMode {
    ancestors.contains("code") || ancestors.contains("pre")
      ? .literalText
      : .trustedText(insideAnchor: ancestors.contains("a"))
  }

  private static func replacingInlineTokens(
    in source: String,
    replacements: [MarkdownEmbeddedHTMLReplacement],
    mode: InlineTokenRestoreMode
  ) -> String {
    replacements.reduce(source) { partial, replacement in
      let value: String
      switch mode {
      case let .trustedText(insideAnchor):
        value = insideAnchor && rootTagName(in: replacement.html) == "a"
          ? escapeHTMLText(replacement.html)
          : replacement.html
      case .literalText:
        value = escapeHTMLText(replacement.html)
      case .attribute:
        value = escapeAttribute(replacement.html)
      }
      return partial.replacingOccurrences(of: replacement.token, with: value)
    }
  }

  private static func rootTagName(in html: String) -> String? {
    let source = html as NSString
    guard source.length > 2, source.character(at: 0) == 60 else { return nil }
    var cursor = 1
    let start = cursor
    while cursor < source.length, isNameCharacter(source.character(at: cursor)) {
      cursor += 1
    }
    guard cursor > start else { return nil }
    return source.substring(with: NSRange(location: start, length: cursor - start)).lowercased()
  }

  private static func renderedTagEnd(from start: Int, source: NSString) -> Int? {
    var quote: unichar?
    var cursor = start
    while cursor < source.length {
      let character = source.character(at: cursor)
      if let activeQuote = quote {
        if character == activeQuote { quote = nil }
      } else if character == 34 || character == 39 {
        quote = character
      } else if character == 62 {
        return cursor
      }
      cursor += 1
    }
    return nil
  }

  private static func updateAncestors(
    from rawTag: String,
    ancestors: inout [String]
  ) {
    let source = rawTag as NSString
    guard source.length >= 3,
          source.character(at: 0) == 60 else { return }
    var cursor = 1
    if source.character(at: cursor) == 33 || source.character(at: cursor) == 63 {
      return
    }
    var isClosing = false
    if source.character(at: cursor) == 47 {
      isClosing = true
      cursor += 1
    }
    while cursor < source.length,
          (source.character(at: cursor) == 32 || source.character(at: cursor) == 9) {
      cursor += 1
    }
    let nameStart = cursor
    while cursor < source.length, isNameCharacter(source.character(at: cursor)) {
      cursor += 1
    }
    guard cursor > nameStart else { return }
    let name = source.substring(with: NSRange(
      location: nameStart,
      length: cursor - nameStart
    )).lowercased()
    if isClosing {
      if let matchingIndex = ancestors.lastIndex(of: name) {
        ancestors.removeSubrange(matchingIndex...)
      }
      return
    }
    let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.hasSuffix("/>"), !voidTags.contains(name) else { return }
    ancestors.append(name)
  }

  private static func matchingClosingIndices(in tokens: [HTMLToken]) -> [Int: Int] {
    var result: [Int: Int] = [:]
    var stack: [Int] = []
    for (index, token) in tokens.enumerated() {
      guard token.kind == .tag else { continue }
      if token.isClosing {
        guard let openingIndex = stack.last,
              tokens[openingIndex].name == token.name else {
          // A mismatched close invalidates every still-open ancestor. Keeping
          // an older entry here would allow a malformed outer fragment through.
          stack.removeAll(keepingCapacity: true)
          continue
        }
        stack.removeLast()
        result[openingIndex] = index
      } else if !token.isSelfClosing, !voidTags.contains(token.name) {
        stack.append(index)
      }
    }
    return result
  }

  private static func sanitizedFragment(
    source: NSString,
    range: NSRange,
    tokens: [HTMLToken],
    tokenIndices: ClosedRange<Int>,
    issues: inout [MarkdownEmbeddedHTMLIssue]
  ) -> (html: String, didRecognizeEveryTag: Bool) {
    var fragment = source.substring(with: range)
    var edits: [(range: NSRange, replacement: String)] = []
    var recognizedEveryTag = true
    if containsUnparsedTagOpener(
      source: source,
      range: range,
      tokens: tokens,
      tokenIndices: tokenIndices
    ) {
      issues.append(malformedFragmentIssue(range: range))
      return (fragment, false)
    }
    for index in tokenIndices {
      let token = tokens[index]
      guard NSIntersectionRange(range, token.range).length == token.range.length else { continue }
      switch token.kind {
      case .comment:
        edits.append((
          NSRange(location: token.range.location - range.location, length: token.range.length),
          ""
        ))
      case .tag:
        guard allowedTags.contains(token.name) else {
          issues.append(unsupportedTagIssue(token: token))
          recognizedEveryTag = false
          continue
        }
        let result = sanitize(token: token)
        issues.append(contentsOf: result.issues)
        guard let html = result.html else {
          recognizedEveryTag = false
          continue
        }
        edits.append((
          NSRange(location: token.range.location - range.location, length: token.range.length),
          html
        ))
      }
    }
    guard recognizedEveryTag else { return (fragment, false) }
    for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
      fragment = (fragment as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }
    return (fragment, true)
  }

  private static func sanitize(
    token: HTMLToken
  ) -> (html: String?, issues: [MarkdownEmbeddedHTMLIssue]) {
    if token.isClosing {
      return ("</\(token.name)>", [])
    }

    var issues: [MarkdownEmbeddedHTMLIssue] = []
    var attributes: [String] = []
    let allowed = globalAttributes.union(tagAttributes[token.name] ?? [])
    for attribute in token.attributes {
      let name = attribute.name.lowercased()
      var value = attribute.value
      let isARIA = name.hasPrefix("aria-")
      guard allowed.contains(name) || isARIA else {
        issues.append(removedAttributeIssue(attribute: attribute, token: token))
        continue
      }
      if name == "target" {
        guard value?.lowercased() == "_blank" else {
          issues.append(removedAttributeIssue(attribute: attribute, token: token))
          continue
        }
        value = "_blank"
      }
      if URLAttributes.contains(name), let value,
         !isSafeURL(value, attribute: name) {
        issues.append(MarkdownEmbeddedHTMLIssue(
          id: "html-url-\(token.range.location)-\(attribute.range.location)",
          severity: .error,
          title: CoreL10n.text("HTML 链接已拦截"),
          message: CoreL10n.format(
            "%@ 使用了不安全的地址协议，预览中已移除。",
            name
          ),
          range: attribute.range
        ))
        continue
      }
      if booleanAttributes.contains(name) {
        attributes.append(name)
      } else if let value {
        attributes.append("\(name)=\"\(escapeAttribute(value))\"")
      } else {
        issues.append(removedAttributeIssue(attribute: attribute, token: token))
      }
    }
    if token.name == "a", attributes.contains(where: { $0 == "target=\"_blank\"" }) {
      attributes.removeAll { $0.hasPrefix("rel=") }
      attributes.append("rel=\"noopener noreferrer\"")
    }
    let suffix = token.isSelfClosing || voidTags.contains(token.name) ? " />" : ">"
    let joinedAttributes = attributes.isEmpty ? "" : " " + attributes.joined(separator: " ")
    return ("<\(token.name)\(joinedAttributes)\(suffix)", issues)
  }

  private static func isSafeURL(_ value: String, attribute: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let normalized = trimmed.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
    }.map(String.init).joined().lowercased()
    guard !trimmed.isEmpty else { return false }
    if trimmed.hasPrefix("#") || trimmed.hasPrefix("/") || trimmed.hasPrefix("./") || trimmed.hasPrefix("../") {
      return true
    }
    guard let components = URLComponents(string: normalized), let scheme = components.scheme?.lowercased() else {
      return !trimmed.contains(":")
    }
    if attribute == "href" {
      return ["http", "https", "mailto"].contains(scheme)
    }
    if scheme == "publisher-asset" { return true }
    if scheme == "data", attribute == "src" {
      let allowedMIMETypes = [
        "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"
      ]
      return allowedMIMETypes.contains { mimeType in
        normalized.hasPrefix("data:\(mimeType);")
          || normalized.hasPrefix("data:\(mimeType),")
      }
    }
    return false
  }

  private static func unsupportedIssues(
    tokens: [HTMLToken],
    excluding consumedIndices: Set<Int>,
    existingIssues: [MarkdownEmbeddedHTMLIssue]
  ) -> [MarkdownEmbeddedHTMLIssue] {
    let existingLocations = Set(existingIssues.map { $0.range.location })
    return tokens.enumerated().compactMap { index, token in
      guard !consumedIndices.contains(index), token.kind == .tag,
            !allowedTags.contains(token.name), !existingLocations.contains(token.range.location) else {
        return nil
      }
      return unsupportedTagIssue(token: token)
    }
  }

  private static func unsupportedTagIssue(token: HTMLToken) -> MarkdownEmbeddedHTMLIssue {
    MarkdownEmbeddedHTMLIssue(
      id: "html-tag-\(token.name)-\(token.range.location)",
      severity: ["script", "iframe", "object", "embed", "style", "form"].contains(token.name)
        ? .error
        : .warning,
      title: CoreL10n.text("HTML 标签未在预览中启用"),
      message: CoreL10n.format(
        "<%@> 会按普通文本显示，以避免不受控内容进入预览。",
        token.name
      ),
      range: token.range
    )
  }

  private static func unbalancedTagIssue(token: HTMLToken) -> MarkdownEmbeddedHTMLIssue {
    MarkdownEmbeddedHTMLIssue(
      id: "html-unbalanced-\(token.name)-\(token.range.location)",
      severity: .warning,
      title: CoreL10n.text("HTML 标签没有配对"),
      message: CoreL10n.format(
        "<%@> 不会进入预览，请补全开始和结束标签。",
        "\(token.isClosing ? "/" : "")\(token.name)"
      ),
      range: token.range
    )
  }

  private static func malformedFragmentIssue(range: NSRange) -> MarkdownEmbeddedHTMLIssue {
    MarkdownEmbeddedHTMLIssue(
      id: "html-malformed-\(range.location)",
      severity: .warning,
      title: CoreL10n.text("HTML 片段格式无效"),
      message: CoreL10n.text(
        "HTML 片段包含无法安全解析的标记，预览中会按普通文本显示。"
      ),
      range: range
    )
  }

  private static func blockPlacementIssue(token: HTMLToken) -> MarkdownEmbeddedHTMLIssue {
    MarkdownEmbeddedHTMLIssue(
      id: "html-block-placement-\(token.range.location)",
      severity: .warning,
      title: CoreL10n.text("HTML 块需要单独成行"),
      message: CoreL10n.format(
        "<%@> 需要单独成块，开始标签前和结束标签后只能有空白。",
        token.name
      ),
      range: token.range
    )
  }

  private static func removedAttributeIssue(
    attribute: HTMLAttribute,
    token: HTMLToken
  ) -> MarkdownEmbeddedHTMLIssue {
    MarkdownEmbeddedHTMLIssue(
      id: "html-attribute-\(token.range.location)-\(attribute.range.location)",
      severity: attribute.name.lowercased().hasPrefix("on") ? .error : .warning,
      title: CoreL10n.text("HTML 属性已从预览移除"),
      message: CoreL10n.format(
        "<%@> 的 %@ 属性不在安全白名单中。",
        token.name,
        attribute.name
      ),
      range: attribute.range
    )
  }

  private static func deduplicatedIssues(
    _ issues: [MarkdownEmbeddedHTMLIssue]
  ) -> [MarkdownEmbeddedHTMLIssue] {
    var seen = Set<String>()
    return issues.sorted {
      if $0.range.location == $1.range.location { return $0.id < $1.id }
      return $0.range.location < $1.range.location
    }.filter { seen.insert($0.id).inserted }
  }

  private static func beginsStandaloneLine(_ range: NSRange, source: NSString) -> Bool {
    let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
    let prefixRange = NSRange(location: lineRange.location, length: range.location - lineRange.location)
    return source.substring(with: prefixRange).trimmingCharacters(in: .whitespaces).isEmpty
  }

  private static func endsStandaloneLine(_ range: NSRange, source: NSString) -> Bool {
    guard range.length > 0 else { return false }
    let finalCharacterLocation = min(NSMaxRange(range) - 1, max(0, source.length - 1))
    let lineRange = source.lineRange(
      for: NSRange(location: finalCharacterLocation, length: 0)
    )
    let suffixLocation = NSMaxRange(range)
    guard suffixLocation <= NSMaxRange(lineRange) else { return false }
    let suffixRange = NSRange(
      location: suffixLocation,
      length: NSMaxRange(lineRange) - suffixLocation
    )
    return source.substring(with: suffixRange)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty
  }

  private static func containsUnparsedTagOpener(
    source: NSString,
    range: NSRange,
    tokens: [HTMLToken],
    tokenIndices: ClosedRange<Int>
  ) -> Bool {
    var cursor = range.location
    for index in tokenIndices {
      let tokenRange = tokens[index].range
      guard tokenRange.location >= cursor,
            NSMaxRange(tokenRange) <= NSMaxRange(range) else {
        continue
      }
      let gapRange = NSRange(
        location: cursor,
        length: tokenRange.location - cursor
      )
      if source.substring(with: gapRange).contains("<") { return true }
      cursor = NSMaxRange(tokenRange)
    }
    guard cursor <= NSMaxRange(range) else { return true }
    let trailingRange = NSRange(
      location: cursor,
      length: NSMaxRange(range) - cursor
    )
    return source.substring(with: trailingRange).contains("<")
  }

  private static func previewToken(index: Int, block: Bool, nonce: String) -> String {
    "PSPHTML\(block ? "BLOCK" : "INLINE")\(nonce)\(index)TOKEN"
  }

  private static func escapeAttribute(_ value: String) -> String {
    MarkupEscaping.htmlDoubleQuotedAttribute(value)
  }

  private static func escapeHTMLText(_ value: String) -> String {
    MarkupEscaping.htmlText(value)
  }

  private enum HTMLTokenKind: Hashable {
    case tag
    case comment
  }

  private struct HTMLToken: Hashable {
    var kind: HTMLTokenKind
    var name: String
    var range: NSRange
    var isClosing: Bool
    var isSelfClosing: Bool
    var attributes: [HTMLAttribute]
  }

  private struct HTMLAttribute: Hashable {
    var name: String
    var value: String?
    var range: NSRange
  }

  private static func htmlTokens(in markdown: String) -> [HTMLToken]? {
    let characters = Array(markdown.utf16)
    var result: [HTMLToken] = []
    var scanBudget = max(1_024, characters.count * 2)
    var index = 0
    while index < characters.count {
      guard characters[index] == 60 else { // <
        index += 1
        continue
      }
      if matches(Array("<!--".utf16), at: index, in: characters),
         let end = find(
           Array("-->".utf16),
           from: index + 4,
           in: characters,
           scanBudget: &scanBudget
         ) {
        result.append(HTMLToken(
          kind: .comment,
          name: "comment",
          range: NSRange(location: index, length: end + 3 - index),
          isClosing: false,
          isSelfClosing: true,
          attributes: []
        ))
        guard result.count <= maximumTokenCount else { return nil }
        index = end + 3
        continue
      }
      guard let end = tagEnd(
        from: index + 1,
        in: characters,
        scanBudget: &scanBudget
      ) else {
        guard scanBudget > 0 else { return nil }
        index += 1
        continue
      }
      let range = NSRange(location: index, length: end + 1 - index)
      let raw = (markdown as NSString).substring(with: range)
      if let parsed = parseTag(raw, globalLocation: index, range: range) {
        result.append(parsed)
        guard result.count <= maximumTokenCount else { return nil }
      }
      index = end + 1
    }
    return result
  }

  private static func parseTag(
    _ raw: String,
    globalLocation: Int,
    range: NSRange
  ) -> HTMLToken? {
    let source = raw as NSString
    var cursor = 1
    skipWhitespace(source, cursor: &cursor)
    var isClosing = false
    if cursor < source.length, source.character(at: cursor) == 47 {
      isClosing = true
      cursor += 1
      skipWhitespace(source, cursor: &cursor)
    }
    let nameStart = cursor
    while cursor < source.length, isNameCharacter(source.character(at: cursor)) { cursor += 1 }
    guard cursor > nameStart else { return nil }
    let name = source.substring(with: NSRange(location: nameStart, length: cursor - nameStart)).lowercased()
    var attributes: [HTMLAttribute] = []
    var isSelfClosing = false
    while cursor < source.length {
      skipWhitespace(source, cursor: &cursor)
      guard cursor < source.length else { break }
      let character = source.character(at: cursor)
      if character == 62 { break }
      if character == 47 {
        isSelfClosing = true
        cursor += 1
        continue
      }
      let attributeStart = cursor
      while cursor < source.length, isAttributeNameCharacter(source.character(at: cursor)) { cursor += 1 }
      guard cursor > attributeStart else { return nil }
      let attributeName = source.substring(
        with: NSRange(location: attributeStart, length: cursor - attributeStart)
      )
      skipWhitespace(source, cursor: &cursor)
      var value: String?
      if cursor < source.length, source.character(at: cursor) == 61 {
        cursor += 1
        skipWhitespace(source, cursor: &cursor)
        guard cursor < source.length else { return nil }
        let quote = source.character(at: cursor)
        if quote == 34 || quote == 39 {
          cursor += 1
          let valueStart = cursor
          while cursor < source.length, source.character(at: cursor) != quote { cursor += 1 }
          guard cursor < source.length else { return nil }
          value = source.substring(with: NSRange(location: valueStart, length: cursor - valueStart))
          cursor += 1
        } else {
          let valueStart = cursor
          while cursor < source.length {
            let candidate = source.character(at: cursor)
            if candidate == 62 {
              break
            }
            if let scalar = UnicodeScalar(candidate),
               CharacterSet.whitespacesAndNewlines.contains(scalar) {
              break
            }
            cursor += 1
          }
          guard cursor > valueStart else { return nil }
          value = source.substring(with: NSRange(location: valueStart, length: cursor - valueStart))
        }
      }
      attributes.append(HTMLAttribute(
        name: attributeName,
        value: value,
        range: NSRange(
          location: globalLocation + attributeStart,
          length: max(1, cursor - attributeStart)
        )
      ))
    }
    return HTMLToken(
      kind: .tag,
      name: name,
      range: range,
      isClosing: isClosing,
      isSelfClosing: isSelfClosing,
      attributes: isClosing ? [] : attributes
    )
  }

  private static func tagEnd(
    from start: Int,
    in characters: [UInt16],
    scanBudget: inout Int
  ) -> Int? {
    var quote: UInt16?
    var index = start
    while index < characters.count, scanBudget > 0 {
      scanBudget -= 1
      let character = characters[index]
      if let activeQuote = quote {
        if character == activeQuote { quote = nil }
      } else if character == 34 || character == 39 {
        quote = character
      } else if character == 62 {
        return index
      } else if character == 60 {
        return nil
      }
      index += 1
    }
    return nil
  }

  private static func skipWhitespace(_ source: NSString, cursor: inout Int) {
    while cursor < source.length {
      guard let scalar = UnicodeScalar(source.character(at: cursor)),
            CharacterSet.whitespacesAndNewlines.contains(scalar) else { break }
      cursor += 1
    }
  }

  private static func isNameCharacter(_ value: unichar) -> Bool {
    guard let scalar = UnicodeScalar(value) else { return false }
    return CharacterSet.alphanumerics.contains(scalar) || value == 45 || value == 58
  }

  private static func isAttributeNameCharacter(_ value: unichar) -> Bool {
    guard let scalar = UnicodeScalar(value) else { return false }
    return CharacterSet.alphanumerics.contains(scalar)
      || value == 45 || value == 95 || value == 58
  }

  private static func matches(_ needle: [UInt16], at index: Int, in haystack: [UInt16]) -> Bool {
    guard index + needle.count <= haystack.count else { return false }
    return Array(haystack[index..<(index + needle.count)]) == needle
  }

  private static func find(
    _ needle: [UInt16],
    from start: Int,
    in haystack: [UInt16],
    scanBudget: inout Int
  ) -> Int? {
    guard !needle.isEmpty, start < haystack.count else { return nil }
    var index = start
    while index + needle.count <= haystack.count, scanBudget > 0 {
      scanBudget -= 1
      if matches(needle, at: index, in: haystack) { return index }
      index += 1
    }
    return nil
  }
}
