import Foundation

public enum KnowledgeNativeMessagingProtocol {
  public static func unixSocketPath(userID: UInt32) -> String {
    let path = "/private/tmp/com.jinfang.personal-site-publisher.\(userID).sock"
    precondition(path.utf8.count < 104, "Unix socket path length exceeds 104 bytes limit")
    return path
  }

  public struct Request: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var path: String
    public var method: String
    public var token: String
    public var bodyJSON: String?

    public init(
      schemaVersion: Int = KnowledgeNativeMessagingProtocol.schemaVersion,
      path: String,
      method: String,
      token: String,
      bodyJSON: String? = nil
    ) {
      self.schemaVersion = schemaVersion
      self.path = path
      self.method = method
      self.token = token
      self.bodyJSON = bodyJSON
    }

    public func validate() throws {
      guard schemaVersion == KnowledgeNativeMessagingProtocol.schemaVersion else {
        throw ProtocolError.unsupportedSchemaVersion
      }
      guard !path.contains("\r") && !path.contains("\n") else {
        throw ProtocolError.disallowedRoute
      }
      if path == KnowledgeNativeMessagingProtocol.handshakePath {
        guard method.uppercased() == "GET", token.isEmpty, bodyJSON == nil else {
          throw ProtocolError.invalidHandshake
        }
        return
      }
      guard KnowledgeNativeMessagingProtocol.allowedRoutes[path]?.contains(method.uppercased())
        == true else {
        throw ProtocolError.disallowedRoute
      }
      guard token.count >= 32, token.count <= 256,
            token.unicodeScalars.allSatisfy({ $0.isASCII && !$0.properties.isWhitespace }) else {
        throw ProtocolError.invalidToken
      }
      if method.uppercased() == "POST" {
        guard let bodyJSON, !bodyJSON.isEmpty,
              bodyJSON.utf8.count <= KnowledgeNativeMessagingProtocol.maximumInputBytes,
              (try? JSONSerialization.jsonObject(with: Data(bodyJSON.utf8))) != nil else {
          throw ProtocolError.invalidBody
        }
      } else if bodyJSON != nil {
        throw ProtocolError.invalidBody
      }
    }

    public static func handshake(
      schemaVersion: Int = KnowledgeNativeMessagingProtocol.schemaVersion
    ) -> Self {
      .init(
        schemaVersion: schemaVersion,
        path: KnowledgeNativeMessagingProtocol.handshakePath,
        method: "GET",
        token: ""
      )
    }

    public var isHandshake: Bool {
      path == KnowledgeNativeMessagingProtocol.handshakePath
    }
  }

  public struct HandshakePayload: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var minimumClientProtocolVersion: Int
    public var maximumClientProtocolVersion: Int
    public var applicationVersion: String
    public var applicationBuild: String

    public init(
      protocolVersion: Int = KnowledgeNativeMessagingProtocol.schemaVersion,
      minimumClientProtocolVersion: Int = KnowledgeNativeMessagingProtocol.schemaVersion,
      maximumClientProtocolVersion: Int = KnowledgeNativeMessagingProtocol.schemaVersion,
      applicationVersion: String,
      applicationBuild: String
    ) {
      self.protocolVersion = protocolVersion
      self.minimumClientProtocolVersion = minimumClientProtocolVersion
      self.maximumClientProtocolVersion = maximumClientProtocolVersion
      self.applicationVersion = applicationVersion
      self.applicationBuild = applicationBuild
    }

    public func validate(clientProtocolVersion: Int) throws {
      guard protocolVersion == KnowledgeNativeMessagingProtocol.schemaVersion,
            minimumClientProtocolVersion <= maximumClientProtocolVersion,
            minimumClientProtocolVersion...maximumClientProtocolVersion ~= clientProtocolVersion else {
        throw ProtocolError.unsupportedSchemaVersion
      }
    }
  }

  public struct HandshakeResponse: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var ok: Bool
    public var status: Int
    public var payload: HandshakePayload
    public var transport: String

    public init(payload: HandshakePayload) {
      schemaVersion = KnowledgeNativeMessagingProtocol.schemaVersion
      ok = true
      status = 200
      self.payload = payload
      transport = "native"
    }

    public func validate(clientProtocolVersion: Int) throws {
      guard schemaVersion == KnowledgeNativeMessagingProtocol.schemaVersion,
            ok,
            status == 200,
            transport == "native" else {
        throw ProtocolError.invalidHandshake
      }
      try payload.validate(clientProtocolVersion: clientProtocolVersion)
    }
  }

  public enum ProtocolError: Error, LocalizedError, Equatable {
    case truncatedHeader
    case messageTooLarge
    case unsupportedSchemaVersion
    case disallowedRoute
    case invalidToken
    case invalidBody
    case invalidHandshake
    case outputTooLarge

    public var errorDescription: String? {
      switch self {
      case .truncatedHeader: "原生消息长度头不完整。"
      case .messageTooLarge: "原生消息超过 50 MB 上限。"
      case .unsupportedSchemaVersion: "原生消息协议版本不受支持。"
      case .disallowedRoute: "原生消息请求了未允许的接口。"
      case .invalidToken: "原生消息令牌格式无效。"
      case .invalidBody: "原生消息正文无效。"
      case .invalidHandshake: "原生消息版本握手无效。"
      case .outputTooLarge: "原生消息响应超过 1 MB 上限。"
      }
    }
  }

  public static let handshakePath = "/native/handshake"

  public enum BrowserFamily: Sendable {
    case firefox
    case chrome
    case edge
  }

  public struct HostManifest: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var path: String
    public var type: String
    public var allowedExtensions: [String]?
    public var allowedOrigins: [String]?

    enum CodingKeys: String, CodingKey {
      case name
      case description
      case path
      case type
      case allowedExtensions = "allowed_extensions"
      case allowedOrigins = "allowed_origins"
    }

    public init(browserFamily: BrowserFamily, hostPath: String) {
      name = KnowledgeNativeMessagingProtocol.hostName
      description = "RepoPress knowledge library bridge"
      path = hostPath
      type = "stdio"
      switch browserFamily {
      case .firefox:
        allowedExtensions = [KnowledgeNativeMessagingProtocol.firefoxExtensionID]
        allowedOrigins = nil
      case .chrome:
        allowedExtensions = nil
        allowedOrigins = KnowledgeNativeMessagingProtocol.chromeAllowedOrigins
      case .edge:
        allowedExtensions = nil
        allowedOrigins = KnowledgeNativeMessagingProtocol.edgeAllowedOrigins
      }
    }

    public func encodedData() throws -> Data {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      return try encoder.encode(self)
    }
  }

  public static func decodeLength(_ header: Data) throws -> Int {
    guard header.count == 4 else { throw ProtocolError.truncatedHeader }
    let value = header.withUnsafeBytes { bytes in
      UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self))
    }
    guard value > 0, value <= maximumInputBytes else {
      throw ProtocolError.messageTooLarge
    }
    return Int(value)
  }

  public static func frame(_ payload: Data) throws -> Data {
    guard payload.count <= maximumOutputBytes else {
      throw ProtocolError.outputTooLarge
    }
    var length = UInt32(payload.count).littleEndian
    var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
    result.append(payload)
    return result
  }
}
