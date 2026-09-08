import Foundation

public enum AssetResourceKind: String, Codable, CaseIterable, Hashable, Sendable {
  case image
  case video
  case audio
  case document

  public var displayName: String {
    switch self {
    case .image: CoreL10n.text("图片")
    case .video: CoreL10n.text("视频")
    case .audio: CoreL10n.text("音频")
    case .document: CoreL10n.text("附件")
    }
  }

  public var systemImage: String {
    switch self {
    case .image: "photo"
    case .video: "video"
    case .audio: "waveform"
    case .document: "doc"
    }
  }
}

public enum AssetResourceReferenceIssueKind: String, Codable, Hashable, Sendable {
  case missing
  case outsideRepository
  case outsideAssetRoot
  case unsupported

  public var displayName: String {
    switch self {
    case .missing: CoreL10n.text("文件不存在")
    case .outsideRepository: CoreL10n.text("路径越出仓库")
    case .outsideAssetRoot: CoreL10n.text("不在资源目录")
    case .unsupported: CoreL10n.text("格式不受支持")
    }
  }
}

public struct AssetResourceReferenceLocation: Codable, Hashable, Sendable {
  public let sourceMarkdownPath: String
  public let lineNumber: Int
  public let rawPath: String
  public let isImageSyntax: Bool

  public init(
    sourceMarkdownPath: String,
    lineNumber: Int,
    rawPath: String,
    isImageSyntax: Bool
  ) {
    self.sourceMarkdownPath = sourceMarkdownPath
    self.lineNumber = lineNumber
    self.rawPath = rawPath
    self.isImageSyntax = isImageSyntax
  }
}

public struct AssetResourceBrokenReference: Identifiable, Codable, Hashable, Sendable {
  public var id: String {
    "\(sourceMarkdownPath):\(lineNumber):\(tokenUTF16Location):\(rawPath)"
  }

  public let sourceMarkdownPath: String
  public let lineNumber: Int
  public let rawPath: String
  public let tokenUTF16Location: Int
  public let tokenUTF16Length: Int
  public let kind: AssetResourceReferenceIssueKind
  public let message: String

  public init(
    sourceMarkdownPath: String,
    lineNumber: Int,
    rawPath: String,
    tokenUTF16Location: Int = 0,
    tokenUTF16Length: Int = 0,
    kind: AssetResourceReferenceIssueKind,
    message: String
  ) {
    self.sourceMarkdownPath = sourceMarkdownPath
    self.lineNumber = lineNumber
    self.rawPath = rawPath
    self.tokenUTF16Location = max(0, tokenUTF16Location)
    self.tokenUTF16Length = max(0, tokenUTF16Length)
    self.kind = kind
    self.message = message
  }

  private enum CodingKeys: String, CodingKey {
    case sourceMarkdownPath
    case lineNumber
    case rawPath
    case tokenUTF16Location
    case tokenUTF16Length
    case kind
    case message
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    sourceMarkdownPath = try container.decode(String.self, forKey: .sourceMarkdownPath)
    lineNumber = try container.decode(Int.self, forKey: .lineNumber)
    rawPath = try container.decode(String.self, forKey: .rawPath)
    tokenUTF16Location = max(
      0, try container.decodeIfPresent(Int.self, forKey: .tokenUTF16Location) ?? 0)
    tokenUTF16Length = max(
      0, try container.decodeIfPresent(Int.self, forKey: .tokenUTF16Length) ?? 0)
    kind = try container.decode(AssetResourceReferenceIssueKind.self, forKey: .kind)
    message = try container.decode(String.self, forKey: .message)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(sourceMarkdownPath, forKey: .sourceMarkdownPath)
    try container.encode(lineNumber, forKey: .lineNumber)
    try container.encode(rawPath, forKey: .rawPath)
    try container.encode(tokenUTF16Location, forKey: .tokenUTF16Location)
    try container.encode(tokenUTF16Length, forKey: .tokenUTF16Length)
    try container.encode(kind, forKey: .kind)
    try container.encode(message, forKey: .message)
  }
}

public struct AssetResourceItem: Identifiable, Codable, Hashable, Sendable {
  public var id: String { repositoryPath }

  public let repositoryPath: String
  public let absoluteFilePath: String
  public let filename: String
  public let fileExtension: String
  public let kind: AssetResourceKind
  public let byteSize: Int64
  public let modifiedAt: Date?
  public let dimensions: ImageDimensions?
  public let references: [AssetResourceReferenceLocation]
  public let canCompress: Bool
  public let compressionReason: String?

