import Foundation

public struct MarkdownRichTextPasteConversion: Equatable, Sendable {
  public var markdown: String
  public var removedTrackingParameterCount: Int

  public init(markdown: String, removedTrackingParameterCount: Int) {
    self.markdown = markdown
    self.removedTrackingParameterCount = removedTrackingParameterCount
  }
}

public struct MarkdownRichTextPasteService: Sendable {
  public init() {}

  public func conversion(
    fromHTML html: String,
    baseURL: URL? = nil
  ) -> MarkdownRichTextPasteConversion? {
    guard let document = try? XMLDocument(
      xmlString: html,
      options: [.documentTidyHTML]
    ), let root = document.rootElement() else {
      return nil
    }

    let renderer = HTMLToMarkdownRenderer(baseURL: baseURL)
    let markdown = renderer.renderDocument(root)
    guard !markdown.isEmpty else { return nil }
    return MarkdownRichTextPasteConversion(
      markdown: markdown,
      removedTrackingParameterCount: renderer.removedTrackingParameterCount
    )
  }

  public func edit(
    in markdown: String,
    selectedRange: NSRange,
    conversion: MarkdownRichTextPasteConversion
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    guard selectedRange.location >= 0,
          NSMaxRange(selectedRange) <= source.length,
          !conversion.markdown.isEmpty else {
      return nil
    }
    return MarkdownSmartEdit(
      replacedRange: selectedRange,
      replacement: conversion.markdown,
      selectedRange: NSRange(
        location: selectedRange.location + (conversion.markdown as NSString).length,
        length: 0
      )
    )
  }
}

struct MarkdownPastedURLSanitizer {
  struct Result: Equatable {
    let value: String
    let scheme: String?
    let removedTrackingParameterCount: Int
  }

  private static let trackingQueryNames: Set<String> = [
    "dclid",
    "fbclid",
    "gclid",
    "igshid",
    "mc_cid",
    "mc_eid",
    "msclkid",
    "vero_conv",
    "vero_id",
    "_hsenc",
    "_hsmi",
  ]

  static func webURL(from value: String) -> String? {
    guard let result = sanitize(value),
          ["http", "https"].contains(result.scheme) else {
      return nil
    }
    return result.value
  }

  static func sanitize(
    _ value: String,
    baseURL: URL? = nil
  ) -> Result? {
    let candidate = value
      .replacingOccurrences(of: "&amp;", with: "&")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty,
          !candidate.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      return nil
    }

    if candidate.hasPrefix("#") {
      return Result(
        value: candidate,
        scheme: nil,
        removedTrackingParameterCount: 0
      )
    }

    let resolvedURL: URL?
    if let directURL = URL(string: candidate), directURL.scheme != nil {
      resolvedURL = directURL
    } else if let baseURL {
      resolvedURL = URL(string: candidate, relativeTo: baseURL)?.absoluteURL
    } else {
      resolvedURL = nil
    }

    guard let resolvedURL else {
      guard !candidate.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains),
            !candidate.lowercased().hasPrefix("javascript:") else {
        return nil
      }
      return Result(
        value: candidate,
        scheme: nil,
        removedTrackingParameterCount: 0
      )
    }

    let scheme = resolvedURL.scheme?.lowercased()
    guard let scheme, ["http", "https", "mailto"].contains(scheme) else {
      return nil
    }
    guard scheme != "http" && scheme != "https" || resolvedURL.host?.nilIfEmpty != nil else {
      return nil
    }

    guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: true) else {
      return nil
    }
    let originalQueryItems = components.queryItems ?? []
    let filteredQueryItems = originalQueryItems.filter { item in
      let name = item.name.lowercased()
      return !name.hasPrefix("utm_") && !trackingQueryNames.contains(name)
    }
    components.queryItems = filteredQueryItems.isEmpty ? nil : filteredQueryItems
    guard let sanitizedURL = components.url else { return nil }
    return Result(
      value: sanitizedURL.absoluteString,
      scheme: scheme,
      removedTrackingParameterCount: originalQueryItems.count - filteredQueryItems.count
    )
  }

  static func markdownDestination(_ value: String) -> String {
    if value.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains)
      || value.contains("(")
      || value.contains(")") {
      return "<\(value.replacingOccurrences(of: ">", with: "%3E"))>"
    }
    return value
  }
}

private final class HTMLToMarkdownRenderer {
  private static let skippedElementNames: Set<String> = [
    "applet", "button", "canvas", "form", "head", "iframe", "input", "link",
    "meta", "noscript", "object", "script", "select", "style", "svg", "textarea",
  ]
  private static let blockElementNames: Set<String> = [
    "address", "article", "aside", "blockquote", "body", "dd", "div", "dl", "dt",
    "figcaption", "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header",
    "hr", "html", "main", "nav", "ol", "p", "pre", "section", "table", "ul",
  ]

