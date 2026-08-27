import Foundation

extension SiteStarterService {
  public func configureGitHubOriginRemoteAsync(profile: SiteProfile) async throws -> String {
    guard let rootURL = profile.localRepositoryRootURL else {
      throw SiteStarterError.missingRepositoryRoot
    }
    guard fileManager.fileExists(atPath: rootURL.appendingPathComponent(".git", isDirectory: true).path) else {
      throw SiteStarterError.notGitRepository(rootURL.path)
    }
    guard let remoteURL = githubRemoteURL(
      owner: profile.repoOwner.trimmedForPublishing,
      repoName: profile.repoName.trimmedForPublishing
    ) else {
      throw SiteStarterError.missingOriginRemote
    }

    let existingRemote = await gitCommandRunner.runAsync(
      ["remote", "get-url", "origin"],
      rootURL: rootURL
    )
    let arguments = existingRemote.terminationStatus == 0
      ? ["remote", "set-url", "origin", remoteURL]
      : ["remote", "add", "origin", remoteURL]
    let result = await gitCommandRunner.runAsync(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw SiteStarterError.gitFailed(result.output)
    }
    return remoteURL
  }

  func initializeGitRepository(at rootURL: URL, branch: String) throws {
    do {
      try runGit(["init", "-b", branch], at: rootURL)
    } catch {
      try runGit(["init"], at: rootURL)
      try runGit(["checkout", "-B", branch], at: rootURL)
    }
  }

  func addOriginRemote(_ remoteURL: String, at rootURL: URL) throws {
    do {
      try runGit(["remote", "add", "origin", remoteURL], at: rootURL)
    } catch {
      try runGit(["remote", "set-url", "origin", remoteURL], at: rootURL)
    }
  }

  func runGit(_ arguments: [String], at rootURL: URL) throws {
    _ = try runGitOutput(arguments, at: rootURL)
  }

  func runGitOutput(_ arguments: [String], at rootURL: URL) throws -> String {
    let result = gitCommandRunner.run(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw SiteStarterError.gitFailed(result.output)
    }
    return result.standardOutput
  }

  func runGitOutputAsync(_ arguments: [String], at rootURL: URL) async throws -> String {
    let result = await gitCommandRunner.runAsync(arguments, rootURL: rootURL)
    guard result.terminationStatus == 0 else {
      throw SiteStarterError.gitFailed(result.output)
    }
    return result.standardOutput
  }

  func validatedStarterPaths(_ paths: [String]) throws -> [String] {
    let normalized = Array(Set(paths.map { $0.trimmedForPublishing }))
      .filter { !$0.isEmpty }
      .sorted()
    guard !normalized.isEmpty else {
      throw SiteStarterError.missingStarterFileManifest
    }
    for path in normalized where !isSafeRelativePath(path) {
      throw SiteStarterError.unsafePath(path)
    }
    return normalized
  }

  func rejectUnrelatedStagedChanges(starterPaths: [String], at rootURL: URL) throws {
    let stagedPaths = try runGitOutput(["diff", "--cached", "--name-only"], at: rootURL)
      .split(separator: "\n")
      .map { String($0).trimmedForPublishing }
      .filter { !$0.isEmpty }
    let unrelatedPaths = stagedPaths.filter { !starterPaths.contains($0) }
    guard unrelatedPaths.isEmpty else {
      throw SiteStarterError.unrelatedStagedChanges(unrelatedPaths.sorted())
    }
  }

  func rejectUnrelatedStagedChangesAsync(starterPaths: [String], at rootURL: URL) async throws {
    let stagedPaths = try await runGitOutputAsync(["diff", "--cached", "--name-only"], at: rootURL)
      .split(separator: "\n")
      .map { String($0).trimmedForPublishing }
      .filter { !$0.isEmpty }
    let unrelatedPaths = stagedPaths.filter { !starterPaths.contains($0) }
    guard unrelatedPaths.isEmpty else {
      throw SiteStarterError.unrelatedStagedChanges(unrelatedPaths.sorted())
    }
  }

