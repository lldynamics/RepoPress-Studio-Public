import CryptoKit
import Foundation

#if canImport(Darwin)
  import Darwin
#endif

public enum PublishFileDiffStatus: String, Codable, Sendable {
  case added
  case modified
  case deleted
  case unchanged
  case missingSource
  case unsafePath

  public var displayName: String {
    switch self {
    case .added:
      return "新增"
    case .modified:
      return "修改"
    case .deleted:
      return "删除"
    case .unchanged:
      return "未变化"
    case .missingSource:
      return "源文件缺失"
    case .unsafePath:
      return "路径不安全"
    }
  }
}

public struct LocalPublishSourceFileState: Codable, Hashable, Sendable {
  public var byteSize: Int64
  public var sha256: Data
  public var deviceIdentifier: UInt64
  public var fileIdentifier: UInt64

  public init(
    byteSize: Int64,
    sha256: Data,
    deviceIdentifier: UInt64,
    fileIdentifier: UInt64
  ) {
    self.byteSize = byteSize
    self.sha256 = sha256
    self.deviceIdentifier = deviceIdentifier
    self.fileIdentifier = fileIdentifier
  }
}

public struct PublishFileDiff: Identifiable, Codable, Hashable, Sendable {
  public var id: String { path }
  public var path: String
  public var kind: PublishFileKind
  public var status: PublishFileDiffStatus
  public var lineDiff: String?
  public var byteSize: Int64
  public var baselineState: LocalPublishFileState?
  public var sourceState: LocalPublishSourceFileState?

  public init(
    path: String,
    kind: PublishFileKind,
    status: PublishFileDiffStatus,
    lineDiff: String? = nil,
    byteSize: Int64 = 0,
    baselineState: LocalPublishFileState? = nil,
    sourceState: LocalPublishSourceFileState? = nil
  ) {
    self.path = path
    self.kind = kind
    self.status = status
    self.lineDiff = lineDiff
    self.byteSize = byteSize
    self.baselineState = baselineState
    self.sourceState = sourceState
  }
}

public struct LocalPublishPreview: Codable, Hashable, Sendable {
  public var package: PublishPackage
  public var fileDiffs: [PublishFileDiff]
  public var issues: [PreflightIssue]
  public var generatedAt: Date

  public init(
    package: PublishPackage,
    fileDiffs: [PublishFileDiff],
    issues: [PreflightIssue],
    generatedAt: Date = Date()
  ) {
    self.package = package
    self.fileDiffs = fileDiffs
    self.issues = issues
    self.generatedAt = generatedAt
  }

  public var changedFileDiffs: [PublishFileDiff] {
    fileDiffs.filter { $0.status != .unchanged }
  }
}

public struct LocalPublishPreviewService: Sendable {
  static let transactionFileName = ".repopress-local-publish-transaction.json"
  private let fileSystem: SendableFileManager

  var fileManager: FileManager { fileSystem.value }

  public init(fileManager: FileManager = .default) {
    self.fileSystem = SendableFileManager(fileManager)
  }

  public func preview(package: PublishPackage, profile: SiteProfile) -> LocalPublishPreview {
    guard
      let preview = profile.withLocalRepositoryRootAccess({ rootURL in
        var result = preview(package: package, rootURL: rootURL)
        for path in Set([package.markdownPath] + package.files.map(\.repositoryPath))
        where StructuralArticlePathPolicy.isProtected(path, profile: profile) {
          result.issues.append(StructuralArticlePathPolicy.issue(path: path))
        }
        return result
      })
    else {
      return missingRepositoryPreview(package: package)
    }

    return preview
  }

  /// Generates the same preview as ``preview(package:profile:)`` without
  /// performing repository traversal or file reads on the caller's executor.
  ///
  /// The synchronous implementation is invoked entirely inside the detached
  /// task so repository file reads stay off the caller's executor.
  public func previewAsync(package: PublishPackage, profile: SiteProfile) async
    -> LocalPublishPreview
  {
    await Task.detached(priority: .userInitiated) {
      preview(package: package, profile: profile)
    }.value
  }

