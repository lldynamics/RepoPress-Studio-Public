import Foundation

/// The original envelope remains recoverable even when a field cannot be edited safely.
public struct ImportedFrontMatter: Codable, Hashable, Sendable {
  public enum Syntax: String, Codable, Sendable { case yaml, toml }
  public var rawBlock: String
  public var syntax: Syntax
  public var baseline: [String: String]

  public init(rawBlock: String, syntax: Syntax, baseline: [String: String] = [:]) {
    self.rawBlock = rawBlock
    self.syntax = syntax
    self.baseline = baseline
  }

  public static func split(_ markdown: String) -> (frontMatter: Self?, body: String) {
    let lines = markdown.components(separatedBy: "\n")
    let opening = lines[0].trimmingCharacters(in: CharacterSet(charactersIn: "\r\u{FEFF}"))
    guard opening == "---" || opening == "+++" else { return (nil, markdown) }
    let syntax: Syntax = opening == "---" ? .yaml : .toml
    var lexicalState = LexicalState()
    for closing in lines.indices.dropFirst() {
      if !lexicalState.isOpen,
        lines[closing].trimmingCharacters(in: CharacterSet(charactersIn: "\r")) == opening {
        return (
          Self(rawBlock: lines[...closing].joined(separator: "\n"), syntax: syntax),
          lines.dropFirst(closing + 1).joined(separator: "\n")
        )
      }
      if syntax == .toml { _ = lexicalState.consume(lines[closing]) }
    }
    // Do not reinterpret a broken envelope as ordinary body and generate a second header.
    return (Self(rawBlock: markdown, syntax: syntax), "")
  }

  public func value(for path: String) -> String? {
    let scan = FrontMatterSourceScan(rawBlock, syntax: syntax)
    guard let entry = scan.entries[path], entry.count == 1 else { return nil }
    return entry[0].value
  }

  public func string(for path: String) -> String? {
    value(for: path).flatMap(Self.decodeString)
  }

  public func strings(for path: String) -> [String] {
    guard let raw = value(for: path), raw.hasPrefix("["), raw.hasSuffix("]") else { return [] }
    guard let parts = FrontMatterSourceScan.parts(String(raw.dropFirst().dropLast()), separator: ",") else {
      return []
    }
    return parts.compactMap { part in
      let value = part.trimmingCharacters(in: .whitespacesAndNewlines)
      return value.isEmpty ? nil : Self.decodeString(value)
    }
  }

  public static func quoted(_ value: String) -> String {
    // JSON double-quoted strings are valid single-line YAML/TOML basic strings.
    let encoder = JSONEncoder()
    encoder.outputFormatting = .withoutEscapingSlashes
    let data = (try? encoder.encode(value)) ?? Data("\"\"".utf8)
    return String(data: data, encoding: .utf8) ?? "\"\""
  }

  public static func array(_ values: [String]) -> String {
    "[" + values.map(quoted).joined(separator: ", ") + "]"
  }

  /// Replacements are source paths, not flattened keys. No profile defaults are applied here.
  public func replacing(_ replacements: [String: String]) throws -> String {
    if rawBlock.isEmpty {
      guard !replacements.isEmpty else { return "" }
      let delimiter = syntax == .yaml ? "---" : "+++"
      return try Self(rawBlock: delimiter + "\n" + delimiter, syntax: syntax).replacing(replacements)
    }
    let scan = FrontMatterSourceScan(rawBlock, syntax: syntax)
    if let problem = scan.problem { throw FrontMatterPreservationError.unsafe(problem) }
    var edits: [(NSRange, String)] = []
    var additions: [(String, String)] = []
    for path in replacements.keys.sorted() {
      let value = replacements[path]!
      if let entries = scan.entries[path] {
        guard entries.count == 1, let entry = entries.first, entry.editable,
          !entry.value.hasPrefix("{"), entry.value.hasPrefix("[") == value.hasPrefix("[") else {
          throw FrontMatterPreservationError.unsafe(path)
        }
        edits.append((entry.range, value))
      } else {
        // Inserting only simple root keys avoids creating/reopening tables or guessing scope.
        guard Self.isSimpleKey(path), !scan.entries.keys.contains(where: { $0.hasPrefix(path + ".") }) else {
          throw FrontMatterPreservationError.unsafe(path)
        }
        additions.append((path, value))
      }
    }
    if !additions.isEmpty {
      let separator = syntax == .yaml ? ": " : " = "
      let newline = rawBlock.contains("\r\n") ? "\r\n" : "\n"
      edits.append((NSRange(location: scan.rootInsertionOffset, length: 0),
        additions.map { $0.0 + separator + $0.1 + newline }.joined()))
    }
    let result = NSMutableString(string: rawBlock)
    for (range, value) in edits.sorted(by: { $0.0.location > $1.0.location }) {
      result.replaceCharacters(in: range, with: value)
    }
    return result as String
  }

