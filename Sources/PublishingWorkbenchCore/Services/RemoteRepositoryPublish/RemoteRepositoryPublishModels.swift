import Foundation

public enum RemoteRepositoryPublishMode: String, Codable, Sendable {
  case directCommit
  case reviewRequest

  public var displayName: String {
    switch self {
    case .directCommit:
      return "线上直接提交"
    case .reviewRequest:
      return "线上 PR/MR"
    }
  }
}

public enum RemoteRepositoryPublishProgressStage: String, Codable, Sendable {
  case preparing
  case validatingTarget
  case creatingBranch
  case uploadingFiles
  case creatingReview
  case completed
  case failed

  public var displayName: String {
    switch self {
    case .preparing:
      return "准备"
    case .validatingTarget:
      return "校验"
    case .creatingBranch:
      return "分支"
    case .uploadingFiles:
      return "上传"
    case .creatingReview:
      return "提交评审"
    case .completed:
      return "完成"
    case .failed:
      return "失败"
    }
  }
}

public struct RemoteRepositoryPublishProgress: Codable, Hashable, Sendable {
  public var stage: RemoteRepositoryPublishProgressStage
  public var progress: Double?
  public var message: String
  public var detail: String?
  public var filePath: String?

  public init(
    stage: RemoteRepositoryPublishProgressStage,
    progress: Double? = nil,
    message: String,
    detail: String? = nil,
    filePath: String? = nil
  ) {
    self.stage = stage
    self.progress = progress
    self.message = message
    self.detail = detail
    self.filePath = filePath
  }
}

public struct RemoteRepositoryAccessCheck: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var repositoryName: String
  public var apiBaseURL: String?
  public var defaultBranch: String?
  public var canRead: Bool
  public var canWrite: Bool
  public var permissionSummary: String
  public var tokenScopeSummary: String?
  public var minimumWritePermission: String
  public var message: String

  public init(
    provider: RepositoryProvider,
    repositoryName: String,
    apiBaseURL: String? = nil,
    defaultBranch: String?,
    canRead: Bool,
    canWrite: Bool,
    permissionSummary: String? = nil,
    tokenScopeSummary: String? = nil,
    minimumWritePermission: String? = nil,
    message: String
  ) {
    self.provider = provider
    self.repositoryName = repositoryName
    self.apiBaseURL = apiBaseURL
    self.defaultBranch = defaultBranch
    self.canRead = canRead
    self.canWrite = canWrite
    self.permissionSummary = permissionSummary ?? (canWrite ? "已确认写入权限。" : "未确认写入权限。")
    self.tokenScopeSummary = tokenScopeSummary
    self.minimumWritePermission = minimumWritePermission ?? "需要仓库写入权限。"
    self.message = message
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case repositoryName
    case apiBaseURL
    case defaultBranch
    case canRead
    case canWrite
    case permissionSummary
    case tokenScopeSummary
    case minimumWritePermission
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(RepositoryProvider.self, forKey: .provider)
    repositoryName = try container.decode(String.self, forKey: .repositoryName)
    apiBaseURL = try container.decodeIfPresent(String.self, forKey: .apiBaseURL)
    defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
    canRead = try container.decodeIfPresent(Bool.self, forKey: .canRead) ?? false
    canWrite = try container.decodeIfPresent(Bool.self, forKey: .canWrite) ?? false
    permissionSummary = try container.decodeIfPresent(String.self, forKey: .permissionSummary)
      ?? (canWrite ? "已确认写入权限。" : "未确认写入权限。")
    tokenScopeSummary = try container.decodeIfPresent(String.self, forKey: .tokenScopeSummary)
    minimumWritePermission = try container.decodeIfPresent(String.self, forKey: .minimumWritePermission)
      ?? "需要仓库写入权限。"
    message = try container.decodeIfPresent(String.self, forKey: .message)
      ?? (canWrite ? "Token 具备写入权限。" : "Token 未确认写入权限。")
  }
}

