import Foundation
import PublishingCoreSupport
import PublishingDomainContracts
import PublishingGitCore

struct RepositoryWorktreeGitExecutionPolicyService {
  let policyService: RepositoryGitExecutionPolicyService
  let git: GitCommandRunner

  init(git: GitCommandRunner) {
    self.git = git
    policyService = RepositoryGitExecutionPolicyService(gitCommandRunner: git)
  }

  func commit(
    confirmation: RepositoryWorktreePublishConfirmation,
    tree: String,
    root: URL,
    index: URL,
    temporaryDirectory: URL,
    validateSnapshot: () throws -> Void
  ) throws -> String {
    let message = temporaryDirectory.appendingPathComponent("COMMIT_EDITMSG")
    try Data((confirmation.commitMessage + "\n").utf8).write(to: message)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: message.path
    )
    try policyService.runPreCommitHooks(
      policy: confirmation.executionPolicy, rootURL: root, indexURL: index,
      messageURL: message, source: "message", validateSnapshot: validateSnapshot
    )
    let arguments = ["commit-tree", tree, "-p", confirmation.snapshot.headSHA, "-F", message.path]
    let result = try policyService.commit(
      arguments, rootURL: root, policy: confirmation.executionPolicy, indexURL: index
    )
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryWorktreePublishError.gitFailed(
        command: GitCommandRunner.redactedCommandDescription(arguments), output: result.output
      )
    }
    return result.standardOutput.trimmedForPublishing
  }

  func postCommit(
    policy: RepositoryGitExecutionPolicy?, root: URL, commitSHA: String
  ) throws {
    do {
      try policyService.runHook(.postCommit, policy: policy, rootURL: root)
    } catch {
      throw RepositoryWorktreePublishError.commitSucceededButPushFailed(
        commitSHA: commitSHA,
        message: CoreL10n.format("本地已提交，post-commit hook 失败，未推送：%@", error.localizedDescription)
      )
    }
  }

  func prePush(
    policy: RepositoryGitExecutionPolicy?,
    branch: String,
    root: URL,
    commitSHA: String,
    remoteSHA: String,
    origin: String,
    temporaryDirectory: URL? = nil,
    validateSnapshot: () throws -> Void
  ) throws {
    guard policy?.hasTrustedHooks == true else { return }
    let headBeforeHook = git.run(["rev-parse", "HEAD"], rootURL: root)
    guard headBeforeHook.terminationStatus == 0, !headBeforeHook.didTimeOut,
      !headBeforeHook.wasOutputTruncated
    else {
      throw RepositoryWorktreePublishError.gitFailed(
        command: "git rev-parse HEAD", output: headBeforeHook.output)
    }
    let directory =
      temporaryDirectory
      ?? FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPress-PushHook-\(UUID().uuidString)", isDirectory: true)
    if temporaryDirectory == nil {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
      )
    }
    defer { if temporaryDirectory == nil { try? FileManager.default.removeItem(at: directory) } }
    let input = directory.appendingPathComponent("pre-push-input")
    let reference = "refs/heads/\(branch)"
    try Data("\(commitSHA) \(commitSHA) \(reference) \(remoteSHA)\n".utf8).write(to: input)
    try policyService.runHook(
      .prePush, policy: policy, rootURL: root,
      arguments: ["origin", origin], standardInputURL: input
    )
    let headAfterHook = git.run(["rev-parse", "HEAD"], rootURL: root)
    guard headAfterHook.terminationStatus == 0, !headAfterHook.didTimeOut,
      !headAfterHook.wasOutputTruncated,
      headAfterHook.standardOutput == headBeforeHook.standardOutput
    else { throw RepositoryGitExecutionPolicyError.reviewedContentChanged }
    try validateSnapshot()
  }
}

extension RepositoryWorktreePublishService {
  func repositoryIndexURL(root: URL) throws -> URL {
    let value = try output(["rev-parse", "--git-path", "index"], root: root)
      .trimmedForPublishing
    guard !value.isEmpty else {
      throw RepositoryWorktreePublishError.invalidRepository(
        "无法定位 Git index。"
      )
    }
    return URL(fileURLWithPath: value, relativeTo: root).standardizedFileURL
  }

  func output(_ arguments: [String], root: URL, indexURL: URL? = nil) throws -> String {
    let result = git.run(
      arguments,
      rootURL: root,
      preserveStandardOutputWhitespace: true,
      environmentOverrides: indexURL.map { ["GIT_INDEX_FILE": $0.path] } ?? [:]
    )
    guard result.terminationStatus == 0,
      !result.didTimeOut,
      !result.wasOutputTruncated
    else {
      throw gitFailure(arguments: arguments, result: result)
    }
    return result.standardOutput
  }

  func gitFailure(
    arguments: [String],
    result: GitCommandResult
  ) -> RepositoryWorktreePublishError {
    var diagnostic = result.output
    if result.didTimeOut {
      diagnostic = "Git 命令超时。\n" + diagnostic
    }
    if result.wasOutputTruncated {
      diagnostic = "Git 输出超过安全上限。\n" + diagnostic
    }
    return .gitFailed(
      command: GitCommandRunner.redactedCommandDescription(arguments),
      output: diagnostic.trimmedForPublishing
    )
  }
}

extension RepositoryWorktreePushRetryService {
  func output(
    _ arguments: [String],
    root: URL,
    preserveWhitespace: Bool = false
  ) throws -> String {
    let result = git.run(
      arguments,
      rootURL: root,
      preserveStandardOutputWhitespace: preserveWhitespace
    )
    guard result.terminationStatus == 0, !result.didTimeOut, !result.wasOutputTruncated else {
      throw RepositoryWorktreePublishError.gitFailed(
        command: GitCommandRunner.redactedCommandDescription(arguments),
        output: result.output
      )
    }
    return result.standardOutput
  }
}
