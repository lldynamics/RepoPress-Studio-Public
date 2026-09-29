import Foundation
import PublishingAICore

/// Reviewed component catalog, shipped with the signed application. An upstream
/// latest release is never implicitly approved for installation. Update this
/// catalog with the protocol tests and isolated installation acceptance.
public struct CodexRuntimeRelease: Equatable, Sendable {
  public let version: CodexAppServerRuntimeVersion
  public let archiveURL: URL
  public let sha256: String

  public static var approved: Self {
    #if arch(arm64)
      let target = "aarch64-apple-darwin"
      let digest = "97809f91cb355e55480cd7a126f9ad24bb7b162222515e30286bcac6fba94acd"
    #else
      let target = "x86_64-apple-darwin"
      let digest = "51cc89d32145c1e5dd4aa9670b88facbeb967ba1470470680ae85376f3e340a0"
    #endif
    let version = CodexAppServerRuntimeVersion(major: 0, minor: 157, patch: 0)
    let url = URL(string: "https://releases.openai.com")!
      .appendingPathComponent("codex/releases/\(version)/codex-package-\(target).tar.gz")
    return Self(version: version, archiveURL: url, sha256: digest)
  }
}
