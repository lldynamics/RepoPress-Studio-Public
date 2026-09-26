import CryptoKit
import Foundation
import PublishingDomainContracts

public enum WorkspaceExchangeCodec {
  public static let fileExtension = "rpworkspaceexchange"
  public static let maximumPackageByteCount = 80 * 1_024 * 1_024
  public static let maximumAttachmentByteCount = 40 * 1_024 * 1_024
  public static let maximumProfileCount = 1_000
  public static let maximumDraftCount = 10_000
  public static let maximumAttachmentCount = 50_000
  private static let format = "com.repopress.workspace-exchange"

  public static func encode(
    _ payload: WorkspaceExchangePayload,
    createdAt: Date = Date()
  ) throws -> Data {
    try validate(payload)
    let payloadBytes = try encoder().encode(payload)
    let digest = sha256(payloadBytes)
    let manifest = WorkspaceExchangeManifest(
      createdAt: createdAt,
      payloadSHA256: digest,
      itemCounts: itemCounts(for: payload)
    )
    let data = try encoder().encode(WorkspaceExchangePackage(manifest: manifest, payload: payload))
    guard data.count <= maximumPackageByteCount else {
      throw WorkspaceExchangeError.payloadTooLarge
    }
    return data
  }

  public static func decode(_ data: Data) throws -> WorkspaceExchangePackage {
    guard data.count <= maximumPackageByteCount else {
      throw WorkspaceExchangeError.payloadTooLarge
    }
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw WorkspaceExchangeError.invalidFormat
    }
    try rejectNulls(root)
    try validateKeys(root, exactly: ["manifest", "payload"])
    guard let manifest = root["manifest"] as? [String: Any],
      let rawPayload = root["payload"] as? [String: Any]
    else { throw WorkspaceExchangeError.invalidFormat }
    try validateKeys(
      manifest, exactly: ["format", "version", "createdAt", "payloadSHA256", "itemCounts"])
    try validateKeys(rawPayload, exactly: ["profiles", "drafts"])
    guard let rawCounts = manifest["itemCounts"] as? [String: Any] else {
      throw WorkspaceExchangeError.invalidFormat
    }
    try validateKeys(rawCounts, exactly: ["profiles", "drafts", "attachments"])
    try validateNestedKeys(payload: rawPayload)
    try validateDateStrings(in: root)

