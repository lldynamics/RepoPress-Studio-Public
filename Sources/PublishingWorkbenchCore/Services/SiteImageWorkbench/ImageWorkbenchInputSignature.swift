import Foundation

/// The Markdown-only portion of an image report input. It is intentionally
/// separate from file attributes so edit commits can decide whether an image
/// cache revision changed without touching the file system.
public struct ImageWorkbenchMarkdownReferenceSignature: Hashable, Sendable {
  private static let markdownImageRegex = try? NSRegularExpression(
    pattern: #"!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#
  )
  private let references: [Reference]

  public init(markdown: String) {
    let range = NSRange(markdown.startIndex..<markdown.endIndex, in: markdown)
    let matches = Self.markdownImageRegex?.matches(in: markdown, range: range) ?? []
    let counts = matches
      .reduce(into: [String: Int]()) { result, match in
        guard let matchRange = Range(match.range(at: 1), in: markdown) else { return }
        let path = String(markdown[matchRange])
        guard !path.hasPrefix("http://"),
              !path.hasPrefix("https://"),
              !path.hasPrefix("data:") else { return }
        result[path, default: 0] += 1
      }
    references = counts
      .map { Reference(path: $0.key, count: $0.value) }
      .sorted { $0.path < $1.path }
  }

  private struct Reference: Hashable, Sendable {
    let path: String
    let count: Int
  }
}

/// The subset of a draft and profile that can change an image report.
///
/// In particular, this intentionally excludes ordinary article prose so typing
/// outside Markdown image references does not invalidate file-backed scans.
public struct ImageWorkbenchReportInputSignature: Hashable, Sendable {
  public let draftID: UUID

  private let visibility: ArticleVisibility
  private let coverAttachmentID: UUID?
  private let attachments: [DraftAttachment]
  private let attachmentFiles: [AttachmentFileInput]
  private let markdownImageReferences: ImageWorkbenchMarkdownReferenceSignature
  private let profile: ProfileInput

  public init(draft: ArticleDraft, profile: SiteProfile) {
    self.draftID = draft.id
    self.visibility = draft.visibility
    self.coverAttachmentID = draft.coverAttachmentID
    self.attachments = draft.attachments
    self.attachmentFiles = draft.attachments.map(AttachmentFileInput.init)
    self.markdownImageReferences = ImageWorkbenchMarkdownReferenceSignature(
      markdown: draft.bodyMarkdown
    )
    self.profile = ProfileInput(profile: profile)
  }

  private struct AttachmentFileInput: Hashable, Sendable {
    let attachmentID: UUID
    let sourcePath: String?
    let exists: Bool
    let byteSize: Int64?
    let modifiedAt: Date?

    init(attachment: DraftAttachment) {
      attachmentID = attachment.id
      sourcePath = attachment.sourceFilePath
      guard let sourcePath = attachment.sourceFilePath?.nilIfEmpty else {
        exists = false
        byteSize = nil
        modifiedAt = nil
        return
      }

      let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath)
      exists = attributes != nil
      byteSize = (attributes?[.size] as? NSNumber)?.int64Value
      modifiedAt = attributes?[.modificationDate] as? Date
    }
  }

  private struct ProfileInput: Hashable, Sendable {
    let siteKind: SiteKind
    let includeCoverInFrontMatter: Bool

    init(profile: SiteProfile) {
      self.siteKind = profile.siteKind
      self.includeCoverInFrontMatter = profile.includeCoverInFrontMatter
    }
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