  func stagedFileObjectIDs(
    paths: [String],
    at rootURL: URL
  ) async throws -> [String: String] {
    var objectIDs: [String: String] = [:]
    objectIDs.reserveCapacity(paths.count)

    for path in paths {
      let output = try await runGitOutputAsync(
        ["ls-files", "--stage", "--", path],
        at: rootURL
      )
      let entries = output.split(separator: "\n", omittingEmptySubsequences: true)
      guard entries.count <= 1 else {
        throw SiteStarterError.starterPushConfirmationChanged
      }
      guard let entry = entries.first else {
        objectIDs[path] = "<deleted>"
        continue
      }
      let fields = entry.split(
        maxSplits: 3,
        omittingEmptySubsequences: true,
        whereSeparator: { $0 == " " || $0 == "\t" }
      )
      guard fields.count == 4, fields[2] == "0", !fields[1].isEmpty else {
        throw SiteStarterError.starterPushConfirmationChanged
      }
      objectIDs[path] = String(fields[1])
    }

    return objectIDs
  }

  func optionalGitOutput(_ arguments: [String], at rootURL: URL) -> String? {
    (try? runGitOutput(arguments, at: rootURL))?.nilIfEmpty
  }

  func parseGitHubRemote(_ remoteURL: String) -> (owner: String, repo: String)? {
    let trimmed = remoteURL.trimmedForPublishing
    let patterns = [
      #"^git@github\.com:([^/]+)/(.+?)(?:\.git)?$"#,
      #"^github\.com:([^/]+)/(.+?)(?:\.git)?$"#,
      #"^https://github\.com/([^/]+)/(.+?)(?:\.git)?$"#,
      #"^ssh://git@github\.com/([^/]+)/(.+?)(?:\.git)?$"#,
    ]

    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
              in: trimmed,
              range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            ),
            match.numberOfRanges == 3,
            let ownerRange = Range(match.range(at: 1), in: trimmed),
            let repoRange = Range(match.range(at: 2), in: trimmed) else {
        continue
      }
      return (
        owner: String(trimmed[ownerRange]),
        repo: String(trimmed[repoRange]).replacingOccurrences(of: ".git", with: "")
      )
    }
    return nil
  }

  func nextCommands(
    rootURL: URL,
    branch: String,
    owner: String,
    repoName: String,
    remoteURL: String?,
    createdFilePaths: [String]
  ) -> [String] {
    let addCommand = (["git", "add", "--"] + createdFilePaths.sorted())
      .map(posixShellQuote)
      .joined(separator: " ")
    var commands = [
      "cd \(posixShellQuote(rootURL.path))",
      addCommand,
      "git commit -m \(posixShellQuote("Initial site"))",
    ]

    if remoteURL == nil, !owner.isEmpty, !repoName.isEmpty {
      commands.append("git remote add origin \(posixShellQuote("git@github.com:\(owner)/\(repoName).git"))")
    }
    if !owner.isEmpty, !repoName.isEmpty {
      commands.append("git push -u origin \(posixShellQuote(branch))")
    } else {
      commands.append("gh repo create <owner>/<repo> --private --source . --remote origin --push")
    }
    return commands
  }

  func importedRepositoryNextCommands(
    rootURL: URL,
    branch: String,
    owner: String,
    repoName: String
  ) -> [String] {
    var commands = [
      "cd \(posixShellQuote(rootURL.path))",
      "git status --short",
    ]
    if !owner.isEmpty, !repoName.isEmpty {
      commands.append("git push -u origin \(posixShellQuote(branch))")
    } else {
      commands.append("确认远程仓库后再执行 git push")
    }
    return commands
  }

  func githubRemoteURL(owner: String, repoName: String) -> String? {
    guard !owner.isEmpty, !repoName.isEmpty else { return nil }
    return "git@github.com:\(owner)/\(repoName).git"
  }

  func isSafeRelativePath(_ path: String) -> Bool {
    !path.isEmpty
      && !path.hasPrefix("/")
      && !path.split(separator: "/").contains("..")
  }
}
