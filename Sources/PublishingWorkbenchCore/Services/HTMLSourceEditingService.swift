import CryptoKit
import Darwin
import Foundation

public enum HTMLSourceEditingError: LocalizedError, Equatable, Sendable {
  case repositoryUnavailable
  case unsafeRepositoryPath
  case unsupportedFileType
  case fileNotFound
  case symbolicLinkNotAllowed
  case fileTooLarge(maximumBytes: Int)
  case unsupportedEncoding
  case repositoryChanged
  case externalModification
  case mixedLineEndings
  case cannotEncode

  public var errorDescription: String? {
    switch self {
    case .repositoryUnavailable:
      CoreL10n.text("本地仓库不可用，请重新选择仓库。")
    case .unsafeRepositoryPath:
      CoreL10n.text("源码路径不安全，已拒绝访问。")
    case .unsupportedFileType:
      CoreL10n.text("高级源码编辑器只支持 HTML 和 HTM 文件。")
    case .fileNotFound:
      CoreL10n.text("找不到这个 HTML 源文件。")
    case .symbolicLinkNotAllowed:
      CoreL10n.text("源码路径包含符号链接，已拒绝访问。")
    case let .fileTooLarge(maximumBytes):
      CoreL10n.format("HTML 文件超过 %d 字节的安全编辑上限。", maximumBytes)
    case .unsupportedEncoding:
      CoreL10n.text("HTML 文件编码不受支持。请转换为 UTF-8 或带 BOM 的 UTF-16。")
    case .repositoryChanged:
      CoreL10n.text("当前站点的仓库已切换，不能保存原仓库中的文件。")
    case .externalModification:
      CoreL10n.text("文件已被其他程序修改。请重新载入并合并更改后再保存。")
    case .mixedLineEndings:
      CoreL10n.text("文件同时包含多种换行格式。为避免静默改写全文，请先统一换行格式后再保存。")
    case .cannotEncode:
      CoreL10n.text("无法用原始编码保存这个 HTML 文件。")
    }
  }
}

private enum HTMLPreviewReferenceScanner {
  private static let htmlAttributeExpression = try? NSRegularExpression(
    pattern: #"\b(?:src|href|poster)\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s>]+))"#,
    options: [.caseInsensitive]
  )
  private static let srcsetExpression = try? NSRegularExpression(
    pattern: #"\bsrcset\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^>\s]+))"#,
    options: [.caseInsensitive]
  )
  private static let cssReferenceExpression = try? NSRegularExpression(
    pattern: #"url\(\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s)]+))\s*\)|@import\s+(?:url\()?\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s;)]+))"#,
    options: [.caseInsensitive]
  )

  static func htmlReferences(in text: String) -> [String] {
    var references = captures(in: text, expression: htmlAttributeExpression)
    for srcset in captures(in: text, expression: srcsetExpression) {
      references.append(contentsOf: srcset.split(separator: ",").compactMap { candidate in
        candidate.split(whereSeparator: \.isWhitespace).first.map(String.init)
      })
    }
    // Also include inline `style` blocks and attributes. The CSS scanner only
    // recognizes url()/@import expressions, so applying it to the full HTML
    // document cannot accidentally treat ordinary markup as a file path.
    references.append(contentsOf: cssReferences(in: text))
    return references
  }

  static func cssReferences(in text: String) -> [String] {
    captures(in: text, expression: cssReferenceExpression)
  }

  private static func captures(
    in text: String,
    expression: NSRegularExpression?
  ) -> [String] {
    guard let expression else { return [] }
    let source = text as NSString
    let fullRange = NSRange(location: 0, length: source.length)
    return expression.matches(in: text, range: fullRange).compactMap { match in
      for index in 1 ..< match.numberOfRanges {
        let range = match.range(at: index)
        if range.location != NSNotFound, range.length > 0 {
          return source.substring(with: range)
        }
      }
      return nil
    }
  }
}

public struct HTMLSourceEditingService: Sendable {
  public static let maximumEditableByteCount = 4 * 1_024 * 1_024
  public static let maximumTraversalEntryCount = 100_000
  public static let maximumTraversalDepth = 64
  static let maximumPreviewAssetByteCount = 32 * 1_024 * 1_024
  static let maximumPreviewPackageByteCount = 128 * 1_024 * 1_024
  static let maximumPreviewAssetCount = 512