public extension RemoteRepositoryAccessCheck {
  var accessEvidenceMarkdown: String {
    var lines: [String] = [
      "# \(provider.displayName) Token 权限证据包",
      "",
      "- 平台：\(provider.displayName)",
      "- 仓库：\(repositoryName)",
      "- 可读取：\(canRead ? "是" : "否")",
      "- 可写入：\(canWrite ? "是" : "否")",
      "- 权限来源：\(permissionSummary)",
      "- 最低写入要求：\(minimumWritePermission)",
      "- 结论：\(message)"
    ]

    if let apiBaseURL = apiBaseURL?.trimmedForPublishing.nilIfEmpty {
      lines.append("- API 端点：\(apiBaseURL)")
    }
    if let defaultBranch = defaultBranch?.trimmedForPublishing.nilIfEmpty {
      lines.append("- 默认分支：\(defaultBranch)")
    }
    if let tokenScopeSummary = tokenScopeSummary?.trimmedForPublishing.nilIfEmpty {
      lines.append("- Token scope：\(tokenScopeSummary)")
    }

    lines.append("")
    lines.append("## 发布前权限清单")
    lines.append("- [\(canRead ? "x" : " ")] Token 可以读取仓库元数据")
    lines.append("- [\(canWrite ? "x" : " ")] Token 满足线上直接提交或 PR/MR 所需写入权限")
    lines.append("- [\(repositoryName.trimmedForPublishing.isEmpty ? " " : "x")] 权限检查仓库与当前发布仓库一致")
    lines.append("- [ ] 使用最小权限 Token，未在截图、日志或证据包中暴露 Token 原文")

    lines.append("")
    lines.append("## API 校验命令")
    let commands = accessVerificationCommands
    if commands.isEmpty {
      lines.append("当前权限检查缺少仓库名，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。")
    } else {
      lines.append("```bash")
      lines.append(contentsOf: commands)
      lines.append("```")
    }

    return lines.joined(separator: "\n")
  }

  var accessVerificationCommands: [String] {
    guard let repositoryName = repositoryName.trimmedForPublishing.nilIfEmpty else {
      return []
    }

    switch provider {
    case .github:
      guard let base = secureVerificationAPIBaseURL(
        apiBaseURL,
        fallback: "https://api.github.com"
      ) else { return [] }
      let url = "\(base)/repos/\(encodedRepositoryPath(repositoryName, separator: "/"))"
      return [
        "curl -fsS -H \"Authorization: Bearer $GITHUB_TOKEN\" \(shellSingleQuoted(url))"
      ]

    case .gitlab:
      guard let base = secureVerificationAPIBaseURL(
        apiBaseURL,
        fallback: "https://gitlab.com/api/v4"
      ) else { return [] }
      let url = "\(base)/projects/\(encodedRepositoryPath(repositoryName, separator: "%2F"))"
      return [
        "curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" \(shellSingleQuoted(url))"
      ]
    }
  }

  private func encodedRepositoryPath(_ value: String, separator: String) -> String {
    value
      .split(separator: "/", omittingEmptySubsequences: false)
      .map { component in
        String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
      }
      .joined(separator: separator)
  }
}

public struct RemoteRepositoryCreationResult: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var repositoryName: String
  public var defaultBranch: String?
  public var sshURL: String?
  public var cloneURL: String?
  public var htmlURL: String?
  public var privateRepository: Bool

  public init(
    provider: RepositoryProvider,
    repositoryName: String,
    defaultBranch: String?,
    sshURL: String?,
    cloneURL: String?,
    htmlURL: String?,
    privateRepository: Bool
  ) {
    self.provider = provider
    self.repositoryName = repositoryName
    self.defaultBranch = defaultBranch
    self.sshURL = sshURL
    self.cloneURL = cloneURL
    self.htmlURL = htmlURL
    self.privateRepository = privateRepository
  }
}

public struct RemoteRepositoryPublishResult: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var repositoryName: String?
  public var apiBaseURL: String?
  public var mode: RemoteRepositoryPublishMode
  public var branchName: String
  public var targetBranch: String
  public var changedPaths: [String]
  public var commitSHA: String?
  public var remoteVersionsByPath: [String: String]?
  public var reviewURL: String?
  public var reviewTitle: String?

  public init(
    provider: RepositoryProvider,
    repositoryName: String? = nil,
    apiBaseURL: String? = nil,
    mode: RemoteRepositoryPublishMode,
    branchName: String,
    targetBranch: String,
    changedPaths: [String],
    commitSHA: String?,
    remoteVersionsByPath: [String: String]? = nil,
    reviewURL: String? = nil,
    reviewTitle: String? = nil
  ) {
    self.provider = provider
    self.repositoryName = repositoryName
    self.apiBaseURL = apiBaseURL
    self.mode = mode
    self.branchName = branchName
    self.targetBranch = targetBranch
    self.changedPaths = changedPaths
    self.commitSHA = commitSHA
    self.remoteVersionsByPath = remoteVersionsByPath
    self.reviewURL = reviewURL
    self.reviewTitle = reviewTitle
  }

  public func remoteVersion(for repositoryPath: String) -> String? {
    remoteVersionsByPath?[repositoryPath.normalizedRelativePath()]?.trimmedForPublishing.nilIfEmpty
  }
}

