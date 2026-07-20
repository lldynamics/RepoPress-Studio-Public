import Foundation

public struct NativeHostApplicationMetadata: Equatable, Sendable {
  public var version: String
  public var build: String

  public init(version: String, build: String) {
    self.version = version
    self.build = build
  }

  public static func resolve(
    forExecutable executableURL: URL,
    fileManager: FileManager = .default
  ) -> Self {
    for infoURL in candidateInfoURLs(forExecutable: executableURL) {
      guard fileManager.isReadableFile(atPath: infoURL.path),
            let data = try? Data(contentsOf: infoURL),
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let info = object as? [String: Any],
            let version = info["CFBundleShortVersionString"] as? String,
            !version.isEmpty,
            let build = info["CFBundleVersion"] as? String,
            !build.isEmpty else {
        continue
      }
      return .init(version: version, build: build)
    }
    return .init(version: "development", build: "0")
  }

  private static func candidateInfoURLs(forExecutable executableURL: URL) -> [URL] {
    let executableDirectory = executableURL.standardizedFileURL.deletingLastPathComponent()
    var candidates: [URL] = []
    if executableDirectory.lastPathComponent == "MacOS" {
      let contentsDirectory = executableDirectory.deletingLastPathComponent()
      if contentsDirectory.lastPathComponent == "Contents" {
        candidates.append(contentsDirectory.appendingPathComponent("Info.plist"))
      }
    }
    candidates.append(executableDirectory.appendingPathComponent("Info.plist"))
    return candidates
  }
}
