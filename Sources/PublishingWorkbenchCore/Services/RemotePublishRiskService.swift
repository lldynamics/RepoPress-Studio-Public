import Foundation

public struct RemotePublishRiskService: Sendable {
  public init() {}

  public func issues(
    package: PublishPackage,
    repositoryReport: RepositoryScanReport?
  ) -> [PreflightIssue] {
    let overlappingPaths = remoteConflictPaths(
      package: package,
      repositoryReport: repositoryReport
    )

    guard !overlappingPaths.isEmpty else {
      return []
    }

    return [
      PreflightIssue(
        severity: .warning,
        title: "远端同路径变更",
        message: "上游也修改了 \(Self.pathSummary(overlappingPaths))。写入或提交前建议先查看远端 diff、导入远端草稿或同步仓库。",
        field: "repository"
      )
    ]
  }

  public func remoteConflictPaths(
    package: PublishPackage,
    repositoryReport: RepositoryScanReport?
  ) -> [String] {
    guard let repositoryReport, !repositoryReport.remoteChangedFiles.isEmpty else {
      return []
    }

    let packagePaths = Set(
      package.files
        .map { Self.normalizedRepositoryPath($0.repositoryPath) }
        .filter { !$0.isEmpty }
    )
    guard !packagePaths.isEmpty else {
      return []
    }

    var seenPaths: Set<String> = []
    return repositoryReport.remoteChangedFiles.compactMap { changedFile -> String? in
      let path = Self.normalizedRepositoryPath(changedFile.displayPath)
      guard packagePaths.contains(path), seenPaths.insert(path).inserted else {
        return nil
      }
      return path
    }
  }

  private static func normalizedRepositoryPath(_ path: String) -> String {
    let displayPath = path.components(separatedBy: " -> ").last?.trimmedForPublishing ?? path.trimmedForPublishing
    return displayPath.normalizedRelativePath()
  }

  private static func pathSummary(_ paths: [String]) -> String {
    let visiblePaths = paths.prefix(3).joined(separator: "、")
    if paths.count > 3 {
      return "\(visiblePaths) 等 \(paths.count) 个文件"
    }
    return visiblePaths
  }
}
