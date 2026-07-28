import Foundation

struct RemoteRepository {
  var profile: SiteProfile
  var owner: String
  var name: String
  var branch: String
  var apiBaseURL: URL

  var displayName: String {
    "\(owner)/\(name)"
  }

  var projectPath: String {
    "\(owner)/\(name)"
  }
}

struct HTTPDataResponse {
  var data: Data
  var statusCode: Int
  var headers: [String: String] = [:]
  var sensitiveValues: [String] = []

  func headerValue(_ name: String) -> String? {
    headers.first { key, _ in
      key.caseInsensitiveCompare(name) == .orderedSame
    }?.value
  }
}

struct GitHubRepositoryMetadata: Decodable {
  var fullName: String?
  var defaultBranch: String?
  var permissions: Permissions?

  enum CodingKeys: String, CodingKey {
    case fullName = "full_name"
    case defaultBranch = "default_branch"
    case permissions
  }

  struct Permissions: Decodable {
    var admin: Bool?
    var maintain: Bool?
    var push: Bool?
  }
}

struct GitHubCurrentUserResponse: Decodable {
  var login: String
}

struct GitHubCreateRepositoryBody: Encodable {
  var name: String
  var description: String?
  var privateRepository: Bool
  var autoInit: Bool

  enum CodingKeys: String, CodingKey {
    case name
    case description
    case privateRepository = "private"
    case autoInit = "auto_init"
  }
}

struct GitHubCreatedRepositoryResponse: Decodable {
  var fullName: String?
  var defaultBranch: String?
  var sshURL: String?
  var cloneURL: String?
  var htmlURL: String?
  var privateRepository: Bool?

  enum CodingKeys: String, CodingKey {
    case fullName = "full_name"
    case defaultBranch = "default_branch"
    case sshURL = "ssh_url"
    case cloneURL = "clone_url"
    case htmlURL = "html_url"
    case privateRepository = "private"
  }
}

struct GitHubReferenceResponse: Decodable {
  var object: Object

  struct Object: Decodable {
    var sha: String
  }
}

struct GitHubCreateReferenceBody: Encodable {
  var ref: String
  var sha: String
}

struct GitHubUpdateReferenceBody: Encodable {
  var sha: String
  var force: Bool
}

struct GitHubCommitResponse: Decodable {
  var sha: String
  var tree: Tree
  var parents: [Parent]

  struct Tree: Decodable {
    var sha: String
  }

  struct Parent: Decodable {
    var sha: String
  }
}

struct GitHubCreateCommitBody: Encodable {
  var message: String
  var tree: String
  var parents: [String]
}

struct GitHubCreateBlobBody: Encodable {
  var content: String
  var encoding: String
}

struct GitHubBlobResponse: Decodable {
  var sha: String
}

struct GitHubCreateTreeBody: Encodable {
  var baseTree: String
  var tree: [GitHubTreeEntry]

  enum CodingKeys: String, CodingKey {
    case baseTree = "base_tree"
    case tree
  }
}

struct GitHubTreeEntry: Encodable {
  var path: String
  var mode: String = "100644"
  var type: String = "blob"
  var sha: String?

  enum CodingKeys: String, CodingKey {
    case path
    case mode
    case type
    case sha
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(path, forKey: .path)
    try container.encode(mode, forKey: .mode)
    try container.encode(type, forKey: .type)
    if let sha {
      try container.encode(sha, forKey: .sha)
    } else {
      try container.encodeNil(forKey: .sha)
    }
  }
}

struct GitHubTreeResponse: Decodable {
  var sha: String
}

struct GitHubContentResponse: Decodable {
  var sha: String?
}

struct GitHubPutContentsBody: Encodable {
  var message: String
  var content: String
  var branch: String
  var sha: String?
}

struct GitHubDeleteContentsBody: Encodable {
  var message: String
  var branch: String
  var sha: String
}

struct GitHubContentMutationResponse: Decodable {
  var content: Content?
  var commit: Commit

  struct Content: Decodable {
    var sha: String?
  }

  struct Commit: Decodable {
    var sha: String
  }
}

struct GitHubCreatePullRequestBody: Encodable {
  var title: String
  var body: String
  var head: String
  var base: String
}

