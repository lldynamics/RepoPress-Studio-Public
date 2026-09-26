import CryptoKit
import PublishingBackupCore
import Foundation
import PublishingDomainContracts
import PublishingCoreSupport
import UniformTypeIdentifiers

struct PreparedWorkspaceExchangeImport: Sendable {
  let profiles: [SiteProfile]
  let drafts: [ArticleDraft]
  let stagingURL: URL
  let promotedAttachmentURLs: [URL]
}

enum WorkspaceExchangeTransferService {
  static func makeData(
    profiles: [SiteProfile],
    drafts: [ArticleDraft],
    attachmentRootURL: URL
  ) throws -> Data {
    var totalAttachmentBytes = 0
    let portableProfiles = profiles.map {
      WorkspaceExchangeProfile(
        id: $0.id,
        name: $0.name,
        siteKind: $0.siteKind.rawValue,
        repoOwner: $0.repoOwner,
        repoName: $0.repoName,
        branch: $0.branch
      )
    }
    let portableDrafts = try drafts.map { draft -> WorkspaceExchangeDraft in
      let attachmentValues = try draft.attachments.map { attachment -> WorkspaceExchangeAttachment in
        guard let sourcePath = attachment.sourceFilePath, !sourcePath.isEmpty else {
          throw WorkspaceExchangeError.attachmentDataUnavailable(attachment.originalFilename)
        }
        let sourceURL = URL(fileURLWithPath: sourcePath).standardizedFileURL
        let standardizedRoot = attachmentRootURL.standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/") ? standardizedRoot.path : standardizedRoot.path + "/"
        guard sourceURL.path.hasPrefix(rootPrefix) else {
          throw WorkspaceExchangeError.attachmentDataUnavailable(attachment.originalFilename)
        }
        let relativePath = String(sourceURL.path.dropFirst(rootPrefix.count))
        guard !relativePath.isEmpty,
          let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
          values.isRegularFile == true,
          let fileSize = values.fileSize, fileSize >= 0,
          fileSize <= WorkspaceExchangeCodec.maximumAttachmentByteCount
        else { throw WorkspaceExchangeError.attachmentDataUnavailable(attachment.originalFilename) }
        let bytes: Data
        do {
          bytes = try SafeFileReader.data(
            relativePath: relativePath,
            under: standardizedRoot,
            maximumByteCount: WorkspaceExchangeCodec.maximumAttachmentByteCount
          )
        }
        catch { throw WorkspaceExchangeError.attachmentDataUnavailable(attachment.originalFilename) }
        guard bytes.count == fileSize else {
          throw WorkspaceExchangeError.attachmentDataUnavailable(attachment.originalFilename)
        }
        totalAttachmentBytes += bytes.count
        guard totalAttachmentBytes <= WorkspaceExchangeCodec.maximumAttachmentByteCount else {
          throw WorkspaceExchangeError.payloadTooLarge
        }
        let ext = URL(fileURLWithPath: attachment.originalFilename).pathExtension
        let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return WorkspaceExchangeAttachment(
          id: attachment.id,
          originalFilename: attachment.originalFilename,
          mimeType: mimeType,
          relativePublishPath: attachment.relativePublishPath,
          role: draft.coverAttachmentID == attachment.id ? "cover" : "inline",
          altText: attachment.altText.isEmpty ? nil : attachment.altText,
          caption: attachment.caption.isEmpty ? nil : attachment.caption,
          bytes: bytes,
          sha256: digest
        )
      }
      let scope: String
      let sourceProfileID: UUID?
      switch draft.scope {
      case .general:
        scope = "general"
        sourceProfileID = nil
      case .site(let id):
        scope = "site"
        sourceProfileID = id
      }
      return WorkspaceExchangeDraft(
        id: draft.id,
        scope: scope,
        sourceProfileID: sourceProfileID,
        title: draft.title,
        date: draft.date,
        slug: draft.slug,
        tags: draft.tags,
        categories: draft.categories,
        authors: draft.authors,
        visibility: draft.visibility.rawValue,
        summary: draft.summary,
        bodyMarkdown: draft.bodyMarkdown,
        coverAttachmentID: draft.coverAttachmentID,
        createdAt: draft.createdAt,
        updatedAt: draft.updatedAt,
        attachments: attachmentValues
      )
    }
    return try WorkspaceExchangeCodec.encode(
      WorkspaceExchangePayload(profiles: portableProfiles, drafts: portableDrafts)
    )
  }

