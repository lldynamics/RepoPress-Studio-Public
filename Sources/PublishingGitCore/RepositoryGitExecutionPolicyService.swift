import Foundation
import PublishingCoreSupport
import PublishingDomainContracts

public enum RepositoryGitHook: String, Sendable, CaseIterable {
  case preCommit = "pre-commit"
  case prepareCommitMessage = "prepare-commit-msg"
  case commitMessage = "commit-msg"
  case postCommit = "post-commit"
  case prePush = "pre-push"
}

public enum RepositoryGitExecutionPolicyError: Error, LocalizedError, Equatable, Sendable {
  case invalidSigningKey
  case trustNoLongerMatches
  case unsafeHooksDirectory
  case unsafeHook(String)
  case hookFailed(String, String)
  case reviewedContentChanged
  case unsupportedRebase
  case gitFailed(String)

  public var errorDescription: String? {
    switch self {
    case .invalidSigningKey:
      return CoreL10n.text("SSH 提交签名需要绝对密钥路径；密钥内容不能保存在站点设置中。")
    case .trustNoLongerMatches:
      return CoreL10n.text("仓库路径或 Git 元数据目录已变化，请重新确认 hooks 信任。")
    case .unsafeHooksDirectory:
      return CoreL10n.text("仅支持当前仓库标准 hooks 目录，目录及其路径不能是符号链接。")
    case .unsafeHook(let name):
      return CoreL10n.format("Git hook 不是安全的普通可执行文件：%@。", name)
    case .hookFailed(let name, let output):
      return CoreL10n.format("Git hook %@ 执行失败：%@", name, output)
    case .reviewedContentChanged:
      return CoreL10n.text("Git hook 改动了已审阅内容或提交说明，请重新扫描并确认后再提交。")
    case .unsupportedRebase:
      return CoreL10n.text("当前变基流程不支持站点提交签名或受信 hooks，请在外部 Git 工具完成变基。")
    case .gitFailed(let output):
      return CoreL10n.format("无法安全读取 Git 执行策略：%@", output)
    }
  }
}

/// A narrow opt-in layer. Repository config never selects the signing program
/// or hooks directory, and no read command gains executable permissions.
public struct RepositoryGitExecutionPolicyService: Sendable {
  private let git: GitCommandRunner

  public init(gitCommandRunner: GitCommandRunner = GitCommandRunner(timeout: 120)) {
    git = gitCommandRunner
  }

  /// Called only after the user confirms trust. Importing a profile cannot
  /// manufacture trust for a different canonical root or metadata directory.
  public func trustingHooks(
    at rootURL: URL,
    policy: RepositoryGitExecutionPolicy = RepositoryGitExecutionPolicy()
  ) throws -> RepositoryGitExecutionPolicy {
    let locations = try repositoryLocations(rootURL: rootURL)
    try validateHooksDirectory(locations.hooks)
    var result = policy
    result.trustedHooksRepositoryPath = locations.root.path
    result.trustedHooksGitDirectoryPath = locations.common.path
    return result
  }

  public func validate(
    policy: RepositoryGitExecutionPolicy?,
    rootURL: URL
  ) throws {
    guard let policy else { return }
    if policy.sshCommitSigningEnabled {
      let key = policy.sshSigningKey.trimmingCharacters(in: .whitespacesAndNewlines)
      guard key.hasPrefix("/"), key.utf8.count <= 4_096,
        !key.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
      else { throw RepositoryGitExecutionPolicyError.invalidSigningKey }
    }
    if policy.hasTrustedHooks {
      _ = try trustedHooksDirectory(policy: policy, rootURL: rootURL)
    }
  }

  public func commit(
    _ arguments: [String],
    rootURL: URL,
    policy: RepositoryGitExecutionPolicy?,
    indexURL: URL? = nil
  ) throws -> GitCommandResult {
    guard arguments.first == "commit-tree" || arguments.first == "commit" else {
      throw RepositoryGitExecutionPolicyError.gitFailed("只允许显式提交命令。")
    }
    try validate(policy: policy, rootURL: rootURL)
    var settings: [(String, String)] = []
    var commitArguments = arguments
    if policy?.sshCommitSigningEnabled == true, let policy {
      settings = [
        ("gpg.format", "ssh"),
        ("user.signingKey", policy.sshSigningKey.trimmingCharacters(in: .whitespacesAndNewlines)),
        ("gpg.ssh.program", "/usr/bin/ssh-keygen"),
        ("commit.gpgSign", "true"),
      ]
      commitArguments.insert("-S", at: 1)
    }
    return git.runControlled(
      commitArguments, rootURL: rootURL,
      environmentOverrides: indexURL.map { ["GIT_INDEX_FILE": $0.path] } ?? [:],
      configurationOverrides: settings
    )
  }

  /// commit-tree bypasses Git's commit hooks, so callers explicitly run these
  /// against their reviewed index. A hook may reject, but cannot silently
  /// replace reviewed content or the message. Revalidation occurs after each.
  public func runPreCommitHooks(
    policy: RepositoryGitExecutionPolicy?,
    rootURL: URL,
    indexURL: URL?,
    messageURL: URL,
    source: String,
    validateSnapshot: () throws -> Void
  ) throws {
    guard policy?.hasTrustedHooks == true else { return }
    let message = try SafeFileReader.data(at: messageURL, maximumByteCount: 8_192)
    for hook in [RepositoryGitHook.preCommit, .prepareCommitMessage, .commitMessage] {
      let arguments: [String]
      switch hook {
      case .preCommit: arguments = []
      case .prepareCommitMessage: arguments = [messageURL.path, source]
      default: arguments = [messageURL.path]
      }
      try runHook(
        hook, policy: policy, rootURL: rootURL, indexURL: indexURL, arguments: arguments
      )
      guard try SafeFileReader.data(at: messageURL, maximumByteCount: 8_192) == message else {
        throw RepositoryGitExecutionPolicyError.reviewedContentChanged
      }
      try validateSnapshot()
    }
  }

