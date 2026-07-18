import Foundation

public enum MarkdownPreviewTitleService {
  public static func bodyMarkdown(title: String, markdown: String) -> String {
    let comparableTitle = comparableText(title)
    guard !comparableTitle.isEmpty else { return markdown }

    var lines = markdown.components(separatedBy: .newlines)
    guard let firstContentIndex = lines.firstIndex(where: {
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }) else {
      return markdown
    }

    if let heading = atxLevelOneHeading(in: lines[firstContentIndex]),
       comparableText(heading) == comparableTitle {
      removeTitleLines(at: firstContentIndex, count: 1, from: &lines)
      return lines.joined(separator: "\n")
    }

    let underlineIndex = firstContentIndex + 1
    if lines.indices.contains(underlineIndex),
       isSetextLevelOneUnderline(lines[underlineIndex]),
       comparableText(lines[firstContentIndex]) == comparableTitle {
      removeTitleLines(at: firstContentIndex, count: 2, from: &lines)
      return lines.joined(separator: "\n")
    }

    return markdown
  }

  private static func atxLevelOneHeading(in line: String) -> String? {
    let trimmed = unwrappedStrongEmphasis(
      line.trimmingCharacters(in: .whitespaces)
    )
    guard trimmed.hasPrefix("#"), !trimmed.hasPrefix("##") else {
      return nil
    }
    let content = trimmed.dropFirst()
    guard content.first?.isWhitespace == true else {
      return nil
    }
    return String(content)
      .trimmingCharacters(in: .whitespaces)
      .replacingOccurrences(
        of: #"\s+#+\s*$"#,
        with: "",
        options: .regularExpression
      )
      .nilIfEmpty
  }

  private static func unwrappedStrongEmphasis(_ line: String) -> String {
    for marker in ["**", "__"] where line.hasPrefix(marker) && line.hasSuffix(marker) {
      let start = line.index(line.startIndex, offsetBy: marker.count)
      let end = line.index(line.endIndex, offsetBy: -marker.count)
      guard start < end else { continue }
      return String(line[start..<end]).trimmingCharacters(in: .whitespaces)
    }
    return line
  }

  private static func isSetextLevelOneUnderline(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "=" }
  }

  private static func removeTitleLines(
    at index: Int,
    count: Int,
    from lines: inout [String]
  ) {
    lines.removeSubrange(index..<(index + count))
    if lines.indices.contains(index),
       lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      lines.remove(at: index)
    }
  }

  private static func comparableText(_ value: String) -> String {
    value
      .replacingOccurrences(
        of: #"!\[([^\]]*)\]\([^)]+\)"#,
        with: "$1",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"\[([^\]]+)\]\([^)]+\)"#,
        with: "$1",
        options: .regularExpression
      )
      .replacingOccurrences(
        of: #"[*_`~]"#,
        with: "",
        options: .regularExpression
      )
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .folding(
        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
        locale: .current
      )
      .lowercased()
  }
}
