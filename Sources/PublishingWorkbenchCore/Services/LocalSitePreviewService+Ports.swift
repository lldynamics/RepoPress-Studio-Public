import Foundation
import PublishingDomainContracts

extension LocalSitePreviewService {
  func arguments(
    baseArguments: [String],
    siteKind: SiteKind,
    packageManager: String?,
    port: Int,
    includesPortArgument: Bool
  ) -> [String] {
    switch siteKind {
    case .zola:
      return baseArguments + ["--interface", "127.0.0.1"]
        + portArguments(port, included: includesPortArgument)
    case .hugo:
      return baseArguments + ["--bind", "127.0.0.1"]
        + portArguments(port, included: includesPortArgument)
    case .astro, .vitePress, .docusaurus:
      return baseArguments
        + forwardedPackageScriptArguments(
          ["--host", "127.0.0.1"]
            + portArguments(port, included: includesPortArgument),
          packageManager: packageManager
        )
    case .nextJS:
      return baseArguments
        + forwardedPackageScriptArguments(
          ["--hostname", "127.0.0.1"]
            + portArguments(port, included: includesPortArgument),
          packageManager: packageManager
        )
    case .hexo:
      return baseArguments
        + forwardedPackageScriptArguments(
          ["--ip", "127.0.0.1"]
            + portArguments(port, included: includesPortArgument),
          packageManager: packageManager
        )
    case .jekyll:
      return baseArguments + ["--host", "127.0.0.1"]
        + portArguments(port, included: includesPortArgument)
    case .mkDocs:
      return baseArguments + ["--dev-addr", "127.0.0.1:\(port)"]
    case .quartz:
      return baseArguments + [
        String(port), String(ProcessInfo.processInfo.processIdentifier),
      ]
    case .foam:
      return baseArguments
    }
  }

  private func portArguments(_ port: Int, included: Bool) -> [String] {
    included ? ["--port", "\(port)"] : []
  }

  private func forwardedPackageScriptArguments(
    _ arguments: [String],
    packageManager: String?
  ) -> [String] {
    packageManager == "yarn" ? arguments : ["--"] + arguments
  }

  static func defaultPort(for siteKind: SiteKind) -> Int {
    switch siteKind {
    case .zola:
      return 1111
    case .hugo:
      return 1313
    case .astro:
      return 4321
    case .vitePress:
      return 5173
    case .nextJS, .foam, .docusaurus:
      return 3000
    case .quartz:
      return 8080
    case .hexo, .jekyll:
      return 4000
    case .mkDocs:
      return 8000
    }
  }
}