  static func prepareImport(
    package: WorkspaceExchangePackage,
    profileMappings: [UUID: WorkspaceExchangeProfileMapping],
    slugOverrides: [UUID: String] = [:],
    activeProfileID: UUID,
    attachmentStore: ManagedAttachmentFileStore,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) throws -> PreparedWorkspaceExchangeImport {
    let sourceProfileIDs = Set(package.payload.profiles.map(\.id))
    let requiredProfileIDs = Set(package.payload.drafts.compactMap { draft in
      draft.scope == "site" ? draft.sourceProfileID : nil
    })
    guard sourceProfileIDs.allSatisfy({ profileMappings[$0] != nil }),
      requiredProfileIDs.allSatisfy({ profileMappings[$0] != nil })
    else { throw WorkspaceExchangeError.invalidReference("站点草稿必须映射到现有或新站点配置") }

    let newProfilesBySourceID = Dictionary(uniqueKeysWithValues: package.payload.profiles.compactMap { source -> (UUID, SiteProfile)? in
      guard profileMappings[source.id] == .importAsNewProfile,
        let siteKind = SiteKind(rawValue: source.siteKind)
      else { return nil }
      return (source.id, SiteProfile(
        name: source.name,
        siteKind: siteKind,
        repoOwner: source.repoOwner,
        repoName: source.repoName,
        branch: source.branch
      ))
    })
    var destinationProfileIDs: [UUID: UUID] = [:]
    for sourceID in sourceProfileIDs {
      switch profileMappings[sourceID] {
      case .existing(let id): destinationProfileIDs[sourceID] = id
      case .importAsNewProfile: destinationProfileIDs[sourceID] = newProfilesBySourceID[sourceID]?.id
      case nil: break
      }
    }
    for sourceID in requiredProfileIDs where destinationProfileIDs[sourceID] == nil {
      guard case .existing(let destinationID)? = profileMappings[sourceID] else {
        throw WorkspaceExchangeError.invalidReference("来源站点配置未映射")
      }
      destinationProfileIDs[sourceID] = destinationID
    }

    let operationID = UUID().uuidString.lowercased()
    let stagingURL = temporaryDirectory
      .appendingPathComponent("WorkspaceExchangeImport-\(operationID)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)
    var promotedAttachmentURLs: [URL] = []
    var importedDrafts: [ArticleDraft] = []
    do {
      for sourceDraft in package.payload.drafts {
        try Task.checkCancellation()
        var attachmentIDMap: [UUID: UUID] = [:]
        var importedAttachments: [DraftAttachment] = []
        for sourceAttachment in sourceDraft.attachments {
          let newID = UUID()
          attachmentIDMap[sourceAttachment.id] = newID
          let stagingFile = stagingURL.appendingPathComponent("\(newID.uuidString.lowercased()).payload")
          try sourceAttachment.bytes.write(to: stagingFile, options: .atomic)
          let managedURL = try attachmentStore.storeFile(at: stagingFile, attachmentID: newID)
          promotedAttachmentURLs.append(managedURL)
          importedAttachments.append(DraftAttachment(
            id: newID,
            originalFilename: sourceAttachment.originalFilename,
            relativePublishPath: sourceAttachment.relativePublishPath,
            repositoryPath: "",
            altText: sourceAttachment.altText ?? "",
            caption: sourceAttachment.caption ?? "",
            byteSize: Int64(sourceAttachment.bytes.count),
            sourceFilePath: managedURL.path
          ))
        }
        let scope: ArticleDraftScope
        let siteProfileID: UUID
        if sourceDraft.scope == "site" {
          guard let sourceID = sourceDraft.sourceProfileID,
            let destinationID = destinationProfileIDs[sourceID]
          else { throw WorkspaceExchangeError.invalidReference("站点草稿缺少有效配置映射") }
          scope = .site(destinationID)
          siteProfileID = destinationID
        } else {
          scope = .general
          siteProfileID = activeProfileID
        }
        guard let visibility = ArticleVisibility(rawValue: sourceDraft.visibility) else {
          throw WorkspaceExchangeError.invalidFormat
        }
        let coverID = sourceDraft.coverAttachmentID.flatMap { attachmentIDMap[$0] }
        importedDrafts.append(ArticleDraft(
          id: UUID(),
          siteProfileID: siteProfileID,
          scope: scope,
          title: sourceDraft.title,
          date: sourceDraft.date,
          slug: slugOverrides[sourceDraft.id] ?? sourceDraft.slug,
          tags: sourceDraft.tags,
          categories: sourceDraft.categories,
          authors: sourceDraft.authors,
          draft: true,
          visibility: visibility,
          summary: sourceDraft.summary,
          coverAttachmentID: coverID,
          bodyMarkdown: sourceDraft.bodyMarkdown,
          attachments: importedAttachments,
          status: .draft,
          createdAt: sourceDraft.createdAt,
          updatedAt: sourceDraft.updatedAt
        ))
      }
      try Task.checkCancellation()
      let newProfiles = package.payload.profiles.compactMap { newProfilesBySourceID[$0.id] }
      return PreparedWorkspaceExchangeImport(
        profiles: newProfiles,
        drafts: importedDrafts,
        stagingURL: stagingURL,
        promotedAttachmentURLs: promotedAttachmentURLs
      )
    } catch {
      for url in promotedAttachmentURLs { try? attachmentStore.discardStoredFile(at: url) }
      try? FileManager.default.removeItem(at: stagingURL)
      throw error
    }
  }
}
