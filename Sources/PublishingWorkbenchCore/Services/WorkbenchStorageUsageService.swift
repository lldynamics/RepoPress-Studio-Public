import Foundation

public struct WorkbenchStorageUsageSnapshot: Equatable, Sendable {
  public var rootURL: URL
  public var totalByteCount: Int64
  public var regularFileCount: Int
  public var knowledgeLibraryByteCount: Int64
  public var rssReaderByteCount: Int64
  public var managedAttachmentsByteCount: Int64
  public var automaticBackupsByteCount: Int64
  public var otherByteCount: Int64

  public init(
    rootURL: URL,
    totalByteCount: Int64,
    regularFileCount: Int,
    knowledgeLibraryByteCount: Int64,
    rssReaderByteCount: Int64,
    managedAttachmentsByteCount: Int64,
    automaticBackupsByteCount: Int64,
    otherByteCount: Int64
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.totalByteCount = max(0, totalByteCount)
    self.regularFileCount = max(0, regularFileCount)
    self.knowledgeLibraryByteCount = max(0, knowledgeLibraryByteCount)
    self.rssReaderByteCount = max(0, rssReaderByteCount)
    self.managedAttachmentsByteCount = max(0, managedAttachmentsByteCount)
    self.automaticBackupsByteCount = max(0, automaticBackupsByteCount)
    self.otherByteCount = max(0, otherByteCount)
  }
}

public enum WorkbenchStorageUsageError: LocalizedError, Equatable, Sendable {
  case rootUnavailable
  case enumerationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .rootUnavailable:
      return CoreL10n.text("数据文件夹不可读取。")
    case .enumerationFailed(let detail):
      return CoreL10n.format("存储空间统计失败：%@", detail)
    }
  }
}

/// Produces a read-only snapshot of disk usage for the app-owned data root.
/// Symbolic links are counted neither as files nor as payload and are never
/// followed, preventing usage inspection from escaping the selected root.
public struct WorkbenchStorageUsageService: Sendable {
  public init() {}

  public func snapshot(
    for layout: WorkbenchDataRootLayout,
    fileManager: FileManager = .default
  ) throws -> WorkbenchStorageUsageSnapshot {
    let rootValues: URLResourceValues
    do {
      rootValues = try layout.rootURL.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
    } catch {
      throw WorkbenchStorageUsageError.rootUnavailable
    }
    guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
      throw WorkbenchStorageUsageError.rootUnavailable
    }

    var enumerationError: Error?
    guard let enumerator = fileManager.enumerator(
      at: layout.rootURL,
      includingPropertiesForKeys: [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey
      ],
      options: [],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    ) else {
      throw WorkbenchStorageUsageError.rootUnavailable
    }

    let knowledgePath = layout.knowledgeLibraryURL.path
    let rssPath = layout.rssReaderURL.path
    let attachmentsPath = layout.managedAttachmentsURL.path
    let backupsPath = layout.rootURL.appendingPathComponent(
      WorkspaceBackupService.automaticBackupDirectoryName,
      isDirectory: true
    ).path
    var totalByteCount: Int64 = 0
    var regularFileCount = 0
    var knowledgeByteCount: Int64 = 0
    var rssByteCount: Int64 = 0
    var attachmentByteCount: Int64 = 0
    var backupByteCount: Int64 = 0

    for case let url as URL in enumerator {
      let values: URLResourceValues
      do {
        values = try url.resourceValues(
          forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .totalFileAllocatedSizeKey
          ]
        )
      } catch {
        throw WorkbenchStorageUsageError.enumerationFailed(error.localizedDescription)
      }
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard values.isRegularFile == true else { continue }

      let byteCount = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
      totalByteCount += max(0, byteCount)
      regularFileCount += 1
      let path = url.standardizedFileURL.path
      if Self.isInside(path, rootPath: knowledgePath) {
        knowledgeByteCount += max(0, byteCount)
      } else if Self.isInside(path, rootPath: rssPath) {
        rssByteCount += max(0, byteCount)
      } else if Self.isInside(path, rootPath: attachmentsPath) {
        attachmentByteCount += max(0, byteCount)
      } else if Self.isInside(path, rootPath: backupsPath) {
        backupByteCount += max(0, byteCount)
      }
    }
    if let enumerationError {
      throw WorkbenchStorageUsageError.enumerationFailed(enumerationError.localizedDescription)
    }

    let categorizedByteCount = knowledgeByteCount + rssByteCount
      + attachmentByteCount + backupByteCount
    return WorkbenchStorageUsageSnapshot(
      rootURL: layout.rootURL,
      totalByteCount: totalByteCount,
      regularFileCount: regularFileCount,
      knowledgeLibraryByteCount: knowledgeByteCount,
      rssReaderByteCount: rssByteCount,
      managedAttachmentsByteCount: attachmentByteCount,
      automaticBackupsByteCount: backupByteCount,
      otherByteCount: max(0, totalByteCount - categorizedByteCount)
    )
  }

  private static func isInside(_ path: String, rootPath: String) -> Bool {
    path == rootPath || path.hasPrefix(rootPath + "/")
  }
}
