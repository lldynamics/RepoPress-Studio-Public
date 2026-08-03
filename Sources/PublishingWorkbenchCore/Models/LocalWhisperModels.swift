import Foundation

public struct LocalWhisperConfiguration: Codable, Hashable, Sendable {
  public var executablePath: String
  public var modelPath: String
  public var language: String

  public init(
    executablePath: String = "",
    modelPath: String = "",
    language: String = "auto"
  ) {
    self.executablePath = executablePath
    self.modelPath = modelPath
    self.language = language
  }

  public var isConfigured: Bool {
    !executablePath.trimmedForPublishing.isEmpty
      && !modelPath.trimmedForPublishing.isEmpty
  }

  public static let commonExecutablePaths: [String] = [
    "/opt/homebrew/bin/whisper-cli",
    "/opt/homebrew/bin/whisper-cpp",
    "/usr/local/bin/whisper-cli",
    "/usr/local/bin/whisper-cpp",
  ]

  public static var discoveredExecutablePath: String? {
    commonExecutablePaths.first(where: {
      FileManager.default.isExecutableFile(atPath: $0)
    })
  }
}

public struct LocalWhisperTranscriptionResult: Hashable, Sendable {
  public var text: String
  public var language: String
  public var executableName: String

  public init(text: String, language: String, executableName: String) {
    self.text = text
    self.language = language
    self.executableName = executableName
  }
}