  public func write(package: PublishPackage, profile: SiteProfile) throws -> [String] {
    try validateArticleWrite(package: package, profile: profile)
    guard
      let writtenPaths = try profile.withLocalRepositoryRootAccess({ rootURL in
        try requireRepositoryRootForProfileWrite(profile: profile, rootURL: rootURL)
        return try write(package: package, rootURL: rootURL, purpose: .article(profile))
      })
    else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }

    return writtenPaths
  }

  public func write(preview: LocalPublishPreview, profile: SiteProfile) throws -> [String] {
    try validateArticleWrite(package: preview.package, profile: profile)
    guard
      let writtenPaths = try profile.withLocalRepositoryRootAccess({ rootURL in
        try requireRepositoryRootForProfileWrite(profile: profile, rootURL: rootURL)
        return try write(preview: preview, rootURL: rootURL, purpose: .article(profile))
      })
    else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }

    return writtenPaths
  }

  public func writeAsync(package: PublishPackage, profile: SiteProfile) async throws -> [String] {
    try validateArticleWrite(package: package, profile: profile)
    guard let rootURL = profile.localRepositoryRootURL else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }
    return try await Task.detached(priority: .userInitiated) {
      try requireRepositoryRootForProfileWrite(profile: profile, rootURL: rootURL)
      return try write(package: package, rootURL: rootURL, purpose: .article(profile))
    }.value
  }

  public func writeAsync(preview: LocalPublishPreview, profile: SiteProfile) async throws
    -> [String]
  {
    try validateArticleWrite(package: preview.package, profile: profile)
    guard let rootURL = profile.localRepositoryRootURL else {
      throw LocalPublishPreviewError.missingRepositoryRoot
    }
    return try await Task.detached(priority: .userInitiated) {
      try requireRepositoryRootForProfileWrite(profile: profile, rootURL: rootURL)
      return try write(preview: preview, rootURL: rootURL, purpose: .article(profile))
    }.value
  }

  /// Profile-backed writes materialize content inside a repository selected by
  /// the user. Publishing and repository-backup profiles must point at the
  /// repository root itself; otherwise autosave could silently write into an
  /// unrelated look-alike directory and never enter the Git publish flow.
  func requireRepositoryRootForProfileWrite(
    profile: SiteProfile,
    rootURL: URL
  ) throws {
    guard profile.purpose.requiresRepositoryReadiness else { return }
    let gitMarkerURL = rootURL.standardizedFileURL.appendingPathComponent(".git")
    guard fileManager.fileExists(atPath: gitMarkerURL.path),
      !isSymbolicLink(gitMarkerURL)
    else {
      throw LocalPublishPreviewError.notGitRepositoryRoot(rootURL.path)
    }
  }

  func write(
    package: PublishPackage, rootURL: URL, purpose: LocalPublishWritePurpose = .article(nil)
  ) throws -> [String] {
    try writeWithEvidence(package: package, rootURL: rootURL, purpose: purpose).writtenPaths
  }

  func write(
    preview: LocalPublishPreview, rootURL: URL, purpose: LocalPublishWritePurpose = .article(nil)
  ) throws -> [String] {
    try writeWithEvidence(
      package: preview.package,
      rootURL: rootURL,
      preview: preview,
      purpose: purpose
    ).writtenPaths
  }

  public func commitCommand(package: PublishPackage, profile: SiteProfile) -> String? {
    guard let rootPath = profile.localRepositoryRootURL?.path else {
      return nil
    }
    guard package.files.allSatisfy({ !isGitControlPath($0.repositoryPath) }) else {
      return nil
    }

    let paths = package.files
      .map(\.repositoryPath)
      .map(posixShellQuote)
      .joined(separator: " ")
    return
      "cd \(posixShellQuote(rootPath)) && git add \(paths) && git commit -m \(posixShellQuote(package.commitMessage))"
  }
}

public enum LocalPublishPreviewError: LocalizedError {
  case missingRepositoryRoot
  case notGitRepositoryRoot(String)
  case unsafePath(String)
  case missingSource(String)
  case unsafeSource(String)
  case invalidPreview(String)
  case previewOutdated(String)
  case sourcePreviewOutdated(String)
  case recoveryFailed(String)
  case rollbackConflict(String)
  case rollbackFailed(original: String, rollback: String)

