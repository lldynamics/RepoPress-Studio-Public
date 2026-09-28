import Foundation
import PublishingDomainContracts

extension SiteProfile {
  public func markdownPath(for draft: ArticleDraft) -> String {
    let publicPath: String
    if let link = draft.translationLink, link.translatedDraftID == draft.id,
      let rawSourcePath = link.sourceMarkdownPath,
      Self.isSafeTranslationSourcePath(rawSourcePath),
      let sourcePath = rawSourcePath.normalizedRelativePath().nilIfEmpty
    {
      if let pattern = translationMarkdownPathPattern?.trimmedForPublishing.nilIfEmpty {
        publicPath = renderPath(
          pattern: pattern,
          draft: draft,
          filename: nil,
          languageCode: link.targetLanguageCode,
          sourceSlug: Self.markdownStem(for: sourcePath)
        )
      } else if siteKind == .hugo || siteKind == .zola {
        publicPath = Self.languageSuffixPath(
          sourcePath,
          languageCode: link.targetLanguageCode
        )
      } else {
        publicPath = renderPath(pattern: markdownPathPattern, draft: draft, filename: nil)
      }
    } else if siteKind == .hugo || siteKind == .zola,
      let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
      Self.languageSuffixCode(for: repositoryPath) != nil
    {
      // Imported native locale files have no app-level source UUID yet, but
      // must round-trip to the same path instead of being rewritten as a base article.
      publicPath = repositoryPath
    } else if let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
      languageCode(matchingTranslationPathTemplate: repositoryPath) != nil
    {
      publicPath = repositoryPath
    } else {
      publicPath = renderPath(pattern: markdownPathPattern, draft: draft, filename: nil)
    }
    guard draft.isPrivate else {
      return publicPath
    }
    if isPrivateContentPath(publicPath) {
      return publicPath
    }

    if let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty,
      isPrivateContentPath(repositoryPath)
    {
      return repositoryPath
    }

    let normalizedContentRoot = contentRoot.normalizedRelativePath()
    guard !normalizedContentRoot.isEmpty,
      publicPath.hasPrefix(normalizedContentRoot + "/")
    else {
      return Self.privateContentRoot + "/" + publicPath
    }
    return Self.privateContentRoot + "/"
      + String(publicPath.dropFirst(normalizedContentRoot.count + 1))
  }

  public func translationLanguageCode(for draft: ArticleDraft) -> String? {
    if let link = draft.translationLink, link.translatedDraftID == draft.id {
      return link.targetLanguageCode
    }
    guard let repositoryPath = draft.repositoryPath?.normalizedRelativePath().nilIfEmpty else {
      return nil
    }
    if siteKind == .hugo || siteKind == .zola,
      let language = Self.languageSuffixCode(for: repositoryPath)
    {
      return language
    }
    return languageCode(matchingTranslationPathTemplate: repositoryPath)
  }

  public func isPrivateContentPath(_ repositoryPath: String) -> Bool {
    let normalizedPath = repositoryPath.normalizedRelativePath()
    return normalizedPath == Self.privateContentRoot
      || normalizedPath.hasPrefix(Self.privateContentRoot + "/")
  }

  public func imageRepositoryPath(filename: String, draft: ArticleDraft? = nil) -> String {
    renderPath(pattern: imagePathPattern, draft: draft, filename: filename)
  }

  public func publicImagePath(filename: String, draft: ArticleDraft? = nil) -> String {
    let path = renderPath(pattern: publicImagePathPattern, draft: draft, filename: filename)
    return path.hasPrefix("/") ? path : "/" + path
  }

  public func videoRepositoryPath(filename: String, draft: ArticleDraft? = nil) -> String {
    replacingImageDirectoryWithVideos(
      in: imageRepositoryPath(filename: filename, draft: draft)
    )
  }

  public func publicVideoPath(filename: String, draft: ArticleDraft? = nil) -> String {
    let path = replacingImageDirectoryWithVideos(
      in: publicImagePath(filename: filename, draft: draft)
    )
    return path.hasPrefix("/") ? path : "/" + path
  }

  private func replacingImageDirectoryWithVideos(in path: String) -> String {
    var components =
      path
      .split(separator: "/", omittingEmptySubsequences: false)
      .map(String.init)
    guard
      let imageDirectoryIndex = components.firstIndex(where: {
        $0.caseInsensitiveCompare("images") == .orderedSame
      })
    else {
      return path
    }
    components[imageDirectoryIndex] = "videos"
    return components.joined(separator: "/")
  }

  private static func markdownStem(for path: String) -> String {
    let filename = (path as NSString).lastPathComponent
    let stem = (filename as NSString).deletingPathExtension
    let components = stem.split(separator: ".")
    guard components.count > 1,
      let last = components.last,
      isLanguageCode(String(last))
    else { return stem }
    return components.dropLast().joined(separator: ".")
  }

