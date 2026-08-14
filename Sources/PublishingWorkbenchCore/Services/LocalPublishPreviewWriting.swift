import Foundation

extension LocalPublishPreviewService {
  func writeWithEvidence(
    package: PublishPackage,
    rootURL: URL,
    preview: LocalPublishPreview? = nil
  ) throws -> LocalPublishWriteResult {
    try recoverInterruptedTransaction(at: rootURL)
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
        expectedSourceState = previewSourceStates?[normalizedPath]
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
        let destinationURL = prepared.file.operation == .delete
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
        switch prepared.file.operation {
        case .delete:
          if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
            rollbackEntries[index].didMutateDestination = true
          }
        case .upsert:
          switch prepared.file.kind {
          case .markdown:
            try (prepared.file.content ?? "").write(to: destinationURL, atomically: true, encoding: .utf8)
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

        let appliedState = try localPublishFileState(at: destinationURL, fileManager: fileManager)
        rollbackEntries[index].appliedState = appliedState
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
        if fileManager.fileExists(atPath: transactionURL.path) {
          try recoverInterruptedTransaction(at: rootURL)
        } else {
          try rollbackLocalPublishWrites(rollbackEntries)
        }
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
            let baselineState = diff.baselineState else {
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
            let sourceState = diff.sourceState else {
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