  private static func isSimpleKey(_ key: String) -> Bool {
    !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
  }

  fileprivate static func decodeString(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("\"") {
      return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
    }
    if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
      return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    guard !value.isEmpty, !value.contains("\n"),
      !["|", ">", "&", "*", "!", "[", "{"].contains(where: value.hasPrefix)
    else { return nil }
    return value
  }
}

public enum FrontMatterPreservationError: Error, Equatable, Sendable {
  case unsafe(String)
}

/// A conservative source scanner, deliberately not a YAML/TOML reserializer.
/// Complex values survive verbatim; only unambiguous single-line values can be replaced.
private struct FrontMatterSourceScan {
  struct Entry {
    var range: NSRange
    var value: String
    var editable: Bool
  }
  var entries: [String: [Entry]] = [:]
  var problem: String?
  var rootInsertionOffset = 0

  private var section = ""
  private var yamlParent = ""
  private var taxonomyIndent: Int?
  private var yamlListPath: String?
  private var yamlList: [String] = []
  private var multiline = LexicalState()
  private var seenTables: Set<String> = []

  init(_ raw: String, syntax: ImportedFrontMatter.Syntax) {
    let lines = raw.components(separatedBy: "\n")
    let delimiter = syntax == .yaml ? "---" : "+++"
    guard lines.count >= 2,
      lines.first?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))) == delimiter,
      lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == delimiter
    else { problem = "delimiter"; return }
    var offset = (lines[0] as NSString).length + 1
    rootInsertionOffset = offset
    for line in lines.dropFirst().dropLast() {
      consume(line, offset: offset, syntax: syntax)
      offset += (line as NSString).length + 1
    }
    if multiline.isOpen || multiline.invalid { problem = "multiline" }
  }

  private mutating func consume(_ line: String, offset: Int, syntax: ImportedFrontMatter.Syntax) {
    let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if multiline.isOpen {
      _ = multiline.consume(line)
      return
    }
    if clean.isEmpty || clean.hasPrefix("#") { return }
    if syntax == .toml && clean.hasPrefix("[") {
      consumeTable(clean)
      return
    }
    if syntax == .yaml && shouldSkipYAMLLine(line, clean: clean) { return }
    let separator: Character = syntax == .yaml ? ":" : "="
    guard let separatorIndex = Self.unquotedIndex(of: separator, in: line) else {
      problem = "mapping"
      return
    }
    guard let key = Self.keyPath(String(line[..<separatorIndex]), syntax: syntax) else {
      problem = "key"
      return
    }
    if key == "<<" { problem = "merge"; return }
    let valueStart = line.index(after: separatorIndex)
    let suffix = String(line[valueStart...])
    var state = LexicalState()
    let contentCount = Self.valueContentCount(suffix, syntax: syntax, state: &state)
    let prefix = String(suffix.prefix(contentCount))
    let value = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    let range = NSRange(
      location: offset + (String(line[..<valueStart]) as NSString).length + leadingWhitespaceLength(prefix),
      length: (value as NSString).length
    )
    let path = sourcePath(for: key, line: line, syntax: syntax)
    record(path: path, range: range, value: value, state: state, syntax: syntax)
  }

  private mutating func record(
    path: String, range: NSRange, value: String, state: LexicalState, syntax: ImportedFrontMatter.Syntax
  ) {
    let editable = !value.isEmpty && !state.isOpen && !state.invalid
      && !["|", ">", "&", "*", "!"].contains(where: value.hasPrefix)
    entries[path, default: []].append(Entry(range: range, value: value, editable: editable))
    if entries[path]!.count > 1 && !section.hasPrefix("[]") { problem = path }
    if state.invalid { problem = path }
    if state.isOpen { multiline = state }
    if syntax == .yaml {
      yamlListPath = value.isEmpty ? path : nil
      yamlList = []
    }
    if path == "taxonomies", value.hasPrefix("{"), value.hasSuffix("}") {
      scanInlineTaxonomies(value, range: range, syntax: syntax)
    }
  }

  private static func valueContentCount(
    _ suffix: String, syntax: ImportedFrontMatter.Syntax, state: inout LexicalState
  ) -> Int {
    let trimmed = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard syntax == .yaml, let first = trimmed.first,
      !["\"", "'", "[", "{"].contains(first)
    else { return state.consume(suffix) }
    // In a YAML plain scalar, quotes/brackets are text, and # starts a comment
    // only when separated by whitespace (e.g. a URL fragment is part of the value).
    let characters = Array(suffix)
    return characters.indices.first { index in
      characters[index] == "#" && (index == 0 || characters[index - 1].isWhitespace)
    } ?? characters.count
  }

  private mutating func sourcePath(for key: String, line: String, syntax: ImportedFrontMatter.Syntax) -> String {
    guard syntax == .yaml else { return section.isEmpty ? key : section + "." + key }
    let indented = line.first?.isWhitespace == true
    if !indented {
      yamlParent = key
      taxonomyIndent = nil
    }
    return indented ? yamlParent + "." + key : key
  }

  private mutating func shouldSkipYAMLLine(_ line: String, clean: String) -> Bool {
    if clean.hasPrefix("- "), let path = yamlListPath {
      let suffix = String(clean.dropFirst(2))
      var state = LexicalState()
      let value = String(suffix.prefix(state.consume(suffix)))
      if let decoded = ImportedFrontMatter.decodeString(value), !value.contains(": ") {
        yamlList.append(decoded)
        entries[path]?[0].value = ImportedFrontMatter.array(yamlList)
      } else { yamlListPath = nil }
      return true
    }
    guard line.first?.isWhitespace == true else { return false }
    guard yamlParent == "taxonomies" else {
      entries[yamlParent]?[0].editable = false
      return true
    }
    let indent = leadingWhitespaceLength(line)
    if taxonomyIndent == nil { taxonomyIndent = indent }
    return indent != taxonomyIndent
  }

  private mutating func consumeTable(_ clean: String) {
    var state = LexicalState()
    let header = String(clean.prefix(state.consume(clean))).trimmingCharacters(in: .whitespaces)
    let isArray = header.hasPrefix("[[")
    let count = isArray ? 2 : 1
    guard header.hasSuffix(isArray ? "]]" : "]"), !state.isOpen,
      let key = Self.keyPath(String(header.dropFirst(count).dropLast(count)), syntax: .toml)
    else { problem = "table"; return }
    section = isArray ? "[]" + key : key
    if !seenTables.insert(section).inserted && !isArray { problem = section }
  }

  private static func unquotedIndex(of separator: Character, in text: String) -> String.Index? {
    var state = LexicalState()
    for index in text.indices {
      if text[index] == separator && !state.isOpen { return index }
      _ = state.consume(String(text[index]), allowsTripleQuotes: false)
    }
    return nil
  }

  private static func keyPath(_ raw: String, syntax: ImportedFrontMatter.Syntax) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let components = syntax == .toml ? parts(trimmed, separator: ".") : [trimmed]
    guard let components, !components.isEmpty else { return nil }
    var decoded: [String] = []
    for component in components {
      let key = component.trimmingCharacters(in: .whitespaces)
      if key.hasPrefix("\"") || key.hasPrefix("'") {
        guard let value = ImportedFrontMatter.decodeString(key) else { return nil }
        // A quoted dot belongs to the literal key, never a nested editor path.
        decoded.append(value.replacingOccurrences(of: ".", with: "\u{1F}"))
      } else {
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace }) else { return nil }
        decoded.append(key)
      }
    }
    return decoded.joined(separator: ".")
  }

  mutating func scanInlineTaxonomies(_ raw: String, range: NSRange, syntax: ImportedFrontMatter.Syntax) {
    let inner = String(raw.dropFirst().dropLast())
    guard let parts = Self.parts(inner, separator: ",") else { return }
    var offset = range.location + 1
    for part in parts {
      defer { offset += (part as NSString).length + 1 }
      let separator: Character = syntax == .yaml ? ":" : "="
      guard let index = part.firstIndex(of: separator) else { continue }
      let key = part[..<index].trimmingCharacters(in: .whitespaces)
      guard key == "tags" || key == "categories" else { continue }
      let start = part.index(after: index)
      let suffix = String(part[start...])
      let value = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
      let path = "taxonomies." + key
      entries[path, default: []].append(Entry(
        range: NSRange(location: offset + (String(part[..<start]) as NSString).length + leadingWhitespaceLength(suffix),
                       length: (value as NSString).length),
        value: value, editable: !value.isEmpty
      ))
      if entries[path]!.count > 1 { problem = path }
    }
  }

  static func parts(_ raw: String, separator: Character) -> [String]? {
    var state = LexicalState()
    var parts: [String] = []
    var start = raw.startIndex
    for index in raw.indices {
      if raw[index] == separator && !state.isOpen {
        parts.append(String(raw[start..<index]))
        start = raw.index(after: index)
      } else { _ = state.consume(String(raw[index]), allowsTripleQuotes: false) }
    }
    guard !state.isOpen, !state.invalid else { return nil }
    parts.append(String(raw[start...]))
    return parts
  }

  private func leadingWhitespaceLength(_ value: String) -> Int {
    (String(value.prefix(while: { $0 == " " || $0 == "\t" })) as NSString).length
  }
}

