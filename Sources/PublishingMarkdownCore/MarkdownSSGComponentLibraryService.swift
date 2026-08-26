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
    var pending: PendingComponent?
    var cursor = 0
    var lineNumber = 1

    while cursor < source.length {
      let lineRange = source.lineRange(for: NSRange(location: cursor, length: 0))
      let line = source.substring(with: lineRange)
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

      if let activePending = pending {
        if closes(activePending, with: trimmed) {
          occurrences.append(makeOccurrence(
            pending: activePending,
            source: source,
            end: NSMaxRange(lineRange),
            contentEnd: lineRange.location
          ))
          pending = nil
        }
        cursor = NSMaxRange(lineRange)
        lineNumber += 1
        continue
      }

      if let directive = parseDirectiveOpening(trimmed) {
        pending = PendingComponent(
          kind: .callout,
          title: directive.title,
          style: .directive,
          start: lineRange.location,
          contentStart: NSMaxRange(lineRange),
          contentEnd: NSMaxRange(lineRange),
          lineNumber: lineNumber
        )
      } else if let hugo = parseHugoOpening(trimmed) {
        if let kind = pairedKind(for: hugo.name) {
          pending = PendingComponent(
            kind: kind,
            title: hugo.title.nilIfEmpty ?? kind.displayName,
            style: .hugo(name: hugo.name.lowercased()),
            start: lineRange.location,
            contentStart: NSMaxRange(lineRange),
            contentEnd: NSMaxRange(lineRange),
            lineNumber: lineNumber
          )
        } else if let kind = inlineKind(for: hugo.name) {
          occurrences.append(makeInlineOccurrence(
            kind: kind,
            title: kind.displayName,
            argument: hugo.title,
            source: source,
            lineRange: lineRange,
            lineNumber: lineNumber
          ))
        }
      }

      cursor = NSMaxRange(lineRange)
      lineNumber += 1
    }

    if let pending {
      occurrences.append(makeOccurrence(
        pending: pending,
        source: source,
        end: source.length,
        contentEnd: source.length
      ))
    }

    return occurrences.sorted { lhs, rhs in
      lhs.sourceRange.location < rhs.sourceRange.location
    }
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

private extension MarkdownSSGComponentLibraryService {
  enum PendingStyle: Equatable {
    case directive
    case hugo(name: String)
  }

  struct PendingComponent: Equatable {
    let kind: MarkdownSSGComponentKind
    let title: String
    let style: PendingStyle
    let start: Int
    let contentStart: Int
    var contentEnd: Int
    let lineNumber: Int
  }

  struct ParsedHugoOpening {
    let name: String
    let title: String
  }

  static func closes(_ pending: PendingComponent, with line: String) -> Bool {
    switch pending.style {
    case .directive:
      return line == ":::"
    case let .hugo(name):
      guard let closing = capture(line, pattern: #"^\{\{<\s*/\s*([A-Za-z0-9_-]+)\s*>\}\}$"#)
      else { return false }
      return closing.first?.lowercased() == name
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
    guard let captures = capture(
      line,
      pattern: #"^\{\{<\s*([A-Za-z0-9_-]+)(?:\s+([^>]*?))?\s*>\}\}$"#
    ), let name = captures.first?.trimmingCharacters(in: .whitespacesAndNewlines),
    !name.isEmpty else {
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

  static func compactPreview(_ value: String, fallback: String) -> String {
    let normalized = value
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
    guard let match = regex.firstMatch(
      in: line,
      range: NSRange(location: 0, length: source.length)
    ) else {
      return nil
    }
    return (1..<match.numberOfRanges).map { index in
      let range = match.range(at: index)
      guard range.location != NSNotFound else { return "" }
      return source.substring(with: range)
    }
  }
}
