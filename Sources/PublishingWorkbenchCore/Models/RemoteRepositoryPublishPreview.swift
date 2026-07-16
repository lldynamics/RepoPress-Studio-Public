import Foundation

public enum RemoteRepositoryPublishReadiness: String, Codable, Sendable {
  case ready
  case needsToken
  case needsPermissionCheck
  case blocked

  public var displayName: String {
    switch self {
    case .ready:
      return CoreL10n.text("可线上发布")
    case .needsToken:
      return CoreL10n.text("缺少 Token")
    case .needsPermissionCheck:
      return CoreL10n.text("建议检查权限")
    case .blocked:
      return CoreL10n.text("已阻塞")
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
      return CoreL10n.text("未保存 Token")
    }
    guard let accessCheck else {
      return CoreL10n.text("Token 已保存，尚未检查权限")
    }
    if accessCheck.canWrite {
      return CoreL10n.text("Token 可写")
    }
    if accessCheck.canRead {
      return CoreL10n.text("Token 可读但未确认写入")
    }
    return CoreL10n.text("Token 权限不足")
  }

  public var checklistMarkdown: String {
    var lines = [
      CoreL10n.text("# GitHub/GitLab 线上发布核对包"),
      "",
      CoreL10n.format("- 平台：%@", provider.displayName),
      CoreL10n.format("- 仓库：%@", repositoryName),
      CoreL10n.format("- 发布模式：%@", mode.displayName),
      CoreL10n.format("- 发布分支：%@", branchName),
      CoreL10n.format("- 目标分支：%@", targetBranch),
      CoreL10n.format("- 状态：%@", readiness.displayName),
      CoreL10n.format("- Token：%@", CoreL10n.text(hasToken ? "已保存" : "未保存")),
      CoreL10n.format("- 权限：%@", accessSummary),
    ]

    if let accessCheck {
      lines.append(CoreL10n.format("- 权限检查仓库：%@", accessCheck.repositoryName))
      if let apiBaseURL = accessCheck.apiBaseURL?.nilIfEmpty {
        lines.append(CoreL10n.format("- 权限检查端点：%@", apiBaseURL))
      }
      if let defaultBranch = accessCheck.defaultBranch?.nilIfEmpty {
        lines.append(CoreL10n.format("- 默认分支：%@", defaultBranch))
      }
      lines.append(CoreL10n.format("- 最低写入要求：%@", accessCheck.minimumWritePermission))
      lines.append(CoreL10n.format("- 权限来源：%@", accessCheck.permissionSummary))
      if let tokenScopeSummary = accessCheck.tokenScopeSummary?.nilIfEmpty {
        lines.append(CoreL10n.format("- Token scope：%@", tokenScopeSummary))
      }
      lines.append(CoreL10n.format("- 权限检查结论：%@", accessCheck.message))
    } else {
      lines.append(CoreL10n.text("- 权限检查结论：尚未完成当前仓库的写入权限检查"))
    }

    lines.append("")
    lines.append(CoreL10n.text("## 发布前检查"))
    lines.append(CoreL10n.format("- [%@] 已保存 %@ Token", hasToken ? "x" : " ", provider.displayName))
    lines.append(CoreL10n.format("- [%@] 已确认 Token 对 %@ 具备写入权限", accessCheck?.canWrite == true ? "x" : " ", repositoryName))
    lines.append(CoreL10n.format("- [%@] 没有阻断项", blockingIssues.isEmpty ? "x" : " "))
    lines.append(CoreL10n.format("- [%@] 已审阅警告项", warningIssues.isEmpty ? "x" : " "))
    lines.append(CoreL10n.format("- [%@] 已确认发布文件清单", changedPaths.isEmpty ? " " : "x"))
    lines.append(CoreL10n.format("- [%@] 已确认远端同路径变更", remoteConflictPaths.isEmpty ? "x" : " "))

    if !changedPaths.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 文件清单"))
      lines.append(contentsOf: changedPaths.map { "- \($0)" })
    }

    if !remoteConflictPaths.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 远端冲突预览"))
      lines.append(CoreL10n.text("这些路径在 upstream 也有变更。直接提交会被阻断；如需继续，请先同步远端或改用 PR/MR。"))
      lines.append(contentsOf: remoteConflictPaths.map { "- \($0)" })
    }

    let issues = blockingIssues + warningIssues
    if !issues.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 阻断和警告"))
      lines.append(contentsOf: issues.map { issue in
        CoreL10n.format("- [%@] %@：%@", issue.severity.displayName, issue.title, issue.message)
      })
    }

    return lines.joined(separator: "\n")
  }
}
