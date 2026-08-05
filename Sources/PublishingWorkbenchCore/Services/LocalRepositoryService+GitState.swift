import Foundation

struct RepositoryGitStatus {
  var branchStatus: RepositoryBranchStatus?
  var changedFiles: [RepositoryChangedFile]
  var remoteChangedFiles: [RepositoryChangedFile]
}
extension LocalRepositoryService {
  func gitStatus(rootURL: URL) -> RepositoryGitStatus {
    let result = gitCommandRunner.run(["status", "--porcelain=v1", "--branch"], rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      return RepositoryGitStatus(branchStatus: nil, changedFiles: [], remoteChangedFiles: [])
    }

    let output = result.standardOutput
    guard !output.isEmpty else {
      return RepositoryGitStatus(branchStatus: nil, changedFiles: [], remoteChangedFiles: [])
    }

    var branchStatus: RepositoryBranchStatus?
    var changedFiles: [RepositoryChangedFile] = []

    for line in output.split(separator: "\n").map(String.init) {
      if line.hasPrefix("## ") {
        branchStatus = parseBranchStatusLine(line)
        continue
      }

      guard line.count >= 4 else { continue }
      let status = String(line.prefix(2))
      let pathStart = line.index(line.startIndex, offsetBy: 3)
      let path = String(line[pathStart...])
      let kind = changeKind(status: status)
      var changedFile = RepositoryChangedFile(status: status, path: path, kind: kind)
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
      ["diff", "--name-status", "HEAD...\(upstreamName)", "--"],
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
    output.split(separator: "\n").compactMap { line -> RepositoryChangedFile? in
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

  func gitOriginRemote(rootURL: URL) -> RepositoryRemote? {
    guard let remoteURL = runGitOutput(["remote", "get-url", "origin"], rootURL: rootURL)?
      .trimmedForPublishing
      .nilIfEmpty else {
      return nil
    }

    return parseRepositoryRemote(remoteURL)
  }

}
