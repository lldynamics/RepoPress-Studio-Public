import Foundation

public enum RemoteRepositoryPublishMode: String, Codable, Sendable {
  case directCommit
  case reviewRequest
  case previewBranch

  public var displayName: String {
    switch self {
    case .directCommit:
      return CoreL10n.text("线上直接提交")
    case .reviewRequest:
      return CoreL10n.text("线上 PR/MR")
    case .previewBranch:
      return CoreL10n.text("草稿预览分支")
    }
  }

  /// Whether this operation must write to a branch dedicated to the current
  /// package. Dedicated modes never mutate the configured target branch.
  public var usesDedicatedBranch: Bool {
    self == .reviewRequest || self == .previewBranch
  }

  /// Whether the operation creates or reuses a PR/MR after uploading files.
  public var createsReview: Bool {
    self == .reviewRequest
  }

  /// The completion boundary shown after the remote write has returned. A
  /// successful remote write is not the same thing as a merged or deployed
  /// release, so each mode states its remaining lifecycle explicitly.
  public var completedProgressMessage: String {
    switch self {
    case .directCommit:
      return CoreL10n.text("目标分支提交完成、部署待验证")
    case .reviewRequest:
      return CoreL10n.text("PR/MR 已创建、等待合并、尚未部署")
    case .previewBranch:
      return CoreL10n.text("预览分支已推送、不影响正式分支")
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
      return CoreL10n.text("准备")
    case .validatingTarget:
      return CoreL10n.text("校验")
    case .creatingBranch:
      return CoreL10n.text("分支")
    case .uploadingFiles:
      return CoreL10n.text("上传")
    case .creatingReview:
      return CoreL10n.text("提交评审")
    case .completed:
      return CoreL10n.text("完成")
    case .failed:
      return CoreL10n.text("失败")
    }
  }
}

public struct RemoteRepositoryPublishProgress: Codable, Hashable, Sendable {
  public var stage: RemoteRepositoryPublishProgressStage
  public var progress: Double?
  public var message: String
  public var detail: String?
  public var filePath: String?
  /// Bytes from the publish package that have completed processing. This is
  /// source-content progress, not a credential-bearing network payload size.
  public var completedByteCount: Int64?
  /// Total source-content bytes represented by the publish package.
  public var totalByteCount: Int64?

  public init(
    stage: RemoteRepositoryPublishProgressStage,
    progress: Double? = nil,
    message: String,
    detail: String? = nil,
    filePath: String? = nil,
    completedByteCount: Int64? = nil,
    totalByteCount: Int64? = nil
  ) {
    self.stage = stage
    self.progress = progress
    self.message = message
    self.detail = detail
    self.filePath = filePath
    self.completedByteCount = completedByteCount
    self.totalByteCount = totalByteCount
  }

  private enum CodingKeys: String, CodingKey {
    case stage
    case progress
    case message
    case detail
    case filePath
    case completedByteCount
    case totalByteCount
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    stage = try container.decode(RemoteRepositoryPublishProgressStage.self, forKey: .stage)
    progress = try container.decodeIfPresent(Double.self, forKey: .progress)
    message = try container.decode(String.self, forKey: .message)
    detail = try container.decodeIfPresent(String.self, forKey: .detail)
    filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
    completedByteCount = try container.decodeIfPresent(Int64.self, forKey: .completedByteCount)
    totalByteCount = try container.decodeIfPresent(Int64.self, forKey: .totalByteCount)
  }

  public var byteProgress: Double? {
    guard let completedByteCount,
          let totalByteCount,
          totalByteCount > 0 else {
      return nil
    }
    return min(1, max(0, Double(completedByteCount) / Double(totalByteCount)))
  }

  public var byteProgressDescription: String? {
    guard let byteProgress,
          let completedByteCount,
          let totalByteCount else {
      return nil
    }
    let percentage = Int((byteProgress * 100).rounded())
    return "\(Self.formatByteCount(completedByteCount)) / \(Self.formatByteCount(totalByteCount)) (\(percentage)%)"
  }

  public var statusDescription: String {
    [
      message.nilIfEmpty,
      detail?.nilIfEmpty,
      byteProgressDescription.map { CoreL10n.format("已上传 %@", $0) },
    ]
    .compactMap { $0 }
    .joined(separator: " · ")
  }

