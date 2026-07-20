import Foundation

public struct NativeMessagingInstallationReceipt: Codable, Sendable, Equatable {
  public static let currentSchemaVersion = 1

  public var receiptSchemaVersion: Int
  public var manifestPath: String
  public var hostPath: String
  public var hostSHA256: String
  public var hostProtocolVersion: Int
  public var applicationBundlePath: String
  public var applicationVersion: String
  public var applicationBuild: String
  public var hostSigningIdentifier: String
  public var teamIdentifier: String?
  public var installedAt: Date

  public init(
    manifestPath: String,
    hostPath: String,
    hostSHA256: String,
    hostProtocolVersion: Int,
    applicationBundlePath: String,
    applicationVersion: String,
    applicationBuild: String,
    hostSigningIdentifier: String,
    teamIdentifier: String?,
    installedAt: Date = Date()
  ) {
    receiptSchemaVersion = Self.currentSchemaVersion
    self.manifestPath = manifestPath
    self.hostPath = hostPath
    self.hostSHA256 = hostSHA256
    self.hostProtocolVersion = hostProtocolVersion
    self.applicationBundlePath = applicationBundlePath
    self.applicationVersion = applicationVersion
    self.applicationBuild = applicationBuild
    self.hostSigningIdentifier = hostSigningIdentifier
    self.teamIdentifier = teamIdentifier
    self.installedAt = installedAt
  }

  public func matches(
    manifestPath: String,
    hostPath: String,
    hostSHA256: String,
    hostProtocolVersion: Int,
    applicationBundlePath: String,
    applicationVersion: String,
    applicationBuild: String,
    hostSigningIdentifier: String,
    teamIdentifier: String?
  ) -> Bool {
    receiptSchemaVersion == Self.currentSchemaVersion
      && self.manifestPath == manifestPath
      && self.hostPath == hostPath
      && self.hostSHA256 == hostSHA256
      && self.hostProtocolVersion == hostProtocolVersion
      && self.applicationBundlePath == applicationBundlePath
      && self.applicationVersion == applicationVersion
      && self.applicationBuild == applicationBuild
      && self.hostSigningIdentifier == hostSigningIdentifier
      && self.teamIdentifier == teamIdentifier
  }

  public func encodedData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }

  public static func decode(_ data: Data) throws -> Self {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(Self.self, from: data)
  }
}
