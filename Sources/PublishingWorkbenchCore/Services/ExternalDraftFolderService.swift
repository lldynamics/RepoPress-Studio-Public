import CryptoKit
import Foundation
import PublishingCoreSupport

public struct ExternalDraftFile: Sendable, Equatable {
  public let relativePath: String
  public let title: String
  public let markdown: String
  public let fingerprint: String

  public init(relativePath: String, title: String, markdown: String, fingerprint: String) {
    self.relativePath = relativePath
    self.title = title
    self.markdown = markdown
    self.fingerprint = fingerprint
  }
}

public enum ExternalDraftFolderServiceError: LocalizedError, Equatable, Sendable {
  case inaccessibleRoot
  case rootIsNotDirectory
  case fileTooLarge(relativePath: String)
  case fileCountExceeded
  case totalSizeExceeded
  case directoryDepthExceeded
  case entryCountExceeded
  case unreadableFile(relativePath: String)
  case invalidUTF8(relativePath: String)

  public var errorDescription: String? {
    switch self {
    case .inaccessibleRoot:
      return CoreL10n.text("外部草稿目录无法访问。")
    case .rootIsNotDirectory:
      return CoreL10n.text("所选外部草稿路径不是文件夹。")
    case .fileTooLarge(let path):
      return CoreL10n.format("外部草稿文件过大：%@", path)
    case .fileCountExceeded:
      return CoreL10n.text("外部草稿文件数量超过扫描上限。")
    case .totalSizeExceeded:
      return CoreL10n.text("外部草稿总大小超过扫描上限，请选择更小的文件夹。")
    case .directoryDepthExceeded:
      return CoreL10n.text("外部草稿文件夹层级过深，请选择更下层的文件夹。")
    case .entryCountExceeded:
      return CoreL10n.text("外部草稿文件夹中的项目过多，请选择更小的文件夹。")
    case .unreadableFile(let path):
      return CoreL10n.format("外部草稿文件无法读取：%@", path)
    case .invalidUTF8(let path):
      return CoreL10n.format("外部草稿文件不是 UTF-8 文本：%@", path)
    }
  }
}

/// Reads Markdown drafts from a user-selected folder without modifying it.
public struct ExternalDraftFolderService: Sendable {
  public static let maximumFileSize = 16 * 1024 * 1024
  public static let maximumFileCount = 10_000
  public static let maximumTotalSize = 64 * 1024 * 1024
  public static let maximumDirectoryDepth = 32
  public static let maximumEntryCount = 50_000

  struct ScanLimits: Sendable {
    var fileSize = ExternalDraftFolderService.maximumFileSize
    var fileCount = ExternalDraftFolderService.maximumFileCount
    var totalSize = ExternalDraftFolderService.maximumTotalSize
    var directoryDepth = ExternalDraftFolderService.maximumDirectoryDepth
    var entryCount = ExternalDraftFolderService.maximumEntryCount
  }

  private let limits: ScanLimits

  public init() { limits = ScanLimits() }

  init(limits: ScanLimits) {
    precondition(limits.fileSize > 0 && limits.fileCount > 0 && limits.totalSize > 0)
    precondition(limits.directoryDepth >= 0 && limits.entryCount > 0)
    self.limits = limits
  }

  public func scanAsync(rootURL: URL) async throws -> [ExternalDraftFile] {
    let task = Task.detached(priority: .utility) { try self.scan(rootURL: rootURL) }
    let files = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    return files
  }

  public func scan(rootURL: URL) throws -> [ExternalDraftFile] {
    try scan(rootURL: rootURL, checkCancellation: { try Task.checkCancellation() })
  }

  func scan(rootURL: URL, checkCancellation: () throws -> Void) throws -> [ExternalDraftFile] {
    try checkCancellation()
    let selectedRoot = rootURL.standardizedFileURL
    guard !isSymbolicLink(at: selectedRoot.path) else {
      throw ExternalDraftFolderServiceError.inaccessibleRoot
    }
    // Foundation can enumerate `/var/...` as `/private/var/...` even when
    // URL.resolvingSymlinksInPath keeps the former spelling. Canonicalize the
    // root with the file system before deriving relative paths.
    guard let canonicalPath = selectedRoot.path.withCString({ realpath($0, nil) }) else {
      throw ExternalDraftFolderServiceError.inaccessibleRoot
    }
    defer { free(canonicalPath) }
    let root = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
    guard fileManager.fileExists(atPath: root.path) else {
      throw ExternalDraftFolderServiceError.inaccessibleRoot
    }
    guard fileManager.isReadableFile(atPath: root.path) else {
      throw ExternalDraftFolderServiceError.inaccessibleRoot
    }
    guard isDirectory(at: root.path) else {
      throw ExternalDraftFolderServiceError.rootIsNotDirectory
    }

    var drafts: [ExternalDraftFile] = []
    try scanDirectory(root: root, drafts: &drafts, checkCancellation: checkCancellation)
    try checkCancellation()
    let sorted = drafts.sorted { $0.relativePath < $1.relativePath }
    try checkCancellation()
    return sorted
  }

  private var fileManager: FileManager { .default }

