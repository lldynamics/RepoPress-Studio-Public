import Foundation
import PublishingCoreSupport

extension MarkdownSSGComponentLibraryService {
  enum PendingStyle: Equatable {
    case directive
    case shortcode(name: String, syntax: MarkdownSSGComponentEngineSyntax)
  }

  struct PendingComponent: Equatable {
    let kind: MarkdownSSGComponentKind
    let title: String
    let style: PendingStyle
    let start: Int
    let contentStart: Int
    let lineNumber: Int
    let tokenRange: NSRange

    var isUnknown: Bool {
      kind == .custom && !title.isEmpty
    }

    func matches(_ name: String) -> Bool {
      switch style {
      case .directive: return false
      case .shortcode(let openName, _): return openName.caseInsensitiveCompare(name) == .orderedSame
      }
    }
  }

  struct ParsedShortcodeToken {
    let name: String
    let arguments: String
    let range: NSRange
    let syntax: MarkdownSSGComponentEngineSyntax
    let isClosing: Bool
    let isSelfClosing: Bool
  }

  static func parseShortcodeTokens(in line: String, base: Int) -> [ParsedShortcodeToken] {
    guard line.contains("{{") || line.contains("{%") else { return [] }
    let patterns: [(String, MarkdownSSGComponentEngineSyntax)] = [
      (#"\{\{\s*<\s*(/?)\s*([A-Za-z][A-Za-z0-9_/-]*)(?:\s+([^>]*?))?\s*>\s*\}\}"#, .hugoAngle),
      (#"\{\{\s*%\s*(/?)\s*([A-Za-z][A-Za-z0-9_/-]*)(?:\s+([^%]*?))?\s*%\s*\}\}"#, .hugoPercent),
      (#"\{\{\s*([A-Za-z][A-Za-z0-9_-]*)\s*\(([^{}]*?)\)\s*\}\}"#, .zolaLegacy),
      (#"\{\{\s*<\s*([A-Za-z][A-Za-z0-9_.-]*)\s*([^>]*?)\s*/>\s*\}\}"#, .zolaInlineComponent),
      (
        #"\{%\s*<\s*(/?)\s*([A-Za-z][A-Za-z0-9_.-]*)(?:\s+([^>]*?))?\s*>\s*%\}"#,
        .zolaInlineComponent
      ),
      (#"\{%\s*(component\s+)?([A-Za-z][A-Za-z0-9_-]*)\s*\(([^{}]*?)\)\s*%\}"#, .zolaComponent),
      (#"\{%\s*(/?)\s*(raw|endraw)\s*%\}"#, .zolaComponent),
    ]
    var result: [ParsedShortcodeToken] = []
    let nsLine = line as NSString
    for (pattern, syntax) in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
      let matches = regex.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
      for match in matches {
        let groups = (1..<match.numberOfRanges).map { index -> String in
          let range = match.range(at: index)
          return range.location == NSNotFound ? "" : nsLine.substring(with: range)
        }
        let name: String
        let args: String
        let closing: Bool
        switch syntax {
        case .hugoAngle, .hugoPercent:
          name = groups[1]
          args = groups[2]
          closing = groups[0] == "/"
        case .zolaLegacy:
          name = groups[0]
          args = groups[1]
          closing = false
        case .zolaInlineComponent:
          if groups.count == 2 {
            name = groups[0]
            args = groups[1]
            closing = false
          } else {
            name = groups[1]
            args = groups[2]
            closing = groups[0] == "/"
          }
        case .zolaComponent:
          if groups.count == 2 {
            name = groups[1]
            args = ""
            closing = groups[0] == "/" || groups[1].lowercased() == "endraw"
          } else {
            name = groups[1]
            args = groups[2]
            closing = false
          }
        }
        let normalizedArgs = args.trimmingCharacters(in: .whitespacesAndNewlines)
        result.append(
          ParsedShortcodeToken(
            name: name, arguments: normalizedArgs,
            range: NSRange(location: base + match.range.location, length: match.range.length),
            syntax: syntax,
            isClosing: closing || name.lowercased() == "endraw",
            isSelfClosing: (syntax == .zolaInlineComponent && groups.count == 2)
              || (syntax == .hugoAngle && normalizedArgs.hasSuffix("/"))))
      }
    }
    var unique: [ParsedShortcodeToken] = []
    for token in result.sorted(by: { $0.range.location < $1.range.location }) {
      if let previous = unique.last, previous.range == token.range {
        if token.syntax == .zolaInlineComponent {
          unique[unique.count - 1] = token
        }
      } else {
        unique.append(token)
      }
    }
    return unique
  }

  static func isFence(_ line: String) -> Bool {
    line.hasPrefix("```") || line.hasPrefix("~~~")
  }

  static func isInInlineCode(_ line: String, offset: Int) -> Bool {
    guard offset > 0 else { return false }
    let nsLine = line as NSString
    let prefix = nsLine.substring(with: NSRange(location: 0, length: min(offset, nsLine.length)))
    return prefix.filter { $0 == "`" }.count % 2 == 1
  }

  struct ParsedHugoOpening {
    let name: String
    let title: String
  }

  static func closes(_ pending: PendingComponent, with line: String) -> Bool {
    switch pending.style {
    case .directive:
      return line == ":::"
    case .shortcode(let name, _):
      return parseShortcodeTokens(in: line, base: 0).contains {
        $0.isClosing && $0.name.lowercased() == name
      }
    }
  }

  static func parseDirectiveOpening(_ line: String) -> (name: String, title: String)? {
    guard let captures = capture(line, pattern: #"^:::\s*([A-Za-z0-9_-]+)(?:\s+(.*))?$"#),
      let name = captures.first?.lowercased(),
      ["tip", "note", "info", "warning", "caution", "danger", "important"].contains(name)
    else {
      return nil
    }
    let explicitTitle = captures.dropFirst().first ?? ""
    return (
      name: name,
      title: explicitTitle.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "提示"
    )
  }

  static func parseHugoOpening(_ line: String) -> ParsedHugoOpening? {
    guard
      let captures = capture(
        line,
        pattern: #"^\{\{<\s*([A-Za-z0-9_-]+)(?:\s+([^>]*?))?\s*>\}\}$"#
      ), let name = captures.first?.trimmingCharacters(in: .whitespacesAndNewlines),
      !name.isEmpty
    else {
      return nil
    }
    return ParsedHugoOpening(
      name: name,
      title: captures.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    )
  }

  static func pairedKind(for name: String) -> MarkdownSSGComponentKind? {
    switch name.lowercased() {
    case "lead":
      return .lead
    case "callout", "admonition":
      return .callout
    default:
      return nil
    }
  }

  static func inlineKind(for name: String) -> MarkdownSSGComponentKind? {
    switch name.lowercased() {
    case "youtube":
      return .youtube
    case "bilibili", "bili":
      return .bilibili
    case "github", "github-card", "githubcard":
      return .githubCard
    case "figure":
      return .figure
    default:
      return .custom
    }
  }

  static func makeOccurrence(
    pending: PendingComponent,
    source: NSString,
    end: Int,
    contentEnd: Int
  ) -> MarkdownSSGComponentOccurrence {
    let safeContentStart = min(max(pending.contentStart, pending.start), source.length)
    let safeContentEnd = min(max(contentEnd, safeContentStart), source.length)
    let contentRange = NSRange(
      location: safeContentStart,
      length: max(0, safeContentEnd - safeContentStart)
    )
    let sourceRange = NSRange(
      location: pending.start,
      length: max(0, min(end, source.length) - pending.start)
    )
    let rawPreview = source.substring(with: contentRange)
    return MarkdownSSGComponentOccurrence(
      id: "\(pending.kind.rawValue)-\(pending.start)",
      kind: pending.kind,
      title: pending.title,
      sourceRange: sourceRange,
      source: source.substring(with: sourceRange),
      previewText: compactPreview(rawPreview, fallback: pending.title),
      lineNumber: pending.lineNumber
    )
  }

  static func makeInlineOccurrence(
    kind: MarkdownSSGComponentKind,
    title: String,
    argument: String,
    source: NSString,
    lineRange: NSRange,
    lineNumber: Int
  ) -> MarkdownSSGComponentOccurrence {
    let sourceText = source.substring(with: lineRange)
    return MarkdownSSGComponentOccurrence(
      id: "\(kind.rawValue)-\(lineRange.location)",
      kind: kind,
      title: title,
      sourceRange: lineRange,
      source: sourceText,
      previewText: compactPreview(argument, fallback: title),
      lineNumber: lineNumber
    )
  }

  static func makeTokenOccurrence(
    kind: MarkdownSSGComponentKind, title: String, argument: String,
    source: NSString, range: NSRange, lineNumber: Int
  ) -> MarkdownSSGComponentOccurrence {
    MarkdownSSGComponentOccurrence(
      id: "\(kind.rawValue)-\(range.location)", kind: kind,
      title: title, sourceRange: range, source: source.substring(with: range),
      previewText: compactPreview(argument, fallback: title), lineNumber: lineNumber)
  }

  static func compactPreview(_ value: String, fallback: String) -> String {
    let normalized =
      value
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return fallback }
    return String(normalized.prefix(96))
  }

  static func capture(_ line: String, pattern: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let source = line as NSString
    guard
      let match = regex.firstMatch(
        in: line,
        range: NSRange(location: 0, length: source.length)
      )
    else {
      return nil
    }
    return (1..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      guard range.location != NSNotFound else { return "" }
      return source.substring(with: range)
    }
  }
}
