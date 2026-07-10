import Foundation

public enum LocalGitPublishMode: String, Codable, Sendable {
  case directCommit
  case reviewBranch

  public var displayName: String {
    switch self {
    case .directCommit:
      return "直接提交"
    case .reviewBranch:
      return "发布分支提交"
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

public struct LocalGitPublishService {
  private let fileManager: FileManager
  private let previewService: LocalPublishPreviewService
  private let gitCommandRunner: GitCommandRunner

  public init(
    fileManager: FileManager = .default,
    previewService: LocalPublishPreviewService = LocalPublishPreviewService(),
    gitExecutablePath: String = "/usr/bin/git",
    gitCommandRunner: GitCommandRunner? = nil
  ) {
    self.fileManager = fileManager
    self.previewService = previewService
    self.gitCommandRunner = gitCommandRunner ?? GitCommandRunner(executableURL: URL(fileURLWithPath: gitExecutablePath))
  }

  public func publish(
    package: PublishPackage,
    profile: SiteProfile,
    mode: LocalGitPublishMode
  ) throws -> LocalGitPublishResult {
    guard let result = try profile.withLocalRepositoryRootAccess({ rootURL in
      try publish(package: package, profile: profile, rootURL: rootURL, mode: mode)
    }) else {
      throw LocalGitPublishError.missingRepositoryRoot
    }

    return result
  }

  private func publish(
    package: PublishPackage,
    profile: SiteProfile,
    rootURL: URL,
    mode: LocalGitPublishMode
  ) throws -> LocalGitPublishResult {
    guard directoryExists(rootURL.appendingPathComponent(".git", isDirectory: true)) else {
      throw LocalGitPublishError.notGitRepository(rootURL.path)
    }

    let currentBranch = try trimmedOutput(runGit(["rev-parse", "--abbrev-ref", "HEAD"], rootURL: rootURL))
    var commandLog: [String] = []
    var outputChunks: [String] = []

    if mode == .reviewBranch {
      try ensureBranchDoesNotExist(package.reviewBranchName, rootURL: rootURL)
      let switchResult = try runGit(["switch", "-c", package.reviewBranchName], rootURL: rootURL)
      commandLog.append("git switch -c \(posixShellQuote(package.reviewBranchName))")
      outputChunks.append(switchResult.output)
    }

    let writtenPaths = try previewService.write(package: package, rootURL: rootURL)
    let addResult = try runGit(["add"] + package.files.map(\.repositoryPath), rootURL: rootURL)
    commandLog.append("git add \(package.files.map(\.repositoryPath).map(posixShellQuote).joined(separator: " "))")
    outputChunks.append(addResult.output)

    let diffResult = try runGit(["diff", "--cached", "--quiet"], rootURL: rootURL, allowsExitCodes: [0, 1])
    if diffResult.terminationStatus == 0 {
      throw LocalGitPublishError.noStagedChanges
    }

    let commitResult = try runGit(["commit", "-m", package.commitMessage], rootURL: rootURL)
    commandLog.append("git commit -m \(posixShellQuote(package.commitMessage))")
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

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
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
}

public enum LocalGitPublishError: LocalizedError, Equatable {
  case missingRepositoryRoot
  case notGitRepository(String)
  case branchAlreadyExists(String)
  case noStagedChanges
  case processLaunchFailed(String)
  case gitCommandFailed(command: String, output: String)

  public var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot:
      return "未选择本地仓库。"
    case .notGitRepository(let path):
      return "当前目录不是 Git 仓库：\(path)"
    case .branchAlreadyExists(let branch):
      return "发布分支已存在：\(branch)"
    case .noStagedChanges:
      return "发布包没有产生新的 Git 变更。"
    case .processLaunchFailed(let message):
      return "无法启动 git：\(message)"
    case .gitCommandFailed(let command, let output):
      return "Git 命令失败：\(command)\n\(output)"
    }
  }
}
