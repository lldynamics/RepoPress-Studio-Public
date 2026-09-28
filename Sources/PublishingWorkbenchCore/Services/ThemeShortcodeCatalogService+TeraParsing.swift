import Foundation

extension ThemeShortcodeCatalogService {
  func definition(
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

  func shortcodeName(repositoryPath: String, relativeDirectory: String) -> String? {
    let prefix = relativeDirectory + "/"
    guard repositoryPath.hasPrefix(prefix) else { return nil }
    let relative = String(repositoryPath.dropFirst(prefix.count))
    let suffixless = (relative as NSString).deletingPathExtension
    let components = suffixless.split(separator: "/").map(String.init)
    guard !components.isEmpty, components.allSatisfy(isSafeShortcodeNamePart) else { return nil }
    return components.joined(separator: "/")
  }

  func teraMacros(in contents: String) -> [(
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

  func teraComponents(in contents: String) -> [(
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
      return (String(contents[nameRange]), parameters, containsTeraBody(in: String(componentBody)))
    }
  }

  func teraComponentParameters(in arguments: String) -> [ThemeShortcodeParameter] {
    var parameters: [ThemeShortcodeParameter] = []
    for token in splitTeraArguments(arguments) {
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

  func splitTeraArguments(_ arguments: String) -> [String] {
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

  func teraContextParameters(in contents: String) -> [ThemeShortcodeParameter] {
    let names = captures(#"\{\{\s*([A-Za-z][A-Za-z0-9_-]*)"#, in: contents)
    let excluded: Set<String> = [
      "config", "page", "section", "current_path", "get_url", "get_taxonomy_url", "trans", "body",
    ]
    return uniqueParameters(names.filter { !excluded.contains($0) })
  }

  func containsTeraBody(in contents: String) -> Bool {
    captures(#"\{\{\s*(body)\b"#, in: contents).isEmpty == false
      || contents.range(of: "{% end %}") != nil
  }

  func legacyTeraSnippet(name: String, parameters: [ThemeShortcodeParameter], inner: Bool) -> String
  {
    let hints = parameters.map { "\($0.name)=\($0.defaultValue ?? "\"value\"")" }.joined(
      separator: ", ")
    if inner {
      return "{% \(name)(\(hints)) %}\n\n{% end %}"
    }
    return "{{ \(name)(\(hints)) }}"
  }

  func teraComponentSnippet(
    name: String, parameters: [ThemeShortcodeParameter], inner: Bool
  ) -> String {
    let hints = parameters.map { "\($0.name)=\($0.defaultValue ?? "\"value\"")" }.joined(
      separator: " ")
    if inner {
      return "{% <\(name)\(hints.isEmpty ? "" : " " + hints)> %}\n\n{% </\(name)> %}"
    }
    return "{{<\(name)\(hints.isEmpty ? "" : " " + hints) />}}"
  }
}
