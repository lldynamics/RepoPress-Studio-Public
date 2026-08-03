import Foundation

public struct SitePreviewStylesheet: Hashable, Sendable {
  public var css: String
  public var sourcePaths: [String]

  public init(css: String, sourcePaths: [String]) {
    self.css = css
    self.sourcePaths = sourcePaths
  }
}

/// Loads a bounded subset of the site's real CSS for the isolated editor
/// preview. Network imports remain unavailable because the preview web view
/// uses a restrictive content security policy.
public enum SitePreviewStyleService {
  public static let maximumStylesheetCount = 6
  public static let maximumStylesheetBytes = 192 * 1_024
  public static let maximumCombinedBytes = 512 * 1_024

  public static func load(for profile: SiteProfile) -> SitePreviewStylesheet? {
    profile.withLocalRepositoryRootAccess { rootURL in
      load(from: rootURL, siteKind: profile.siteKind)
    } ?? nil
  }

  public static func load(
    from repositoryRootURL: URL,
    siteKind: SiteKind
  ) -> SitePreviewStylesheet? {
    let rootURL = repositoryRootURL.standardizedFileURL.resolvingSymlinksInPath()
    guard rootURL.isFileURL else { return nil }

    let candidates = stylesheetCandidates(
      below: rootURL,
      siteKind: siteKind
    )
    var remainingBytes = maximumCombinedBytes
    var sourcePaths: [String] = []
    var sections: [String] = []

    for candidate in candidates.prefix(maximumStylesheetCount) {
      guard remainingBytes > 0 else { break }
      let byteLimit = min(maximumStylesheetBytes, remainingBytes)
      guard
        candidate.byteCount > 0,
        candidate.byteCount <= byteLimit,
        let data = try? Data(contentsOf: candidate.url, options: [.mappedIfSafe]),
        !data.isEmpty,
        data.count <= byteLimit
      else {
        continue
      }
      let css = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !css.isEmpty else { continue }

      remainingBytes -= data.count
      sourcePaths.append(candidate.relativePath)
      let commentPath = candidate.relativePath.replacingOccurrences(of: "*/", with: "* /")
      sections.append(
        "/* RepoPress site source: \(commentPath) */\n\(htmlSafeCSS(css))"
      )
    }

    guard !sections.isEmpty else { return nil }
    return SitePreviewStylesheet(
      css: sections.joined(separator: "\n\n"),
      sourcePaths: sourcePaths
    )
  }

  private struct Candidate {
    var url: URL
    var relativePath: String
    var score: Int
    var byteCount: Int
  }

  private static func stylesheetCandidates(
    below rootURL: URL,
    siteKind: SiteKind
  ) -> [Candidate] {
    let keys: Set<URLResourceKey> = [
      .isDirectoryKey,
      .isRegularFileKey,
      .isHiddenKey,
      .fileSizeKey,
    ]
    guard
      let enumerator = FileManager.default.enumerator(
        at: rootURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      return []
    }

    var candidates: [Candidate] = []
    while let url = enumerator.nextObject() as? URL {
      let relativePath = relativePath(for: url, below: rootURL)
      let pathComponents = relativePath.split(separator: "/").map(String.init)
      if shouldSkip(pathComponents: pathComponents) {
        if (try? url.resourceValues(forKeys: keys).isDirectory) == true {
          enumerator.skipDescendants()
        }
        continue
      }

      guard url.pathExtension.lowercased() == "css" else { continue }
      let values = try? url.resourceValues(forKeys: keys)
      guard
        values?.isRegularFile == true,
        values?.isHidden != true,
        let byteCount = values?.fileSize,
        byteCount > 0,
        byteCount <= maximumStylesheetBytes
      else {
        continue
      }
      candidates.append(
        Candidate(
          url: url,
          relativePath: relativePath,
          score: score(relativePath: relativePath, siteKind: siteKind),
          byteCount: byteCount
        )
      )
    }

    return candidates.sorted {
      if $0.score == $1.score {
        return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
      }
      return $0.score > $1.score
    }
  }

  private static func relativePath(for url: URL, below rootURL: URL) -> String {
    let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
    let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
    guard resolvedURL.path.hasPrefix(rootPath) else { return resolvedURL.lastPathComponent }
    return String(resolvedURL.path.dropFirst(rootPath.count))
  }

  private static func shouldSkip(pathComponents: [String]) -> Bool {
    let excluded = Set([
      ".git",
      ".build",
      "node_modules",
      "vendor",
      "dist",
      "build",
      "coverage",
    ])
    return pathComponents.dropLast().contains { excluded.contains($0.lowercased()) }
  }

  private static func score(relativePath: String, siteKind: SiteKind) -> Int {
    let path = relativePath.lowercased()
    let filename = URL(fileURLWithPath: path).lastPathComponent
    var result = 0

    if ["site.css", "main.css", "style.css", "styles.css", "app.css"].contains(filename) {
      result += 60
    }
    if filename.hasSuffix(".min.css") {
      result -= 12
    }
    if path.contains("/theme") || path.hasPrefix("themes/") {
      result += 10
    }

    let preferredPrefixes: [String]
    switch siteKind {
    case .zola:
      preferredPrefixes = ["static/css/", "themes/"]
    case .astro:
      preferredPrefixes = ["src/styles/", "src/assets/", "public/css/"]
    case .hugo:
      preferredPrefixes = ["assets/css/", "static/css/", "themes/"]
    case .hexo:
      preferredPrefixes = ["source/css/", "themes/"]
    case .jekyll:
      preferredPrefixes = ["assets/css/", "css/"]
    }
    if preferredPrefixes.contains(where: path.hasPrefix) {
      result += 40
    }
    result -= min(path.split(separator: "/").count, 12)
    return result
  }

  private static func htmlSafeCSS(_ css: String) -> String {
    css
      .replacingOccurrences(of: "\0", with: "")
      .replacingOccurrences(
        of: "</style",
        with: "<\\/style",
        options: [.caseInsensitive]
      )
  }
}
