import Foundation

extension LocalPublishPreviewService {
  func replaceBinaryFileAtomically(
    sourceURL: URL,
    expectedSourceState: LocalPublishSourceFileState?,
    destinationURL: URL,
    repositoryPath: String
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

    if fileManager.fileExists(atPath: destinationURL.path) {
      _ = try fileManager.replaceItemAt(destinationURL, withItemAt: stagingURL)
    } else {
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
    }
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

  func recoverInterruptedTransaction(at rootURL: URL) throws {
    let transactionURL = localPublishTransactionURL(for: rootURL)
    guard fileManager.fileExists(atPath: transactionURL.path) else { return }
    do {
      guard !isSymbolicLink(transactionURL) else {
        throw LocalPublishPreviewError.recoveryFailed("事务日志不能是符号链接")
      }
      let data = try Data(contentsOf: transactionURL)
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

      // Validate the complete journal before changing any destination. A
      // forged entry later in the list must not allow an earlier content path
      // to be restored before recovery fails closed on a Git path.
      for entry in transaction.entries {
        guard !isGitControlPath(entry.repositoryPath) else {
          throw LocalPublishPreviewError.recoveryFailed("恢复路径属于 Git 管理目录：\(entry.repositoryPath)")
        }
        _ = try validatedDestinationURLForWrite(
          rootURL: root,
          repositoryPath: entry.repositoryPath
        )
      }

      if transaction.phase == .committed {
        if fileManager.fileExists(atPath: rollbackDirectory.path) {
          try fileManager.removeItem(at: rollbackDirectory)
        }
        try fileManager.removeItem(at: transactionURL)
        return
      }

      for entry in transaction.entries.reversed() {
        guard !isGitControlPath(entry.repositoryPath) else {
          throw LocalPublishPreviewError.recoveryFailed("恢复路径属于 Git 管理目录：\(entry.repositoryPath)")
        }
        let destinationURL = try validatedDestinationURLForWrite(
          rootURL: root,
          repositoryPath: entry.repositoryPath
        )
        if fileManager.fileExists(atPath: destinationURL.path) {
          try fileManager.removeItem(at: destinationURL)
        }
        if let backupFileName = entry.backupFileName {
          guard !backupFileName.contains("/"),
            !backupFileName.contains("\\"),
            !backupFileName.contains("..")
          else {
            throw LocalPublishPreviewError.recoveryFailed("恢复备份路径不安全")
          }
          let backupURL = rollbackDirectory.appendingPathComponent(backupFileName)
            .standardizedFileURL
          guard backupURL.deletingLastPathComponent() == rollbackDirectory,
            fileManager.fileExists(atPath: backupURL.path),
            !isSymbolicLink(backupURL)
          else {
            throw LocalPublishPreviewError.recoveryFailed("恢复备份文件缺失：\(entry.repositoryPath)")
          }
          var backupIsDirectory: ObjCBool = false
          guard
            !fileManager.fileExists(
              atPath: backupURL.path,
              isDirectory: &backupIsDirectory
            ) || !backupIsDirectory.boolValue
          else {
            throw LocalPublishPreviewError.recoveryFailed("恢复备份文件不是普通文件：\(entry.repositoryPath)")
          }
          try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try fileManager.copyItem(at: backupURL, to: destinationURL)
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