private struct LexicalState {
  var quote: Character?
  var triple = false
  var escaped = false
  var brackets: [Character] = []
  var invalid = false
  var isOpen: Bool { quote != nil || !brackets.isEmpty }

  /// Returns the character count before an unquoted comment.
  mutating func consume(_ text: String, allowsTripleQuotes: Bool = true) -> Int {
    let chars = Array(text)
    var index = 0
    while index < chars.count {
      let character = chars[index]
      if quote != nil {
        index += consumeQuoted(chars, at: index)
      } else if character == "#" {
        return index
      } else if character == "\"" || character == "'" {
        quote = character
        if allowsTripleQuotes && index + 2 < chars.count && chars[index + 1] == character && chars[index + 2] == character {
          triple = true; index += 2
        }
      } else if character == "[" || character == "{" {
        brackets.append(character)
      } else if character == "]" || character == "}" {
        if brackets.popLast() != (character == "]" ? "[" : "{") { invalid = true }
      }
      index += 1
    }
    return chars.count
  }

  private mutating func consumeQuoted(_ chars: [Character], at index: Int) -> Int {
    let character = chars[index]
    if escaped {
      escaped = false
    } else if character == "\\" && quote == "\"" {
      escaped = true
    } else if character == quote {
      if !triple {
        quote = nil
      } else if index + 2 < chars.count && chars[index + 1] == quote && chars[index + 2] == quote {
        quote = nil
        triple = false
        return 2
      }
    }
    return 0
  }

}
