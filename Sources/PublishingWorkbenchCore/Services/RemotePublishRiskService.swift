import Foundation

public enum RemotePublishRiskState: String, Codable, Hashable, Sendable {
  case unknown
  case clean
  case conflict

  public var displayName: String {
    switch self {
    case .unknown:
      return CoreL10n.text("待核对远端")
    case .clean:
      return CoreL10n.text("未发现同路径冲突")
    case .conflict:
      return CoreL10n.text("发现同路径冲突")
    }
  }
}

public struct RemotePublishRiskAssessment: Codable, Hashable, Sendable {
  public var state: RemotePublishRiskState
  public var conflictPaths: [String]

  public init(state: RemotePublishRiskState, conflictPaths: [String] = []) {
    self.state = state
    self.conflictPaths = conflictPaths
  }
}

public struct RemotePublishRiskService: Sendable {
  private let maximumReportAge: TimeInterval

  public init(maximumReportAge: TimeInterval = 5 * 60) {
    self.maximumReportAge = maximumReportAge
  }

  public func issues(
    package: PublishPackage,
    repositoryReport: RepositoryScanReport?,
    includeUnknownState: Bool = false,
    now: Date = Date()
  ) -> [PreflightIssue] {
    issues(
      for: assessment(
        package: package,
        repositoryReport: repositoryReport,
        now: now
      ),
      includeUnknownState: includeUnknownState
    )
  }

  public func assessment(
    package: PublishPackage,
    repositoryReport: RepositoryScanReport?,
    now: Date = Date()
  ) -> RemotePublishRiskAssessment {
    let overlappingPaths = remoteConflictPaths(
      package: package,
      repositoryReport: repositoryReport
    )

    if !overlappingPaths.isEmpty {
      return RemotePublishRiskAssessment(
        state: .conflict,
        conflictPaths: overlappingPaths
      )
    }

    guard let repositoryReport,
          repositoryReport.hasGitDirectory,
          repositoryReport.branchStatus?.upstreamName?.trimmedForPublishing.nilIfEmpty != nil,
          now.timeIntervalSince(repositoryReport.scannedAt) <= maximumReportAge else {
      return RemotePublishRiskAssessment(state: .unknown)
    }

    return RemotePublishRiskAssessment(state: .clean)
  }

  public func issues(
    for assessment: RemotePublishRiskAssessment,
    includeUnknownState: Bool = false
  ) -> [PreflightIssue] {
    switch assessment.state {
    case .unknown:
      guard includeUnknownState else { return [] }
      return [
        PreflightIssue(
          severity: .warning,
          title: CoreL10n.text("远端状态待确认"),
          message: CoreL10n.text("当前没有可用的最新 upstream 扫描结果。直接提交会在写入前通过远端 API 核对每个文件版本；PR/MR 可继续进入审阅流程。"),
          field: "repository"
        )
      ]
    case .clean:
      return []
    case .conflict:
      return [
        PreflightIssue(
          severity: .warning,
          title: CoreL10n.text("远端同路径变更"),
          message: CoreL10n.format(
            "上游也修改了 %@。写入或提交前建议先查看远端 diff、导入远端草稿或同步仓库。",
            Self.pathSummary(assessment.conflictPaths)
          ),
          field: "repository"
        )
      ]
    }
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
      let path = Self.normalizedRepositoryPath(changedFile.destinationPath)
      guard packagePaths.contains(path), seenPaths.insert(path).inserted else {
        return nil
      }
      return path
    }
  }

  private static func normalizedRepositoryPath(_ path: String) -> String {
    return path.trimmedForPublishing.normalizedRelativePath()
  }

  private static func pathSummary(_ paths: [String]) -> String {
    let visiblePaths = paths.prefix(3).joined(separator: "、")
    if paths.count > 3 {
      return CoreL10n.format("%@ 等 %d 个文件", visiblePaths, paths.count)
    }
    return visiblePaths
  }
}
