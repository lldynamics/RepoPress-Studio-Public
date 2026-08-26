import Foundation
import PublishingCoreSupport

/// Converts Foundation's parsed Markdown attributes into safe, semantic HTML.
///
/// `NSAttributedString`'s HTML exporter does not preserve Markdown presentation
/// intents. In particular, headings, paragraphs, and list items are flattened
/// into one paragraph. This renderer keeps those intents and emits the matching
/// block elements while still relying on Foundation for Markdown parsing.
public enum MarkdownHTMLRenderingService {
  public static func renderBody(_ markdown: String) -> String {
    guard !markdown.isEmpty else { return "" }

    do {
      let attributed = try AttributedString(
        markdown: markdown,
        options: AttributedString.MarkdownParsingOptions(
          interpretedSyntax: .full
        )
      )
      return render(attributed)
    } catch {
      return "<pre><code>\(escapeHTML(markdown))</code></pre>"
    }
  }

  /// Renders the explicit, sanitized HTML subset used by the in-app article preview.
  /// The default `renderBody` API intentionally continues to escape all raw HTML.
  public static func renderPreviewBodyAllowingSanitizedHTML(_ markdown: String) -> String {
    let mathPrepared = LocalKaTeXPreviewService.prepare(markdown: markdown)
    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: mathPrepared.markdown)
    let embeddedHTML = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: renderBody(prepared.markdown),
      replacements: prepared.replacements
    )
    return LocalKaTeXPreviewService.restore(
      renderedHTML: embeddedHTML,
      replacements: mathPrepared.replacements
    )
  }

  /// Renders preview HTML with source-line anchors on top-level block elements.
  ///
  /// This is intentionally a preview-only API. The regular renderers continue to
  /// return the historical HTML shape so exports and rich-text copying do not
  /// acquire editor synchronization metadata.
  public static func renderPreviewBodyWithSourceLineAnchorsAllowingSanitizedHTML(
    _ markdown: String,
    startingAtLine: Int = 1
  ) -> String {
    let mathPrepared = LocalKaTeXPreviewService.prepare(markdown: markdown)
    let prepared = MarkdownEmbeddedHTMLService.prepare(markdown: mathPrepared.markdown)
    let embeddedHTML = MarkdownEmbeddedHTMLService.restore(
      renderedHTML: renderBody(prepared.markdown),
      replacements: prepared.replacements
    )
    let renderedHTML = LocalKaTeXPreviewService.restore(
      renderedHTML: embeddedHTML,
      replacements: mathPrepared.replacements
    )

    return addSourceLineAnchors(
      to: renderedHTML,
      sourceLineAnchors: MarkdownSourceLineAnchorScanner.scan(
        markdown,
        startingAtLine: startingAtLine
      )
    )
  }
}

extension MarkdownHTMLRenderingService {
  fileprivate static let sourceAnchorBlockTags: Set<String> = [
    "address", "article", "aside", "audio", "blockquote", "canvas", "dd",
    "details", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer",
    "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "main", "nav",
    "ol", "p", "pre", "section", "table", "ul", "video",
  ]

  fileprivate static let sourceAnchorVoidTags: Set<String> = [
    "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta",
    "param", "source", "track", "wbr",
  ]

  fileprivate struct OpenBlock {
    let identity: Int
    let closingHTML: String
    let suppressesText: Bool
    let rendersVerbatimText: Bool
  }

