import Foundation

public enum LocalGitPublishMode: String, Codable, Sendable {
  case directCommit
  case reviewBranch

  public var displayName: String {
    switch self {
    case .directCommit:
      return CoreL10n.text("直接提交")
    case .reviewBranch:
      return CoreL10n.text("发布分支提交")
    }
  }
}

public struct LocalGitPublishResult: Codable, Hashable, Sendable {
  public var mode: LocalGitPublishMode
  public var branchName: String
  public var committedPaths: [String]
  public var commitSHA: String
  public var commandLog: [String]
  public var output: String

  public init(
    mode: LocalGitPublishMode,
    branchName: String,
    committedPaths: [String],
    commitSHA: String,
    commandLog: [String],
    output: String
  ) {
    self.mode = mode
    self.branchName = branchName
    self.committedPaths = committedPaths
    self.commitSHA = commitSHA
    self.commandLog = commandLog
    self.output = output
  }
}

public struct LocalGitPublishService: Sendable {
  private let fileSystem: SendableFileManager
  private let previewService: LocalPublishPreviewService
  private let gitCommandRunner: GitCommandRunner

  private var fileManager: FileManager { fileSystem.value }

  public init(
    fileManager: FileManager = .default,
    previewService: LocalPublishPreviewService = LocalPublishPreviewService(),
    gitExecutablePath: String = "/usr/bin/git",
    gitCommandRunner: GitCommandRunner? = nil
  ) {
    self.fileSystem = SendableFileManager(fileManager)
    self.previewService = previewService
    self.gitCommandRunner = gitCommandRunner ?? GitCommandRunner(executableURL: URL(fileURLWithPath: gitExecutablePath))
  }

  public func publish(
    package: PublishPackage,
    profile: SiteProfile,
    mode: LocalGitPublishMode,
    preview: LocalPublishPreview? = nil
  ) throws -> LocalGitPublishResult {
    guard let result = try profile.withLocalRepositoryRootAccess({ rootURL in
      try publish(
        package: package,
        rootURL: rootURL,
        mode: mode,
        preview: preview
      )
    }) else {
      throw LocalGitPublishError.missingRepositoryRoot
    }

    return result
  }

