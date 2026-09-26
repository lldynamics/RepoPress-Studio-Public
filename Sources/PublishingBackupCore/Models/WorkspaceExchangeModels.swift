import Foundation

public struct WorkspaceExchangeManifest: Codable, Equatable, Sendable {
  public var format: String
  public var version: Int
  public var createdAt: Date
  public var payloadSHA256: String
  public var itemCounts: WorkspaceExchangeItemCounts

  public init(
    format: String = "com.repopress.workspace-exchange",
    version: Int = 1,
    createdAt: Date,
    payloadSHA256: String,
    itemCounts: WorkspaceExchangeItemCounts
  ) {
    self.format = format
    self.version = version
    self.createdAt = createdAt
    self.payloadSHA256 = payloadSHA256
    self.itemCounts = itemCounts
  }
}

public struct WorkspaceExchangeItemCounts: Codable, Equatable, Sendable {
  public var profiles: Int
  public var drafts: Int
  public var attachments: Int

  public init(profiles: Int, drafts: Int, attachments: Int) {
    self.profiles = profiles
    self.drafts = drafts
    self.attachments = attachments
  }
}

public struct WorkspaceExchangePayload: Codable, Equatable, Sendable {
  public var profiles: [WorkspaceExchangeProfile]
  public var drafts: [WorkspaceExchangeDraft]

  public init(profiles: [WorkspaceExchangeProfile], drafts: [WorkspaceExchangeDraft]) {
    self.profiles = profiles
    self.drafts = drafts
  }
}

public struct WorkspaceExchangeProfile: Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var siteKind: String
  public var repoOwner: String
  public var repoName: String
  public var branch: String

  public init(
    id: UUID, name: String, siteKind: String, repoOwner: String, repoName: String, branch: String
  ) {
    self.id = id
    self.name = name
    self.siteKind = siteKind
    self.repoOwner = repoOwner
    self.repoName = repoName
    self.branch = branch
  }
}

public struct WorkspaceExchangeDraft: Codable, Equatable, Sendable {
  public var id: UUID
  public var scope: String
  public var sourceProfileID: UUID?
  public var title: String
  public var date: Date
  public var slug: String
  public var tags: [String]
  public var categories: [String]
  public var authors: [String]
  public var visibility: String
  public var summary: String
  public var bodyMarkdown: String
  public var coverAttachmentID: UUID?
  public var createdAt: Date
  public var updatedAt: Date
  public var attachments: [WorkspaceExchangeAttachment]

  public init(
    id: UUID, scope: String, sourceProfileID: UUID? = nil, title: String, date: Date,
    slug: String, tags: [String], categories: [String], authors: [String], visibility: String,
    summary: String, bodyMarkdown: String, coverAttachmentID: UUID? = nil,
    createdAt: Date, updatedAt: Date, attachments: [WorkspaceExchangeAttachment]
  ) {
    self.id = id
    self.scope = scope
    self.sourceProfileID = sourceProfileID
    self.title = title
    self.date = date
    self.slug = slug
    self.tags = tags
    self.categories = categories
    self.authors = authors
    self.visibility = visibility
    self.summary = summary
    self.bodyMarkdown = bodyMarkdown
    self.coverAttachmentID = coverAttachmentID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.attachments = attachments
  }
}

public struct WorkspaceExchangeAttachment: Codable, Equatable, Sendable {
  public var id: UUID
  public var originalFilename: String
  public var mimeType: String
  public var relativePublishPath: String
  public var role: String
  public var altText: String?
  public var caption: String?
  public var bytes: Data
  public var sha256: String

  public init(
    id: UUID, originalFilename: String, mimeType: String, relativePublishPath: String,
    role: String, altText: String? = nil, caption: String? = nil, bytes: Data, sha256: String
  ) {
    self.id = id
    self.originalFilename = originalFilename
    self.mimeType = mimeType
    self.relativePublishPath = relativePublishPath
    self.role = role
    self.altText = altText
    self.caption = caption
    self.bytes = bytes
    self.sha256 = sha256
  }
}