  private static func formatByteCount(_ byteCount: Int64) -> String {
    let value = Double(max(0, byteCount))
    let units = ["B", "KB", "MB", "GB", "TB"]
    guard value >= 1_000 else {
      return "\(max(0, byteCount)) B"
    }

    let exponent = min(
      units.count - 1,
      Int(log(value) / log(1_000))
    )
    let scaledValue = value / pow(1_000, Double(exponent))
    let format = scaledValue >= 100 ? "%.0f" : scaledValue >= 10 ? "%.1f" : "%.2f"
    let number = String(
      format: format,
      locale: Locale(identifier: "en_US_POSIX"),
      scaledValue
    )
    return "\(number) \(units[exponent])"
  }
}

public struct RemoteRepositoryAccessCheck: Codable, Hashable, Sendable {
  public static let maximumCacheAge: TimeInterval = 5 * 60

  public var provider: RepositoryProvider
  public var repositoryName: String
  public var apiBaseURL: String?
  public var defaultBranch: String?
  public var targetBranch: String?
  public var publishStrategy: RepositoryPublishStrategy?
  public var canRead: Bool
  public var canWrite: Bool
  public var permissionSummary: String
  public var tokenScopeSummary: String?
  public var minimumWritePermission: String
  public var message: String
  public var checkedAt: Date?

  public init(
    provider: RepositoryProvider,
    repositoryName: String,
    apiBaseURL: String? = nil,
    defaultBranch: String?,
    targetBranch: String? = nil,
    publishStrategy: RepositoryPublishStrategy? = nil,
    canRead: Bool,
    canWrite: Bool,
    permissionSummary: String? = nil,
    tokenScopeSummary: String? = nil,
    minimumWritePermission: String? = nil,
    message: String,
    checkedAt: Date = Date()
  ) {
    self.provider = provider
    self.repositoryName = repositoryName
    self.apiBaseURL = apiBaseURL
    self.defaultBranch = defaultBranch
    self.targetBranch = targetBranch
    self.publishStrategy = publishStrategy
    self.canRead = canRead
    self.canWrite = canWrite
    self.permissionSummary = permissionSummary ?? CoreL10n.text(canWrite ? "已确认写入权限。" : "未确认写入权限。")
    self.tokenScopeSummary = tokenScopeSummary
    self.minimumWritePermission = minimumWritePermission ?? CoreL10n.text("需要仓库写入权限。")
    self.message = message
    self.checkedAt = checkedAt
  }

  public func isFresh(
    at date: Date = Date(),
    maximumAge: TimeInterval = Self.maximumCacheAge
  ) -> Bool {
    guard let checkedAt else { return false }
    let age = date.timeIntervalSince(checkedAt)
    return age >= 0 && age <= maximumAge
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case repositoryName
    case apiBaseURL
    case defaultBranch
    case targetBranch
    case publishStrategy
    case canRead
    case canWrite
    case permissionSummary
    case tokenScopeSummary
    case minimumWritePermission
    case message
    case checkedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(RepositoryProvider.self, forKey: .provider)
    repositoryName = try container.decode(String.self, forKey: .repositoryName)
    apiBaseURL = try container.decodeIfPresent(String.self, forKey: .apiBaseURL)
    defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
    targetBranch = try container.decodeIfPresent(String.self, forKey: .targetBranch)
    publishStrategy = try container.decodeIfPresent(
      RepositoryPublishStrategy.self,
      forKey: .publishStrategy
    )
    canRead = try container.decodeIfPresent(Bool.self, forKey: .canRead) ?? false
    canWrite = try container.decodeIfPresent(Bool.self, forKey: .canWrite) ?? false
    permissionSummary = try container.decodeIfPresent(String.self, forKey: .permissionSummary)
      ?? CoreL10n.text(canWrite ? "已确认写入权限。" : "未确认写入权限。")
    tokenScopeSummary = try container.decodeIfPresent(String.self, forKey: .tokenScopeSummary)
    minimumWritePermission = try container.decodeIfPresent(String.self, forKey: .minimumWritePermission)
      ?? CoreL10n.text("需要仓库写入权限。")
    message = try container.decodeIfPresent(String.self, forKey: .message)
      ?? CoreL10n.text(canWrite ? "Token 具备写入权限。" : "Token 未确认写入权限。")
    checkedAt = try container.decodeIfPresent(Date.self, forKey: .checkedAt)
  }
}

