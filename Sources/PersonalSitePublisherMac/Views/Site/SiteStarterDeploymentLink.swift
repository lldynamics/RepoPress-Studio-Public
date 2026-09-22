import Foundation
import PublishingDomainContracts

enum SiteStarterDeploymentLink {
  /// A first Starter push predates article release history. Its own commit
  /// page is the appropriate fallback for inspecting GitHub checks.
  static func commitURL(for result: SiteStarterPushResult) -> URL? {
    let sha = result.commitSHA.trimmingCharacters(in: .whitespacesAndNewlines)
    guard [40, 64].contains(sha.count),
      sha.unicodeScalars.allSatisfy({
        CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0)
      }),
      var components = URLComponents(string: result.remoteURL),
      components.scheme == "https", components.host != nil,
      components.user == nil, components.password == nil,
      components.query == nil, components.fragment == nil
    else { return nil }
    var path = components.path
    while path.hasSuffix("/") { path.removeLast() }
    if path.hasSuffix(".git") { path.removeLast(4) }
    guard path.split(separator: "/").count == 2 else { return nil }
    components.path = path + "/commit/" + sha
    return components.url
  }
}
