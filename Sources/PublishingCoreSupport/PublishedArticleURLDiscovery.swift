import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

/// Finds bounded, same-origin article URL candidates from a sitemap.
///
/// This type deliberately does not perform title matching or slug generation. The
/// caller owns the final HTTP and page-title verification step.
public struct PublishedArticleURLDiscovery: Sendable {
  public static let maximumSitemapBytes = 1_000_000
  public static let maximumLocations = 2_000
  public static let maximumCandidates = 24

  public init() {}

  public func candidates(
    baseURL: URL,
    sitemap: Data,
    markdownPath: String,
    expectedTitle: String? = nil
  ) -> [URL] {
    guard sitemap.count <= Self.maximumSitemapBytes,
      (try? UntrustedXMLParserGuard.validate(
        data: sitemap,
        limits: UntrustedXMLParserGuard.Limits(
          maximumCharacterCount: Self.maximumSitemapBytes * 2,
          maximumElementDepth: 128
        )
      )) != nil,
      let locations = SitemapLocationParser.parse(sitemap),
      let origin = Origin(baseURL),
      let parent = parentRoute(for: markdownPath, baseURL: baseURL)
    else { return [] }

    let markers = Array(
      Set(asciiMarkers(from: markdownPath) + asciiMarkers(from: expectedTitle ?? ""))
    ).sorted()
    var unique: [URL] = []
    var seen = Set<String>()
    for location in locations {
      guard let url = URL(string: location),
        let candidateOrigin = Origin(url),
        candidateOrigin == origin,
        let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
        url.user == nil, url.password == nil, url.fragment == nil
      else { continue }
      let normalized = normalizedURLString(url)
      guard seen.insert(normalized).inserted else { continue }
      unique.append(url)
    }

    return
      unique
      .sorted { lhs, rhs in
        let left = score(lhs, parent: parent, markers: markers)
        let right = score(rhs, parent: parent, markers: markers)
        if left.0 != right.0 { return left.0 > right.0 }
        if left.1 != right.1 { return left.1 > right.1 }
        if left.2 != right.2 { return left.2 > right.2 }
        return left.3 < right.3
      }
      .prefix(Self.maximumCandidates)
      .map { $0 }
  }

  public func candidates(
    baseURL: URL,
    sitemapText: String,
    markdownPath: String,
    expectedTitle: String? = nil
  ) -> [URL] {
    candidates(
      baseURL: baseURL,
      sitemap: Data(sitemapText.utf8),
      markdownPath: markdownPath,
      expectedTitle: expectedTitle
    )
  }

  private func parentRoute(for markdownPath: String, baseURL: URL) -> String? {
    let path = markdownPath.replacingOccurrences(of: "\\", with: "/")
    guard let contentRange = path.range(of: "content/", options: [.caseInsensitive]) else {
      return nil
    }
    let relative = String(path[contentRange.upperBound...])
    guard let slash = relative.lastIndex(of: "/") else { return nil }
    let directory = String(relative[..<slash])
    let basePath = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let route = [basePath, directory].filter { !$0.isEmpty }.joined(separator: "/")
    return "/" + route + "/"
  }

  private func asciiMarkers(from markdownPath: String) -> [String] {
    let filename = markdownPath.split(separator: "/").last.map(String.init) ?? markdownPath
    let stem = filename.replacingOccurrences(
      of: #"\.[^.]+$"#, with: "", options: .regularExpression)
    return
      stem
      .split(whereSeparator: { !$0.isASCII || (!$0.isLetter && !$0.isNumber) })
      .map { $0.lowercased() }
      .filter { $0.count >= 2 }
  }

  private func score(_ url: URL, parent: String, markers: [String]) -> (Int, Int, Int, String) {
    let path = url.path.lowercased()
    let parentMatch = path.hasPrefix(parent.lowercased()) ? 1 : 0
    let markerMatch = markers.reduce(into: 0) { count, marker in
      if path.contains(marker) { count += 1 }
    }
    // Prefer the closest route and then the most informative slug. The final
    // string tie-break keeps ordering deterministic across runs.
    return (parentMatch, markerMatch, path == parent ? 0 : 1, path)
  }

  private func normalizedURLString(_ url: URL) -> String {
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.fragment = nil
    return components?.url?.absoluteString ?? url.absoluteString
  }
}

private struct Origin: Equatable {
  let scheme: String
  let host: String
  let port: Int?

  init?(_ url: URL) {
    guard let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = url.host?.lowercased(), !host.isEmpty,
      url.user == nil, url.password == nil
    else { return nil }
    self.scheme = scheme
    self.host = host
    self.port = url.port ?? (scheme == "https" ? 443 : 80)
  }
}

private final class SitemapLocationParser: NSObject, XMLParserDelegate {
  private var locations: [String] = []
  private var currentElement = ""
  private var currentValue = ""
  private var failed = false

  static func parse(_ data: Data) -> [String]? {
    let delegate = SitemapLocationParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.shouldResolveExternalEntities = false
    guard parser.parse(), !delegate.failed else { return nil }
    return delegate.locations
  }

  func parser(
    _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
  ) {
    currentElement = (qName ?? elementName).lowercased()
    if currentElement == "loc" { currentValue = "" }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    guard currentElement == "loc" else { return }
    currentValue.append(string)
    if currentValue.utf8.count > 4096 {
      failed = true
      parser.abortParsing()
    }
  }

  func parser(
    _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = (qName ?? elementName).lowercased()
    guard name == "loc" else { return }
    let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if !value.isEmpty {
      guard locations.count < PublishedArticleURLDiscovery.maximumLocations else {
        failed = true
        parser.abortParsing()
        return
      }
      locations.append(value)
    }
    currentElement = ""
  }
}