  public func publishAsync(
    package: PublishPackage,
    profile: SiteProfile,
    mode: LocalGitPublishMode,
    preview: LocalPublishPreview? = nil
  ) async throws -> LocalGitPublishResult {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw LocalGitPublishError.missingRepositoryRoot
    }
    let didStartAccessing = rootURL.startAccessingSecurityScopedResource()
    defer {
      if didStartAccessing {
        rootURL.stopAccessingSecurityScopedResource()
      }
    }
    return try await publishAsync(
      package: package,
      rootURL: rootURL,
      mode: mode,
      preview: preview
    )
  }

  private func publish(
    package: PublishPackage,
    rootURL: URL,
    mode: LocalGitPublishMode,
    preview: LocalPublishPreview?
  ) throws -> LocalGitPublishResult {
    try ensureGitWorkTree(rootURL: rootURL)

    let currentBranch = try trimmedOutput(runGit(["rev-parse", "--abbrev-ref", "HEAD"], rootURL: rootURL))
    let initialHEAD = try trimmedOutput(runGit(["rev-parse", "HEAD"], rootURL: rootURL))
    let packagePaths = Array(Set(package.files.map(\.repositoryPath))).sorted()
    try ensurePublishPreconditions(packagePaths: packagePaths, rootURL: rootURL)
    var commandLog: [String] = []
    var outputChunks: [String] = []
    var branchCreated = false
    var didCommit = false
    var appliedStatesByRepositoryPath: [String: LocalPublishFileState] = [:]

    do {
      if mode == .reviewBranch {
        try ensureBranchDoesNotExist(package.reviewBranchName, rootURL: rootURL)
        let switchResult = try runGit(["switch", "-c", package.reviewBranchName], rootURL: rootURL)
        branchCreated = true
        commandLog.append("git switch -c \(posixShellQuote(package.reviewBranchName))")
        outputChunks.append(switchResult.output)
      }

      let writeResult = try previewService.writeWithEvidence(
        package: package,
        rootURL: rootURL,
        preview: preview
      )
      let writtenPaths = writeResult.writtenPaths
      appliedStatesByRepositoryPath = writeResult.appliedStatesByRepositoryPath
      let addResult = try runGit(["add", "--"] + packagePaths, rootURL: rootURL)
      commandLog.append("git add -- \(packagePaths.map(posixShellQuote).joined(separator: " "))")
      outputChunks.append(addResult.output)

      let diffResult = try runGit(
        ["diff", "--cached", "--quiet", "--"] + packagePaths,
        rootURL: rootURL,
        allowsExitCodes: [0, 1]
      )
      if diffResult.terminationStatus == 0 {
        throw LocalGitPublishError.noStagedChanges
      }

      let commitResult = try runGit(
        ["commit", "-m", package.commitMessage, "--"] + packagePaths,
        rootURL: rootURL
      )
      didCommit = true
      commandLog.append(
        "git commit -m \(posixShellQuote(package.commitMessage)) -- \(packagePaths.map(posixShellQuote).joined(separator: " "))"
      )
      outputChunks.append(commitResult.output)

      let commitSHA = try trimmedOutput(runGit(["rev-parse", "HEAD"], rootURL: rootURL))
      let branchName = mode == .reviewBranch ? package.reviewBranchName : currentBranch

      return LocalGitPublishResult(
        mode: mode,
        branchName: branchName,
        committedPaths: writtenPaths,
        commitSHA: commitSHA,
        commandLog: commandLog,
        output: outputChunks.map { $0.trimmedForPublishing }.filter { !$0.isEmpty }.joined(separator: "\n")
      )
    } catch {
      let rollbackFailures = rollbackPublishAttempt(
        rootURL: rootURL,
        initialBranch: currentBranch,
        initialHEAD: initialHEAD,
        reviewBranchName: package.reviewBranchName,
        packagePaths: packagePaths,
        appliedStatesByRepositoryPath: appliedStatesByRepositoryPath,
        branchCreated: branchCreated,
        didCommit: didCommit
      )
      guard rollbackFailures.isEmpty else {
        throw LocalGitPublishError.rollbackFailed(
          original: error.localizedDescription,
          rollback: rollbackFailures.joined(separator: "\n")
        )
      }
      throw error
    }
  }

  private func publishAsync(
    package: PublishPackage,
    rootURL: URL,
    mode: LocalGitPublishMode,
    preview: LocalPublishPreview?
  ) async throws -> LocalGitPublishResult {
    try await ensureGitWorkTreeAsync(rootURL: rootURL)

    let currentBranch = try trimmedOutput(await runGitAsync(["rev-parse", "--abbrev-ref", "HEAD"], rootURL: rootURL))
    let initialHEAD = try trimmedOutput(await runGitAsync(["rev-parse", "HEAD"], rootURL: rootURL))
    let packagePaths = Array(Set(package.files.map(\.repositoryPath))).sorted()
    try await ensurePublishPreconditionsAsync(packagePaths: packagePaths, rootURL: rootURL)
    var commandLog: [String] = []
    var outputChunks: [String] = []
    var branchCreated = false
    var didCommit = false
    var appliedStatesByRepositoryPath: [String: LocalPublishFileState] = [:]

    do {
      if mode == .reviewBranch {
        try await ensureBranchDoesNotExistAsync(package.reviewBranchName, rootURL: rootURL)
        let switchResult = try await runGitAsync(["switch", "-c", package.reviewBranchName], rootURL: rootURL)
        branchCreated = true
        commandLog.append("git switch -c \(posixShellQuote(package.reviewBranchName))")
        outputChunks.append(switchResult.output)
      }

      let writeResult = try previewService.writeWithEvidence(
        package: package,
        rootURL: rootURL,
        preview: preview
      )
      let writtenPaths = writeResult.writtenPaths
      appliedStatesByRepositoryPath = writeResult.appliedStatesByRepositoryPath
      let addResult = try await runGitAsync(["add", "--"] + packagePaths, rootURL: rootURL)
      commandLog.append("git add -- \(packagePaths.map(posixShellQuote).joined(separator: " "))")
      outputChunks.append(addResult.output)

      let diffResult = try await runGitAsync(
        ["diff", "--cached", "--quiet", "--"] + packagePaths,
        rootURL: rootURL,
        allowsExitCodes: [0, 1]
      )
      if diffResult.terminationStatus == 0 {
        throw LocalGitPublishError.noStagedChanges
      }

      let commitResult = try await runGitAsync(
        ["commit", "-m", package.commitMessage, "--"] + packagePaths,
        rootURL: rootURL
      )
      didCommit = true
      commandLog.append(
        "git commit -m \(posixShellQuote(package.commitMessage)) -- \(packagePaths.map(posixShellQuote).joined(separator: " "))"
      )
      outputChunks.append(commitResult.output)

      let commitSHA = try trimmedOutput(await runGitAsync(["rev-parse", "HEAD"], rootURL: rootURL))
      let branchName = mode == .reviewBranch ? package.reviewBranchName : currentBranch
      return LocalGitPublishResult(
        mode: mode,
        branchName: branchName,
        committedPaths: writtenPaths,
        commitSHA: commitSHA,
        commandLog: commandLog,
        output: outputChunks.map { $0.trimmedForPublishing }.filter { !$0.isEmpty }.joined(separator: "\n")
      )
    } catch {
      let rollbackFailures = await rollbackPublishAttemptAsync(
        rootURL: rootURL,
        initialBranch: currentBranch,
        initialHEAD: initialHEAD,
        reviewBranchName: package.reviewBranchName,
        packagePaths: packagePaths,
        appliedStatesByRepositoryPath: appliedStatesByRepositoryPath,
        branchCreated: branchCreated,
        didCommit: didCommit
      )
      guard rollbackFailures.isEmpty else {
        throw LocalGitPublishError.rollbackFailed(
          original: error.localizedDescription,
          rollback: rollbackFailures.joined(separator: "\n")
        )
      }
      throw error
    }
  }

  private func ensurePublishPreconditions(packagePaths: [String], rootURL: URL) throws {
    let stagedResult = try runGit(
      ["diff", "--cached", "--quiet"],
      rootURL: rootURL,
      allowsExitCodes: [0, 1]
    )
    if stagedResult.terminationStatus == 1 {
      let paths = try trimmedOutput(runGit(["diff", "--cached", "--name-only"], rootURL: rootURL))
        .split(separator: "\n")
        .map(String.init)
      throw LocalGitPublishError.repositoryHasStagedChanges(paths)
    }

    let status = try trimmedOutput(
      runGit(
        ["status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching", "--"] + packagePaths,
        rootURL: rootURL
      )
    )
    guard status.isEmpty else {
      throw LocalGitPublishError.packagePathsNotClean(status.split(separator: "\n").map(String.init))
    }
  }

  private func ensurePublishPreconditionsAsync(packagePaths: [String], rootURL: URL) async throws {
    let stagedResult = try await runGitAsync(
      ["diff", "--cached", "--quiet"],
      rootURL: rootURL,
      allowsExitCodes: [0, 1]
    )
    if stagedResult.terminationStatus == 1 {
      let paths = try trimmedOutput(await runGitAsync(["diff", "--cached", "--name-only"], rootURL: rootURL))
        .split(separator: "\n")
        .map(String.init)
      throw LocalGitPublishError.repositoryHasStagedChanges(paths)
    }

    let status = try trimmedOutput(
      await runGitAsync(
        ["status", "--porcelain=v1", "--untracked-files=all", "--ignored=matching", "--"] + packagePaths,
        rootURL: rootURL
      )
    )
    guard status.isEmpty else {
      throw LocalGitPublishError.packagePathsNotClean(status.split(separator: "\n").map(String.init))
    }
  }

  private func rollbackPublishAttempt(
    rootURL: URL,
    initialBranch: String,
    initialHEAD: String,
    reviewBranchName: String,
    packagePaths: [String],
    appliedStatesByRepositoryPath: [String: LocalPublishFileState],
    branchCreated: Bool,
    didCommit: Bool
  ) -> [String] {
    var failures: [String] = []
    func attempt(_ arguments: [String], allowsExitCodes: Set<Int32> = [0]) -> GitCommandResult {
      let result = gitCommandRunner.run(arguments, rootURL: rootURL)
      if !allowsExitCodes.contains(result.terminationStatus) {
        failures.append("git \(arguments.map(posixShellQuote).joined(separator: " ")): \(result.output)")
      }
      return result
    }

    let externallyModifiedPaths = externallyModifiedPackagePaths(
      rootURL: rootURL,
      appliedStatesByRepositoryPath: appliedStatesByRepositoryPath
    )
    guard externallyModifiedPaths.isEmpty else {
      return [CoreL10n.format("检测到发布后的外部修改，已停止自动回滚并保留当前文件：%@", externallyModifiedPaths.joined(separator: ", "))]
    }

    if didCommit {
      _ = attempt(["reset", "--soft", initialHEAD])
    }
    if !appliedStatesByRepositoryPath.isEmpty {
      _ = attempt(["reset", "--quiet", initialHEAD, "--"] + packagePaths)
      let originalPathsResult = attempt(["ls-tree", "-r", "--name-only", initialHEAD, "--"] + packagePaths)
      let originalPaths = originalPathsResult.output.split(separator: "\n").map(String.init)
      if !originalPaths.isEmpty {
        _ = attempt(["restore", "--source", initialHEAD, "--worktree", "--"] + originalPaths)
      }
      _ = attempt(["clean", "-f", "-d", "-x", "--"] + packagePaths)
    }

    if branchCreated {
      if initialBranch == "HEAD" {
        _ = attempt(["switch", "--detach", initialHEAD])
      } else {
        _ = attempt(["switch", initialBranch])
      }
      _ = attempt(["branch", "-D", reviewBranchName])
    }
    return failures
  }

  private func rollbackPublishAttemptAsync(
    rootURL: URL,
    initialBranch: String,
    initialHEAD: String,
    reviewBranchName: String,
    packagePaths: [String],
    appliedStatesByRepositoryPath: [String: LocalPublishFileState],
    branchCreated: Bool,
    didCommit: Bool
  ) async -> [String] {
    var failures: [String] = []
    func attempt(_ arguments: [String], allowsExitCodes: Set<Int32> = [0]) async -> GitCommandResult {
      let result = await gitCommandRunner.runAsync(arguments, rootURL: rootURL)
      if !allowsExitCodes.contains(result.terminationStatus) {
        failures.append("git \(arguments.map(posixShellQuote).joined(separator: " ")): \(result.output)")
      }
      return result
    }

    let externallyModifiedPaths = externallyModifiedPackagePaths(
      rootURL: rootURL,
      appliedStatesByRepositoryPath: appliedStatesByRepositoryPath
    )
    guard externallyModifiedPaths.isEmpty else {
      return [CoreL10n.format("检测到发布后的外部修改，已停止自动回滚并保留当前文件：%@", externallyModifiedPaths.joined(separator: ", "))]
    }

    if didCommit {
      _ = await attempt(["reset", "--soft", initialHEAD])
    }
    if !appliedStatesByRepositoryPath.isEmpty {
      _ = await attempt(["reset", "--quiet", initialHEAD, "--"] + packagePaths)
      let originalPathsResult = await attempt(["ls-tree", "-r", "--name-only", initialHEAD, "--"] + packagePaths)
      let originalPaths = originalPathsResult.output.split(separator: "\n").map(String.init)
      if !originalPaths.isEmpty {
        _ = await attempt(["restore", "--source", initialHEAD, "--worktree", "--"] + originalPaths)
      }
      _ = await attempt(["clean", "-f", "-d", "-x", "--"] + packagePaths)
    }

    if branchCreated {
      if initialBranch == "HEAD" {
        _ = await attempt(["switch", "--detach", initialHEAD])
      } else {
        _ = await attempt(["switch", initialBranch])
      }
      _ = await attempt(["branch", "-D", reviewBranchName])
    }
    return failures
  }

  private func externallyModifiedPackagePaths(
    rootURL: URL,
    appliedStatesByRepositoryPath: [String: LocalPublishFileState]
  ) -> [String] {
    appliedStatesByRepositoryPath.keys.sorted().filter { path in
      guard let expectedState = appliedStatesByRepositoryPath[path] else { return true }
      let currentURL = rootURL.appendingPathComponent(path.normalizedRelativePath())
      guard let currentState = try? localPublishFileState(at: currentURL, fileManager: fileManager) else {
        return true
      }
      return currentState != expectedState
    }
  }

  private func ensureBranchDoesNotExist(_ branchName: String, rootURL: URL) throws {
    let result = try runGit(
      ["rev-parse", "--verify", "--quiet", branchName],
      rootURL: rootURL,
      allowsExitCodes: [0, 1]
    )

    if result.terminationStatus == 0 {
      throw LocalGitPublishError.branchAlreadyExists(branchName)
    }
  }

  private func ensureBranchDoesNotExistAsync(_ branchName: String, rootURL: URL) async throws {
    let result = try await runGitAsync(
      ["rev-parse", "--verify", "--quiet", branchName],
      rootURL: rootURL,
      allowsExitCodes: [0, 1]
    )
    if result.terminationStatus == 0 {
      throw LocalGitPublishError.branchAlreadyExists(branchName)
    }
  }

  private func ensureGitWorkTree(rootURL: URL) throws {
    let result = gitCommandRunner.run(["rev-parse", "--is-inside-work-tree"], rootURL: rootURL)
    guard result.terminationStatus == 0,
          trimmedOutput(result) == "true" else {
      throw LocalGitPublishError.notGitRepository(rootURL.path)
    }
  }

  private func ensureGitWorkTreeAsync(rootURL: URL) async throws {
    let result = await gitCommandRunner.runAsync(["rev-parse", "--is-inside-work-tree"], rootURL: rootURL)
    guard result.terminationStatus == 0,
          trimmedOutput(result) == "true" else {
      throw LocalGitPublishError.notGitRepository(rootURL.path)
    }
  }

  private func trimmedOutput(_ result: GitCommandResult) -> String {
    result.output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func runGit(
    _ arguments: [String],
    rootURL: URL,
    allowsExitCodes: Set<Int32> = [0]
  ) throws -> GitCommandResult {
    let result = gitCommandRunner.run(arguments, rootURL: rootURL)
    if result.terminationStatus == 127 {
      throw LocalGitPublishError.processLaunchFailed(result.output)
    }

    guard allowsExitCodes.contains(result.terminationStatus) else {
      throw LocalGitPublishError.gitCommandFailed(
        command: (["git", "-C", rootURL.path] + arguments).map(posixShellQuote).joined(separator: " "),
        output: result.output
      )
    }

    return result
  }

  private func runGitAsync(
    _ arguments: [String],
    rootURL: URL,
    allowsExitCodes: Set<Int32> = [0]
  ) async throws -> GitCommandResult {
    let result = await gitCommandRunner.runAsync(arguments, rootURL: rootURL)
    if result.terminationStatus == 127 {
      throw LocalGitPublishError.processLaunchFailed(result.output)
    }
    guard allowsExitCodes.contains(result.terminationStatus) else {
      throw LocalGitPublishError.gitCommandFailed(
        command: (["git", "-C", rootURL.path] + arguments).map(posixShellQuote).joined(separator: " "),
        output: result.output
      )
    }
    return result
  }
}

