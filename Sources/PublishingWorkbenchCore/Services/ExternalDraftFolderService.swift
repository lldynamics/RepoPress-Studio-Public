import CryptoKit
import Foundation

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

  public init() {}

  public func scan(rootURL: URL) throws -> [ExternalDraftFile] {
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
    try scanDirectory(root: root, directory: root, drafts: &drafts)
    return drafts.sorted { $0.relativePath < $1.relativePath }
  }

  private var fileManager: FileManager { .default }

  private func scanDirectory(
    root: URL,
    directory: URL,
    drafts: inout [ExternalDraftFile]
  ) throws {
    let entries: [URL]
    do {
      entries = try fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [],
        options: [.skipsHiddenFiles]
      )
    } catch {
      if directory == root {
        throw ExternalDraftFolderServiceError.inaccessibleRoot
      }
      return
    }

    for entry in entries {
      let path = entry.path
      let attributes = try? fileManager.attributesOfItem(atPath: path)
      guard let attributes else { continue }
      let type = attributes[.type] as? FileAttributeType
      if type == .typeSymbolicLink { continue }

      let relativePath = relativePath(of: entry, from: root)
      guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), relativePath != ".." else {
        continue
      }

      if type == .typeDirectory {
        // `skipsHiddenFiles` handles normal dot directories; this explicit check
        // also keeps the rule stable if the Foundation enumerator changes.
        guard !entry.lastPathComponent.hasPrefix(".") else { continue }
        try scanDirectory(root: root, directory: entry, drafts: &drafts)
        continue
      }
      guard type == .typeRegular,
        isMarkdownFile(entry.lastPathComponent)
      else { continue }

      guard drafts.count < Self.maximumFileCount else {
        throw ExternalDraftFolderServiceError.fileCountExceeded
      }
      let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
      guard size <= Self.maximumFileSize else {
        throw ExternalDraftFolderServiceError.fileTooLarge(relativePath: relativePath)
      }
      let data: Data
      do {
        data = try Data(contentsOf: entry, options: [.mappedIfSafe])
      } catch {
        throw ExternalDraftFolderServiceError.unreadableFile(relativePath: relativePath)
      }
      guard data.count <= Self.maximumFileSize else {
        throw ExternalDraftFolderServiceError.fileTooLarge(relativePath: relativePath)
      }
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
          title: title(
            for: markdown.hasPrefix("\u{FEFF}") ? String(markdown.dropFirst()) : markdown,
            filename: entry.deletingPathExtension().lastPathComponent
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

  private func title(for markdown: String, filename: String) -> String {
    var inFence = false
    for line in markdown.split(whereSeparator: \.isNewline).map(String.init) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
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
