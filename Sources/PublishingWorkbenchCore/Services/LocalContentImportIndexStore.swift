import Darwin
import Foundation

struct LocalContentImportFileMetadata: Codable, Equatable, Sendable {
  var byteSize: Int64
  var deviceIdentifier: UInt64
  var fileIdentifier: UInt64
  var modifiedSeconds: Int64
  var modifiedNanoseconds: Int64
  var changedSeconds: Int64
  var changedNanoseconds: Int64

  static func read(from fileURL: URL) -> LocalContentImportFileMetadata? {
    let descriptor: Int32 = fileURL.withUnsafeFileSystemRepresentation { path in
      guard let path else { return Int32(-1) }
      return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }

    var fileStatus = stat()
    guard Darwin.fstat(descriptor, &fileStatus) == 0,
          (fileStatus.st_mode & S_IFMT) == S_IFREG else {
      return nil
    }
    return LocalContentImportFileMetadata(
      byteSize: Int64(fileStatus.st_size),
      deviceIdentifier: UInt64(fileStatus.st_dev),
      fileIdentifier: UInt64(fileStatus.st_ino),
      modifiedSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
      modifiedNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec),
      changedSeconds: Int64(fileStatus.st_ctimespec.tv_sec),
      changedNanoseconds: Int64(fileStatus.st_ctimespec.tv_nsec)
    )
  }
}

struct LocalContentImportAssetState: Codable, Equatable, Sendable {
  var repositoryPath: String
  var metadata: LocalContentImportFileMetadata?
}

struct LocalContentImportIndexEntry: Codable, Equatable, Sendable {
  var sourceMetadata: LocalContentImportFileMetadata
  var referencedAssets: [LocalContentImportAssetState]
  var draft: ArticleDraft

  func isCurrent(rootURL: URL, sourceURL: URL) -> Bool {
    guard LocalContentImportFileMetadata.read(from: sourceURL) == sourceMetadata else {
      return false
    }
    return referencedAssets.allSatisfy { asset in
      guard asset.metadata != nil else { return false }
      let fileURL = rootURL.appendingPathComponent(asset.repositoryPath)
      return LocalContentImportFileMetadata.read(from: fileURL) == asset.metadata
    }
  }
}

struct LocalContentImportIndexSnapshot: Codable, Sendable {
  static let currentSchemaVersion = 2

  var schemaVersion: Int
  var profileID: UUID
  var repositoryRootPath: String
  var configurationSignature: String
  var entries: [String: LocalContentImportIndexEntry]

  init(
    profileID: UUID,
    repositoryRootPath: String,
    configurationSignature: String,
    entries: [String: LocalContentImportIndexEntry] = [:]
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.profileID = profileID
    self.repositoryRootPath = repositoryRootPath
    self.configurationSignature = configurationSignature
    self.entries = entries
  }
}

/// Best-effort parsed-document cache for large local sites.
///
/// Correctness never depends on this file: an unreadable, oversized, stale or
/// incompatible index is ignored and rebuilt from the repository. Source and
/// referenced-asset metadata include inode plus nanosecond mtime/ctime so an
/// atomic replacement or an in-place edit invalidates the cached draft.
final class LocalContentImportIndexStore: @unchecked Sendable {
  static let maximumIndexByteCount = 128 * 1_024 * 1_024
  static let maximumEntryCount = 20_000

  private static let mutationLock = NSLock()
  private let fileSystem: SendableFileManager
  private let directoryURL: URL

  private var fileManager: FileManager { fileSystem.value }

