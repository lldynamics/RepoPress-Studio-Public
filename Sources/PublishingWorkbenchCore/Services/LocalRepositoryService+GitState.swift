import Foundation
import PublishingGitCore

struct RepositoryGitStatus {
  var branchStatus: RepositoryBranchStatus?
  var changedFiles: [RepositoryChangedFile]
  var remoteChangedFiles: [RepositoryChangedFile]
}
extension LocalRepositoryService {
  func gitStatus(rootURL: URL) -> RepositoryGitStatus {
    let result = gitCommandRunner.run(
      ["status", "--porcelain=v1", "--branch", "-z"],
      rootURL: rootURL
    )
    guard result.terminationStatus == 0 else {
      return RepositoryGitStatus(branchStatus: nil, changedFiles: [], remoteChangedFiles: [])
    }

    let output = result.standardOutput
    guard !output.isEmpty else {
      return RepositoryGitStatus(branchStatus: nil, changedFiles: [], remoteChangedFiles: [])
    }

    let parsedStatus = GitRepositoryOutputParser().parsePorcelainV1Status(output)
    let branchStatus = parsedStatus.branchStatus
    var changedFiles: [RepositoryChangedFile] = []
    for file in parsedStatus.changedFiles {
      var changedFile = file
      changedFile.lineDiff = diffForChangedFile(changedFile, rootURL: rootURL)
      changedFiles.append(changedFile)
    }

    let remoteChangedFiles = branchStatus?.upstreamName.flatMap {
      self.remoteChangedFiles(rootURL: rootURL, upstreamName: $0)
    } ?? []

    return RepositoryGitStatus(
      branchStatus: branchStatus,
      changedFiles: changedFiles,
      remoteChangedFiles: remoteChangedFiles
    )
  }

  func remoteChangedFiles(rootURL: URL, upstreamName: String) -> [RepositoryChangedFile] {
    let policy = RepositoryRemoteDiffCommandPolicy()
    guard let plan = policy.plan(
      for: RepositoryRemoteDiffCommandInput(upstreamName: upstreamName)
    ),
    let output = runGitOutput(plan.changedFilesArguments, rootURL: rootURL) else {
      return []
    }

    return GitRepositoryOutputParser().parseNameStatus(output).map { file in
      var changedFile = file
      if let arguments = plan.fileDiffArguments(for: file) {
        changedFile.lineDiff = runGitDiff(arguments, rootURL: rootURL)
      }
      return changedFile
    }
  }

  func remoteFileSnapshot(
    rootURL: URL,
    repositoryPath: String,
    repositoryProvider: RepositoryProvider
  ) -> RepositoryFileSnapshot? {
    remoteFileSnapshots(
      rootURL: rootURL,
      repositoryPaths: [repositoryPath],
      repositoryProvider: repositoryProvider
    ).first
  }

  /// Builds remote snapshots without constructing the full working-tree
  /// report. Resolving the configured upstream is one lightweight Git call;
  /// each requested path then performs only its safe content/version reads.
  /// This is intentionally shared by the single-file and batch entry points.
  func remoteFileSnapshots(
    rootURL: URL,
    repositoryPaths: [String],
    repositoryProvider: RepositoryProvider,
    cancellationCheck: @escaping @Sendable () -> Bool = { false }
  ) -> [RepositoryFileSnapshot] {
    guard !cancellationCheck() else {
      return []
    }
    guard let upstreamName = configuredUpstreamName(rootURL: rootURL) else {
      return []
    }

    let policy = RepositoryFileSnapshotCommandPolicy()
    var seenPaths = Set<String>()
    var snapshots: [RepositoryFileSnapshot] = []
    snapshots.reserveCapacity(repositoryPaths.count)

    for repositoryPath in repositoryPaths {
      guard !cancellationCheck() else {
        return snapshots
      }
      guard let plan = policy.plan(
        for: RepositoryFileSnapshotCommandInput(
          provider: repositoryProvider,
          upstreamName: upstreamName,
          exactRepositoryPath: repositoryPath
        )
      ), seenPaths.insert(plan.repositoryPath).inserted else {
        continue
      }
      guard let content = runGitOutput(plan.contentArguments, rootURL: rootURL) else {
        continue
      }
      guard !cancellationCheck() else {
        return snapshots
      }
      let repositorySHA = runGitOutput(plan.versionArguments, rootURL: rootURL)?
        .trimmedForPublishing
        .nilIfEmpty
      guard !cancellationCheck() else {
        return snapshots
      }
      snapshots.append(
        RepositoryFileSnapshot(
          refName: upstreamName,
          repositoryPath: plan.repositoryPath,
          content: content,
          repositorySHA: repositorySHA
        )
      )
    }

    return snapshots
  }

  private func configuredUpstreamName(rootURL: URL) -> String? {
    guard let rawName = runGitOutput(
      ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"],
      rootURL: rootURL
    )?.trimmedForPublishing.nilIfEmpty else {
      return nil
    }

    if rawName.hasPrefix("refs/remotes/") {
      return String(rawName.dropFirst("refs/remotes/".count))
    }
    if rawName.hasPrefix("remotes/") {
      return String(rawName.dropFirst("remotes/".count))
    }
    return rawName
  }

  func gitOriginRemote(rootURL: URL) -> RepositoryRemote? {
    guard let remoteURL = runGitOutput(["remote", "get-url", "origin"], rootURL: rootURL)?
      .trimmedForPublishing
      .nilIfEmpty else {
      return nil
    }

    return parseRepositoryRemote(remoteURL)
  }

}