  fileprivate static func render(_ attributed: AttributedString) -> String {
    var html = ""
    var openBlocks: [OpenBlock] = []

    for run in attributed.runs {
      let components = Array(
        (run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]?.components
          ?? []).reversed()
      )
      let identities = components.map(\.identity)
      let commonCount = commonPrefixCount(
        openBlocks.map(\.identity),
        identities
      )

      for block in openBlocks[commonCount...].reversed() {
        html += block.closingHTML
      }
      openBlocks.removeLast(openBlocks.count - commonCount)

      for (index, component) in components.dropFirst(commonCount).enumerated() {
        let componentIndex = commonCount + index
        let block = block(
          for: component,
          components: components,
          componentIndex: componentIndex
        )
        html += block.openingHTML
        openBlocks.append(block.openBlock)
      }

      guard openBlocks.last?.suppressesText != true else {
        continue
      }

      let text = String(attributed[run.range].characters)
      if openBlocks.contains(where: \.rendersVerbatimText) {
        html += escapeHTML(text)
      } else {
        html += renderInline(text, run: run)
      }
    }

    for block in openBlocks.reversed() {
      html += block.closingHTML
    }
    return html
  }

  fileprivate static func commonPrefixCount(_ lhs: [Int], _ rhs: [Int]) -> Int {
    zip(lhs, rhs).prefix(while: ==).count
  }

  fileprivate static func block(
    for component: PresentationIntent.IntentType,
    components: [PresentationIntent.IntentType],
    componentIndex: Int
  ) -> (openingHTML: String, openBlock: OpenBlock) {
    let openingHTML: String
    let closingHTML: String
    let suppressesText: Bool
    let rendersVerbatimText: Bool

    switch component.kind {
    case .paragraph:
      openingHTML = "<p>"
      closingHTML = "</p>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .header(let level):
      let safeLevel = min(max(level, 1), 6)
      openingHTML = "<h\(safeLevel)>"
      closingHTML = "</h\(safeLevel)>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .unorderedList:
      openingHTML = "<ul>\n"
      closingHTML = "</ul>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .orderedList:
      openingHTML = "<ol>\n"
      closingHTML = "</ol>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .listItem:
      openingHTML = "<li>"
      closingHTML = "</li>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .blockQuote:
      openingHTML = "<blockquote>\n"
      closingHTML = "</blockquote>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .codeBlock(let languageHint):
      let languageClass =
        languageHint
        .flatMap(safeLanguageClass)
        .map { " class=\"language-\($0)\"" }
        ?? ""
      openingHTML = "<pre><code\(languageClass)>"
      closingHTML = "</code></pre>\n"
      suppressesText = false
      rendersVerbatimText = true
    case .thematicBreak:
      openingHTML = "<hr>\n"
      closingHTML = ""
      suppressesText = true
      rendersVerbatimText = false
    case .table:
      openingHTML = "<table>\n"
      closingHTML = "</table>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .tableHeaderRow:
      openingHTML = "<thead><tr>"
      closingHTML = "</tr></thead>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .tableRow:
      openingHTML = "<tbody><tr>"
      closingHTML = "</tr></tbody>\n"
      suppressesText = false
      rendersVerbatimText = false
    case .tableCell:
      let isHeader = components[..<componentIndex].contains {
        if case .tableHeaderRow = $0.kind { return true }
        return false
      }
      openingHTML = isHeader ? "<th>" : "<td>"
      closingHTML = isHeader ? "</th>" : "</td>"
      suppressesText = false
      rendersVerbatimText = false
    default:
      openingHTML = "<div>"
      closingHTML = "</div>\n"
      suppressesText = false
      rendersVerbatimText = false
    }

    return (
      openingHTML,
      OpenBlock(
        identity: component.identity,
        closingHTML: closingHTML,
        suppressesText: suppressesText,
        rendersVerbatimText: rendersVerbatimText
      )
    )
  }

  fileprivate static func renderInline(
    _ text: String,
    run: AttributedString.Runs.Run
  ) -> String {
    let intent = run[
      AttributeScopes.FoundationAttributes.InlinePresentationIntentAttribute.self
    ]
    if intent?.contains(.lineBreak) == true {
      return "<br>\n"
    }

    var result = escapeHTML(text)

    if let imageURL = run[AttributeScopes.FoundationAttributes.ImageURLAttribute.self],
      let source = safeURLString(imageURL, allowsImageData: true)
    {
      return "<img src=\"\(escapeHTMLAttribute(source))\" alt=\"\(escapeHTMLAttribute(text))\">"
    }
    if intent?.contains(.code) == true {
      result = "<code>\(result)</code>"
    }
    if intent?.contains(.stronglyEmphasized) == true {
      result = "<strong>\(result)</strong>"
    }
    if intent?.contains(.emphasized) == true {
      result = "<em>\(result)</em>"
    }
    if intent?.contains(.strikethrough) == true {
      result = "<del>\(result)</del>"
    }
    if let link = run[AttributeScopes.FoundationAttributes.LinkAttribute.self],
      let destination = safeURLString(link, allowsImageData: false)
    {
      result = "<a href=\"\(escapeHTMLAttribute(destination))\">\(result)</a>"
    }
    return result
  }

  fileprivate static func safeLanguageClass(_ value: String) -> String? {
    let safe = value.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    }
    return String(String.UnicodeScalarView(safe)).nilIfEmpty
  }

  fileprivate static func safeURLString(
    _ url: URL,
    allowsImageData: Bool
  ) -> String? {
    let value = url.absoluteString
    guard let scheme = url.scheme?.lowercased() else {
      return value
    }
    if ["http", "https", "mailto"].contains(scheme) {
      return value
    }
    if allowsImageData,
      scheme == "data",
      value.lowercased().hasPrefix("data:image/")
    {
      return value
    }
    return nil
  }

  fileprivate static func escapeHTML(_ value: String) -> String {
    MarkupEscaping.html(value)
  }

  fileprivate static func escapeHTMLAttribute(_ value: String) -> String {
    escapeHTML(value)
  }

  fileprivate static func addSourceLineAnchors(
    to html: String,
    sourceLineAnchors: [Int]
  ) -> String {
    guard !html.isEmpty, !sourceLineAnchors.isEmpty else { return html }

    var result = ""
    result.reserveCapacity(html.utf8.count + sourceLineAnchors.count * 24)
    var openTags: [String] = []
    var nextAnchorIndex = 0
    var cursor = html.startIndex

    while cursor < html.endIndex {
      guard let tagStart = html[cursor...].firstIndex(of: "<") else {
        result += html[cursor...]
        break
      }
      if tagStart > cursor {
        result += html[cursor..<tagStart]
      }

      guard let tagEnd = htmlTagEnd(in: html, startingAt: tagStart) else {
        result += html[tagStart...]
        break
      }

      let rawTag = String(html[tagStart...tagEnd])
      guard let tagName = htmlTagName(rawTag) else {
        result += rawTag
        cursor = html.index(after: tagEnd)
        continue
      }

      if isClosingHTMLTag(rawTag) {
        result += rawTag
        if let openIndex = openTags.lastIndex(of: tagName) {
          openTags.removeSubrange(openIndex...)
        }
      } else {
        var outputTag = rawTag
        let isTopLevelBlock = openTags.isEmpty && sourceAnchorBlockTags.contains(tagName)
        if isTopLevelBlock, nextAnchorIndex < sourceLineAnchors.count {
          outputTag = addingSourceLineAttribute(
            to: rawTag,
            line: sourceLineAnchors[nextAnchorIndex]
          )
          nextAnchorIndex += 1
        }
        result += outputTag
        if !sourceAnchorVoidTags.contains(tagName), !isSelfClosingHTMLTag(rawTag) {
          openTags.append(tagName)
        }
      }
      cursor = html.index(after: tagEnd)
    }

    return result
  }

  fileprivate static func htmlTagEnd(in html: String, startingAt start: String.Index) -> String
    .Index?
  {
    var cursor = start
    var quote: Character?
    while cursor < html.endIndex {
      let character = html[cursor]
      if let activeQuote = quote {
        if character == activeQuote {
          quote = nil
        }
      } else if character == "\"" || character == "'" {
        quote = character
      } else if character == ">" {
        return cursor
      }
      cursor = html.index(after: cursor)
    }
    return nil
  }

  fileprivate static func htmlTagName(_ rawTag: String) -> String? {
    var remainder = rawTag.dropFirst()
    if remainder.first == "/" {
      remainder = remainder.dropFirst()
    }
    while let first = remainder.first,
      first == " " || first == "\t" || first == "\n" || first == "\r"
    {
      remainder = remainder.dropFirst()
    }
    guard let first = remainder.first, first.isLetter else { return nil }
    let name = remainder.prefix { $0.isLetter || $0.isNumber || $0 == ":" || $0 == "-" }
    guard !name.isEmpty else { return nil }
    return String(name).lowercased()
  }

  fileprivate static func isClosingHTMLTag(_ rawTag: String) -> Bool {
    var remainder = rawTag.dropFirst()
    while let first = remainder.first,
      first == " " || first == "\t" || first == "\n" || first == "\r"
    {
      remainder = remainder.dropFirst()
    }
    return remainder.first == "/"
  }

  fileprivate static func isSelfClosingHTMLTag(_ rawTag: String) -> Bool {
    guard let closing = rawTag.lastIndex(of: ">") else { return false }
    var cursor = closing
    while cursor > rawTag.startIndex {
      let previous = rawTag.index(before: cursor)
      let character = rawTag[previous]
      if character == " " || character == "\t" || character == "\n" || character == "\r" {
        cursor = previous
        continue
      }
      return character == "/"
    }
    return false
  }

  fileprivate static func addingSourceLineAttribute(to rawTag: String, line: Int) -> String {
    guard !rawTag.contains("data-source-line=") else { return rawTag }
    guard let closing = rawTag.lastIndex(of: ">") else { return rawTag }

    var insertion = closing
    while insertion > rawTag.startIndex {
      let previous = rawTag.index(before: insertion)
      let character = rawTag[previous]
      if character == " " || character == "\t" || character == "\n" || character == "\r" {
        insertion = previous
      } else {
        break
      }
    }
    if insertion > rawTag.startIndex,
      rawTag[rawTag.index(before: insertion)] == "/"
    {
      insertion = rawTag.index(before: insertion)
    }

    return String(rawTag[..<insertion])
      + " data-source-line=\"\(line)\""
      + String(rawTag[insertion...])
  }
}

