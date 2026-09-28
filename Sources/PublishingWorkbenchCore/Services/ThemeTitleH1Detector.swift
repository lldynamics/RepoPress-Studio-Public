import Darwin
import Foundation
import os

/// Uses the shortcode catalog's safe theme selection to inspect the article
/// layout without executing templates. `nil` means the layout is unknown.
struct ThemeTitleH1Detector: Sendable {
  private struct CacheKey: Hashable, Sendable {
    let profileID: UUID
    let siteKind: SiteKind
    let repositoryPath: String

    init(profile: SiteProfile) {
      profileID = profile.id
      siteKind = profile.siteKind
      repositoryPath = profile.localRepositoryRootPath
    }
  }

  private struct CacheEntry: Sendable {
    let repositoryRevision: UUID
    let generation: UInt64
    var rendersTitleAsH1: Bool?
    var isResolved: Bool
  }

  private struct CacheState: Sendable {
    var entries: [CacheKey: CacheEntry] = [:]
    var generation: UInt64 = 0
  }

  private enum DetectionRequest {
    case cached(Bool?)
    case calculate(UInt64)
  }

  private static let cache = OSAllocatedUnfairLock(initialState: CacheState())

  private enum TemplateInput {
    case missing
    case text(String)
    case unavailable
  }

  /// Reading this value is safe from SwiftUI body and binding getters. A miss
  /// keeps the historical enabled default until a background audit fills it.
  static func cachedRendersTitleAsH1(profile: SiteProfile) -> Bool? {
    cache.withLock { state in
      guard let entry = state.entries[CacheKey(profile: profile)], entry.isResolved else {
        return nil
      }
      return entry.rendersTitleAsH1
    }
  }

  /// Call only from background work. The repository revision changes on every
  /// completed scan, so typing and view redraws reuse the same detection.
  func cachedOrDetect(profile: SiteProfile, repositoryRevision: UUID) -> Bool? {
    let key = CacheKey(profile: profile)
    let request = Self.cache.withLock { state -> DetectionRequest in
      if let entry = state.entries[key], entry.repositoryRevision == repositoryRevision,
        entry.isResolved
      {
        return .cached(entry.rendersTitleAsH1)
      }
      state.generation &+= 1
      let generation = state.generation
      state.entries[key] = CacheEntry(
        repositoryRevision: repositoryRevision,
        generation: generation,
        rendersTitleAsH1: nil,
        isResolved: false)
      return .calculate(generation)
    }
    guard case .calculate(let generation) = request else {
      if case .cached(let result) = request { return result }
      return nil
    }
    let result = rendersTitleAsH1(profile: profile)
    Self.cache.withLock { state in
      guard state.entries[key]?.generation == generation else { return }
      state.entries[key]?.rendersTitleAsH1 = result
      state.entries[key]?.isResolved = true
    }
    return result
  }

  private func rendersTitleAsH1(profile: SiteProfile) -> Bool? {
    guard profile.siteKind == .hugo || profile.siteKind == .zola else { return nil }
    let catalog = ThemeShortcodeCatalogService().catalog(profile: profile)
    guard !catalog.diagnostics.contains(where: { $0.code == .repositoryUnavailable }) else {
      return nil
    }
    return profile.withLocalRepositoryRootAccess { rootURL in
      inspect(rootURL: rootURL, siteKind: profile.siteKind, themeName: catalog.selectedThemeName)
    } ?? nil
  }

  private func inspect(rootURL: URL, siteKind: SiteKind, themeName: String?) -> Bool? {
    let layoutPaths: [String]
    switch siteKind {
    case .hugo:
      layoutPaths = ["layouts/_default/single.html", "layouts/_default/baseof.html"]
    case .zola:
      layoutPaths = ["templates/page.html", "templates/base.html"]
    default:
      return nil
    }

    var inspected: [String] = []
    var inspectedArticleLayout = false
    for (index, layoutPath) in layoutPaths.enumerated() {
      var candidates = [layoutPath]
      if let themeName {
        candidates.append("themes/\(themeName)/\(layoutPath)")
      }
      switch selectedTemplate(in: rootURL, candidates: candidates) {
      case .missing:
        continue
      case .unavailable:
        return nil
      case .text(let text):
        inspected.append(text)
        if index == 0 { inspectedArticleLayout = true }
      }
    }
    guard !inspected.isEmpty else { return nil }
    if inspected.contains(where: { rendersTitleAsH1(in: $0, siteKind: siteKind) }) {
      return true
    }
    // An included partial can add a title heading outside the inspected files.
    if !inspectedArticleLayout || inspected.contains(where: containsUninspectedTemplate) {
      return nil
    }
    return false
  }

  private func selectedTemplate(in rootURL: URL, candidates: [String]) -> TemplateInput {
    for relativePath in candidates {
      switch readTemplate(in: rootURL, relativePath: relativePath) {
      case .missing:
        continue
      case let result:
        return result
      }
    }
    return .missing
  }

  private func readTemplate(in rootURL: URL, relativePath: String) -> TemplateInput {
    let root = rootURL.standardizedFileURL
    var current = root
    let components = relativePath.split(separator: "/")
    guard !components.isEmpty else { return .unavailable }
    for (index, component) in components.enumerated() {
      current.appendPathComponent(String(component), isDirectory: index < components.count - 1)
      var status = stat()
      if lstat(current.path, &status) != 0 {
        return errno == ENOENT ? .missing : .unavailable
      }
      let fileType = status.st_mode & mode_t(S_IFMT)
      if index < components.count - 1 {
        guard fileType == mode_t(S_IFDIR) else { return .unavailable }
      } else {
        guard fileType == mode_t(S_IFREG),
          status.st_size <= Int64(ThemeShortcodeCatalogService.maximumFileBytes)
        else { return .unavailable }
      }
    }
    guard let handle = try? FileHandle(forReadingFrom: current) else { return .unavailable }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: ThemeShortcodeCatalogService.maximumFileBytes + 1),
      data.count <= ThemeShortcodeCatalogService.maximumFileBytes,
      let text = String(data: data, encoding: .utf8)
    else { return .unavailable }
    return .text(text)
  }

  private func rendersTitleAsH1(in template: String, siteKind: SiteKind) -> Bool {
    let uncommented = template.replacingOccurrences(
      of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
    guard
      let headings = try? NSRegularExpression(
        pattern: #"(?is)<h1\b[^>]*>(.*?)</h1\s*>"#)
    else { return false }
    let range = NSRange(uncommented.startIndex..., in: uncommented)
    return headings.matches(in: uncommented, range: range).contains { match in
      guard let headingRange = Range(match.range(at: 1), in: uncommented) else { return false }
      let heading = String(uncommented[headingRange])
      let titlePattern =
        siteKind == .hugo
        ? #"(?is)\{\{[^}]*\.(?:Page\.)?Title\b[^}]*\}\}"#
        : #"(?is)\{\{[^}]*\b(?:page|section)\.title\b[^}]*\}\}"#
      return heading.range(of: titlePattern, options: .regularExpression) != nil
    }
  }

  private func containsUninspectedTemplate(_ template: String) -> Bool {
    template.range(
      of: #"(?i)(?:\{\{\s*(?:partial|template)\b|\{%\s*(?:include|import|extends)\b)"#,
      options: .regularExpression) != nil
  }
}