    let package: WorkspaceExchangePackage
    do { package = try decoder().decode(WorkspaceExchangePackage.self, from: data) } catch {
      throw WorkspaceExchangeError.invalidFormat
    }
    guard package.manifest.format == format else { throw WorkspaceExchangeError.invalidFormat }
    guard package.manifest.version == 1 else {
      throw WorkspaceExchangeError.unsupportedVersion(package.manifest.version)
    }
    try validate(package.payload)
    guard package.manifest.itemCounts == itemCounts(for: package.payload) else {
      throw WorkspaceExchangeError.invalidFormat
    }
    let canonicalPayload = try encoder().encode(package.payload)
    guard package.manifest.payloadSHA256 == sha256(canonicalPayload) else {
      throw WorkspaceExchangeError.invalidPayloadHash
    }
    // Re-encoding also verifies the decoded shape remains within the package cap.
    guard try encoder().encode(package).count <= maximumPackageByteCount else {
      throw WorkspaceExchangeError.payloadTooLarge
    }
    return package
  }

  public static func itemCounts(for payload: WorkspaceExchangePayload)
    -> WorkspaceExchangeItemCounts
  {
    WorkspaceExchangeItemCounts(
      profiles: payload.profiles.count,
      drafts: payload.drafts.count,
      attachments: payload.drafts.reduce(0) { $0 + $1.attachments.count }
    )
  }

  public static func isSafeRelativePublishPath(_ path: String) -> Bool {
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty else { return false }
    return components.allSatisfy { component in
      component != "." && component != ".." && !component.isEmpty
        && !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
  }

  private static func validate(_ payload: WorkspaceExchangePayload) throws {
    let attachmentCount = payload.drafts.reduce(0) { $0 + $1.attachments.count }
    guard payload.profiles.count <= maximumProfileCount,
      payload.drafts.count <= maximumDraftCount,
      attachmentCount <= maximumAttachmentCount
    else { throw WorkspaceExchangeError.payloadTooLarge }
    guard !payload.profiles.isEmpty || !payload.drafts.isEmpty else {
      throw WorkspaceExchangeError.invalidFormat
    }
    let profileIDs = payload.profiles.map(\.id)
    let draftIDs = payload.drafts.map(\.id)
    guard Set(profileIDs).count == profileIDs.count, Set(draftIDs).count == draftIDs.count else {
      throw WorkspaceExchangeError.invalidReference("重复的 profile 或 draft ID")
    }
    for profile in payload.profiles {
      guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        SiteKind(rawValue: profile.siteKind) != nil,
        !containsControlCharacters(profile.name),
        !containsControlCharacters(profile.repoOwner),
        !containsControlCharacters(profile.repoName),
        !containsControlCharacters(profile.branch)
      else { throw WorkspaceExchangeError.invalidFormat }
    }

    var allAttachmentIDs = Set<UUID>()
    var totalAttachmentBytes = 0
    for draft in payload.drafts {
      guard draft.scope == "site" || draft.scope == "general",
        ArticleVisibility(rawValue: draft.visibility) != nil,
        !containsControlCharacters(draft.slug),
        draft.targetWordCount.map({ (1...1_000_000).contains($0) }) ?? true
      else { throw WorkspaceExchangeError.invalidFormat }
      if draft.scope == "site" {
        guard draft.sourceProfileID != nil else {
          throw WorkspaceExchangeError.invalidReference("站点草稿缺少 sourceProfileID")
        }
      } else if draft.sourceProfileID != nil {
        throw WorkspaceExchangeError.invalidReference("通用草稿不得包含 sourceProfileID")
      }
      let attachments = draft.attachments
      let ids = attachments.map(\.id)
      guard Set(ids).count == ids.count else {
        throw WorkspaceExchangeError.invalidReference("同一草稿内附件 ID 重复")
      }
      let publishPaths = attachments.map { $0.relativePublishPath.lowercased() }
      guard Set(publishPaths).count == publishPaths.count else {
        throw WorkspaceExchangeError.invalidReference("同一草稿内附件发布路径重复")
      }
      for attachment in attachments {
        guard allAttachmentIDs.insert(attachment.id).inserted else {
          throw WorkspaceExchangeError.invalidReference("附件 ID 必须在整个包中唯一")
        }
        guard attachment.role == "inline" || attachment.role == "cover",
          isSafeRelativePublishPath(attachment.relativePublishPath),
          !attachment.originalFilename.isEmpty,
          !containsControlCharacters(attachment.originalFilename),
          !attachment.mimeType.isEmpty,
          !containsControlCharacters(attachment.mimeType)
        else { throw WorkspaceExchangeError.invalidPath(attachment.relativePublishPath) }
        totalAttachmentBytes += attachment.bytes.count
        guard totalAttachmentBytes <= maximumAttachmentByteCount else {
          throw WorkspaceExchangeError.payloadTooLarge
        }
        guard sha256(attachment.bytes) == attachment.sha256 else {
          throw WorkspaceExchangeError.invalidAttachmentHash(attachment.originalFilename)
        }
      }
      if let coverID = draft.coverAttachmentID {
        guard let cover = attachments.first(where: { $0.id == coverID }), cover.role == "cover"
        else {
          throw WorkspaceExchangeError.invalidReference("coverAttachmentID 未指向封面附件")
        }
      }
      guard attachments.filter({ $0.role == "cover" }).count <= 1 else {
        throw WorkspaceExchangeError.invalidReference("每篇草稿最多一个封面附件")
      }
    }
  }

  private static func validateKeys(_ object: [String: Any], exactly allowed: Set<String>) throws {
    guard Set(object.keys) == allowed else { throw WorkspaceExchangeError.invalidFormat }
  }

  private static func validateNestedKeys(payload: [String: Any]) throws {
    guard let profiles = payload["profiles"] as? [[String: Any]],
      let drafts = payload["drafts"] as? [[String: Any]]
    else { throw WorkspaceExchangeError.invalidFormat }
    for profile in profiles {
      try validateKeys(
        profile, exactly: ["id", "name", "siteKind", "repoOwner", "repoName", "branch"])
    }
    for draft in drafts {
      let draftKeys: Set<String> = [
        "id", "scope", "title", "date", "slug", "tags", "categories", "authors",
        "visibility", "summary", "bodyMarkdown", "createdAt", "updatedAt", "attachments",
      ]
      let optionalDraftKeys: Set<String> = [
        "sourceProfileID", "coverAttachmentID", "targetWordCount",
      ]
      guard Set(draft.keys).isSubset(of: draftKeys.union(optionalDraftKeys)),
        draftKeys.isSubset(of: Set(draft.keys))
      else { throw WorkspaceExchangeError.invalidFormat }
      guard let attachments = draft["attachments"] as? [[String: Any]] else {
        throw WorkspaceExchangeError.invalidFormat
      }
      for attachment in attachments {
        let required: Set<String> = [
          "id", "originalFilename", "mimeType", "relativePublishPath", "role", "bytes", "sha256",
        ]
        let optional: Set<String> = ["altText", "caption"]
        guard required.isSubset(of: Set(attachment.keys)),
          Set(attachment.keys).isSubset(of: required.union(optional))
        else { throw WorkspaceExchangeError.invalidFormat }
      }
    }
  }

  private static func rejectNulls(_ value: Any) throws {
    if value is NSNull { throw WorkspaceExchangeError.invalidFormat }
    if let object = value as? [String: Any] {
      for child in object.values { try rejectNulls(child) }
    } else if let array = value as? [Any] {
      for child in array { try rejectNulls(child) }
    }
  }

  private static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func validateDateStrings(in value: Any) throws {
    if let object = value as? [String: Any] {
      for (key, child) in object {
        if ["createdAt", "updatedAt", "date"].contains(key) {
          guard let text = child as? String,
            text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression)
              != nil,
            text.count == 20,
            ISO8601DateFormatter().date(from: text) != nil
          else {
            throw WorkspaceExchangeError.invalidFormat
          }
        }
        try validateDateStrings(in: child)
      }
    } else if let array = value as? [Any] {
      for child in array { try validateDateStrings(in: child) }
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