  public init(
    repositoryPath: String,
    absoluteFilePath: String,
    filename: String,
    fileExtension: String,
    kind: AssetResourceKind,
    byteSize: Int64,
    modifiedAt: Date?,
    dimensions: ImageDimensions?,
    references: [AssetResourceReferenceLocation],
    canCompress: Bool,
    compressionReason: String? = nil
  ) {
    self.repositoryPath = repositoryPath
    self.absoluteFilePath = absoluteFilePath
    self.filename = filename
    self.fileExtension = fileExtension
    self.kind = kind
    self.byteSize = byteSize
    self.modifiedAt = modifiedAt
    self.dimensions = dimensions
    self.references = references
    self.canCompress = canCompress
    self.compressionReason = compressionReason
  }

  public var fileURL: URL {
    URL(fileURLWithPath: absoluteFilePath)
  }

  public var isReferenced: Bool {
    !references.isEmpty
  }

  public var isOrphaned: Bool {
    references.isEmpty
  }
}

public struct AssetResourceScanReport: Codable, Hashable, Sendable {
  public let revisionID: UUID
  public let profileID: UUID
  public let generatedAt: Date
  public let repositoryRootPath: String
  public let assetRootPath: String
  public let assets: [AssetResourceItem]
  public let brokenReferences: [AssetResourceBrokenReference]
  public let scannedMarkdownFileCount: Int
  public let skippedMarkdownFileCount: Int
  public let wasTruncated: Bool

  public init(
    revisionID: UUID = UUID(),
    profileID: UUID,
    generatedAt: Date = Date(),
    repositoryRootPath: String,
    assetRootPath: String,
    assets: [AssetResourceItem],
    brokenReferences: [AssetResourceBrokenReference],
    scannedMarkdownFileCount: Int,
    skippedMarkdownFileCount: Int = 0,
    wasTruncated: Bool = false
  ) {
    self.revisionID = revisionID
    self.profileID = profileID
    self.generatedAt = generatedAt
    self.repositoryRootPath = repositoryRootPath
    self.assetRootPath = assetRootPath
    self.assets = assets
    self.brokenReferences = brokenReferences
    self.scannedMarkdownFileCount = scannedMarkdownFileCount
    self.skippedMarkdownFileCount = skippedMarkdownFileCount
    self.wasTruncated = wasTruncated
  }

  public var orphanedAssets: [AssetResourceItem] {
    assets.filter(\.isOrphaned)
  }

  public var referencedAssetCount: Int {
    assets.count - orphanedAssets.count
  }

  public var compressionCandidates: [AssetResourceItem] {
    assets.filter(\.canCompress)
  }

  /// An incomplete reference scan cannot safely establish that an asset is
  /// orphaned. Callers must keep destructive cleanup unavailable until a
  /// complete scan succeeds.
  public var isComplete: Bool {
    !wasTruncated && skippedMarkdownFileCount == 0
  }

  public var totalByteSize: Int64 {
    assets.reduce(0) { $0 + max(0, $1.byteSize) }
  }

  public var orphanedByteSize: Int64 {
    orphanedAssets.reduce(0) { $0 + max(0, $1.byteSize) }
  }
}

public struct AssetResourceCleanupResult: Hashable, Sendable {
  public let movedToTrashPaths: [String]
  public let needsReviewPaths: [String]
  public let failedPaths: [String]

  public init(
    movedToTrashPaths: [String],
    needsReviewPaths: [String],
    failedPaths: [String]
  ) {
    self.movedToTrashPaths = movedToTrashPaths
    self.needsReviewPaths = needsReviewPaths
    self.failedPaths = failedPaths
  }
}

public struct AssetResourceOptimizationResult: Hashable, Sendable {
  public let optimizedPaths: [String]
  public let savedBytes: Int64
  public let skippedPaths: [String]
  public let failedPaths: [String]

  public init(
    optimizedPaths: [String],
    savedBytes: Int64,
    skippedPaths: [String],
    failedPaths: [String]
  ) {
    self.optimizedPaths = optimizedPaths
    self.savedBytes = savedBytes
    self.skippedPaths = skippedPaths
    self.failedPaths = failedPaths
  }
}

public enum AssetResourceManagerError: LocalizedError, Equatable {
  case repositoryUnavailable
  case cleanupReviewChanged
  case invalidAssetRoot
  case assetDirectoryUnavailable(String)
  case unsafeAssetPath(String)

  public var errorDescription: String? {
    switch self {
    case .cleanupReviewChanged:
      CoreL10n.text("资源或引用已变化，或扫描不完整。请重新扫描并确认清理清单。")
    case .repositoryUnavailable:
      CoreL10n.text("请先选择一个本地站点文件夹。")
    case .invalidAssetRoot:
      CoreL10n.text("资源目录路径无效或不安全。")
    case .assetDirectoryUnavailable(let path):
      CoreL10n.format("找不到资源目录：%@", path)
    case .unsafeAssetPath(let path):
      CoreL10n.format("已拒绝越出资源目录的文件操作：%@", path)
    }
  }
}
