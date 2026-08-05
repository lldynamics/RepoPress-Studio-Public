import Foundation


public enum RepositoryChangeKind: String, Codable, Sendable {
  case added
  case modified
  case deleted
  case renamed
  case untracked
  case other

  public var displayName: String {
    switch self {
    case .added:
      return "新增"
    case .modified:
      return "修改"
    case .deleted:
      return "删除"
    case .renamed:
      return "重命名"
    case .untracked:
      return "未跟踪"
    case .other:
      return "其他"
    }
  }
}
public struct RepositoryChangedFile: Identifiable, Codable, Hashable, Sendable {
  public var id: String { status + path }
  public var status: String
  public var path: String
  public var kind: RepositoryChangeKind
  public var lineDiff: String?

  public init(
    status: String,
    path: String,
    kind: RepositoryChangeKind,
    lineDiff: String? = nil
  ) {
    self.status = status
    self.path = path
    self.kind = kind
    self.lineDiff = lineDiff
  }

  public var displayPath: String {
    path.components(separatedBy: " -> ").last?.trimmedForPublishing ?? path.trimmedForPublishing
  }
}

public struct RepositoryFileSnapshot: Codable, Hashable, Sendable {
  public var refName: String
  public var repositoryPath: String
  public var repositorySHA: String?
  public var content: String

  public init(
    refName: String,
    repositoryPath: String,
    content: String,
    repositorySHA: String? = nil
  ) {
    self.refName = refName
    self.repositoryPath = repositoryPath
    self.content = content
    self.repositorySHA = repositorySHA
  }
}

public enum RepositoryFetchStatus: String, Codable, Hashable, Sendable {
  case succeeded
  case skipped
  case failed
}

public struct RepositoryFetchResult: Codable, Hashable, Sendable {
  public var status: RepositoryFetchStatus
  public var remoteName: String?
  public var upstreamName: String?
  public var message: String

  public init(
    status: RepositoryFetchStatus,
    remoteName: String?,
    upstreamName: String?,
    message: String
  ) {
    self.status = status
    self.remoteName = remoteName
    self.upstreamName = upstreamName
    self.message = message
  }
}

public enum RepositoryChangedFileRole: String, Codable, CaseIterable, Sendable {
  case article
  case image
  case configuration
  case other

  public var displayName: String {
    switch self {
    case .article:
      return "文章"
    case .image:
      return "图片"
    case .configuration:
      return "配置"
    case .other:
      return "其他"
    }
  }

  public var queueTitle: String {
    switch self {
    case .article:
      return "文章变更"
    case .image:
      return "图片变更"
    case .configuration:
      return "配置变更"
    case .other:
      return "其他变更"
    }
  }

  public var systemImage: String {
    switch self {
    case .article:
      return "doc.text"
    case .image:
      return "photo"
    case .configuration:
      return "gearshape"
    case .other:
      return "ellipsis.circle"
    }
  }

  public var isPublishRelevant: Bool {
    switch self {
    case .article, .image, .configuration:
      return true
    case .other:
      return false
    }
  }
}

public struct RepositoryChangeQueueSection: Identifiable, Codable, Hashable, Sendable {
  public var id: String { role.rawValue }
  public var role: RepositoryChangedFileRole
  public var files: [RepositoryChangedFile]

  public init(role: RepositoryChangedFileRole, files: [RepositoryChangedFile]) {
    self.role = role
    self.files = files
  }

  public var title: String {
    role.queueTitle
  }

  public var subtitle: String {
    role.isPublishRelevant ? "会影响发布输出" : "不直接影响文章发布"
  }

  public var count: Int {
    files.count
  }
}

public struct RepositoryChangeSummary: Codable, Hashable, Sendable {
  public var articleCount: Int
  public var imageCount: Int
  public var configurationCount: Int
  public var otherCount: Int

  public init(
    articleCount: Int,
    imageCount: Int,
    configurationCount: Int,
    otherCount: Int
  ) {
    self.articleCount = articleCount
    self.imageCount = imageCount
    self.configurationCount = configurationCount
    self.otherCount = otherCount
  }