private enum MarkdownSourceLineAnchorScanner {
  struct SourceLine {
    let number: Int
    let text: String
  }

  struct ListMarker {
    let indent: Int
    let ordered: Bool
  }

  static func scan(_ markdown: String, startingAtLine: Int) -> [Int] {
    let lines =
      markdown
      .components(separatedBy: "\n")
      .enumerated()
      .map { index, rawLine in
        SourceLine(
          number: max(1, startingAtLine) + index,
          text: rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        )
      }
    guard !lines.isEmpty else { return [] }

    var anchors: [Int] = []
    var index = 0
    while index < lines.count {
      let line = lines[index].text
      if isBlank(line) {
        index += 1
        continue
      }

      if let fence = fenceMarker(in: line) {
        anchors.append(lines[index].number)
        index += 1
        while index < lines.count {
          let closingLine = lines[index].text
          index += 1
          if isClosingFence(closingLine, matching: fence) {
            break
          }
        }
        continue
      }

      if isIndentedCodeLine(line) {
        anchors.append(lines[index].number)
        index += 1
        while index < lines.count,
          isBlank(lines[index].text) || isIndentedCodeLine(lines[index].text)
        {
          index += 1
        }
        continue
      }

      if isATXHeading(line) {
        anchors.append(lines[index].number)
        index += 1
        continue
      }

      if isThematicBreak(line) {
        anchors.append(lines[index].number)
        index += 1
        continue
      }

      if isBlockQuote(line) {
        anchors.append(lines[index].number)
        index = endOfBlockQuote(lines, from: index)
        continue
      }

      if let marker = listMarker(in: line) {
        anchors.append(lines[index].number)
        index = endOfList(lines, from: index, marker: marker)
        continue
      }

      if isTableHeader(lines, at: index) {
        anchors.append(lines[index].number)
        index = endOfTable(lines, from: index)
        continue
      }

      if index + 1 < lines.count, isSetextUnderline(lines[index + 1].text) {
        anchors.append(lines[index].number)
        index += 2
        continue
      }

      anchors.append(lines[index].number)
      index = endOfParagraph(lines, from: index)
    }
    return anchors
  }

