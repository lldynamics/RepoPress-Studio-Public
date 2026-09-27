import Darwin
import Foundation
import PublishingCoreSupport

public enum RepositoryHTMLFileError: LocalizedError, Equatable, Sendable {
  case repositoryUnavailable
  case unsafeRepositoryPath
  case unsupportedFileType
  case fileNotFound
  case symbolicLinkNotAllowed
  case aliasFileNotAllowed

  public var errorDescription: String? {
    switch self {
    case .repositoryUnavailable:
      CoreL10n.text("本地仓库不可用，请重新选择仓库。")
    case .unsafeRepositoryPath:
      CoreL10n.text("HTML 文件路径不安全，已拒绝访问。")
    case .unsupportedFileType:
      CoreL10n.text("此操作只支持 HTML 和 HTM 文件。")
    case .fileNotFound:
      CoreL10n.text("找不到这个 HTML 文件。")
    case .symbolicLinkNotAllowed:
      CoreL10n.text("HTML 文件路径包含符号链接，已拒绝访问。")
    case .aliasFileNotAllowed:
      CoreL10n.text("HTML 文件是 Finder 替身，已拒绝访问。")
    }
  }
}

/// Finds HTML files in a locally configured repository and safely resolves an
/// original repository URL for actions handled by Finder or the default app.
///
/// The service deliberately does not read, edit, save, copy, or preview HTML.
/// `withOriginalFileURL` validates every path component while the repository
/// directory descriptors are open, then supplies the actual repository URL to
/// the caller's immediate operation.
public struct RepositoryHTMLFileService: Sendable {
  public static let maximumTraversalEntryCount = 100_000
  public static let maximumTraversalDepth = 64

  private var fileManager: FileManager { .default }

  public init() {}

