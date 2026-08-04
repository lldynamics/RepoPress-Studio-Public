import Foundation

public enum MarkdownPreviewSourceLinkService {
  public static let urlScheme = "publisher-source"

  public static func sourceURLString(location: Int) -> String {
    "\(urlScheme)://jump/\(max(0, location))"
  }

  public static func sourceLocation(from url: URL) -> Int? {
    guard
      url.scheme?.lowercased() == urlScheme,
      url.host?.lowercased() == "jump",
      let locationText = url.pathComponents.dropFirst().first,
      let location = Int(locationText),
      location >= 0
    else {
      return nil
    }
    return location
  }

  /// Adds a small source-navigation affordance to rendered Markdown headings.
  /// It does not require JavaScript and leaves existing heading/link markup
  /// untouched.
  public static func annotatingHeadingLinks(
    in renderedHTML: String,
    sourceMarkdown: String
  ) -> String {
    let headings = sourceHeadings(in: sourceMarkdown)
    guard !headings.isEmpty else { return renderedHTML }
    guard
      let expression = try? NSRegularExpression(
        pattern: #"<h([1-6])\b[^>]*>[\s\S]*?</h\1\s*>"#,
        options: [.caseInsensitive]
      )
    else {
      return renderedHTML
    }

    let htmlSource = renderedHTML as NSString
    let matches = expression.matches(
      in: renderedHTML,
      range: NSRange(location: 0, length: htmlSource.length)
    )
    guard !matches.isEmpty else { return renderedHTML }

    var sourceCursor = 0
    var insertions: [(location: Int, value: String)] = []
    for match in matches {
      guard match.numberOfRanges > 1 else { continue }
      let levelText = htmlSource.substring(with: match.range(at: 1))
      guard let level = Int(levelText) else { continue }
      guard
        let headingIndex = headings[sourceCursor...].firstIndex(where: { $0.level == level })
      else {
        continue
      }
      let heading = headings[headingIndex]
      sourceCursor = headingIndex + 1

      let fullMarkup = htmlSource.substring(with: match.range)
      guard
        let closingRange = fullMarkup.range(
          of: "</h\(level)",
          options: [.caseInsensitive, .backwards]
        )
      else {
        continue
      }
      let insertionOffset = fullMarkup[..<closingRange.lowerBound].utf16.count
      let sourceURL = sourceURLString(location: heading.location)
      insertions.append(
        (
          location: match.range.location + insertionOffset,
          value:
            " <a class=\"repopress-source-jump\" href=\"\(sourceURL)\" "
            + "title=\"在编辑器中定位\" aria-label=\"在编辑器中定位\">¶</a>"
        )
      )
    }

    let mutableHTML = NSMutableString(string: renderedHTML)
    for insertion in insertions.sorted(by: { $0.location > $1.location }) {
      mutableHTML.insert(insertion.value, at: insertion.location)
    }
    return mutableHTML as String
  }

  private struct SourceHeading {
    var level: Int
    var location: Int
  }

  private static func sourceHeadings(in markdown: String) -> [SourceHeading] {
    let source = markdown as NSString
    guard
      let expression = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]{0,3}(#{1,6})[ \t]+.+?[ \t#]*$"#
      )
    else {
      return []
    }
    let codeRanges = MarkdownCodeRangeScanner.scan(markdown).allRanges
    return expression.matches(
      in: markdown,
      range: NSRange(location: 0, length: source.length)
    ).compactMap { match in
      guard
        match.numberOfRanges > 1,
        !codeRanges.contains(where: { NSLocationInRange(match.range.location, $0) })
      else {
        return nil
      }
      return SourceHeading(
        level: source.substring(with: match.range(at: 1)).count,
        location: match.range.location
      )
    }
  }
}
