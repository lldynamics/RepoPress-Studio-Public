import Foundation
import PublishingGitCore
import RepoPressCore

/// Reviews immutable outgoing blobs, including content removed by later commits.
enum RepositoryOutgoingPublicationReview {
  static func diagnostics(
    snapshot: RepositoryWorktreePublishSnapshot, profile: SiteProfile,
    git: GitCommandRunner, analyzer: RepositoryPublishSafetyAnalyzer
  ) throws -> [RepositoryPublishSafetyDiagnostic] {
    guard let history = snapshot.outgoingHistory else { return [] }
    var diagnostics: [RepositoryPublishSafetyDiagnostic] = []
    var drafts: Set<String> = []
    var checked: Set<String> = []
    let root = URL(fileURLWithPath: snapshot.repositoryRoot)
    let privateRoot = SiteProfile.privateContentRoot.normalizedRelativePath()
    for commit in history.commitReviews {
      let review = RepositoryWorktreePublishSnapshot(
        repositoryRoot: snapshot.repositoryRoot, gitCommonDirectory: snapshot.gitCommonDirectory,
        branch: snapshot.branch, headSHA: commit.commitSHA, originURL: snapshot.originURL,
        remoteBranchSHA: snapshot.remoteBranchSHA, statusFingerprint: commit.commitSHA,
        entries: commit.entries)
      diagnostics += analyzer.analyze(snapshot: review, profile: profile).diagnostics
      for entry in commit.entries where entry.kind != .deleted {
        if !privateRoot.isEmpty,
          entry.path == privateRoot || entry.path.hasPrefix(privateRoot + "/")
        {
          throw RepositoryWorktreePublishError.sensitivePaths([entry.path])
        }
        guard
          ["md", "markdown", "mdx"].contains(
            URL(fileURLWithPath: entry.path).pathExtension.lowercased()),
          let oid = entry.blobOID, checked.insert(entry.path + ":" + oid).inserted
        else { continue }
        let result = git.run(["cat-file", "blob", oid], rootURL: root)
        guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
          throw RepositoryWorktreePublishError.incompleteReview
        }
        guard let metadata = ImportedFrontMatter.split(result.standardOutput).frontMatter else {
          continue
        }
        if metadata.value(for: "private")?.lowercased() == "true"
          || metadata.value(for: "visibility")?.lowercased() == "private"
        {
          throw RepositoryWorktreePublishError.sensitivePaths([entry.path])
        }
        if metadata.value(for: "draft")?.lowercased() == "true" { drafts.insert(entry.path) }
      }
    }
    if !drafts.isEmpty {
      diagnostics.append(
        .init(
          code: .draftSourcePublication, severity: .warning,
          title: CoreL10n.text("草稿源码将上传到仓库"),
          message: CoreL10n.text("草稿不会生成网站页面，但本次会上传它的源码；公开仓库中的源码可被他人查看。请确认这些内容适合公开。"),
          paths: Array(drafts)))
    }
    return Array(Set(diagnostics)).sorted { $0.id < $1.id }
  }
}
