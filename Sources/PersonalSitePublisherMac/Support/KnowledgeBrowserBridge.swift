import Combine
import Foundation
import Network
import PublishingWorkbenchCore
import Security

enum KnowledgeBrowserBridgeState: Equatable {
  case stopped
  case starting
  case ready
  case failed(String)

  var localizedDisplayName: String {
    switch self {
    case .stopped: String(localized: "未启动")
    case .starting: String(localized: "正在启动")
    case .ready: String(localized: "可以连接")
    case .failed: String(localized: "连接失败")
    }
  }
}

@MainActor
final class KnowledgeBrowserBridge: ObservableObject {
  nonisolated static let port: UInt16 = 47_831

  @Published private(set) var state: KnowledgeBrowserBridgeState = .stopped
  @Published private(set) var connectionToken: String
  @Published private(set) var lastMessage: String?

  private let knowledge: KnowledgeStore
  private let defaults: UserDefaults
  private let queue = DispatchQueue(label: "com.jinfang.PersonalSitePublisherMac.browser-bridge")
  private var listener: NWListener?

  init(knowledge: KnowledgeStore, defaults: UserDefaults = .standard) {
    self.knowledge = knowledge
    self.defaults = defaults
    if let stored = defaults.string(forKey: Self.tokenDefaultsKey), stored.count >= 32 {
      connectionToken = stored
    } else {
      let token = Self.makeConnectionToken()
      connectionToken = token
      defaults.set(token, forKey: Self.tokenDefaultsKey)
    }
  }

  deinit {
    listener?.cancel()
  }

  func start() {
    guard listener == nil else { return }
    state = .starting
    do {
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .hostPort(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: Self.port)!
      )
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        self?.receiveRequest(on: connection)
      }
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self else { return }
          switch state {
          case .ready:
            self.state = .ready
            self.lastMessage = "浏览器桥接仅监听本机 127.0.0.1。"
          case .failed(let error):
            self.state = .failed(error.localizedDescription)
            self.lastMessage = "浏览器桥接启动失败：\(error.localizedDescription)"
            self.listener?.cancel()
            self.listener = nil
          case .cancelled:
            self.state = .stopped
            self.listener = nil
          default:
            break
          }
        }
      }
      self.listener = listener
      listener.start(queue: queue)
    } catch {
      state = .failed(error.localizedDescription)
      lastMessage = "浏览器桥接启动失败：\(error.localizedDescription)"
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
    state = .stopped
  }

  func rotateConnectionToken() {
    let token = Self.makeConnectionToken()
    connectionToken = token
    defaults.set(token, forKey: Self.tokenDefaultsKey)
    lastMessage = "连接令牌已更新，浏览器插件需要重新连接。"
  }

  nonisolated private func receiveRequest(on connection: NWConnection) {
    connection.start(queue: queue)
    receiveChunk(on: connection, accumulated: Data())
  }

  nonisolated private func receiveChunk(
    on connection: NWConnection,
    accumulated: Data
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      if error != nil {
        connection.cancel()
        return
      }
      var buffer = accumulated
      if let data { buffer.append(data) }
      guard buffer.count <= BrowserBridgeHTTPRequest.maximumRequestBytes else {
        self.sendResponse(.error(status: 413, message: "页面数据超过 48 MB。"), on: connection)
        return
      }

      switch BrowserBridgeHTTPRequest.completionState(for: buffer) {
      case .complete(let requestLength):
        let requestData = Data(buffer.prefix(requestLength))
        guard let request = BrowserBridgeHTTPRequest(data: requestData) else {
          self.sendResponse(.error(status: 400, message: "请求格式无效。"), on: connection)
          return
        }
        Task { @MainActor [weak self] in
          await self?.handle(request, connection: connection)
        }
      case .incomplete:
        guard !isComplete else {
          self.sendResponse(.error(status: 400, message: "请求内容不完整。"), on: connection)
          return
        }
        self.receiveChunk(on: connection, accumulated: buffer)
      case .invalid:
        self.sendResponse(.error(status: 400, message: "请求头无效。"), on: connection)
      }
    }
  }

  private func handle(
    _ request: BrowserBridgeHTTPRequest,
    connection: NWConnection
  ) async {
    guard request.hasSafeLoopbackHost else {
      sendResponse(.error(status: 403, message: "只接受本机连接。"), on: connection)
      return
    }
    if request.method == "OPTIONS" {
      sendResponse(.empty(status: 204), on: connection)
      return
    }
    if request.method == "GET", request.path == "/v1/status" {
      sendResponse(.json(status: 200, value: BrowserStatusResponse(
        ready: state == .ready,
        protocolVersion: 1,
        application: "PersonalSitePublisherMac"
      )), on: connection)
      return
    }
    guard request.headers["authorization"] == "Bearer \(connectionToken)" else {
      sendResponse(.error(status: 401, message: "连接令牌无效。"), on: connection)
      return
    }

    if request.method == "GET", request.path == "/v1/folders" {
      sendResponse(.json(status: 200, value: BrowserFoldersResponse(
        folders: knowledge.folders.map { BrowserFolderResponse(id: $0.id, name: $0.name) }
      )), on: connection)
      return
    }

    if request.method == "POST", request.path == "/v1/import" {
      guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
        sendResponse(.error(status: 415, message: "只接受 JSON 页面数据。"), on: connection)
        return
      }
      do {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(BrowserImportEnvelope.self, from: request.body)
        let result = try await knowledge.importBrowserCapture(
          envelope.capture,
          folderID: envelope.folderID,
          newFolderName: envelope.newFolderName
        )
        lastMessage = "已从浏览器保存“\(envelope.capture.title)”。"
        sendResponse(.json(status: 200, value: BrowserImportResponse(
          insertedCount: result.insertedCount,
          updatedCount: result.updatedCount,
          skippedCount: result.skippedCount
        )), on: connection)
      } catch {
        lastMessage = error.localizedDescription
        sendResponse(.error(status: 422, message: error.localizedDescription), on: connection)
      }
      return
    }

    sendResponse(.error(status: 404, message: "接口不存在。"), on: connection)
  }

  nonisolated private func sendResponse(
    _ response: BrowserBridgeHTTPResponse,
    on connection: NWConnection
  ) {
    let data = response.encodedData()
    connection.send(content: data, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private static let tokenDefaultsKey = "KnowledgeBrowserBridge.connectionToken.v1"

  private static func makeConnectionToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
      return bytes.map { String(format: "%02x", $0) }.joined()
    }
    return UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }
}