  private static func isLanguageCode(_ code: String) -> Bool {
    code.range(
      of: #"\A[a-z]{2,3}(?:-[a-z0-9]{2,8})*\z"#,
      options: .regularExpression
    ) != nil
  }

  private static func isSafeTranslationSourcePath(_ path: String) -> Bool {
    let extensionName = (path as NSString).pathExtension.lowercased()
    return !path.isEmpty
      && !path.hasPrefix("/")
      && !path.contains("\\")
      && !path.contains("://")
      && !path.split(separator: "/").contains("..")
      && ["md", "markdown", "mdx"].contains(extensionName)
  }

  private static func languageSuffixCode(for path: String) -> String? {
    let filename = (path as NSString).lastPathComponent
    let extensionName = (filename as NSString).pathExtension.lowercased()
    guard ["md", "markdown"].contains(extensionName) else { return nil }
    let stem = (filename as NSString).deletingPathExtension
    let components = stem.split(separator: ".")
    guard components.count > 1, let language = components.last,
      isLanguageCode(String(language))
    else { return nil }
    return String(language)
  }

  private func languageCode(matchingTranslationPathTemplate path: String) -> String? {
    guard let pattern = translationMarkdownPathPattern?.trimmedForPublishing.nilIfEmpty,
      pattern.contains("{language}"),
      let tokens = try? NSRegularExpression(pattern: #"\{([A-Za-z]+)\}"#)
    else { return nil }
    let normalizedPattern = pattern.normalizedRelativePath()
    let source = normalizedPattern as NSString
    let matches = tokens.matches(
      in: normalizedPattern,
      range: NSRange(location: 0, length: source.length)
    )
    var expression = "\\A"
    var cursor = 0
    for match in matches {
      let preceding = source.substring(
        with: NSRange(location: cursor, length: match.range.location - cursor)
      )
      expression += NSRegularExpression.escapedPattern(for: preceding)
      let token = source.substring(with: match.range(at: 1))
      switch token {
      case "language": expression += #"([a-z]{2,3}(?:-[a-z0-9]{2,8})*)"#
      case "year": expression += #"[0-9]{4}"#
      case "month", "day": expression += #"[0-9]{2}"#
      case "slug", "titleSlug", "sourceSlug", "filename": expression += #"[^/]+"#
      default: return nil
      }
      cursor = match.range.location + match.range.length
    }
    let trailingLiteral = source.substring(from: cursor)
    expression += NSRegularExpression.escapedPattern(for: trailingLiteral) + "\\z"
    guard let matcher = try? NSRegularExpression(pattern: expression),
      let match = matcher.firstMatch(
        in: path,
        range: NSRange(location: 0, length: (path as NSString).length)
      ),
      match.range(at: 1).location != NSNotFound
    else { return nil }
    return (path as NSString).substring(with: match.range(at: 1))
  }

  private static func languageSuffixPath(_ sourcePath: String, languageCode: String) -> String {
    guard isLanguageCode(languageCode) else { return sourcePath }
    let path = sourcePath as NSString
    let directory = path.deletingLastPathComponent
    let extensionName = path.pathExtension
    let stem = markdownStem(for: sourcePath)
    let filename = "\(stem).\(languageCode).\(extensionName)"
    return (directory == "." ? filename : directory + "/" + filename)
      .normalizedRelativePath()
  }

  private func renderPath(
    pattern: String,
    draft: ArticleDraft?,
    filename: String?,
    languageCode: String? = nil,
    sourceSlug: String? = nil
  ) -> String {
    let date = draft?.date ?? Date()
    let calendar = Calendar(identifier: .gregorian)
    let year = String(calendar.component(.year, from: date))
    let month = String(format: "%02d", calendar.component(.month, from: date))
    let day = String(format: "%02d", calendar.component(.day, from: date))
    let slug = draft?.slug.nilIfEmpty ?? SlugService.fallbackSlug(date: date)
    let titleSlug = SlugService.slug(from: draft?.title ?? "")

    return
      pattern
      .replacingOccurrences(of: "{year}", with: year)
      .replacingOccurrences(of: "{month}", with: month)
      .replacingOccurrences(of: "{day}", with: day)
      .replacingOccurrences(of: "{slug}", with: slug)
      .replacingOccurrences(of: "{titleSlug}", with: titleSlug)
      .replacingOccurrences(of: "{language}", with: languageCode ?? "")
      .replacingOccurrences(of: "{sourceSlug}", with: sourceSlug ?? slug)
      .replacingOccurrences(of: "{filename}", with: filename ?? "")
      .normalizedRelativePath()
  }
}
