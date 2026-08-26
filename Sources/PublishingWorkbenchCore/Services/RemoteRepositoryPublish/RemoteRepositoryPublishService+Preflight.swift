import Foundation

extension RemoteRepositoryPublishService {
  /// Reads the configured target branch and validates every file in a direct
  /// publish package without making any remote mutation.
  ///
  /// The result contains every version conflict found in the package. Upsert
  /// files whose exact content is already present remotely are returned in
  /// `remoteVersionsByPath`, so callers can repair a missing or stale local
  /// baseline before invoking `publish`.
  public func preflight(
    package: PublishPackage,
    profile: SiteProfile,
    token: String?
  ) async throws -> RemoteRepositoryPublishPreflightResult {
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)
    let files = uniquePreflightFiles(package.files)

    try Task.checkCancellation()
    switch profile.repositoryProvider {
    case .github:
      return try await preflightGitHub(
        files: files,
        repository: repository,
        token: token
      )
    case .gitlab:
      return try await preflightGitLab(
        files: files,
        repository: repository,
        token: token
      )
    }
  }

  private func preflightGitHub(
    files: [(path: String, file: PublishPackageFile)],
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryPublishPreflightResult {
    var conflicts: [RemoteRepositoryPublishPreflightConflict] = []
    var remoteVersionsByPath: [String: String] = [:]

    for entry in files {
      try Task.checkCancellation()
      let path = entry.path
      let file = entry.file
      let remoteSHA = try await githubContentSHA(
        repository: repository,
        path: path,
        branch: repository.branch,
        token: token
      )
      try Task.checkCancellation()

      let content = file.operation == .upsert ? try contentData(for: file) : nil
      switch file.operation {
      case .upsert:
        let isAlreadyPublished = content.map {
          githubRemoteContentMatches(data: $0, remoteSHA: remoteSHA)
        } ?? false
        if isAlreadyPublished {
          if let remoteSHA = remoteSHA?.trimmedForPublishing.nilIfEmpty {
            remoteVersionsByPath[path] = remoteSHA
          }
        } else if let conflict = preflightVersionConflict(
          path: path,
          expectedSHA: file.expectedRemoteSHA,
          actualSHA: remoteSHA
        ) {
          conflicts.append(conflict)
        }

      case .delete:
        guard remoteSHA != nil else {
          // Deleting a file that is already absent is idempotent and safe.
          continue
        }
        guard !githubLegacyDeleteContentMatches(file: file, remoteSHA: remoteSHA) else {
          continue
        }
        if let conflict = preflightVersionConflict(
          path: path,
          expectedSHA: file.expectedRemoteSHA,
          actualSHA: remoteSHA
        ) {
          conflicts.append(conflict)
        }
      }
    }

    return RemoteRepositoryPublishPreflightResult(
      conflicts: conflicts,
      remoteVersionsByPath: remoteVersionsByPath
    )
  }

  private func preflightGitLab(
    files: [(path: String, file: PublishPackageFile)],
    repository: RemoteRepository,
    token: String
  ) async throws -> RemoteRepositoryPublishPreflightResult {
    var conflicts: [RemoteRepositoryPublishPreflightConflict] = []
    var remoteVersionsByPath: [String: String] = [:]

    for entry in files {
      try Task.checkCancellation()
      let path = entry.path
      let file = entry.file
      let remoteState = try await gitLabFileState(
        repository: repository,
        path: path,
        ref: repository.branch,
        token: token
      )
      try Task.checkCancellation()

      let content = file.operation == .upsert ? try contentData(for: file) : nil
      switch file.operation {
      case .upsert:
        let isAlreadyPublished = remoteState.exists && content == remoteState.content
        if isAlreadyPublished {
          if let lastCommitID = remoteState.lastCommitID?.trimmedForPublishing.nilIfEmpty {
            remoteVersionsByPath[path] = lastCommitID
          }
        } else if let conflict = preflightVersionConflict(
          path: path,
          expectedSHA: file.expectedRemoteSHA,
          actualSHA: remoteState.lastCommitID
        ) {
          conflicts.append(conflict)
        }

      case .delete:
        guard remoteState.exists else {
          // Deleting a file that is already absent is idempotent and safe.
          continue
        }
        guard !gitLabLegacyDeleteContentMatches(
          file: file,
          remoteContent: remoteState.content
        ) else {
          continue
        }
        if let conflict = preflightVersionConflict(
          path: path,
          expectedSHA: file.expectedRemoteSHA,
          actualSHA: remoteState.lastCommitID
        ) {
          conflicts.append(conflict)
        }
      }
    }

    return RemoteRepositoryPublishPreflightResult(
      conflicts: conflicts,
      remoteVersionsByPath: remoteVersionsByPath
    )
  }

  private func uniquePreflightFiles(
    _ files: [PublishPackageFile]
  ) -> [(path: String, file: PublishPackageFile)] {
    var seenPaths = Set<String>()
    var uniqueFiles: [(path: String, file: PublishPackageFile)] = []
    uniqueFiles.reserveCapacity(files.count)

    for file in files {
      let path = file.repositoryPath.normalizedRelativePath()
      guard !path.isEmpty, seenPaths.insert(path).inserted else {
        continue
      }
      uniqueFiles.append((path: path, file: file))
    }
    return uniqueFiles
  }

  private func preflightVersionConflict(
    path: String,
    expectedSHA: String?,
    actualSHA: String?
  ) -> RemoteRepositoryPublishPreflightConflict? {
    let expectedSHA = expectedSHA?.trimmedForPublishing.nilIfEmpty
    let actualSHA = actualSHA?.trimmedForPublishing.nilIfEmpty

    guard let expectedSHA else {
      guard let actualSHA else {
        return nil
      }
      return RemoteRepositoryPublishPreflightConflict(
        kind: .untrackedRemoteFile,
        path: path,
        actualSHA: actualSHA
      )
    }

    guard expectedSHA != actualSHA else {
      return nil
    }
    return RemoteRepositoryPublishPreflightConflict(
      kind: .remoteVersionConflict,
      path: path,
      expectedSHA: expectedSHA,
      actualSHA: actualSHA
    )
  }
}
