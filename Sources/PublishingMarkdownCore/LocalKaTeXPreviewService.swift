import Foundation

public struct LocalKaTeXPreviewReplacement: Hashable, Sendable {
  public var token: String
  public var html: String
  public var isBlock: Bool

  public init(token: String, html: String, isBlock: Bool) {
    self.token = token
    self.html = html
    self.isBlock = isBlock
  }
}

public struct LocalKaTeXPreviewPreparation: Hashable, Sendable {
  public var markdown: String
  public var replacements: [LocalKaTeXPreviewReplacement]

  public init(
    markdown: String,
    replacements: [LocalKaTeXPreviewReplacement]
  ) {
    self.markdown = markdown
    self.replacements = replacements
  }
}

/// A bundled, offline KaTeX-compatible subset for common article formulas.
/// It intentionally does not claim to implement the full KaTeX grammar.
public enum LocalKaTeXPreviewService {
  public static func prepare(markdown: String) -> LocalKaTeXPreviewPreparation {
    let source = markdown as NSString
    guard source.length > 0 else {
      return LocalKaTeXPreviewPreparation(markdown: markdown, replacements: [])
    }
    let protectedRanges = MarkdownCodeRangeScanner.scan(markdown).allRanges
    let patterns: [(NSRegularExpression, Bool)]
    do {
      patterns = try [
        (NSRegularExpression(pattern: #"(?s)(?<!\\)\$\$(.+?)(?<!\\)\$\$"#), true),
        (NSRegularExpression(pattern: #"(?s)(?<!\\)\\\[(.+?)(?<!\\)\\\]"#), true),
        (NSRegularExpression(pattern: #"(?<!\\)\$(?!\$)([^$\n]+?)(?<!\\)\$(?!\$)"#), false),
        (NSRegularExpression(pattern: #"(?<!\\)\\\(([^\n]+?)(?<!\\)\\\)"#), false),
      ]
    } catch {
      return LocalKaTeXPreviewPreparation(markdown: markdown, replacements: [])
    }
    var candidates: [(range: NSRange, source: String, isBlock: Bool)] = []
    for (regex, isBlock) in patterns {
      for match in regex.matches(
        in: markdown,
        range: NSRange(location: 0, length: source.length)
      ) where !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
        guard match.numberOfRanges > 1 else { continue }
        let formula = source.substring(with: match.range(at: 1))
        guard !formula.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        candidates.append((match.range, formula, isBlock))
      }
    }

    var selected: [(range: NSRange, source: String, isBlock: Bool)] = []
    for candidate in candidates.sorted(by: { lhs, rhs in
      if lhs.range.location == rhs.range.location {
        return lhs.range.length > rhs.range.length
      }
      return lhs.range.location < rhs.range.location
    }) {
      guard !selected.contains(where: {
        NSIntersectionRange($0.range, candidate.range).length > 0
      }) else { continue }
      selected.append(candidate)
    }
    guard !selected.isEmpty else {
      return LocalKaTeXPreviewPreparation(markdown: markdown, replacements: [])
    }

    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    var prepared = markdown
    var replacements: [LocalKaTeXPreviewReplacement] = []
    for (index, candidate) in selected.sorted(by: { $0.range.location > $1.range.location }).enumerated() {
      let token = "REPOPRESSLOCALMATH\(nonce)\(index)"
      let html = render(candidate.source, displayMode: candidate.isBlock)
      replacements.append(LocalKaTeXPreviewReplacement(
        token: token,
        html: html,
        isBlock: candidate.isBlock
      ))
      prepared = (prepared as NSString).replacingCharacters(in: candidate.range, with: token)
    }
    return LocalKaTeXPreviewPreparation(markdown: prepared, replacements: replacements)
  }

  public static func restore(
    renderedHTML: String,
    replacements: [LocalKaTeXPreviewReplacement]
  ) -> String {
    var restored = renderedHTML
    for replacement in replacements where replacement.isBlock {
      restored = restored
        .replacingOccurrences(
          of: "<p>\(replacement.token)</p>\n",
          with: "\(replacement.html)\n"
        )
        .replacingOccurrences(
          of: "<p>\(replacement.token)</p>",
          with: replacement.html
        )
    }
    for replacement in replacements where !replacement.isBlock {
      restored = restored.replacingOccurrences(of: replacement.token, with: replacement.html)
    }
    return restored
  }

  public static func render(_ formula: String, displayMode: Bool = false) -> String {
    let content = renderExpression(Array(formula), index: 0, stopAtClosingBrace: false)
    let safeContent = content.nilIfEmpty ?? MarkupEscaping.html(formula)
    let className = displayMode ? "local-katex-display" : "local-katex-inline"
    let label = MarkupEscaping.html(
      "本地 KaTeX 公式预览：\(formula.trimmingCharacters(in: .whitespacesAndNewlines))"
    )
    if displayMode {
      return "<div class=\"local-katex \(className)\" role=\"img\" aria-label=\"\(label)\">\(safeContent)</div>"
    }
    return "<span class=\"local-katex \(className)\" role=\"img\" aria-label=\"\(label)\">\(safeContent)</span>"
  }
}

private extension LocalKaTeXPreviewService {
  static let commandMap: [String: String] = [
    "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
    "epsilon": "ϵ", "theta": "θ", "lambda": "λ", "mu": "μ",
    "pi": "π", "sigma": "σ", "phi": "φ", "omega": "ω",
    "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ",
    "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Omega": "Ω",
    "times": "×", "cdot": "·", "pm": "±", "leq": "≤",
    "geq": "≥", "neq": "≠", "infty": "∞", "sum": "∑",
    "prod": "∏", "int": "∫", "to": "→", "rightarrow": "→",
    "leftarrow": "←", "approx": "≈", "in": "∈",
  ]

  static func renderExpression(
    _ characters: [Character],
    index: Int,
    stopAtClosingBrace: Bool
  ) -> String {
    var index = index
    var output = ""
    while index < characters.count {
      let character = characters[index]
      if character == "}" {
        if stopAtClosingBrace { index += 1; break }
        index += 1
        continue
      }
      if character == "{" {
        index += 1
        output += renderExpression(
          characters,
          index: index,
          stopAtClosingBrace: true
        )
        while index < characters.count, characters[index] != "}" { index += 1 }
        if index < characters.count { index += 1 }
        continue
      }
      if character == "\\" {
        index += 1
        let commandStart = index
        while index < characters.count, characters[index].isLetter { index += 1 }
        if commandStart == index {
          if index < characters.count {
            output += escape(String(characters[index]))
            index += 1
          }
          continue
        }
        let command = String(characters[commandStart ..< index])
        switch command {
        case "frac":
          let numerator = consumeGroup(characters, index: &index)
          let denominator = consumeGroup(characters, index: &index)
          if let numerator, let denominator {
            output += "<span class=\"math-fraction\"><span class=\"math-numerator\">\(numerator)</span><span class=\"math-denominator\">\(denominator)</span></span>"
          }
        case "sqrt":
          let body = consumeGroup(characters, index: &index) ?? ""
          output += "<span class=\"math-root\"><span class=\"math-root-sign\">√</span><span>\(body)</span></span>"
        case "text", "mathrm", "mathbf", "mathit", "operatorname":
          let body = consumeGroup(characters, index: &index) ?? ""
          output += "<span class=\"math-\(command.lowercased())\">\(body)</span>"
        case "left", "right":
          continue
        default:
          output += escape(commandMap[command] ?? "\\\(command)")
        }
        continue
      }
      if character == "^" || character == "_" {
        index += 1
        let body = consumeAtom(characters, index: &index)
          ?? ""
        let tag = character == "^" ? "sup" : "sub"
        output += "<\(tag)>\(body)</\(tag)>"
        continue
      }
      if character.isWhitespace {
        output += " "
      } else {
        output += escape(String(character))
      }
      index += 1
    }
    return output
  }

  static func consumeGroup(_ characters: [Character], index: inout Int) -> String? {
    while index < characters.count, characters[index].isWhitespace { index += 1 }
    guard index < characters.count, characters[index] == "{" else {
      return consumeAtom(characters, index: &index)
    }
    index += 1
    let start = index
    var depth = 1
    while index < characters.count, depth > 0 {
      if characters[index] == "{" { depth += 1 }
      if characters[index] == "}" { depth -= 1 }
      index += 1
    }
    guard depth == 0 else { return nil }
    let end = index - 1
    return renderExpression(
      Array(characters[start ..< end]),
      index: 0,
      stopAtClosingBrace: false
    )
  }

  static func consumeAtom(_ characters: [Character], index: inout Int) -> String? {
    while index < characters.count, characters[index].isWhitespace { index += 1 }
    guard index < characters.count else { return nil }
    if characters[index] == "{" {
      return consumeGroup(characters, index: &index)
    }
    if characters[index] == "\\" {
      index += 1
      let start = index
      while index < characters.count, characters[index].isLetter { index += 1 }
      let command = String(characters[start ..< index])
      return escape(commandMap[command] ?? "\\\(command)")
    }
    let value = escape(String(characters[index]))
    index += 1
    return value
  }

  static func escape(_ value: String) -> String {
    MarkupEscaping.html(value)
  }
}
