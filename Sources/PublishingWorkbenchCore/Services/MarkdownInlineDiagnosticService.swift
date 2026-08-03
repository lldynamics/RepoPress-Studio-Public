import Foundation

public enum MarkdownInlineDiagnosticSeverity: String, Codable, Hashable, Sendable {
  case warning
  case error
}

public struct MarkdownInlineDiagnostic: Identifiable, Hashable, Sendable {
  public var id: String
  public var severity: MarkdownInlineDiagnosticSeverity
  public var title: String
  public var message: String
  public var range: NSRange
  public var replacement: String?

  public init(
    id: String,
    severity: MarkdownInlineDiagnosticSeverity,
    title: String,
    message: String,
    range: NSRange,
    replacement: String? = nil
  ) {
    self.id = id
    self.severity = severity
    self.title = title
    self.message = message
    self.range = range
    self.replacement = replacement
  }

  public var quickFixTitle: String? {
    replacement == nil ? nil : "应用快速修复"
  }
}

public struct MarkdownInlineDiagnosticContext: Hashable, Sendable {
  public var knownArticleTitles: Set<String>
  public var attachmentPaths: Set<String>

  public init(
    knownArticleTitles: Set<String> = [],
    attachmentPaths: Set<String> = []
  ) {
    self.knownArticleTitles = knownArticleTitles
    self.attachmentPaths = attachmentPaths
  }

  public static let empty = MarkdownInlineDiagnosticContext()
}

public enum MarkdownInlineDiagnosticService {
  public static func diagnostics(
    in markdown: String,
    context: MarkdownInlineDiagnosticContext = .empty
  ) -> [MarkdownInlineDiagnostic] {
    let source = markdown as NSString
    let codeRanges = MarkdownCodeRangeScanner.scan(markdown).allRanges
    var result: [MarkdownInlineDiagnostic] = []
    result.append(contentsOf: imageAltDiagnostics(in: markdown, source: source))
    result.append(contentsOf: headingDiagnostics(in: markdown))
    result.append(contentsOf: footnoteDiagnostics(in: markdown, source: source))
    result.append(contentsOf: bareURLDiagnostics(
      in: markdown,
      source: source,
      codeRanges: codeRanges
    ))
    result.append(contentsOf: orderedListDiagnostics(in: markdown))
    result.append(contentsOf: unclosedFenceDiagnostics(in: markdown))
    result.append(contentsOf: internalLinkDiagnostics(
      in: markdown,
      source: source,
      codeRanges: codeRanges,
      knownArticleTitles: context.knownArticleTitles
    ))
    result.append(contentsOf: embeddedHTMLDiagnostics(in: markdown))
    return result.sorted {
      if $0.range.location == $1.range.location { return $0.id < $1.id }
      return $0.range.location < $1.range.location
    }
  }

  public static func quickFix(
    for diagnostic: MarkdownInlineDiagnostic,
    in markdown: String
  ) -> MarkdownSmartEdit? {
    guard let replacement = diagnostic.replacement else { return nil }
    let source = markdown as NSString
    guard diagnostic.range.location >= 0,
          NSMaxRange(diagnostic.range) <= source.length else { return nil }
    return MarkdownSmartEdit(
      replacedRange: diagnostic.range,
      replacement: replacement,
      selectedRange: NSRange(
        location: diagnostic.range.location + (replacement as NSString).length,
        length: 0
      )
    )
  }

  private static func imageAltDiagnostics(in markdown: String, source: NSString) -> [MarkdownInlineDiagnostic] {
    guard let regex = try? NSRegularExpression(pattern: #"!\[\s*\]\(([^)]+)\)"#) else { return [] }
    return regex.matches(in: markdown, range: NSRange(location: 0, length: source.length)).enumerated().map { index, match in
      let path = match.numberOfRanges > 1 ? source.substring(with: match.range(at: 1)) : "image"
      let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: "-", with: " ")
        .replacingOccurrences(of: "_", with: " ")
        .trimmedForPublishing
      let alt = fileName.nilIfEmpty ?? "图片说明"
      return MarkdownInlineDiagnostic(
        id: "image-alt-\(index)-\(match.range.location)",
        severity: .warning,
        title: "图片缺少 alt",
        message: "补充替代文本可改善无障碍与搜索表现。",
        range: match.range,
        replacement: "![\(alt)](\(path))"
      )
    }
  }

