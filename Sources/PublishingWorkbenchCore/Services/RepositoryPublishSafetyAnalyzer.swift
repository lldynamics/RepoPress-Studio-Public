import Foundation

public struct RepositoryPublishSafetyAnalyzer: Sendable {
  private static let massDeleteThreshold = 10
  private static let massContentRewriteThreshold = 25

  public init() {}

  public func analyze(
    snapshot: RepositoryWorktreePublishSnapshot,
    profile: SiteProfile
  ) -> RepositoryPublishSafetyReport {
    var diagnostics: [RepositoryPublishSafetyDiagnostic] = []

    let structuralDeletes = snapshot.entries.compactMap { entry -> String? in
      guard entry.kind == .deleted || entry.kind == .renamed || entry.kind == .typeChanged else {
        return nil
      }
      let removedPath = entry.sourcePath ?? entry.path
      return StructuralArticlePathPolicy.isProtected(removedPath, profile: profile)
        ? removedPath : nil
    }
    if !structuralDeletes.isEmpty {
      diagnostics.append(
        RepositoryPublishSafetyDiagnostic(
          code: .structuralDelete,
          severity: .blocker,
          title: CoreL10n.text("栏目结构页被删除或移走"),
          message: CoreL10n.text("_index 结构页不能通过普通整仓库发布删除，请使用专用结构维护流程。"),
          paths: structuralDeletes
        )
      )
    }

    let crossSectionMoves = snapshot.entries.compactMap { entry -> [String]? in
      guard entry.kind == .renamed,
        let sourcePath = entry.sourcePath,
        let sourceSection = topLevelContentSection(for: sourcePath, profile: profile),
        let destinationSection = topLevelContentSection(for: entry.path, profile: profile),
        sourceSection.caseInsensitiveCompare(destinationSection) != .orderedSame
      else {
        return nil
      }
      return [sourcePath, entry.path]
    }.flatMap { $0 }
    if !crossSectionMoves.isEmpty {
      diagnostics.append(
        RepositoryPublishSafetyDiagnostic(
          code: .crossSectionMove,
          severity: .blocker,
          title: CoreL10n.text("内容被移到不同栏目"),
          message: CoreL10n.text("检测到跨一级内容栏目的移动；这会改变公开 URL 和站点结构，已停止普通发布。"),
          paths: crossSectionMoves
        )
      )
    }

    let deletedPaths = snapshot.entries.filter { $0.kind == .deleted }.map(\.path)
    if deletedPaths.count >= Self.massDeleteThreshold {
      diagnostics.append(
        RepositoryPublishSafetyDiagnostic(
          code: .massDelete,
          severity: .blocker,
          title: CoreL10n.text("检测到批量删除"),
          message: CoreL10n.format(
            "一次发布将删除 %@ 个路径，请先在仓库工作台分类复核。",
            String(deletedPaths.count)
          ),
          paths: deletedPaths
        )
      )
    }

    let changedMarkdownPaths = snapshot.entries.flatMap { entry in
      [entry.sourcePath, entry.path].compactMap { $0 }
    }.filter { path in
      let lowercased = path.lowercased()
      return lowercased.hasSuffix(".md") || lowercased.hasSuffix(".markdown")
        || lowercased.hasSuffix(".mdx")
    }
    if Set(changedMarkdownPaths).count >= Self.massContentRewriteThreshold {
      diagnostics.append(
        RepositoryPublishSafetyDiagnostic(
          code: .massContentRewrite,
          severity: .warning,
          title: CoreL10n.text("检测到批量内容改写"),
          message: CoreL10n.format(
            "本次发布涉及 %@ 个 Markdown 路径，请重点核对 Front Matter 和删除范围。",
            String(Set(changedMarkdownPaths).count)
          ),
          paths: Array(Set(changedMarkdownPaths))
        )
      )
    }

    let guardPaths = snapshot.paths.filter(Self.isPublishGuardPath)
    let contentPaths = snapshot.paths.filter {
      topLevelContentSection(for: $0, profile: profile) != nil
    }
    if !guardPaths.isEmpty, !contentPaths.isEmpty {
      diagnostics.append(
        RepositoryPublishSafetyDiagnostic(
          code: .publishGuardChanged,
          severity: .warning,
          title: CoreL10n.text("内容与发布门禁同时变更"),
          message: CoreL10n.text("本次同时修改了内容与构建/质量门禁，请确认检查标准没有被为了通过发布而放宽。"),
          paths: guardPaths
        )
      )
    }

    return RepositoryPublishSafetyReport(diagnostics: diagnostics)
  }

  private func topLevelContentSection(for path: String, profile: SiteProfile) -> String? {
    let root = profile.contentRoot.normalizedRelativePath()
    let normalized = path.normalizedRelativePath()
    guard !root.isEmpty,
      normalized != root,
      normalized.hasPrefix(root + "/")
    else {
      return nil
    }
    return normalized.dropFirst(root.count + 1).split(separator: "/").first.map(String.init)
  }

  private static func isPublishGuardPath(_ path: String) -> Bool {
    let normalized = path.normalizedRelativePath().lowercased()
    if normalized.hasPrefix("scripts/") || normalized.hasPrefix("script/")
      || normalized.hasPrefix(".github/workflows/")
    {
      return true
    }
    let name = URL(fileURLWithPath: normalized).lastPathComponent
    return [
      "config.toml", "config.yaml", "config.yml", "package.json", "package-lock.json",
      "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb",
    ].contains(name) || normalized.contains("baseline")
  }
}
