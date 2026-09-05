import Foundation

/// Section documents are not articles. Keep this guard at mutation boundaries,
/// not only at import: older snapshots may already contain a section as a draft.
public enum StructuralArticlePathPolicy {
  public static func isProtected(_ path: String, profile: SiteProfile) -> Bool {
    guard profile.siteKind == .zola || profile.siteKind == .hugo else { return false }
    return isSectionFile(path)
  }

  static func isSectionFile(_ path: String) -> Bool {
    let name = (path.normalizedRelativePath() as NSString).lastPathComponent.lowercased()
    return ["_index.md", "_index.markdown", "_index.mdx"].contains(name)
  }

  public static func protectedPath(for draft: ArticleDraft, profile: SiteProfile) -> String? {
    guard !draft.isGeneralDraft else { return nil }
    return [
      draft.repositoryPath, draft.repositoryBinding?.repositoryPath,
      profile.markdownPath(for: draft),
    ].compactMap { $0 }.first { isProtected($0, profile: profile) }
  }

  static func validate(package: PublishPackage, profile: SiteProfile) throws {
    for path in [package.markdownPath] + package.files.map(\.repositoryPath) {
      if isProtected(path, profile: profile) {
        throw StructuralArticlePathError.protectedPath(path)
      }
    }
  }

  static func issue(path: String) -> PreflightIssue {
    PreflightIssue(
      severity: .error,
      title: CoreL10n.text("栏目结构页不能作为文章写入"),
      message: CoreL10n.format("%@ 是站点结构页。请在内容健康中使用“检查遗留记录”，保留内容并解除错误绑定。", path),
      field: "repositoryPath"
    )
  }
}

public enum StructuralArticlePathError: LocalizedError, Equatable {
  case protectedPath(String)

  public var errorDescription: String? {
    switch self {
    case .protectedPath(let path):
      return StructuralArticlePathPolicy.issue(path: path).message
    }
  }
}
