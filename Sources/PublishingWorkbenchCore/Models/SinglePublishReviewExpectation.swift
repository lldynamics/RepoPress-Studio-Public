import Foundation

/// Exact article bytes and destination accepted in the single-article sheet.
public struct SinglePublishReviewExpectation: Equatable, Sendable {
  public let draftID: UUID
  public let files: [PublishPackageFile]
  public let target: RemoteRepositoryPublishTargetSnapshot
  private let sourceDigests: [String: String]

  public init(
    package: PublishPackage, profile: SiteProfile, preview: RemoteRepositoryPublishPreview
  ) throws {
    draftID = package.draftID
    files = package.files
    target = RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview)
    sourceDigests = try Self.mediaDigests(package)
  }

  public func matches(
    package: PublishPackage, profile: SiteProfile, preview: RemoteRepositoryPublishPreview
  ) -> Bool {
    draftID == package.draftID && files == package.files
      && target == RemoteRepositoryPublishTargetSnapshot(profile: profile, preview: preview)
      && (try? Self.mediaDigests(package)) == sourceDigests
  }

  func bindingMediaContent(in package: PublishPackage) -> PublishPackage {
    var result = package
    for index in result.files.indices {
      result.files[index].reviewedSourceSHA256 = sourceDigests[result.files[index].repositoryPath]
    }
    return result
  }

  private static func mediaDigests(_ package: PublishPackage) throws -> [String: String] {
    var result: [String: String] = [:]
    for file in package.files where file.operation == .upsert && file.kind != .markdown {
      guard let path = file.sourceFilePath else { throw CocoaError(.fileReadNoSuchFile) }
      let digest = try BoundedFileReader.sha256(
        at: URL(fileURLWithPath: path),
        maximumByteCount: WorkbenchFileReadLimits.maximumRemoteMediaUploadByteCount
      )
      result[file.repositoryPath] = digest.map { String(format: "%02x", $0) }.joined()
    }
    return result
  }
}
