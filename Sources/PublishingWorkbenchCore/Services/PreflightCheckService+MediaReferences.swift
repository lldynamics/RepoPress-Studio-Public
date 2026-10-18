import Foundation
import PublishingMarkdownCore

extension PreflightCheckService {
  private static let markdownImageRegex = try? NSRegularExpression(
    pattern: #"!\[[^\]]*\]\(([^)]+)\)"#
  )
  func missingMarkdownImagePaths(in draft: ArticleDraft) -> [String] {
    let registered = Set(
      draft.attachments
        .filter { $0.mediaKind == .image }
        .map(\.relativePublishPath)
    )
    guard let regex = Self.markdownImageRegex else {
      return []
    }

    let text = draft.bodyMarkdown
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard let matchRange = Range(match.range(at: 1), in: text) else { return nil }
      let path = String(text[matchRange])
      guard !path.hasPrefix("http://"), !path.hasPrefix("https://"), !path.hasPrefix("data:") else {
        return nil
      }
      return registered.contains(path) ? nil : path
    }
  }
  func shortcodeIssues(body: String, profile: SiteProfile) -> [PreflightIssue] {
    guard profile.siteKind == .hugo || profile.siteKind == .zola else { return [] }
    let detected = MarkdownSSGComponentLibraryService.detectedReferences(in: body)
    guard !detected.isEmpty else { return [] }
    let catalog = ThemeShortcodeCatalogService().catalog(profile: profile)
    let references = detected.filter { reference in
      guard !reference.isClosing else { return false }
      switch profile.siteKind {
      case .hugo:
        return reference.engineSyntax == .hugoAngle
          || reference.engineSyntax == .hugoPercent
          || reference.engineSyntax == .zolaInlineComponent
      case .zola:
        return catalog.usesLegacyZolaShortcodes
          ? reference.engineSyntax == .zolaLegacy || reference.engineSyntax == .zolaComponent
          : reference.engineSyntax == .zolaInlineComponent
      default: return false
      }
    }
    guard !references.isEmpty else { return [] }

    let known = Set(catalog.definitions.map { $0.name.lowercased() })
      .union(profile.siteKind == .hugo ? Self.hugoEmbeddedShortcodes : [])
    let unknown = Dictionary(
      grouping: references.filter {
        !known.contains($0.name.lowercased())
          && !(profile.siteKind == .zola && $0.engineSyntax == .zolaLegacy
            && Self.zolaTeraFunctions.contains($0.name.lowercased()))
      },
      by: { $0.name.lowercased() }
    )
    guard !unknown.isEmpty else { return [] }

    let catalogIncomplete = catalog.diagnostics.contains {
      $0.code != .unsupportedSiteKind
    }
    return unknown.keys.sorted().compactMap { name in
      guard let occurrences = unknown[name], let first = occurrences.first else { return nil }
      let lines = occurrences.map(\.lineNumber).sorted().map(String.init).joined(separator: "、")
      return PreflightIssue(
        severity: catalogIncomplete ? .warning : .error,
        title: catalogIncomplete ? CoreL10n.text("短代码目录无法核实") : CoreL10n.text("未知短代码"),
        message: catalogIncomplete
          ? CoreL10n.format("第 %@ 行的 %@ 尚无法与主题目录核对，请检查仓库或主题配置。", lines, first.name)
          : CoreL10n.format("第 %@ 行使用了主题中不存在的短代码 %@。", lines, first.name),
        field: PreflightIssueField.body.rawValue,
        relatedValue: first.name
      )
    }
  }

  private static let hugoEmbeddedShortcodes: Set<String> = [
    "details", "figure", "highlight", "instagram", "param", "qr",
    "ref", "relref", "vimeo", "x", "youtube",
  ]

  // Zola 0.23+ parses content as Tera. A function call resembles the old
  // `{{ shortcode(...) }}` form, so documented built-ins are not shortcode errors.
  private static let zolaTeraFunctions: Set<String> = [
    "get_env", "get_hash", "get_image_metadata", "get_page", "get_section",
    "get_taxonomy", "get_taxonomy_term", "get_taxonomy_url", "get_url", "load_data",
    "range", "resize_image", "text_direction", "throw", "trans",
  ]

}
