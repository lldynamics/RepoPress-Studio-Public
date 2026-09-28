import Foundation

/// Where a shortcode definition was found. Repository definitions override
/// definitions supplied by a selected theme with the same name.
public enum ThemeShortcodeSource: Hashable, Sendable {
  case repositoryOverride
  case configuredTheme(name: String)
  case inferredTheme(name: String)
  case teraComponent
}

public struct ThemeShortcodeParameter: Hashable, Identifiable, Sendable {
  public let name: String
  public let defaultValue: String?

  public var id: String { name }

  public init(name: String, defaultValue: String? = nil) {
    self.name = name
    self.defaultValue = defaultValue
  }
}

/// A display-ready shortcode definition. `insertionTemplate` is an editable
/// starting point and does not attempt to evaluate template code.
public struct ThemeShortcodeDefinition: Hashable, Identifiable, Sendable {
  public let name: String
  public let parameters: [ThemeShortcodeParameter]
  public let insertionTemplate: String
  public let supportsInnerContent: Bool
  public let source: ThemeShortcodeSource
  public let repositoryPath: String

  public var id: String { name }

  public init(
    name: String,
    parameters: [ThemeShortcodeParameter],
    insertionTemplate: String,
    supportsInnerContent: Bool,
    source: ThemeShortcodeSource,
    repositoryPath: String
  ) {
    self.name = name
    self.parameters = parameters
    self.insertionTemplate = insertionTemplate
    self.supportsInnerContent = supportsInnerContent
    self.source = source
    self.repositoryPath = repositoryPath
  }
}

public enum ThemeShortcodeCatalogDiagnosticCode: String, Hashable, Sendable {
  case unsupportedSiteKind
  case repositoryUnavailable
  case unsafePath
  case unreadableDirectory
  case unreadableFile
  case fileTooLarge
  case scanLimitReached
  case ambiguousTheme
  case selectedThemeUnavailable
}

public struct ThemeShortcodeCatalogDiagnostic: Hashable, Identifiable, Sendable {
  public let code: ThemeShortcodeCatalogDiagnosticCode
  public let message: String
  public let repositoryPath: String?

  public var id: String {
    [code.rawValue, repositoryPath ?? "", message].joined(separator: "\u{1F}")
  }

  public init(
    code: ThemeShortcodeCatalogDiagnosticCode,
    message: String,
    repositoryPath: String? = nil
  ) {
    self.code = code
    self.message = message
    self.repositoryPath = repositoryPath
  }
}

public struct ThemeShortcodeCatalog: Hashable, Sendable {
  public let definitions: [ThemeShortcodeDefinition]
  public let diagnostics: [ThemeShortcodeCatalogDiagnostic]
  public let selectedThemeName: String?
  public let usesLegacyZolaShortcodes: Bool

  public init(
    definitions: [ThemeShortcodeDefinition] = [],
    diagnostics: [ThemeShortcodeCatalogDiagnostic] = [],
    selectedThemeName: String? = nil,
    usesLegacyZolaShortcodes: Bool = false
  ) {
    self.definitions = definitions
    self.diagnostics = diagnostics
    self.selectedThemeName = selectedThemeName
    self.usesLegacyZolaShortcodes = usesLegacyZolaShortcodes
  }
}

/// Reads a small, local catalog of Hugo or Zola shortcodes without loading a
/// theme, executing templates, or following symlinks. The scan is intentionally
/// bounded so it remains safe to use while editing a repository.
public struct ThemeShortcodeCatalogService: Sendable {
  public static let maximumFilesPerDirectory = 200
  public static let maximumFileBytes = 128 * 1_024
  public static let maximumTotalBytes = 1_024 * 1_024
  public static let maximumDirectoryDepth = 8

  private static let cache = ThemeShortcodeCatalogCache()

  static var cacheStatistics: ThemeShortcodeCatalogCacheStatistics { cache.statistics }

  static func resetCacheForTesting() {
    cache.removeAll()
  }

  var fileManager: FileManager { .default }

  public init() {}

  public func catalog(profile: SiteProfile) -> ThemeShortcodeCatalog {
    guard profile.siteKind == .hugo || profile.siteKind == .zola else {
      return ThemeShortcodeCatalog(
        diagnostics: [
          .init(
            code: .unsupportedSiteKind,
            message: "Shortcode catalog is available for Hugo and Zola sites only."
          )
        ]
      )
    }

    guard
      let result = profile.withLocalRepositoryRootAccess({ rootURL in
        catalog(rootURL: rootURL, siteKind: profile.siteKind)
      })
    else {
      return ThemeShortcodeCatalog(
        diagnostics: [
          .init(code: .repositoryUnavailable, message: "No local repository has been selected.")
        ]
      )
    }
    return result
  }

