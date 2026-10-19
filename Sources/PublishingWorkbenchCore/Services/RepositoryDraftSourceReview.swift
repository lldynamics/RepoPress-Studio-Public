import Foundation
import PublishingCoreSupport
import RepoPressCore

/// Draft excludes generated pages, not the source files in a Git publication.
enum RepositoryDraftSourceReview {
  static func validatedReport(
    snapshot: RepositoryWorktreePublishSnapshot, profile: SiteProfile,
    analyzer: RepositoryPublishSafetyAnalyzer
  ) throws -> RepositoryPublishSafetyReport {
    let report = RepositoryPublishSafetyReport(
      diagnostics:
        analyzer.analyze(snapshot: snapshot, profile: profile).diagnostics
        + (try diagnostics(snapshot: snapshot)))
    guard report.canPublish else { throw RepositoryPublishSafetyError.blocked(report.blockers) }
    return report
  }

  static func diagnostics(
    snapshot: RepositoryWorktreePublishSnapshot
  ) throws -> [RepositoryPublishSafetyDiagnostic] {
    let root = URL(fileURLWithPath: snapshot.repositoryRoot, isDirectory: true)
    var paths: [String] = []
    for entry in snapshot.entries where entry.kind != .deleted {
      guard
        ["md", "markdown", "mdx"].contains(
          URL(fileURLWithPath: entry.path).pathExtension.lowercased())
      else { continue }
      let data = try BoundedFileReader.data(
        relativePath: entry.path, under: root, maximumByteCount: 100 * 1_024 * 1_024)
      guard let source = String(data: data, encoding: .utf8),
        let metadata = ImportedFrontMatter.split(source).frontMatter,
        metadata.value(for: "draft")?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
      else { continue }
      paths.append(entry.path)
    }
    guard !paths.isEmpty else { return [] }
    return [
      .init(
        code: .draftSourcePublication, severity: .warning,
        title: CoreL10n.text("草稿源码将上传到仓库"),
        message: CoreL10n.text("草稿不会生成网站页面，但本次会上传它的源码；公开仓库中的源码可被他人查看。请确认这些内容适合公开。"),
        paths: paths)
    ]
  }
}
