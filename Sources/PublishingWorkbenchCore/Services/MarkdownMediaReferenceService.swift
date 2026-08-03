import Foundation

public enum MarkdownMediaReferenceService {
  /// Rewrites only references that belong to the attachment. Code blocks and
  /// inline code are excluded, and the destination must be a safe HTTP(S) URL.
  public static func replacingAttachmentReference(
    in markdown: String,
    attachment: DraftAttachment,
    destination: String
  ) -> String {
    guard isSafeRemoteURL(destination) else { return markdown }
    let references = Set([
      attachment.relativePublishPath,
      attachment.repositoryPath,
      attachment.remoteURL ?? "",
    ].map(normalizedReference).filter { !$0.isEmpty })
    guard !references.isEmpty else { return markdown }

    let protectedRanges = MarkdownCodeRangeScanner.scan(markdown).allRanges
    let pattern = #"!\[([^\]]*)\]\((?:<([^>]+)>|([^\s)]+))(?:\s+[^)]*)?\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return markdown }
    let source = markdown as NSString
    let matches = regex.matches(
      in: markdown,
      range: NSRange(location: 0, length: source.length)
    )
    let replacementURL = "<\(destination)>"
    let updated = NSMutableString(string: markdown)
    for match in matches.reversed() {
      guard !protectedRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
            match.numberOfRanges > 3 else { continue }
      let pathRange = match.range(at: 2).location != NSNotFound
        ? match.range(at: 2)
        : match.range(at: 3)
      guard pathRange.location != NSNotFound else { continue }
      let path = source.substring(with: pathRange)
      guard references.contains(normalizedReference(path)) else { continue }
      let fullMatch = source.substring(with: match.range)
      let alt = match.range(at: 1).location == NSNotFound
        ? ""
        : source.substring(with: match.range(at: 1))
      updated.replaceCharacters(
        in: match.range,
        with: "![\(alt)](\(replacementURL))"
      )
      _ = fullMatch
    }
    return updated as String
  }

  public static func isSafeRemoteURL(_ value: String) -> Bool {
    guard !value.contains("\n"),
          !value.contains("\r"),
          let url = URL(string: value),
          let scheme = url.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          url.host?.nilIfEmpty != nil,
          url.user == nil,
          url.password == nil else {
      return false
    }
    return true
  }

  private static func normalizedReference(_ value: String) -> String {
    let decoded = value.removingPercentEncoding ?? value
    return decoded
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "./", with: "", options: [], range: nil)
  }
}