  public func listDocuments(profile: SiteProfile) throws -> [RepositoryHTMLFileDescriptor] {
    try withRepositoryRoot(profile: profile) { rootURL in
      let keys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey,
        .fileSizeKey, .contentModificationDateKey,
      ]
      guard
        let enumerator = fileManager.enumerator(
          at: rootURL,
          includingPropertiesForKeys: keys,
          options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
      else {
        throw RepositoryHTMLFileError.repositoryUnavailable
      }

      let excludedDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "node_modules", "vendor",
      ]
      var documents: [RepositoryHTMLFileDescriptor] = []
      var visitedEntryCount = 0
      while let url = enumerator.nextObject() as? URL {
        visitedEntryCount += 1
        if visitedEntryCount > Self.maximumTraversalEntryCount { break }

        guard let path = try? safeRelativePath(for: url, rootURL: rootURL) else { continue }
        if path.split(separator: "/").count > Self.maximumTraversalDepth {
          enumerator.skipDescendants()
          continue
        }
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
        if values.isDirectory == true {
          if values.isSymbolicLink == true || excludedDirectoryNames.contains(url.lastPathComponent)
          {
            enumerator.skipDescendants()
          }
          continue
        }
        guard values.isRegularFile == true,
          values.isSymbolicLink != true,
          values.isAliasFile != true,
          Self.isHTMLFile(url)
        else {
          continue
        }
        documents.append(
          RepositoryHTMLFileDescriptor(
            repositoryPath: path,
            byteSize: values.fileSize ?? 0,
            modificationDate: values.contentModificationDate
          ))
      }
      return documents.sorted {
        $0.repositoryPath.localizedStandardCompare($1.repositoryPath) == .orderedAscending
      }
    }
  }

  /// Resolves one requested file even when it is outside the bounded browser scan.
  public func descriptor(
    profile: SiteProfile,
    repositoryPath: String
  ) throws -> RepositoryHTMLFileDescriptor {
    try withOriginalFileURL(profile: profile, repositoryPath: repositoryPath) { url in
      let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      return RepositoryHTMLFileDescriptor(
        repositoryPath: repositoryPath,
        byteSize: values.fileSize ?? 0,
        modificationDate: values.contentModificationDate
      )
    }
  }

  /// Runs an immediate user-interface operation with the original repository
  /// file URL after verifying that it is a regular HTML file below the selected
  /// repository and that neither the repository root nor any path component is
  /// a symbolic link.
  public func withOriginalFileURL<T>(
    profile: SiteProfile,
    repositoryPath: String,
    operation: (URL) throws -> T
  ) throws -> T {
    try withRepositoryRoot(profile: profile) { rootURL in
      try withSafeParentDirectory(rootURL: rootURL, repositoryPath: repositoryPath) {
        parentDescriptor, fileName in
        try withOpenRegularHTMLFile(
          parentDescriptor: parentDescriptor,
          fileName: fileName
        ) { _, fileStat in
          let parentURL = URL(
            fileURLWithPath: try filePath(for: parentDescriptor),
            isDirectory: true
          )
          let originalURL = parentURL.appendingPathComponent(fileName, isDirectory: false)
          guard try safeRelativePath(for: originalURL, rootURL: rootURL) == repositoryPath else {
            throw RepositoryHTMLFileError.unsafeRepositoryPath
          }
          var currentStat = stat()
          guard Darwin.lstat(originalURL.path, &currentStat) == 0,
            currentStat.st_dev == fileStat.st_dev,
            currentStat.st_ino == fileStat.st_ino,
            (currentStat.st_mode & S_IFMT) == S_IFREG
          else {
            throw RepositoryHTMLFileError.fileNotFound
          }
          if try originalURL.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile == true {
            throw RepositoryHTMLFileError.aliasFileNotAllowed
          }
          return try operation(originalURL)
        }
      }
    }
  }

  private func withRepositoryRoot<T>(
    profile: SiteProfile,
    operation: (URL) throws -> T
  ) throws -> T {
    guard
      let value = try profile.withLocalRepositoryRootAccess({ configuredRootURL in
        var rootStat = stat()
        guard Darwin.lstat(configuredRootURL.path, &rootStat) == 0 else {
          throw posixError(fallback: .repositoryUnavailable)
        }
        guard (rootStat.st_mode & S_IFMT) != S_IFLNK else {
          throw RepositoryHTMLFileError.symbolicLinkNotAllowed
        }
        let values = try configuredRootURL.resourceValues(forKeys: [
          .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true else {
          throw RepositoryHTMLFileError.repositoryUnavailable
        }
        guard values.isSymbolicLink != true else {
          throw RepositoryHTMLFileError.symbolicLinkNotAllowed
        }
        let descriptor = configuredRootURL.path.withCString {
          Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
          throw posixError(fallback: .repositoryUnavailable)
        }
        defer { Darwin.close(descriptor) }
        return try operation(URL(fileURLWithPath: try filePath(for: descriptor), isDirectory: true))
      })
    else {
      throw RepositoryHTMLFileError.repositoryUnavailable
    }
    return value
  }

  private func safeRelativePath(for url: URL, rootURL: URL) throws -> String {
    let rootPath = rootURL.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    guard filePath.hasPrefix(rootPath + "/") else {
      throw RepositoryHTMLFileError.unsafeRepositoryPath
    }
    return String(filePath.dropFirst(rootPath.count + 1))
  }

  private func validatedPathComponents(_ repositoryPath: String) throws -> [String] {
    let components = repositoryPath.split(separator: "/", omittingEmptySubsequences: false)
    guard !repositoryPath.isEmpty,
      !repositoryPath.hasPrefix("/"),
      !repositoryPath.contains("\\"),
      !repositoryPath.contains("\0"),
      !repositoryPath.contains("://"),
      components.count <= Self.maximumTraversalDepth,
      components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else {
      throw RepositoryHTMLFileError.unsafeRepositoryPath
    }
    let result = components.map(String.init)
    guard let fileName = result.last,
      ["html", "htm"].contains(URL(fileURLWithPath: fileName).pathExtension.lowercased())
    else {
      throw RepositoryHTMLFileError.unsupportedFileType
    }
    return result
  }

  private func withSafeParentDirectory<T>(
    rootURL: URL,
    repositoryPath: String,
    operation: (Int32, String) throws -> T
  ) throws -> T {
    let components = try validatedPathComponents(repositoryPath)
    let rootDescriptor = rootURL.path.withCString {
      Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
    }
    guard rootDescriptor >= 0 else {
      throw posixError(fallback: .repositoryUnavailable)
    }
    defer { Darwin.close(rootDescriptor) }

    var openedDescriptors: [Int32] = []
    defer {
      for descriptor in openedDescriptors.reversed() {
        Darwin.close(descriptor)
      }
    }

    var parentDescriptor = rootDescriptor
    for component in components.dropLast() {
      let nextDescriptor = component.withCString {
        Darwin.openat(
          parentDescriptor,
          $0,
          O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
      }
      guard nextDescriptor >= 0 else {
        let openError = errno
        var entryStat = stat()
        let inspected = component.withCString {
          Darwin.fstatat(parentDescriptor, $0, &entryStat, AT_SYMLINK_NOFOLLOW)
        }
        if inspected == 0, (entryStat.st_mode & S_IFMT) == S_IFLNK {
          throw RepositoryHTMLFileError.symbolicLinkNotAllowed
        }
        throw posixError(code: openError, fallback: .fileNotFound)
      }
      openedDescriptors.append(nextDescriptor)
      parentDescriptor = nextDescriptor
    }
    return try operation(parentDescriptor, components[components.count - 1])
  }

  private func withOpenRegularHTMLFile<T>(
    parentDescriptor: Int32,
    fileName: String,
    operation: (Int32, stat) throws -> T
  ) throws -> T {
    let descriptor = fileName.withCString {
      Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
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
      throw RepositoryHTMLFileError.fileNotFound
    }
    return try operation(descriptor, fileStat)
  }

  private func filePath(for descriptor: Int32) throws -> String {
    var pathBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    guard Darwin.fcntl(descriptor, F_GETPATH, &pathBuffer) == 0 else {
      throw posixError(fallback: .repositoryUnavailable)
    }
    return String(
      decoding: pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
      as: UTF8.self
    )
  }

  private func posixError(
    code: Int32 = errno,
    fallback: RepositoryHTMLFileError
  ) -> Error {
    switch code {
    case ELOOP:
      RepositoryHTMLFileError.symbolicLinkNotAllowed
    case ENOENT, ENOTDIR:
      RepositoryHTMLFileError.fileNotFound
    default:
      fallback
    }
  }

  private static func isHTMLFile(_ url: URL) -> Bool {
    ["html", "htm"].contains(url.pathExtension.lowercased())
  }
}
