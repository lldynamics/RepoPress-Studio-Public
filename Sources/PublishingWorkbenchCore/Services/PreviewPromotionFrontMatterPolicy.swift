import Foundation

/// This is a deliberately conservative safety reader, not an import parser.
/// Unsupported/ambiguous metadata cannot silently become a public article.
enum PreviewPromotionFrontMatterPolicy {
  static func validatePublicDocument(_ markdown: String) throws {
    guard let document = DelimitedFrontMatterParser().split(markdown) else { throw unavailable }
    var values: [String: String] = [:]
    var inTOMLTable = false
    var firstYAMLKey = true
    let protectedKeys: Set<String> = [
      "draft", "private", "visibility", "publish", "published", "status",
    ]
    for raw in document.contentLines {
      let line = try removingComment(raw).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if document.delimiter == .toml, line.hasPrefix("[") {
        guard line.hasSuffix("]") else { throw unavailable }
        inTOMLTable = true
        continue
      }
      if document.delimiter == .yaml {
        if firstYAMLKey {
          guard raw.first?.isWhitespace != true else { throw unavailable }
          firstYAMLKey = false
        }
        if raw.first?.isWhitespace == true { continue }
        guard !line.hasPrefix("{"), !line.hasPrefix("["), !line.hasPrefix("?"),
          !line.hasPrefix("<<")
        else { throw unavailable }
      }
      let separator: Character = document.delimiter == .toml ? "=" : ":"
      guard let boundary = line.firstIndex(of: separator) else { throw unavailable }
      let rawKey = String(line[..<boundary]).trimmingCharacters(in: .whitespaces)
      guard !rawKey.contains("\\") else { throw unavailable }
      let key = try scalar(rawKey).lowercased()
      if inTOMLTable || !protectedKeys.contains(key) { continue }
      guard values[key] == nil else { throw unavailable }
      values[key] = try scalar(String(line[line.index(after: boundary)...])).lowercased()
    }
    for key in ["draft", "private"] {
      if let value = values[key] {
        guard ["false", "no", "0"].contains(value) else { throw unavailable }
      }
    }
    if let value = values["visibility"], value != "public" { throw unavailable }
    if let value = values["publish"], !["true", "yes", "1"].contains(value) { throw unavailable }
    // Jekyll uses `published: false` to suppress a page. Some other generators
    // use a date under this key; reject unknown values instead of guessing.
    if let value = values["published"], !["true", "yes", "1"].contains(value) { throw unavailable }
    if let value = values["status"], !["published", "public"].contains(value) { throw unavailable }
  }

  private static func scalar(_ text: String) throws -> String {
    let value = text.trimmingCharacters(in: .whitespaces)
    guard !value.isEmpty else { throw unavailable }
    if value.first == "\"" || value.first == "'" {
      guard value.count >= 2, value.last == value.first else { throw unavailable }
      let inner = String(value.dropFirst().dropLast())
      guard !inner.contains("\\"), !inner.contains("\""), !inner.contains("'") else {
        throw unavailable
      }
      return inner
    }
    guard !value.contains(where: { "&*!{}[]|>".contains($0) }) else { throw unavailable }
    return value
  }

  private static func removingComment(_ text: String) throws -> String {
    guard !text.contains("\"\"\""), !text.contains("'''") else { throw unavailable }
    var quote: Character?
    var escaped = false
    var result = ""
    for character in text {
      if escaped {
        result.append(character)
        escaped = false
        continue
      }
      if character == "\\", quote == "\"" {
        result.append(character)
        escaped = true
        continue
      }
      if let current = quote {
        result.append(character)
        if character == current { quote = nil }
      } else if character == "#" {
        break
      } else {
        result.append(character)
        if character == "\"" || character == "'" { quote = character }
      }
    }
    guard quote == nil, !escaped else { throw unavailable }
    return result
  }

  private static var unavailable: PreviewPromotionError {
    .unavailable(CoreL10n.text("预览元数据包含草稿、私密或无法确认的标记；请在写作中确认公开设置并重新生成预览。"))
  }
}
