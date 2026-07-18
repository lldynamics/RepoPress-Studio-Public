import Foundation

public struct MarkdownMermaidNode: Identifiable, Hashable, Sendable {
  public var id: String
  public var label: String

  public init(id: String, label: String) {
    self.id = id
    self.label = label
  }
}

public struct MarkdownMermaidEdge: Identifiable, Hashable, Sendable {
  public var id: String { "\(from)->\(to)-\(label ?? "")" }
  public var from: String
  public var to: String
  public var label: String?

  public init(from: String, to: String, label: String? = nil) {
    self.from = from
    self.to = to
    self.label = label
  }
}

public struct MarkdownMermaidDiagram: Hashable, Sendable {
  public enum Direction: String, Hashable, Sendable { case topDown, leftRight }
  public var direction: Direction
  public var nodes: [MarkdownMermaidNode]
  public var edges: [MarkdownMermaidEdge]
  public var source: String

  public init(
    direction: Direction,
    nodes: [MarkdownMermaidNode],
    edges: [MarkdownMermaidEdge],
    source: String
  ) {
    self.direction = direction
    self.nodes = nodes
    self.edges = edges
    self.source = source
  }
}

public enum MarkdownExtendedPreviewBlock: Hashable, Sendable {
  case markdown(String)
  case mermaid(MarkdownMermaidDiagram)
}

public enum MarkdownExtendedPreviewService {
  public static func blocks(in markdown: String) -> [MarkdownExtendedPreviewBlock] {
    let footnoteExpanded = expandingFootnotes(in: markdown)
    guard let regex = try? NSRegularExpression(
      pattern: #"(?s)```mermaid\s*\n(.*?)\n```"#,
      options: [.caseInsensitive]
    ) else { return [.markdown(footnoteExpanded)] }
    let source = footnoteExpanded as NSString
    let matches = regex.matches(in: footnoteExpanded, range: NSRange(location: 0, length: source.length))
    guard !matches.isEmpty else { return [.markdown(footnoteExpanded)] }

    var blocks: [MarkdownExtendedPreviewBlock] = []
    var location = 0
    for match in matches {
      if match.range.location > location {
        blocks.append(.markdown(source.substring(with: NSRange(location: location, length: match.range.location - location))))
      }
      let diagramSource = match.numberOfRanges > 1 ? source.substring(with: match.range(at: 1)) : ""
      blocks.append(.mermaid(parseMermaid(diagramSource)))
      location = NSMaxRange(match.range)
    }
    if location < source.length {
      blocks.append(.markdown(source.substring(from: location)))
    }
    return blocks
  }

  public static func expandingFootnotes(in markdown: String) -> String {
    let lines = markdown.components(separatedBy: "\n")
    var definitions: [(id: String, text: String)] = []
    var bodyLines: [String] = []
    for line in lines {
      guard line.hasPrefix("[^"),
            let close = line.range(of: "]:") else {
        bodyLines.append(line)
        continue
      }
      let id = String(line[line.index(line.startIndex, offsetBy: 2)..<close.lowerBound])
      let text = String(line[close.upperBound...]).trimmedForPublishing
      guard !id.isEmpty else {
        bodyLines.append(line)
        continue
      }
      definitions.append((id, text))
    }
    guard !definitions.isEmpty else { return markdown }

    var body = bodyLines.joined(separator: "\n")
    for (index, definition) in definitions.enumerated() {
      body = body.replacingOccurrences(
        of: "[^\(definition.id)]",
        with: "[\(index + 1)](#footnote-\(definition.id))"
      )
    }
    let notes = definitions.enumerated().map { index, definition in
      "\(index + 1). <a id=\"footnote-\(definition.id)\"></a>\(definition.text)"
    }
    return body.trimmedForPublishing + "\n\n---\n\n### 脚注\n\n" + notes.joined(separator: "\n")
  }

  public static func parseMermaid(_ source: String) -> MarkdownMermaidDiagram {
    let lines = source.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
    let header = lines.first?.lowercased() ?? ""
    let direction: MarkdownMermaidDiagram.Direction = header.contains(" lr") ? .leftRight : .topDown
    var nodeLabels: [String: String] = [:]
    var nodeOrder: [String] = []
    var edges: [MarkdownMermaidEdge] = []

    func register(_ token: String) -> String? {
      let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      let id = String(trimmed.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
      guard !id.isEmpty else { return nil }
      var label = id
      if let open = trimmed.firstIndex(where: { "[{(".contains($0) }),
         let close = trimmed.lastIndex(where: { "]})".contains($0) }),
         open < close {
        label = String(trimmed[trimmed.index(after: open)..<close])
      }
      if nodeLabels[id] == nil { nodeOrder.append(id) }
      nodeLabels[id] = label.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      return id
    }

    for line in lines.dropFirst(header.hasPrefix("graph") || header.hasPrefix("flowchart") ? 1 : 0) {
      let arrowTokens = ["-->", "---", "==>"]
      guard let arrow = arrowTokens.first(where: { line.contains($0) }),
            let range = line.range(of: arrow) else {
        _ = register(line)
        continue
      }
      let left = String(line[..<range.lowerBound])
      var right = String(line[range.upperBound...])
      var label: String?
      if right.hasPrefix("|") {
        let rest = right.dropFirst()
        if let close = rest.firstIndex(of: "|") {
          label = String(rest[..<close])
          right = String(rest[rest.index(after: close)...])
        }
      }
      if let from = register(left), let to = register(right) {
        edges.append(MarkdownMermaidEdge(from: from, to: to, label: label))
      }
    }
    return MarkdownMermaidDiagram(
      direction: direction,
      nodes: nodeOrder.map { MarkdownMermaidNode(id: $0, label: nodeLabels[$0] ?? $0) },
      edges: edges,
      source: source
    )
  }
}
