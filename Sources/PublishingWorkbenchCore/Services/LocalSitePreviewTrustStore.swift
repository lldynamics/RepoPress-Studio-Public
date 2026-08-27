import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum LocalSitePreviewExecutionFingerprint {
  static let maximumManifestByteCount = 1 * 1_024 * 1_024

  struct ManifestSnapshot: Sendable {
    fileprivate let entries: [ManifestEntry]

    func data(relativePath: String) -> Data? {
      entries.first { $0.relativePath == relativePath }?.data
    }
  }

  fileprivate struct ManifestEntry: Sendable {
    let relativePath: String
    let data: Data?
  }

  private struct ManifestDigestComponent: Codable {
    let relativePath: String
    let state: String
    let contentDigest: String?
  }

  private struct FingerprintMaterial: Codable {
    let profileID: UUID
    let canonicalRootPath: String
    let siteKind: SiteKind
    let executablePath: String
    let resolvedExecutablePath: String
    let arguments: [String]
    let command: String
    let manifestRelativePaths: [String]
    let manifestDigest: String
  }

  static func manifestRelativePaths(for siteKind: SiteKind) -> [String] {
    switch siteKind {
    case .astro, .vitePress, .nextJS, .quartz, .hexo:
      return ["package.json"]
    case .jekyll:
      return ["Gemfile", "Gemfile.lock"]
    case .zola, .hugo, .foam:
      return []
    }
  }

  static func captureManifest(
    rootPath: String,
    siteKind: SiteKind
  ) throws -> ManifestSnapshot {
    let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
    let entries = try manifestRelativePaths(for: siteKind).map { relativePath in
      let fileURL = rootURL.appendingPathComponent(relativePath, isDirectory: false)
      guard pathExistsWithoutFollowing(at: fileURL) else {
        return ManifestEntry(relativePath: relativePath, data: nil)
      }
      let data = try BoundedFileReader.data(
        relativePath: relativePath,
        under: rootURL,
        maximumByteCount: maximumManifestByteCount
      )
      return ManifestEntry(relativePath: relativePath, data: data)
    }
    return ManifestSnapshot(entries: entries)
  }

  static func makeIdentity(
    profileID: UUID,
    rootPath: String,
    siteKind: SiteKind,
    executablePath: String,
    arguments: [String],
    command: String,
    manifestSnapshot: ManifestSnapshot? = nil
  ) throws -> LocalSitePreviewExecutionIdentity {
    let canonicalRootPath = URL(fileURLWithPath: rootPath, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
      .path
    let standardizedExecutablePath = URL(fileURLWithPath: executablePath)
      .standardizedFileURL
      .path
    let resolvedExecutablePath = URL(fileURLWithPath: standardizedExecutablePath)
      .resolvingSymlinksInPath()
      .standardizedFileURL
      .path
    let manifestRelativePaths = manifestRelativePaths(for: siteKind)
    let snapshot = try manifestSnapshot ?? captureManifest(
      rootPath: canonicalRootPath,
      siteKind: siteKind
    )
    let manifestDigest = try digest(snapshot: snapshot)
    let material = FingerprintMaterial(
      profileID: profileID,
      canonicalRootPath: canonicalRootPath,
      siteKind: siteKind,
      executablePath: standardizedExecutablePath,
      resolvedExecutablePath: resolvedExecutablePath,
      arguments: arguments,
      command: command,
      manifestRelativePaths: manifestRelativePaths,
      manifestDigest: manifestDigest
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let fingerprint = sha256(try encoder.encode(material))
    return LocalSitePreviewExecutionIdentity(
      profileID: profileID,
      canonicalRootPath: canonicalRootPath,
      siteKind: siteKind,
      executablePath: standardizedExecutablePath,
      resolvedExecutablePath: resolvedExecutablePath,
      arguments: arguments,
      command: command,
      manifestRelativePaths: manifestRelativePaths,
      manifestDigest: manifestDigest,
      fingerprint: fingerprint
    )
  }

  static func currentIdentity(
    for plan: LocalSitePreviewPlan,
    plannedIdentity: LocalSitePreviewExecutionIdentity
  ) throws -> LocalSitePreviewExecutionIdentity {
    try makeIdentity(
      profileID: plannedIdentity.profileID,
      rootPath: plan.rootPath,
      siteKind: plan.siteKind,
      executablePath: plan.executablePath,
      arguments: plan.arguments,
      command: plan.command
    )
  }

  private static func digest(snapshot: ManifestSnapshot) throws -> String {
    let components = snapshot.entries.map { entry in
      ManifestDigestComponent(
        relativePath: entry.relativePath,
        state: entry.data == nil ? "missing" : "contents",
        contentDigest: entry.data.map(sha256)
      )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return sha256(try encoder.encode(components))
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func pathExistsWithoutFollowing(at url: URL) -> Bool {
#if canImport(Darwin)
    var metadata = stat()
    return url.path.withCString { Darwin.lstat($0, &metadata) } == 0
#else
    return (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])) != nil
#endif
  }
}

final class LocalSitePreviewTrustStore: @unchecked Sendable {
  private static let schemaVersion = 1
  private static let maximumStoreByteCount = 512 * 1_024

  private struct Document: Codable {
    let schemaVersion: Int
    var records: [Record]
  }

  private struct Record: Codable, Hashable {
    let profileID: UUID
    let canonicalRootPath: String
    let siteKind: SiteKind
    let executablePath: String
    let resolvedExecutablePath: String
    let arguments: [String]
    let command: String
    let manifestRelativePaths: [String]
    let manifestDigest: String
    let fingerprint: String
    let authorizedAt: Date

    init(identity: LocalSitePreviewExecutionIdentity, authorizedAt: Date) {
      profileID = identity.profileID
      canonicalRootPath = identity.canonicalRootPath
      siteKind = identity.siteKind
      executablePath = identity.executablePath
      resolvedExecutablePath = identity.resolvedExecutablePath
      arguments = identity.arguments
      command = identity.command
      manifestRelativePaths = identity.manifestRelativePaths
      manifestDigest = identity.manifestDigest
      fingerprint = identity.fingerprint
      self.authorizedAt = authorizedAt
    }

    func matches(_ identity: LocalSitePreviewExecutionIdentity) -> Bool {
      profileID == identity.profileID
        && canonicalRootPath == identity.canonicalRootPath
        && siteKind == identity.siteKind
        && executablePath == identity.executablePath
        && resolvedExecutablePath == identity.resolvedExecutablePath
        && arguments == identity.arguments
        && command == identity.command
        && manifestRelativePaths == identity.manifestRelativePaths
        && manifestDigest == identity.manifestDigest
        && fingerprint == identity.fingerprint
    }

    func belongs(to identity: LocalSitePreviewExecutionIdentity) -> Bool {
      profileID == identity.profileID && canonicalRootPath == identity.canonicalRootPath
    }
  }

  let fileURL: URL
  let maximumRecordCount: Int

  private let fileManager: FileManager
  private let lock = NSLock()

  init(
    fileURL: URL? = nil,
    maximumRecordCount: Int = 64,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
    self.maximumRecordCount = min(max(maximumRecordCount, 1), 256)
  }

  static func defaultFileURL(fileManager: FileManager = .default) -> URL {
    guard let supportURL = fileManager.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      return URL(fileURLWithPath: "/.repopress-application-support-unavailable", isDirectory: true)
        .appendingPathComponent("local-site-preview-trust.json")
    }
    return supportURL
      .appendingPathComponent("RepoPress Studio", isDirectory: true)
      .appendingPathComponent("local-site-preview-trust.json")
  }

  func isAuthorized(_ identity: LocalSitePreviewExecutionIdentity) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !identity.fingerprint.isEmpty else { return false }
    do {
      return try loadDocument().records.contains { $0.matches(identity) }
    } catch {
      return false
    }
  }

  func authorize(_ identity: LocalSitePreviewExecutionIdentity) throws {
    lock.lock()
    defer { lock.unlock() }
    guard !identity.fingerprint.isEmpty else {
      throw LocalSitePreviewError.executionPlanChanged
    }

    let existingRecords: [Record]
    do {
      existingRecords = try loadDocument().records
    } catch {
      // A new explicit confirmation may replace an unreadable legacy or corrupt
      // document; the subsequent guarded write must still succeed before use.
      existingRecords = []
    }
    var records = existingRecords.filter { !$0.belongs(to: identity) }
    records.append(Record(identity: identity, authorizedAt: Date()))
    records.sort { $0.authorizedAt > $1.authorizedAt }
    if records.count > maximumRecordCount {
      records.removeLast(records.count - maximumRecordCount)
    }
    do {
      try write(Document(schemaVersion: Self.schemaVersion, records: records))
    } catch {
      throw LocalSitePreviewError.authorizationStoreUnavailable(error.localizedDescription)
    }
  }

  func invalidate(_ identity: LocalSitePreviewExecutionIdentity) {
    lock.lock()
    defer { lock.unlock() }
    do {
      var document = try loadDocument()
      let originalCount = document.records.count
      document.records.removeAll { $0.belongs(to: identity) }
      guard document.records.count != originalCount else { return }
      try write(document)
    } catch {
      // Identity revalidation still rejects the changed plan in this process;
      // invalidation is best-effort when the backing store is unavailable.
      return
    }
  }

  private func loadDocument() throws -> Document {
    try validateContainerDirectoryIfPresent()
    if isSymbolicLink(at: fileURL) {
      throw CocoaError(.fileReadNoPermission)
    }
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return Document(schemaVersion: Self.schemaVersion, records: [])
    }
    let data = try BoundedFileReader.data(
      at: fileURL,
      maximumByteCount: Self.maximumStoreByteCount
    )
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let document = try decoder.decode(Document.self, from: data)
    guard document.schemaVersion == Self.schemaVersion,
      document.records.count <= maximumRecordCount
    else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return document
  }

  private func write(_ document: Document) throws {
    try validateContainerDirectoryIfPresent()
    guard !isSymbolicLink(at: fileURL) else {
      throw CocoaError(.fileWriteNoPermission)
    }
    let parentURL = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
    try validateContainerDirectoryIfPresent()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(document)
    guard data.count <= Self.maximumStoreByteCount else {
      throw CocoaError(.fileWriteOutOfSpace)
    }
    try data.write(to: fileURL, options: .atomic)
    guard !isSymbolicLink(at: fileURL) else {
      throw CocoaError(.fileWriteNoPermission)
    }
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
  }

  /// The trust document must never be redirected through a substituted app
  /// support directory. The final container is the app-owned boundary; its
  /// ancestors may legitimately contain platform symlinks (for example /var).
  private func validateContainerDirectoryIfPresent() throws {
    let parentURL = fileURL.deletingLastPathComponent()
#if canImport(Darwin)
    var metadata = stat()
    let result = parentURL.path.withCString { Darwin.lstat($0, &metadata) }
    if result != 0 {
      if errno == ENOENT { return }
      throw CocoaError(.fileReadNoPermission)
    }
    guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
      throw CocoaError(.fileReadNoPermission)
    }
#else
    guard fileManager.fileExists(atPath: parentURL.path) else { return }
    let values = try parentURL.resourceValues(forKeys: [
      .isDirectoryKey,
      .isSymbolicLinkKey,
    ])
    guard values.isDirectory == true, values.isSymbolicLink != true else {
      throw CocoaError(.fileReadNoPermission)
    }
#endif
  }

  private func isSymbolicLink(at url: URL) -> Bool {
#if canImport(Darwin)
    var metadata = stat()
    guard url.path.withCString({ Darwin.lstat($0, &metadata) }) == 0 else {
      return false
    }
    return (metadata.st_mode & S_IFMT) == S_IFLNK
#else
    return (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
#endif
  }
}
