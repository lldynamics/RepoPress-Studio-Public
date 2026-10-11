import Foundation

extension PreflightCheckService {
  private static let markdownImageRegex = try? NSRegularExpression(
    pattern: #"!\[[^\]]*\]\(([^)]+)\)"#
  )
  func missingMarkdownImagePaths(in draft: ArticleDraft) -> [String] {
    let registered = Set(
      draft.attachments
        .filter { $0.mediaKind == .image }
        .map(\.relativePublishPath)
    )
    guard let regex = Self.markdownImageRegex else {
      return []
    }

    let text = draft.bodyMarkdown
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
      let path = String(text[matchRange])
      guard !path.hasPrefix("http://"), !path.hasPrefix("https://"), !path.hasPrefix("data:") else {
        return nil
      }
      return registered.contains(path) ? nil : path
    }
  }
}