  let baseURL: URL?
  private(set) var removedTrackingParameterCount = 0

  init(baseURL: URL?) {
    self.baseURL = baseURL
  }

  func renderDocument(_ root: XMLElement) -> String {
    let contentRoot = firstDescendant(named: "body", in: root) ?? root
    return normalizedDocument(renderContainer(children(of: contentRoot)))
  }

  private func renderContainer(_ nodes: [XMLNode]) -> String {
    var blocks: [String] = []
    var inlineNodes: [XMLNode] = []

    func flushInlineNodes() {
      let inline = normalizedInline(renderInline(inlineNodes))
      if !inline.isEmpty {
        blocks.append(inline)
      }
      inlineNodes.removeAll(keepingCapacity: true)
    }

    for node in nodes {
      if isBlockNode(node) {
        flushInlineNodes()
        let block = renderBlock(node).trimmingCharacters(in: .whitespacesAndNewlines)
        if !block.isEmpty {
          blocks.append(block)
        }
      } else {
        inlineNodes.append(node)
      }
    }
    flushInlineNodes()
    return blocks.joined(separator: "\n\n")
  }

  private func renderBlock(_ node: XMLNode) -> String {
    guard let element = node as? XMLElement else {
      return normalizedInline(renderInlineNode(node))
    }
    let name = elementName(element)
    if Self.skippedElementNames.contains(name) { return "" }

    switch name {
    case "h1", "h2", "h3", "h4", "h5", "h6":
      let level = Int(name.dropFirst()) ?? 1
      let title = oneLine(renderInline(children(of: element)))
      return title.isEmpty ? "" : String(repeating: "#", count: level) + " " + title
    case "p", "address", "figcaption":
      return normalizedInline(renderInline(children(of: element)))
    case "ul", "ol":
      return renderList(element, depth: 0)
    case "blockquote":
      let quoted = normalizedDocument(renderContainer(children(of: element)))
      guard !quoted.isEmpty else { return "" }
      return quoted
        .components(separatedBy: "\n")
        .map { $0.isEmpty ? ">" : "> " + $0 }
        .joined(separator: "\n")
    case "pre":
      return renderCodeBlock(element)
    case "table":
      return renderTable(element)
    case "hr":
      return "---"
    case "dt":
      let term = normalizedInline(renderInline(children(of: element)))
      return term.isEmpty ? "" : "**\(term)**"
    case "dd":
      let definition = normalizedDocument(renderContainer(children(of: element)))
      return definition.isEmpty ? "" : definition
        .components(separatedBy: "\n")
        .map { "  " + $0 }
        .joined(separator: "\n")
    default:
      return renderContainer(children(of: element))
    }
  }

  private func renderInline(_ nodes: [XMLNode]) -> String {
    nodes.map(renderInlineNode).joined()
  }

  private func renderInlineNode(_ node: XMLNode) -> String {
    if node.kind == .text {
      return escapedMarkdownText(collapsedWhitespace(node.stringValue ?? ""))
    }
    guard let element = node as? XMLElement else { return "" }
    let name = elementName(element)
    if Self.skippedElementNames.contains(name) { return "" }

    let content = renderInline(children(of: element))
    switch name {
    case "br":
      return "\n"
    case "strong", "b":
      let text = normalizedInline(content)
      return text.isEmpty ? "" : "**\(text)**"
    case "em", "i":
      let text = normalizedInline(content)
      return text.isEmpty ? "" : "*\(text)*"
    case "del", "s", "strike":
      let text = normalizedInline(content)
      return text.isEmpty ? "" : "~~\(text)~~"
    case "code", "tt", "kbd", "samp":
      return inlineCode(element.stringValue ?? "")
    case "a":
      return renderLink(element, label: normalizedInline(content))
    case "img":
      return renderImage(element)
    case "sub":
      let text = normalizedInline(content)
      return text.isEmpty ? "" : "~\(text)~"
    case "sup":
      let text = normalizedInline(content)
      return text.isEmpty ? "" : "^\(text)^"
    default:
      if Self.blockElementNames.contains(name) {
        return renderBlock(element)
      }
      return content
    }
  }

  private func renderLink(_ element: XMLElement, label: String) -> String {
    guard let rawDestination = attribute("href", in: element),
          let destination = sanitizedDestination(rawDestination) else {
      return label
    }
    let linkLabel = label.nilIfEmpty ?? destination
    return "[\(linkLabel)](\(MarkdownPastedURLSanitizer.markdownDestination(destination)))"
  }

