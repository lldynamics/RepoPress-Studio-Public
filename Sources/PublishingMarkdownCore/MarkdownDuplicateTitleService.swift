import Foundation

/// Finds only a title repeated at the start of the body. Ranges include the
/// title's own line ending, leaving every surrounding blank line unchanged.
public enum MarkdownDuplicateTitleService {
  public static func duplicateTitleRange(in body: String, title: String) -> NSRange? {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, !title.contains(where: \.isNewline) else { return nil }
    let source = body as NSString
    var location = 0
    while location < source.length {
      let line = source.lineRange(for: NSRange(location: location, length: 0))
      let raw = source.substring(with: line).trimmingCharacters(in: .newlines)
      let text = raw.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else {
        location = NSMaxRange(line)
        continue
      }
      // Four-space or tab indentation is code, even when its text is the title.
      guard !isCodeIndented(raw) else {
        return nil
      }
      if text.hasPrefix("#") {
        guard text.hasPrefix("# ") || text.hasPrefix("#\t") else { return nil }
        var heading = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        let withoutClosingHashes = heading.dropLast(
          heading.reversed().prefix(while: { $0 == "#" }).count)
        if withoutClosingHashes.isEmpty || withoutClosingHashes.last?.isWhitespace == true {
          heading = String(withoutClosingHashes).trimmingCharacters(in: .whitespaces)
        }
        return heading == title ? line : nil
      }
      // Do not reinterpret a Markdown block or front-matter delimiter as prose.
      guard !text.hasPrefix("```"), !text.hasPrefix("~~~"),
        !text.hasPrefix(">"), !text.hasPrefix("<"),
        !text.hasPrefix("- "), !text.hasPrefix("* "), !text.hasPrefix("+ "),
        !text.hasPrefix("-\t"), !text.hasPrefix("*\t"), !text.hasPrefix("+\t"),
        !isOrderedListItem(text),
        text != "---", text != "+++", text != "***", text != "___"
      else { return nil }
      guard text == title else { return nil }
      let nextLocation = NSMaxRange(line)
      if nextLocation < source.length {
        let nextLine = source.lineRange(for: NSRange(location: nextLocation, length: 0))
        let rawNext = source.substring(with: nextLine).trimmingCharacters(in: .newlines)
        let next = rawNext.trimmingCharacters(in: .whitespaces)
        if !isCodeIndented(rawNext) {
          if !next.isEmpty, next.allSatisfy({ $0 == "=" }) {
            return NSRange(location: line.location, length: NSMaxRange(nextLine) - line.location)
          }
          // A matching H2 is a section, not a repeated document title.
          if !next.isEmpty, next.allSatisfy({ $0 == "-" }) { return nil }
        }
      }
      return line
    }
    return nil
  }

  public static func removalEdit(
    in body: String, title: String, selectedRange: NSRange
  ) -> MarkdownSmartEdit? {
    guard let range = duplicateTitleRange(in: body, title: title) else { return nil }
    let length = (body as NSString).length
    let start = min(max(selectedRange.location, 0), length)
    let end = start + min(max(selectedRange.length, 0), length - start)
    func shifted(_ location: Int) -> Int {
      location <= range.location ? location : max(range.location, location - range.length)
    }
    let selectionStart = shifted(start)
    return MarkdownSmartEdit(
      replacedRange: range, replacement: "",
      selectedRange: NSRange(location: selectionStart, length: shifted(end) - selectionStart)
    )
  }

  private static func isOrderedListItem(_ text: String) -> Bool {
    let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
    guard !digits.isEmpty, digits.count <= 9 else { return false }
    let suffix = text.dropFirst(digits.count)
    guard suffix.first == "." || suffix.first == ")" else { return false }
    return suffix.dropFirst().first?.isWhitespace == true
  }

  private static func isCodeIndented(_ line: String) -> Bool {
    var column = 0
    for character in line {
      if character == " " {
        column += 1
      } else if character == "\t" {
        column += 4 - column % 4
      } else {
        break
      }
      if column >= 4 { return true }
    }
    return false
  }
}
