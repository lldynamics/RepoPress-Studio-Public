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
