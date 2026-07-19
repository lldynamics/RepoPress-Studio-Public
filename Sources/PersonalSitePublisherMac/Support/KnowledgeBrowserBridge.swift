import Combine
import Darwin
import Foundation
import KnowledgeNativeMessagingSupport
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
  nonisolated static var socketPath: String {
    KnowledgeNativeMessagingProtocol.unixSocketPath(userID: getuid())
  }

  @Published private(set) var state: KnowledgeBrowserBridgeState = .stopped
  @Published private(set) var connectionToken: String
  @Published private(set) var connectionTokenExpiresAt: Date
  @Published private(set) var lastMessage: String?
  @Published private(set) var lastOpenedDocumentID: UUID?

  private let knowledge: KnowledgeStore
  private let defaults: UserDefaults
  private let onOpenDocument: (UUID) -> Void
  private let now: () -> Date
  private var invalidatedExpiredToken: String?
  private let queue = DispatchQueue(label: "com.jinfang.PersonalSitePublisherMac.browser-bridge")
  private var listener: NWListener?

  init(
    knowledge: KnowledgeStore,
    defaults: UserDefaults = .standard,
    now: @escaping () -> Date = Date.init,
    onOpenDocument: @escaping (UUID) -> Void = { _ in }
  ) {
    self.knowledge = knowledge
    self.defaults = defaults
    self.now = now
    self.onOpenDocument = onOpenDocument
    let currentDate = now()
    let storedToken = defaults.string(forKey: Self.tokenDefaultsKey)
    let storedExpiry = defaults.object(forKey: Self.tokenExpiryDefaultsKey) as? Date
    invalidatedExpiredToken = if let storedToken, let storedExpiry, storedExpiry <= currentDate {
      storedToken
    } else {
      nil
    }
    let lease = KnowledgeBrowserConnectionTokenLease(
      storedToken: storedToken,
      storedExpiresAt: storedExpiry,
      now: currentDate,
      generateToken: Self.makeConnectionToken
    )
    connectionToken = lease.token
    connectionTokenExpiresAt = lease.expiresAt
    defaults.set(connectionToken, forKey: Self.tokenDefaultsKey)
    defaults.set(connectionTokenExpiresAt, forKey: Self.tokenExpiryDefaultsKey)
  }

  deinit {
    listener?.cancel()
    try? FileManager.default.removeItem(atPath: Self.socketPath)
  }

  func start() {
    guard listener == nil else { return }
    state = .starting
    do {
      try prepareUnixSocketPath()
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      parameters.requiredLocalEndpoint = .unix(path: Self.socketPath)
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        self?.receiveRequest(on: connection)
      }
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self else { return }
          switch state {
          case .ready:
            guard chmod(Self.socketPath, S_IRUSR | S_IWUSR) == 0 else {
              self.state = .failed(String(localized: "无法限制本地套接字权限。"))
              self.lastMessage = String(localized: "原生连接套接字权限设置失败。")
              self.listener?.cancel()
              self.listener = nil
              try? FileManager.default.removeItem(atPath: Self.socketPath)
              return
            }
            self.state = .ready
            self.lastMessage = String(localized: "原生连接使用当前用户专属 Unix Domain Socket。")
          case .failed(let error):
            self.state = .failed(error.localizedDescription)
            self.lastMessage = "浏览器桥接启动失败：\(error.localizedDescription)"
            self.listener?.cancel()
            self.listener = nil
            try? FileManager.default.removeItem(atPath: Self.socketPath)
          case .cancelled:
            self.state = .stopped
            self.listener = nil
            try? FileManager.default.removeItem(atPath: Self.socketPath)
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
    try? FileManager.default.removeItem(atPath: Self.socketPath)
    state = .stopped
  }

  func rotateConnectionToken() {
    let token = Self.makeConnectionToken()
    connectionToken = token
    connectionTokenExpiresAt = now().addingTimeInterval(
      KnowledgeBrowserConnectionTokenLease.defaultLifetime
    )
    defaults.set(token, forKey: Self.tokenDefaultsKey)
    defaults.set(connectionTokenExpiresAt, forKey: Self.tokenExpiryDefaultsKey)
    lastMessage = "连接令牌已更新，浏览器插件需要重新连接。"
  }

  @discardableResult
  func refreshExpiredConnectionToken() -> Bool {
    guard now() >= connectionTokenExpiresAt else { return false }
    rotateConnectionToken()
    lastMessage = "旧连接令牌已过期并失效，请用新令牌重新配对浏览器插件。"
    return true
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
    guard request.isNativeMessagingForward else {
      sendResponse(.error(status: 403, message: "只接受已安装原生宿主。", code: "invalid-transport"), on: connection)
      return
    }
    if request.method == "GET", request.path == "/v1/status" {
      sendResponse(.json(status: 200, value: BrowserStatusResponse(
        ready: state == .ready,
        protocolVersion: 5,
        application: "PersonalSitePublisherMac"
      )), on: connection)
      return
    }
    if let invalidatedExpiredToken,
       request.bearerToken == invalidatedExpiredToken {
      self.invalidatedExpiredToken = nil
      sendResponse(.error(
        status: 401,
        message: "连接令牌已过期，请从应用复制新令牌重新配对。",
        code: "token-expired"
      ), on: connection)
      return
    }
    if refreshExpiredConnectionToken() {
      sendResponse(.error(
        status: 401,
        message: "连接令牌已过期，请从应用复制新令牌重新配对。",
        code: "token-expired"
      ), on: connection)
      return
    }
    guard request.headers["authorization"] == "Bearer \(connectionToken)" else {
      sendResponse(.error(status: 401, message: "连接令牌无效，请重新配对。", code: "invalid-token"), on: connection)
      return
    }

    if request.method == "GET", request.path == "/v1/folders" {
      sendResponse(.json(status: 200, value: BrowserFoldersResponse(
        folders: knowledge.folders.map { BrowserFolderResponse(id: $0.id, name: $0.name) },
        tokenExpiresAt: ISO8601DateFormatter().string(from: connectionTokenExpiresAt)
      )), on: connection)
      return
    }

    if request.method == "POST", request.path == "/v1/suggestions" {
      guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
        sendResponse(.error(status: 415, message: "只接受 JSON 分类建议请求。"), on: connection)
        return
      }
      guard let envelope = try? JSONDecoder().decode(
        BrowserOrganizationSuggestionEnvelope.self,
        from: request.body
      ) else {
        sendResponse(.error(status: 400, message: "分类建议请求无效。"), on: connection)
        return
      }
      let suggestions = KnowledgeSmartCollectionService().browserOrganizationSuggestions(
        sourceURL: envelope.sourceURL,
        authors: envelope.authors,
        tags: envelope.tags,
        documents: knowledge.documents,
        folders: knowledge.folders
      )
      sendResponse(.json(status: 200, value: BrowserOrganizationSuggestionsResponse(
        folders: suggestions.folders.map {
          BrowserFolderSuggestionResponse(
            folder: BrowserFolderResponse(id: $0.folder.id, name: $0.folder.name),
            score: $0.score,
            reasons: $0.reasons.map(\.rawValue)
          )
        },
        tags: suggestions.tags
      )), on: connection)
      return
    }

    if request.method == "POST", request.path == "/v1/open" {
      guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
        sendResponse(.error(status: 415, message: "只接受 JSON 资料定位请求。"), on: connection)
        return
      }
      guard let envelope = try? JSONDecoder().decode(BrowserOpenEnvelope.self, from: request.body) else {
        sendResponse(.error(status: 400, message: "资料定位请求无效。"), on: connection)
        return
      }
      guard knowledge.revealDocument(envelope.documentID) else {
        sendResponse(.error(status: 404, message: "资料库中找不到该资料。"), on: connection)
        return
      }
      lastOpenedDocumentID = envelope.documentID
      onOpenDocument(envelope.documentID)
      lastMessage = "已打开浏览器刚保存的资料。"
      sendResponse(.json(status: 200, value: BrowserOpenResponse(
        documentID: envelope.documentID,
        opened: true
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
        let outcome = try await knowledge.importBrowserCapture(
          envelope.capture,
          folderID: envelope.folderID,
          newFolderName: envelope.newFolderName,
          duplicateResolution: envelope.duplicateResolution
        )
        guard case .saved(let result, let action) = outcome else {
          if case .requiresDuplicateResolution(let conflict) = outcome {
            lastMessage = "检测到同网址资料，等待选择处理方式。"
            sendResponse(.json(status: 200, value: BrowserDuplicateResolutionResponse(
              requiresDuplicateResolution: true,
              conflict: BrowserDuplicateConflictResponse(
                documentID: conflict.document.id,
                title: conflict.document.title,
                folder: conflict.folder.map { BrowserFolderResponse(id: $0.id, name: $0.name) },
                fileSizeBytes: conflict.document.sourceByteCount,
                updatedAt: conflict.document.updatedAt,
                incomingHasChanges: conflict.incomingHasChanges
              )
            )), on: connection)
          }
          return
        }
        guard
          let documentID = result.documentIDs.first,
          let document = knowledge.documents.first(where: { $0.id == documentID })
        else {
          sendResponse(.error(status: 500, message: "页面已保存，但生成保存回执失败。"), on: connection)
          return
        }
        let folder = document.folderID.flatMap { folderID in
          knowledge.folders.first(where: { $0.id == folderID })
        }
        lastMessage = "已从浏览器保存“\(envelope.capture.title)”。"
        sendResponse(.json(status: 200, value: BrowserImportResponse(
          insertedCount: result.insertedCount,
          updatedCount: result.updatedCount,
          skippedCount: result.skippedCount,
          action: action.rawValue,
          documentID: document.id,
          title: document.title,
          folder: folder.map { BrowserFolderResponse(id: $0.id, name: $0.name) },
          fileSizeBytes: document.sourceByteCount,
          archiveType: envelope.capture.archiveFormat?.lowercased() ?? "none",
          indexStatus: "ready",
          allowsAIUse: document.allowsAIUse,
          savedAt: document.updatedAt
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
  private static let tokenExpiryDefaultsKey = "KnowledgeBrowserBridge.connectionTokenExpiresAt.v1"

  private static func makeConnectionToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
      return bytes.map { String(format: "%02x", $0) }.joined()
    }
    return UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

  private func prepareUnixSocketPath() throws {
    let path = Self.socketPath
    guard FileManager.default.fileExists(atPath: path) else { return }
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    guard attributes[.type] as? FileAttributeType == .typeSocket else {
      throw NSError(
        domain: "KnowledgeBrowserBridge",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey:
            String(localized: "原生连接路径被非套接字文件占用，已拒绝覆盖。")
        ]
      )
    }
    try FileManager.default.removeItem(atPath: path)
  }
}

private struct BrowserImportEnvelope: Decodable {
  var capture: KnowledgeBrowserCapture
  var folderID: UUID?
  var newFolderName: String?
  var duplicateResolution: KnowledgeBrowserDuplicateResolution?
}

private struct BrowserOpenEnvelope: Decodable {
  var documentID: UUID
}

private struct BrowserOrganizationSuggestionEnvelope: Decodable {
  var sourceURL: URL
  var authors: [String]
  var tags: [String]
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
  var tokenExpiresAt: String
}

private struct BrowserFolderSuggestionResponse: Encodable {
  var folder: BrowserFolderResponse
  var score: Double
  var reasons: [String]
}

private struct BrowserOrganizationSuggestionsResponse: Encodable {
  var folders: [BrowserFolderSuggestionResponse]
  var tags: [String]
}

private struct BrowserImportResponse: Encodable {
  var insertedCount: Int
  var updatedCount: Int
  var skippedCount: Int
  var action: String
  var documentID: UUID
  var title: String
  var folder: BrowserFolderResponse?
  var fileSizeBytes: Int64
  var archiveType: String
  var indexStatus: String
  var allowsAIUse: Bool
  var savedAt: Date
}

private struct BrowserDuplicateConflictResponse: Encodable {
  var documentID: UUID
  var title: String
  var folder: BrowserFolderResponse?
  var fileSizeBytes: Int64
  var updatedAt: Date
  var incomingHasChanges: Bool
}

private struct BrowserDuplicateResolutionResponse: Encodable {
  var requiresDuplicateResolution: Bool
  var conflict: BrowserDuplicateConflictResponse
}

private struct BrowserOpenResponse: Encodable {
  var documentID: UUID
  var opened: Bool
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

  var isNativeMessagingForward: Bool {
    headers["x-knowledge-native-messaging"] == "1"
      && headers["origin"] == nil
  }

  var bearerToken: String? {
    let prefix = "Bearer "
    guard let authorization = headers["authorization"],
          authorization.hasPrefix(prefix) else { return nil }
    return String(authorization.dropFirst(prefix.count))
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

  static func error(status: Int, message: String, code: String? = nil) -> Self {
    var value = ["error": message]
    if let code { value["code"] = code }
    return json(status: status, value: value)
  }

  func encodedData() -> Data {
    let reason: String
    switch status {
    case 200: reason = "OK"
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
    Cache-Control: no-store\r
    Connection: close\r
    \r

    """
    var output = Data(header.utf8)
    output.append(body)
    return output
  }
}
