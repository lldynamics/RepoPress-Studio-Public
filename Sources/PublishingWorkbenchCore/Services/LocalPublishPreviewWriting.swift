import CryptoKit
import Foundation

enum LocalPublishWritePurpose {
  case article(SiteProfile?)
  case structuralRepair(Set<String>)
}

private final class LocalPublishWriteCoordinator: @unchecked Sendable {
  static let shared = LocalPublishWriteCoordinator()
  let lock = NSRecursiveLock()
}

extension LocalPublishPreviewService {
  func withWriteLock<T>(_ work: () throws -> T) rethrows -> T {
    LocalPublishWriteCoordinator.shared.lock.lock()
    defer { LocalPublishWriteCoordinator.shared.lock.unlock() }
    return try work()
  }

  func writeWithEvidence(
    package: PublishPackage,
    rootURL: URL,
    preview: LocalPublishPreview? = nil,
    purpose: LocalPublishWritePurpose = .article(nil)
  ) throws -> LocalPublishWriteResult {
    try withWriteLock {
      try writeLocked(package: package, rootURL: rootURL, preview: preview, purpose: purpose)
    }
  }

  private func writeLocked(
    package: PublishPackage, rootURL: URL, preview: LocalPublishPreview?,
    purpose: LocalPublishWritePurpose
  ) throws -> LocalPublishWriteResult {
    switch purpose {
    case .article(let profile):
      for path in [package.markdownPath] + package.files.map(\.repositoryPath) {
        let protected =
          profile.map { StructuralArticlePathPolicy.isProtected(path, profile: $0) }
          ?? StructuralArticlePathPolicy.isSectionFile(path)
        if protected { throw StructuralArticlePathError.protectedPath(path) }
      }
      try recoverInterruptedTransaction(at: rootURL, articleProfile: profile)
    case .structuralRepair(let approvedPaths):
      guard !approvedPaths.isEmpty,
        Set(package.files.map(\.repositoryPath)) == approvedPaths,
        package.files.allSatisfy({
          $0.operation == .upsert && StructuralArticlePathPolicy.isSectionFile($0.repositoryPath)
        }),
        !fileManager.fileExists(atPath: localPublishTransactionURL(for: rootURL).path),
        !isSymbolicLink(localPublishTransactionURL(for: rootURL))
      else {
        throw LocalPublishPreviewError.recoveryFailed("栏目恢复范围或事务状态已变化，请重新扫描。")
      }
    }
    let previewBaseStates: [String: LocalPublishFileState]?
    let previewSourceStates: [String: LocalPublishSourceFileState]?
    if let preview {
      previewBaseStates = try expectedBaseStates(for: package, preview: preview)
      previewSourceStates = try expectedSourceStates(for: package, preview: preview)
    } else {
      previewBaseStates = nil
      previewSourceStates = nil
    }
    var seenDestinationPaths = Set<String>()
    let preparedWrites = try package.files.map { file -> PreparedLocalPublishWrite in
      guard !isGitControlPath(file.repositoryPath) else {
        throw LocalPublishPreviewError.unsafePath(file.repositoryPath)
      }
      let destinationURL = try validatedDestinationURLForWrite(
        rootURL: rootURL,
        repositoryPath: file.repositoryPath
      )
      guard seenDestinationPaths.insert(destinationURL.path).inserted else {
        throw LocalPublishPreviewError.unsafePath(file.repositoryPath)
      }

      if file.operation == .delete {
        return PreparedLocalPublishWrite(
          file: file,
          destinationURL: destinationURL,
          sourceURL: nil,
          expectedSourceState: nil
        )
      }

      let sourceURL: URL?
      let expectedSourceState: LocalPublishSourceFileState?
      switch file.kind {
      case .markdown:
        sourceURL = nil
        expectedSourceState = nil
      case .image, .video:
        guard let sourceFilePath = file.sourceFilePath else {
          throw LocalPublishPreviewError.missingSource(file.repositoryPath)
        }
        let candidate = URL(fileURLWithPath: sourceFilePath)
        let currentSourceState = try localPublishSourceFileState(
          at: candidate,
          repositoryPath: file.repositoryPath
        )
        let normalizedPath = file.repositoryPath.normalizedRelativePath()
        expectedSourceState = previewSourceStates?[normalizedPath] ?? currentSourceState
        if let expectedSourceState, currentSourceState != expectedSourceState {
          throw LocalPublishPreviewError.sourcePreviewOutdated(file.repositoryPath)
        }
        sourceURL = candidate
      }
      return PreparedLocalPublishWrite(
        file: file,
        destinationURL: destinationURL,
        sourceURL: sourceURL,
        expectedSourceState: expectedSourceState
      )
    }

    for prepared in preparedWrites {
      try validatePreviewBaseline(
        for: prepared.file,
        destinationURL: prepared.destinationURL,
        expectedBaseStates: previewBaseStates
      )
    }

    // Keep the rollback payload beside the journal in the repository. A
    // process restart cannot rely on the system temporary directory, and the
    // journal can validate that this directory is still app-owned.
    let rollbackDirectory = rootURL.standardizedFileURL
      .appendingPathComponent(
        ".repopress-local-publish-rollback-\(UUID().uuidString)",
        isDirectory: true
      )
    try fileManager.createDirectory(at: rollbackDirectory, withIntermediateDirectories: true)

    var writtenPaths: [String] = []
    var rollbackEntries: [LocalPublishRollbackEntry] = []
    var appliedStates: [LocalPublishFileState] = []
    let transactionURL = localPublishTransactionURL(for: rootURL)
    var transactionCommitted = false
    do {
      // Prepare every backup before the first destination is changed, then
      // persist the journal. A process stop at any later point can restore all
      // paths, including files that did not exist before this publish.
      for (index, prepared) in preparedWrites.enumerated() {
        guard !isGitControlPath(prepared.file.repositoryPath) else {
          throw LocalPublishPreviewError.unsafePath(prepared.file.repositoryPath)
        }
        let destinationURL = prepared.destinationURL
        try validatePreviewBaseline(
          for: prepared.file,
          destinationURL: destinationURL,
          expectedBaseStates: previewBaseStates
        )
        let backupURL: URL?
        if fileManager.fileExists(atPath: destinationURL.path) {
          let candidate = rollbackDirectory.appendingPathComponent("\(index)-backup")
          try fileManager.copyItem(at: destinationURL, to: candidate)
          backupURL = candidate
        } else {
          backupURL = nil
        }
        rollbackEntries.append(
          LocalPublishRollbackEntry(
            destinationURL: destinationURL,
            backupURL: backupURL,
            appliedState: nil,
            didMutateDestination: false
          )
        )
      }
      try persistLocalPublishTransaction(
        LocalPublishTransaction(
          phase: .applying,
          rollbackDirectoryPath: rollbackDirectory.path,
          entries: rollbackEntries.enumerated().map { index, entry in
            LocalPublishTransactionEntry(
              repositoryPath: preparedWrites[index].file.repositoryPath.normalizedRelativePath(),
              backupFileName: entry.backupURL?.lastPathComponent
            )
          }
        ),
        at: transactionURL
      )

      for (index, prepared) in preparedWrites.enumerated() {
        let destinationURL =
          prepared.file.operation == .delete
          ? prepared.destinationURL
          : try safeDestinationURLForWrite(
            rootURL: rootURL,
            repositoryPath: prepared.file.repositoryPath
          )
        try validatePreviewBaseline(
          for: prepared.file,
          destinationURL: destinationURL,
          expectedBaseStates: previewBaseStates
        )
        // Record the payload we intend to write, never adopt a post-write
        // observation: an external editor may already have replaced it.
        let appliedState: LocalPublishFileState
        if prepared.file.operation == .delete {
          appliedState = .missing
        } else if prepared.file.kind == .markdown {
          appliedState = .fileDigest(
            Data(SHA256.hash(data: Data((prepared.file.content ?? "").utf8))))
        } else if let sourceState = prepared.expectedSourceState {
          appliedState = .fileDigest(sourceState.sha256)
        } else {
          throw LocalPublishPreviewError.missingSource(prepared.file.repositoryPath)
        }
        rollbackEntries[index].appliedState = appliedState
        switch prepared.file.operation {
        case .delete:
          if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
            rollbackEntries[index].didMutateDestination = true
          }
        case .upsert:
          switch prepared.file.kind {
          case .markdown:
            try (prepared.file.content ?? "").write(
              to: destinationURL, atomically: true, encoding: .utf8)
          case .image, .video:
            guard let sourceURL = prepared.sourceURL else {
              throw LocalPublishPreviewError.missingSource(prepared.file.repositoryPath)
            }
            try replaceBinaryFileAtomically(
              sourceURL: sourceURL,
              expectedSourceState: prepared.expectedSourceState,
              destinationURL: destinationURL,
              repositoryPath: prepared.file.repositoryPath
            )
          }
          rollbackEntries[index].didMutateDestination = true
        }

        guard
          try localPublishFileState(at: destinationURL, fileManager: fileManager) == appliedState
        else {
          throw LocalPublishPreviewError.previewOutdated(prepared.file.repositoryPath)
        }
        appliedStates.append(appliedState)
        writtenPaths.append(prepared.file.repositoryPath)
      }
      try persistLocalPublishTransaction(
        LocalPublishTransaction(
          phase: .committed,
          rollbackDirectoryPath: rollbackDirectory.path,
          entries: rollbackEntries.enumerated().map { index, entry in
            LocalPublishTransactionEntry(
              repositoryPath: preparedWrites[index].file.repositoryPath.normalizedRelativePath(),
              backupFileName: entry.backupURL?.lastPathComponent
            )
          }
        ),
        at: transactionURL
      )
      transactionCommitted = true
      try fileManager.removeItem(at: transactionURL)
    } catch {
      if transactionCommitted {
        throw LocalPublishPreviewError.recoveryFailed(
          "本地文件已写入，但事务日志清理失败：\(error.localizedDescription)。日志保留在 \(transactionURL.path)"
        )
      }
      do {
        // If rollback is interrupted or detects an external change, a later
        // ordinary publish must not replay the original applying journal.
        if fileManager.fileExists(atPath: transactionURL.path) {
          try persistLocalPublishTransaction(
            LocalPublishTransaction(
              phase: .manualRecoveryRequired,
              rollbackDirectoryPath: rollbackDirectory.path,
              entries: rollbackEntries.enumerated().map { index, entry in
                LocalPublishTransactionEntry(
                  repositoryPath: preparedWrites[index].file.repositoryPath
                    .normalizedRelativePath(),
                  backupFileName: entry.backupURL?.lastPathComponent
                )
              }
            ), at: transactionURL)
        }
        // A live attempt knows which destinations it actually changed. The
        // crash journal also contains untouched files, including a file whose
        // external edit may have caused the preview check to fail. Never
        // replay that journal here; preserve external changes and keep the
        // journal/backups intact if an applied destination has also changed.
        try rollbackLocalPublishWrites(rollbackEntries)
      } catch let rollbackError {
        throw LocalPublishPreviewError.rollbackFailed(
          original: error.localizedDescription,
          rollback: rollbackError.localizedDescription
        )
      }
      do {
        if fileManager.fileExists(atPath: transactionURL.path) {
          try fileManager.removeItem(at: transactionURL)
        }
      } catch let cleanupError {
        throw LocalPublishPreviewError.rollbackFailed(
          original: error.localizedDescription,
          rollback: "文件已回滚，但事务日志清理失败：\(cleanupError.localizedDescription)"
        )
      }
      do {
        if fileManager.fileExists(atPath: rollbackDirectory.path) {
          try fileManager.removeItem(at: rollbackDirectory)
        }
      } catch let cleanupError {
        throw LocalPublishPreviewError.rollbackFailed(
          original: error.localizedDescription,
          rollback: "文件已回滚，但回滚目录清理失败：\(cleanupError.localizedDescription)"
        )
      }
      throw error
    }
    do {
      if fileManager.fileExists(atPath: rollbackDirectory.path) {
        try fileManager.removeItem(at: rollbackDirectory)
      }
    } catch let cleanupError {
      throw LocalPublishPreviewError.recoveryFailed(
        "本地文件已写入，但回滚目录清理失败：\(cleanupError.localizedDescription)。目录保留在 \(rollbackDirectory.path)"
      )
    }
    return LocalPublishWriteResult(
      writtenPaths: writtenPaths,
      appliedStatesByRepositoryPath: Dictionary(
        uniqueKeysWithValues: zip(
          writtenPaths,
          appliedStates
        )
      )
    )
  }

  private func expectedBaseStates(
    for package: PublishPackage,
    preview: LocalPublishPreview
  ) throws -> [String: LocalPublishFileState] {
    guard preview.package == package else {
      throw LocalPublishPreviewError.invalidPreview("发布包已变化")
    }

    var result: [String: LocalPublishFileState] = [:]
    for file in package.files {
      let normalizedPath = file.repositoryPath.normalizedRelativePath()
      guard result[normalizedPath] == nil,
        let diff = preview.fileDiffs.first(where: {
          $0.path.normalizedRelativePath() == normalizedPath
        }),
        let baselineState = diff.baselineState
      else {
        throw LocalPublishPreviewError.invalidPreview(file.repositoryPath)
      }
      result[normalizedPath] = baselineState
    }
    return result
  }

  private func expectedSourceStates(
    for package: PublishPackage,
    preview: LocalPublishPreview
  ) throws -> [String: LocalPublishSourceFileState] {
    var result: [String: LocalPublishSourceFileState] = [:]
    for file in package.files where file.operation == .upsert && file.kind != .markdown {
      let normalizedPath = file.repositoryPath.normalizedRelativePath()
      guard result[normalizedPath] == nil,
        let diff = preview.fileDiffs.first(where: {
          $0.path.normalizedRelativePath() == normalizedPath
        }),
        let sourceState = diff.sourceState
      else {
        throw LocalPublishPreviewError.invalidPreview(file.repositoryPath)
      }
      result[normalizedPath] = sourceState
    }
    return result
  }

  private func validatePreviewBaseline(
    for file: PublishPackageFile,
    destinationURL: URL,
    expectedBaseStates: [String: LocalPublishFileState]?
  ) throws {
    guard let expectedBaseStates else { return }
    let normalizedPath = file.repositoryPath.normalizedRelativePath()
    guard let expectedState = expectedBaseStates[normalizedPath] else {
      throw LocalPublishPreviewError.invalidPreview(file.repositoryPath)
    }
    let currentState = try localPublishFileState(at: destinationURL, fileManager: fileManager)
    guard currentState == expectedState else {
      throw LocalPublishPreviewError.previewOutdated(file.repositoryPath)
    }
  }

}
