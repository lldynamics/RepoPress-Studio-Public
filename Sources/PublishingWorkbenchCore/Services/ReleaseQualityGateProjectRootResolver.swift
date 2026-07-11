import Foundation

struct ReleaseQualityGateProjectRootResolver {
  static let environmentKey = "PERSONAL_SITE_PUBLISHER_PROJECT_ROOT"

  private let fileManager: FileManager
  private let environment: [String: String]

  init(
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.fileManager = fileManager
    self.environment = environment
  }

  func resolve(
    explicitRoot: URL?,
    bundleURL: URL = Bundle.main.bundleURL,
    currentDirectoryURL: URL = URL(
      fileURLWithPath: FileManager.default.currentDirectoryPath,
      isDirectory: true
    )
  ) -> URL? {
    if let explicitRoot {
      return explicitRoot.standardizedFileURL
    }

    if let environmentPath = environment[Self.environmentKey]?.nilIfEmpty {
      let environmentRoot = URL(fileURLWithPath: environmentPath, isDirectory: true)
        .standardizedFileURL
      if isProjectRoot(environmentRoot) {
        return environmentRoot
      }
    }

    for candidate in [bundleURL, currentDirectoryURL] {
      if let root = nearestProjectRoot(startingAt: candidate) {
        return root
      }
    }
    return nil
  }

  private func nearestProjectRoot(startingAt url: URL) -> URL? {
    var candidatePath = url.standardizedFileURL.path
    var candidate = URL(fileURLWithPath: candidatePath, isDirectory: true)
    if !directoryExists(candidate) {
      candidatePath = (candidatePath as NSString).deletingLastPathComponent
    }

    while true {
      candidate = URL(fileURLWithPath: candidatePath, isDirectory: true)
      if isProjectRoot(candidate) {
        return candidate
      }
      let parentPath = (candidatePath as NSString).deletingLastPathComponent
      guard !parentPath.isEmpty, parentPath != candidatePath else {
        return nil
      }
      candidatePath = parentPath
    }
  }

  private func isProjectRoot(_ url: URL) -> Bool {
    fileManager.fileExists(atPath: url.appendingPathComponent("Package.swift").path)
      && directoryExists(url.appendingPathComponent("Sources", isDirectory: true))
      && fileManager.fileExists(
        atPath: url.appendingPathComponent("script/release_checks.json").path
      )
  }

  private func directoryExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
