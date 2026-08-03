import Foundation

public enum RepositoryProvider: String, Codable, CaseIterable, Identifiable, Sendable {
  case github
  case gitlab

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .github:
      return "GitHub"
    case .gitlab:
      return "GitLab"
    }
  }

  public var defaultBaseURL: String {
    switch self {
    case .github:
      return "https://api.github.com"
    case .gitlab:
      return "https://gitlab.com"
    }
  }

  public var ownerFieldLabel: String {
    switch self {
    case .github:
      return "Owner"
    case .gitlab:
      return "Namespace / Group"
    }
  }

  public var repositoryFieldLabel: String {
    switch self {
    case .github:
      return "Repo"
    case .gitlab:
      return "Project"
    }
  }
}

public enum RepositoryPublishStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
  case direct
  case reviewRequest

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .direct:
      return "直接提交"
    case .reviewRequest:
      return "分支 + PR/MR"
    }
  }

  public var detail: String {
    switch self {
    case .direct:
      return "日常文章直接提交到目标分支。"
    case .reviewRequest:
      return "重要文章先创建发布分支，再打开 PR 或 MR。"
    }
  }
}

public enum SiteProfilePurpose: String, Codable, CaseIterable, Identifiable, Sendable {
  case publishing
  case repositoryBackup
  case generalDraftBackup

  public var id: String { rawValue }

  public var displayName: String {
    switch self {
    case .publishing:
      return "连接仓库并发布"
    case .repositoryBackup:
      return "连接仓库备份"
    case .generalDraftBackup:
      return "素材库"
    }
  }

  public var detail: String {
    switch self {
    case .publishing:
      return "用于真实站点发布，检查本地仓库、站点类型、内容目录、图片目录和 Git 同步状态。"
    case .repositoryBackup:
      return "用于把草稿写入本地仓库，保留 Git 安全检查，但不要求仓库必须是可部署静态站点。"
    case .generalDraftBackup:
      return "用于沉淀跨文章、跨站点复用素材，不要求连接仓库或通过部署检查。"
    }
  }

  public var systemImage: String {
    switch self {
    case .publishing:
      return "globe"
    case .repositoryBackup:
      return "externaldrive"
    case .generalDraftBackup:
      return "doc.text"
    }
  }

  public var requiresRepositoryReadiness: Bool {
    self != .generalDraftBackup
  }

  public var requiresDeploymentReadiness: Bool {
    self == .publishing
  }

  public var repositoryRootMissingMessage: String {
    switch self {
    case .publishing:
      return CoreL10n.text("Mac 版发布链路建议先选择真实站点仓库。")
    case .repositoryBackup:
      return CoreL10n.text("仓库备份 Profile 需要先选择本地仓库。")
    case .generalDraftBackup:
      return CoreL10n.text("素材库不要求连接本地仓库。")
    }
  }

  public var repositoryStatusWhenUnconfigured: String {
    switch self {
    case .publishing:
      return "未选择本地仓库"
    case .repositoryBackup:
      return "待选择备份仓库"
    case .generalDraftBackup:
      return "素材库模式"
    }
  }
}
