import Foundation

extension LocalPublishPreviewService {
  static let maximumTransactionByteCount = 1_048_576

  func replaceBinaryFileAtomically(
    sourceURL: URL,
    expectedSourceState: LocalPublishSourceFileState?,
    destinationURL: URL,
    repositoryPath: String,
    requiresMissingDestination: Bool = false
  ) throws {
    let stagingURL =
      destinationURL
      .deletingLastPathComponent()
      .appendingPathComponent(
        ".\(destinationURL.lastPathComponent).publisher-stage-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: stagingURL) }

    #if canImport(Darwin)
      let stagingDescriptor = stagingURL.path.withCString {
        Darwin.open(
          $0,
          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
          mode_t(S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        )
      }
      guard stagingDescriptor >= 0 else {
        throw LocalPublishPreviewError.unsafePath(repositoryPath)
      }
      var stagingDescriptorIsOpen = true
      defer {
        if stagingDescriptorIsOpen {
          Darwin.close(stagingDescriptor)
        }
      }

      let copiedSourceState = try withLocalPublishSourceDescriptor(
        at: sourceURL,
        repositoryPath: repositoryPath
      ) { sourceDescriptor in
        try readLocalPublishSource(
          descriptor: sourceDescriptor,
          repositoryPath: repositoryPath,
          destinationDescriptor: stagingDescriptor
        )
      }
      if let expectedSourceState, copiedSourceState != expectedSourceState {
        throw LocalPublishPreviewError.sourcePreviewOutdated(repositoryPath)
      }
      guard Darwin.fsync(stagingDescriptor) == 0 else {
        throw LocalPublishPreviewError.unsafeSource(repositoryPath)
      }
      Darwin.close(stagingDescriptor)
      stagingDescriptorIsOpen = false
    #else
      let data = try BoundedFileReader.data(
        at: sourceURL,
        maximumByteCount: WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount
      )
      let copiedSourceState = try localPublishSourceFileState(
        at: sourceURL,
        repositoryPath: repositoryPath
      )
      guard expectedSourceState == nil || copiedSourceState == expectedSourceState else {
        throw LocalPublishPreviewError.sourcePreviewOutdated(repositoryPath)
      }
      try data.write(to: stagingURL, options: .withoutOverwriting)
    #endif

    if requiresMissingDestination {
      try moveRecoveryFileExclusively(from: stagingURL, to: destinationURL)
    } else if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
    } else {
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }
  }

  /// rename with NOREPLACE semantics closes the existence-check/write gap.
  private func moveRecoveryFileExclusively(from source: URL, to destination: URL) throws {
    #if canImport(Darwin)
      let result = source.path.withCString { sourcePath in
        destination.path.withCString { destinationPath in
          Darwin.renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL))
        }
      }
      guard result == 0 else {
        throw LocalPublishPreviewError.rollbackConflict(destination.path)
      }
    #else
      try fileManager.moveItem(at: source, to: destination)
    #endif
  }

  func localPublishTransactionURL(for rootURL: URL) -> URL {
    rootURL.standardizedFileURL.appendingPathComponent(Self.transactionFileName)
  }

  /// A local publish package may write site content, but it must never write
  /// Git's control plane.  Keep this check independent from the filesystem's
  /// case-sensitivity so a transaction crafted on a case-insensitive volume
  /// cannot be replayed as a different path on another volume.
  func isGitControlPath(_ repositoryPath: String) -> Bool {
    let pathForComparison =
      repositoryPath
      .replacingOccurrences(of: "\\", with: "/")
      .normalizedRelativePath()
    return
      pathForComparison
      .split(separator: "/")
      .contains { String($0).caseInsensitiveCompare(".git") == .orderedSame }
  }

  func persistLocalPublishTransaction(
    _ transaction: LocalPublishTransaction,
    at url: URL
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(transaction).write(to: url, options: [.atomic])
    let handle = try FileHandle(forWritingTo: url)
    try handle.synchronize()
    try handle.close()
  }

  func recoverInterruptedTransaction(
    at rootURL: URL,
    beforeDestinationIsolation: ((URL) throws -> Void)? = nil,
    afterDestinationIsolation: ((URL) throws -> Void)? = nil
  ) throws {
    let transactionURL = localPublishTransactionURL(for: rootURL)
    guard fileManager.fileExists(atPath: transactionURL.path) else { return }
    do {
      guard !isSymbolicLink(transactionURL) else {
        throw LocalPublishPreviewError.recoveryFailed("事务日志不能是符号链接")
      }
      let data = try BoundedFileReader.data(
        at: transactionURL,
        maximumByteCount: Self.maximumTransactionByteCount
      )
      let transaction = try JSONDecoder().decode(LocalPublishTransaction.self, from: data)
      let root = rootURL.standardizedFileURL
      let rollbackDirectory = URL(fileURLWithPath: transaction.rollbackDirectoryPath)
        .standardizedFileURL
      guard rollbackDirectory.deletingLastPathComponent() == root,
        rollbackDirectory.lastPathComponent.hasPrefix(".repopress-local-publish-rollback-"),
        !isSymbolicLink(rollbackDirectory)
      else {
        throw LocalPublishPreviewError.recoveryFailed("恢复目录不在本地仓库内")
      }
      if fileManager.fileExists(atPath: rollbackDirectory.path),
        try fileManager.contentsOfDirectory(atPath: rollbackDirectory.path)
          .contains(where: { $0.hasPrefix("recovery-current-") })
      {
        // A crash or concurrent save during isolation must keep both copies.
        // Never let an apparently restored target silently discard evidence.
        throw LocalPublishPreviewError.recoveryFailed("恢复隔离文件待核对：\(rollbackDirectory.path)")
      }

      // Validate the complete journal and every referenced backup before
      // changing any destination. A forged or incomplete entry later in the
      // list must not allow an earlier content path to be removed first.
      var preparedRecoveries: [PreparedLocalPublishRecovery] = []
      var seenDestinations = Set<String>()
      for entry in transaction.entries {
        guard !isGitControlPath(entry.repositoryPath) else {
          throw LocalPublishPreviewError.recoveryFailed("恢复路径属于 Git 管理目录：\(entry.repositoryPath)")
        }
        let destinationURL = try validatedDestinationURLForWrite(
          rootURL: root,
          repositoryPath: entry.repositoryPath
        )
        guard seenDestinations.insert(destinationURL.path).inserted else {
          throw LocalPublishPreviewError.unsafePath(entry.repositoryPath)
        }
        let backupURL: URL?
        if let backupFileName = entry.backupFileName {
          guard !backupFileName.contains("/"),
            !backupFileName.contains("\\"),
            !backupFileName.contains("..")
          else {
            throw LocalPublishPreviewError.recoveryFailed("恢复备份路径不安全")
          }
          let candidate = rollbackDirectory.appendingPathComponent(backupFileName)
            .standardizedFileURL
          guard candidate.deletingLastPathComponent() == rollbackDirectory,
            fileManager.fileExists(atPath: candidate.path),
            !isSymbolicLink(candidate)
          else {
            throw LocalPublishPreviewError.recoveryFailed("恢复备份文件缺失：\(entry.repositoryPath)")
          }
          var backupIsDirectory: ObjCBool = false
          guard fileManager.fileExists(atPath: candidate.path, isDirectory: &backupIsDirectory),
            !backupIsDirectory.boolValue
          else {
            throw LocalPublishPreviewError.recoveryFailed("恢复备份文件不是普通文件：\(entry.repositoryPath)")
          }
          backupURL = candidate
        } else {
          backupURL = nil
        }
        // Committed journals only need validated cleanup paths; content may
        // legitimately have changed since the completed publish.
        guard transaction.phase == .applying else { continue }
        let backupSourceState = try backupURL.map {
          try localPublishSourceFileState(at: $0, repositoryPath: entry.repositoryPath)
        }
        let originalState: LocalPublishFileState =
          backupSourceState.map { .fileDigest($0.sha256) } ?? .missing
        let observedState = try localPublishFileState(at: destinationURL, fileManager: fileManager)
        if transaction.phase == .applying {
          // Check the entire transaction before touching any file. A legacy
          // journal has no proof of what it wrote, so changed files are kept.
          guard entry.originalState == nil || entry.originalState == originalState,
            observedState == originalState
              || (entry.originalState != nil && observedState == entry.intendedState)
          else {
            throw LocalPublishPreviewError.rollbackConflict(entry.repositoryPath)
          }
        }
        preparedRecoveries.append(
          PreparedLocalPublishRecovery(
            destinationURL: destinationURL,
            backupURL: backupURL,
            originalState: originalState,
            observedState: observedState,
            backupSourceState: backupSourceState
          )
        )
      }

      if transaction.phase == .committed {
        if fileManager.fileExists(atPath: rollbackDirectory.path) {
          try fileManager.removeItem(at: rollbackDirectory)
        }
        try fileManager.removeItem(at: transactionURL)
        return
      }

      for recovery in preparedRecoveries.reversed() {
        let currentState = try localPublishFileState(
          at: recovery.destinationURL, fileManager: fileManager)
        guard currentState == recovery.observedState else {
          throw LocalPublishPreviewError.rollbackConflict(recovery.destinationURL.path)
        }
        // Also makes recovery restartable if a prior recovery was interrupted.
        guard currentState != recovery.originalState else { continue }
        try beforeDestinationIsolation?(recovery.destinationURL)
        let isolatedURL = rollbackDirectory.appendingPathComponent("recovery-current-\(UUID())")
        var hasIsolatedDestination = false
        do {
          if currentState != .missing {
            // Capture the actual path atomically, then validate the captured
            // bytes. A save after the earlier digest check is preserved.
            try moveRecoveryFileExclusively(from: recovery.destinationURL, to: isolatedURL)
            hasIsolatedDestination = true
            guard
              try localPublishFileState(at: isolatedURL, fileManager: fileManager) == currentState
            else { throw LocalPublishPreviewError.rollbackConflict(recovery.destinationURL.path) }
          }
          try afterDestinationIsolation?(recovery.destinationURL)
          if let backupURL = recovery.backupURL {
            try fileManager.createDirectory(
              at: recovery.destinationURL.deletingLastPathComponent(),
              withIntermediateDirectories: true
            )
            try replaceBinaryFileAtomically(
              sourceURL: backupURL,
              expectedSourceState: recovery.backupSourceState,
              destinationURL: recovery.destinationURL,
              repositoryPath: recovery.destinationURL.path,
              requiresMissingDestination: true
            )
          }
          if hasIsolatedDestination {
            guard
              try localPublishFileState(at: isolatedURL, fileManager: fileManager) == currentState
            else { throw LocalPublishPreviewError.rollbackConflict(recovery.destinationURL.path) }
            try fileManager.removeItem(at: isolatedURL)
          }
        } catch {
          if hasIsolatedDestination, fileManager.fileExists(atPath: isolatedURL.path) {
            // Restore only into an empty path. A newer destination wins and
            // the isolated copy stays beside the journal for manual recovery.
            do {
              try moveRecoveryFileExclusively(from: isolatedURL, to: recovery.destinationURL)
            } catch {
              throw LocalPublishPreviewError.recoveryFailed("并发修改已保留，需核对：\(isolatedURL.path)")
            }
          }
          throw error
        }
      }
      try fileManager.removeItem(at: rollbackDirectory)
      try fileManager.removeItem(at: transactionURL)
    } catch let error as LocalPublishPreviewError {
      throw error
    } catch {
      throw LocalPublishPreviewError.recoveryFailed(error.localizedDescription)
    }
  }

  /// Reports persisted recovery state without mutating the repository. The
  /// next write remains responsible for performing the actual recovery.
  func interruptedTransactionIssue(at rootURL: URL) -> PreflightIssue? {
    let transactionURL = localPublishTransactionURL(for: rootURL)
    guard fileManager.fileExists(atPath: transactionURL.path) else { return nil }

    do {
      guard !isSymbolicLink(transactionURL) else {
        throw LocalPublishPreviewError.recoveryFailed("事务日志不能是符号链接")
      }
      let data = try BoundedFileReader.data(
        at: transactionURL,
        maximumByteCount: Self.maximumTransactionByteCount
      )
      let transaction = try JSONDecoder().decode(LocalPublishTransaction.self, from: data)
      let message =
        switch transaction.phase {
        case .applying:
          CoreL10n.text("检测到上一次写入中断；再次写入前会先自动恢复原文件。")
        case .committed:
          CoreL10n.text("上一次文件写入已完成，但事务清理尚未完成；再次写入前会先清理。")
        }
      return PreflightIssue(
        severity: .warning,
        title: CoreL10n.text("发现未完成的本地发布事务"),
        message: message,
        field: "repository"
      )
    } catch {
      return PreflightIssue(
        severity: .error,
        title: CoreL10n.text("本地发布事务无法恢复"),
        message: CoreL10n.format("事务日志读取失败，已阻止继续写入：%@", error.localizedDescription),
        field: "repository"
      )
    }
  }

  func rollbackLocalPublishWrites(_ entries: [LocalPublishRollbackEntry]) throws {
    for entry in entries.reversed() {
      guard entry.didMutateDestination else { continue }
      guard let appliedState = entry.appliedState else {
        throw LocalPublishPreviewError.rollbackConflict(entry.destinationURL.path)
      }
      let currentState = try localPublishFileState(
        at: entry.destinationURL, fileManager: fileManager)
      guard currentState == appliedState else {
        throw LocalPublishPreviewError.rollbackConflict(entry.destinationURL.path)
      }
      if fileManager.fileExists(atPath: entry.destinationURL.path) {
        try fileManager.removeItem(at: entry.destinationURL)
      }
      if let backupURL = entry.backupURL {
        try fileManager.copyItem(at: backupURL, to: entry.destinationURL)
      }
    }
  }

  func isSymbolicLink(_ url: URL) -> Bool {
    // destinationOfSymbolicLink catches dangling links too, unlike fileExists.
    (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
  }

}
