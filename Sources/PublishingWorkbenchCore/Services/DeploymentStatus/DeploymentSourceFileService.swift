import Foundation
import PublishingCoreSupport

public struct DeploymentSourceDocument: Identifiable, Sendable {
  public let id = UUID()
  public let repositoryPath: String
  public let text: String
  public let lineNumber: Int
  public let selectionRange: NSRange
  public let didClampLine: Bool
}

public enum DeploymentSourceFileError: Error, Equatable, Sendable {
  case unsafePath
  case repositoryUnavailable
  case unsupportedFile
}

/// Reads only bounded UTF-8 source files below the selected repository. Remote
/// build-machine paths are never guessed or remapped to unrelated local files.
public struct DeploymentSourceFileService: Sendable {
  public static let maximumByteCount = 2 * 1_024 * 1_024

  public init() {}

  public func open(profile: SiteProfile, entry: DeploymentLogEntry) throws
    -> DeploymentSourceDocument
  {
    guard
      let document = try profile.withLocalRepositoryRootAccess({ root in
        let path = try repositoryPath(entry.filePath, root: root)
        let text = try SafeFileReader.utf8String(
          relativePath: path, under: root, maximumByteCount: Self.maximumByteCount)
        guard !text.contains("\0") else { throw DeploymentSourceFileError.unsupportedFile }
        let selection = Self.lineSelection(in: text, requestedLine: entry.line)
        return DeploymentSourceDocument(
          repositoryPath: path, text: text, lineNumber: selection.line,
          selectionRange: selection.range, didClampLine: selection.wasClamped)
      })
    else { throw DeploymentSourceFileError.repositoryUnavailable }
    return document
  }

  func repositoryPath(_ suppliedPath: String?, root: URL) throws -> String {
    guard var path = suppliedPath?.trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty, !path.contains("\\"), !path.contains(":"),
      !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw DeploymentSourceFileError.unsafePath }
    if path.hasPrefix("/") {
      let prefix = root.standardizedFileURL.path + "/"
      guard path.hasPrefix(prefix) else { throw DeploymentSourceFileError.unsafePath }
      path = String(path.dropFirst(prefix.count))
    }
    while path.hasPrefix("./") { path = String(path.dropFirst(2)) }
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !parts.isEmpty, parts.count <= 64,
      parts.allSatisfy({ part in
        !part.isEmpty && part != "." && part != ".."
          && (!part.hasPrefix(".") || part == ".github" || part == ".gitlab-ci.yml")
      })
    else { throw DeploymentSourceFileError.unsafePath }
    let supportedExtensions: Set<String> = [
      "md", "markdown", "mdx", "html", "htm", "css", "scss", "sass", "less",
      "js", "mjs", "cjs", "jsx", "ts", "tsx", "json", "toml", "yaml", "yml",
      "txt", "xml", "astro", "vue", "svelte", "njk", "liquid", "jinja", "jinja2",
    ]
    guard supportedExtensions.contains((path as NSString).pathExtension.lowercased()) else {
      throw DeploymentSourceFileError.unsupportedFile
    }
    return path
  }

  static func lineSelection(
    in text: String, requestedLine: Int?
  ) -> (line: Int, range: NSRange, wasClamped: Bool) {
    let source = text as NSString
    let requested = max(1, requestedLine ?? 1)
    var line = 1
    var start = 0
    var end = 0
    var contentsEnd = 0
    while start < source.length {
      source.getLineStart(
        nil, end: &end, contentsEnd: &contentsEnd,
        for: NSRange(location: start, length: 0))
      if line == requested || (end == source.length && contentsEnd == end) { break }
      start = end
      line += 1
      contentsEnd = start
    }
    return (line, NSRange(location: start, length: max(0, contentsEnd - start)), line != requested)
  }
}
