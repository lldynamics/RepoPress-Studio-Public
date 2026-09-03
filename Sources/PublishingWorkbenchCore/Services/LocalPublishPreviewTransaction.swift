import Foundation

extension LocalPublishPreviewService {
  /// A legacy journal can otherwise mutate a section before the new article
  /// package is validated. Leave that journal intact for explicit inspection.
  func validateArticleWrite(package: PublishPackage, profile: SiteProfile) throws {
    try StructuralArticlePathPolicy.validate(package: package, profile: profile)
    guard let root = profile.localRepositoryRootURL else { return }
    let journalURL = localPublishTransactionURL(for: root)
    guard fileManager.fileExists(atPath: journalURL.path) else { return }
    guard !isSymbolicLink(journalURL) else {
      throw LocalPublishPreviewError.recoveryFailed("事务日志不能是符号链接")
    }
    let transaction = try JSONDecoder().decode(
      LocalPublishTransaction.self,
      from: BoundedFileReader.data(
        at: journalURL, maximumByteCount: Self.maximumTransactionByteCount))
    guard transaction.phase != .manualRecoveryRequired else {
      throw LocalPublishPreviewError.recoveryFailed("上次写入回滚未完成，已保留事务和备份；请先人工核对外部修改。")
    }
    if transaction.phase == .applying,
      let entry = transaction.entries.first(where: {
        StructuralArticlePathPolicy.isProtected($0.repositoryPath, profile: profile)
      })
    {
      throw StructuralArticlePathError.protectedPath(entry.repositoryPath)
    }
  }

  static let maximumTransactionByteCount = 1_048_576

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

  func recoverInterruptedTransaction(
    at rootURL: URL, articleProfile: SiteProfile? = nil
  ) throws {
    try withWriteLock {
      try recoverLockedTransaction(at: rootURL, articleProfile: articleProfile)
    }
  }

  private func recoverLockedTransaction(
    at rootURL: URL, articleProfile: SiteProfile?
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
      guard transaction.phase != .manualRecoveryRequired else {
        throw LocalPublishPreviewError.recoveryFailed("上次写入回滚未完成，可能存在外部修改。已保留事务和备份，请先人工核对，禁止自动恢复。")
      }
      let root = rootURL.standardizedFileURL
      let rollbackDirectory = URL(fileURLWithPath: transaction.rollbackDirectoryPath)
        .standardizedFileURL
      guard rollbackDirectory.deletingLastPathComponent() == root,
        rollbackDirectory.lastPathComponent.hasPrefix(".repopress-local-publish-rollback-"),
        !isSymbolicLink(rollbackDirectory)
      else {
        throw LocalPublishPreviewError.recoveryFailed("恢复目录不在本地仓库内")
      }

      // Validate the complete journal and every referenced backup before
      // changing any destination. A forged or incomplete entry later in the
      // list must not allow an earlier content path to be removed first.
      var preparedRecoveries: [PreparedLocalPublishRecovery] = []
      for entry in transaction.entries {
        let protectsSection =
          articleProfile.map {
            StructuralArticlePathPolicy.isProtected(entry.repositoryPath, profile: $0)
          } ?? StructuralArticlePathPolicy.isSectionFile(entry.repositoryPath)
        guard !protectsSection else {
          throw StructuralArticlePathError.protectedPath(entry.repositoryPath)
        }
        guard !isGitControlPath(entry.repositoryPath) else {
          throw LocalPublishPreviewError.recoveryFailed("恢复路径属于 Git 管理目录：\(entry.repositoryPath)")
        }
        let destinationURL = try validatedDestinationURLForWrite(
          rootURL: root,
          repositoryPath: entry.repositoryPath
        )
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
        preparedRecoveries.append(
          PreparedLocalPublishRecovery(
            destinationURL: destinationURL,
            backupURL: backupURL
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
        if fileManager.fileExists(atPath: recovery.destinationURL.path) {
          try fileManager.removeItem(at: recovery.destinationURL)
        }
        if let backupURL = recovery.backupURL {
          try fileManager.createDirectory(
            at: recovery.destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try fileManager.copyItem(at: backupURL, to: recovery.destinationURL)
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
        case .manualRecoveryRequired:
          CoreL10n.text("上次回滚未完成，已保留事务和备份。请先人工核对外部修改，自动恢复已停止。")
        }
      return PreflightIssue(
        severity: transaction.phase == .manualRecoveryRequired ? .error : .warning,
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
