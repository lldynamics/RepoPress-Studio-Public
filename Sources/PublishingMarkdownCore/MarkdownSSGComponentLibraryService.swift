import Foundation
import PublishingCoreSupport

public enum MarkdownSSGComponentKind: String, CaseIterable, Codable, Hashable, Sendable {
  case callout
  case lead
  case youtube
  case bilibili
  case githubCard
  case figure
  case custom

  public var displayName: String {
    switch self {
    case .callout:
      return "提示框"
    case .lead:
      return "导语"
    case .youtube:
      return "YouTube 视频"
    case .bilibili:
      return "B 站视频"
    case .githubCard:
      return "GitHub 卡片"
    case .figure:
      return "图片短代码"
    case .custom:
      return "自定义短代码"
    }
  }

  public var systemImage: String {
    switch self {
    case .callout:
      return "exclamationmark.bubble"
    case .lead:
      return "text.quote"
    case .youtube:
      return "play.rectangle"
    case .bilibili:
      return "play.tv"
    case .githubCard:
      return "chevron.left.forwardslash.chevron.right"
    case .figure:
      return "photo"
    case .custom:
      return "curlybraces.square"
    }
  }
}

public struct MarkdownSSGComponentOccurrence: Identifiable, Equatable, Sendable {
  public var id: String
  public var kind: MarkdownSSGComponentKind
  public var title: String
  public var sourceRange: NSRange
  public var source: String
  public var previewText: String
  public var lineNumber: Int

  public init(
    id: String,
    kind: MarkdownSSGComponentKind,
    title: String,
    sourceRange: NSRange,
    source: String,
    previewText: String,
    lineNumber: Int
  ) {
    self.id = id
    self.kind = kind
    self.title = title
    self.sourceRange = sourceRange
    self.source = source
    self.previewText = previewText
    self.lineNumber = lineNumber
  }
}

public enum MarkdownSSGComponentEngineSyntax: String, Codable, Hashable, Sendable {
  case hugoAngle = "hugo-angle"
  case hugoPercent = "hugo-percent"
  case zolaLegacy = "zola-legacy"
  case zolaComponent = "zola-component"
  case zolaInlineComponent = "zola-inline-component"
}

public struct MarkdownSSGComponentReference: Equatable, Sendable {
  public let name: String
  public let sourceRange: NSRange
  public let lineNumber: Int
  public let engineSyntax: MarkdownSSGComponentEngineSyntax
  public let isClosing: Bool

  public init(
    name: String, sourceRange: NSRange, lineNumber: Int,
    engineSyntax: MarkdownSSGComponentEngineSyntax, isClosing: Bool = false
  ) {
    self.name = name
    self.sourceRange = sourceRange
    self.lineNumber = lineNumber
    self.engineSyntax = engineSyntax
    self.isClosing = isClosing
  }
}

public enum MarkdownSSGComponentLibraryService {
  public static let builtInSnippets: [MarkdownSnippet] = [
    MarkdownSnippet(
      id: "ssg-callout",
      title: "提示框",
      detail: "::: tip · Astro/Hexo 常见容器",
      systemImage: MarkdownSSGComponentKind.callout.systemImage,
      kind: .snippet,
      markdown: "::: tip 提示\n在这里输入提示内容。\n:::",
      shortcut: "callout",
      previewKind: .callout,
      selectionToken: "在这里输入提示内容。"
    ),
    MarkdownSnippet(
      id: "ssg-lead",
      title: "导语短代码",
      detail: "Hugo {{< lead >}} 导语容器",
      systemImage: MarkdownSSGComponentKind.lead.systemImage,
      kind: .snippet,
      markdown: "{{< lead >}}\n在这里输入文章导语。\n{{< /lead >}}",
      shortcut: "lead",
      previewKind: .lead,
      selectionToken: "在这里输入文章导语。"
    ),
    MarkdownSnippet(
      id: "ssg-youtube",
      title: "YouTube 视频",
      detail: "Hugo/自定义短代码 · 替换 VIDEO_ID",
      systemImage: MarkdownSSGComponentKind.youtube.systemImage,
      kind: .snippet,
      markdown: "{{< youtube VIDEO_ID >}}",
      shortcut: "youtube",
      previewKind: .youtube,
      selectionToken: "VIDEO_ID"
    ),
    MarkdownSnippet(
      id: "ssg-bilibili",
      title: "B 站视频",
      detail: "Hugo/自定义短代码 · 替换 BV_ID",
      systemImage: MarkdownSSGComponentKind.bilibili.systemImage,
      kind: .snippet,
      markdown: "{{< bilibili BV_ID >}}",
      shortcut: "bilibili",
      previewKind: .bilibili,
      selectionToken: "BV_ID"
    ),
    MarkdownSnippet(
      id: "ssg-github-card",
      title: "GitHub 卡片",
      detail: "Hugo/自定义短代码 · 替换 owner/repo",
      systemImage: MarkdownSSGComponentKind.githubCard.systemImage,
      kind: .snippet,
      markdown: "{{< github-card owner/repo >}}",
      shortcut: "github",
      previewKind: .githubCard,
      selectionToken: "owner/repo"
    ),
    MarkdownSnippet(
      id: "ssg-figure",
      title: "图片短代码",
      detail: "Hugo figure · 支持图片说明",
      systemImage: MarkdownSSGComponentKind.figure.systemImage,
      kind: .snippet,
      markdown: "{{< figure src=\"/images/example.jpg\" title=\"图片说明\" >}}",
      shortcut: "figure",
      previewKind: .figure,
      selectionToken: "/images/example.jpg"
    ),
  ]