  static func endOfParagraph(_ lines: [SourceLine], from start: Int) -> Int {
    var index = start + 1
    while index < lines.count {
      let line = lines[index].text
      if isBlank(line) {
        break
      }
      if isSetextUnderline(line) {
        index += 1
        break
      }
      if isBlockStart(lines, at: index) {
        break
      }
      index += 1
    }
    return index
  }

  static func isBlockStart(_ lines: [SourceLine], at index: Int) -> Bool {
    let line = lines[index].text
    if fenceMarker(in: line) != nil || isATXHeading(line) {
      return true
    }
    if isBlockQuote(line) || isThematicBreak(line) || listMarker(in: line) != nil {
      return true
    }
    return isTableHeader(lines, at: index)
  }

  static func endOfBlockQuote(_ lines: [SourceLine], from start: Int) -> Int {
    var index = start + 1
    while index < lines.count {
      if isBlockQuote(lines[index].text) {
        index += 1
        continue
      }
      if isBlank(lines[index].text),
        index + 1 < lines.count,
        isBlockQuote(lines[index + 1].text)
      {
        index += 1
        continue
      }
      if !isBlank(lines[index].text), !isBlockStart(lines, at: index) {
        index += 1
        continue
      }
      break
    }
    return index
  }

  static func endOfList(
    _ lines: [SourceLine],
    from start: Int,
    marker: ListMarker
  ) -> Int {
    var index = start + 1
    while index < lines.count {
      let line = lines[index].text
      if isBlank(line) {
        guard index + 1 < lines.count else { return index + 1 }
        if !isThematicBreak(lines[index + 1].text),
          let nextMarker = listMarker(in: lines[index + 1].text),
          nextMarker.indent == marker.indent,
          nextMarker.ordered == marker.ordered
        {
          index += 1
          continue
        }
        if leadingIndent(of: lines[index + 1].text) > marker.indent {
          index += 1
          continue
        }
        return index
      }

      if isThematicBreak(line) {
        return index
      }

      if let nextMarker = listMarker(in: line) {
        if nextMarker.indent == marker.indent,
          nextMarker.ordered == marker.ordered
        {
          index += 1
          continue
        }
        if nextMarker.indent > marker.indent {
          index += 1
          continue
        }
        return index
      }

      if leadingIndent(of: line) > marker.indent {
        index += 1
        continue
      }

      // CommonMark permits a lazy continuation line in a list item. Keep it
      // with this list until a blank line or another top-level block appears.
      if isBlockQuote(line) || isATXHeading(line) || isThematicBreak(line)
        || fenceMarker(in: line) != nil
      {
        return index
      }
      index += 1
    }
    return index
  }