struct GitHubPullRequestResponse: Decodable {
  var htmlURL: String?

  enum CodingKeys: String, CodingKey {
    case htmlURL = "html_url"
  }
}

struct GitHubClosePullRequestBody: Encodable {
  var state: String
}

struct GitHubPullRequestStateResponse: Decodable {
  var state: String?
  var htmlURL: String?

  enum CodingKeys: String, CodingKey {
    case state
    case htmlURL = "html_url"
  }
}

struct GitLabProjectMetadata: Decodable {
  var pathWithNamespace: String?
  var defaultBranch: String?
  var permissions: Permissions?

  enum CodingKeys: String, CodingKey {
    case pathWithNamespace = "path_with_namespace"
    case defaultBranch = "default_branch"
    case permissions
  }

  struct Permissions: Decodable {
    var projectAccess: Access?
    var groupAccess: Access?

    enum CodingKeys: String, CodingKey {
      case projectAccess = "project_access"
      case groupAccess = "group_access"
    }
  }

  struct Access: Decodable {
    var accessLevel: Int

    enum CodingKeys: String, CodingKey {
      case accessLevel = "access_level"
    }
  }
}

struct GitLabGroupResponse: Decodable {
  var id: Int
  var fullPath: String?

  enum CodingKeys: String, CodingKey {
    case id
    case fullPath = "full_path"
  }
}

struct GitLabCreateProjectBody: Encodable {
  var name: String
  var path: String
  var description: String?
  var visibility: String
  var namespaceID: Int?
  var initializeWithReadme: Bool

  enum CodingKeys: String, CodingKey {
    case name
    case path
    case description
    case visibility
    case namespaceID = "namespace_id"
    case initializeWithReadme = "initialize_with_readme"
  }
}

struct GitLabCreatedProjectResponse: Decodable {
  var pathWithNamespace: String?
  var defaultBranch: String?
  var sshURL: String?
  var httpURL: String?
  var webURL: String?
  var visibility: String?

  enum CodingKeys: String, CodingKey {
    case pathWithNamespace = "path_with_namespace"
    case defaultBranch = "default_branch"
    case sshURL = "ssh_url_to_repo"
    case httpURL = "http_url_to_repo"
    case webURL = "web_url"
    case visibility
  }
}

struct GitLabCreateCommitBody: Encodable {
  var branch: String
  var commitMessage: String
  var startBranch: String?
  var actions: [GitLabCommitAction]

  enum CodingKeys: String, CodingKey {
    case branch
    case commitMessage = "commit_message"
    case startBranch = "start_branch"
    case actions
  }
}

struct GitLabRevertCommitBody: Encodable {
  var branch: String
}

struct GitLabCommitAction: Encodable {
  var action: String
  var filePath: String
  var content: String?
  var encoding: String?
  var lastCommitID: String?

  enum CodingKeys: String, CodingKey {
    case action
    case filePath = "file_path"
    case content
    case encoding
    case lastCommitID = "last_commit_id"
  }
}

struct GitLabFileRemoteState {
  var exists: Bool
  var lastCommitID: String?
  var content: Data?
}

struct GitLabFileResponse: Decodable {
  var lastCommitID: String?
  var content: String?
  var encoding: String?

  enum CodingKeys: String, CodingKey {
    case lastCommitID = "last_commit_id"
    case content
    case encoding
  }

  var decodedContent: Data? {
    guard let content else { return nil }
    if encoding?.lowercased() == "base64" {
      return Data(base64Encoded: content, options: .ignoreUnknownCharacters)
    }
    return Data(content.utf8)
  }
}

struct GitLabCommitResponse: Decodable {
  var id: String
}

struct GitLabCreateMergeRequestBody: Encodable {
  var sourceBranch: String
  var targetBranch: String
  var title: String
  var description: String
  var removeSourceBranch: Bool

  enum CodingKeys: String, CodingKey {
    case sourceBranch = "source_branch"
    case targetBranch = "target_branch"
    case title
    case description
    case removeSourceBranch = "remove_source_branch"
  }
}

struct GitLabMergeRequestResponse: Decodable {
  var webURL: String?

  enum CodingKeys: String, CodingKey {
    case webURL = "web_url"
  }
}

