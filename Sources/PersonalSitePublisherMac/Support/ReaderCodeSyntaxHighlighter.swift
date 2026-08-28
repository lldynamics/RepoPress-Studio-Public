import Foundation
import SwiftUI

enum ReaderCodeTokenKind: Equatable {
  case plain
  case keyword
  case type
  case string
  case number
  case comment
}

struct ReaderCodeToken: Equatable {
  let text: String
  let kind: ReaderCodeTokenKind
}

struct ReaderCodePalette {
  let foreground: Color
  let background: Color
  let border: Color
  let keyword: Color
  let type: Color
  let string: Color
  let number: Color
  let comment: Color

  static func resolve(
    theme: ReaderCodeHighlightTheme,
    colorScheme: ColorScheme
  ) -> ReaderCodePalette {
    switch (theme, colorScheme) {
    case (.adaptive, .dark):
      ReaderCodePalette(
        foreground: Color(red: 0.87, green: 0.89, blue: 0.93),
        background: Color(red: 0.09, green: 0.10, blue: 0.13),
        border: Color.white.opacity(0.13),
        keyword: Color(red: 0.78, green: 0.56, blue: 0.98),
        type: Color(red: 0.36, green: 0.78, blue: 0.88),
        string: Color(red: 0.98, green: 0.64, blue: 0.54),
        number: Color(red: 0.76, green: 0.68, blue: 0.98),
        comment: Color(red: 0.46, green: 0.67, blue: 0.49)
      )
    case (.adaptive, _):
      ReaderCodePalette(
        foreground: Color(red: 0.12, green: 0.14, blue: 0.18),
        background: Color(red: 0.965, green: 0.97, blue: 0.98),
        border: Color.black.opacity(0.10),
        keyword: Color(red: 0.55, green: 0.15, blue: 0.72),
        type: Color(red: 0.05, green: 0.43, blue: 0.55),
        string: Color(red: 0.75, green: 0.16, blue: 0.12),
        number: Color(red: 0.35, green: 0.22, blue: 0.70),
        comment: Color(red: 0.20, green: 0.50, blue: 0.24)
      )
    case (.xcode, .dark):
      ReaderCodePalette(
        foreground: Color(red: 0.88, green: 0.88, blue: 0.90),
        background: Color(red: 0.11, green: 0.12, blue: 0.14),
        border: Color.white.opacity(0.14),
        keyword: Color(red: 0.99, green: 0.43, blue: 0.72),
        type: Color(red: 0.40, green: 0.78, blue: 0.92),
        string: Color(red: 0.98, green: 0.65, blue: 0.45),
        number: Color(red: 0.78, green: 0.64, blue: 0.98),
        comment: Color(red: 0.45, green: 0.68, blue: 0.46)
      )
    case (.xcode, _):
      ReaderCodePalette(
        foreground: Color(red: 0.10, green: 0.11, blue: 0.13),
        background: Color(red: 0.96, green: 0.965, blue: 0.975),
        border: Color.black.opacity(0.11),
        keyword: Color(red: 0.67, green: 0.08, blue: 0.55),
        type: Color(red: 0.00, green: 0.39, blue: 0.58),
        string: Color(red: 0.78, green: 0.12, blue: 0.11),
        number: Color(red: 0.30, green: 0.18, blue: 0.70),
        comment: Color(red: 0.18, green: 0.47, blue: 0.22)
      )
    case (.solarized, .dark):
      ReaderCodePalette(
        foreground: Color(red: 0.72, green: 0.78, blue: 0.79),
        background: Color(red: 0.00, green: 0.17, blue: 0.21),
        border: Color(red: 0.48, green: 0.56, blue: 0.58).opacity(0.65),
        keyword: Color(red: 1.00, green: 0.44, blue: 0.72),
        type: Color(red: 0.37, green: 0.85, blue: 0.82),
        string: Color(red: 0.95, green: 0.79, blue: 0.41),
        number: Color(red: 0.73, green: 0.71, blue: 1.00),
        comment: Color(red: 0.58, green: 0.63, blue: 0.63)
      )
    case (.solarized, _):
      ReaderCodePalette(
        foreground: Color(red: 0.25, green: 0.31, blue: 0.32),
        background: Color(red: 0.99, green: 0.96, blue: 0.89),
        border: Color(red: 0.58, green: 0.63, blue: 0.63).opacity(0.55),
        keyword: Color(red: 0.83, green: 0.21, blue: 0.51),
        type: Color(red: 0.16, green: 0.63, blue: 0.60),
        string: Color(red: 0.71, green: 0.54, blue: 0.00),
        number: Color(red: 0.42, green: 0.44, blue: 0.77),
        comment: Color(red: 0.35, green: 0.43, blue: 0.46)
      )
    }
  }
}

