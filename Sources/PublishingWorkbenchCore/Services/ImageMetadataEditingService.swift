import Foundation

public struct ImageMetadataUpdateResult: Equatable, Sendable {
  public var draft: ArticleDraft
  public var updatedMarkdownReferenceCount: Int

  public init(draft: ArticleDraft, updatedMarkdownReferenceCount: Int) {
    self.draft = draft
    self.updatedMarkdownReferenceCount = updatedMarkdownReferenceCount
  }
}

public struct ImageMetadataEditingService {
  public init() {}

  public func markdownReference(altText: String, imagePath: String) -> String {
    "![\(escapedMarkdownAlt(normalizedAltText(altText)))](\(imagePath))"
  }

  public func updating(
    draft: ArticleDraft,
    attachmentID: UUID,
    altText: String,
    caption: String,
    isCover: Bool
  ) -> ImageMetadataUpdateResult? {
    guard let attachmentIndex = draft.attachments.firstIndex(where: { $0.id == attachmentID }) else {
      return nil
    }

    var updated = draft
    let normalizedAlt = normalizedAltText(altText)
    updated.attachments[attachmentIndex].altText = normalizedAlt
    updated.attachments[attachmentIndex].caption = caption.trimmedForPublishing

    if isCover {
      updated.coverAttachmentID = attachmentID
    } else if updated.coverAttachmentID == attachmentID {
      updated.coverAttachmentID = nil
    }

    let replacement = replacingMarkdownAlt(
      in: updated.bodyMarkdown,
      imagePath: updated.attachments[attachmentIndex].relativePublishPath,
      altText: normalizedAlt
    )
    updated.bodyMarkdown = replacement.markdown

    return ImageMetadataUpdateResult(
      draft: updated,
      updatedMarkdownReferenceCount: replacement.count
    )
  }

  private func replacingMarkdownAlt(
    in markdown: String,
    imagePath: String,
    altText: String
  ) -> (markdown: String, count: Int) {
    let pattern = #"!\[((?:\\.|[^\]])*)\]\("#
      + NSRegularExpression.escapedPattern(for: imagePath)
      + #"(?:\s+(?:\"[^\"]*\"|'[^']*'|\([^)]*\)))?\)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return (markdown, 0)
    }

    let source = markdown as NSString
    let matches = regex.matches(
      in: markdown,
      range: NSRange(location: 0, length: source.length)
    )
    guard !matches.isEmpty else {
      return (markdown, 0)
    }

    let updated = NSMutableString(string: markdown)
    let escapedAlt = escapedMarkdownAlt(altText)
    for match in matches.reversed() {
      updated.replaceCharacters(in: match.range(at: 1), with: escapedAlt)
    }
    return (updated as String, matches.count)
  }

  private func normalizedAltText(_ text: String) -> String {
    text
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }

  private func escapedMarkdownAlt(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "[", with: "\\[")
      .replacingOccurrences(of: "]", with: "\\]")
  }
}