public enum LocalGitPublishError: LocalizedError, Equatable {
  case missingRepositoryRoot
  case notGitRepository(String)
  case branchAlreadyExists(String)
  case repositoryHasStagedChanges([String])
  case packagePathsNotClean([String])
  case noStagedChanges
  case processLaunchFailed(String)
  case gitCommandFailed(command: String, output: String)
  case rollbackFailed(original: String, rollback: String)

  public var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot:
      return CoreL10n.text("未选择本地仓库。")
    case .notGitRepository(let path):
      return CoreL10n.format("当前目录不是 Git 仓库：%@", path)
    case .branchAlreadyExists(let branch):
      return CoreL10n.format("发布分支已存在：%@", branch)
    case .repositoryHasStagedChanges(let paths):
      return CoreL10n.format("仓库已有暂存内容，请先提交或取消暂存后再发布：%@", paths.joined(separator: CoreL10n.text("、")))
    case .packagePathsNotClean(let entries):
      return CoreL10n.format("发布目标路径存在未提交内容，为避免覆盖已停止发布：%@", entries.joined(separator: CoreL10n.text("；")))
    case .noStagedChanges:
      return CoreL10n.text("发布包没有产生新的 Git 变更。")
    case .processLaunchFailed(let message):
      return CoreL10n.format("无法启动 git：%@", message)
    case .gitCommandFailed(let command, let output):
      return CoreL10n.format("Git 命令失败：%@\n%@", command, output)
    case .rollbackFailed(let original, let rollback):
      return CoreL10n.format("发布失败，且自动恢复未完全成功。原始错误：%@\n恢复错误：%@", original, rollback)
    }
  }
}
