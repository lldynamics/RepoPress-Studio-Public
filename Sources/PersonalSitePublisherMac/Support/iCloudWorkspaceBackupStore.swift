import Dispatch
import Foundation
import PublishingWorkbenchCore

/// Resolves the app's iCloud Documents backup folder and reports the actual
/// ubiquitous-item state. A successful local copy is never treated as proof
/// that iCloud has uploaded the bytes.
struct iCloudWorkspaceBackupStore: Sendable {
  static let containerIdentifier = "iCloud.com.chengjinfang.repopress"
  static let directoryName = "WorkspaceBackups"

  enum Availability: Equatable, Sendable {
    case unavailable(String)
    case localOnly
    case pendingUpload
    case uploading
    case availableInCloud
    case downloading
    case downloadRequired
    case failed(String)
  }

  struct Item: Identifiable, Sendable {
    let url: URL
    let availability: Availability
    var id: URL { url }
  }

  func directoryURL() async throws -> URL {
    try await performFileOperation {
      try self.resolvedDirectoryURL(fileManager: FileManager())
    }
  }

  private func resolvedDirectoryURL(fileManager: FileManager) throws -> URL {
    guard let container = fileManager.url(
      forUbiquityContainerIdentifier: Self.containerIdentifier
    ) else {
      throw StoreError.containerUnavailable
    }
    let documents = container.appendingPathComponent("Documents", isDirectory: true)
    let directory = documents.appendingPathComponent(Self.directoryName, isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  func copyInspectedBackup(from localBackupURL: URL) async throws -> URL {
    try await performFileOperation {
      try self.copyInspectedBackupSynchronously(from: localBackupURL, fileManager: FileManager())
    }
  }

  private func copyInspectedBackupSynchronously(
    from localBackupURL: URL,
    fileManager: FileManager
  ) throws -> URL {
    guard localBackupURL.pathExtension == "psworkspacebackup",
      fileManager.fileExists(atPath: localBackupURL.path)
    else { throw StoreError.invalidBackup }

    let directory = try resolvedDirectoryURL(fileManager: fileManager)
    let destination = directory.appendingPathComponent(localBackupURL.lastPathComponent)
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw StoreError.destinationAlreadyExists
    }
    var coordinationError: NSError?
    var copyError: Error?
    NSFileCoordinator(filePresenter: nil).coordinate(
      writingItemAt: destination,
      options: .forReplacing,
      error: &coordinationError
    ) { coordinatedURL in
      do { try fileManager.copyItem(at: localBackupURL, to: coordinatedURL) }
      catch { copyError = error }
    }
    if let coordinationError { throw coordinationError }
    if let copyError { throw copyError }
    return destination
  }

  func listItems() async throws -> [Item] {
    try await performFileOperation {
      try self.loadItems(fileManager: FileManager())
    }
  }

  private func loadItems(fileManager: FileManager) throws -> [Item] {
    let directory = try resolvedDirectoryURL(fileManager: fileManager)
    let urls = try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [
        .isRegularFileKey,
        .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey,
        .ubiquitousItemUploadingErrorKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadingErrorKey,
      ],
      options: [.skipsHiddenFiles]
    )
    return urls.filter { $0.pathExtension == "psworkspacebackup" }.map {
      Item(url: $0, availability: availability(of: $0))
    }.sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }
  }

  func availability(of url: URL) -> Availability {
    do {
      let values = try url.resourceValues(forKeys: [
        .isDirectoryKey,
        .ubiquitousItemIsUploadedKey,
        .ubiquitousItemIsUploadingKey,
        .ubiquitousItemUploadingErrorKey,
        .ubiquitousItemIsDownloadingKey,
        .ubiquitousItemDownloadingStatusKey,
        .ubiquitousItemDownloadingErrorKey,
      ])
      let rootState = Self.mapAvailability(
        isUploaded: values.ubiquitousItemIsUploaded,
        isUploading: values.ubiquitousItemIsUploading,
        isDownloading: values.ubiquitousItemIsDownloading,
        uploadingError: values.ubiquitousItemUploadingError?.localizedDescription,
        downloadingStatus: values.ubiquitousItemDownloadingStatus,
        downloadingError: values.ubiquitousItemDownloadingError?.localizedDescription
      )
      guard values.isDirectory == true else { return rootState }
      if rootState == .downloadRequired || rootState == .downloading || isFailure(rootState) {
        return rootState
      }
      guard values.ubiquitousItemIsUploaded == true else { return rootState }
      guard let paths = declaredPayloadPaths(in: url) else { return .pendingUpload }

      var payloadUploadFlags = [Bool?]()
      for relativePath in paths {
        guard isSafeRelativePath(relativePath) else { return .pendingUpload }
        let payloadURL = url.appendingPathComponent(relativePath).standardizedFileURL
        guard payloadURL.path.hasPrefix(url.standardizedFileURL.path + "/") else {
          return .pendingUpload
        }
        let payloadValues = try payloadURL.resourceValues(forKeys: [
          .isSymbolicLinkKey,
          .ubiquitousItemIsUploadedKey,
          .ubiquitousItemIsUploadingKey,
          .ubiquitousItemUploadingErrorKey,
          .ubiquitousItemIsDownloadingKey,
          .ubiquitousItemDownloadingStatusKey,
          .ubiquitousItemDownloadingErrorKey,
        ])
        guard payloadValues.isSymbolicLink != true else { return .pendingUpload }
        let payloadState = Self.mapAvailability(
          isUploaded: payloadValues.ubiquitousItemIsUploaded,
          isUploading: payloadValues.ubiquitousItemIsUploading,
          isDownloading: payloadValues.ubiquitousItemIsDownloading,
          uploadingError: payloadValues.ubiquitousItemUploadingError?.localizedDescription,
          downloadingStatus: payloadValues.ubiquitousItemDownloadingStatus,
          downloadingError: payloadValues.ubiquitousItemDownloadingError?.localizedDescription
        )
        if payloadState != .availableInCloud { return payloadState }
        payloadUploadFlags.append(payloadValues.ubiquitousItemIsUploaded)
      }
      return Self.allPackageItemsUploaded(
        rootUploaded: values.ubiquitousItemIsUploaded,
        payloadUploadFlags: payloadUploadFlags
      ) ? .availableInCloud : .pendingUpload
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  private func declaredPayloadPaths(in packageURL: URL) -> [String]? {
    let manifestURL = packageURL.appendingPathComponent(WorkspaceBackupService.manifestFileName)
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: manifestURL.path),
      let byteCount = attributes[.size] as? NSNumber,
      byteCount.intValue > 0,
      byteCount.intValue <= 8 * 1_024 * 1_024,
      let data = try? Data(contentsOf: manifestURL),
      let paths = Self.manifestPayloadPaths(from: data)
    else { return nil }
    return [WorkspaceBackupService.manifestFileName] + paths
  }

  static func manifestPayloadPaths(from data: Data) -> [String]? {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let manifest = try? decoder.decode(WorkspaceBackupManifest.self, from: data) else {
      return nil
    }
    return manifest.files.map(\.relativePath)
  }

  private func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/") else { return false }
    return !path.split(separator: "/", omittingEmptySubsequences: false)
      .contains { $0.isEmpty || $0 == "." || $0 == ".." }
  }

  private func isFailure(_ availability: Availability) -> Bool {
    if case .failed = availability { return true }
    if case .unavailable = availability { return true }
    return false
  }

  static func mapAvailability(
    isUploaded: Bool?,
    isUploading: Bool? = nil,
    isDownloading: Bool? = nil,
    uploadingError: String?,
    downloadingStatus: URLUbiquitousItemDownloadingStatus?,
    downloadingError: String?
  ) -> Availability {
    if let uploadingError { return .failed(uploadingError) }
    if let downloadingError { return .failed(downloadingError) }
    if isDownloading == true { return .downloading }
    // A downloaded/current local copy can still be waiting to upload. Only
    // the explicit upload flag justifies telling users the cloud copy exists.
    if downloadingStatus == .notDownloaded { return .downloadRequired }
    if isUploaded == true { return .availableInCloud }
    if isUploading == true { return .uploading }
    if downloadingStatus == .downloaded { return .localOnly }
    if downloadingStatus == .current { return .localOnly }
    return .pendingUpload
  }

  static func allPackageItemsUploaded(
    rootUploaded: Bool?,
    payloadUploadFlags: [Bool?]
  ) -> Bool {
    rootUploaded == true && !payloadUploadFlags.isEmpty
      && payloadUploadFlags.allSatisfy { $0 == true }
  }

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

  private func performFileOperation<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        continuation.resume(with: Result { try operation() })
      }
    }
  }

  enum StoreError: LocalizedError {
    case containerUnavailable
    case invalidBackup
    case destinationAlreadyExists
    case downloadTimedOut
    case cloudOperationFailed(String)

    var errorDescription: String? {
      switch self {
      case .containerUnavailable:
        return String(localized: "iCloud 云盘暂不可用，请检查账号、网络和应用签名。")
      case .invalidBackup:
        return String(localized: "所选文件不是有效的 Mac 工作区备份。")
      case .destinationAlreadyExists:
        return String(localized: "iCloud 备份目录中已存在同名文件。")
      case .downloadTimedOut:
        return String(localized: "等待 iCloud 下载超时，请稍后重试。")
      case .cloudOperationFailed(let message):
        return message
      }
    }
  }
}
