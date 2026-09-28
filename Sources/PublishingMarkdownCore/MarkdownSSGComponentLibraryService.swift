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