  private var fileManager: FileManager { .default }

  public init() {}

  public func listDocuments(profile: SiteProfile) throws -> [RepositoryHTMLFileDescriptor] {
    try withRepositoryRoot(profile: profile) { rootURL in
      let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey
      ]
      guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else {
        throw HTMLSourceEditingError.repositoryUnavailable
      }

      let excludedDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "vendor"
      ]
      var documents: [RepositoryHTMLFileDescriptor] = []
      var visitedEntryCount = 0
      while let url = enumerator.nextObject() as? URL {
        visitedEntryCount += 1
        if visitedEntryCount > Self.maximumTraversalEntryCount {
          break
        }
        guard let path = try? safeRelativePath(for: url, rootURL: rootURL) else { continue }
        if path.split(separator: "/").count > Self.maximumTraversalDepth {
          enumerator.skipDescendants()
          continue
        }
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if values.isDirectory == true {
          if values.isSymbolicLink == true || excludedDirectoryNames.contains(url.lastPathComponent) {
            enumerator.skipDescendants()
          }
          continue
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              Self.isHTMLFile(url) else { continue }
        let byteSize = values.fileSize ?? 0
        documents.append(RepositoryHTMLFileDescriptor(
          repositoryPath: path,
          byteSize: byteSize,
          modificationDate: values.contentModificationDate,
          isEditable: byteSize <= Self.maximumEditableByteCount
        ))
      }
      return documents.sorted {
        $0.repositoryPath.localizedStandardCompare($1.repositoryPath) == .orderedAscending
      }
    }
  }

  public func open(
    profile: SiteProfile,
    repositoryPath: String
  ) throws -> RepositoryTextDocument {
    try withRepositoryRoot(profile: profile) { rootURL in
      return try withSafeParentDirectory(
        rootURL: rootURL,
        repositoryPath: repositoryPath
      ) { parentDescriptor, fileName, verifiedRootURL, rootStat in
        try withOpenRegularFile(
          parentDescriptor: parentDescriptor,
          fileName: fileName,
          flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        ) { descriptor, fileStat in
          let data = try readLimitedData(from: descriptor, fileStat: fileStat)
          return try makeDocument(
            data: data,
            fileStat: fileStat,
            rootURL: verifiedRootURL,
            rootStat: rootStat,
            repositoryPath: repositoryPath,
            siteKind: profile.siteKind
          )
        }
      }
    }
  }

  public func save(
    _ document: RepositoryTextDocument,
    profile: SiteProfile
  ) throws -> RepositoryTextDocument {
    try withRepositoryRoot(profile: profile) { rootURL in
      guard !document.hasMixedLineEndings else {
        throw HTMLSourceEditingError.mixedLineEndings
      }
      let encodedData = try encode(document)
      guard encodedData.count <= Self.maximumEditableByteCount else {
        throw HTMLSourceEditingError.fileTooLarge(
          maximumBytes: Self.maximumEditableByteCount
        )
      }
      return try withSafeParentDirectory(
        rootURL: rootURL,
        repositoryPath: document.repositoryPath
      ) { parentDescriptor, fileName, verifiedRootURL, rootStat in
        guard verifiedRootURL.path == document.repositoryRootPath,
              UInt64(rootStat.st_dev) == document.repositoryRootDevice,
              UInt64(rootStat.st_ino) == document.repositoryRootInode else {
          throw HTMLSourceEditingError.repositoryChanged
        }
        let committedStat = try securelyReplaceFile(
          parentDescriptor: parentDescriptor,
          fileName: fileName,
          expectedDigest: document.baselineSHA256,
          data: encodedData
        )
        return try makeDocument(
          data: encodedData,
          fileStat: committedStat,
          rootURL: verifiedRootURL,
          rootStat: rootStat,
          repositoryPath: document.repositoryPath,
          siteKind: profile.siteKind
        )
      }
    }
  }

  public func withResolvedFileURL<T>(
    profile: SiteProfile,
    repositoryPath: String,
    operation: (URL) throws -> T
  ) throws -> T {
    try withRepositoryRoot(profile: profile) { rootURL in
      try withSafeParentDirectory(
        rootURL: rootURL,
        repositoryPath: repositoryPath
      ) { parentDescriptor, fileName, verifiedRootURL, _ in
        try withOpenRegularFile(
          parentDescriptor: parentDescriptor,
          fileName: fileName,
          flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        ) { descriptor, fileStat in
          let data = try readLimitedData(from: descriptor, fileStat: fileStat)
          let snapshotURL = try makePreviewSnapshot(
            data: data,
            rootURL: verifiedRootURL,
            repositoryPath: repositoryPath
          )
          return try operation(snapshotURL)
        }
      }
    }
  }

  private func withRepositoryRoot<T>(
    profile: SiteProfile,
    operation: (URL) throws -> T
  ) throws -> T {
    guard let value = try profile.withLocalRepositoryRootAccess({ rootURL in
      let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey])
      guard values.isDirectory == true else {
        throw HTMLSourceEditingError.repositoryUnavailable
      }
      return try operation(rootURL.standardizedFileURL)
    }) else {
      throw HTMLSourceEditingError.repositoryUnavailable
    }
    return value
  }

  private func safeRelativePath(for url: URL, rootURL: URL) throws -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath + "/") else {
      throw HTMLSourceEditingError.unsafeRepositoryPath
    }
    return String(filePath.dropFirst(rootPath.count + 1))
  }

  private func validatedPathComponents(_ repositoryPath: String) throws -> [String] {
    let components = repositoryPath.split(separator: "/", omittingEmptySubsequences: false)
    guard !repositoryPath.isEmpty, !repositoryPath.hasPrefix("/"),
          !repositoryPath.contains("\\"), !repositoryPath.contains("\0"),
          !repositoryPath.contains("://"),
          components.count <= Self.maximumTraversalDepth,
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw HTMLSourceEditingError.unsafeRepositoryPath
    }
    let result = components.map(String.init)
    guard let fileName = result.last,
          ["html", "htm"].contains(URL(fileURLWithPath: fileName).pathExtension.lowercased()) else {
      throw HTMLSourceEditingError.unsupportedFileType
    }
    return result
  }

  private func withSafeParentDirectory<T>(
    rootURL: URL,
    repositoryPath: String,
    operation: (Int32, String, URL, stat) throws -> T
  ) throws -> T {
    let components = try validatedPathComponents(repositoryPath)
    // First obtain the directory authorized by the profile. `F_GETPATH` gives
    // the kernel-resolved path of that already-open descriptor (including
    // system aliases such as /var -> /private/var).
    let authorizedDescriptor = rootURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard authorizedDescriptor >= 0 else {
      throw posixError(fallback: .repositoryUnavailable)
    }
    defer { Darwin.close(authorizedDescriptor) }
    let resolvedRootURL = URL(
      fileURLWithPath: try filePath(for: authorizedDescriptor),
      isDirectory: true
    ).standardizedFileURL

    var openedDescriptors: [Int32] = []
    defer {
      for descriptor in openedDescriptors.reversed() {
        Darwin.close(descriptor)
      }
    }

    // The authorized descriptor itself is the stable trust anchor. Every
    // repository component below it is opened relative to this descriptor, so
    // later renames or symlink substitutions of the profile pathname cannot
    // redirect the active operation.
    var rootStat = stat()
    guard Darwin.fstat(authorizedDescriptor, &rootStat) == 0 else {
      throw posixError(fallback: .repositoryUnavailable)
    }
    var parentDescriptor = authorizedDescriptor
    for component in components.dropLast() {
      let nextDescriptor = component.withCString {
        Darwin.openat(
          parentDescriptor,
          $0,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
      }
      guard nextDescriptor >= 0 else {
        throw posixError(fallback: .symbolicLinkNotAllowed)
      }
      openedDescriptors.append(nextDescriptor)
      parentDescriptor = nextDescriptor
    }
    return try operation(
      parentDescriptor,
      components[components.count - 1],
      resolvedRootURL,
      rootStat
    )
  }

  private func filePath(for descriptor: Int32) throws -> String {
    var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard Darwin.fcntl(descriptor, F_GETPATH, &pathBuffer) == 0 else {
      throw posixError(fallback: .repositoryUnavailable)
    }
    let descriptorPath = String(
      decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
    var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let didResolve = descriptorPath.withCString {
      Darwin.realpath($0, &canonicalBuffer) != nil
    }
    guard didResolve else {
      throw posixError(fallback: .repositoryUnavailable)
    }
    return String(
      decoding: canonicalBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
  }

  private func withOpenRegularFile<T>(
    parentDescriptor: Int32,
    fileName: String,
    flags: Int32,
    operation: (Int32, stat) throws -> T
  ) throws -> T {
    let descriptor = fileName.withCString {
      Darwin.openat(parentDescriptor, $0, flags | O_NONBLOCK)
    }
    guard descriptor >= 0 else {
      throw posixError(fallback: .fileNotFound)
    }
    defer { Darwin.close(descriptor) }

    var fileStat = stat()
    guard Darwin.fstat(descriptor, &fileStat) == 0 else {
      throw posixError(fallback: .fileNotFound)
    }
    guard (fileStat.st_mode & S_IFMT) == S_IFREG else {
      throw HTMLSourceEditingError.fileNotFound
    }
    return try operation(descriptor, fileStat)
  }

  private func readLimitedData(from descriptor: Int32, fileStat: stat) throws -> Data {
    guard fileStat.st_size >= 0,
          fileStat.st_size <= Self.maximumEditableByteCount else {
      throw HTMLSourceEditingError.fileTooLarge(
        maximumBytes: Self.maximumEditableByteCount
      )
    }
    guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
      throw posixError(fallback: .fileNotFound)
    }

    var data = Data()
    data.reserveCapacity(Int(fileStat.st_size))
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = buffer.withUnsafeMutableBytes { bytes in
        Darwin.read(descriptor, bytes.baseAddress, bytes.count)
      }
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw posixError(fallback: .fileNotFound)
      }
      guard data.count + count <= Self.maximumEditableByteCount else {
        throw HTMLSourceEditingError.fileTooLarge(
          maximumBytes: Self.maximumEditableByteCount
        )
      }
      data.append(buffer, count: count)
    }
    return data
  }

  /// Creates a stable, app-controlled snapshot for consumers such as
  /// LaunchServices. Passing the repository pathname after validating a file
  /// descriptor would reintroduce a path-substitution race because the consumer
  /// resolves that pathname asynchronously.
  private func makePreviewSnapshot(
    data: Data,
    rootURL: URL,
    repositoryPath: String
  ) throws -> URL {
    cleanupExpiredPreviewSnapshots()
    let directoryURL = fileManager.temporaryDirectory.appendingPathComponent(
      "PersonalSitePublisher-HTMLPreview-\(UUID().uuidString)",
      isDirectory: true
    )
    do {
      try fileManager.createDirectory(
        at: directoryURL,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      let snapshotURL = directoryURL.appendingPathComponent(repositoryPath, isDirectory: false)
      try fileManager.createDirectory(
        at: snapshotURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      // The parent is a freshly-created 0700 directory with a UUID name, so
      // direct creation is already isolated. Foundation traps when `.atomic`
      // and `.withoutOverwriting` are combined; keeping the latter preserves
      // the important no-clobber guarantee without that process crash.
      try data.write(to: snapshotURL, options: .withoutOverwriting)
      try copyPreviewDependencies(
        referencedBy: data,
        sourcePath: repositoryPath,
        rootURL: rootURL,
        previewRootURL: directoryURL,
        initialByteCount: data.count
      )
      schedulePreviewCleanup(directoryURL)
      return snapshotURL
    } catch {
      try? fileManager.removeItem(at: directoryURL)
      throw error
    }
  }

  private func copyPreviewDependencies(
    referencedBy documentData: Data,
    sourcePath: String,
    rootURL: URL,
    previewRootURL: URL,
    initialByteCount: Int
  ) throws {
    var queue = previewReferences(in: documentData, sourcePath: sourcePath)
    var visitedPaths = Set<String>()
    var copiedByteCount = initialByteCount
    var copiedAssetCount = 0

    while !queue.isEmpty, copiedAssetCount < Self.maximumPreviewAssetCount {
      let candidate = queue.removeFirst()
      guard let repositoryPath = normalizedPreviewResourcePath(
        candidate.reference,
        relativeTo: candidate.sourcePath
      ),
      visitedPaths.insert(repositoryPath).inserted else {
        continue
      }
      let remainingByteCount = Self.maximumPreviewPackageByteCount - copiedByteCount
      guard remainingByteCount > 0 else { break }
      let perFileLimit = min(Self.maximumPreviewAssetByteCount, remainingByteCount)
      guard let resourceData = try? BoundedFileReader.data(
        relativePath: repositoryPath,
        under: rootURL,
        maximumByteCount: perFileLimit
      ) else {
        continue
      }

      let destinationURL = previewRootURL.appendingPathComponent(repositoryPath)
      try fileManager.createDirectory(
        at: destinationURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      if !fileManager.fileExists(atPath: destinationURL.path) {
        try resourceData.write(to: destinationURL, options: .withoutOverwriting)
      }
      copiedByteCount += resourceData.count
      copiedAssetCount += 1

      let pathExtension = destinationURL.pathExtension.lowercased()
      if pathExtension == "css" || pathExtension == "html" || pathExtension == "htm" {
        queue.append(contentsOf: previewReferences(in: resourceData, sourcePath: repositoryPath))
      }
    }
  }

  private func previewReferences(in data: Data, sourcePath: String) -> [PreviewReference] {
    guard data.count <= Self.maximumEditableByteCount,
          let text = String(data: data, encoding: .utf8) else {
      return []
    }
    let pathExtension = URL(fileURLWithPath: sourcePath).pathExtension.lowercased()
    let references = pathExtension == "css"
      ? HTMLPreviewReferenceScanner.cssReferences(in: text)
      : HTMLPreviewReferenceScanner.htmlReferences(in: text)
    return references.map { PreviewReference(reference: $0, sourcePath: sourcePath) }
  }

  private func normalizedPreviewResourcePath(
    _ rawReference: String,
    relativeTo sourcePath: String
  ) -> String? {
    var reference = rawReference
      .replacingOccurrences(of: "&amp;", with: "&")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty,
          !reference.hasPrefix("#"),
          !reference.hasPrefix("//"),
          !reference.lowercased().hasPrefix("data:"),
          !reference.lowercased().hasPrefix("javascript:"),
          !reference.lowercased().hasPrefix("mailto:"),
          !reference.contains("://") else {
      return nil
    }
    reference = reference.components(separatedBy: "#")[0]
    reference = reference.components(separatedBy: "?")[0]
    reference = reference.removingPercentEncoding ?? reference
    guard !reference.contains("\\"), !reference.contains("\0") else { return nil }

    var components = reference.hasPrefix("/")
      ? []
      : sourcePath.split(separator: "/").dropLast().map(String.init)
    for component in reference.split(separator: "/", omittingEmptySubsequences: true) {
      switch component {
      case ".":
        continue
      case "..":
        guard !components.isEmpty else { return nil }
        components.removeLast()
      default:
        guard !component.contains(":"), component != "~" else { return nil }
        components.append(String(component))
      }
    }
    let normalized = components.joined(separator: "/")
    guard !normalized.isEmpty,
          normalized != ".",
          normalized != "..",
          !normalized.hasPrefix("../"),
          !normalized.hasPrefix("/"),
          normalized.split(separator: "/").count <= Self.maximumTraversalDepth,
          Self.previewAssetExtensions.contains(
            URL(fileURLWithPath: normalized).pathExtension.lowercased()
          ) else {
      return nil
    }
    return normalized
  }

  private func cleanupExpiredPreviewSnapshots(now: Date = Date()) {
    let expirationDate = now.addingTimeInterval(-24 * 60 * 60)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
    guard let urls = try? fileManager.contentsOfDirectory(
      at: fileManager.temporaryDirectory,
      includingPropertiesForKeys: Array(keys),
      options: [.skipsHiddenFiles]
    ) else { return }
    for url in urls where url.lastPathComponent.hasPrefix(Self.previewDirectoryPrefix) {
      guard let values = try? url.resourceValues(forKeys: keys),
            values.isDirectory == true,
            (values.contentModificationDate ?? .distantPast) < expirationDate else {
        continue
      }
      try? fileManager.removeItem(at: url)
    }
  }

  private func schedulePreviewCleanup(_ directoryURL: URL) {
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6 * 60 * 60) {
      try? FileManager.default.removeItem(at: directoryURL)
    }
  }

  private struct PreviewReference {
    let reference: String
    let sourcePath: String
  }

  private static let previewDirectoryPrefix = "PersonalSitePublisher-HTMLPreview-"
  private static let previewAssetExtensions: Set<String> = [
    "avif", "css", "gif", "htm", "html", "ico", "jpeg", "jpg", "js", "json",
    "m4v", "map", "mjs", "mov", "mp3", "mp4", "ogg", "otf", "png", "svg",
    "ttf", "wasm", "wav", "webm", "webp", "woff", "woff2", "xml"
  ]

  private func makeDocument(
    data: Data,
    fileStat: stat,
    rootURL: URL,
    rootStat: stat,
    repositoryPath: String,
    siteKind: SiteKind
  ) throws -> RepositoryTextDocument {
    let decoded = try decode(data)
    let text = Self.normalizedLineEndings(decoded.text)
    let lineEndingAnalysis = Self.lineEndingAnalysis(in: decoded.text)
    let timestamp = Double(fileStat.st_mtimespec.tv_sec)
      + Double(fileStat.st_mtimespec.tv_nsec) / 1_000_000_000
    return RepositoryTextDocument(
      repositoryRootPath: rootURL.standardizedFileURL.path,
      repositoryPath: repositoryPath,
      text: text,
      encoding: decoded.encoding,
      lineEnding: lineEndingAnalysis.dominant,
      dialect: Self.detectDialect(text: text, siteKind: siteKind),
      byteSize: data.count,
      modificationDate: Date(timeIntervalSince1970: timestamp),
      baselineSHA256: Self.digest(data),
      hasMixedLineEndings: lineEndingAnalysis.isMixed,
      repositoryRootDevice: UInt64(rootStat.st_dev),
      repositoryRootInode: UInt64(rootStat.st_ino)
    )
  }

  private func securelyReplaceFile(
    parentDescriptor: Int32,
    fileName: String,
    expectedDigest: Data,
    data: Data
  ) throws -> stat {
    try withOpenRegularFile(
      parentDescriptor: parentDescriptor,
      fileName: fileName,
      flags: O_RDWR | O_CLOEXEC | O_NOFOLLOW
    ) { originalDescriptor, originalStat in
      guard flock(originalDescriptor, LOCK_EX) == 0 else {
        throw posixError(fallback: .externalModification)
      }
      defer { flock(originalDescriptor, LOCK_UN) }

      let currentData = try readLimitedData(from: originalDescriptor, fileStat: originalStat)
      guard Self.digest(currentData) == expectedDigest else {
        throw HTMLSourceEditingError.externalModification
      }

      let temporaryName = ".psp-html-\(UUID().uuidString).tmp"
      let temporaryDescriptor = temporaryName.withCString {
        Darwin.openat(
          parentDescriptor,
          $0,
          O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
          mode_t(0o600)
        )
      }
      guard temporaryDescriptor >= 0 else {
        throw posixError(fallback: .cannotEncode)
      }
      var shouldRemoveTemporary = true
      defer {
        Darwin.close(temporaryDescriptor)
        if shouldRemoveTemporary {
          temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
        }
      }

      try writeAll(data, to: temporaryDescriptor)
      guard Darwin.fchmod(
        temporaryDescriptor,
        mode_t(originalStat.st_mode & 0o7777)
      ) == 0 else {
        throw posixError(fallback: .cannotEncode)
      }
      try synchronize(descriptor: temporaryDescriptor)

      var committedStat = stat()
      guard Darwin.fstat(temporaryDescriptor, &committedStat) == 0 else {
        throw posixError(fallback: .cannotEncode)
      }

      // Swap atomically first, then validate the displaced directory entry.
      // Unlike a check followed by `renameat`, this captures the exact target
      // version that existed at the commit instant and closes that TOCTOU gap.
      guard swapDirectoryEntries(
        parentDescriptor: parentDescriptor,
        firstName: temporaryName,
        secondName: fileName
      ) else {
        throw posixError(fallback: .cannotEncode)
      }
      // The temporary name now contains the displaced repository file. Never
      // delete it automatically unless validation succeeds or rollback restores
      // it to the repository path.
      shouldRemoveTemporary = false

      do {
        let displacedMatchesBaseline = try withOpenRegularFile(
          parentDescriptor: parentDescriptor,
          fileName: temporaryName,
          flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        ) { displacedDescriptor, displacedStat in
          guard displacedStat.st_dev == originalStat.st_dev,
                displacedStat.st_ino == originalStat.st_ino else {
            return false
          }
          let displacedData = try readLimitedData(
            from: displacedDescriptor,
            fileStat: displacedStat
          )
          return Self.digest(displacedData) == expectedDigest
        }
        guard displacedMatchesBaseline else {
          throw HTMLSourceEditingError.externalModification
        }

        // Persist the new directory entry before deleting the displaced inode.
        // A later cleanup failure can only leave a hidden backup behind; it
        // cannot make the committed source contents disappear.
        try synchronize(descriptor: parentDescriptor)
      } catch {
        let commitError = error
        if fileMatches(
          parentDescriptor: parentDescriptor,
          fileName: fileName,
          expectedStat: committedStat,
          expectedDigest: Self.digest(data)
        ), swapDirectoryEntries(
          parentDescriptor: parentDescriptor,
          firstName: temporaryName,
          secondName: fileName
        ) {
          // The baseline is back at the repository path; the temporary name
          // once again contains only our uncommitted bytes.
          shouldRemoveTemporary = true
          try? synchronize(descriptor: parentDescriptor)
        }
        throw commitError
      }

      let cleanupResult = temporaryName.withCString {
        Darwin.unlinkat(parentDescriptor, $0, 0)
      }
      if cleanupResult == 0 {
        // The commit itself was already synced. This second sync only prevents
        // a harmless hidden backup from reappearing after a crash.
        try? synchronize(descriptor: parentDescriptor)
      }
      return committedStat
    }
  }

  private func swapDirectoryEntries(
    parentDescriptor: Int32,
    firstName: String,
    secondName: String
  ) -> Bool {
    firstName.withCString { firstPointer in
      secondName.withCString { secondPointer in
        Darwin.renameatx_np(
          parentDescriptor,
          firstPointer,
          parentDescriptor,
          secondPointer,
          UInt32(RENAME_SWAP)
        ) == 0
      }
    }
  }

  private func fileMatches(
    parentDescriptor: Int32,
    fileName: String,
    expectedStat: stat,
    expectedDigest: Data
  ) -> Bool {
    do {
      return try withOpenRegularFile(
        parentDescriptor: parentDescriptor,
        fileName: fileName,
        flags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW
      ) { descriptor, fileStat in
        guard fileStat.st_dev == expectedStat.st_dev,
              fileStat.st_ino == expectedStat.st_ino else {
          return false
        }
        return Self.digest(try readLimitedData(from: descriptor, fileStat: fileStat))
          == expectedDigest
      }
    } catch {
      return false
    }
  }

  private func synchronize(descriptor: Int32) throws {
    while Darwin.fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw posixError(fallback: .cannotEncode)
    }
  }

  private func writeAll(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
      var written = 0
      while written < bytes.count {
        let count = Darwin.write(
          descriptor,
          bytes.baseAddress?.advanced(by: written),
          bytes.count - written
        )
        if count < 0 {
          if errno == EINTR { continue }
          throw posixError(fallback: .cannotEncode)
        }
        guard count > 0 else {
          throw HTMLSourceEditingError.cannotEncode
        }
        written += count
      }
    }
  }

  private func posixError(fallback: HTMLSourceEditingError) -> Error {
    switch errno {
    case ELOOP, ENOTDIR:
      return HTMLSourceEditingError.symbolicLinkNotAllowed
    case ENOENT:
      return HTMLSourceEditingError.fileNotFound
    case EFBIG:
      return HTMLSourceEditingError.fileTooLarge(
        maximumBytes: Self.maximumEditableByteCount
      )
    default:
      let code = errno
      guard code != 0 else { return fallback }
      return NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
  }

  private func decode(_ data: Data) throws -> (text: String, encoding: RepositoryTextEncoding) {
    if data.starts(with: [0xFF, 0xFE, 0x00, 0x00])
      || data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
      throw HTMLSourceEditingError.unsupportedEncoding
    }
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      guard let text = String(data: data.dropFirst(3), encoding: .utf8) else {
        throw HTMLSourceEditingError.unsupportedEncoding
      }
      return (text, .utf8WithBOM)
    }
    if data.starts(with: [0xFF, 0xFE]) {
      guard let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else {
        throw HTMLSourceEditingError.unsupportedEncoding
      }
      return (text, .utf16LittleEndian)
    }
    if data.starts(with: [0xFE, 0xFF]) {
      guard let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else {
        throw HTMLSourceEditingError.unsupportedEncoding
      }
      return (text, .utf16BigEndian)
    }
    guard let text = String(data: data, encoding: .utf8) else {
      throw HTMLSourceEditingError.unsupportedEncoding
    }
    return (text, .utf8)
  }

  private func encode(_ document: RepositoryTextDocument) throws -> Data {
    let normalized = Self.normalizedLineEndings(document.text)
    let storedText = normalized.replacingOccurrences(of: "\n", with: document.lineEnding.sequence)
    switch document.encoding {
    case .utf8:
      guard let data = storedText.data(using: .utf8) else {
        throw HTMLSourceEditingError.cannotEncode
      }
      return data
    case .utf8WithBOM:
      guard let body = storedText.data(using: .utf8) else {
        throw HTMLSourceEditingError.cannotEncode
      }
      return Data([0xEF, 0xBB, 0xBF]) + body
    case .utf16LittleEndian:
      guard let body = storedText.data(using: .utf16LittleEndian) else {
        throw HTMLSourceEditingError.cannotEncode
      }
      return Data([0xFF, 0xFE]) + body
    case .utf16BigEndian:
      guard let body = storedText.data(using: .utf16BigEndian) else {
        throw HTMLSourceEditingError.cannotEncode
      }
      return Data([0xFE, 0xFF]) + body
    }
  }

  private static func isHTMLFile(_ url: URL) -> Bool {
    ["html", "htm"].contains(url.pathExtension.lowercased())
  }

  private static func digest(_ data: Data) -> Data {
    Data(SHA256.hash(data: data))
  }

  private static func normalizedLineEndings(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
  }

  private static func lineEndingAnalysis(
    in text: String
  ) -> (dominant: RepositoryLineEnding, isMixed: Bool) {
    let crlfCount = text.components(separatedBy: "\r\n").count - 1
    let withoutCRLF = text.replacingOccurrences(of: "\r\n", with: "")
    let crCount = withoutCRLF.components(separatedBy: "\r").count - 1
    let lfCount = withoutCRLF.components(separatedBy: "\n").count - 1
    let kindsPresent = [crlfCount, crCount, lfCount].filter { $0 > 0 }.count
    let dominant: RepositoryLineEnding
    if crlfCount >= crCount, crlfCount >= lfCount, crlfCount > 0 {
      dominant = .crlf
    } else if crCount >= lfCount, crCount > 0 {
      dominant = .cr
    } else {
      dominant = .lf
    }
    return (dominant, kindsPresent > 1)
  }

  public static func detectDialect(text: String, siteKind: SiteKind) -> HTMLSourceDialect {
    if text.contains("<%") || text.contains("---\n") && siteKind == .astro {
      return .astro
    }
    if text.contains("{{<") || text.contains("{{%") || text.contains(".Site") {
      return .goTemplate
    }
    if text.contains("{%") || text.contains("{{") {
      switch siteKind {
      case .zola:
        return .tera
      case .hugo:
        return .goTemplate
      case .jekyll, .hexo:
        return .liquid
      case .astro:
        return .astro
      }
    }
    return .html
  }
}