  /// The repository's own `core.hooksPath`, as set by tools such as husky.
  /// RepoPress only runs the standard hooks directory, never this one, so the
  /// settings explain why those hooks do not run. Reading config executes
  /// nothing.
  public func configuredHooksPath(rootURL: URL) async -> String? {
    let result = await git.runAsync(
      ["config", "--local", "--get", "core.hooksPath"], rootURL: rootURL)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      return nil
    }
    let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }

  /// A GUI app inherits only the system PATH, so hooks that start Homebrew
  /// tools (node, npx, lint-staged) would fail. Homebrew's standard locations
  /// are appended, never prepended, so system commands keep precedence.
  static func hookSearchPath(
    inherited: String?,
    candidates: [String] = ["/opt/homebrew/bin", "/usr/local/bin"],
    directoryExists: (String) -> Bool = { path in
      var isDirectory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        && isDirectory.boolValue
    }
  ) -> String {
    var entries = (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin")
      .split(separator: ":").map(String.init).filter { !$0.isEmpty }
    for candidate in candidates where !entries.contains(candidate) && directoryExists(candidate) {
      entries.append(candidate)
    }
    return entries.joined(separator: ":")
  }

  public func runHook(
    _ hook: RepositoryGitHook,
    policy: RepositoryGitExecutionPolicy?,
    rootURL: URL,
    indexURL: URL? = nil,
    arguments: [String] = [],
    standardInputURL: URL? = nil
  ) throws {
    guard let policy, policy.hasTrustedHooks else { return }
    let directory = try trustedHooksDirectory(policy: policy, rootURL: rootURL)
    let hookURL = directory.appendingPathComponent(hook.rawValue)
    // Git ignores absent or non-executable ordinary hook files. Reject links
    // even if their target is missing, rather than accidentally following one.
    guard try !isSymbolicLink(hookURL) else {
      throw RepositoryGitExecutionPolicyError.unsafeHook(hook.rawValue)
    }
    guard FileManager.default.fileExists(atPath: hookURL.path) else { return }
    let attributes = try FileManager.default.attributesOfItem(atPath: hookURL.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw RepositoryGitExecutionPolicyError.unsafeHook(hook.rawValue)
    }
    guard FileManager.default.isExecutableFile(atPath: hookURL.path) else { return }
    var command = ["hook", "run"]
    if let standardInputURL { command.append("--to-stdin=\(standardInputURL.path)") }
    command.append(hook.rawValue)
    if !arguments.isEmpty { command += ["--"] + arguments }
    let result = git.runControlled(
      command, rootURL: rootURL,
      environmentOverrides: indexURL.map { ["GIT_INDEX_FILE": $0.path] } ?? [:],
      configurationOverrides: [("core.hooksPath", directory.path)],
      searchPath: Self.hookSearchPath(inherited: ProcessInfo.processInfo.environment["PATH"])
    )
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryGitExecutionPolicyError.hookFailed(hook.rawValue, result.output)
    }
  }

  private func trustedHooksDirectory(
    policy: RepositoryGitExecutionPolicy,
    rootURL: URL
  ) throws -> URL {
    let locations = try repositoryLocations(rootURL: rootURL)
    guard policy.trustedHooksRepositoryPath == locations.root.path,
      policy.trustedHooksGitDirectoryPath == locations.common.path
    else { throw RepositoryGitExecutionPolicyError.trustNoLongerMatches }
    try validateHooksDirectory(locations.hooks)
    return locations.hooks
  }

  private func repositoryLocations(rootURL: URL) throws -> (root: URL, common: URL, hooks: URL) {
    let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let top = try output(["rev-parse", "--show-toplevel"], rootURL: root)
    guard URL(fileURLWithPath: top).standardizedFileURL.resolvingSymlinksInPath() == root else {
      throw RepositoryGitExecutionPolicyError.trustNoLongerMatches
    }
    let rawCommon = try output(["rev-parse", "--git-common-dir"], rootURL: root)
    let common = URL(fileURLWithPath: rawCommon, relativeTo: root).standardizedFileURL
    guard common.path == common.resolvingSymlinksInPath().path,
      try !isSymbolicLink(common)
    else { throw RepositoryGitExecutionPolicyError.unsafeHooksDirectory }
    return (root, common, common.appendingPathComponent("hooks", isDirectory: true))
  }

  private func validateHooksDirectory(_ directory: URL) throws {
    guard try !isSymbolicLink(directory), directory.path == directory.resolvingSymlinksInPath().path
    else {
      throw RepositoryGitExecutionPolicyError.unsafeHooksDirectory
    }
    if FileManager.default.fileExists(atPath: directory.path) {
      let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
      guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw RepositoryGitExecutionPolicyError.unsafeHooksDirectory
      }
    }
  }

  private func output(_ arguments: [String], rootURL: URL) throws -> String {
    let result = git.run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated,
      !result.standardOutput.isEmpty
    else { throw RepositoryGitExecutionPolicyError.gitFailed(result.output) }
    return result.standardOutput
  }

  private func isSymbolicLink(_ url: URL) throws -> Bool {
    do {
      return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        == .typeSymbolicLink
    } catch {
      let cocoaError = error as NSError
      if cocoaError.domain == NSCocoaErrorDomain,
        cocoaError.code == NSFileNoSuchFileError || cocoaError.code == NSFileReadNoSuchFileError
      {
        return false
      }
      throw error
    }
  }
}
