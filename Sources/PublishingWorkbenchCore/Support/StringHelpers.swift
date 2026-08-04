import Foundation

public extension String {
  var trimmedForPublishing: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var nilIfEmpty: String? {
    let trimmed = trimmedForPublishing
    return trimmed.isEmpty ? nil : trimmed
  }

  func normalizedRelativePath() -> String {
    split(separator: "/")
      .map(String.init)
      .filter { !$0.isEmpty && $0 != "." }
      .joined(separator: "/")
  }
}

/// Encodes one value as a POSIX-shell argument. Always quoting keeps
/// copyable commands safe for titles, paths, branch names, and newlines.
public func posixShellQuote(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