  public var errorDescription: String? {
    switch self {
    case .missingRepositoryRoot:
      return CoreL10n.text("未选择本地仓库。")
    case .notGitRepositoryRoot(let path):
      return CoreL10n.format("所选目录不是 Git 仓库根目录，已停止写入：%@", path)
    case .unsafePath(let path):
      return CoreL10n.format("发布路径不安全：%@", path)
    case .missingSource(let path):
      return CoreL10n.format("源文件缺失：%@", path)
    case .unsafeSource(let path):
      return CoreL10n.format("源文件不是可安全读取的普通文件：%@", path)
    case .invalidPreview(let path):
      return CoreL10n.format("发布预览缺少有效的文件基线，请重新生成预览：%@", path)
    case .previewOutdated(let path):
      return CoreL10n.format("目标文件在预览后已被外部修改，已停止写入：%@", path)
    case .sourcePreviewOutdated(let path):
      return CoreL10n.format("媒体源文件在预览后已变化，已停止写入：%@", path)
    case .recoveryFailed(let message):
      return CoreL10n.format("上一次本地发布未完成，自动恢复失败：%@", message)
    case .rollbackConflict(let path):
      return CoreL10n.format("检测到外部修改，已停止自动恢复并保留当前文件：%@", path)
    case .rollbackFailed(let original, let rollback):
      return CoreL10n.format(
        "本地写入失败，且自动恢复未完整完成：%@；恢复错误：%@",
        original,
        rollback
      )
    }
  }
}

struct PreparedLocalPublishWrite {
  let file: PublishPackageFile
  let destinationURL: URL
  let sourceURL: URL?
  let expectedSourceState: LocalPublishSourceFileState?
}

struct LocalPublishRollbackEntry {
  let destinationURL: URL
  let backupURL: URL?
  var appliedState: LocalPublishFileState?
  var didMutateDestination: Bool
}

struct PreparedLocalPublishRecovery {
  let destinationURL: URL
  let backupURL: URL?
}

enum LocalPublishTransactionPhase: String, Codable {
  case applying
  case committed
  case manualRecoveryRequired
}

struct LocalPublishTransactionEntry: Codable {
  var repositoryPath: String
  var backupFileName: String?
}

struct LocalPublishTransaction: Codable {
  var phase: LocalPublishTransactionPhase
  var rollbackDirectoryPath: String
  var entries: [LocalPublishTransactionEntry]
}

struct LocalPublishWriteResult {
  let writtenPaths: [String]
  let appliedStatesByRepositoryPath: [String: LocalPublishFileState]
}

public enum LocalPublishFileState: Codable, Hashable, Sendable {
  case missing
  case fileDigest(Data)
}