enum ReaderCodeSyntaxHighlighter {
  private static let commonKeywords: Set<String> = [
    "as", "async", "await", "break", "case", "catch", "class", "const",
    "continue", "default", "defer", "do", "else", "enum", "export", "extends",
    "false", "final", "for", "from", "func", "function", "guard", "if", "import",
    "in", "init", "interface", "internal", "let", "nil", "null", "override",
    "private", "protocol", "public", "repeat", "return", "self", "static", "struct",
    "super", "switch", "throws", "true", "try", "typealias", "var", "where", "while",
  ]
  private static let languageKeywords: [String: Set<String>] = [
    "python": [
      "and", "def", "del", "elif", "except", "finally", "global", "is", "lambda", "nonlocal", "not",
      "or", "pass", "raise", "with", "yield",
    ],
    "ruby": [
      "alias", "begin", "defined", "elsif", "end", "ensure", "module", "next", "redo", "rescue",
      "retry", "then", "undef", "unless", "until", "when",
    ],
    "sql": [
      "alter", "create", "delete", "distinct", "drop", "group", "having", "insert", "join", "limit",
      "order", "select", "table", "union", "update", "values",
    ],
  ]

  static func tokens(in source: String, language: String? = nil) -> [ReaderCodeToken] {
    guard !source.isEmpty else { return [] }
    let normalizedLanguage = language?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    let keywords = commonKeywords.union(languageKeywords[normalizedLanguage ?? ""] ?? [])
    let hashComments = ["python", "py", "ruby", "rb", "shell", "sh", "bash", "yaml", "yml"]
      .contains(normalizedLanguage ?? "")
    let dashComments = ["sql", "lua", "haskell", "hs"].contains(normalizedLanguage ?? "")

    var result: [ReaderCodeToken] = []
    var cursor = source.startIndex

    func append(_ range: Range<String.Index>, kind: ReaderCodeTokenKind) {
      guard !range.isEmpty else { return }
      let text = String(source[range])
      if kind == .plain, result.last?.kind == .plain {
        let previous = result.removeLast()
        result.append(ReaderCodeToken(text: previous.text + text, kind: .plain))
      } else {
        result.append(ReaderCodeToken(text: text, kind: kind))
      }
    }

    while cursor < source.endIndex {
      let next = source.index(after: cursor)
      let character = source[cursor]

      if character == "/", next < source.endIndex, source[next] == "/" {
        let end = source[next...].firstIndex(of: "\n") ?? source.endIndex
        append(cursor..<end, kind: .comment)
        cursor = end
        continue
      }
      if character == "/", next < source.endIndex, source[next] == "*" {
        let searchStart = source.index(after: next)
        let end: String.Index
        if let close = source.range(of: "*/", range: searchStart..<source.endIndex) {
          end = close.upperBound
        } else {
          end = source.endIndex
        }
        append(cursor..<end, kind: .comment)
        cursor = end
        continue
      }
      if hashComments, character == "#" {
        let end = source[next...].firstIndex(of: "\n") ?? source.endIndex
        append(cursor..<end, kind: .comment)
        cursor = end
        continue
      }
      if dashComments, character == "-", next < source.endIndex, source[next] == "-" {
        let end = source[next...].firstIndex(of: "\n") ?? source.endIndex
        append(cursor..<end, kind: .comment)
        cursor = end
        continue
      }

      if character == "\"" || character == "'" || character == "`" {
        let quote = character
        var end = next
        var escaped = false
        while end < source.endIndex {
          let current = source[end]
          end = source.index(after: end)
          if escaped {
            escaped = false
          } else if current == "\\" {
            escaped = true
          } else if current == quote {
            break
          }
        }
        append(cursor..<end, kind: .string)
        cursor = end
        continue
      }

      if character.isNumber {
        var end = next
        while end < source.endIndex,
          source[end].isNumber || ".xXabcdefABCDEF_".contains(source[end])
        {
          end = source.index(after: end)
        }
        append(cursor..<end, kind: .number)
        cursor = end
        continue
      }

      if isIdentifierStart(character) {
        var end = next
        while end < source.endIndex, isIdentifierContinuation(source[end]) {
          end = source.index(after: end)
        }
        let value = String(source[cursor..<end])
        let kind: ReaderCodeTokenKind
        if keywords.contains(value.lowercased()) {
          kind = .keyword
        } else if value.first?.isUppercase == true {
          kind = .type
        } else {
          kind = .plain
        }
        append(cursor..<end, kind: kind)
        cursor = end
        continue
      }

      append(cursor..<next, kind: .plain)
      cursor = next
    }

    return result
  }

  static func attributedString(
    _ source: String,
    language: String?,
    theme: ReaderCodeHighlightTheme,
    colorScheme: ColorScheme
  ) -> AttributedString {
    let palette = ReaderCodePalette.resolve(theme: theme, colorScheme: colorScheme)
    return tokens(in: source, language: language).reduce(into: AttributedString()) {
      output, token in
      var fragment = AttributedString(token.text)
      fragment.foregroundColor = color(for: token.kind, palette: palette)
      output.append(fragment)
    }
  }

  private static func color(
    for kind: ReaderCodeTokenKind,
    palette: ReaderCodePalette
  ) -> Color {
    switch kind {
    case .plain: palette.foreground
    case .keyword: palette.keyword
    case .type: palette.type
    case .string: palette.string
    case .number: palette.number
    case .comment: palette.comment
    }
  }

  private static func isIdentifierStart(_ character: Character) -> Bool {
    character == "_" || character.isLetter
  }

  private static func isIdentifierContinuation(_ character: Character) -> Bool {
    character == "_" || character.isLetter || character.isNumber
  }
}
