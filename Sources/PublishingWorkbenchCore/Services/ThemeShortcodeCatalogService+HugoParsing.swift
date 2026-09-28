import Foundation

extension ThemeShortcodeCatalogService {
  func hugoShortcodeName(
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

  func hugoParameters(in contents: String) -> [ThemeShortcodeParameter] {
    let getNames = captures(#"\.Get\s+\"([A-Za-z][A-Za-z0-9_-]*)\""#, in: contents)
    let paramsNames = captures(#"\.Params\.([A-Za-z][A-Za-z0-9_-]*)"#, in: contents)
    let indexNames = captures(#"index\s+\.Params\s+\"([A-Za-z][A-Za-z0-9_-]*)\""#, in: contents)
    return uniqueParameters(getNames + paramsNames + indexNames)
  }

  func hugoSnippet(name: String, parameters: [ThemeShortcodeParameter], inner: Bool) -> String {
    let hints = parameters.map { "\($0.name)=\"\($0.defaultValue ?? "value")\"" }.joined(
      separator: " ")
    let opening = "{{< \(name)\(hints.isEmpty ? "" : " " + hints) >}}"
    return inner ? opening + "\n\n{{< /\(name) >}}" : opening
  }
}