  public var totalCount: Int {
    articleCount + imageCount + configurationCount + otherCount
  }

  public var publishRelevantCount: Int {
    articleCount + imageCount + configurationCount
  }

  public func count(for role: RepositoryChangedFileRole) -> Int {
    switch role {
    case .article:
      return articleCount
    case .image:
      return imageCount
    case .configuration:
      return configurationCount
    case .other:
      return otherCount
    }
  }
}

public struct RepositoryBranchStatus: Codable, Hashable, Sendable {
  public var branchName: String?
  public var upstreamName: String?
  public var aheadCount: Int
  public var behindCount: Int
  public var isDetached: Bool

  public init(
    branchName: String?,
    upstreamName: String?,
    aheadCount: Int = 0,
    behindCount: Int = 0,
    isDetached: Bool = false
  ) {
    self.branchName = branchName
    self.upstreamName = upstreamName
    self.aheadCount = aheadCount
    self.behindCount = behindCount
    self.isDetached = isDetached
  }

  public var displayName: String {
    if isDetached {
      return "Detached HEAD"
    }
    return branchName ?? "未识别分支"
  }

  public var syncStatusTitle: String {
    if upstreamName == nil {
      return "未设置上游分支"
    }
    if aheadCount == 0 && behindCount == 0 {
      return "已与远端同步"
    }
    if aheadCount > 0 && behindCount > 0 {
      return "本地领先 \(aheadCount)，落后 \(behindCount)"
    }
    if aheadCount > 0 {
      return "本地领先 \(aheadCount)"
    }
    return "落后远端 \(behindCount)"
  }
}

public struct RepositoryBranch: Identifiable, Codable, Hashable, Sendable {
  public var id: String { name }
  public var name: String
  public var isCurrent: Bool
  public var upstreamName: String?

  public init(name: String, isCurrent: Bool = false, upstreamName: String? = nil) {
    self.name = name
    self.isCurrent = isCurrent
    self.upstreamName = upstreamName
  }
}

public struct RepositoryCommitInfo: Identifiable, Codable, Hashable, Sendable {
  public var id: String { sha }
  public var sha: String
  public var shortSHA: String
  public var author: String
  public var date: Date
  public var message: String

  public init(sha: String, shortSHA: String, author: String, date: Date, message: String) {
    self.sha = sha
    self.shortSHA = shortSHA
    self.author = author
    self.date = date
    self.message = message
  }
}

public enum LocalRepositoryServiceError: Error, LocalizedError, Sendable {
  case repositoryUnavailable
  case invalidBranchName
  case workingTreeHasChanges
  case commandFailed(terminated: Int32, output: String)

  public var errorDescription: String? {
    switch self {
    case .repositoryUnavailable:
      return "未找到可用的本地仓库路径。"
    case .invalidBranchName:
      return "分支名无效。"
    case .workingTreeHasChanges:
      return "工作区存在未提交变更。请先提交、暂存处理或还原这些变更，再切换分支。"
    case .commandFailed(let terminated, let output):
      let normalizedOutput = output.isEmpty ? "请检查分支与权限设置。" : output
      return "Git 命令执行失败（退出码：\(terminated)）：\(normalizedOutput)"
    }
  }
}

public struct RepositoryRemote: Codable, Hashable, Sendable {
  public var remoteURL: String
  public var provider: RepositoryProvider
  public var repositoryBaseURL: String
  public var owner: String
  public var name: String

  public init(
    remoteURL: String,
    provider: RepositoryProvider,
    repositoryBaseURL: String,
    owner: String,
    name: String
  ) {
    self.remoteURL = remoteURL
    self.provider = provider
    self.repositoryBaseURL = repositoryBaseURL
    self.owner = owner
    self.name = name
  }

  public var displayName: String {
    "\(provider.displayName) \(owner)/\(name)"
  }
}