struct GitLabCloseMergeRequestBody: Encodable {
  var stateEvent: String

  enum CodingKeys: String, CodingKey {
    case stateEvent = "state_event"
  }
}

struct GitLabMergeRequestStateResponse: Decodable {
  var state: String?
  var webURL: String?

  enum CodingKeys: String, CodingKey {
    case state
    case webURL = "web_url"
  }
}

public enum RemoteRepositoryPublishError: LocalizedError, Equatable {
  case missingToken
  case missingRepositoryConfiguration
  case missingRepositoryName
  case missingRollbackCommit
  case rollbackCommitHasNoParent(String)
  case missingReviewURL
  case invalidReviewURL(String)
  case reviewRecoveryUnavailable(String)
  case reviewCreationPermissionDenied(provider: RepositoryProvider, body: String)
  case unsupportedRepositoryCreationProvider(String)
  case invalidBaseURL(String)
  case insecureBaseURL
  case invalidResponse
  case httpStatus(Int, String)
  case missingSourceFile(String)
  case sourceFileTooLarge(path: String, maximumByteCount: Int)
  case invalidSourceFile(path: String, reason: String)
  case untrackedRemoteFile(path: String, actualSHA: String)
  case remoteVersionConflict(path: String, expectedSHA: String, actualSHA: String?)
  case partialPublish(
    provider: RepositoryProvider,
    mode: RemoteRepositoryPublishMode,
    branchName: String,
    targetBranch: String,
    changedPaths: [String],
    commitSHA: String?,
    underlyingMessage: String
  )

  public var errorDescription: String? {
    switch self {
    case .missingToken:
      return CoreL10n.text("未保存仓库访问 Token。")
    case .missingRepositoryConfiguration:
      return CoreL10n.text("请先填写仓库 Owner/Namespace 和 Repo/Project。")
    case .missingRepositoryName:
      return CoreL10n.text("请先填写 Repo/Project 名称。")
    case .missingRollbackCommit:
      return CoreL10n.text("这条发布记录没有远端 commit，无法执行线上回滚。")
    case .rollbackCommitHasNoParent(let sha):
      return CoreL10n.format("无法回滚 commit %@：远端没有返回父提交。", sha)
    case .missingReviewURL:
      return CoreL10n.text("这条发布记录没有 PR/MR 链接，无法通过 API 撤回 Review。")
    case .invalidReviewURL(let value):
      return CoreL10n.format("无法从 PR/MR 链接解析编号：%@", value)
    case .reviewRecoveryUnavailable(let reason):
      return CoreL10n.format("无法继续创建 PR/MR：%@", reason)
    case .reviewCreationPermissionDenied(let provider, let body):
      let detail = remoteAPIErrorDetail(from: body)
        .map { CoreL10n.format("\n远端信息：%@", $0) }
        ?? ""
      switch provider {
      case .github:
        return CoreL10n.format("GitHub 内容写入已完成，但创建 PR 被拒绝。请给 fine-grained Token 开启 Pull requests: Read and write。%@", detail)
      case .gitlab:
        return CoreL10n.format("GitLab 内容写入已完成，但创建 MR 被拒绝。请确认 Token 具备 api scope，且账号至少是 Developer。%@", detail)
      }
    case .unsupportedRepositoryCreationProvider(let provider):
      return CoreL10n.format("%@ 暂不支持在 App 内创建仓库。", provider)
    case .invalidBaseURL(let value):
      return CoreL10n.format("仓库 API Base URL 无效：%@", value)
    case .insecureBaseURL:
      return CoreL10n.text("仓库 API Base URL 必须使用 HTTPS；已阻止向不安全端点发送 Token。")
    case .invalidResponse:
      return CoreL10n.text("仓库 API 返回了无效响应。")
    case .httpStatus(let status, let body):
      return remoteAPIHTTPStatusDescription(status: status, body: body)
    case .missingSourceFile(let path):
      return CoreL10n.format("媒体源文件缺失：%@", path)
    case .sourceFileTooLarge(let path, let maximumByteCount):
      return CoreL10n.format(
        "媒体文件超过远端内联发布上限（%@ MB）：%@",
        String(maximumByteCount / 1_024 / 1_024),
        path
      )
    case .invalidSourceFile(let path, let reason):
      return CoreL10n.format("媒体源文件无法安全读取：%@。%@", path, reason)
    case .untrackedRemoteFile(let path, let actualSHA):
      return CoreL10n.format("远端同路径文件已存在：%@ 的当前版本是 %@，但本地草稿没有记录远端版本。请先同步远端变更或改用 PR/MR。", path, actualSHA)
    case .remoteVersionConflict(let path, let expectedSHA, let actualSHA):
      let actual = actualSHA?.nilIfEmpty ?? CoreL10n.text("远端文件不存在")
      return CoreL10n.format("远端版本冲突：%@ 的当前版本是 %@，本地草稿基于 %@。请先同步远端变更或改用 PR/MR。", path, actual, expectedSHA)
    case .partialPublish(let provider, let mode, let branchName, _, let changedPaths, let commitSHA, let underlyingMessage):
      let commitSummary = commitSHA.map {
        CoreL10n.format("，最后 commit：%@", String($0.prefix(8)))
      } ?? ""
      return CoreL10n.format("%@ %@部分完成后失败：%@ 个文件已写入 %@%@。%@", provider.displayName, mode.displayName, String(changedPaths.count), branchName, commitSummary, underlyingMessage)
    }
  }

