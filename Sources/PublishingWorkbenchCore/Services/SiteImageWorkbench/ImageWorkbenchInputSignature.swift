import Foundation

/// The subset of a draft and profile that can change an image report.
///
/// In particular, this intentionally excludes ordinary article prose so typing
/// outside Markdown image references does not invalidate file-backed scans.
public struct ImageWorkbenchReportInputSignature: Hashable, Sendable {
  private static let markdownImageRegex = try! NSRegularExpression(
    pattern: #"!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#
  )
  public let draftID: UUID

  private let visibility: ArticleVisibility
  private let coverAttachmentID: UUID?
  private let attachments: [DraftAttachment]
  private let markdownImageReferences: [MarkdownImageReference]
  private let profile: ProfileInput

  public init(draft: ArticleDraft, profile: SiteProfile) {
    self.draftID = draft.id
    self.visibility = draft.visibility
    self.coverAttachmentID = draft.coverAttachmentID
    self.attachments = draft.attachments
    self.markdownImageReferences = Self.markdownImageReferences(in: draft.bodyMarkdown)
    self.profile = ProfileInput(profile: profile)
  }

  private struct MarkdownImageReference: Hashable, Sendable {
    let path: String
    let count: Int
  }

  private struct ProfileInput: Hashable, Sendable {
    let siteKind: SiteKind
    let includeCoverInFrontMatter: Bool

    init(profile: SiteProfile) {
      self.siteKind = profile.siteKind
      self.includeCoverInFrontMatter = profile.includeCoverInFrontMatter
    }
  }

  private static func markdownImageReferences(in markdown: String) -> [MarkdownImageReference] {
    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    let counts = markdownImageRegex.matches(in: markdown, range: range).reduce(into: [String: Int]()) { result, match in
      guard let matchRange = Range(match.range(at: 1), in: markdown) else { return }
      let path = String(markdown[matchRange])
      guard !path.hasPrefix("http://"), !path.hasPrefix("https://"), !path.hasPrefix("data:") else {
        return
      }
      result[path, default: 0] += 1
    }
    return counts
      .map { MarkdownImageReference(path: $0.key, count: $0.value) }
      .sorted { $0.path < $1.path }
  }
}

/// The image-sensitive input for a site summary. Article titles are included
/// because the summary displays and sorts by title, while unrelated body prose
/// remains excluded through ``ImageWorkbenchReportInputSignature``.
public struct ImageWorkbenchSiteSummaryInputSignature: Hashable, Sendable {
  private let drafts: [DraftInput]

  public init(drafts: [ArticleDraft], profile: SiteProfile) {
    self.drafts = drafts.map { draft in
      DraftInput(
        title: draft.title,
        report: ImageWorkbenchReportInputSignature(draft: draft, profile: profile)
      )
    }
  }

  private struct DraftInput: Hashable, Sendable {
    let title: String
    let report: ImageWorkbenchReportInputSignature
  }
}
