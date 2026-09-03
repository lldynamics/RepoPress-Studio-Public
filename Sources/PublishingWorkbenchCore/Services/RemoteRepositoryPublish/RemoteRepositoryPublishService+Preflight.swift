import Foundation

struct RemoteRepositoryPreflightFileSnapshot: Sendable {
  var version: String?
  var content: Data?
  var exists: Bool
}

struct RemoteRepositoryPreflightInspection: Sendable {
  var package: PublishPackage
  var result: RemoteRepositoryPublishPreflightResult
  var snapshotsByPath: [String: RemoteRepositoryPreflightFileSnapshot]
}

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
    try await preflightInspection(
      package: package,
      profile: profile,
      token: token
    ).result
  }

  func preflightInspection(
    package: PublishPackage,
    profile: SiteProfile,
    token: String?,
    ref: String? = nil
  ) async throws -> RemoteRepositoryPreflightInspection {
    try StructuralArticlePathPolicy.validate(package: package, profile: profile)
    let package = try normalizedPublishPackage(package)
    let token = try requiredToken(token)
    let repository = try remoteRepository(from: profile)
    let files = package.files.map { (path: $0.repositoryPath, file: $0) }

    try Task.checkCancellation()
    var inspection: RemoteRepositoryPreflightInspection
    switch profile.repositoryProvider {
    case .github:
      inspection = try await preflightGitHub(
        package: package,
        files: files,
        repository: repository,
        token: token,
        ref: ref ?? repository.branch
      )
    case .gitlab:
      inspection = try await preflightGitLab(
        package: package,
        files: files,
        repository: repository,
        token: token,
        ref: ref ?? repository.branch
      )
    }
    inspection.package = package
    return inspection
  }

  private func preflightGitHub(
    package: PublishPackage,
    files: [(path: String, file: PublishPackageFile)],
    repository: RemoteRepository,
    token: String,
    ref: String
  ) async throws -> RemoteRepositoryPreflightInspection {
    var conflicts: [RemoteRepositoryPublishPreflightConflict] = []
    var remoteVersionsByPath: [String: String] = [:]
    var snapshotsByPath: [String: RemoteRepositoryPreflightFileSnapshot] = [:]

    for entry in files {
      try Task.checkCancellation()
      let path = entry.path
      let file = entry.file
      let remoteState = try await githubFileState(
        repository: repository,
        path: path,
        ref: ref,
        token: token
      )
      try Task.checkCancellation()
      let remoteSHA = remoteState.sha
      snapshotsByPath[path] = RemoteRepositoryPreflightFileSnapshot(
        version: remoteSHA,
        content: remoteState.content,
        exists: remoteState.exists
      )

      let content = file.operation == .upsert ? try contentData(for: file) : nil
      switch file.operation {
      case .upsert:
        let isAlreadyPublished =
          content.map {
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

    let result = RemoteRepositoryPublishPreflightResult(
      conflicts: conflicts,
      remoteVersionsByPath: remoteVersionsByPath
    )
    return RemoteRepositoryPreflightInspection(
      package: package,
      result: result,
      snapshotsByPath: snapshotsByPath
    )
  }

  private func preflightGitLab(
    package: PublishPackage,
    files: [(path: String, file: PublishPackageFile)],
    repository: RemoteRepository,
    token: String,
    ref: String
  ) async throws -> RemoteRepositoryPreflightInspection {
    var conflicts: [RemoteRepositoryPublishPreflightConflict] = []
    var remoteVersionsByPath: [String: String] = [:]
    var snapshotsByPath: [String: RemoteRepositoryPreflightFileSnapshot] = [:]

    for entry in files {
      try Task.checkCancellation()
      let path = entry.path
      let file = entry.file
      let remoteState = try await gitLabFileState(
        repository: repository,
        path: path,
        ref: ref,
        token: token
      )
      try Task.checkCancellation()
      snapshotsByPath[path] = RemoteRepositoryPreflightFileSnapshot(
        version: remoteState.lastCommitID,
        content: remoteState.content,
        exists: remoteState.exists
      )

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
        guard
          !gitLabLegacyDeleteContentMatches(
            file: file,
            remoteContent: remoteState.content
          )
        else {
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

    let result = RemoteRepositoryPublishPreflightResult(
      conflicts: conflicts,
      remoteVersionsByPath: remoteVersionsByPath
    )
    return RemoteRepositoryPreflightInspection(
      package: package,
      result: result,
      snapshotsByPath: snapshotsByPath
    )
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
