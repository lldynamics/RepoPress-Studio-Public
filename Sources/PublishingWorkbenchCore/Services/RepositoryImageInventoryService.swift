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

public enum RepositoryImageInventoryError: LocalizedError, Equatable {
  case repositoryUnavailable
  case unsafeAssetRoot
  case assetDirectoryUnavailable(String)
  case invalidRepositoryPath
  case pathOutsideAssetRoot
  case unsupportedImageFormat
  case imageFileUnavailable(String)

  public var errorDescription: String? {
    switch self {
    case .repositoryUnavailable:
      CoreL10n.text("请先在“仓库与发布”中选择本地仓库。")
    case .unsafeAssetRoot:
      CoreL10n.text("图片目录路径不安全，请在设置中重新配置。")
    case .assetDirectoryUnavailable(let path):
      CoreL10n.format("找不到仓库图片目录：%@", path)
    case .invalidRepositoryPath:
      CoreL10n.text("仓库图片路径无效。")
    case .pathOutsideAssetRoot:
      CoreL10n.text("只能管理仓库图片目录内的文件。")
    case .unsupportedImageFormat:
      CoreL10n.text("该文件不是受支持的图片格式。")
    case .imageFileUnavailable(let path):
      CoreL10n.format("图片文件不存在或无法读取：%@", path)
    }
  }
}

public struct RepositoryImageInventoryService: Sendable {
  public static let maximumAssetCount = 5_000

  public init() {}

  public func inventoryAsync(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) async throws -> RepositoryImageInventory {
    let task = Task.detached(priority: .utility) {
      try self.inventory(drafts: drafts, profile: profile)
    }
    let result = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    return result
  }

  public func inventory(
    drafts: [ArticleDraft],
    profile: SiteProfile
  ) throws -> RepositoryImageInventory {
    guard let inventory = try profile.withLocalRepositoryRootAccess({ rootURL in
      try inventory(drafts: drafts, profile: profile, rootURL: rootURL)
    }) else {
      throw RepositoryImageInventoryError.repositoryUnavailable
    }
    return inventory
  }

  public func validatedAssetLocation(
    profile: SiteProfile,
    repositoryPath: String
  ) throws -> RepositoryImageAssetLocation {
    guard let location = try profile.withLocalRepositoryRootAccess({ rootURL in
      try validatedAssetLocation(
        rootURL: rootURL,
        assetRoot: profile.assetRoot,
        repositoryPath: repositoryPath
      )
    }) else {
      throw RepositoryImageInventoryError.repositoryUnavailable
    }
    return location
  }

  private func inventory(
    drafts: [ArticleDraft],
    profile: SiteProfile,
    rootURL: URL
  ) throws -> RepositoryImageInventory {
    try Task.checkCancellation()
    let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let normalizedAssetRoot = try normalizedAssetRoot(profile.assetRoot)
    let requestedAssetURL = canonicalRoot
      .appendingPathComponent(normalizedAssetRoot, isDirectory: true)
      .standardizedFileURL
    let canonicalAssetURL = requestedAssetURL.standardizedFileURL.resolvingSymlinksInPath()
    guard canonicalAssetURL.path == requestedAssetURL.path,
          isDescendantOrSame(canonicalAssetURL, root: canonicalRoot) else {
      throw RepositoryImageInventoryError.unsafeAssetRoot
    }

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonicalAssetURL.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
      throw RepositoryImageInventoryError.assetDirectoryUnavailable(normalizedAssetRoot)
    }

    let references = try referencesByRepositoryPath(drafts: drafts)
    let keys: Set<URLResourceKey> = [
      .isRegularFileKey,
      .isDirectoryKey,
      .isSymbolicLinkKey,
      .fileSizeKey,
      .contentModificationDateKey,
    ]
    guard let enumerator = FileManager.default.enumerator(
      at: canonicalAssetURL,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
      throw RepositoryImageInventoryError.assetDirectoryUnavailable(normalizedAssetRoot)
    }

