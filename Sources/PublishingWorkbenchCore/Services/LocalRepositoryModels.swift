import Foundation
import PublishingGitCore

public extension RepositoryChangeKind {
  var displayName: String {
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

public extension RepositoryBranchStatus {
  var displayName: String {
    if isDetached {
      return "Detached HEAD"
    }
    return branchName ?? "未识别分支"
  }

  var syncStatusTitle: String {
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
