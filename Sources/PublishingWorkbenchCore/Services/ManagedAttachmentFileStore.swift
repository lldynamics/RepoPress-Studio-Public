import Foundation

public enum ManagedAttachmentFileStoreError: LocalizedError, Equatable, Sendable {
  case sourceUnavailable(String)
  case storageFailed(path: String, reason: String)
  case discardFailed(path: String, reason: String)

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable(let path):
      return CoreL10n.format("媒体源文件缺失：%@", path)
    case .storageFailed(let path, let reason):
      return CoreL10n.format("媒体源文件无法安全读取：%@。%@", path, reason)
    case .discardFailed(let path, let reason):
      return CoreL10n.format("媒体临时文件清理失败：%@。%@", path, reason)
    }
  }
}

/// Owns durable copies of user-selected draft attachments.
///
/// A user-selected `NSOpenPanel` URL is not a durable ownership boundary and may
/// become unreadable after relaunch. New attachments are therefore copied into
/// the app-owned data root (or the legacy Application Support default) before
/// their paths are added to a draft. The existing
/// `DraftAttachment.sourceFilePath` field continues to store the resolved
/// absolute path, so snapshots created by older builds remain decodable.
public struct ManagedAttachmentFileStore: Sendable {
  public let rootDirectoryURL: URL

  public init(rootDirectoryURL: URL? = nil) {
    self.rootDirectoryURL = rootDirectoryURL ?? Self.defaultRootDirectoryURL()
  }

  public static func defaultRootDirectoryURL(
    fileManager: FileManager = .default
  ) -> URL {
    let supportURL =
      fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? fileManager.temporaryDirectory
    return
      supportURL
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("ManagedAttachments", isDirectory: true)
  }

  /// Copies one attachment through a same-directory staging file.
  ///
  /// `moveItem` publishes the completed staging file as a single directory
  /// entry update. A repeated request for the same attachment identifier is
  /// idempotent and returns the already-managed regular file.
  public func storeFile(
    at sourceURL: URL,
    attachmentID: UUID
  ) throws -> URL {
    let fileManager = FileManager.default
    let standardizedSourceURL = sourceURL.standardizedFileURL
    guard fileManager.isReadableFile(atPath: standardizedSourceURL.path),
      let sourceValues = try? standardizedSourceURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      ),
      sourceValues.isRegularFile == true,
      sourceValues.isSymbolicLink != true
    else {
      throw ManagedAttachmentFileStoreError.sourceUnavailable(
        standardizedSourceURL.path
      )
    }

    let attachmentDirectoryURL =
      rootDirectoryURL
      .appendingPathComponent(attachmentID.uuidString.lowercased(), isDirectory: true)
    let destinationURL = attachmentDirectoryURL.appendingPathComponent(
      safeFilename(for: standardizedSourceURL, attachmentID: attachmentID),
      isDirectory: false
    )

    do {
      try fileManager.createDirectory(
        at: attachmentDirectoryURL,
        withIntermediateDirectories: true
      )
      if isRegularFile(at: destinationURL, fileManager: fileManager) {
        return destinationURL
      }

      let stagingURL = attachmentDirectoryURL.appendingPathComponent(
        ".attachment-import-\(UUID().uuidString.lowercased()).stage",
        isDirectory: false
      )
      defer { try? fileManager.removeItem(at: stagingURL) }
      try fileManager.copyItem(at: standardizedSourceURL, to: stagingURL)
      try fileManager.moveItem(at: stagingURL, to: destinationURL)
      return destinationURL
    } catch {
      // Two callers can import the same attachment ID at the same time. The
      // first atomic move wins; the losing move reports “file exists”, which
      // is a successful idempotent result once the winner's regular file is
      // visible.
      if isRegularFile(at: destinationURL, fileManager: fileManager) {
        return destinationURL
      }
      try? removeDirectoryIfEmpty(attachmentDirectoryURL, fileManager: fileManager)
      throw ManagedAttachmentFileStoreError.storageFailed(
        path: standardizedSourceURL.path,
        reason: error.localizedDescription
      )
    }
  }

  /// Removes only a file previously generated below this store's exact root.
  /// Used when an asynchronous import is cancelled before the draft can adopt
  /// the managed copy.
  public func discardStoredFile(at fileURL: URL) throws {
    let standardizedRootURL = rootDirectoryURL.standardizedFileURL
    let standardizedFileURL = fileURL.standardizedFileURL
    guard
      standardizedFileURL.deletingLastPathComponent()
        .deletingLastPathComponent() == standardizedRootURL
    else {
      return
    }

    let fileManager = FileManager.default
    do {
      if fileManager.fileExists(atPath: standardizedFileURL.path) {
        try fileManager.removeItem(at: standardizedFileURL)
      }
      let attachmentDirectoryURL = standardizedFileURL.deletingLastPathComponent()
      try removeDirectoryIfEmpty(attachmentDirectoryURL, fileManager: fileManager)
    } catch {
      throw ManagedAttachmentFileStoreError.discardFailed(
        path: standardizedFileURL.path,
        reason: error.localizedDescription
      )
    }
  }

  private func safeFilename(for sourceURL: URL, attachmentID: UUID) -> String {
    let filename = sourceURL.lastPathComponent
    guard !filename.isEmpty, filename != ".", filename != ".." else {
      return "attachment-\(attachmentID.uuidString.lowercased())"
    }
    return filename
  }

  private func isRegularFile(
    at url: URL,
    fileManager: FileManager
  ) -> Bool {
    guard fileManager.fileExists(atPath: url.path),
      let values = try? url.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
      )
    else {
      return false
    }
    return values.isRegularFile == true && values.isSymbolicLink != true
  }

  private func removeDirectoryIfEmpty(
    _ directoryURL: URL,
    fileManager: FileManager
  ) throws {
    guard fileManager.fileExists(atPath: directoryURL.path) else { return }
    let contents = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
    guard contents.isEmpty else { return }
    try fileManager.removeItem(at: directoryURL)
  }
}
