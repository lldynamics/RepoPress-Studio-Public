import Foundation
import PublishingCoreSupport

public enum KnowledgeDocumentBlockKind: Hashable, Sendable {
  case heading(level: Int)
  case paragraph
  case quote
  case unorderedListItem
  case orderedListItem(number: Int?)
  case code(language: String?)
  case locator
  case separator
}

public struct KnowledgeDocumentBlock: Identifiable, Hashable, Sendable {
  public var id: Int
  public var kind: KnowledgeDocumentBlockKind
  public var text: String

  public init(id: Int, kind: KnowledgeDocumentBlockKind, text: String) {
    self.id = id
    self.kind = kind
    self.text = text
  }
}

public struct KnowledgeDocumentBlockParser: Sendable {
  public init() {}

  public func blocks(in source: String) -> [KnowledgeDocumentBlock] {
    let normalized = source
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
    let lines = normalized.components(separatedBy: "\n")
    var output: [KnowledgeDocumentBlock] = []
    var paragraphLines: [String] = []
    var quoteLines: [String] = []
    var codeLines: [String] = []
    var codeLanguage: String?
    var isInsideCodeFence = false

    func append(_ kind: KnowledgeDocumentBlockKind, text: String) {
      let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty || kind == .separator else { return }
      output.append(KnowledgeDocumentBlock(id: output.count, kind: kind, text: value))
    }

    func flushParagraph() {
      append(.paragraph, text: paragraphLines.joined(separator: "\n"))
      paragraphLines.removeAll(keepingCapacity: true)
    }

    func flushQuote() {
      append(.quote, text: quoteLines.joined(separator: "\n"))
      quoteLines.removeAll(keepingCapacity: true)
    }

    func flushTextBlocks() {
      flushParagraph()
      flushQuote()
    }

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      if isInsideCodeFence {
        if trimmed.hasPrefix("```") {
          append(.code(language: codeLanguage), text: codeLines.joined(separator: "\n"))
          codeLines.removeAll(keepingCapacity: true)
          codeLanguage = nil
          isInsideCodeFence = false
        } else {
          codeLines.append(line)
        }
        continue
      }

      if trimmed.hasPrefix("```") {
        flushTextBlocks()
        isInsideCodeFence = true
        codeLanguage = String(trimmed.dropFirst(3))
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .nilIfEmpty
        continue
      }

      if trimmed.isEmpty {
        flushTextBlocks()
        continue
      }

      if let heading = heading(in: trimmed) {
        flushTextBlocks()
        append(.heading(level: heading.level), text: heading.text)
        continue
      }

      if Self.isSeparator(trimmed) {
        flushTextBlocks()
        append(.separator, text: "")
        continue
      }

      if let locator = Self.locator(in: trimmed) {
        flushTextBlocks()
        append(.locator, text: locator)
        continue
      }

      if trimmed.hasPrefix(">") {
        flushParagraph()
        quoteLines.append(
          String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        )
        continue
      }

      if let item = Self.unorderedListItem(in: trimmed) {
        flushTextBlocks()
        append(.unorderedListItem, text: item)
        continue
      }

      if let item = Self.orderedListItem(in: trimmed) {
        flushTextBlocks()
        append(.orderedListItem(number: item.number), text: item.text)
        continue
      }

      flushQuote()
      paragraphLines.append(line.trimmingCharacters(in: .whitespaces))
    }

    if isInsideCodeFence {
      append(.code(language: codeLanguage), text: codeLines.joined(separator: "\n"))
    }
    flushTextBlocks()
    return output
  }

  private func heading(in line: String) -> (level: Int, text: String)? {
    let markerCount = line.prefix { $0 == "#" }.count
    guard (1...6).contains(markerCount) else { return nil }
    let remainder = line.dropFirst(markerCount)
    guard remainder.first?.isWhitespace == true else { return nil }
    let text = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return (markerCount, text)
  }

  private static func unorderedListItem(in line: String) -> String? {
    for prefix in ["- ", "* ", "+ "] where line.hasPrefix(prefix) {
      return String(line.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfEmpty
    }
    return nil
  }

  private static func orderedListItem(in line: String) -> (number: Int?, text: String)? {
    guard let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }) else {
      return nil
    }
    let numberText = line[..<separator]
    guard !numberText.isEmpty,
          numberText.allSatisfy(\.isNumber) else {
      return nil
    }
    let contentStart = line.index(after: separator)
    guard contentStart < line.endIndex, line[contentStart].isWhitespace else { return nil }
    let text = line[line.index(after: contentStart)...]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    return (Int(numberText), text)
  }

  private static func locator(in line: String) -> String? {
    guard line.count <= 120,
          line.hasPrefix("["),
          line.hasSuffix("]"),
          !line.contains("]("),
          !line.contains("[") || line.first == "[" else {
      return nil
    }
    return String(line.dropFirst().dropLast())
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nilIfEmpty
  }

  private static func isSeparator(_ line: String) -> Bool {
    let compact = line.replacingOccurrences(of: " ", with: "")
    return compact == "---" || compact == "***" || compact == "___"
  }
}
