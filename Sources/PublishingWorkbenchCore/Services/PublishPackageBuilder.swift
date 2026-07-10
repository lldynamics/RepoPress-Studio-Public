import Foundation

public enum PublishFileKind: String, Codable, Sendable {
  case markdown
  case image

  public var displayName: String {
    switch self {
    case .markdown:
      return "Markdown"
    case .image:
      return "图片"
    }
  }
}

public struct PublishPackageFile: Identifiable, Codable, Hashable, Sendable {
  public var id: String { repositoryPath }
  public var kind: PublishFileKind
  public var repositoryPath: String
  public var content: String?
  public var sourceFilePath: String?
  public var byteSize: Int64
  public var expectedRemoteSHA: String?

  public init(
    kind: PublishFileKind,
    repositoryPath: String,
    content: String? = nil,
    sourceFilePath: String? = nil,
    byteSize: Int64 = 0,
    expectedRemoteSHA: String? = nil
  ) {
    self.kind = kind
    self.repositoryPath = repositoryPath
    self.content = content
    self.sourceFilePath = sourceFilePath
    self.byteSize = byteSize
    self.expectedRemoteSHA = expectedRemoteSHA
  }
}

public struct PublishPackage: Identifiable, Codable, Hashable, Sendable {
  public var id: UUID
  public var draftID: UUID
  public var title: String
  public var draftSummary: String?
  public var draftCoverAltText: String?
  public var markdownPath: String
  public var files: [PublishPackageFile]
  public var commitMessage: String
  public var reviewBranchName: String
  public var reviewTitle: String
  public var reviewChecklist: [String]
  public var builtAt: Date

  public init(
    id: UUID = UUID(),
    draftID: UUID,
    title: String,
    draftSummary: String? = nil,
    draftCoverAltText: String? = nil,
    markdownPath: String,
    files: [PublishPackageFile],
    commitMessage: String,
    reviewBranchName: String,
    reviewTitle: String,
    reviewChecklist: [String],
    builtAt: Date = Date()
  ) {
    self.id = id
    self.draftID = draftID
    self.title = title
    self.draftSummary = draftSummary
    self.draftCoverAltText = draftCoverAltText
    self.markdownPath = markdownPath
    self.files = files
    self.commitMessage = commitMessage
    self.reviewBranchName = reviewBranchName
    self.reviewTitle = reviewTitle
    self.reviewChecklist = reviewChecklist
    self.builtAt = builtAt
  }

  public var markdownFile: PublishPackageFile? {
    files.first(where: { $0.kind == .markdown })
  }
}

public struct PublishPackageBuilder {
  private let frontMatterRenderer: FrontMatterRenderer

  public init(frontMatterRenderer: FrontMatterRenderer = FrontMatterRenderer()) {
    self.frontMatterRenderer = frontMatterRenderer
  }

  public func build(draft: ArticleDraft, profile: SiteProfile) -> PublishPackage {
    let markdownPath = profile.markdownPath(for: draft)
    var files = [
      PublishPackageFile(
        kind: .markdown,
        repositoryPath: markdownPath,
        content: frontMatterRenderer.renderDocument(draft: draft, profile: profile),
        expectedRemoteSHA: expectedRemoteSHA(for: draft, markdownPath: markdownPath)
      )
    ]

    files.append(
      contentsOf: draft.attachments.map { attachment in
        PublishPackageFile(
          kind: .image,
          repositoryPath: attachment.repositoryPath,
          sourceFilePath: attachment.sourceFilePath,
          byteSize: attachment.byteSize
        )
      }
    )

    return PublishPackage(
      draftID: draft.id,
      title: draft.title,
      draftSummary: draft.summary.trimmedForPublishing.nilIfEmpty,
      draftCoverAltText: coverAltText(for: draft),
      markdownPath: markdownPath,
      files: files,
      commitMessage: "Publish: \(draft.title)",
      reviewBranchName: reviewBranchName(for: draft),
      reviewTitle: "Publish \(draft.title)",
      reviewChecklist: [
        "Front Matter 已检查",
        "图片路径和 alt/caption 已检查",
        "本地预览已确认",
        "公开风险和私密内容已确认",
      ]
    )
  }

  private func reviewBranchName(for draft: ArticleDraft) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    let dateToken = formatter.string(from: draft.date)
    let slug = draft.slug.nilIfEmpty ?? SlugService.slug(from: draft.title)
    return "publish/\(slug)-\(dateToken)"
  }

  private func expectedRemoteSHA(for draft: ArticleDraft, markdownPath: String) -> String? {
    guard draft.repositoryPath?.normalizedRelativePath() == markdownPath.normalizedRelativePath() else {
      return nil
    }
    return draft.repositorySHA?.trimmedForPublishing.nilIfEmpty
  }

  private func coverAltText(for draft: ArticleDraft) -> String? {
    guard let coverAttachmentID = draft.coverAttachmentID,
          let cover = draft.attachments.first(where: { $0.id == coverAttachmentID }) else {
      return nil
    }
    return cover.altText.trimmedForPublishing.nilIfEmpty
  }
}
