import Darwin
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

  private var fileManager: FileManager { .default }

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
        scan(rootURL: rootURL, siteKind: profile.siteKind)
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

  private func shortcodeDirectories(siteKind: SiteKind, under prefix: String) -> [(
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

  private func configuredThemeName(
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

  private func selectTheme(
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

  private func scanDirectory(
    rootURL: URL,
    relativeDirectory: String,
    siteKind: SiteKind,
    source: ThemeShortcodeSource,
    priority: Int,
    remainingBytes: inout Int,
    diagnostics: inout [ThemeShortcodeCatalogDiagnostic]
  ) -> [Candidate] {
    guard isSafeRelativePath(relativeDirectory) else {
      diagnostics.append(
        .init(code: .unsafePath, message: "An unsafe shortcode directory was rejected."))
      return []
    }
    let directoryURL = rootURL.appendingPathComponent(relativeDirectory, isDirectory: true)
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    guard isSafeDirectory(directoryURL, below: rootURL) else {
      diagnostics.append(
        .init(
          code: .unsafePath,
          message: "A shortcode directory is a symlink or escapes the repository.",
          repositoryPath: relativeDirectory)
      )
      return []
    }

    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard
      let enumerator = fileManager.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      diagnostics.append(
        .init(
          code: .unreadableDirectory, message: "A shortcode directory cannot be read.",
          repositoryPath: relativeDirectory)
      )
      return []
    }

    var result: [Candidate] = []
    var fileCount = 0
    while let url = enumerator.nextObject() as? URL {
      guard let relativePath = repositoryPath(of: url, below: rootURL) else {
        diagnostics.append(
          .init(code: .unsafePath, message: "A shortcode entry escaped the repository root."))
        continue
      }
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        diagnostics.append(
          .init(
            code: .unreadableFile, message: "A shortcode entry cannot be inspected.",
            repositoryPath: relativePath))
        continue
      }
      if values.isSymbolicLink == true || isSymbolicLink(url) {
        enumerator.skipDescendants()
        diagnostics.append(
          .init(
            code: .unsafePath, message: "A symbolic link was excluded from the shortcode scan.",
            repositoryPath: relativePath))
        continue
      }
      if values.isDirectory == true {
        if depth(of: url, below: directoryURL) > Self.maximumDirectoryDepth {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true, isTemplateFile(url, siteKind: siteKind) else { continue }
      fileCount += 1
      guard fileCount <= Self.maximumFilesPerDirectory else {
        diagnostics.append(
          .init(
            code: .scanLimitReached,
            message: "The shortcode directory contains too many template files.",
            repositoryPath: relativeDirectory))
        break
      }
      var byteBudget: Int? = remainingBytes
      guard
        let contents = readBoundedFile(url, remainingBytes: &byteBudget, diagnostics: &diagnostics)
      else { continue }
      remainingBytes = byteBudget ?? 0
      guard
        let definition = definition(
          for: url,
          contents: contents,
          siteKind: siteKind,
          source: source,
          relativeDirectory: relativeDirectory,
          repositoryPath: relativePath
        )
      else { continue }
      result.append(Candidate(definition: definition, priority: priority))
    }
    return result
  }

  private func scanZolaComponents(
    rootURL: URL,
    relativeDirectory: String,
    priority: Int,
    remainingBytes: inout Int,
    diagnostics: inout [ThemeShortcodeCatalogDiagnostic]
  ) -> [Candidate] {
    guard isSafeRelativePath(relativeDirectory) else {
      diagnostics.append(
        .init(code: .unsafePath, message: "An unsafe component directory was rejected."))
      return []
    }
    let directoryURL = rootURL.appendingPathComponent(relativeDirectory, isDirectory: true)
    guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }
    guard isSafeDirectory(directoryURL, below: rootURL) else {
      diagnostics.append(
        .init(
          code: .unsafePath,
          message: "A component directory is a symlink or escapes the repository.",
          repositoryPath: relativeDirectory)
      )
      return []
    }

    let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard
      let enumerator = fileManager.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: keys,
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else {
      diagnostics.append(
        .init(
          code: .unreadableDirectory, message: "A component directory cannot be read.",
          repositoryPath: relativeDirectory)
      )
      return []
    }

    var result: [Candidate] = []
    var fileCount = 0
    while let url = enumerator.nextObject() as? URL {
      guard let repositoryPath = repositoryPath(of: url, below: rootURL) else {
        diagnostics.append(
          .init(code: .unsafePath, message: "A component entry escaped the repository root."))
        continue
      }
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
        diagnostics.append(
          .init(
            code: .unreadableFile, message: "A component entry cannot be inspected.",
            repositoryPath: repositoryPath))
        continue
      }
      if values.isSymbolicLink == true || isSymbolicLink(url) {
        enumerator.skipDescendants()
        diagnostics.append(
          .init(
            code: .unsafePath, message: "A symbolic link was excluded from the component scan.",
            repositoryPath: repositoryPath))
        continue
      }
      if values.isDirectory == true {
        if depth(of: url, below: directoryURL) > Self.maximumDirectoryDepth {
          enumerator.skipDescendants()
        }
        continue
      }
      guard values.isRegularFile == true, url.pathExtension.lowercased() == "html" else { continue }
      fileCount += 1
      guard fileCount <= Self.maximumFilesPerDirectory else {
        diagnostics.append(
          .init(
            code: .scanLimitReached,
            message: "The component directory contains too many template files.",
            repositoryPath: relativeDirectory))
        break
      }
      var byteBudget: Int? = remainingBytes
      guard
        let contents = readBoundedFile(url, remainingBytes: &byteBudget, diagnostics: &diagnostics)
      else { continue }
      remainingBytes = byteBudget ?? 0
      for component in teraComponents(in: contents) {
        result.append(
          Candidate(
            definition: ThemeShortcodeDefinition(
              name: component.name,
              parameters: component.parameters,
              insertionTemplate: teraComponentSnippet(
                name: component.name,
                parameters: component.parameters,
                inner: component.supportsInnerContent
              ),
              supportsInnerContent: component.supportsInnerContent,
              source: .teraComponent,
              repositoryPath: repositoryPath
            ),
            priority: priority
          )
        )
      }
    }
    return result
  }

  private func definition(
    for url: URL,
    contents: String,
    siteKind: SiteKind,
    source: ThemeShortcodeSource,
    relativeDirectory: String,
    repositoryPath: String
  ) -> ThemeShortcodeDefinition? {
    let nameFromPath = shortcodeName(
      repositoryPath: repositoryPath, relativeDirectory: relativeDirectory)
    switch siteKind {
    case .hugo:
      guard
        let nameFromPath = hugoShortcodeName(
          repositoryPath: repositoryPath, relativeDirectory: relativeDirectory)
      else { return nil }
      let parameters = hugoParameters(in: contents)
      let supportsInnerContent = contents.range(of: ".Inner") != nil
      return ThemeShortcodeDefinition(
        name: nameFromPath,
        parameters: parameters,
        insertionTemplate: hugoSnippet(
          name: nameFromPath, parameters: parameters, inner: supportsInnerContent),
        supportsInnerContent: supportsInnerContent,
        source: source,
        repositoryPath: repositoryPath
      )
    case .zola:
      guard let nameFromPath else { return nil }
      let macro = teraMacros(in: contents).first(where: { $0.name == nameFromPath })
      let parameters = macro?.parameters ?? teraContextParameters(in: contents)
      let supportsInnerContent = macro?.supportsBody ?? containsTeraBody(in: contents)
      return ThemeShortcodeDefinition(
        name: nameFromPath,
        parameters: parameters,
        insertionTemplate: legacyTeraSnippet(
          name: nameFromPath, parameters: parameters, inner: supportsInnerContent),
        supportsInnerContent: supportsInnerContent,
        source: source,
        repositoryPath: repositoryPath
      )
    default:
      return nil
    }
  }

  private func shortcodeName(repositoryPath: String, relativeDirectory: String) -> String? {
    let prefix = relativeDirectory + "/"
    guard repositoryPath.hasPrefix(prefix) else { return nil }
    let relative = String(repositoryPath.dropFirst(prefix.count))
    let suffixless = (relative as NSString).deletingPathExtension
    let components = suffixless.split(separator: "/").map(String.init)
    guard !components.isEmpty, components.allSatisfy(isSafeShortcodeNamePart) else { return nil }
    return components.joined(separator: "/")
  }

  private func hugoShortcodeName(
    repositoryPath: String, relativeDirectory: String
  ) -> String? {
    let prefix = relativeDirectory + "/"
    guard repositoryPath.hasPrefix(prefix) else { return nil }
    let relative = String(repositoryPath.dropFirst(prefix.count))
    let suffixless = (relative as NSString).deletingPathExtension
    var path = suffixless.split(separator: "/").map(String.init)
    guard let filename = path.popLast(), path.allSatisfy(isSafeShortcodeNamePart) else {
      return nil
    }
    var parts = filename.split(separator: ".").map(String.init)
    while parts.count > 1, let suffix = parts.last {
      let normalizedSuffix = suffix.lowercased()
      let isOutputFormat = ["amp", "csv", "html", "json", "rss", "xml"]
        .contains(normalizedSuffix)
      let isLanguage =
        normalizedSuffix.range(
          of: #"^[a-z]{2,3}(?:-[a-z]{2,4})?$"#, options: .regularExpression
        ) != nil
      guard isOutputFormat || isLanguage else { break }
      parts.removeLast()
    }
    let baseName = parts.joined(separator: ".")
    guard isSafeShortcodeNamePart(baseName) else { return nil }
    path.append(baseName)
    return path.joined(separator: "/")
  }

  private func hugoParameters(in contents: String) -> [ThemeShortcodeParameter] {
    let getNames = captures(#"\.Get\s+\"([A-Za-z][A-Za-z0-9_-]*)\""#, in: contents)
    let paramsNames = captures(#"\.Params\.([A-Za-z][A-Za-z0-9_-]*)"#, in: contents)
    let indexNames = captures(#"index\s+\.Params\s+\"([A-Za-z][A-Za-z0-9_-]*)\""#, in: contents)
    return uniqueParameters(getNames + paramsNames + indexNames)
  }

  private func teraMacros(in contents: String) -> [(
    name: String, parameters: [ThemeShortcodeParameter], supportsBody: Bool
  )] {
    let expression = #"(?s)\{%\s*macro\s+([A-Za-z][A-Za-z0-9_-]*)\s*\((.*?)\)\s*%\}"#
    guard let regex = try? NSRegularExpression(pattern: expression) else { return [] }
    let range = NSRange(contents.startIndex..., in: contents)
    return regex.matches(in: contents, range: range).compactMap { match in
      guard let nameRange = Range(match.range(at: 1), in: contents),
        let argumentsRange = Range(match.range(at: 2), in: contents)
      else { return nil }
      let arguments = String(contents[argumentsRange])
      let parsed = arguments.split(separator: ",").compactMap {
        argument -> ThemeShortcodeParameter? in
        let pieces = argument.split(separator: "=", maxSplits: 1).map {
          $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let name = pieces.first, isSafeShortcodeNamePart(name) else { return nil }
        return ThemeShortcodeParameter(
          name: name, defaultValue: pieces.count == 2 ? pieces[1] : nil)
      }
      let hasBody = parsed.contains { $0.name == "body" } || containsTeraBody(in: contents)
      return (String(contents[nameRange]), parsed.filter { $0.name != "body" }, hasBody)
    }
  }

  private func teraComponents(in contents: String) -> [(
    name: String, parameters: [ThemeShortcodeParameter], supportsInnerContent: Bool
  )] {
    let expression =
      #"(?s)\{%\s*component\s+([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*\((.*?)\)\s*(?:\{.*?\})?\s*%\}"#
    guard let regex = try? NSRegularExpression(pattern: expression) else { return [] }
    let range = NSRange(contents.startIndex..., in: contents)
    return regex.matches(in: contents, range: range).compactMap { match in
      guard let nameRange = Range(match.range(at: 1), in: contents),
        let argumentsRange = Range(match.range(at: 2), in: contents),
        let declarationRange = Range(match.range, in: contents)
      else { return nil }
      let parameters = teraComponentParameters(in: String(contents[argumentsRange]))
      let remainder = contents[declarationRange.upperBound...]
      let componentBody = String(remainder).components(separatedBy: "{% endcomponent").first ?? ""
      return (
        String(contents[nameRange]),
        parameters,
        containsTeraBody(in: String(componentBody))
      )
    }
  }

  private func teraComponentParameters(in arguments: String) -> [ThemeShortcodeParameter] {
    let tokens = splitTeraArguments(arguments)
    var parameters: [ThemeShortcodeParameter] = []
    for token in tokens {
      let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.hasPrefix("...") else { continue }
      let explicit = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
      guard let name = captures(#"^([A-Za-z_][A-Za-z0-9_]*)"#, in: explicit).first else { continue }
      // Implicit parameters resolve from the caller context and do not need a
      // placeholder in a copied insertion snippet.
      guard !trimmed.hasPrefix("@") else { continue }
      let defaultValue = explicit.split(separator: "=", maxSplits: 1).dropFirst().first
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      parameters.append(ThemeShortcodeParameter(name: name, defaultValue: defaultValue))
    }
    return uniqueParameters(parameters)
  }

  private func splitTeraArguments(_ arguments: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var nesting = 0
    for character in arguments {
      if let activeQuote = quote {
        current.append(character)
        if character == activeQuote { quote = nil }
        continue
      }
      if character == "\"" || character == "'" || character == "`" {
        quote = character
        current.append(character)
      } else if character == "(" || character == "[" || character == "{" {
        nesting += 1
        current.append(character)
      } else if character == ")" || character == "]" || character == "}" {
        nesting = max(0, nesting - 1)
        current.append(character)
      } else if character == "," && nesting == 0 {
        result.append(current)
        current = ""
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  private func teraContextParameters(in contents: String) -> [ThemeShortcodeParameter] {
    let names = captures(#"\{\{\s*([A-Za-z][A-Za-z0-9_-]*)"#, in: contents)
    let excluded: Set<String> = [
      "config", "page", "section", "current_path", "get_url", "get_taxonomy_url", "trans", "body",
    ]
    return uniqueParameters(names.filter { !excluded.contains($0) })
  }

  private func containsTeraBody(in contents: String) -> Bool {
    captures(#"\{\{\s*(body)\b"#, in: contents).isEmpty == false
      || contents.range(of: "{% end %}") != nil
  }

  private func uniqueParameters(_ names: [String]) -> [ThemeShortcodeParameter] {
    var seen: Set<String> = []
    return names.compactMap { name in
      guard seen.insert(name).inserted else { return nil }
      return ThemeShortcodeParameter(name: name)
    }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private func uniqueParameters(_ parameters: [ThemeShortcodeParameter])
    -> [ThemeShortcodeParameter]
  {
    var seen: Set<String> = []
    return parameters.compactMap { parameter in
      guard seen.insert(parameter.name).inserted else { return nil }
      return parameter
    }
  }

  private func hugoSnippet(name: String, parameters: [ThemeShortcodeParameter], inner: Bool)
    -> String
  {
    let hints = parameters.map { "\($0.name)=\"\($0.defaultValue ?? "value")\"" }.joined(
      separator: " ")
    let opening = "{{< \(name)\(hints.isEmpty ? "" : " " + hints) >}}"
    return inner ? opening + "\n\n{{< /\(name) >}}" : opening
  }

  private func legacyTeraSnippet(name: String, parameters: [ThemeShortcodeParameter], inner: Bool)
    -> String
  {
    let hints = parameters.map { "\($0.name)=\($0.defaultValue ?? "\"value\"")" }.joined(
      separator: ", ")
    if inner {
      return "{% \(name)(\(hints)) %}\n\n{% end %}"
    }
    return "{{ \(name)(\(hints)) }}"
  }

  private func teraComponentSnippet(
    name: String, parameters: [ThemeShortcodeParameter], inner: Bool
  ) -> String {
    let hints = parameters.map { "\($0.name)=\($0.defaultValue ?? "\"value\"")" }.joined(
      separator: " ")
    if inner {
      return "{% <\(name)\(hints.isEmpty ? "" : " " + hints)> %}\n\n{% </\(name)> %}"
    }
    return "{{<\(name)\(hints.isEmpty ? "" : " " + hints) />}}"
  }

  private func themeNames(in text: String, fileExtension: String) -> [String] {
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

  private func topLevelTOMLThemeNames(in text: String) -> [String] {
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

  private func captures(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return regex.matches(in: text, range: range).compactMap { match in
      guard match.numberOfRanges > 1, let captureRange = Range(match.range(at: 1), in: text) else {
        return nil
      }
      return String(text[captureRange])
    }
  }

  private func readBoundedFile(
    _ url: URL,
    remainingBytes: inout Int?,
    diagnostics: inout [ThemeShortcodeCatalogDiagnostic]
  ) -> String? {
    guard !isSymbolicLink(url),
      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
      values.isRegularFile == true,
      let size = values.fileSize,
      size >= 0
    else {
      diagnostics.append(
        .init(
          code: .unsafePath, message: "A non-regular shortcode file was excluded.",
          repositoryPath: url.lastPathComponent))
      return nil
    }
    guard size <= Self.maximumFileBytes else {
      diagnostics.append(
        .init(
          code: .fileTooLarge, message: "A shortcode template exceeds the read limit.",
          repositoryPath: url.lastPathComponent))
      return nil
    }
    if let remaining = remainingBytes {
      guard remaining >= size else {
        diagnostics.append(
          .init(
            code: .scanLimitReached, message: "The shortcode catalog reached its total read limit.")
        )
        return nil
      }
      remainingBytes = remaining - size
    }
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
      let text = String(data: data, encoding: .utf8)
    else {
      diagnostics.append(
        .init(
          code: .unreadableFile, message: "A shortcode template cannot be decoded as UTF-8.",
          repositoryPath: url.lastPathComponent))
      return nil
    }
    return text
  }

  private func isSafeDirectory(_ url: URL) -> Bool {
    var status = stat()
    guard !isSymbolicLink(url), Darwin.lstat(url.path, &status) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFDIR
  }

  private func isSafeDirectory(_ url: URL, below rootURL: URL) -> Bool {
    let root = rootURL.standardizedFileURL
    let directory = url.standardizedFileURL
    let rootPath = root.path
    let directoryPath = directory.path
    guard directoryPath.hasPrefix(rootPath + "/"), isSafeDirectory(root) else { return false }
    var current = root
    for component in directoryPath.dropFirst(rootPath.count + 1).split(separator: "/") {
      current.appendPathComponent(String(component), isDirectory: true)
      guard isSafeDirectory(current) else { return false }
    }
    return true
  }

  private func isSymbolicLink(_ url: URL) -> Bool {
    var status = stat()
    guard Darwin.lstat(url.path, &status) == 0 else { return false }
    return (status.st_mode & S_IFMT) == S_IFLNK
  }

  private func repositoryPath(of url: URL, below root: URL) -> String? {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return nil }
    return String(path.dropFirst(rootPath.count + 1))
  }

  private func depth(of url: URL, below root: URL) -> Int {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard path.hasPrefix(rootPath + "/") else { return .max }
    return path.dropFirst(rootPath.count + 1).split(separator: "/").count
  }

  private func isTemplateFile(_ url: URL, siteKind: SiteKind) -> Bool {
    switch siteKind {
    case .hugo:
      return ["html", "htm", "xml"].contains(url.pathExtension.lowercased())
    case .zola:
      return ["html", "htm", "tera"].contains(url.pathExtension.lowercased())
    default:
      return false
    }
  }

  private func isSafeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0")
      && value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }

  private func isSafeThemeName(_ value: String) -> Bool {
    isSafeShortcodeNamePart(value) && !value.contains(".")
  }

  private func isSafeShortcodeNamePart<S: StringProtocol>(_ value: S) -> Bool {
    !value.isEmpty
      && value.allSatisfy { character in
        character.isLetter || character.isNumber || character == "_" || character == "-"
      }
  }

  private struct Candidate {
    let definition: ThemeShortcodeDefinition
    let priority: Int
  }
}
