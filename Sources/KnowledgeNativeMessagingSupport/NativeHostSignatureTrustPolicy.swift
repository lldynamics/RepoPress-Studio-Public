import Foundation

public struct NativeCodeSignatureIdentity: Sendable, Equatable {
  public var signingIdentifier: String
  public var teamIdentifier: String?

  public init(signingIdentifier: String, teamIdentifier: String?) {
    self.signingIdentifier = signingIdentifier
    self.teamIdentifier = teamIdentifier
  }
}

public enum NativeHostSignatureTrustPolicy {
  public enum TrustError: Error, LocalizedError, Equatable {
    case signingIdentifierMismatch
    case teamIdentifierMismatch
    case missingTeamIdentifier

    public var errorDescription: String? {
      switch self {
      case .signingIdentifierMismatch:
        "宿主签名标识不属于当前应用。"
      case .teamIdentifierMismatch:
        "宿主与当前应用的签名团队不一致。"
      case .missingTeamIdentifier:
        "发布版应用与宿主必须包含签名团队标识。"
      }
    }
  }

  public static func validate(
    host: NativeCodeSignatureIdentity,
    application: NativeCodeSignatureIdentity,
    expectedHostSigningIdentifier: String,
    requiresTeamIdentifier: Bool = false
  ) throws {
    guard host.signingIdentifier == expectedHostSigningIdentifier else {
      throw TrustError.signingIdentifierMismatch
    }
    guard host.teamIdentifier == application.teamIdentifier else {
      throw TrustError.teamIdentifierMismatch
    }
    if requiresTeamIdentifier,
       host.teamIdentifier?.isEmpty != false || application.teamIdentifier?.isEmpty != false {
      throw TrustError.missingTeamIdentifier
    }
  }
}