  static func endOfTable(_ lines: [SourceLine], from start: Int) -> Int {
    var index = start + 2
    while index < lines.count {
      let line = lines[index].text
      guard !isBlank(line), line.contains("|") else { break }
      index += 1
    }
    return index
  }

  static func isTableHeader(_ lines: [SourceLine], at index: Int) -> Bool {
    guard index + 1 < lines.count else { return false }
    guard lines[index].text.contains("|") else { return false }
    return isTableSeparator(lines[index + 1].text)
  }

  static func isTableSeparator(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("|") else { return false }
    let cells =
      trimmed
      .split(separator: "|", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard cells.count >= 2 else { return false }
    return cells.allSatisfy { cell in
      guard !cell.isEmpty else { return false }
      var content = cell[...]
      if content.first == ":" { content = content.dropFirst() }
      if content.last == ":" { content = content.dropLast() }
      return content.count >= 3 && content.allSatisfy { $0 == "-" }
    }
  }

  static func isATXHeading(_ line: String) -> Bool {
    let indent = leadingIndent(of: line)
    guard indent <= 3 else { return false }
    let content = line.dropFirst(indent)
    let hashes = content.prefix { $0 == "#" }
    guard (1...6).contains(hashes.count) else { return false }
    guard content.dropFirst(hashes.count).first.map({ $0 == " " || $0 == "\t" }) ?? true else {
      return false
    }
    return true
  }

  static func isBlockQuote(_ line: String) -> Bool {
    let indent = leadingIndent(of: line)
    guard indent <= 3 else { return false }
    let content = line.dropFirst(indent)
    return content.first == ">"
  }

  static func isThematicBreak(_ line: String) -> Bool {
    let content = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = content.first, first == "-" || first == "_" || first == "*" else {
      return false
    }
    let marks = content.filter { $0 != " " && $0 != "\t" }
    return marks.count >= 3 && marks.allSatisfy { $0 == first }
  }

  static func isSetextUnderline(_ line: String) -> Bool {
    let content = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let first = content.first, first == "=" || first == "-" else { return false }
    let minimum = first == "=" ? 1 : 3
    return content.count >= minimum && content.allSatisfy { $0 == first }
  }

  static func isBlank(_ line: String) -> Bool {
    line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  static func isIndentedCodeLine(_ line: String) -> Bool {
    guard !line.isEmpty else { return false }
    if line.first == "\t" { return true }
    var spaces = 0
    for character in line {
      guard character == " " else { break }
      spaces += 1
    }
    return spaces >= 4
  }

  static func leadingIndent(of line: String) -> Int {
    var count = 0
    for character in line {
      if character == " " {
        count += 1
      } else if character == "\t" {
        count += 4
      } else {
        break
      }
    }
    return count
  }

  static func fenceMarker(in line: String) -> (character: Character, length: Int)? {
    let indent = leadingIndent(of: line)
    guard indent <= 3 else { return nil }
    let content = line.dropFirst(min(indent, line.count))
    guard let first = content.first, first == "`" || first == "~" else { return nil }
    let run = content.prefix { $0 == first }
    guard run.count >= 3 else { return nil }
    if first == "`", content.dropFirst(run.count).contains("`") {
      return nil
    }
    return (first, run.count)
  }

  static func isClosingFence(
    _ line: String,
    matching fence: (character: Character, length: Int)
  ) -> Bool {
    let indent = leadingIndent(of: line)
    guard indent <= 3 else { return false }
    let content = line.dropFirst(min(indent, line.count))
    let run = content.prefix { $0 == fence.character }
    guard run.count >= fence.length else { return false }
    return content.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\t" }
  }

  static func listMarker(in line: String) -> ListMarker? {
    let indent = leadingIndent(of: line)
    guard indent <= 3 else { return nil }
    let content = Array(line.dropFirst(min(indent, line.count)))
    guard !content.isEmpty else { return nil }

    if content[0] == "-" || content[0] == "+" || content[0] == "*" {
      guard content.count == 1 || content[1] == " " || content[1] == "\t" else { return nil }
      return ListMarker(indent: indent, ordered: false)
    }

    var cursor = 0
    while cursor < content.count, content[cursor].isNumber {
      cursor += 1
    }
    guard cursor > 0, cursor + 1 < content.count,
      content[cursor] == "." || content[cursor] == ")",
      content[cursor + 1] == " " || content[cursor + 1] == "\t"
    else {
      return nil
    }
    return ListMarker(indent: indent, ordered: true)
  }
}
