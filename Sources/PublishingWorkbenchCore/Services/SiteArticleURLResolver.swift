import Foundation

public struct SiteArticleURLResolver: Sendable {
  public init() {}

  public func url(baseURL: URL, markdownPath: String, siteKind: SiteKind) -> URL? {
    guard baseURL.scheme != nil, baseURL.host != nil else { return nil }
    let path = relativeWebPath(from: markdownPath, siteKind: siteKind)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return baseURL.appendingPathComponent(path)
  }

  public func relativeWebPath(from markdownPath: String, siteKind: SiteKind) -> String {
    var path = markdownPath.normalizedRelativePath()
    switch siteKind {
    case .jekyll:
      if path.hasPrefix("_posts/") {
        path = String(path.dropFirst("_posts/".count))
      }
      if let datedPath = datedPostWebPath(from: path) {
        return datedPath
      }
    case .hugo:
      if path.hasPrefix("content/") {
        path = String(path.dropFirst("content/".count))
      }
    case .hexo:
      if path.hasPrefix("source/_posts/") {
        path = String(path.dropFirst("source/_posts/".count))
      }
      if let datedPath = datedPostWebPath(from: path) {
        return datedPath
      }
    case .zola, .astro:
      for prefix in ["content/posts/", "content/", "src/content/blog/", "source/_posts/", "_posts/"] where path.hasPrefix(prefix) {
        path = String(path.dropFirst(prefix.count))
        break
      }
    }

    for suffix in [".mdx", ".markdown", ".md"] where path.hasSuffix(suffix) {
      path = String(path.dropLast(suffix.count))
      break
    }
    return "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
  }

  private func datedPostWebPath(from path: String) -> String? {
    var stem = path.normalizedRelativePath()
    for suffix in [".mdx", ".markdown", ".md"] where stem.hasSuffix(suffix) {
      stem = String(stem.dropLast(suffix.count))
      break
    }
    let parts = stem.split(separator: "-", maxSplits: 3).map(String.init)
    guard parts.count == 4,
          parts[0].count == 4,
          parts[1].count == 2,
          parts[2].count == 2,
          Int(parts[0]) != nil,
          Int(parts[1]) != nil,
          Int(parts[2]) != nil,
          !parts[3].isEmpty else {
      return nil
    }
    return "/\(parts[0])/\(parts[1])/\(parts[2])/\(parts[3])/"
  }
}