  private func remoteAPIHTTPStatusDescription(status: Int, body: String) -> String {
    let detail = remoteAPIErrorDetail(from: body)
    let detailLine = detail.map { CoreL10n.format("\n远端信息：%@", $0) }
      ?? body.nilIfEmpty.map { "\n\($0)" }
      ?? ""
    let nextStep: String
    switch status {
    case 401:
      nextStep = CoreL10n.text("Token 无效或已过期；请重新保存 GitHub/GitLab Token 后再检查权限。")
    case 403:
      nextStep = CoreL10n.text("Token 权限不足或仓库策略拒绝操作；GitHub 写入内容需 Contents: Read and write，创建 PR 还需 Pull requests: Read and write；GitLab 请确认 Developer(30) 或更高权限。")
    case 404:
      nextStep = CoreL10n.text("仓库、分支或文件路径不存在；请确认 Owner/Namespace、Repo/Project、默认分支和发布路径。")
    case 409:
      nextStep = CoreL10n.text("远端存在冲突或分支状态不一致；请先同步远端变更，或改用 PR/MR。")
    case 422:
      nextStep = CoreL10n.text("平台拒绝了本次写入参数；请检查分支名、同名 PR/MR、文件路径、commit 内容和 Token 写权限。")
    default:
      nextStep = CoreL10n.text("请根据远端响应修正配置或稍后重试。")
    }
    return CoreL10n.format("仓库 API 请求失败：HTTP %@。%@%@", String(status), nextStep, detailLine)
  }

  private func remoteAPIErrorDetail(from body: String) -> String? {
    guard let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else {
      return body.trimmedForPublishing.nilIfEmpty
    }
    var parts: [String] = []
    if let dictionary = object as? [String: Any] {
      appendRemoteAPIValue(dictionary["message"], into: &parts)
      appendRemoteAPIValue(dictionary["error"], into: &parts)
      appendRemoteAPIValue(dictionary["errors"], into: &parts)
      appendRemoteAPIValue(dictionary["documentation_url"], into: &parts)
    } else {
      appendRemoteAPIValue(object, into: &parts)
    }
    let summary = uniqueStrings(parts)
      .map { $0.trimmedForPublishing }
      .filter { !$0.isEmpty }
      .joined(separator: CoreL10n.text("；"))
    return summary.nilIfEmpty
  }

  private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
      guard seen.insert(value).inserted else { continue }
      result.append(value)
    }
    return result
  }

  private func appendRemoteAPIValue(_ value: Any?, into parts: inout [String]) {
    switch value {
    case let text as String:
      parts.append(text)
    case let dictionary as [String: Any]:
      for key in dictionary.keys.sorted() {
        appendRemoteAPIValue(dictionary[key], into: &parts)
      }
    case let array as [Any]:
      for item in array {
        appendRemoteAPIValue(item, into: &parts)
      }
    case let number as NSNumber:
      parts.append(number.stringValue)
    case .none:
      break
    case let value?:
      parts.append(String(describing: value))
    }
  }
}
