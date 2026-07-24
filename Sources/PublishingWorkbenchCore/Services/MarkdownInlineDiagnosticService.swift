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

public enum MarkdownInlineDiagnosticService {
  public static func diagnostics(in markdown: String) -> [MarkdownInlineDiagnostic] {
    let source = markdown as NSString
    var result: [MarkdownInlineDiagnostic] = []
    result.append(contentsOf: imageAltDiagnostics(in: markdown, source: source))
    result.append(contentsOf: headingDiagnostics(in: markdown))
    result.append(contentsOf: footnoteDiagnostics(in: markdown, source: source))
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
}
