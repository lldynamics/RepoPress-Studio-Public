import Foundation

public enum RemoteRepositoryPublishReadiness: String, Codable, Sendable {
  case ready
  case needsToken
  case needsPermissionCheck
  case blocked

  public var displayName: String {
    switch self {
    case .ready:
      return "可线上发布"
    case .needsToken:
      return "缺少 Token"
    case .needsPermissionCheck:
      return "建议检查权限"
    case .blocked:
      return "已阻塞"
    }
  }

  public var systemImage: String {
    switch self {
    case .ready:
      return "checkmark.circle"
    case .needsToken:
      return "key"
    case .needsPermissionCheck:
      return "person.badge.key"
    case .blocked:
      return "xmark.octagon"
    }
  }
}

public struct RemoteRepositoryPublishPreview: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var repositoryName: String
  public var mode: RemoteRepositoryPublishMode
  public var branchName: String
  public var targetBranch: String
  public var changedPaths: [String]
  public var remoteConflictPaths: [String]
  public var hasToken: Bool
  public var accessCheck: RemoteRepositoryAccessCheck?
  public var blockingIssues: [PreflightIssue]
  public var warningIssues: [PreflightIssue]

  public init(
    provider: RepositoryProvider,
    repositoryName: String,
    mode: RemoteRepositoryPublishMode,
    branchName: String,
    targetBranch: String,
    changedPaths: [String],
    remoteConflictPaths: [String] = [],
    hasToken: Bool,
    accessCheck: RemoteRepositoryAccessCheck? = nil,
    blockingIssues: [PreflightIssue],
    warningIssues: [PreflightIssue]
  ) {
    self.provider = provider
    self.repositoryName = repositoryName
    self.mode = mode
    self.branchName = branchName
    self.targetBranch = targetBranch
    self.changedPaths = changedPaths
    self.remoteConflictPaths = remoteConflictPaths
    self.hasToken = hasToken
    self.accessCheck = accessCheck
    self.blockingIssues = blockingIssues
    self.warningIssues = warningIssues
  }

  public var readiness: RemoteRepositoryPublishReadiness {
    if !blockingIssues.isEmpty {
      return .blocked
    }
    if !hasToken {
      return .needsToken
    }
    if accessCheck == nil {
      return .needsPermissionCheck
    }
    if accessCheck?.canWrite != true {
      return .blocked
    }
    return .ready
  }

  public var canPublish: Bool {
    blockingIssues.isEmpty
      && hasToken
      && accessCheck?.canWrite == true
  }

  public var accessSummary: String {
    guard hasToken else {
      return "未保存 Token"
    }
    guard let accessCheck else {
      return "Token 已保存，尚未检查权限"
    }
    if accessCheck.canWrite {
      return "Token 可写"
    }
    if accessCheck.canRead {
      return "Token 可读但未确认写入"
    }
    return "Token 权限不足"
  }

  public var checklistMarkdown: String {
    var lines = [
      "# GitHub/GitLab 线上发布核对包",
      "",
      "- 平台：\(provider.displayName)",
      "- 仓库：\(repositoryName)",
      "- 发布模式：\(mode.displayName)",
      "- 发布分支：\(branchName)",
      "- 目标分支：\(targetBranch)",
      "- 状态：\(readiness.displayName)",
      "- Token：\(hasToken ? "已保存" : "未保存")",
      "- 权限：\(accessSummary)",
    ]

    if let accessCheck {
      lines.append("- 权限检查仓库：\(accessCheck.repositoryName)")
      if let apiBaseURL = accessCheck.apiBaseURL?.nilIfEmpty {
        lines.append("- 权限检查端点：\(apiBaseURL)")
      }
      if let defaultBranch = accessCheck.defaultBranch?.nilIfEmpty {
        lines.append("- 默认分支：\(defaultBranch)")
      }
      lines.append("- 最低写入要求：\(accessCheck.minimumWritePermission)")
      lines.append("- 权限来源：\(accessCheck.permissionSummary)")
      if let tokenScopeSummary = accessCheck.tokenScopeSummary?.nilIfEmpty {
        lines.append("- Token scope：\(tokenScopeSummary)")
      }
      lines.append("- 权限检查结论：\(accessCheck.message)")
    } else {
      lines.append("- 权限检查结论：尚未完成当前仓库的写入权限检查")
    }

    lines.append("")
    lines.append("## 发布前检查")
    lines.append("- [\(hasToken ? "x" : " ")] 已保存 \(provider.displayName) Token")
    lines.append("- [\(accessCheck?.canWrite == true ? "x" : " ")] 已确认 Token 对 \(repositoryName) 具备写入权限")
    lines.append("- [\(blockingIssues.isEmpty ? "x" : " ")] 没有阻断项")
    lines.append("- [\(warningIssues.isEmpty ? "x" : " ")] 已审阅警告项")
    lines.append("- [\(changedPaths.isEmpty ? " " : "x")] 已确认发布文件清单")
    lines.append("- [\(remoteConflictPaths.isEmpty ? "x" : " ")] 已确认远端同路径变更")

    if !changedPaths.isEmpty {
      lines.append("")
      lines.append("## 文件清单")
      lines.append(contentsOf: changedPaths.map { "- \($0)" })
    }

    if !remoteConflictPaths.isEmpty {
      lines.append("")
      lines.append("## 远端冲突预览")
      lines.append("这些路径在 upstream 也有变更。直接提交会被阻断；如需继续，请先同步远端或改用 PR/MR。")
      lines.append(contentsOf: remoteConflictPaths.map { "- \($0)" })
    }

    let issues = blockingIssues + warningIssues
    if !issues.isEmpty {
      lines.append("")
      lines.append("## 阻断和警告")
      lines.append(contentsOf: issues.map { issue in
        "- [\(issue.severity.displayName)] \(issue.title)：\(issue.message)"
      })
    }

    return lines.joined(separator: "\n")
  }
}
