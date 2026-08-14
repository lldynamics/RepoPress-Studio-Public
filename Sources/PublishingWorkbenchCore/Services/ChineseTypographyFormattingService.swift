import Foundation

/// Provides automated Chinese-Western mixed typography formatting ("Pangu Spacing"),
/// punctuation normalization, and whitespace cleanup while strictly preserving
/// Markdown syntax, Front Matter, code blocks, URLs, and inline markup.
public struct ChineseTypographyFormattingService: Sendable {
  public init() {}

  /// Formats the given Markdown document or snippet.
  public static func format(markdown: String) -> String {
    ChineseTypographyFormattingService().formattedText(for: markdown)
  }

  /// Plans a formatted text edit for the selected range or entire document as a single undoable transaction.
  public func formattingEdit(
    in markdown: String,
    selectedRange: NSRange? = nil
  ) -> MarkdownSmartEdit? {
    let source = markdown as NSString
    let targetRange: NSRange
    if let selectedRange, selectedRange.length > 0 {
      targetRange = NSRange(
        location: min(max(0, selectedRange.location), source.length),
        length: min(selectedRange.length, source.length - min(max(0, selectedRange.location), source.length))
      )
    } else {
      targetRange = NSRange(location: 0, length: source.length)
    }

    guard targetRange.length > 0 else { return nil }
    let originalSubtext = source.substring(with: targetRange)
    let formattedSubtext = formattedText(for: originalSubtext)
    guard formattedSubtext != originalSubtext else { return nil }

    let newSelectionLength = (selectedRange?.length ?? 0) > 0 ? (formattedSubtext as NSString).length : 0
    return MarkdownSmartEdit(
      replacedRange: targetRange,
      replacement: formattedSubtext,
      selectedRange: NSRange(location: targetRange.location, length: newSelectionLength)
    )
  }

  /// Transforms text by adding spacing between CJK and Latin/digits, normalizing punctuation, and cleaning whitespace.
  public func formattedText(for markdown: String) -> String {
    guard !markdown.isEmpty else { return "" }

    // 1. Extract protected blocks and replace with placeholders
    var protectedTokens: [String: String] = [:]
    var tokenIndex = 0

    func makePlaceholder() -> String {
      let token = "___CHINESE_TYPOGRAPHY_PROTECTED_\(tokenIndex)___"
      tokenIndex += 1
      return token
    }

    var processed = markdown

    // Protect Front Matter (only at start of text)
    if processed.hasPrefix("---") {
      let fmPattern = #"^---\r?\n[\s\S]*?\r?\n---\r?\n?"#
      if let fmRegex = try? NSRegularExpression(pattern: fmPattern) {
        let ns = processed as NSString
        if let match = fmRegex.firstMatch(in: processed, range: NSRange(location: 0, length: ns.length)) {
          let fmText = ns.substring(with: match.range)
          let token = makePlaceholder()
          protectedTokens[token] = fmText
          processed = (processed as NSString).replacingCharacters(in: match.range, with: token)
        }
      }
    }

    // Protect Fenced Code Blocks (``` or ~~~)
    let fencedCodePattern = #"(?m)^([ \t]*)(`{3,}|~{3,})[^\n]*\n[\s\S]*?\n\1\2[ \t]*$"#
    processed = replaceMatches(in: processed, pattern: fencedCodePattern) { matchText in
      let token = makePlaceholder()
      protectedTokens[token] = matchText
      return token
    }

    // Protect Math display blocks ($$...$$)
    let mathBlockPattern = #"\$\$[\s\S]*?\$\$"#
    processed = replaceMatches(in: processed, pattern: mathBlockPattern) { matchText in
      let token = makePlaceholder()
      protectedTokens[token] = matchText
      return token
    }

    // Protect Inline Code (`...`)
    let inlineCodePattern = #"`[^`\n]+`"#
    processed = replaceMatches(in: processed, pattern: inlineCodePattern) { matchText in
      let token = makePlaceholder()
      protectedTokens[token] = matchText
      return token
    }

    // Protect HTML tags (<...>)
    let htmlTagPattern = #"<[^>\n]+>"#
    processed = replaceMatches(in: processed, pattern: htmlTagPattern) { matchText in
      let token = makePlaceholder()
      protectedTokens[token] = matchText
      return token
    }

    // Protect Markdown links & images destination URL [text](url) -> protect (url)
    let linkDestPattern = #"(?<=\])\([^)\n]+\)"#
    processed = replaceMatches(in: processed, pattern: linkDestPattern) { matchText in
      let token = makePlaceholder()
      protectedTokens[token] = matchText
      return token
    }

    // Protect SSG Shortcodes / Component tags ({{< ... >}}, {% ... %})
    let ssgPattern = #"(\{\{<[\s\S]*?>\}\}|\{\{[\s\S]*?\}\}|\{%.*?%\})"#
    processed = replaceMatches(in: processed, pattern: ssgPattern) { matchText in
      let token = makePlaceholder()
      protectedTokens[token] = matchText
      return token
    }

    // 2. Perform Typography Formatting on unprotected text
    processed = formatTypography(processed)

    // 3. Restore protected blocks
    for (token, originalText) in protectedTokens {
      processed = processed.replacingOccurrences(of: token, with: originalText)
    }

    return processed
  }

