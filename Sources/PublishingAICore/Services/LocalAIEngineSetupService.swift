import Foundation

public enum LocalAIEngineSetupRecommendation: Hashable, Sendable {
  case launchApplication(bundleIdentifier: String)
  case openOfficialDownloadPage(URL)
  case unavailable
}

/// Supplies fixed, local-engine setup targets. The macOS app owns the small
/// AppKit bridge that opens these targets so this service remains testable and
/// never starts a process itself.
public struct LocalAIEngineSetupService: Sendable {
  public init() {}

  public func recommendation(
    for kind: LocalAIEngineKind,
    applicationIsInstalled: Bool
  ) -> LocalAIEngineSetupRecommendation {
    guard let target = Self.applicationTarget(for: kind) else { return .unavailable }
    if applicationIsInstalled {
      return .launchApplication(bundleIdentifier: target.bundleIdentifier)
    }
    return .openOfficialDownloadPage(target.downloadURL)
  }

  public static func applicationTarget(
    for kind: LocalAIEngineKind
  ) -> LocalAIEngineApplicationTarget? {
    switch kind {
    case .ollama:
      return LocalAIEngineApplicationTarget(
        bundleIdentifier: "com.electron.ollama",
        downloadURL: URL(string: "https://ollama.com/download/mac")!
      )
    case .lmStudio:
      return LocalAIEngineApplicationTarget(
        bundleIdentifier: "ai.elementlabs.lmstudio",
        downloadURL: URL(string: "https://lmstudio.ai/download")!
      )
    case .vLLM, .mlx:
      return nil
    }
  }
}

public struct LocalAIEngineApplicationTarget: Hashable, Sendable {
  public let bundleIdentifier: String
  public let downloadURL: URL

  public init(bundleIdentifier: String, downloadURL: URL) {
    self.bundleIdentifier = bundleIdentifier
    self.downloadURL = downloadURL
  }
}