  private func scanDirectory(
    root: URL,
    drafts: inout [ExternalDraftFile],
    checkCancellation: () throws -> Void
  ) throws {
    // Enumerate lazily so a wide directory cannot allocate an unbounded URL array.
    guard
      let entries = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [],
        options: [.skipsHiddenFiles]
      )
    else {
      throw ExternalDraftFolderServiceError.inaccessibleRoot
    }
    var entryCount = 0
    var totalSize = 0
    while true {
      try checkCancellation()
      guard let entry = entries.nextObject() as? URL else { break }
      guard entryCount < limits.entryCount else {
        throw ExternalDraftFolderServiceError.entryCountExceeded
      }
      entryCount += 1
      let path = entry.path
      let attributes: [FileAttributeKey: Any]
      do { attributes = try fileManager.attributesOfItem(atPath: path) } catch { continue }
      let type = attributes[.type] as? FileAttributeType
      if type == .typeSymbolicLink {
        entries.skipDescendants()
        continue
      }

      let relativePath = relativePath(of: entry, from: root)
      guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), relativePath != ".." else {
        continue
      }

      if type == .typeDirectory {
        guard entries.level <= limits.directoryDepth else {
          throw ExternalDraftFolderServiceError.directoryDepthExceeded
        }
        continue
      }
      guard type == .typeRegular,
        isMarkdownFile(entry.lastPathComponent)
      else { continue }

      guard drafts.count < limits.fileCount else {
        throw ExternalDraftFolderServiceError.fileCountExceeded
      }
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      guard size >= 0, size <= limits.fileSize else {
        throw ExternalDraftFolderServiceError.fileTooLarge(relativePath: relativePath)
      }
      let remainingBytes = limits.totalSize - totalSize
      guard size <= remainingBytes else { throw ExternalDraftFolderServiceError.totalSizeExceeded }
      try checkCancellation()
      let data: Data
      do {
        // The descriptor-based reader also bounds files that grow after enumeration.
        data = try SafeFileReader.data(
          relativePath: relativePath, under: root,
          maximumByteCount: min(limits.fileSize, max(1, remainingBytes)))
      } catch SafeFileReadError.exceedsByteLimit {
        if remainingBytes < limits.fileSize {
          throw ExternalDraftFolderServiceError.totalSizeExceeded
        }
        throw ExternalDraftFolderServiceError.fileTooLarge(relativePath: relativePath)
      } catch {
        throw ExternalDraftFolderServiceError.unreadableFile(relativePath: relativePath)
      }
      try checkCancellation()
      guard data.count <= remainingBytes else {
        throw ExternalDraftFolderServiceError.totalSizeExceeded
      }
      totalSize += data.count
      guard var markdown = String(data: data, encoding: .utf8) else {
        throw ExternalDraftFolderServiceError.invalidUTF8(relativePath: relativePath)
      }
      // Foundation strips a UTF-8 BOM while decoding. Preserve it in the
      // editable text so the source fingerprint remains a valid write baseline.
      if data.starts(with: [0xEF, 0xBB, 0xBF]) {
        markdown = "\u{FEFF}" + markdown
      }
      drafts.append(
        ExternalDraftFile(
          relativePath: relativePath,
          title: try title(
            for: markdown.hasPrefix("\u{FEFF}") ? String(markdown.dropFirst()) : markdown,
            filename: entry.deletingPathExtension().lastPathComponent,
            checkCancellation: checkCancellation
          ),
          markdown: markdown,
          fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
      )
    }
  }

  private func relativePath(of entry: URL, from root: URL) -> String {
    let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
    guard entry.path.hasPrefix(rootPath) else { return "../" }
    return String(entry.path.dropFirst(rootPath.count))
  }

  private func isMarkdownFile(_ name: String) -> Bool {
    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
    return ext == "md" || ext == "markdown" || ext == "mdx" || ext == "txt"
  }

  private func title(
    for markdown: String, filename: String, checkCancellation: () throws -> Void
  ) throws -> String {
    var inFence = false
    var lineStart = markdown.startIndex
    while lineStart < markdown.endIndex {
      try checkCancellation()
      var lineEnd = lineStart
      var visitedCharacters = 0
      while lineEnd < markdown.endIndex, !markdown[lineEnd].isNewline {
        if visitedCharacters.isMultiple(of: 4_096) { try checkCancellation() }
        lineEnd = markdown.index(after: lineEnd)
        visitedCharacters += 1
      }
      let trimmed = markdown[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
      lineStart = lineEnd == markdown.endIndex ? lineEnd : markdown.index(after: lineEnd)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        inFence.toggle()
        continue
      }
      guard !inFence, let match = trimmed.firstMatch(of: /^#(?:[ \t]+)(.+?)[ \t]*#*[ \t]*$/) else {
        continue
      }
      let heading = String(match.1).trimmingCharacters(in: .whitespacesAndNewlines)
      if !heading.isEmpty { return heading }
    }
    return filename
  }

  private func isSymbolicLink(at path: String) -> Bool {
    (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType)
      == .typeSymbolicLink
  }

  private func isDirectory(at path: String) -> Bool {
    (try? fileManager.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeDirectory
  }
}