  public static func occurrences(
    in markdown: String
  ) -> [MarkdownSSGComponentOccurrence] {
    let source = markdown as NSString
    guard source.length > 0 else { return [] }

    var occurrences: [MarkdownSSGComponentOccurrence] = []
    var pending: [PendingComponent] = []
    var cursor = 0
    var lineNumber = 1
    var fenced = false
    var rawName: String?
    var htmlComment = false

    while cursor < source.length {
      let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
      let line = source.substring(with: lineRange)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      if isFence(trimmed) { fenced.toggle() }
      if htmlComment {
        if trimmed.contains("-->") { htmlComment = false }
        cursor = NSMaxRange(lineRange)
        lineNumber += 1
        continue
      }
      if trimmed.contains("<!--") {
        htmlComment = !trimmed.contains("-->")
        cursor = NSMaxRange(lineRange)
        lineNumber += 1
        continue
      }
      if fenced {
        cursor = NSMaxRange(lineRange)
        lineNumber += 1
        continue
      }
      if rawName == nil, let directive = parseDirectiveOpening(trimmed) {
        pending.append(
          PendingComponent(
            kind: .callout, title: directive.title,
            style: .directive, start: lineRange.location, contentStart: NSMaxRange(lineRange),
            lineNumber: lineNumber, tokenRange: lineRange))
      } else if rawName == nil, trimmed == ":::",
        let index = pending.lastIndex(where: { $0.style == .directive })
      {
        let item = pending.remove(at: index)
        occurrences.append(
          makeOccurrence(
            pending: item, source: source,
            end: NSMaxRange(lineRange), contentEnd: lineRange.location))
      }
      for token in parseShortcodeTokens(in: line, base: lineRange.location)
      where !isInInlineCode(line, offset: token.range.location - lineRange.location) {
        if let raw = rawName {
          if token.isClosing
            && (token.name.caseInsensitiveCompare(raw) == .orderedSame
              || token.name.caseInsensitiveCompare("endraw") == .orderedSame)
          {
            rawName = nil
          }
          continue
        }
        if token.name.lowercased() == "raw", !token.isClosing {
          rawName = token.name
          continue
        }
        if token.name.lowercased() == "endraw" { continue }
        if token.isClosing {
          guard let index = pending.lastIndex(where: { $0.matches(token.name) }) else { continue }
          let item = pending.remove(at: index)
          occurrences.append(
            makeOccurrence(
              pending: item, source: source,
              end: NSMaxRange(token.range), contentEnd: token.range.location))
        } else if token.isSelfClosing {
          let kind = inlineKind(for: token.name) ?? .custom
          occurrences.append(
            makeTokenOccurrence(
              kind: kind, title: kind == .custom ? token.name : kind.displayName,
              argument: token.arguments, source: source, range: token.range, lineNumber: lineNumber)
          )
        } else {
          let knownPair = pairedKind(for: token.name) != nil
          if knownPair || inlineKind(for: token.name) == .custom {
            pending.append(
              PendingComponent(
                kind: knownPair ? (pairedKind(for: token.name) ?? .custom) : .custom,
                title: token.arguments.nilIfEmpty
                  ?? (knownPair ? (pairedKind(for: token.name)?.displayName ?? "") : token.name),
                style: .shortcode(name: token.name.lowercased(), syntax: token.syntax),
                start: token.range.location, contentStart: NSMaxRange(token.range),
                lineNumber: lineNumber,
                tokenRange: token.range))
          } else if let kind = inlineKind(for: token.name) {
            occurrences.append(
              makeTokenOccurrence(
                kind: kind, title: kind.displayName,
                argument: token.arguments, source: source, range: token.range,
                lineNumber: lineNumber))
          }
        }
      }

      cursor = NSMaxRange(lineRange)
      lineNumber += 1
    }

    for item in pending where item.isUnknown {
      occurrences.append(
        makeTokenOccurrence(
          kind: .custom, title: item.title,
          argument: item.title, source: source, range: item.tokenRange, lineNumber: item.lineNumber)
      )
    }

    return occurrences.sorted { lhs, rhs in
      lhs.sourceRange.location < rhs.sourceRange.location
    }
  }

