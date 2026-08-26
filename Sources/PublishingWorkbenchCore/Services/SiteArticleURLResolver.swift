import Foundation

public struct SiteArticleURLResolver: Sendable {
  public init() {}

  public func url(baseURL: URL, markdownPath: String, siteKind: SiteKind) -> URL? {
    guard baseURL.scheme != nil, baseURL.host != nil else { return nil }
    let path = relativeWebPath(from: markdownPath, siteKind: siteKind)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return baseURL.appendingPathComponent(path)
  }

  public func url(
    baseURL: URL,
    markdownPath: String,
    profile: SiteProfile,
    permalink: String? = nil
  ) -> URL? {
    guard baseURL.scheme != nil, baseURL.host != nil else { return nil }
    let path = relativeWebPath(
      from: markdownPath,
      profile: profile,
      permalink: permalink
    ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return path.isEmpty ? baseURL : baseURL.appendingPathComponent(path)
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
    case .nextJS:
      path = removingFirstMatchingPrefix(
        from: path,
        prefixes: ["content/posts/", "posts/"]
      )
      path = "blog/" + path
    case .quartz:
      path = removingFirstMatchingPrefix(from: path, prefixes: ["content/"])
    case .foam:
      break
    case .zola, .astro, .vitePress:
      for prefix in ["content/posts/", "content/", "src/content/blog/", "docs/posts/", "source/_posts/", "_posts/"] where path.hasPrefix(prefix) {
        path = String(path.dropFirst(prefix.count))
        break
      }
    }

    return webPath(fromExtensionlessPath: removingMarkdownExtension(from: path))
  }

  public func relativeWebPath(
    from markdownPath: String,
    profile: SiteProfile,
    permalink: String? = nil
  ) -> String {
    if let override = normalizedRouteOverride(permalink) {
      return override
    }

    var path = markdownPath.normalizedRelativePath()
    let contentRoot = profile.contentRoot.normalizedRelativePath()
    if !contentRoot.isEmpty {
      path = removingFirstMatchingPrefix(
        from: path,
        prefixes: [contentRoot + "/"]
      )
    }

    switch profile.siteKind {
    case .jekyll:
      if path.hasPrefix("_posts/") {
        path = String(path.dropFirst("_posts/".count))
      }
      if let datedPath = datedPostWebPath(from: path) {
        return datedPath
      }
    case .hexo:
      if path.hasPrefix("source/_posts/") {
        path = String(path.dropFirst("source/_posts/".count))
      }
      if let datedPath = datedPostWebPath(from: path) {
        return datedPath
      }
    case .nextJS:
      path = removingFirstMatchingPrefix(
        from: path,
        prefixes: ["content/posts/", "posts/"]
      )
      path = "blog/" + path
    case .zola:
      path = removingFirstMatchingPrefix(
        from: path,
        prefixes: ["content/posts/", "content/", "posts/"]
      )
    case .astro:
      path = removingFirstMatchingPrefix(
        from: path,
        prefixes: ["src/content/blog/", "content/posts/", "posts/"]
      )
    case .vitePress:
      path = removingFirstMatchingPrefix(
        from: path,
        prefixes: ["docs/posts/", "docs/", "posts/"]
      )
    case .quartz:
      path = removingFirstMatchingPrefix(from: path, prefixes: ["content/"])
    case .hugo, .foam:
      break
    }

    return webPath(fromExtensionlessPath: removingMarkdownExtension(from: path))
  }

  private func removingFirstMatchingPrefix(from path: String, prefixes: [String]) -> String {
    for prefix in prefixes where path.hasPrefix(prefix) {
      return String(path.dropFirst(prefix.count))
    }
    return path
  }

  private func removingMarkdownExtension(from path: String) -> String {
    for suffix in [".mdx", ".markdown", ".md"] where path.hasSuffix(suffix) {
      return String(path.dropLast(suffix.count))
    }
    return path
  }

  private func webPath(fromExtensionlessPath path: String) -> String {
    var components = path
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .split(separator: "/")
      .map(String.init)
    if components.last?.lowercased() == "index"
      || components.last?.lowercased() == "readme" {
      components.removeLast()
    }
    guard !components.isEmpty else { return "/" }
    return "/" + components.joined(separator: "/") + "/"
  }

  private func normalizedRouteOverride(_ value: String?) -> String? {
    guard var path = value?.trimmedForPublishing.nilIfEmpty,
          !path.contains("://"),
          !path.hasPrefix("//"),
          !path.contains("\\") else {
      return nil
    }
    path = String(path.split(separator: "#", maxSplits: 1).first ?? "")
    path = String(path.split(separator: "?", maxSplits: 1).first ?? "")
    let components = path.split(separator: "/").map(String.init)
    guard !components.contains("..") else { return nil }
    return webPath(fromExtensionlessPath: path)
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