public struct WorkspaceExchangePackage: Codable, Equatable, Sendable {
  public var manifest: WorkspaceExchangeManifest
  public var payload: WorkspaceExchangePayload

  public init(manifest: WorkspaceExchangeManifest, payload: WorkspaceExchangePayload) {
    self.manifest = manifest
    self.payload = payload
  }
}

public struct WorkspaceExchangePreview: Identifiable, Sendable {
  public let id = UUID()
  public var package: WorkspaceExchangePackage
  public var sourceData: Data
  public var estimatedSizeBytes: Int
  public var conflictingProfileNames: [String]
  public var unmappedSiteDraftCount: Int
  public var attachmentAccessibilityMetadataCount: Int

  public init(
    package: WorkspaceExchangePackage,
    sourceData: Data,
    estimatedSizeBytes: Int,
    conflictingProfileNames: [String],
    unmappedSiteDraftCount: Int,
    attachmentAccessibilityMetadataCount: Int
  ) {
    self.package = package
    self.sourceData = sourceData
    self.estimatedSizeBytes = estimatedSizeBytes
    self.conflictingProfileNames = conflictingProfileNames
    self.unmappedSiteDraftCount = unmappedSiteDraftCount
    self.attachmentAccessibilityMetadataCount = attachmentAccessibilityMetadataCount
  }
}

public struct WorkspaceExchangePublishPathConflict: Identifiable, Equatable, Sendable {
  public var sourceDraftID: UUID
  public var title: String
  public var slug: String
  public var destinationProfileName: String
  public var path: String

  public var id: UUID { sourceDraftID }

  public init(
    sourceDraftID: UUID,
    title: String,
    slug: String,
    destinationProfileName: String,
    path: String
  ) {
    self.sourceDraftID = sourceDraftID
    self.title = title
    self.slug = slug
    self.destinationProfileName = destinationProfileName
    self.path = path
  }
}

public enum WorkspaceExchangeProfileMapping: Hashable, Sendable {
  case existing(UUID)
  case importAsNewProfile
}

public enum WorkspaceExchangeError: LocalizedError, Equatable {
  case invalidFormat
  case unsupportedVersion(Int)
  case invalidPayloadHash
  case invalidAttachmentHash(String)
  case invalidReference(String)
  case invalidPath(String)
  case invalidSlug(String)
  case duplicatePublishPath(String)
  case payloadTooLarge
  case attachmentDataUnavailable(String)
  case siteProfilesRequireConfirmation
  case unavailable
  case persistenceFailed

  public var errorDescription: String? {
    switch self {
    case .invalidFormat: "交换文件格式无效或包含不支持的字段。"
    case .unsupportedVersion(let version): "暂不支持此交换格式版本：\(version)。"
    case .invalidPayloadHash: "交换文件完整性校验失败。"
    case .invalidAttachmentHash(let name): "附件校验失败：\(name)"
    case .invalidReference(let detail): "交换文件中的引用无效：\(detail)"
    case .invalidPath(let path): "附件发布路径不安全：\(path)"
    case .invalidSlug(let slug): "新 Slug 不符合目标站点规则：\(slug)"
    case .duplicatePublishPath(let path): "目标站点的发布路径已被占用：\(path)。请重新预览并修改 Slug。"
    case .payloadTooLarge: "交换文件或附件总量超过 80 MiB / 40 MiB 安全上限。"
    case .attachmentDataUnavailable(let name): "无法安全读取附件：\(name)"
    case .siteProfilesRequireConfirmation: "导入站点文章前必须确认创建新的站点配置。"
    case .unavailable: "当前工作区不可写，无法导入交换文件。"
    case .persistenceFailed: "导入未能确认保存结果。附件数据已保留，请重新读取工作区后检查导入状态。"
    }
  }
}