  public static func detectedReferences(in markdown: String) -> [MarkdownSSGComponentReference] {
    let source = markdown as NSString
    guard source.length > 0 else { return [] }
    var result: [MarkdownSSGComponentReference] = []
    var cursor = 0
    var line = 1
    var fenced = false
    var htmlComment = false
    var rawName: String?
    while cursor < source.length {
      let range = source.lineRange(for: NSRange(location: cursor, length: 0))
      let text = source.substring(with: range)
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if isFence(trimmed) { fenced.toggle() }
      if htmlComment {
        if trimmed.contains("-->") { htmlComment = false }
      } else if trimmed.contains("<!--") {
        htmlComment = !trimmed.contains("-->")
      } else if !fenced {
        for token in parseShortcodeTokens(in: text, base: range.location)
        where !isInInlineCode(text, offset: token.range.location - range.location) {
          if let raw = rawName {
            if token.isClosing
              && (token.name.caseInsensitiveCompare(raw) == .orderedSame
                || token.name.caseInsensitiveCompare("endraw") == .orderedSame)
            {
              rawName = nil
            }
          } else if token.name.lowercased() == "raw", !token.isClosing {
            rawName = token.name
          } else if token.name.lowercased() == "endraw" {
            continue
          } else {
            result.append(
              MarkdownSSGComponentReference(
                name: token.name, sourceRange: token.range,
                lineNumber: line, engineSyntax: token.syntax, isClosing: token.isClosing))
          }
        }
      }
      cursor = NSMaxRange(range)
      line += 1
    }
    return result.sorted { $0.sourceRange.location < $1.sourceRange.location }
  }

  public static func inferredPreviewKind(for markdown: String) -> MarkdownSSGComponentKind? {
    let normalized = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }
    if normalized.hasPrefix(":::") {
      return .callout
    }
    return normalized.contains("{{<") ? .custom : nil
  }
}

extension MarkdownSSGComponentLibraryService {
  fileprivate enum PendingStyle: Equatable {
    case directive
    case shortcode(name: String, syntax: MarkdownSSGComponentEngineSyntax)
  }

  fileprivate struct PendingComponent: Equatable {
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

  fileprivate struct ParsedShortcodeToken {
    let name: String
    let arguments: String
    let range: NSRange
    let syntax: MarkdownSSGComponentEngineSyntax
    let isClosing: Bool
    let isSelfClosing: Bool
  }

  fileprivate static func parseShortcodeTokens(in line: String, base: Int) -> [ParsedShortcodeToken]
  {
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

  fileprivate static func isFence(_ line: String) -> Bool {
    line.hasPrefix("```") || line.hasPrefix("~~~")
  }

  fileprivate static func isInInlineCode(_ line: String, offset: Int) -> Bool {
    guard offset > 0 else { return false }
    let nsLine = line as NSString
    let prefix = nsLine.substring(with: NSRange(location: 0, length: min(offset, nsLine.length)))
    return prefix.filter { $0 == "`" }.count % 2 == 1
  }

  fileprivate struct ParsedHugoOpening {
    let name: String
    let title: String
  }

  fileprivate static func closes(_ pending: PendingComponent, with line: String) -> Bool {
    switch pending.style {
    case .directive:
      return line == ":::"
    case .shortcode(let name, _):
      return parseShortcodeTokens(in: line, base: 0).contains {
        $0.isClosing && $0.name.lowercased() == name
      }
    }
  }

  fileprivate static func parseDirectiveOpening(_ line: String) -> (name: String, title: String)? {
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

  fileprivate static func parseHugoOpening(_ line: String) -> ParsedHugoOpening? {
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

  fileprivate static func pairedKind(for name: String) -> MarkdownSSGComponentKind? {
    switch name.lowercased() {
    case "lead":
      return .lead
    case "callout", "admonition":
      return .callout
    default:
      return nil
    }
  }

  fileprivate static func inlineKind(for name: String) -> MarkdownSSGComponentKind? {
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

  fileprivate static func makeOccurrence(
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

  fileprivate static func makeInlineOccurrence(
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

  fileprivate static func makeTokenOccurrence(
    kind: MarkdownSSGComponentKind, title: String, argument: String,
    source: NSString, range: NSRange, lineNumber: Int
  ) -> MarkdownSSGComponentOccurrence {
    MarkdownSSGComponentOccurrence(
      id: "\(kind.rawValue)-\(range.location)", kind: kind,
      title: title, sourceRange: range, source: source.substring(with: range),
      previewText: compactPreview(argument, fallback: title), lineNumber: lineNumber)
  }

  fileprivate static func compactPreview(_ value: String, fallback: String) -> String {
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

  fileprivate static func capture(_ line: String, pattern: String) -> [String]? {
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
