import Foundation

public enum KnowledgeNativeMessagingProtocol {
  public static let schemaVersion = 1
  public static let hostName = "com.jinfang.personal_site_publisher.knowledge"
  public static let firefoxExtensionID = "knowledge-capture@jinfang.local"
  public static let chromiumDevelopmentExtensionID = "lnibkmfhfikfbkeehcjbiaalhkiankam"
  public static let chromiumDevelopmentOrigin =
    "chrome-extension://\(chromiumDevelopmentExtensionID)/"
  public static let maximumInputBytes = 50 * 1_024 * 1_024
  public static let maximumOutputBytes = 1 * 1_024 * 1_024

  public static func unixSocketPath(userID: UInt32) -> String {
    "/private/tmp/com.jinfang.personal-site-publisher.\(userID).sock"
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
      guard Self.allowedRoutes[path]?.contains(method.uppercased()) == true else {
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

    private static let allowedRoutes: [String: Set<String>] = [
      "/v1/folders": ["GET"],
      "/v1/import": ["POST"],
      "/v1/open": ["POST"],
      "/v1/suggestions": ["POST"],
    ]
  }

  public enum ProtocolError: Error, LocalizedError, Equatable {
    case truncatedHeader
    case messageTooLarge
    case unsupportedSchemaVersion
    case disallowedRoute
    case invalidToken
    case invalidBody
    case outputTooLarge

    public var errorDescription: String? {
      switch self {
      case .truncatedHeader: "原生消息长度头不完整。"
      case .messageTooLarge: "原生消息超过 50 MB 上限。"
      case .unsupportedSchemaVersion: "原生消息协议版本不受支持。"
      case .disallowedRoute: "原生消息请求了未允许的接口。"
      case .invalidToken: "原生消息令牌格式无效。"
      case .invalidBody: "原生消息正文无效。"
      case .outputTooLarge: "原生消息响应超过 1 MB 上限。"
      }
    }
  }

  public enum BrowserFamily: Sendable {
    case firefox
    case chromium
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
      description = "Personal Site Publisher knowledge library bridge"
      path = hostPath
      type = "stdio"
      switch browserFamily {
      case .firefox:
        allowedExtensions = [KnowledgeNativeMessagingProtocol.firefoxExtensionID]
        allowedOrigins = nil
      case .chromium:
        allowedExtensions = nil
        allowedOrigins = [KnowledgeNativeMessagingProtocol.chromiumDevelopmentOrigin]
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
