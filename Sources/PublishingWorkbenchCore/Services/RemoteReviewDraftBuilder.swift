import Foundation

public struct RemoteReviewDraftBuilder {
  public init() {}

  public func build(package: PublishPackage, profile: SiteProfile) -> RemoteReviewDraft {
    let body = reviewBody(package: package, profile: profile)
    let targetBranch = profile.branch.nilIfEmpty ?? "main"
    let title = localizedReviewTitle(for: package)
    return RemoteReviewDraft(
      provider: profile.repositoryProvider,
      branchName: package.reviewBranchName,
      targetBranch: targetBranch,
      title: title,
      body: body,
      webURL: reviewWebURL(
        branchName: package.reviewBranchName,
        targetBranch: targetBranch,
        title: title,
        profile: profile,
        body: body
      )
    )
  }

  private func reviewBody(package: PublishPackage, profile: SiteProfile) -> String {
    let checklist = package.reviewChecklist
      .map { "- [ ] \(localizedChecklistItem($0))" }
      .joined(separator: "\n")
    let files = package.files
      .map { file in
        CoreL10n.format("- %@：`%@`", localizedReviewAction(for: file), file.repositoryPath)
      }
      .joined(separator: "\n")

    return [
      CoreL10n.text("## 发布内容"),
      CoreL10n.format("- 站点：%@", profile.name),
      CoreL10n.format("- 目标分支：%@", profile.branch.nilIfEmpty ?? "main"),
      CoreL10n.format("- 文章路径：`%@`", package.markdownPath),
      "",
      CoreL10n.text("## 文件"),
      files,
      "",
      CoreL10n.text("## 检查清单"),
      checklist,
    ].joined(separator: "\n")
  }

  private func localizedReviewTitle(for package: PublishPackage) -> String {
    if package.reviewTitle == "Publish \(package.title)" {
      return CoreL10n.format("发布 %@", package.title)
    }
    if package.reviewTitle == "Delete \(package.title)" {
      return CoreL10n.format("删除 %@", package.title)
    }
    return package.reviewTitle
  }

  private func localizedReviewAction(for file: PublishPackageFile) -> String {
    if file.operation == .delete {
      return CoreL10n.text("删除")
    }
    switch file.kind {
    case .markdown:
      return "Markdown"
    case .image:
      return CoreL10n.text("图片")
    case .video:
      return CoreL10n.text("视频")
    }
  }

  private func localizedChecklistItem(_ item: String) -> String {
    switch item {
    case "Front Matter 已检查":
      return CoreL10n.text("Front Matter 已检查")
    case "图片、视频路径和 alt/caption 已检查":
      return CoreL10n.text("图片、视频路径和 alt/caption 已检查")
    case "图片路径和 alt/caption 已检查":
      return CoreL10n.text("图片路径和 alt/caption 已检查")
    case "本地预览已确认":
      return CoreL10n.text("本地预览已确认")
    case "公开风险和私密内容已确认":
      return CoreL10n.text("公开风险和私密内容已确认")
    case "已确认文章仍在回收站或已永久删除":
      return CoreL10n.text("已确认文章仍在回收站或已永久删除")
    case "已核对待删除的仓库路径":
      return CoreL10n.text("已核对待删除的仓库路径")
    case "批量发布清单已确认":
      return CoreL10n.text("批量发布清单已确认")
    default:
      return item
    }
  }

  private func reviewWebURL(
    branchName: String,
    targetBranch: String,
    title: String,
    profile: SiteProfile,
    body: String
  ) -> URL? {
    return RepositoryReviewURLBuilder().buildURL(
      for: RepositoryReviewURLInput(
        provider: profile.repositoryProvider,
        repositoryBaseURL: profile.repositoryBaseURL,
        owner: profile.repoOwner,
        repositoryName: profile.repoName,
        sourceBranch: branchName,
        targetBranch: targetBranch,
        title: title,
        body: body
      )
    )
  }
}