  private func catalog(rootURL: URL, siteKind: SiteKind) -> ThemeShortcodeCatalog {
    guard let initialKey = ThemeShortcodeCatalogCacheKey.make(rootURL: rootURL, siteKind: siteKind)
    else {
      return scan(rootURL: rootURL, siteKind: siteKind)
    }
    if let cached = Self.cache.lookup(initialKey) {
      return cached
    }

    let scanned = scan(rootURL: rootURL, siteKind: siteKind)
    guard
      let finalKey = ThemeShortcodeCatalogCacheKey.make(rootURL: rootURL, siteKind: siteKind),
      finalKey == initialKey
    else {
      return scanned
    }
    Self.cache.insert(scanned, for: finalKey)
    return scanned
  }

  private func scan(rootURL: URL, siteKind: SiteKind) -> ThemeShortcodeCatalog {
    var diagnostics: [ThemeShortcodeCatalogDiagnostic] = []
    guard isSafeDirectory(rootURL) else {
      return ThemeShortcodeCatalog(
        diagnostics: [
          .init(code: .repositoryUnavailable, message: "The local repository cannot be read.")
        ]
      )
    }

    let root = rootURL.standardizedFileURL
    let usesLegacyZolaShortcodes =
      siteKind == .zola
      && !fileManager.fileExists(atPath: root.appendingPathComponent("zola.toml").path)
      && fileManager.fileExists(atPath: root.appendingPathComponent("config.toml").path)
    var remainingBytes = Self.maximumTotalBytes
    var candidates: [Candidate] = []

    let configuredTheme = configuredThemeName(
      rootURL: root, siteKind: siteKind, diagnostics: &diagnostics)
    let themeSelection = selectTheme(
      rootURL: root,
      configuredTheme: configuredTheme,
      diagnostics: &diagnostics
    )

    if let themeSelection {
      let themeDirectories = shortcodeDirectories(
        siteKind: siteKind, under: "themes/\(themeSelection.name)")
      for directory in themeDirectories {
        guard siteKind != .zola || usesLegacyZolaShortcodes else { continue }
        candidates.append(
          contentsOf: scanDirectory(
            rootURL: root,
            relativeDirectory: directory.path,
            siteKind: siteKind,
            source: themeSelection.source,
            priority: directory.priority,
            remainingBytes: &remainingBytes,
            diagnostics: &diagnostics
          )
        )
      }
      if siteKind == .zola && !usesLegacyZolaShortcodes {
        candidates.append(
          contentsOf: scanZolaComponents(
            rootURL: root,
            relativeDirectory: "themes/\(themeSelection.name)/templates",
            priority: 30,
            remainingBytes: &remainingBytes,
            diagnostics: &diagnostics
          )
        )
      }
    }

    for directory in shortcodeDirectories(siteKind: siteKind, under: "") {
      guard siteKind != .zola || usesLegacyZolaShortcodes else { continue }
      candidates.append(
        contentsOf: scanDirectory(
          rootURL: root,
          relativeDirectory: directory.path,
          siteKind: siteKind,
          source: .repositoryOverride,
          priority: directory.priority + 100,
          remainingBytes: &remainingBytes,
          diagnostics: &diagnostics
        )
      )
    }
    if siteKind == .zola && !usesLegacyZolaShortcodes {
      candidates.append(
        contentsOf: scanZolaComponents(
          rootURL: root,
          relativeDirectory: "templates",
          priority: 130,
          remainingBytes: &remainingBytes,
          diagnostics: &diagnostics
        )
      )
    }

    var selected: [String: Candidate] = [:]
    for candidate in candidates {
      guard let current = selected[candidate.definition.name] else {
        selected[candidate.definition.name] = candidate
        continue
      }
      if candidate.priority > current.priority
        || (candidate.priority == current.priority
          && candidate.definition.repositoryPath.localizedStandardCompare(
            current.definition.repositoryPath)
            == .orderedAscending)
      {
        selected[candidate.definition.name] = candidate
      }
    }

    return ThemeShortcodeCatalog(
      definitions: selected.values.map(\.definition).sorted {
        $0.name.localizedStandardCompare($1.name) == .orderedAscending
      },
      diagnostics: diagnostics,
      selectedThemeName: themeSelection?.name,
      usesLegacyZolaShortcodes: usesLegacyZolaShortcodes
    )
  }

  func shortcodeDirectories(siteKind: SiteKind, under prefix: String) -> [(
    path: String, priority: Int
  )] {
    let base = prefix.isEmpty ? "" : prefix + "/"
    switch siteKind {
    case .hugo:
      // Hugo's documented location uses `_shortcodes`; `shortcodes` is kept
      // for older theme layouts found in existing repositories.
      return [
        (base + "layouts/_shortcodes", 20),
        (base + "layouts/shortcodes", 10),
      ]
    case .zola:
      return [
        (base + "templates/shortcodes", 20)
      ]
    default:
      return []
    }
  }