  // MARK: - Typography Rules

  private func formatTypography(_ text: String) -> String {
    var result = text

    let cjkRange = #"[\u4e00-\u9fa5\u3400-\u4dbf\uf900-\ufaff]"#

    // Rule 1: CJK followed by Latin Letter
    result = applyRegex(
      to: result,
      pattern: "(\(cjkRange))([a-zA-Z])",
      template: "$1 $2"
    )

    // Rule 2: Latin Letter followed by CJK
    result = applyRegex(
      to: result,
      pattern: "([a-zA-Z])(\(cjkRange))",
      template: "$1 $2"
    )

    // Rule 3: CJK followed by Digit
    result = applyRegex(
      to: result,
      pattern: "(\(cjkRange))([0-9])",
      template: "$1 $2"
    )

    // Rule 4: Digit followed by CJK
    result = applyRegex(
      to: result,
      pattern: "([0-9])(\(cjkRange))",
      template: "$1 $2"
    )

    // Rule 5: Remove spaces preceding full-width punctuation
    result = applyRegex(
      to: result,
      pattern: "[ \t]+([，。！？；：、）》】」』”’（《【「『“‘])",
      template: "$1"
    )

    // Rule 6: Remove spaces succeeding full-width open punctuation
    result = applyRegex(
      to: result,
      pattern: "([（《【「『“‘])[ \t]+",
      template: "$1"
    )

    // Rule 6a: Remove spaces succeeding full-width closing/general punctuation
    result = applyRegex(
      to: result,
      pattern: "([，。！？；：、）》】」』”’])[ \t]+",
      template: "$1"
    )

    // Rule 7: Clean trailing spaces on lines
    result = applyRegex(
      to: result,
      pattern: "(?m)[ \t]+$",
      template: ""
    )

    // Rule 8: Collapse 3+ consecutive newlines into 2 (max 1 empty line between paragraphs)
    result = applyRegex(
      to: result,
      pattern: "\n{3,}",
      template: "\n\n"
    )

    return result
  }

  // MARK: - Helpers

  private func applyRegex(to text: String, pattern: String, template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let ns = text as NSString
    return regex.stringByReplacingMatches(
      in: text,
      range: NSRange(location: 0, length: ns.length),
      withTemplate: template
    )
  }

  private func replaceMatches(
    in text: String,
    pattern: String,
    transform: (String) -> String
  ) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    let ns = text as NSString
    let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
    guard !matches.isEmpty else { return text }

    var result = ""
    var lastIndex = 0

    for match in matches {
      let matchRange = match.range
      if matchRange.location > lastIndex {
        result += ns.substring(with: NSRange(location: lastIndex, length: matchRange.location - lastIndex))
      }
      let matchText = ns.substring(with: matchRange)
      result += transform(matchText)
      lastIndex = NSMaxRange(matchRange)
    }

    if lastIndex < ns.length {
      result += ns.substring(from: lastIndex)
    }

    return result
  }
}
