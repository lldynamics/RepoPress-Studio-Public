import Foundation

/// Keeps repository discovery aligned with the publishing layout. Importing
/// every Markdown file below `contentRoot` is unsafe for generators such as
/// Zola and Hugo because their section pages are Markdown too, but do not
/// represent articles that the workbench is allowed to rewrite.
struct ArticleRepositoryPathPolicy: Sendable {
  let publicRoot: String
  let privateRoot: String
  let translationRoot: String?
  let excludesGeneratorIndexPages: Bool

  init(profile: SiteProfile) {
    let pattern = profile.markdownPathPattern.normalizedRelativePath()
    let prefix = String(pattern.prefix { $0 != "{" })
    let prefixRoot =
      prefix
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      .normalizedRelativePath()
    let configuredContentRoot = profile.contentRoot.normalizedRelativePath()

    // Patterns normally put the first placeholder immediately after the
    // article directory (`content/posts/{year}/…`). For a pattern without a
    // directory prefix, retain the configured content root as the boundary.
    publicRoot = prefixRoot.nilIfEmpty ?? configuredContentRoot
    if let translationPattern = profile.translationMarkdownPathPattern?
      .trimmedForPublishing.nilIfEmpty,
      translationPattern.contains("{language}"),
      !translationPattern.hasPrefix("/"),
      !translationPattern.contains("\\"),
      !translationPattern.contains("://"),
      !translationPattern.split(separator: "/").contains("..")
    {
      let translationPrefix = String(translationPattern.prefix { $0 != "{" })
      translationRoot =
        translationPrefix
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        .normalizedRelativePath()
        .nilIfEmpty ?? configuredContentRoot
    } else {
      translationRoot = nil
    }

    if publicRoot.isEmpty || publicRoot == configuredContentRoot {
      privateRoot = SiteProfile.privateContentRoot
    } else if !configuredContentRoot.isEmpty,
      publicRoot.hasPrefix(configuredContentRoot + "/")
    {
      privateRoot =
        SiteProfile.privateContentRoot + "/"
        + String(
          publicRoot.dropFirst(configuredContentRoot.count + 1)
        )
    } else {
      // Jekyll-style roots such as `_posts` are outside `contentRoot` but
      // still need a corresponding private namespace rather than accepting
      // all of `private`.
      privateRoot = SiteProfile.privateContentRoot + "/" + publicRoot
    }
    excludesGeneratorIndexPages = profile.siteKind == .zola || profile.siteKind == .hugo
  }

  var scanRoots: [String] {
    // An empty public root already scans the repository. Adding `private`
    // again would parse those files twice for root-based generators.
    guard !publicRoot.isEmpty else { return [""] }
    return Array(Set([publicRoot, privateRoot] + [translationRoot].compactMap { $0 })).sorted()
  }

  func accepts(_ repositoryPath: String) -> Bool {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    let pathExtension = (normalizedPath as NSString).pathExtension.lowercased()
    guard ["md", "markdown", "mdx"].contains(pathExtension),
      isDescendant(normalizedPath, of: publicRoot)
        || isDescendant(normalizedPath, of: privateRoot)
        || translationRoot.map({ isDescendant(normalizedPath, of: $0) }) == true
    else {
      return false
    }

    guard excludesGeneratorIndexPages else { return true }
    let filename = (normalizedPath as NSString).lastPathComponent.lowercased()
    return filename != "_index.\(pathExtension)" && filename != "index.\(pathExtension)"
  }

  private func isDescendant(_ path: String, of root: String) -> Bool {
    root.isEmpty || path == root || path.hasPrefix(root + "/")
  }
}
