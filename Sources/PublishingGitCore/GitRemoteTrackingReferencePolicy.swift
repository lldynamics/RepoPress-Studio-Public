import Foundation

/// Canonicalizes the upstream name reported by Git into an unambiguous
/// remote-tracking ref.  Git status normally reports `origin/main`, while
/// some porcelain/status surfaces expose `remotes/origin/main` and callers
/// may already have the complete `refs/remotes/origin/main` spelling.
///
/// This policy is intentionally internal: it is shared by the public command
/// planners in this module, while Workbench callers only need their provider
/// specific plans.
struct GitRemoteTrackingReferencePolicy: Sendable {
  init() {}

  func fullReference(for upstreamName: String) -> String? {
    guard !upstreamName.isEmpty,
          !upstreamName.hasPrefix("-"),
          !containsRefControlOrASCIIWhitespace(upstreamName),
          !upstreamName.contains(".."),
          !upstreamName.contains("@{"),
          !upstreamName.contains(where: { character in
            "~^:?*[\\".contains(character)
          }),
          upstreamName != "@" else {
      return nil
    }

    let fullRef: String
    if upstreamName.hasPrefix("refs/remotes/") {
      fullRef = upstreamName
    } else if upstreamName.hasPrefix("remotes/") {
      fullRef = "refs/\(upstreamName)"
    } else if upstreamName.hasPrefix("refs/") {
      return nil
    } else {
      fullRef = "refs/remotes/\(upstreamName)"
    }

    let prefix = "refs/remotes/"
    guard fullRef.hasPrefix(prefix),
          !containsRefControlOrASCIIWhitespace(fullRef),
          !fullRef.contains(".."),
          !fullRef.contains("@{"),
          !fullRef.contains(where: { character in
            "~^:?*[\\".contains(character)
          }) else {
      return nil
    }

    let suffix = String(fullRef.dropFirst(prefix.count))
    let components = suffix.split(separator: "/", omittingEmptySubsequences: false)
    guard components.count >= 2,
          !components.contains(where: { component in
            component.isEmpty ||
              component.hasPrefix(".") ||
              component.hasSuffix(".") ||
              component.hasSuffix(".lock")
          }) else {
      return nil
    }

    return fullRef
  }

  private func containsRefControlOrASCIIWhitespace(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
      let codePoint = scalar.value
      return codePoint <= 0x20 || codePoint == 0x7F
    }
  }
}
