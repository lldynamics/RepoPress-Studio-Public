import Foundation

public struct RepositoryImageReference: Hashable, Sendable {
  public let draftID: UUID
  public let draftTitle: String
  public let isCover: Bool

  public init(draftID: UUID, draftTitle: String, isCover: Bool) {
    self.draftID = draftID
    self.draftTitle = draftTitle
    self.isCover = isCover
  }
}

public struct RepositoryImageAsset: Identifiable, Hashable, Sendable {
  public var id: String { repositoryPath }

  public let repositoryPath: String
  public let absoluteFilePath: String
  public let filename: String
  public let fileExtension: String
  public let byteSize: Int64
  public let modifiedAt: Date?
  public let references: [RepositoryImageReference]

  public init(
    repositoryPath: String,
    absoluteFilePath: String,
    filename: String,
    fileExtension: String,
    byteSize: Int64,
    modifiedAt: Date?,
    references: [RepositoryImageReference]
  ) {
    self.repositoryPath = repositoryPath
    self.absoluteFilePath = absoluteFilePath
    self.filename = filename
    self.fileExtension = fileExtension
    self.byteSize = byteSize
    self.modifiedAt = modifiedAt
    self.references = references
  }

  public var fileURL: URL {
    URL(fileURLWithPath: absoluteFilePath)
  }

  public var isRegisteredToArticle: Bool {
    !references.isEmpty
  }
}

public struct RepositoryImageInventory: Hashable, Sendable {
  public let revisionID: UUID
  public let profileID: UUID
  public let repositoryRootPath: String
  public let assetRootPath: String
  public let assets: [RepositoryImageAsset]
  public let wasTruncated: Bool

  public init(
    revisionID: UUID = UUID(),
    profileID: UUID,
    repositoryRootPath: String,
    assetRootPath: String,
    assets: [RepositoryImageAsset],
    wasTruncated: Bool = false
  ) {
    self.revisionID = revisionID
    self.profileID = profileID
    self.repositoryRootPath = repositoryRootPath
    self.assetRootPath = assetRootPath
    self.assets = assets
    self.wasTruncated = wasTruncated
  }

  public var totalByteSize: Int64 {
    assets.reduce(0) { $0 + max(0, $1.byteSize) }
  }

  public var registeredCount: Int {
    assets.filter(\.isRegisteredToArticle).count
  }

  public var unregisteredCount: Int {
    assets.count - registeredCount
  }
}

public struct RepositoryImageAssetLocation: Hashable, Sendable {
  public let repositoryPath: String
  public let absoluteFilePath: String
  public let byteSize: Int64

  public init(repositoryPath: String, absoluteFilePath: String, byteSize: Int64) {
    self.repositoryPath = repositoryPath
    self.absoluteFilePath = absoluteFilePath
    self.byteSize = byteSize
  }
}
