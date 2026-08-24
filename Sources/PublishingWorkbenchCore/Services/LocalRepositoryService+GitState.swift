import Foundation

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

    let parsedStatus = parsePorcelainStatus(output)
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
    guard let output = runGitOutput(
      ["diff", "-M", "--name-status", "-z", "HEAD...\(upstreamName)", "--"],
      rootURL: rootURL
    ) else {
      return []
    }

    return parseNameStatus(output).map { file in
      var changedFile = file
      changedFile.lineDiff = remoteDiffForChangedFile(file, upstreamName: upstreamName, rootURL: rootURL)
      return changedFile
    }
  }

  func remoteDiffForChangedFile(
    _ file: RepositoryChangedFile,
    upstreamName: String,
    rootURL: URL
  ) -> String? {
    runGitDiff(["diff", "HEAD...\(upstreamName)", "--", file.displayPath], rootURL: rootURL)
  }

  func remoteFileSnapshot(
    rootURL: URL,
    repositoryPath: String,
    repositoryProvider: RepositoryProvider
  ) -> RepositoryFileSnapshot? {
    let status = gitStatus(rootURL: rootURL)
    guard let upstreamName = status.branchStatus?.upstreamName?.nilIfEmpty,
          let safePath = safeRepositoryFilePath(repositoryPath),
          let content = runGitOutput(["show", "\(upstreamName):\(safePath)"], rootURL: rootURL) else {
      return nil
    }
    let repositorySHA = remoteFileVersionSHA(
      rootURL: rootURL,
      upstreamName: upstreamName,
      repositoryPath: safePath,
      repositoryProvider: repositoryProvider
    )

    return RepositoryFileSnapshot(
      refName: upstreamName,
      repositoryPath: safePath,
      content: content,
      repositorySHA: repositorySHA
    )
  }

  func remoteFileVersionSHA(
    rootURL: URL,
    upstreamName: String,
    repositoryPath: String,
    repositoryProvider: RepositoryProvider
  ) -> String? {
    switch repositoryProvider {
    case .github:
      return runGitOutput(["rev-parse", "\(upstreamName):\(repositoryPath)"], rootURL: rootURL)?
        .trimmedForPublishing
        .nilIfEmpty
    case .gitlab:
      return runGitOutput(["log", "-n", "1", "--format=%H", upstreamName, "--", repositoryPath], rootURL: rootURL)?
        .trimmedForPublishing
        .nilIfEmpty
    }
  }

  func safeRepositoryFilePath(_ repositoryPath: String) -> String? {
    let displayPath = repositoryPath.components(separatedBy: " -> ").last?.trimmedForPublishing ?? repositoryPath.trimmedForPublishing
    guard !displayPath.isEmpty,
          !displayPath.hasPrefix("/"),
          !displayPath.contains("\\"),
          !displayPath.contains("://") else {
      return nil
    }

    let normalizedPath = displayPath.normalizedRelativePath()
    guard !normalizedPath.isEmpty,
          !normalizedPath.split(separator: "/").contains("..") else {
      return nil
    }

    return normalizedPath
  }

  func parseNameStatus(_ output: String) -> [RepositoryChangedFile] {
    if output.contains("\0") {
      return parseNULNameStatus(output)
    }

    return output.split(separator: "\n").compactMap { line -> RepositoryChangedFile? in
      let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard let status = parts.first?.nilIfEmpty, parts.count >= 2 else {
        return nil
      }

      let path: String
      if status.hasPrefix("R"), parts.count >= 3 {
        path = "\(parts[1]) -> \(parts[2])"
      } else {
        path = parts[1]
      }

      return RepositoryChangedFile(status: status, path: path, kind: changeKind(status: status))
    }
  }

  private func parsePorcelainStatus(
    _ output: String
  ) -> (branchStatus: RepositoryBranchStatus?, changedFiles: [RepositoryChangedFile]) {
    // `git status --porcelain=v1 -z` emits a branch header followed by NUL
    // separated records. Rename/copy records put the destination in the
    // status record and the source in the following NUL-delimited field.
    let fields = output
      .split(separator: "\0", omittingEmptySubsequences: true)
      .map(String.init)
    var branchStatus: RepositoryBranchStatus?
    var changedFiles: [RepositoryChangedFile] = []
    var index = 0

    while index < fields.count {
      let field = fields[index]
      index += 1

      if field.hasPrefix("## ") {
        branchStatus = parseBranchStatusLine(field)
        continue
      }

      guard field.count >= 4 else { continue }
      let status = String(field.prefix(2))
      let path = String(field.dropFirst(3))
      guard !path.isEmpty else { continue }

      var normalizedPath = path
      if isRenameOrCopyStatus(status), index < fields.count {
        let sourcePath = fields[index]
        index += 1
        normalizedPath = "\(sourcePath) -> \(path)"
      }

      changedFiles.append(
        RepositoryChangedFile(
          status: status,
          path: normalizedPath,
          kind: changeKind(status: status)
        )
      )
    }

    return (branchStatus, changedFiles)
  }

  private func parseNULNameStatus(_ output: String) -> [RepositoryChangedFile] {
    // `git diff --name-status -z` emits status, path, and (for rename/copy)
    // the second path as independent NUL-delimited fields. This avoids Git's
    // quotePath octal escaping and remains safe for spaces, quotes, and UTF-8.
    let fields = output
      .split(separator: "\0", omittingEmptySubsequences: true)
      .map(String.init)
    var files: [RepositoryChangedFile] = []
    var index = 0

    while index < fields.count {
      let status = fields[index]
      index += 1
      guard !status.isEmpty, index < fields.count else { break }

      let sourceOrPath = fields[index]
      index += 1
      var path = sourceOrPath
      if isRenameOrCopyStatus(status) {
        guard index < fields.count else { break }
        let destinationPath = fields[index]
        index += 1
        path = "\(sourceOrPath) -> \(destinationPath)"
      }

      files.append(
        RepositoryChangedFile(
          status: status,
          path: path,
          kind: changeKind(status: status)
        )
      )
    }

    return files
  }

  private func isRenameOrCopyStatus(_ status: String) -> Bool {
    status.contains("R") || status.contains("C")
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