    var assets: [RepositoryImageAsset] = []
    var wasTruncated = false
    for case let fileURL as URL in enumerator {
      try Task.checkCancellation()
      let values = try? fileURL.resourceValues(forKeys: keys)
      if values?.isSymbolicLink == true {
        if values?.isDirectory == true {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values?.isRegularFile == true,
            ImageFileSupport.isSupportedImageURL(fileURL) else {
        continue
      }

      let canonicalFileURL = fileURL.standardizedFileURL.resolvingSymlinksInPath()
      guard isDescendantOrSame(canonicalFileURL, root: canonicalAssetURL),
            isDescendantOrSame(canonicalFileURL, root: canonicalRoot),
            let repositoryPath = relativePath(of: canonicalFileURL, root: canonicalRoot) else {
        continue
      }

      if assets.count >= Self.maximumAssetCount {
        wasTruncated = true
        break
      }
      let normalizedPath = repositoryPath.normalizedRelativePath()
      assets.append(
        RepositoryImageAsset(
          repositoryPath: normalizedPath,
          absoluteFilePath: canonicalFileURL.path,
          filename: canonicalFileURL.lastPathComponent,
          fileExtension: canonicalFileURL.pathExtension.uppercased(),
          byteSize: Int64(values?.fileSize ?? 0),
          modifiedAt: values?.contentModificationDate,
          references: references[normalizedPath] ?? []
        )
      )
    }

    assets.sort {
      $0.repositoryPath.localizedStandardCompare($1.repositoryPath) == .orderedAscending
    }
    return RepositoryImageInventory(
      profileID: profile.id,
      repositoryRootPath: canonicalRoot.path,
      assetRootPath: normalizedAssetRoot,
      assets: assets,
      wasTruncated: wasTruncated
    )
  }

  private func validatedAssetLocation(
    rootURL: URL,
    assetRoot: String,
    repositoryPath: String
  ) throws -> RepositoryImageAssetLocation {
    let canonicalRoot = rootURL.standardizedFileURL.resolvingSymlinksInPath()
    let normalizedAssetRoot = try normalizedAssetRoot(assetRoot)
    let normalizedPath = try normalizedRepositoryPath(repositoryPath)
    guard normalizedPath == normalizedAssetRoot
      || normalizedPath.hasPrefix(normalizedAssetRoot + "/") else {
      throw RepositoryImageInventoryError.pathOutsideAssetRoot
    }
    guard ImageFileSupport.isSupportedImagePath(normalizedPath) else {
      throw RepositoryImageInventoryError.unsupportedImageFormat
    }

    let canonicalAssetURL = canonicalRoot
      .appendingPathComponent(normalizedAssetRoot, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    let requestedAssetURL = canonicalRoot
      .appendingPathComponent(normalizedAssetRoot, isDirectory: true)
      .standardizedFileURL
    let candidateURL = canonicalRoot
      .appendingPathComponent(normalizedPath)
      .standardizedFileURL
      .resolvingSymlinksInPath()
    guard canonicalAssetURL.path == requestedAssetURL.path,
          isDescendantOrSame(canonicalAssetURL, root: canonicalRoot),
          isDescendantOrSame(candidateURL, root: canonicalAssetURL),
          isDescendantOrSame(candidateURL, root: canonicalRoot) else {
      throw RepositoryImageInventoryError.pathOutsideAssetRoot
    }

    let values = try? candidateURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard values?.isRegularFile == true else {
      throw RepositoryImageInventoryError.imageFileUnavailable(normalizedPath)
    }
    return RepositoryImageAssetLocation(
      repositoryPath: normalizedPath,
      absoluteFilePath: candidateURL.path,
      byteSize: Int64(values?.fileSize ?? 0)
    )
  }

  private func referencesByRepositoryPath(
    drafts: [ArticleDraft]
  ) throws -> [String: [RepositoryImageReference]] {
    var output: [String: [RepositoryImageReference]] = [:]
    for draft in drafts {
      try Task.checkCancellation()
      let title = draft.title.trimmedForPublishing.nilIfEmpty ?? CoreL10n.text("未命名文章")
      for attachment in draft.attachments where attachment.mediaKind == .image {
        try Task.checkCancellation()
        let path = attachment.repositoryPath.normalizedRelativePath()
        guard !path.isEmpty else { continue }
        let reference = RepositoryImageReference(
          draftID: draft.id,
          draftTitle: title,
          isCover: draft.coverAttachmentID == attachment.id
        )
        var pathReferences = output[path] ?? []
        if let existingIndex = pathReferences.firstIndex(where: { $0.draftID == draft.id }) {
          if reference.isCover, !pathReferences[existingIndex].isCover {
            pathReferences[existingIndex] = reference
          }
        } else {
          pathReferences.append(reference)
        }
        output[path] = pathReferences
      }
    }
    for key in Array(output.keys) {
      output[key]?.sort {
        $0.draftTitle.localizedStandardCompare($1.draftTitle) == .orderedAscending
      }
    }
    return output
  }

  private func normalizedAssetRoot(_ path: String) throws -> String {
    let normalized = try normalizedRepositoryPath(path)
    guard !normalized.isEmpty else {
      throw RepositoryImageInventoryError.unsafeAssetRoot
    }
    return normalized
  }

  private func normalizedRepositoryPath(_ path: String) throws -> String {
    let trimmed = path.trimmedForPublishing.replacingOccurrences(of: "\\", with: "/")
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false)
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("/"),
          !components.contains(where: { $0 == ".." }) else {
      throw RepositoryImageInventoryError.invalidRepositoryPath
    }
    let normalized = trimmed.normalizedRelativePath()
    guard !normalized.isEmpty else {
      throw RepositoryImageInventoryError.invalidRepositoryPath
    }
    return normalized
  }

  private func isDescendantOrSame(_ candidate: URL, root: URL) -> Bool {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    return candidate.path == root.path || candidate.path.hasPrefix(rootPath)
  }

  private func relativePath(of candidate: URL, root: URL) -> String? {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard candidate.path.hasPrefix(rootPath) else { return nil }
    return String(candidate.path.dropFirst(rootPath.count))
  }
}