  private static func headingDiagnostics(in markdown: String) -> [MarkdownInlineDiagnostic] {
    let lines = markdown.components(separatedBy: "\n")
    var location = 0
    var previousLevel: Int?
    var seen = Set<String>()
    var result: [MarkdownInlineDiagnostic] = []

    for (index, line) in lines.enumerated() {
      let lineLength = (line as NSString).length
      let hashes = line.prefix { $0 == "#" }.count
      let isHeading = hashes > 0 && hashes <= 6 && line.dropFirst(hashes).first == " "
      if isHeading {
        let title = String(line.dropFirst(hashes)).trimmedForPublishing
        let range = NSRange(location: location, length: lineLength)
        if let previousLevel, hashes > previousLevel + 1 {
          let replacementLevel = previousLevel + 1
          let replacement = String(repeating: "#", count: replacementLevel) + " " + title
          result.append(MarkdownInlineDiagnostic(
            id: "heading-jump-\(index)",
            severity: .warning,
            title: "标题层级跳跃",
            message: "H\(previousLevel) 后直接使用 H\(hashes)，建议调整为 H\(replacementLevel)。",
            range: range,
            replacement: replacement
          ))
        }
        let normalized = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        if !normalized.isEmpty && !seen.insert(normalized).inserted {
          result.append(MarkdownInlineDiagnostic(
            id: "duplicate-heading-\(index)",
            severity: .warning,
            title: "标题重复",
            message: "相同章节名会生成冲突锚点，建议改成更具体的标题。",
            range: range
          ))
        }
        previousLevel = hashes
      }
      location += lineLength + (index + 1 < lines.count ? 1 : 0)
    }
    return result
  }

  private static func footnoteDiagnostics(in markdown: String, source: NSString) -> [MarkdownInlineDiagnostic] {
    guard let referenceRegex = try? NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#),
          let definitionRegex = try? NSRegularExpression(pattern: #"(?m)^\[\^([^\]]+)\]:"#) else { return [] }
    let fullRange = NSRange(location: 0, length: source.length)
    let definitions = Set(definitionRegex.matches(in: markdown, range: fullRange).compactMap { match -> String? in
      guard match.numberOfRanges > 1 else { return nil }
      return source.substring(with: match.range(at: 1))
    })
    return referenceRegex.matches(in: markdown, range: fullRange).enumerated().compactMap { index, match in
      guard match.numberOfRanges > 1 else { return nil }
      let name = source.substring(with: match.range(at: 1))
      guard !definitions.contains(name) else { return nil }
      return MarkdownInlineDiagnostic(
        id: "missing-footnote-\(index)-\(match.range.location)",
        severity: .error,
        title: "脚注没有定义",
        message: "为 [^\(name)] 添加对应的脚注内容。",
        range: match.range
      )
    }
  }

  private static func embeddedHTMLDiagnostics(in markdown: String) -> [MarkdownInlineDiagnostic] {
    MarkdownEmbeddedHTMLService.prepare(markdown: markdown).issues.map { issue in
      MarkdownInlineDiagnostic(
        id: issue.id,
        severity: issue.severity,
        title: issue.title,
        message: issue.message,
        range: issue.range
      )
    }
  }

  private static func bareURLDiagnostics(
    in markdown: String,
    source: NSString,
    codeRanges: [NSRange]
  ) -> [MarkdownInlineDiagnostic] {
    guard
      let urlExpression = try? NSRegularExpression(
        pattern: #"https?://[^\s<>()]+"#,
        options: [.caseInsensitive]
      ),
      let linkedURLExpression = try? NSRegularExpression(
        pattern: #"\]\(\s*<?(https?://[^\s>)]+)"#,
        options: [.caseInsensitive]
      )
    else {
      return []
    }
    let fullRange = NSRange(location: 0, length: source.length)
    let linkedRanges = linkedURLExpression.matches(
      in: markdown,
      range: fullRange
    ).compactMap { match -> NSRange? in
      guard match.numberOfRanges > 1 else { return nil }
      return match.range(at: 1)
    }

    return urlExpression.matches(in: markdown, range: fullRange)
      .enumerated()
      .compactMap { index, match in
        guard
          !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
          !linkedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
        else {
          return nil
        }
        if match.range.location > 0 {
          let preceding = source.character(at: match.range.location - 1)
          if preceding == 60 || preceding == 34 || preceding == 39 {
            return nil
          }
        }
        let url = source.substring(with: match.range)
        return MarkdownInlineDiagnostic(
          id: "bare-url-\(index)-\(match.range.location)",
          severity: .warning,
          title: "链接缺少说明文字",
          message: "把裸露网址改成有意义的链接文字，可改善可读性和无障碍体验。",
          range: match.range,
          replacement: "[链接](\(url))"
        )
      }
  }

  private static func orderedListDiagnostics(
    in markdown: String
  ) -> [MarkdownInlineDiagnostic] {
    guard
      let expression = try? NSRegularExpression(
        pattern: #"^([ \t]*)(\d+)(、)([ \t]*)"#
      )
    else {
      return []
    }
    let lines = markdown.components(separatedBy: "\n")
    var result: [MarkdownInlineDiagnostic] = []
    var expectedByIndent: [String: Int] = [:]
    var location = 0

    for (lineIndex, line) in lines.enumerated() {
      let lineSource = line as NSString
      let match = expression.firstMatch(
        in: line,
        range: NSRange(location: 0, length: lineSource.length)
      )
      if let match, match.numberOfRanges > 2 {
        let indent = lineSource.substring(with: match.range(at: 1))
        let numberText = lineSource.substring(with: match.range(at: 2))
        let number = Int(numberText) ?? 1
        if let expected = expectedByIndent[indent], number != expected {
          let numberRange = NSRange(
            location: location + match.range(at: 2).location,
            length: match.range(at: 2).length
          )
          result.append(
            MarkdownInlineDiagnostic(
              id: "ordered-list-sequence-\(lineIndex)-\(numberRange.location)",
              severity: .warning,
              title: "列表序号不连续",
              message: "这里应从 \(expected)、继续编号。",
              range: numberRange,
              replacement: String(expected)
            )
          )
          expectedByIndent[indent] = expected + 1
        } else {
          expectedByIndent[indent] = number + 1
        }
      } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
        expectedByIndent.removeAll()
      }
      location += lineSource.length + (lineIndex + 1 < lines.count ? 1 : 0)
    }
    return result
  }

