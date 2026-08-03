import Foundation

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
}

private extension MarkdownHTMLRenderingService {
  struct OpenBlock {
    let identity: Int
    let closingHTML: String
    let suppressesText: Bool
    let rendersVerbatimText: Bool
  }

  static func render(_ attributed: AttributedString) -> String {
    var html = ""
    var openBlocks: [OpenBlock] = []

    for run in attributed.runs {
      let components = Array(
        (
          run[AttributeScopes.FoundationAttributes.PresentationIntentAttribute.self]?.components
            ?? []
        ).reversed()
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

  static func commonPrefixCount(_ lhs: [Int], _ rhs: [Int]) -> Int {
    zip(lhs, rhs).prefix(while: ==).count
  }

  static func block(
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
    case let .header(level):
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
    case let .codeBlock(languageHint):
      let languageClass = languageHint
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

  static func renderInline(
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
       let source = safeURLString(imageURL, allowsImageData: true) {
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
       let destination = safeURLString(link, allowsImageData: false) {
      result = "<a href=\"\(escapeHTMLAttribute(destination))\">\(result)</a>"
    }
    return result
  }

  static func safeLanguageClass(_ value: String) -> String? {
    let safe = value.unicodeScalars.filter {
      CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
    }
    return String(String.UnicodeScalarView(safe)).nilIfEmpty
  }

  static func safeURLString(
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
       value.lowercased().hasPrefix("data:image/") {
      return value
    }
    return nil
  }

  static func escapeHTML(_ value: String) -> String {
    MarkupEscaping.html(value)
  }

  static func escapeHTMLAttribute(_ value: String) -> String {
    escapeHTML(value)
  }
}