  func configuredThemeName(
    rootURL: URL,
    siteKind: SiteKind,
    diagnostics: inout [ThemeShortcodeCatalogDiagnostic]
  ) -> String? {
    let configNames: [String]
    switch siteKind {
    case .hugo:
      configNames = [
        "hugo.toml", "hugo.yaml", "hugo.yml", "hugo.json",
        "config.toml", "config.yaml", "config.yml", "config.json",
      ]
    case .zola:
      configNames =
        fileManager.fileExists(
          atPath: rootURL.appendingPathComponent("zola.toml").path)
        ? ["zola.toml"] : ["config.toml"]
    default:
      return nil
    }

    var names: Set<String> = []
    for fileName in configNames {
      let url = rootURL.appendingPathComponent(fileName, isDirectory: false)
      guard fileManager.fileExists(atPath: url.path) else { continue }
      var noBudget: Int? = nil
      guard let text = readBoundedFile(url, remainingBytes: &noBudget, diagnostics: &diagnostics)
      else { continue }
      names.formUnion(themeNames(in: text, fileExtension: url.pathExtension))
    }

    guard names.count == 1, let name = names.first else {
      if names.count > 1 {
        diagnostics.append(
          .init(
            code: .ambiguousTheme,
            message: "More than one configured theme was found; theme shortcodes were not scanned."
          )
        )
      }
      return nil
    }
    guard isSafeThemeName(name) else {
      diagnostics.append(
        .init(code: .unsafePath, message: "The configured theme name is not a safe directory name.")
      )
      return nil
    }
    return name
  }

  func selectTheme(
    rootURL: URL,
    configuredTheme: String?,
    diagnostics: inout [ThemeShortcodeCatalogDiagnostic]
  ) -> (name: String, source: ThemeShortcodeSource)? {
    if let configuredTheme {
      let themeURL = rootURL.appendingPathComponent("themes/\(configuredTheme)", isDirectory: true)
      guard isSafeDirectory(themeURL, below: rootURL) else {
        diagnostics.append(
          .init(
            code: .selectedThemeUnavailable,
            message: "The configured theme is unavailable or unsafe.",
            repositoryPath: "themes/\(configuredTheme)"
          )
        )
        return nil
      }
      return (configuredTheme, .configuredTheme(name: configuredTheme))
    }

    let themesURL = rootURL.appendingPathComponent("themes", isDirectory: true)
    guard isSafeDirectory(themesURL, below: rootURL) else { return nil }
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: themesURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
    else {
      diagnostics.append(
        .init(
          code: .unreadableDirectory, message: "The themes directory cannot be read.",
          repositoryPath: "themes")
      )
      return nil
    }
    let candidates = entries.compactMap { url -> String? in
      guard isSafeThemeName(url.lastPathComponent), isSafeDirectory(url, below: rootURL) else {
        return nil
      }
      return url.lastPathComponent
    }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    guard candidates.count == 1, let name = candidates.first else {
      if candidates.count > 1 {
        diagnostics.append(
          .init(
            code: .ambiguousTheme,
            message:
              "Several local themes are available and none is configured; theme shortcodes were not scanned.",
            repositoryPath: "themes"
          )
        )
      }
      return nil
    }
    return (name, .inferredTheme(name: name))
  }

  func uniqueParameters(_ names: [String]) -> [ThemeShortcodeParameter] {
    var seen: Set<String> = []
    return names.compactMap { name in
      guard seen.insert(name).inserted else { return nil }
      return ThemeShortcodeParameter(name: name)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func uniqueParameters(_ parameters: [ThemeShortcodeParameter])
    -> [ThemeShortcodeParameter]
  {
    var seen: Set<String> = []
    return parameters.compactMap { parameter in
      guard seen.insert(parameter.name).inserted else { return nil }
      return parameter
    }
  }

  func themeNames(in text: String, fileExtension: String) -> [String] {
    let pattern: String
    switch fileExtension.lowercased() {
    case "json":
      pattern = #"\"theme\"\s*:\s*\"([^\"]+)\""#
    case "yaml", "yml":
      pattern = #"(?m)^theme\s*:\s*[\"']?([^\"'\s#]+)"#
    default:
      return topLevelTOMLThemeNames(in: text)
    }
    return captures(pattern, in: text)
  }

  func topLevelTOMLThemeNames(in text: String) -> [String] {
    var inTable = false
    var names: [String] = []
    let pattern = #"^\s*theme\s*=\s*[\"']([^\"']+)[\"']"#
    for line in text.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("[") { inTable = true }
      guard !inTable else { continue }
      names.append(contentsOf: captures(pattern, in: String(line)))
    }
    return names
  }

  func captures(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else {
        return nil
      }
      return String(text[captureRange])
    }
  }

  func isSafeThemeName(_ value: String) -> Bool {
    isSafeShortcodeNamePart(value) && !value.contains(".")
  }

  func isSafeShortcodeNamePart<S: StringProtocol>(_ value: S) -> Bool {
    !value.isEmpty
      && value.allSatisfy { character in
        character.isLetter || character.isNumber || character == "_" || character == "-"
      }
  }

  struct Candidate {
    let definition: ThemeShortcodeDefinition
    let priority: Int
  }
}