public extension RemoteRepositoryAccessCheck {
  var accessEvidenceMarkdown: String {
    var lines: [String] = [
      CoreL10n.format("# %@ Token 权限证据包", provider.displayName),
      "",
      CoreL10n.format("- 平台：%@", provider.displayName),
      CoreL10n.format("- 仓库：%@", repositoryName),
      CoreL10n.format("- 可读取：%@", CoreL10n.text(canRead ? "是" : "否")),
      CoreL10n.format("- 可写入：%@", CoreL10n.text(canWrite ? "是" : "否")),
      CoreL10n.format("- 权限来源：%@", permissionSummary),
      CoreL10n.format("- 最低写入要求：%@", minimumWritePermission),
      CoreL10n.format("- 结论：%@", message)
    ]

    if let apiBaseURL = apiBaseURL?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- API 端点：%@", apiBaseURL))
    }
    if let defaultBranch = defaultBranch?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- 默认分支：%@", defaultBranch))
    }
    if let tokenScopeSummary = tokenScopeSummary?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- Token scope：%@", tokenScopeSummary))
    }

    lines.append("")
    lines.append(CoreL10n.text("## 发布前权限清单"))
    lines.append(CoreL10n.format("- [%@] Token 可以读取仓库元数据", canRead ? "x" : " "))
    lines.append(CoreL10n.format("- [%@] Token 满足内容写入所需权限", canWrite ? "x" : " "))
    if provider == .github {
      lines.append(CoreL10n.text("- [ ] PR 创建权限需在实际创建时验证"))
    }
    lines.append(CoreL10n.format("- [%@] 权限检查仓库与当前发布仓库一致", repositoryName.trimmedForPublishing.isEmpty ? " " : "x"))
    lines.append(CoreL10n.text("- [ ] 使用最小权限 Token，未在截图、日志或证据包中暴露 Token 原文"))

    lines.append("")
    lines.append(CoreL10n.text("## API 校验命令"))
    let commands = accessVerificationCommands
    if commands.isEmpty {
      lines.append(CoreL10n.text("当前权限检查缺少仓库名，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。"))
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
  /// Delete paths that still exist on the target branch and are waiting for
  /// the returned PR/MR to merge. An empty array proves that no requested
  /// deletion remains pending review. Nil preserves compatibility with
  /// results persisted before per-path review tracking was introduced.
  public var reviewPendingPaths: [String]?
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
    reviewPendingPaths: [String]? = nil,
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
    self.reviewPendingPaths = reviewPendingPaths
    self.reviewURL = reviewURL
    self.reviewTitle = reviewTitle
  }

  public func remoteVersion(for repositoryPath: String) -> String? {
    remoteVersionsByPath?[repositoryPath.normalizedRelativePath()]?.trimmedForPublishing.nilIfEmpty
  }

  /// Paths that were already present remotely and matched the upload payload,
  /// so the publish operation repaired the local baseline without writing a
  /// new remote commit for them.
  public var automaticallyAdoptedPaths: [String] {
    let changed = Set(changedPaths.map { $0.normalizedRelativePath() })
    let adopted = remoteVersionsByPath?.keys.map { $0.normalizedRelativePath() } ?? []
    return adopted
      .filter { !changed.contains($0) }
      .sorted()
  }

  /// Enforces the success contract at the boundary shared by both providers.
  /// Review mode must always retain a usable PR/MR URL; otherwise callers
  /// cannot recover or distinguish a completed review request from a plain
  /// branch write.
  public func validatedForSuccess() throws -> Self {
    guard mode == .reviewRequest else { return self }
    let reviewURLIsUsable: Bool = {
      guard let value = reviewURL?.trimmedForPublishing.nilIfEmpty,
        let url = URL(string: value),
        let scheme = url.scheme?.lowercased(),
        scheme == "https" || scheme == "http",
        url.host?.trimmedForPublishing.nilIfEmpty != nil
      else {
        return false
      }
      return true
    }()
    guard reviewURLIsUsable else {
      if !changedPaths.isEmpty || commitSHA?.trimmedForPublishing.nilIfEmpty != nil {
        throw RemoteRepositoryPublishError.partialPublish(
          provider: provider,
          mode: mode,
          branchName: branchName,
          targetBranch: targetBranch,
          changedPaths: changedPaths,
          commitSHA: commitSHA,
          underlyingMessage: CoreL10n.text("PR/MR 链接缺失，无法确认评审已创建。")
        )
      }
      throw RemoteRepositoryPublishError.reviewRecoveryUnavailable(
        CoreL10n.text("没有可恢复的发布变更或 PR/MR 链接。")
      )
    }
    return self
  }
}

/// A conflict found by the read-only direct-publish preflight.
public enum RemoteRepositoryPublishPreflightConflictKind: String, Codable, Hashable, Sendable {
  case untrackedRemoteFile
  case remoteVersionConflict
}

/// One per-path remote version conflict discovered before a direct publish.
public struct RemoteRepositoryPublishPreflightConflict: Identifiable, Codable, Hashable, Sendable {
  public var id: String {
    "\(kind.rawValue):\(path)"
  }

