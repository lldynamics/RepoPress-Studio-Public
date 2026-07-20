import AppKit
import PublishingWorkbenchCore

enum MarkdownPasteboardReader {
  struct RichTextContent {
    let html: String
    let baseURL: URL?
  }

  static func imageFileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)?
      .compactMap { ($0 as? URL)?.standardizedFileURL }
      .filter(\.isFileURL)
      ?? []
    return ImageFileSupport.supportedImageURLs(in: fileURLs)
  }

  static func pngData(from pasteboard: NSPasteboard) -> Data? {
    if let pngData = pasteboard.data(forType: .png), !pngData.isEmpty {
      return pngData
    }
    guard let image = NSImage(pasteboard: pasteboard),
          let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData) else {
      return nil
    }
    return bitmap.representation(using: .png, properties: [:])
  }

  static func richTextContent(from pasteboard: NSPasteboard) -> RichTextContent? {
    let baseURL = pasteboard.string(forType: .URL).flatMap { value -> URL? in
      guard let url = URL(string: value),
            let scheme = url.scheme?.lowercased(),
            ["http", "https"].contains(scheme) else {
        return nil
      }
      return url
    }

    if let html = pasteboard.string(forType: .html)?.nilIfEmpty {
      return RichTextContent(html: html, baseURL: baseURL)
    }
    if let data = pasteboard.data(forType: .html),
       let html = decodedHTML(data)?.nilIfEmpty {
      return RichTextContent(html: html, baseURL: baseURL)
    }
    if let attributed = attributedString(from: pasteboard, type: .rtf, documentType: .rtf) {
      return RichTextContent(
        html: semanticHTML(from: attributed),
        baseURL: baseURL
      )
    }
    if let attributed = attributedString(from: pasteboard, type: .rtfd, documentType: .rtfd) {
      return RichTextContent(
        html: semanticHTML(from: attributed),
        baseURL: baseURL
      )
    }
    return nil
  }

  static func shouldPreferRichConversion(
    _ markdown: String,
    over plainText: String?
  ) -> Bool {
    guard let plainText else { return true }
    return normalizedPasteComparison(markdown) != normalizedPasteComparison(plainText)
  }

  private static func attributedString(
    from pasteboard: NSPasteboard,
    type: NSPasteboard.PasteboardType,
    documentType: NSAttributedString.DocumentType
  ) -> NSAttributedString? {
    guard let data = pasteboard.data(forType: type), !data.isEmpty else { return nil }
    return try? NSAttributedString(
      data: data,
      options: [.documentType: documentType],
      documentAttributes: nil
    )
  }

  private static func decodedHTML(_ data: Data) -> String? {
    for encoding in [
      String.Encoding.utf8,
      .utf16,
      .unicode,
      .windowsCP1252,
      .isoLatin1,
    ] {
      if let value = String(data: data, encoding: encoding), !value.isEmpty {
        return value
      }
    }
    return nil
  }

  private static func semanticHTML(from attributed: NSAttributedString) -> String {
    let source = attributed.string as NSString
    guard source.length > 0 else { return "" }
    var html = "<article>"
    var cursor = 0
    var openList: RichTextListKind?

    func closeOpenList() {
      if let openList {
        html += openList == .ordered ? "</ol>" : "</ul>"
      }
      openList = nil
    }

    while cursor < source.length {
      let paragraphRange = source.paragraphRange(
        for: NSRange(location: cursor, length: 0)
      )
      var contentRange = paragraphRange
      while contentRange.length > 0,
            source.substring(
              with: NSRange(location: NSMaxRange(contentRange) - 1, length: 1)
            ).rangeOfCharacter(from: .newlines) != nil {
        contentRange.length -= 1
      }
      let plainParagraph = source.substring(with: contentRange)
      let list = richTextListKind(
        for: attributed,
        paragraphRange: contentRange,
        plainText: plainParagraph
      )
      let markerLength = listMarkerLength(in: plainParagraph, kind: list)
      let semanticRange = NSRange(
        location: min(NSMaxRange(contentRange), contentRange.location + markerLength),
        length: max(0, contentRange.length - markerLength)
      )
      let inline = semanticInlineHTML(from: attributed, range: semanticRange)

      if let list {
        if openList != list {
          closeOpenList()
          html += list == .ordered ? "<ol>" : "<ul>"
          openList = list
        }
        html += "<li>\(inline)</li>"
      } else {
        closeOpenList()
        let headingLevel = inferredHeadingLevel(in: attributed, range: contentRange)
        if let headingLevel, !inline.isEmpty {
          html += "<h\(headingLevel)>\(inline)</h\(headingLevel)>"
        } else {
          html += "<p>\(inline)</p>"
        }
      }
      cursor = NSMaxRange(paragraphRange)
    }
    closeOpenList()
    html += "</article>"
    return html
  }

  private static func semanticInlineHTML(
    from attributed: NSAttributedString,
    range: NSRange
  ) -> String {
    guard range.length > 0 else { return "" }
    var html = ""
    attributed.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
      var fragment = escapedHTML((attributed.string as NSString).substring(with: runRange))
      guard !fragment.isEmpty else { return }
      let font = attributes[.font] as? NSFont
      let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
      if font?.isFixedPitch == true {
        fragment = "<code>\(fragment)</code>"
      }
      if traits.contains(.boldFontMask) {
        fragment = "<strong>\(fragment)</strong>"
      }
      if traits.contains(.italicFontMask) {
        fragment = "<em>\(fragment)</em>"
      }
      if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 {
        fragment = "<del>\(fragment)</del>"
      }
      if let linkValue = attributes[.link] {
        let destination = (linkValue as? URL)?.absoluteString
          ?? (linkValue as? String)
        if let destination = destination?.nilIfEmpty {
          fragment = "<a href=\"\(escapedHTMLAttribute(destination))\">\(fragment)</a>"
        }
      }
      html += fragment
    }
    return html
  }

  private static func inferredHeadingLevel(
    in attributed: NSAttributedString,
    range: NSRange
  ) -> Int? {
    guard range.length > 0 else { return nil }
    var maximumSize: CGFloat = 0
    var containsBold = false
    attributed.enumerateAttribute(.font, in: range, options: []) { value, _, _ in
      guard let font = value as? NSFont else { return }
      maximumSize = max(maximumSize, font.pointSize)
      containsBold = containsBold
        || NSFontManager.shared.traits(of: font).contains(.boldFontMask)
    }
    if maximumSize >= 24 { return 1 }
    if maximumSize >= 19 { return 2 }
    if maximumSize >= 16, containsBold { return 3 }
    return nil
  }

  private static func richTextListKind(
    for attributed: NSAttributedString,
    paragraphRange: NSRange,
    plainText: String
  ) -> RichTextListKind? {
    if paragraphRange.length > 0,
       let style = attributed.attribute(
         .paragraphStyle,
         at: paragraphRange.location,
         effectiveRange: nil
       ) as? NSParagraphStyle,
       let marker = style.textLists.first?.markerFormat.rawValue.lowercased() {
      return marker.contains("decimal")
        || marker.contains("roman")
        || marker.contains("alpha")
        ? .ordered
        : .unordered
    }
    let trimmed = plainText.trimmingCharacters(in: .whitespaces)
    if trimmed.range(of: #"^\d+[\.)][ \t]+"#, options: .regularExpression) != nil {
      return .ordered
    }
    if trimmed.range(of: #"^[•◦▪‣⁃\-+*][ \t]+"#, options: .regularExpression) != nil {
      return .unordered
    }
    return nil
  }

  private static func listMarkerLength(
    in plainText: String,
    kind: RichTextListKind?
  ) -> Int {
    guard kind != nil else { return 0 }
    let source = plainText as NSString
    let pattern = kind == .ordered
      ? #"^[ \t]*\d+[\.)][ \t]+"#
      : #"^[ \t]*[•◦▪‣⁃\-+*][ \t]+"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(
            in: plainText,
            range: NSRange(location: 0, length: source.length)
          ) else {
      return 0
    }
    return match.range.length
  }

  private static func normalizedPasteComparison(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func escapedHTML(_ value: String) -> String {
    escapedHTMLAttribute(value)
  }

  private static func escapedHTMLAttribute(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
  }

  private enum RichTextListKind: Equatable {
    case ordered
    case unordered
  }
}