private struct BrowserImportEnvelope: Decodable {
  var capture: KnowledgeBrowserCapture
  var folderID: UUID?
  var newFolderName: String?
}

private struct BrowserStatusResponse: Encodable {
  var ready: Bool
  var protocolVersion: Int
  var application: String
}

private struct BrowserFolderResponse: Encodable {
  var id: UUID
  var name: String
}

private struct BrowserFoldersResponse: Encodable {
  var folders: [BrowserFolderResponse]
}

private struct BrowserImportResponse: Encodable {
  var insertedCount: Int
  var updatedCount: Int
  var skippedCount: Int
}

private enum BrowserBridgeRequestCompletionState {
  case incomplete
  case complete(Int)
  case invalid
}

private struct BrowserBridgeHTTPRequest {
  static let maximumRequestBytes = 48 * 1_024 * 1_024
  static let maximumHeaderBytes = 32 * 1_024
  private static let headerSeparator = Data("\r\n\r\n".utf8)

  var method: String
  var path: String
  var headers: [String: String]
  var body: Data

  init?(data: Data) {
    guard let separatorRange = data.range(of: Self.headerSeparator),
          separatorRange.lowerBound <= Self.maximumHeaderBytes,
          let headerText = String(data: data[..<separatorRange.lowerBound], encoding: .utf8) else {
      return nil
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3,
          requestParts[2].hasPrefix("HTTP/1.") else { return nil }
    method = String(requestParts[0]).uppercased()
    path = String(requestParts[1]).components(separatedBy: "?").first ?? "/"
    var parsedHeaders: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { return nil }
      let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return nil }
      parsedHeaders[name] = value
    }
    headers = parsedHeaders
    body = Data(data[separatorRange.upperBound...])
  }

  var hasSafeLoopbackHost: Bool {
    guard let host = headers["host"]?.lowercased() else { return false }
    return host == "127.0.0.1:\(KnowledgeBrowserBridge.port)"
      || host == "localhost:\(KnowledgeBrowserBridge.port)"
  }

  static func completionState(for data: Data) -> BrowserBridgeRequestCompletionState {
    guard let separatorRange = data.range(of: headerSeparator) else {
      return data.count > maximumHeaderBytes ? .invalid : .incomplete
    }
    guard separatorRange.lowerBound <= maximumHeaderBytes,
          let headerText = String(data: data[..<separatorRange.lowerBound], encoding: .utf8) else {
      return .invalid
    }
    let contentLengthLine = headerText.components(separatedBy: "\r\n").first {
      $0.lowercased().hasPrefix("content-length:")
    }
    let contentLength: Int
    if let contentLengthLine,
       let separator = contentLengthLine.firstIndex(of: ":"),
       let value = Int(contentLengthLine[contentLengthLine.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)),
       value >= 0 {
      contentLength = value
    } else {
      contentLength = 0
    }
    let requestLength = separatorRange.upperBound + contentLength
    guard requestLength <= maximumRequestBytes else { return .invalid }
    return data.count >= requestLength ? .complete(requestLength) : .incomplete
  }
}

private struct BrowserBridgeHTTPResponse {
  var status: Int
  var contentType: String
  var body: Data

  static func empty(status: Int) -> Self {
    Self(status: status, contentType: "application/json; charset=utf-8", body: Data())
  }

  static func json<Value: Encodable>(status: Int, value: Value) -> Self {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    return Self(status: status, contentType: "application/json; charset=utf-8", body: data)
  }

  static func error(status: Int, message: String) -> Self {
    json(status: status, value: ["error": message])
  }

  func encodedData() -> Data {
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 204: reason = "No Content"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 403: reason = "Forbidden"
    case 404: reason = "Not Found"
    case 413: reason = "Payload Too Large"
    case 415: reason = "Unsupported Media Type"
    case 422: reason = "Unprocessable Content"
    default: reason = "Error"
    }
    let header = """
    HTTP/1.1 \(status) \(reason)\r
    Content-Type: \(contentType)\r
    Content-Length: \(body.count)\r
    Access-Control-Allow-Origin: *\r
    Access-Control-Allow-Headers: Authorization, Content-Type\r
    Access-Control-Allow-Methods: GET, POST, OPTIONS\r
    Cache-Control: no-store\r
    Connection: close\r
    \r

    """
    var output = Data(header.utf8)
    output.append(body)
    return output
  }
}