  public var kind: RemoteRepositoryPublishPreflightConflictKind
  public var path: String
  public var expectedSHA: String?
  public var actualSHA: String?

  public init(
    kind: RemoteRepositoryPublishPreflightConflictKind,
    path: String,
    expectedSHA: String? = nil,
    actualSHA: String? = nil
  ) {
    self.kind = kind
    self.path = path.normalizedRelativePath()
    self.expectedSHA = expectedSHA?.trimmedForPublishing.nilIfEmpty
    self.actualSHA = actualSHA?.trimmedForPublishing.nilIfEmpty
  }

  public var isUntrackedRemoteFile: Bool {
    kind == .untrackedRemoteFile
  }

  public var isRemoteVersionConflict: Bool {
    kind == .remoteVersionConflict
  }

  /// Alias used by publish stores that treat all path-bearing work items
  /// uniformly.
  public var repositoryPath: String {
    path
  }

  /// The equivalent existing publish error, preserving the established
  /// localized messaging and conflict semantics.
  public var error: RemoteRepositoryPublishError {
    switch kind {
    case .untrackedRemoteFile:
      return .untrackedRemoteFile(path: path, actualSHA: actualSHA ?? "")
    case .remoteVersionConflict:
      return .remoteVersionConflict(
        path: path,
        expectedSHA: expectedSHA ?? "",
        actualSHA: actualSHA
      )
    }
  }
}

/// The complete result of a no-write direct-publish remote preflight.
public struct RemoteRepositoryPublishPreflightResult: Codable, Hashable, Sendable {
  public var conflicts: [RemoteRepositoryPublishPreflightConflict]
  /// Versions for upsert files whose exact local content is already present
  /// remotely. These values can repair a missing or stale local baseline.
  public var remoteVersionsByPath: [String: String]

  public init(
    conflicts: [RemoteRepositoryPublishPreflightConflict] = [],
    remoteVersionsByPath: [String: String] = [:]
  ) {
    self.conflicts = conflicts
    self.remoteVersionsByPath = remoteVersionsByPath.reduce(into: [String: String]()) { result, entry in
      let path = entry.key.normalizedRelativePath()
      guard !path.isEmpty,
            let version = entry.value.trimmedForPublishing.nilIfEmpty else {
        return
      }
      result[path] = version
    }
  }

  public var isSafe: Bool {
    conflicts.isEmpty
  }

  public var automaticallyAdoptedPaths: [String] {
    remoteVersionsByPath.keys.sorted()
  }

  public func remoteVersion(for repositoryPath: String) -> String? {
    remoteVersionsByPath[repositoryPath.normalizedRelativePath()]
  }
}

public struct RemoteRepositoryReviewRecoveryDraft: Codable, Hashable, Sendable {
  public var recordID: UUID
  public var branchName: String
  public var targetBranch: String
  public var title: String
  public var body: String
  public var changedPaths: [String]
  public var recordedCommitSHA: String

  public init(
    recordID: UUID,
    branchName: String,
    targetBranch: String,
    title: String,
    body: String,
    changedPaths: [String],
    recordedCommitSHA: String
  ) {
    self.recordID = recordID
    self.branchName = branchName
    self.targetBranch = targetBranch
    self.title = title
    self.body = body
    self.changedPaths = changedPaths
    self.recordedCommitSHA = recordedCommitSHA
  }
}

public extension RemoteRepositoryReviewRecoveryDraft {
  static func make(record: ReleaseRecord) throws -> RemoteRepositoryReviewRecoveryDraft {
    guard record.kind == .remotePublishFailure,
          let branchName = record.branchName?.trimmedForPublishing.nilIfEmpty,
          let targetBranch = record.targetBranch?.trimmedForPublishing.nilIfEmpty,
          let commitSHA = record.commitSHA?.trimmedForPublishing.nilIfEmpty,
          branchName != targetBranch else {
      throw RemoteRepositoryPublishError.reviewRecoveryUnavailable(
        CoreL10n.text("记录中没有可恢复的 Review 分支、目标分支或 commit。")
      )
    }

    let title: String
    if let recordedTitle = record.reviewTitle?.trimmedForPublishing.nilIfEmpty {
      title = recordedTitle
    } else if !record.batchItems.isEmpty {
      title = "Publish \(record.batchItems.count) articles"
    } else {
      title = CoreL10n.format("发布：%@", record.draftTitle ?? record.title)
    }

    var bodyLines: [String] = [
      CoreL10n.text("## 恢复发布"),
      CoreL10n.format("- 站点：%@", record.siteName ?? CoreL10n.text("未命名站点")),
      CoreL10n.format("- 目标分支：%@", targetBranch),
      CoreL10n.format("- 发布分支：%@", branchName),
      CoreL10n.format("- Commit：%@", commitSHA),
      "",
      CoreL10n.text("该分支的文件和 commit 已在之前的发布中写入；本次仅继续创建或获取 PR/MR，不重新上传文件。")
    ]

    if !record.batchItems.isEmpty {
      bodyLines.append(contentsOf: ["", CoreL10n.text("## 文章")])
      bodyLines.append(contentsOf: record.batchItems.map { "- \($0.draftTitle): `\($0.markdownPath)`" })
    }
    if !record.changedPaths.isEmpty {
      bodyLines.append(contentsOf: ["", CoreL10n.text("## 文件")])
      bodyLines.append(contentsOf: record.changedPaths.map { "- `\($0)`" })
    }

    return RemoteRepositoryReviewRecoveryDraft(
      recordID: record.id,
      branchName: branchName,
      targetBranch: targetBranch,
      title: title,
      body: bodyLines.joined(separator: "\n"),
      changedPaths: record.changedPaths,
      recordedCommitSHA: commitSHA
    )
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
    mode.usesDedicatedBranch
      ? "\(branchName) -> \(targetBranch)"
      : targetBranch
  }

