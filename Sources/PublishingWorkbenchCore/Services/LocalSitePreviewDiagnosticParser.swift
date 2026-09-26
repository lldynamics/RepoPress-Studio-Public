import Foundation
import PublishingPreviewCore

/// A source location reported by the local static-site preview process.
///
/// `relativePath` is always relative to the configured repository root. The
/// parser rejects locations outside that root before constructing this value,
/// so presentation layers can safely use it for in-editor navigation.
public struct LocalSitePreviewRuntimeDiagnostic: Codable, Hashable, Identifiable, Sendable {
  public let relativePath: String
  public let line: Int
  public let column: Int?
  public let message: String
  public let severity: LocalSitePreviewDiagnosticSeverity

  public var id: String {
    "\(relativePath):\(line):\(column ?? 0):\(severity.rawValue):\(message)"
  }

  public init(
    relativePath: String,
    line: Int,
    column: Int? = nil,
    message: String,
    severity: LocalSitePreviewDiagnosticSeverity = .error
  ) {
    self.relativePath = relativePath
    self.line = line
    self.column = column
    self.message = message
    self.severity = severity
  }

  public func targets(relativeArticlePath: String?) -> Bool {
    relativeArticlePath == relativePath
  }
}

/// Parses source locations emitted by Hugo, Astro and the other SSG runners.
/// The location format is deliberately shared: most tools eventually print
/// `path:line[:column]`, even when their surrounding error text differs.
struct LocalSitePreviewDiagnosticParser {
  private static let locationExpression = try? NSRegularExpression(
    pattern:
      #"((?:(?:file://)?/[^\n\"'()\[\]:]+|(?:\.?/)?(?:[^\s/\"'()\[\]:]+/)*[^\s/\"'()\[\]:]+\.(?:md|mdx|markdown|astro|html?|tsx?|jsx?|vue|svelte|ya?ml|toml|json|css|scss|sass))):(\d+)(?::(\d+))?"#,
    options: [.caseInsensitive]
  )

  private static let supportedExtensions: Set<String> = [
    "md", "mdx", "markdown", "astro", "html", "htm", "ts", "tsx", "js", "jsx", "vue",
    "svelte", "yaml", "yml", "toml", "json", "css", "scss", "sass",
  ]

  static func parse(line: String, rootPath: String) -> LocalSitePreviewRuntimeDiagnostic? {
    guard let rootURL = repositoryRootURL(rootPath) else { return nil }
    let range = NSRange(line.startIndex..., in: line)
    guard let match = locationExpression?.firstMatch(in: line, options: [], range: range),
      let pathRange = Range(match.range(at: 1), in: line),
      let lineRange = Range(match.range(at: 2), in: line),
      let sourceLine = Int(line[lineRange]),
      sourceLine > 0
    else {
      return nil
    }

    let sourcePath = String(line[pathRange])
    guard let relativePath = relativePath(for: sourcePath, rootURL: rootURL) else { return nil }
    let column = Range(match.range(at: 3), in: line).flatMap { Int(line[$0]) }

    return LocalSitePreviewRuntimeDiagnostic(
      relativePath: relativePath,
      line: sourceLine,
      column: column,
      message: line.trimmingCharacters(in: .whitespacesAndNewlines),
      severity: severity(in: line)
    )
  }

  static func diagnostics(lines: [String], rootPath: String) -> [LocalSitePreviewRuntimeDiagnostic]
  {
    lines.reduce(into: []) { diagnostics, line in
      guard let diagnostic = parse(line: line, rootPath: rootPath),
        !diagnostics.contains(diagnostic)
      else {
        return
      }
      diagnostics.append(diagnostic)
    }
  }

  private static func repositoryRootURL(_ rootPath: String) -> URL? {
    let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return URL(fileURLWithPath: trimmed, isDirectory: true)
      .standardizedFileURL
      .resolvingSymlinksInPath()
  }

  private static func relativePath(for loggedPath: String, rootURL: URL) -> String? {
    let decodedPath: String
    if loggedPath.hasPrefix("file://"), let url = URL(string: loggedPath), url.isFileURL {
      decodedPath = url.path
    } else {
      decodedPath = loggedPath.removingPercentEncoding ?? loggedPath
    }

    let components = decodedPath.split(separator: "/", omittingEmptySubsequences: true)
    guard !components.contains("..") else { return nil }

    let candidateURL: URL
    if decodedPath.hasPrefix("/") {
      candidateURL = URL(fileURLWithPath: decodedPath)
    } else {
      candidateURL = URL(fileURLWithPath: decodedPath, relativeTo: rootURL)
    }
    let canonicalURL = candidateURL.standardizedFileURL.resolvingSymlinksInPath()
    guard supportedExtensions.contains(canonicalURL.pathExtension.lowercased()) else { return nil }

    let rootPath = rootURL.path.hasSuffix("/") ? String(rootURL.path.dropLast()) : rootURL.path
    let candidatePath = canonicalURL.path
    guard candidatePath.hasPrefix(rootPath + "/") else { return nil }
    return String(candidatePath.dropFirst(rootPath.count + 1))
  }

  private static func severity(in line: String) -> LocalSitePreviewDiagnosticSeverity {
    let lowercased = line.lowercased()
    if lowercased.contains("warning") || lowercased.contains("warn ") {
      return .warning
    }
    return .error
  }
}
