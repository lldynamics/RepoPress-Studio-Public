import Foundation

public enum WorkspaceBackupComponent: String, Codable, CaseIterable, Hashable, Sendable {
  case workbenchState = "工作台数据"
  case draftAttachments = "草稿附件"
  case knowledgeLibrary = "资料库"
  case rssReader = "RSS 阅读器"
}

public struct WorkspaceBackupComponentSummary: Codable, Hashable, Sendable {
  public var component: WorkspaceBackupComponent
  public var fileCount: Int
  public var byteCount: Int64

  public init(
    component: WorkspaceBackupComponent,
    fileCount: Int,
    byteCount: Int64
  ) {
    self.component = component
    self.fileCount = fileCount
    self.byteCount = byteCount
  }
}

public struct WorkspaceBackupFileRecord: Codable, Hashable, Sendable {
  public var relativePath: String
  public var component: WorkspaceBackupComponent
  public var byteCount: Int64
  public var sha256: String

  public init(
    relativePath: String,
    component: WorkspaceBackupComponent,
    byteCount: Int64,
    sha256: String
  ) {
    self.relativePath = relativePath
    self.component = component
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

/// Maps an attachment source path to a stable, archive-local marker.
///
/// The original absolute path is intentionally not stored in the manifest.
/// A restore writes the file below ManagedAttachments and replaces the marker
/// in every draft, recycled draft, and historical version.
public struct WorkspaceBackupAttachmentReference: Codable, Hashable, Sendable {
  public var marker: String
  public var archiveRelativePath: String
  public var restoredRelativePath: String

  public init(
    marker: String,
    archiveRelativePath: String,
    restoredRelativePath: String
  ) {
    self.marker = marker
    self.archiveRelativePath = archiveRelativePath
    self.restoredRelativePath = restoredRelativePath
  }
}

public struct WorkspaceBackupManifest: Codable, Hashable, Sendable {
  public static let currentFormatVersion = 2
  public static let minimumSupportedFormatVersion = 1
  public static let attachmentMarkerPrefix = "workspace-backup-attachment://"

  public var formatVersion: Int
  public var createdAt: Date
  public var applicationVersion: String
  /// This is a format guarantee, not a UI preference. Workspace backup never
  /// reads Keychain values and a valid manifest must keep this false.
  public var includesAPIKeys: Bool
  public var profileCount: Int
  public var draftCount: Int
  public var draftVersionCount: Int
  public var releaseRecordCount: Int
  public var attachmentReferenceCount: Int
  public var unresolvedAttachmentCount: Int
  public var components: [WorkspaceBackupComponentSummary]
  public var fileCount: Int
  public var totalByteCount: Int64
  public var attachmentReferences: [WorkspaceBackupAttachmentReference]
  public var files: [WorkspaceBackupFileRecord]

  public init(
    formatVersion: Int = WorkspaceBackupManifest.currentFormatVersion,
    createdAt: Date = Date(),
    applicationVersion: String,
    includesAPIKeys: Bool = false,
    profileCount: Int,
    draftCount: Int,
    draftVersionCount: Int,
    releaseRecordCount: Int,
    attachmentReferenceCount: Int,
    unresolvedAttachmentCount: Int,
    components: [WorkspaceBackupComponentSummary],
    fileCount: Int,
    totalByteCount: Int64,
    attachmentReferences: [WorkspaceBackupAttachmentReference],
    files: [WorkspaceBackupFileRecord]
  ) {
    self.formatVersion = formatVersion
    self.createdAt = createdAt
    self.applicationVersion = applicationVersion
    self.includesAPIKeys = includesAPIKeys
    self.profileCount = profileCount
    self.draftCount = draftCount
    self.draftVersionCount = draftVersionCount
    self.releaseRecordCount = releaseRecordCount
    self.attachmentReferenceCount = attachmentReferenceCount
    self.unresolvedAttachmentCount = unresolvedAttachmentCount
    self.components = components
    self.fileCount = fileCount
    self.totalByteCount = totalByteCount
    self.attachmentReferences = attachmentReferences
    self.files = files
  }
}

public enum WorkspaceBackupCompatibility: String, Codable, Hashable, Sendable {
  case compatible
  case createdByOlderApplication
  case createdByNewerApplication
  case unknownApplicationVersion

  public var requiresConfirmation: Bool {
    self != .compatible
  }
}

public struct WorkspaceBackupPreview: Identifiable, Hashable, Sendable {
  public var id: URL { backupURL }
  public var backupURL: URL
  public var createdAt: Date
  public var applicationVersion: String
  public var formatVersion: Int
  public var compatibility: WorkspaceBackupCompatibility
  public var includesAPIKeys: Bool
  public var profileCount: Int
  public var draftCount: Int
  public var draftVersionCount: Int
  public var releaseRecordCount: Int
  public var attachmentReferenceCount: Int
  public var unresolvedAttachmentCount: Int
  public var components: [WorkspaceBackupComponentSummary]
  public var fileCount: Int
  public var totalByteCount: Int64

  public init(
    backupURL: URL,
    createdAt: Date,
    applicationVersion: String,
    formatVersion: Int = WorkspaceBackupManifest.currentFormatVersion,
    compatibility: WorkspaceBackupCompatibility = .unknownApplicationVersion,
    includesAPIKeys: Bool,
    profileCount: Int,
    draftCount: Int,
    draftVersionCount: Int,
    releaseRecordCount: Int,
    attachmentReferenceCount: Int,
    unresolvedAttachmentCount: Int,
    components: [WorkspaceBackupComponentSummary],
    fileCount: Int,
    totalByteCount: Int64
  ) {
    self.backupURL = backupURL
    self.createdAt = createdAt
    self.applicationVersion = applicationVersion
    self.formatVersion = formatVersion
    self.compatibility = compatibility
    self.includesAPIKeys = includesAPIKeys
    self.profileCount = profileCount
    self.draftCount = draftCount
    self.draftVersionCount = draftVersionCount
    self.releaseRecordCount = releaseRecordCount
    self.attachmentReferenceCount = attachmentReferenceCount
    self.unresolvedAttachmentCount = unresolvedAttachmentCount
    self.components = components
    self.fileCount = fileCount
    self.totalByteCount = totalByteCount
  }
}

public struct WorkspaceBackupRestoreStartupResult: Hashable, Sendable {
  public var restoredPreview: WorkspaceBackupPreview
  public var recoveryURL: URL

  public init(
    restoredPreview: WorkspaceBackupPreview,
    recoveryURL: URL
  ) {
    self.restoredPreview = restoredPreview
    self.recoveryURL = recoveryURL
  }
}

public enum WorkspaceBackupRestoreStartupOutcome: Hashable, Sendable {
  case none
  case restored(WorkspaceBackupRestoreStartupResult)
  case failed(String)
}

/// Result of checking for a restore transaction that was interrupted after it
/// started moving live workspace data. Call this before constructing services
/// that open the workbench, knowledge, or RSS stores.
public enum WorkspaceBackupRestoreRecoveryOutcome: Hashable, Sendable {
  case none
  case rolledBack
  case failed(String)
}

public enum WorkspaceBackupError: LocalizedError, Hashable, Sendable {
  case sourceUnavailable(String)
  case invalidManifest(String)
  case unsupportedFormat(Int)
  case apiKeysNotAllowed
  case invalidPath(String)
  case missingFile(String)
  case tooManyFiles(maximumCount: Int)
  case fileTooLarge(path: String, maximumByteCount: Int64)
  case backupTooLarge(maximumByteCount: Int64)
  case fileSizeMismatch(String)
  case checksumMismatch(String)
  case invalidWorkbenchSnapshot(String)
  case invalidAttachmentReference(String)
  case attachmentSourceUnavailable(String)
  case knowledgeLibraryInvalid(String)
  case rssReaderInvalid(String)
  case stagingFailed(String)
  case restoreFailed(String)

  public var errorDescription: String? {
    switch self {
    case .sourceUnavailable(let detail):
      return CoreL10n.format("工作区备份来源不可用：%@", detail)
    case .invalidManifest(let detail):
      return CoreL10n.format("工作区备份清单无效：%@", detail)
    case .unsupportedFormat(let version):
      return CoreL10n.format("暂不支持此工作区备份格式（版本 %d）。", version)
    case .apiKeysNotAllowed:
      return CoreL10n.text("此备份包含不允许导入的 API Key，已拒绝恢复。")
    case .invalidPath(let path):
      return CoreL10n.format("备份包含不安全的文件路径：%@", path)
    case .missingFile(let path):
      return CoreL10n.format("备份缺少文件：%@", path)
    case .tooManyFiles(let maximumCount):
      return CoreL10n.format("备份文件数超过允许的 %d 个。", maximumCount)
    case .fileTooLarge(let path, let maximumByteCount):
      return CoreL10n.format(
        "备份文件超过允许大小（%lld MB）：%@",
        maximumByteCount / 1_024 / 1_024,
        path
      )
    case .backupTooLarge(let maximumByteCount):
      return CoreL10n.format(
        "备份总大小超过允许的 %lld GB。",
        maximumByteCount / 1_024 / 1_024 / 1_024
      )
    case .fileSizeMismatch(let path):
      return CoreL10n.format("备份文件大小与清单不一致：%@", path)
    case .checksumMismatch(let path):
      return CoreL10n.format("备份文件校验失败，内容可能已损坏或被修改：%@", path)
    case .invalidWorkbenchSnapshot(let detail):
      return CoreL10n.format("工作台快照无效：%@", detail)
    case .invalidAttachmentReference(let detail):
      return CoreL10n.format("附件引用无效：%@", detail)
    case .attachmentSourceUnavailable(let path):
      return CoreL10n.format("附件源文件不可读取：%@", path)
    case .knowledgeLibraryInvalid(let detail):
      return CoreL10n.format("资料库备份无效：%@", detail)
    case .rssReaderInvalid(let detail):
      return CoreL10n.format("RSS 备份无效：%@", detail)
    case .stagingFailed(let detail):
      return CoreL10n.format("工作区恢复暂存失败：%@", detail)
    case .restoreFailed(let detail):
      return CoreL10n.format("工作区恢复失败：%@", detail)
    }
  }
}