  private func renderImage(_ element: XMLElement) -> String {
    let alt = escapedMarkdownAlt(attribute("alt", in: element) ?? "")
    guard let rawDestination = attribute("src", in: element),
          let destination = sanitizedDestination(rawDestination) else {
      return alt
    }
    return "![\(alt)](\(MarkdownPastedURLSanitizer.markdownDestination(destination)))"
  }

  private func sanitizedDestination(_ rawDestination: String) -> String? {
    guard let result = MarkdownPastedURLSanitizer.sanitize(
      rawDestination,
      baseURL: baseURL
    ) else {
      return nil
    }
    removedTrackingParameterCount += result.removedTrackingParameterCount
    return result.value
  }

  private func renderList(_ list: XMLElement, depth: Int) -> String {
    let listName = elementName(list)
    let isOrdered = listName == "ol"
    let start = Int(attribute("start", in: list) ?? "") ?? 1
    let items = childElements(of: list).filter { elementName($0) == "li" }
    var lines: [String] = []

    for (offset, item) in items.enumerated() {
      let nestedLists = childElements(of: item).filter {
        let name = elementName($0)
        return name == "ul" || name == "ol"
      }
      let contentNodes = children(of: item).filter { node in
        guard let element = node as? XMLElement else { return true }
        let name = elementName(element)
        return name != "ul" && name != "ol"
      }
      let content = normalizedDocument(renderContainer(contentNodes))
      let marker = isOrdered ? "\(start + offset). " : "- "
      let indent = String(repeating: "  ", count: depth)
      let contentLines = content.components(separatedBy: "\n")
      if let first = contentLines.first, !first.isEmpty {
        lines.append(indent + marker + first)
        let continuationIndent = indent + String(repeating: " ", count: marker.count)
        lines.append(contentsOf: contentLines.dropFirst().map {
          $0.isEmpty ? continuationIndent : continuationIndent + $0
        })
      } else {
        lines.append(indent + marker.trimmingCharacters(in: .whitespaces))
      }
      for nestedList in nestedLists {
        let nested = renderList(nestedList, depth: depth + 1)
        if !nested.isEmpty {
          lines.append(nested)
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  private func renderTable(_ table: XMLElement) -> String {
    let rows = descendantRows(in: table).compactMap { row -> TableRow? in
      let cells = childElements(of: row).filter {
        let name = elementName($0)
        return name == "th" || name == "td"
      }
      guard !cells.isEmpty else { return nil }
      return TableRow(
        cells: cells.map { cell in
          normalizedDocument(renderContainer(children(of: cell)))
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "|", with: #"\|"#)
        },
        alignments: cells.map(tableAlignment)
      )
    }
    guard let firstRow = rows.first else { return "" }
    let columnCount = rows.map(\.cells.count).max() ?? 0
    guard columnCount > 0 else { return "" }

    let header = padded(firstRow.cells, count: columnCount)
    let alignments = padded(firstRow.alignments, count: columnCount, fill: .none)
    var lines = [tableLine(header)]
    lines.append(tableLine(alignments.map { alignment in
      switch alignment {
      case .left: return ":---"
      case .center: return ":---:"
      case .right: return "---:"
      case .none: return "---"
      }
    }))
    for row in rows.dropFirst() {
      lines.append(tableLine(padded(row.cells, count: columnCount)))
    }
    return lines.joined(separator: "\n")
  }

  private func renderCodeBlock(_ pre: XMLElement) -> String {
    var source = (pre.stringValue ?? "")
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    while source.hasPrefix("\n") { source.removeFirst() }
    while source.hasSuffix("\n") { source.removeLast() }
    let longestRun = longestBacktickRun(in: source)
    let fence = String(repeating: "`", count: max(3, longestRun + 1))
    let language = codeLanguage(in: pre)
    return "\(fence)\(language)\n\(source)\n\(fence)"
  }

  private func inlineCode(_ source: String) -> String {
    let normalized = source
      .replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
    guard !normalized.isEmpty else { return "" }
    let fence = String(repeating: "`", count: max(1, longestBacktickRun(in: normalized) + 1))
    let needsPadding = normalized.hasPrefix("`")
      || normalized.hasSuffix("`")
      || normalized.hasPrefix(" ")
      || normalized.hasSuffix(" ")
    return needsPadding
      ? "\(fence) \(normalized) \(fence)"
      : "\(fence)\(normalized)\(fence)"
  }

  private func codeLanguage(in pre: XMLElement) -> String {
    let code = firstDescendant(named: "code", in: pre)
    let candidates = [
      code.flatMap { attribute("data-language", in: $0) },
      code.flatMap { attribute("class", in: $0) },
      attribute("data-language", in: pre),
      attribute("class", in: pre),
    ]
    for candidate in candidates.compactMap({ $0 }) {
      for token in candidate.split(whereSeparator: \.isWhitespace) {
        let value = String(token)
        let language: String
        if value.hasPrefix("language-") {
          language = String(value.dropFirst("language-".count))
        } else if value.hasPrefix("lang-") {
          language = String(value.dropFirst("lang-".count))
        } else if candidate == attribute("data-language", in: code ?? pre) {
          language = value
        } else {
          continue
        }
        let allowed = language.unicodeScalars.allSatisfy {
          CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_+-")).contains($0)
        }
        if allowed, !language.isEmpty { return language }
      }
    }
    return ""
  }

  private func descendantRows(in table: XMLElement) -> [XMLElement] {
    var result: [XMLElement] = []
    func visit(_ element: XMLElement) {
      for child in childElements(of: element) {
        let name = elementName(child)
        if name == "table", child !== table { continue }
        if name == "tr" {
          result.append(child)
        } else {
          visit(child)
        }
      }
    }
    visit(table)
    return result
  }

  private func firstDescendant(named name: String, in element: XMLElement) -> XMLElement? {
    for child in childElements(of: element) {
      if elementName(child) == name { return child }
      if let descendant = firstDescendant(named: name, in: child) {
        return descendant
      }
    }
    return nil
  }

  private func isBlockNode(_ node: XMLNode) -> Bool {
    guard let element = node as? XMLElement else { return false }
    return Self.blockElementNames.contains(elementName(element))
  }

  private func children(of element: XMLElement) -> [XMLNode] {
    element.children ?? []
  }

  private func childElements(of element: XMLElement) -> [XMLElement] {
    children(of: element).compactMap { $0 as? XMLElement }
  }

  private func elementName(_ element: XMLElement) -> String {
    let name = element.localName ?? element.name ?? ""
    return name.split(separator: ":").last.map(String.init)?.lowercased() ?? ""
  }

  private func attribute(_ name: String, in element: XMLElement) -> String? {
    element.attribute(forName: name)?.stringValue?.nilIfEmpty
  }

  private func normalizedDocument(_ value: String) -> String {
    let normalizedLines = value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .components(separatedBy: "\n")
      .map { $0.replacingOccurrences(of: #"[ \t]+$"#, with: "", options: .regularExpression) }
      .joined(separator: "\n")
    return normalizedLines
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizedInline(_ value: String) -> String {
    value
      .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
      .replacingOccurrences(of: #"\n[ \t]+"#, with: "\n", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func oneLine(_ value: String) -> String {
    normalizedInline(value)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
  }

  private func collapsedWhitespace(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\u{00A0}", with: " ")
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
  }

  private func escapedMarkdownText(_ value: String) -> String {
    value
      .replacingOccurrences(of: #"\"#, with: #"\\"#)
      .replacingOccurrences(of: "`", with: #"\`"#)
      .replacingOccurrences(of: "*", with: #"\*"#)
      .replacingOccurrences(of: "_", with: #"\_"#)
      .replacingOccurrences(of: "[", with: #"\["#)
      .replacingOccurrences(of: "]", with: #"\]"#)
  }

  private func escapedMarkdownAlt(_ value: String) -> String {
    value
      .replacingOccurrences(of: #"\"#, with: #"\\"#)
      .replacingOccurrences(of: "[", with: #"\["#)
      .replacingOccurrences(of: "]", with: #"\]"#)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func longestBacktickRun(in value: String) -> Int {
    var longest = 0
    var current = 0
    for character in value {
      if character == "`" {
        current += 1
        longest = max(longest, current)
      } else {
        current = 0
      }
    }
    return longest
  }

  private func tableLine(_ cells: [String]) -> String {
    "| " + cells.joined(separator: " | ") + " |"
  }

  private func padded(_ values: [String], count: Int) -> [String] {
    padded(values, count: count, fill: "")
  }

  private func padded<Value>(_ values: [Value], count: Int, fill: Value) -> [Value] {
    values + Array(repeating: fill, count: max(0, count - values.count))
  }

  private enum TableAlignment {
    case none
    case left
    case center
    case right
  }

  private struct TableRow {
    let cells: [String]
    let alignments: [TableAlignment]
  }

  private func tableAlignment(_ cell: XMLElement) -> TableAlignment {
    let direct = attribute("align", in: cell)?.lowercased()
    let style = attribute("style", in: cell)?.lowercased() ?? ""
    let value: String?
    if let direct {
      value = direct
    } else if let range = style.range(of: #"text-align\s*:\s*(left|center|right)"#, options: .regularExpression) {
      value = style[range]
        .split(separator: ":", maxSplits: 1)
        .last
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    } else {
      value = nil
    }
    switch value {
    case "left": return .left
    case "center": return .center
    case "right": return .right
    default: return .none
    }
  }
}