  private static func unclosedFenceDiagnostics(
    in markdown: String
  ) -> [MarkdownInlineDiagnostic] {
    MarkdownCursorContextService().fenceMatches(in: markdown)
      .filter { !$0.isClosed }
      .map { match in
        MarkdownInlineDiagnostic(
          id: "unclosed-code-fence-\(match.openingMarkerRange.location)",
          severity: .error,
          title: "代码围栏没有闭合",
          message: "第 \(match.openingLine) 行的 \(match.marker) 代码块缺少结束标记。",
          range: match.openingMarkerRange
        )
      }
  }

  private static func internalLinkDiagnostics(
    in markdown: String,
    source: NSString,
    codeRanges: [NSRange],
    knownArticleTitles: Set<String>
  ) -> [MarkdownInlineDiagnostic] {
    let normalizedTitles = Set(knownArticleTitles.compactMap(normalizedInternalLinkTarget))
    guard !normalizedTitles.isEmpty else { return [] }
    guard
      let expression = try? NSRegularExpression(
        pattern: #"\[\[([^\]\n]+)\]\]"#
      )
    else {
      return []
    }
    let fullRange = NSRange(location: 0, length: source.length)
    return expression.matches(in: markdown, range: fullRange)
      .enumerated()
      .compactMap { index, match in
        guard
          match.numberOfRanges > 1,
          !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 })
        else {
          return nil
        }
        let rawTarget = source.substring(with: match.range(at: 1))
          .components(separatedBy: "|").first?
          .components(separatedBy: "#").first ?? ""
        guard
          let target = normalizedInternalLinkTarget(rawTarget),
          !normalizedTitles.contains(target)
        else {
          return nil
        }
        return MarkdownInlineDiagnostic(
          id: "missing-internal-link-\(index)-\(match.range.location)",
          severity: .error,
          title: "内部链接目标不存在",
          message: "没有找到题为“\(rawTarget.trimmedForPublishing)”的文章。",
          range: match.range
        )
      }
  }

  private static func normalizedInternalLinkTarget(_ value: String) -> String? {
    value.trimmedForPublishing
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
      )
      .nilIfEmpty
  }
}
