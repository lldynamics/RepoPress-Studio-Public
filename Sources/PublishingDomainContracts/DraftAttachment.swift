import Foundation

public struct DraftAttachment: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var originalFilename: String
  public var relativePublishPath: String
  public var repositoryPath: String
  public var altText: String
  public var caption: String
  public var byteSize: Int64
  public var sourceFilePath: String?
  public var repositorySHA: String?
  /// The object key and public CDN URL are optional so existing local-repository
  /// attachments remain fully backward compatible.
  public var remoteObjectKey: String?
  public var remoteURL: String?
  public var remoteETag: String?

  public init(
    id: UUID = UUID(),
    originalFilename: String,
    relativePublishPath: String,
    repositoryPath: String,
    altText: String = "",
    caption: String = "",
    byteSize: Int64 = 0,
    sourceFilePath: String? = nil,
    repositorySHA: String? = nil,
    remoteObjectKey: String? = nil,
    remoteURL: String? = nil,
    remoteETag: String? = nil
  ) {
    self.id = id
    self.originalFilename = originalFilename
    self.relativePublishPath = relativePublishPath
    self.repositoryPath = repositoryPath
    self.altText = altText
    self.caption = caption
    self.byteSize = byteSize
    self.sourceFilePath = sourceFilePath
    self.repositorySHA = repositorySHA
    self.remoteObjectKey = remoteObjectKey
    self.remoteURL = remoteURL
    self.remoteETag = remoteETag
  }
}
