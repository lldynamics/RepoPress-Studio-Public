import Foundation

/// A bounded, non-executing scanner for HTML start tags used by publication checks.
/// Attribute names are exact, case-insensitive tokens; both HTML quoting forms and
/// legal unquoted values are accepted. Comments and raw-text elements are ignored.
enum HTMLMetadataScanner {
  static func elements(named name: String, in html: String, withinHead: Bool = false) -> [[String: String]] {
    let bytes = Array(html.utf8)
    var cursor = 0
    var rawElement: String?
    var templateDepth = 0
    var inHead = false
    var results: [[String: String]] = []
    while cursor < bytes.count {
      if let raw = rawElement {
        // In script/style/RCDATA, '<' is text unless it starts the exact
        // closing tag. Parsing JavaScript comparisons as tags can swallow
        // </script> and hide every real metadata tag that follows it.
        guard let closing = rawTextClosingTag(in: bytes, from: cursor, named: raw) else { break }
        cursor = closing
        rawElement = nil
      }
      guard bytes[cursor] == 60 else {
        cursor += 1
        continue
      }
      if bytes[cursor...].starts(with: [60, 33, 45, 45]) {
        cursor += 4
        while cursor + 2 < bytes.count && !bytes[cursor...].starts(with: [45, 45, 62]) {
          cursor += 1
        }
        cursor = min(cursor + 3, bytes.count)
        continue
      }
      cursor += 1
      let closing = cursor < bytes.count && bytes[cursor] == 47
      if closing { cursor += 1 }
      let start = cursor
      while cursor < bytes.count && isName(bytes[cursor]) { cursor += 1 }
      let tagName = String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased()
      guard !tagName.isEmpty else { continue }
      guard cursor < bytes.count,
        isSpace(bytes[cursor]) || bytes[cursor] == 47 || bytes[cursor] == 62
      else { continue }
      let attributesStart = cursor
      var quote: UInt8?
      while cursor < bytes.count {
        let byte = bytes[cursor]
        if let current = quote {
          if byte == current { quote = nil }
        } else if byte == 34 || byte == 39 {
          quote = byte
        } else if byte == 62 {
          break
        }
        cursor += 1
      }
      let attributesEnd = cursor
      guard cursor < bytes.count else { break }
      cursor += 1
      // Template content is parsed HTML but remains outside the document's
      // metadata, including after an inner template has closed.
      if tagName == "template" {
        templateDepth = closing ? max(0, templateDepth - 1) : templateDepth + 1
        continue
      }
      if !closing && ["script", "style", "textarea", "title", "noscript"].contains(tagName) {
        rawElement = tagName
      }
      guard templateDepth == 0 else { continue }
      if tagName == "head" { inHead = !closing }
      if tagName == "body", !closing { inHead = false }
      if closing { continue }
      if tagName == name.lowercased(), !withinHead || inHead {
        results.append(attributes(in: bytes, range: attributesStart..<attributesEnd))
      }
    }
    return results
  }

  private static func rawTextClosingTag(in bytes: [UInt8], from start: Int, named name: String)
    -> Int?
  {
    let ending = Array(("</" + name).utf8)
    var cursor = start
    while cursor + ending.count < bytes.count {
      if bytes[cursor] == 60,
        ending.indices.allSatisfy({ index in
          let byte = bytes[cursor + index]
          return ((65...90).contains(byte) ? byte + 32 : byte) == ending[index]
        })
      {
        let delimiter = bytes[cursor + ending.count]
        if isSpace(delimiter) || delimiter == 47 || delimiter == 62 { return cursor }
      }
      cursor += 1
    }
    return nil
  }

  static func attribute(named name: String, in tag: String) -> String? {
    let bytes = Array(tag.utf8)
    var cursor = bytes.first == 60 ? 1 : 0
    while cursor < bytes.count && isName(bytes[cursor]) { cursor += 1 }
    return attributes(in: bytes, range: cursor..<bytes.count)[name.lowercased()]
  }

  private static func attributes(in bytes: [UInt8], range: Range<Int>) -> [String: String] {
    var result: [String: String] = [:]
    var cursor = range.lowerBound
    while cursor < range.upperBound {
      while cursor < range.upperBound
        && (isSpace(bytes[cursor]) || bytes[cursor] == 47 || bytes[cursor] == 62)
      { cursor += 1 }
      let start = cursor
      while cursor < range.upperBound && !isSpace(bytes[cursor])
        && ![47, 61, 62].contains(bytes[cursor])
      { cursor += 1 }
      guard cursor > start else {
        cursor += 1
        continue
      }
      let name = String(decoding: bytes[start..<cursor], as: UTF8.self).lowercased()
      while cursor < range.upperBound && isSpace(bytes[cursor]) { cursor += 1 }
      var value = ""
      if cursor < range.upperBound && bytes[cursor] == 61 {
        cursor += 1
        while cursor < range.upperBound && isSpace(bytes[cursor]) { cursor += 1 }
        let quote: UInt8? =
          cursor < range.upperBound && [34, 39].contains(bytes[cursor]) ? bytes[cursor] : nil
        if quote != nil { cursor += 1 }
        let valueStart = cursor
        while cursor < range.upperBound {
          if let quote {
            if bytes[cursor] == quote { break }
          } else if isSpace(bytes[cursor]) || bytes[cursor] == 62 {
            break
          }
          cursor += 1
        }
        value = decodeEntities(String(decoding: bytes[valueStart..<cursor], as: UTF8.self))
        if quote != nil && cursor < range.upperBound { cursor += 1 }
      }
      // HTML keeps the first duplicate attribute.
      if result[name] == nil { result[name] = value }
    }
    return result
  }

  static func decodeEntities(_ text: String) -> String {
    var output = ""
    var cursor = text.startIndex
    let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " "]
    while cursor < text.endIndex {
      if text[cursor] == "&", let end = text[cursor...].prefix(16).firstIndex(of: ";") {
        let entity = String(text[text.index(after: cursor)..<end])
        let replacement: String?
        if entity.hasPrefix("#") {
          let hex = entity.dropFirst().hasPrefix("x") || entity.dropFirst().hasPrefix("X")
          let digits = entity.dropFirst(hex ? 2 : 1)
          replacement = UInt32(digits, radix: hex ? 16 : 10).flatMap(UnicodeScalar.init).map(
            String.init)
        } else {
          replacement = named[entity]
        }
        if let replacement {
          output += replacement
          cursor = text.index(after: end)
          continue
        }
      }
      output.append(text[cursor])
      cursor = text.index(after: cursor)
    }
    return output
  }

  private static func isSpace(_ byte: UInt8) -> Bool { [9, 10, 12, 13, 32].contains(byte) }
  private static func isName(_ byte: UInt8) -> Bool {
    (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte) || byte == 45
      || byte == 58
  }
}
