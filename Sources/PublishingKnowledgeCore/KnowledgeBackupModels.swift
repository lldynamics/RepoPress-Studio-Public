import Foundation

public struct KnowledgeLibraryBackupFileRecord: Codable, Hashable, Sendable {
  public var relativePath: String
  public var byteCount: Int64
  public var sha256: String

  public init(relativePath: String, byteCount: Int64, sha256: String) {
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

public struct KnowledgeLibraryBackupManifest: Codable, Hashable, Sendable {
  public static let currentFormatVersion = 1

  public var formatVersion: Int
  public var createdAt: Date
  public var applicationVersion: String
  public var databaseUserVersion: Int
  public var documentCount: Int
  public var folderCount: Int
  public var revisionCount: Int
  public var chunkCount: Int
  public var totalByteCount: Int64
  public var files: [KnowledgeLibraryBackupFileRecord]

  public init(
    formatVersion: Int = KnowledgeLibraryBackupManifest.currentFormatVersion,
    createdAt: Date = Date(),
    applicationVersion: String,
    databaseUserVersion: Int,
    documentCount: Int,
    folderCount: Int,
    revisionCount: Int,
    chunkCount: Int,
    totalByteCount: Int64,
    files: [KnowledgeLibraryBackupFileRecord]
  ) {
    self.formatVersion = formatVersion
    self.createdAt = createdAt
    self.applicationVersion = applicationVersion
    self.databaseUserVersion = databaseUserVersion
    self.documentCount = documentCount
    self.folderCount = folderCount
    self.revisionCount = revisionCount
    self.chunkCount = chunkCount
    self.totalByteCount = totalByteCount
    self.files = files
  }
}

public struct KnowledgeLibraryBackupPreview: Identifiable, Hashable, Sendable {
  public var id: URL { backupURL }
  public var backupURL: URL
  public var createdAt: Date
  public var applicationVersion: String
  public var databaseUserVersion: Int
  public var documentCount: Int
  public var folderCount: Int
  public var revisionCount: Int
  public var chunkCount: Int
  public var totalByteCount: Int64
  public var sampleTitles: [String]

  public init(
    backupURL: URL,
    createdAt: Date,
    applicationVersion: String,
    databaseUserVersion: Int,
    documentCount: Int,
    folderCount: Int,
    revisionCount: Int,
    chunkCount: Int,
    totalByteCount: Int64,
    sampleTitles: [String]
  ) {
    self.backupURL = backupURL
    self.createdAt = createdAt
    self.applicationVersion = applicationVersion
    self.databaseUserVersion = databaseUserVersion
    self.documentCount = documentCount
    self.folderCount = folderCount
    self.revisionCount = revisionCount
    self.chunkCount = chunkCount
    self.totalByteCount = totalByteCount
    self.sampleTitles = sampleTitles
  }
}

public struct KnowledgeLibraryRestoreStartupResult: Hashable, Sendable {
  public var restoredPreview: KnowledgeLibraryBackupPreview
  public var previousLibraryURL: URL?

  public init(
    restoredPreview: KnowledgeLibraryBackupPreview,
    previousLibraryURL: URL?
  ) {
    self.restoredPreview = restoredPreview
    self.previousLibraryURL = previousLibraryURL
  }
}

public enum KnowledgeLibraryRestoreStartupOutcome: Hashable, Sendable {
  case none
  case restored(KnowledgeLibraryRestoreStartupResult)
  case failed(String)
}

public enum KnowledgeLibraryBackupError: LocalizedError, Hashable, Sendable {
  case sourceUnavailable(String)
  case invalidManifest(String)
  case unsupportedFormat(Int)
  case unsupportedDatabaseVersion(found: Int, supported: Int)
  case invalidPath(String)
  case missingFile(String)
  case manifestTooLarge(maximumByteCount: Int)
  case tooManyFiles(maximumCount: Int)
  case fileTooLarge(path: String, maximumByteCount: Int64)
  case backupTooLarge(maximumByteCount: Int64)
  case fileSizeMismatch(String)
  case checksumMismatch(String)
  case databaseIntegrity(String)
  case metadataMismatch(String)
  case stagingFailed(String)
  case restoreFailed(String)

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable(let detail):
      "备份来源不可用：\(detail)"
    case .invalidManifest(let detail):
      "备份清单无效：\(detail)"
    case .unsupportedFormat(let version):
      "暂不支持此资料库备份格式（版本 \(version)）。"
    case .unsupportedDatabaseVersion(let found, let supported):
      "此备份使用更新的资料库数据库版本 \(found)，当前版本最高支持 \(supported)，已拒绝恢复。"
    case .invalidPath(let path):
      "备份包含不安全的文件路径：\(path)"
    case .missingFile(let path):
      "备份缺少文件：\(path)"
    case .manifestTooLarge(let maximumByteCount):
      "备份清单超过允许的 \(maximumByteCount / 1_024 / 1_024) MB。"
    case .tooManyFiles(let maximumCount):
      "备份文件数超过允许的 \(maximumCount) 个。"
    case .fileTooLarge(let path, let maximumByteCount):
      "备份单个文件超过允许的 \(maximumByteCount / 1_024 / 1_024) MB：\(path)"
    case .backupTooLarge(let maximumByteCount):
      "备份总大小超过允许的 \(maximumByteCount / 1_024 / 1_024 / 1_024) GB。"
    case .fileSizeMismatch(let path):
      "备份文件大小与清单不一致：\(path)"
    case .checksumMismatch(let path):
      "备份文件校验失败，内容可能已损坏或被修改：\(path)"
    case .databaseIntegrity(let detail):
      "备份数据库完整性校验失败：\(detail)"
    case .metadataMismatch(let detail):
      "备份清单与数据库不一致：\(detail)"
    case .stagingFailed(let detail):
      "无法准备资料库恢复：\(detail)"
    case .restoreFailed(let detail):
      "资料库恢复失败：\(detail)"
    }
  }
}
