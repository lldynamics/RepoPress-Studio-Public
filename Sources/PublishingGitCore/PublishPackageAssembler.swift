import Foundation
import PublishingDomainContracts

/// Purely assembles the serializable package contract from Foundation-only
/// input. Draft and site policy decisions belong to the Workbench facade.
public struct PublishPackageAssembler: Sendable {
  public init() {}

  public func assemble(_ input: PublishPackageBuildInput) -> PublishPackage {
    let markdownFile = PublishPackageFile(
      kind: .markdown,
      repositoryPath: input.markdown.repositoryPath,
      content: input.markdown.content,
      expectedRemoteSHA: input.markdown.expectedRemoteSHA,
      expectedContentSHA256: input.markdown.expectedContentSHA256,
      expectedGitBlobSHA: input.markdown.expectedGitBlobSHA
    )
    let attachmentFiles = input.attachments.map { attachment in
      PublishPackageFile(
        kind: attachment.kind,
        repositoryPath: attachment.repositoryPath,
        sourceFilePath: attachment.sourceFilePath,
        byteSize: attachment.byteSize,
        expectedRemoteSHA: attachment.expectedRemoteSHA,
        expectedContentSHA256: attachment.expectedContentSHA256,
        expectedGitBlobSHA: attachment.expectedGitBlobSHA
      )
    }
    var files = [markdownFile]
    files.append(contentsOf: attachmentFiles)
    if let deletion = input.previousMarkdownDeletion {
      files.append(
        PublishPackageFile(
          kind: .markdown,
          operation: .delete,
          repositoryPath: deletion.repositoryPath,
          expectedRemoteSHA: deletion.expectedRemoteSHA,
          expectedContentSHA256: deletion.expectedContentSHA256,
          expectedGitBlobSHA: deletion.expectedGitBlobSHA
        )
      )
    }

    return PublishPackage(
      draftID: input.draftID,
      title: input.title,
      draftSummary: input.draftSummary,
      draftCoverAltText: input.draftCoverAltText,
      markdownPath: input.markdown.repositoryPath,
      files: files,
      commitMessage: "Publish: \(input.title)",
      reviewBranchName: reviewBranchName(for: input),
      reviewTitle: "Publish \(input.title)",
      reviewChecklist: [
        "Front Matter 已检查",
        "图片、视频路径和 alt/caption 已检查",
        "本地预览已确认",
        "公开风险和私密内容已确认",
      ],
      builtAt: input.builtAt
    )
  }

  private func reviewBranchName(for input: PublishPackageBuildInput) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd"
    return "publish/\(input.reviewSlug)-\(formatter.string(from: input.publicationDate))"
  }
}
