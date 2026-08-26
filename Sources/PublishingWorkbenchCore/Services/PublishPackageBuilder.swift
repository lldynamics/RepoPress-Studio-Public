import Foundation
import PublishingDomainContracts
import PublishingGitCore

public extension PublishFileKind {
  var displayName: String {
    switch self {
    case .markdown:
      return "Markdown"
    case .image:
      return CoreL10n.text("图片")
    case .video:
      return CoreL10n.text("视频")
    }
  }
}

public extension PublishFileOperation {
  var displayName: String {
    switch self {
    case .upsert:
      return "写入"
    case .delete:
      return "删除"
    }
  }
}

public struct PublishPackageBuilder: Sendable {
  private let frontMatterRenderer: FrontMatterRenderer
  private let packageAssembler: PublishPackageAssembler

  public init(frontMatterRenderer: FrontMatterRenderer = FrontMatterRenderer()) {
    self.frontMatterRenderer = frontMatterRenderer
    self.packageAssembler = PublishPackageAssembler()
  }

  public func build(draft: ArticleDraft, profile: SiteProfile) -> PublishPackage {
    let markdownPath = profile.markdownPath(for: draft)
    let markdown = PublishPackageBuildInput.Markdown(
      repositoryPath: markdownPath,
      content: frontMatterRenderer.renderDocument(draft: draft, profile: profile),
      expectedRemoteSHA: verifiedRemoteRevision(
        for: draft,
        profile: profile,
        repositoryPath: markdownPath
      )
    )

    let attachments = draft.attachments.map { attachment in
      PublishPackageBuildInput.Attachment(
        kind: attachment.mediaKind == .video ? .video : .image,
        repositoryPath: attachment.repositoryPath,
        sourceFilePath: attachment.sourceFilePath,
        byteSize: attachment.byteSize,
        expectedRemoteSHA: attachment.repositorySHA?.trimmedForPublishing.nilIfEmpty
      )
    }

    let previousMarkdownDeletion: PublishPackageBuildInput.PreviousMarkdownDeletion?
    if let previousMarkdownPath = previousMarkdownPath(for: draft, currentPath: markdownPath) {
      previousMarkdownDeletion = PublishPackageBuildInput.PreviousMarkdownDeletion(
        repositoryPath: previousMarkdownPath,
        expectedRemoteSHA: verifiedRemoteRevision(
          for: draft,
          profile: profile,
          repositoryPath: previousMarkdownPath
        )
      )
    } else {
      previousMarkdownDeletion = nil
    }

    let input = PublishPackageBuildInput(
      draftID: draft.id,
      title: draft.title,
      draftSummary: draft.summary.trimmedForPublishing.nilIfEmpty,
      draftCoverAltText: coverAltText(for: draft),
      markdown: markdown,
      attachments: attachments,
      previousMarkdownDeletion: previousMarkdownDeletion,
      publicationDate: draft.date,
      reviewSlug: draft.slug.nilIfEmpty ?? SlugService.slug(from: draft.title)
    )
    return packageAssembler.assemble(input)
  }

  private func verifiedRemoteRevision(
    for draft: ArticleDraft,
    profile: SiteProfile,
    repositoryPath: String
  ) -> String? {
    guard let binding = draft.repositoryBinding,
      binding.verification == .verified,
      binding.identity == DraftRepositoryIdentity(profile: profile),
      binding.repositoryPath.normalizedRelativePath()
        == repositoryPath.normalizedRelativePath()
    else {
      return nil
    }
    return binding.remoteRevision?.trimmedForPublishing.nilIfEmpty
  }

  private func previousMarkdownPath(for draft: ArticleDraft, currentPath: String) -> String? {
    guard let previousPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
          previousPath != currentPath.normalizedRelativePath() else {
      return nil
    }
    return previousPath
  }

  private func coverAltText(for draft: ArticleDraft) -> String? {
    guard let coverAttachmentID = draft.coverAttachmentID,
          let cover = draft.attachments.first(where: { $0.id == coverAttachmentID }) else {
      return nil
    }
    return cover.altText.trimmedForPublishing.nilIfEmpty
  }
}