func localPublishSourceFileState(
  at url: URL,
  repositoryPath: String
) throws -> LocalPublishSourceFileState {
  #if canImport(Darwin)
    return try withLocalPublishSourceDescriptor(
      at: url,
      repositoryPath: repositoryPath
    ) { descriptor in
      try readLocalPublishSource(
        descriptor: descriptor,
        repositoryPath: repositoryPath,
        destinationDescriptor: nil
      )
    }
  #else
    let values = try url.resourceValues(forKeys: [
      .isRegularFileKey,
      .isSymbolicLinkKey,
      .fileSizeKey,
      .fileResourceIdentifierKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw LocalPublishPreviewError.unsafeSource(repositoryPath)
    }
    let digest = try BoundedFileReader.sha256(
      at: url,
      maximumByteCount: WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount
    )
    let identifier = stableLocalPublishFileIdentifier(values.fileResourceIdentifier)
    return LocalPublishSourceFileState(
      byteSize: Int64(values.fileSize ?? 0),
      sha256: digest,
      deviceIdentifier: 0,
      fileIdentifier: identifier
    )
  #endif
}

/// Converts Foundation's opaque file-resource identifier into a reproducible value.
///
/// `Hashable.hashValue` is intentionally randomized between processes, so it cannot
/// participate in a persisted preview identity. Unknown identifier representations
/// fail closed to zero; the source digest and byte size still protect content while
/// avoiding a false claim that an unstable identity is durable.
func stableLocalPublishFileIdentifier(_ identifier: Any?) -> UInt64 {
  switch identifier {
  case let number as NSNumber:
    return number.uint64Value
  case let data as Data:
    return stableLocalPublishIdentifierDigest(data)
  case let string as String:
    return stableLocalPublishIdentifierDigest(Data(string.utf8))
  case let uuid as UUID:
    return stableLocalPublishIdentifierDigest(withUnsafeBytes(of: uuid.uuid) { Data($0) })
  default:
    return 0
  }
}

private func stableLocalPublishIdentifierDigest(_ data: Data) -> UInt64 {
  SHA256.hash(data: data).prefix(8).reduce(into: UInt64(0)) { value, byte in
    value = (value << 8) | UInt64(byte)
  }
}

#if canImport(Darwin)
  func withLocalPublishSourceDescriptor<Result>(
    at url: URL,
    repositoryPath: String,
    operation: (Int32) throws -> Result
  ) throws -> Result {
    let descriptor = url.path.withCString {
      Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
      if errno == ENOENT {
        throw LocalPublishPreviewError.missingSource(repositoryPath)
      }
      throw LocalPublishPreviewError.unsafeSource(repositoryPath)
    }
    defer { Darwin.close(descriptor) }
    return try operation(descriptor)
  }

  func readLocalPublishSource(
    descriptor: Int32,
    repositoryPath: String,
    destinationDescriptor: Int32?
  ) throws -> LocalPublishSourceFileState {
    var initialMetadata = stat()
    guard Darwin.fstat(descriptor, &initialMetadata) == 0,
      (initialMetadata.st_mode & S_IFMT) == S_IFREG,
      initialMetadata.st_size >= 0,
      initialMetadata.st_size
        <= off_t(WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount)
    else {
      throw LocalPublishPreviewError.unsafeSource(repositoryPath)
    }

    var digest = SHA256()
    var totalBytes: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
        Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
      }
      if bytesRead == 0 {
        break
      }
      if bytesRead < 0 {
        if errno == EINTR { continue }
        throw LocalPublishPreviewError.unsafeSource(repositoryPath)
      }

      totalBytes += Int64(bytesRead)
      guard totalBytes <= Int64(WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount)
      else {
        throw LocalPublishPreviewError.unsafeSource(repositoryPath)
      }

      if let destinationDescriptor {
        try buffer.withUnsafeBytes { rawBuffer in
          guard let baseAddress = rawBuffer.baseAddress else { return }
          var writtenByteCount = 0
          while writtenByteCount < bytesRead {
            let result = Darwin.write(
              destinationDescriptor,
              baseAddress.advanced(by: writtenByteCount),
              bytesRead - writtenByteCount
            )
            if result < 0 {
              if errno == EINTR { continue }
              throw LocalPublishPreviewError.unsafeSource(repositoryPath)
            }
            guard result > 0 else {
              throw LocalPublishPreviewError.unsafeSource(repositoryPath)
            }
            writtenByteCount += result
          }
        }
      }
      digest.update(data: Data(buffer.prefix(bytesRead)))
    }

    var finalMetadata = stat()
    guard Darwin.fstat(descriptor, &finalMetadata) == 0,
      totalBytes == Int64(initialMetadata.st_size),
      localPublishSourceMetadataIsUnchanged(initialMetadata, finalMetadata)
    else {
      throw LocalPublishPreviewError.unsafeSource(repositoryPath)
    }

    return LocalPublishSourceFileState(
      byteSize: totalBytes,
      sha256: Data(digest.finalize()),
      deviceIdentifier: UInt64(initialMetadata.st_dev),
      fileIdentifier: UInt64(initialMetadata.st_ino)
    )
  }

  private func localPublishSourceMetadataIsUnchanged(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev
      && lhs.st_ino == rhs.st_ino
      && lhs.st_size == rhs.st_size
      && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
      && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
      && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
      && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
  }
#endif

func localPublishFileState(at url: URL, fileManager: FileManager) throws -> LocalPublishFileState {
  var isDirectory: ObjCBool = false
  guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
    return .missing
  }
  guard !isDirectory.boolValue else {
    throw LocalPublishPreviewError.unsafePath(url.path)
  }
  return .fileDigest(
    try BoundedFileReader.sha256(
      at: url,
      maximumByteCount: WorkbenchFileReadLimits.maximumLocalPublishTrackedFileByteCount
    ))
}