public struct RemoteRepositoryRollbackDraft: Codable, Hashable, Sendable {
  public var recordID: UUID
  public var title: String
  public var commitMessage: String
  public var targetBranch: String
  public var commitSHA: String
  public var changedPaths: [String]

  public init(
    recordID: UUID,
    title: String,
    commitMessage: String,
    targetBranch: String,
    commitSHA: String,
    changedPaths: [String]
  ) {
    self.recordID = recordID
    self.title = title
    self.commitMessage = commitMessage
    self.targetBranch = targetBranch
    self.commitSHA = commitSHA
    self.changedPaths = changedPaths
  }
}

public struct RemoteRepositoryRollbackResult: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var recordID: UUID
  public var targetBranch: String
  public var rolledBackCommitSHA: String
  public var rollbackCommitSHA: String
  public var changedPaths: [String]
  public var remoteURL: String?

  public init(
    provider: RepositoryProvider,
    recordID: UUID,
    targetBranch: String,
    rolledBackCommitSHA: String,
    rollbackCommitSHA: String,
    changedPaths: [String],
    remoteURL: String? = nil
  ) {
    self.provider = provider
    self.recordID = recordID
    self.targetBranch = targetBranch
    self.rolledBackCommitSHA = rolledBackCommitSHA
    self.rollbackCommitSHA = rollbackCommitSHA
    self.changedPaths = changedPaths
    self.remoteURL = remoteURL
  }

  public var shortRollbackCommitSHA: String {
    String(rollbackCommitSHA.prefix(8))
  }
}

public struct RemoteRepositoryReviewWithdrawalDraft: Codable, Hashable, Sendable {
  public var recordID: UUID
  public var title: String
  public var reviewURL: String
  public var reviewNumber: Int
  public var branchName: String?
  public var targetBranch: String?

  public init(
    recordID: UUID,
    title: String,
    reviewURL: String,
    reviewNumber: Int,
    branchName: String? = nil,
    targetBranch: String? = nil
  ) {
    self.recordID = recordID
    self.title = title
    self.reviewURL = reviewURL
    self.reviewNumber = reviewNumber
    self.branchName = branchName
    self.targetBranch = targetBranch
  }
}

public struct RemoteRepositoryReviewWithdrawalResult: Codable, Hashable, Sendable {
  public var provider: RepositoryProvider
  public var recordID: UUID
  public var reviewURL: String
  public var reviewNumber: Int
  public var state: String
  public var branchName: String?
  public var targetBranch: String?

  public init(
    provider: RepositoryProvider,
    recordID: UUID,
    reviewURL: String,
    reviewNumber: Int,
    state: String,
    branchName: String? = nil,
    targetBranch: String? = nil
  ) {
    self.provider = provider
    self.recordID = recordID
    self.reviewURL = reviewURL
    self.reviewNumber = reviewNumber
    self.state = state
    self.branchName = branchName
    self.targetBranch = targetBranch
  }
}

public extension RemoteRepositoryPublishResult {
  var shortCommitSHA: String? {
    commitSHA.map { String($0.prefix(8)) }
  }

  var displayTitle: String {
    "\(provider.displayName) \(mode.displayName)"
  }

  var branchSummary: String {
    mode == .reviewRequest
      ? "\(branchName) -> \(targetBranch)"
      : targetBranch
  }

