import Foundation

/// Downloads a workspace backup chosen from iCloud Drive into a private local
/// staging folder before the restore flow inspects it.
struct iCloudWorkspaceBackupStore: Sendable {
  func downloadToLocalStaging(
    _ cloudURL: URL,
    fileManager: FileManager = .default,
    timeout: Duration = .seconds(120)
  ) async throws -> URL {
    guard cloudURL.pathExtension == "psworkspacebackup" else { throw StoreError.invalidBackup }
    let staging = fileManager.temporaryDirectory
      .appendingPathComponent("WorkspaceBackupRestore-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
    let destination = staging.appendingPathComponent(cloudURL.lastPathComponent)
    do {
      try fileManager.startDownloadingUbiquitousItem(at: cloudURL)
      let deadline = ContinuousClock.now.advanced(by: timeout)
      while ContinuousClock.now < deadline {
        try Task.checkCancellation()
        switch downloadReadiness(of: cloudURL) {
        case .ready:
          try coordinatedCopy(from: cloudURL, to: destination, fileManager: fileManager)
          return destination
        case .failed(let message): throw StoreError.cloudOperationFailed(message)
        case .waiting:
          try await Task.sleep(for: .milliseconds(500))
        }
      }
      throw StoreError.downloadTimedOut
    } catch {
      try? fileManager.removeItem(at: staging)
      throw error
    }
  }

  private func downloadReadiness(of url: URL) -> DownloadReadiness {
    do {
      let values = try url.resourceValues(forKeys: [
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadingErrorKey,
      ])
      if let error = values.ubiquitousItemDownloadingError {
        return .failed(error.localizedDescription)
      }
      if values.ubiquitousItemIsDownloading == true { return .waiting }
      switch values.ubiquitousItemDownloadingStatus {
      case .some(.downloaded), .some(.current): return .ready
      case .none, .some(_): return .waiting
      }
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  private enum DownloadReadiness {
    case ready
    case waiting
    case failed(String)
  }

  private func coordinatedCopy(
    from source: URL,
    to destination: URL,
    fileManager: FileManager
  ) throws {
    var coordinationError: NSError?
    var copyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: source,
      options: .withoutChanges,
      writingItemAt: destination,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedSource, coordinatedDestination in
      do { try fileManager.copyItem(at: coordinatedSource, to: coordinatedDestination) }
      catch { copyError = error }
    }
    if let coordinationError { throw coordinationError }
    if let copyError { throw copyError }
  }

  enum StoreError: LocalizedError {
    case invalidBackup
    case downloadTimedOut
    case cloudOperationFailed(String)

    var errorDescription: String? {
      switch self {
      case .invalidBackup:
        return String(localized: "所选文件不是有效的 Mac 工作区备份。")
      case .downloadTimedOut:
        return String(localized: "等待 iCloud 下载超时，请稍后重试。")
      case .cloudOperationFailed(let message):
        return message
      }
    }
  }
}