  var clipboardSummary: String {
    var lines = [
      "\(displayTitle)",
      CoreL10n.format("分支：%@", branchSummary),
      CoreL10n.format("文件：%@", String(changedPaths.count))
    ]
    if let repositoryName {
      lines.insert(CoreL10n.format("仓库：%@", repositoryName), at: 1)
    }
    if let commitSHA {
      lines.append(CoreL10n.format("Commit：%@", commitSHA))
    }
    if let reviewURL {
      lines.append(CoreL10n.format("PR/MR：%@", reviewURL))
    }
    if let reviewTitle {
      lines.append(CoreL10n.format("标题：%@", reviewTitle))
    }
    if !changedPaths.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("变更文件："))
      lines.append(contentsOf: changedPaths.map { "- \($0)" })
    }
    return lines.joined(separator: "\n")
  }

  var remoteVerificationMarkdown: String {
    var lines = [
      CoreL10n.format("# %@ 线上发布实测包", provider.displayName),
      "",
      CoreL10n.format("- 发布方式：%@", mode.displayName),
      CoreL10n.format("- 分支：%@", branchSummary),
      CoreL10n.format("- 文件：%@", String(changedPaths.count))
    ]
    if let repositoryName = repositoryName?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- 仓库：%@", repositoryName))
    }
    if let commitSHA = commitSHA?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- Commit：%@", commitSHA))
    }
    if let reviewURL = reviewURL?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- PR/MR：%@", reviewURL))
    }
    if let reviewTitle = reviewTitle?.trimmedForPublishing.nilIfEmpty {
      lines.append(CoreL10n.format("- 标题：%@", reviewTitle))
    }

    if !changedPaths.isEmpty {
      lines.append("")
      lines.append(CoreL10n.text("## 文件清单"))
      lines.append(contentsOf: changedPaths.map { "- \($0)" })
    }

    let commands = remoteVerificationCommands
    lines.append("")
    lines.append(CoreL10n.text("## API 实测命令"))
    if commands.isEmpty {
      lines.append(CoreL10n.text("当前结果缺少仓库名或 commit，或 API 端点不符合 HTTPS 安全要求；未生成含 Token 的命令。"))
    } else {
      lines.append("```bash")
      lines.append(contentsOf: commands)
      lines.append("```")
    }

    lines.append("")
    lines.append(CoreL10n.text("## 发布后核对"))
    lines.append(CoreL10n.text("- [ ] 远端 commit 或 PR/MR 可打开。"))
    lines.append(CoreL10n.text("- [ ] 变更文件都在目标分支或 Review 分支。"))
    lines.append(CoreL10n.text("- [ ] 部署状态面板已刷新到最新记录。"))
    lines.append(CoreL10n.text("- [ ] 文章页面、Open Graph 和 Twitter 卡片已完成发布后检查。"))

    return lines.joined(separator: "\n")
  }

  var remoteVerificationCommands: [String] {
    guard let repositoryName = repositoryName?.trimmedForPublishing.nilIfEmpty else {
      return []
    }

    let ref = mode.usesDedicatedBranch ? branchName : targetBranch
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
    let rollbackTitle = CoreL10n.format("回滚：%@", displayTitle)
    return RemoteRepositoryRollbackDraft(
      recordID: record.id,
      title: rollbackTitle,
      commitMessage: rollbackTitle,
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
      title: CoreL10n.format("撤回 Review：%@", record.draftTitle ?? record.title),
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
