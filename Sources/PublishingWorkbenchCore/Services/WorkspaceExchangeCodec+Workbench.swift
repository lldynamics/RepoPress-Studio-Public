import Foundation
import PublishingBackupCore

extension WorkspaceExchangeCodec {
  public static func preview(
    _ data: Data,
    existingProfiles: [SiteProfile]
  ) throws -> WorkspaceExchangePreview {
    let package = try decode(data)
    let profileNames = Set(existingProfiles.map { $0.name.localizedLowercase })
    let includedProfileIDs = Set(package.payload.profiles.map(\.id))
    let unmapped = package.payload.drafts.filter {
      $0.scope == "site" && $0.sourceProfileID.map(includedProfileIDs.contains) != true
    }.count
    return WorkspaceExchangePreview(
      package: package,
      sourceData: data,
      estimatedSizeBytes: data.count,
      conflictingProfileNames: package.payload.profiles
        .filter { profileNames.contains($0.name.localizedLowercase) }.map(\.name),
      unmappedSiteDraftCount: unmapped,
      attachmentAccessibilityMetadataCount: package.payload.drafts
        .flatMap(\.attachments)
        .filter { !($0.altText ?? "").isEmpty || !($0.caption ?? "").isEmpty }
        .count
    )
  }
}