  init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
    fileSystem = SendableFileManager(fileManager)
    self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
  }

  func snapshot(profile: SiteProfile, rootURL: URL) -> LocalContentImportIndexSnapshot {
    let rootPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    let signature = configurationSignature(profile: profile, rootPath: rootPath)
    let empty = LocalContentImportIndexSnapshot(
      profileID: profile.id,
      repositoryRootPath: rootPath,
      configurationSignature: signature
    )
    let indexURL = fileURL(profileID: profile.id)

    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }

    guard let attributes = try? fileManager.attributesOfItem(atPath: indexURL.path),
          let size = (attributes[.size] as? NSNumber)?.intValue,
          size > 0,
          size <= Self.maximumIndexByteCount,
          let data = try? Data(contentsOf: indexURL, options: .mappedIfSafe),
          let decoded = try? JSONDecoder.localContentImportIndex.decode(
            LocalContentImportIndexSnapshot.self,
            from: data
          ),
          decoded.schemaVersion == LocalContentImportIndexSnapshot.currentSchemaVersion,
          decoded.profileID == profile.id,
          decoded.repositoryRootPath == rootPath,
          decoded.configurationSignature == signature,
          decoded.entries.count <= Self.maximumEntryCount,
          Self.hasValidEntries(decoded.entries, profileID: profile.id) else {
      return empty
    }
    return decoded
  }

  func save(_ snapshot: LocalContentImportIndexSnapshot) {
    guard snapshot.entries.count <= Self.maximumEntryCount,
          let data = try? JSONEncoder.localContentImportIndex.encode(snapshot),
          data.count <= Self.maximumIndexByteCount else {
      return
    }

    Self.mutationLock.lock()
    defer { Self.mutationLock.unlock() }
    do {
      try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
      try data.write(to: fileURL(profileID: snapshot.profileID), options: .atomic)
    } catch {
      // The index is an optimization only. A later scan can rebuild it without
      // affecting imported content or surfacing a false repository failure.
    }
  }

  func entry(
    draft: ArticleDraft,
    sourceURL: URL,
    rootURL: URL,
    expectedSourceMetadata: LocalContentImportFileMetadata
  ) -> LocalContentImportIndexEntry? {
    guard let sourceMetadata = LocalContentImportFileMetadata.read(from: sourceURL),
          sourceMetadata == expectedSourceMetadata else {
      return nil
    }
    let assets = draft.attachments
      .map(\.repositoryPath)
      .filter { !$0.isEmpty }
      .sorted()
      .map { repositoryPath in
        LocalContentImportAssetState(
          repositoryPath: repositoryPath,
          metadata: LocalContentImportFileMetadata.read(
            from: rootURL.appendingPathComponent(repositoryPath)
          )
        )
      }
    guard assets.allSatisfy({ $0.metadata != nil }) else {
      return nil
    }
    return LocalContentImportIndexEntry(
      sourceMetadata: sourceMetadata,
      referencedAssets: assets,
      draft: draft
    )
  }

  private func configurationSignature(profile: SiteProfile, rootPath: String) -> String {
    [
      String(LocalContentImportIndexSnapshot.currentSchemaVersion),
      rootPath,
      profile.id.uuidString.lowercased(),
      profile.siteKind.rawValue,
      profile.contentRoot.normalizedRelativePath(),
      profile.assetRoot.normalizedRelativePath(),
      profile.dateFormat,
      profile.defaultAuthor,
      profile.markdownPathPattern,
    ].joined(separator: "\u{1F}")
  }

  private func fileURL(profileID: UUID) -> URL {
    directoryURL.appendingPathComponent(
      "\(profileID.uuidString.lowercased()).json",
      isDirectory: false
    )
  }

  private static func hasValidEntries(
    _ entries: [String: LocalContentImportIndexEntry],
    profileID: UUID
  ) -> Bool {
    entries.allSatisfy { repositoryPath, entry in
      isSafeRepositoryPath(repositoryPath)
        && entry.draft.repositoryPath == repositoryPath
        && entry.draft.belongs(toSiteProfileID: profileID)
        && entry.referencedAssets.allSatisfy {
          isSafeRepositoryPath($0.repositoryPath) && $0.metadata != nil
        }
    }
  }

  private static func isSafeRepositoryPath(_ path: String) -> Bool {
    guard !path.isEmpty,
          !path.hasPrefix("/"),
          !path.contains("\\"),
          !path.contains("\0"),
          path == path.normalizedRelativePath() else {
      return false
    }
    return !path.split(separator: "/", omittingEmptySubsequences: false)
      .contains(where: { $0 == ".." })
  }

  private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
    let cacheURL = fileManager.urls(
      for: .cachesDirectory,
      in: .userDomainMask
    ).first ?? fileManager.temporaryDirectory
    return cacheURL
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("ContentImportIndex", isDirectory: true)
  }
}

private extension JSONEncoder {
  static var localContentImportIndex: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
  }
}

private extension JSONDecoder {
  static var localContentImportIndex: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
  }
}