  var clipboardSummary: String {
    var lines = [
      "\(displayTitle)",
      "分支：\(branchSummary)",
      "文件：\(changedPaths.count)"
    ]
    if let repositoryName {
      lines.insert("仓库：\(repositoryName)", at: 1)
    }
    if let commitSHA {
      lines.append("Commit：\(commitSHA)")
    }
    if let reviewURL {
      lines.append("PR/MR：\(reviewURL)")
    }
    if let reviewTitle {
      lines.append("标题：\(reviewTitle)")
    }
    if !changedPaths.isEmpty {
      lines.append("")
      lines.append("变更文件：")
      lines.append(contentsOf: changedPaths.map { "- \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  var remoteVerificationMarkdown: String {
    var lines = [
      "# \(provider.displayName) 线上发布实测包",
      "",
      "- 发布方式：\(mode.displayName)",
      "- 分支：\(branchSummary)",
      "- 文件：\(changedPaths.count)"
    ]
    if let repositoryName = repositoryName?.trimmedForPublishing.nilIfEmpty {
      lines.append("- 仓库：\(repositoryName)")
    }
    if let commitSHA = commitSHA?.trimmedForPublishing.nilIfEmpty {
      lines.append("- Commit：\(commitSHA)")
    }
    if let reviewURL = reviewURL?.trimmedForPublishing.nilIfEmpty {
      lines.append("- PR/MR：\(reviewURL)")
    }
    if let reviewTitle = reviewTitle?.trimmedForPublishing.nilIfEmpty {
      lines.append("- 标题：\(reviewTitle)")
    }

    if !changedPaths.isEmpty {
      lines.append("")
      lines.append("## 文件清单")
      lines.append(contentsOf: changedPaths.map { "- \($0)" })
    }

    let commands = remoteVerificationCommands
    lines.append("")
    lines.append("## API 实测命令")
    if commands.isEmpty {
      lines.append("当前结果缺少仓库名或 commit，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。")
    } else {
      lines.append("```bash")
      lines.append(contentsOf: commands)
      lines.append("```")
    }

    lines.append("")
    lines.append("## 发布后核对")
    lines.append("- [ ] 远端 commit 或 PR/MR 可打开。")
    lines.append("- [ ] 变更文件都在目标分支或 Review 分支。")
    lines.append("- [ ] 部署状态面板已刷新到最新记录。")
    lines.append("- [ ] 文章页面、Open Graph 和 Twitter 卡片已完成发布后检查。")

    return lines.joined(separator: "\n")
  }

  var remoteVerificationCommands: [String] {
    guard let repositoryName = repositoryName?.trimmedForPublishing.nilIfEmpty else {
      return []
    }

    let ref = mode == .reviewRequest ? branchName : targetBranch
    switch provider {
    case .github:
      guard let base = secureVerificationAPIBaseURL(
        apiBaseURL,
        fallback: "https://api.github.com"
      ) else { return [] }
      var commands: [String] = []
      if let commitSHA = commitSHA?.trimmedForPublishing.nilIfEmpty {
        commands.append("curl -fsS -H \"Authorization: Bearer $GITHUB_TOKEN\" \(shellSingleQuoted("\(base)/repos/\(repositoryName)/commits/\(commitSHA)"))")
      }
      if let reviewNumber = reviewNumber(from: reviewURL) {
        commands.append("curl -fsS -H \"Authorization: Bearer $GITHUB_TOKEN\" \(shellSingleQuoted("\(base)/repos/\(repositoryName)/pulls/\(reviewNumber)"))")
      }
      commands.append(contentsOf: changedPaths.prefix(6).map { path in
        let url = "\(base)/repos/\(repositoryName)/contents/\(encodedVerificationRepositoryPath(path))?ref=\(encodedVerificationPath(ref))"
        return "curl -fsS -H \"Authorization: Bearer $GITHUB_TOKEN\" \(shellSingleQuoted(url))"
      })
      return commands

    case .gitlab:
      guard let base = secureVerificationAPIBaseURL(
        apiBaseURL,
        fallback: "https://gitlab.com/api/v4"
      ) else { return [] }
      let project = encodedVerificationPath(repositoryName)
      var commands: [String] = []
      if let commitSHA = commitSHA?.trimmedForPublishing.nilIfEmpty {
        commands.append("curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" \(shellSingleQuoted("\(base)/projects/\(project)/repository/commits/\(encodedVerificationPath(commitSHA))"))")
      }
      if let reviewNumber = reviewNumber(from: reviewURL) {
        commands.append("curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" \(shellSingleQuoted("\(base)/projects/\(project)/merge_requests/\(reviewNumber)"))")
      }
      commands.append(contentsOf: changedPaths.prefix(6).map { path in
        let url = "\(base)/projects/\(project)/repository/files/\(encodedVerificationPath(path))?ref=\(encodedVerificationPath(ref))"
        return "curl -fsS --header \"PRIVATE-TOKEN: $GITLAB_TOKEN\" \(shellSingleQuoted(url))"
      })
      return commands
    }
  }

  private func reviewNumber(from urlText: String?) -> Int? {
    guard let urlText = urlText?.trimmedForPublishing.nilIfEmpty,
          let url = URL(string: urlText) else {
      return nil
    }
    let components = url.pathComponents
    if let pullIndex = components.firstIndex(of: "pull"),
       components.indices.contains(components.index(after: pullIndex)),
       let number = Int(components[components.index(after: pullIndex)]) {
      return number
    }
    if let mrIndex = components.firstIndex(of: "merge_requests"),
       components.indices.contains(components.index(after: mrIndex)),
       let number = Int(components[components.index(after: mrIndex)]) {
      return number
    }
    return nil
  }

  private func encodedVerificationPath(_ value: String) -> String {
    value
      .split(separator: "/", omittingEmptySubsequences: false)
      .map { component in
        String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
      }
      .joined(separator: "%2F")
  }

  private func encodedVerificationRepositoryPath(_ value: String) -> String {
    value
      .split(separator: "/", omittingEmptySubsequences: false)
      .map { component in
        String(component).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(component)
      }
      .joined(separator: "/")
  }
}

private func secureVerificationAPIBaseURL(_ candidate: String?, fallback: String) -> String? {
  let text = candidate?.trimmedForPublishing.nilIfEmpty ?? fallback
  guard let url = URL(string: text),
        CredentialedEndpointPolicy.isSecureAPIBaseURL(url) else {
    return nil
  }
  return url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

private func shellSingleQuoted(_ value: String) -> String {
  "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

public extension RemoteRepositoryRollbackDraft {
  static func make(record: ReleaseRecord) throws -> RemoteRepositoryRollbackDraft {
    guard let commitSHA = record.commitSHA?.trimmedForPublishing.nilIfEmpty else {
      throw RemoteRepositoryPublishError.missingRollbackCommit
    }
    let targetBranch = record.targetBranch?.nilIfEmpty
      ?? record.branchName?.nilIfEmpty
      ?? "main"
    let displayTitle = record.draftTitle ?? record.title
    return RemoteRepositoryRollbackDraft(
      recordID: record.id,
      title: "回滚：\(displayTitle)",
      commitMessage: "Rollback: \(displayTitle)",
      targetBranch: targetBranch,
      commitSHA: commitSHA,
      changedPaths: record.changedPaths
    )
  }
}

public extension RemoteRepositoryReviewWithdrawalDraft {
  static func make(record: ReleaseRecord) throws -> RemoteRepositoryReviewWithdrawalDraft {
    guard let reviewURL = record.reviewURL?.trimmedForPublishing.nilIfEmpty else {
      throw RemoteRepositoryPublishError.missingReviewURL
    }
    guard let reviewNumber = Self.reviewNumber(from: reviewURL) else {
      throw RemoteRepositoryPublishError.invalidReviewURL(reviewURL)
    }
    return RemoteRepositoryReviewWithdrawalDraft(
      recordID: record.id,
      title: "撤回 Review：\(record.draftTitle ?? record.title)",
      reviewURL: reviewURL,
      reviewNumber: reviewNumber,
      branchName: record.branchName?.nilIfEmpty,
      targetBranch: record.targetBranch?.nilIfEmpty
    )
  }

  private static func reviewNumber(from reviewURL: String) -> Int? {
    guard let url = URL(string: reviewURL) else {
      return nil
    }
    let components = url.pathComponents
    if let pullIndex = components.firstIndex(of: "pull"),
       components.indices.contains(components.index(after: pullIndex)),
       let number = Int(components[components.index(after: pullIndex)]) {
      return number
    }
    if let mrIndex = components.firstIndex(of: "merge_requests"),
       components.indices.contains(components.index(after: mrIndex)),
       let number = Int(components[components.index(after: mrIndex)]) {
      return number
    }
    return nil
  }
}
