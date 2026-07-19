import Darwin
import Foundation
import KnowledgeNativeMessagingSupport
import Network

@main
struct KnowledgeNativeMessagingHost {
  static func main() async {
    let response: Data
    do {
      let request = try readRequest()
      try request.validate()
      response = try await forward(request)
    } catch {
      response = errorResponse(error.localizedDescription)
    }

    let framedResponse: Data
    do {
      framedResponse = try KnowledgeNativeMessagingProtocol.frame(response)
    } catch {
      framedResponse = try! KnowledgeNativeMessagingProtocol.frame(errorResponse(error.localizedDescription))
    }
    FileHandle.standardOutput.write(framedResponse)
  }

  private static func readRequest() throws -> KnowledgeNativeMessagingProtocol.Request {
    let input = FileHandle.standardInput
    let header = try readExactly(4, from: input)
    let length = try KnowledgeNativeMessagingProtocol.decodeLength(header)
    let payload = try readExactly(length, from: input)
    return try JSONDecoder().decode(KnowledgeNativeMessagingProtocol.Request.self, from: payload)
  }

  private static func readExactly(_ count: Int, from handle: FileHandle) throws -> Data {
    var result = Data()
    while result.count < count {
      let chunk = handle.readData(ofLength: count - result.count)
      guard !chunk.isEmpty else {
        throw KnowledgeNativeMessagingProtocol.ProtocolError.truncatedHeader
      }
      result.append(chunk)
    }
    return result
  }

  private static func forward(_ nativeRequest: KnowledgeNativeMessagingProtocol.Request) async throws -> Data {
    let requestData = encodedBridgeRequest(nativeRequest)
    let socketPath = KnowledgeNativeMessagingProtocol.unixSocketPath(userID: getuid())
    let responseData = try await UnixSocketHTTPClient(socketPath: socketPath).execute(requestData)
    let (status, body) = try parsedBridgeResponse(responseData)
    let payload: Any
    if body.isEmpty {
      payload = [:]
    } else {
      payload = try JSONSerialization.jsonObject(with: body)
    }
    return try JSONSerialization.data(withJSONObject: [
      "schemaVersion": KnowledgeNativeMessagingProtocol.schemaVersion,
      "ok": (200..<300).contains(status),
      "status": status,
      "payload": payload,
      "transport": "native",
    ])
  }

  private static func encodedBridgeRequest(
    _ request: KnowledgeNativeMessagingProtocol.Request
  ) -> Data {
    let body = request.bodyJSON.map { Data($0.utf8) } ?? Data()
    var headers = [
      "\(request.method.uppercased()) \(request.path) HTTP/1.1",
      "Host: localhost",
      "Authorization: Bearer \(request.token)",
      "X-Knowledge-Native-Messaging: 1",
      "Content-Length: \(body.count)",
      "Cache-Control: no-store",
      "Connection: close",
    ]
    if !body.isEmpty { headers.append("Content-Type: application/json") }
    var data = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    data.append(body)
    return data
  }

  private static func parsedBridgeResponse(_ data: Data) throws -> (Int, Data) {
    let separator = Data("\r\n\r\n".utf8)
    guard let range = data.range(of: separator),
          let header = String(data: data[..<range.lowerBound], encoding: .utf8),
          let statusLine = header.components(separatedBy: "\r\n").first else {
      throw HostTransportError.invalidResponse
    }
    let parts = statusLine.split(separator: " ", maxSplits: 2)
    guard parts.count >= 2, let status = Int(parts[1]) else {
      throw HostTransportError.invalidResponse
    }
    return (status, Data(data[range.upperBound...]))
  }

  private static func errorResponse(_ message: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: [
      "schemaVersion": KnowledgeNativeMessagingProtocol.schemaVersion,
      "ok": false,
      "status": 0,
      "payload": [
        "error": message,
        "code": "native-host-error",
      ],
      "transport": "native",
    ])) ?? Data("{\"ok\":false}".utf8)
  }
}

private final class UnixSocketHTTPClient: @unchecked Sendable {
  private static let maximumResponseBytes =
    KnowledgeNativeMessagingProtocol.maximumOutputBytes + 32 * 1_024

  private let connection: NWConnection
  private let queue = DispatchQueue(label: "com.jinfang.knowledge-native-host.socket")
  private var request = Data()
  private var response = Data()
  private var continuation: CheckedContinuation<Data, Error>?

  init(socketPath: String) {
    connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
  }

  func execute(_ request: Data) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
      self.request = request
      self.continuation = continuation
      connection.stateUpdateHandler = { [weak self] state in
        self?.handle(state)
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + 5) { [weak self] in
        guard self?.continuation != nil else { return }
        self?.finish(.failure(HostTransportError.timedOut))
      }
    }
  }

  private func handle(_ state: NWConnection.State) {
    switch state {
    case .ready:
      connection.send(content: request, completion: .contentProcessed { [weak self] error in
        if let error { self?.finish(.failure(error)) }
        else { self?.receive() }
      })
    case .failed(let error):
      finish(.failure(error))
    case .cancelled:
      if continuation != nil { finish(.failure(HostTransportError.connectionClosed)) }
    default:
      break
    }
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        finish(.failure(error))
        return
      }
      if let data { response.append(data) }
      guard response.count <= Self.maximumResponseBytes else {
        finish(.failure(HostTransportError.responseTooLarge))
        return
      }
      if let length = Self.completeResponseLength(response), response.count >= length {
        finish(.success(Data(response.prefix(length))))
      } else if isComplete {
        finish(.failure(HostTransportError.invalidResponse))
      } else {
        receive()
      }
    }
  }

  private func finish(_ result: Result<Data, Error>) {
    guard let continuation else { return }
    self.continuation = nil
    connection.cancel()
    continuation.resume(with: result)
  }

  private static func completeResponseLength(_ data: Data) -> Int? {
    let separator = Data("\r\n\r\n".utf8)
    guard let range = data.range(of: separator),
          let header = String(data: data[..<range.lowerBound], encoding: .utf8) else {
      return nil
    }
    let line = header.components(separatedBy: "\r\n").first {
      $0.lowercased().hasPrefix("content-length:")
    }
    guard let line, let colon = line.firstIndex(of: ":"),
          let length = Int(line[line.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)),
          length >= 0 else {
      return nil
    }
    return range.upperBound + length
  }
}

private enum HostTransportError: Error, LocalizedError {
  case connectionClosed
  case invalidResponse
  case responseTooLarge
  case timedOut

  var errorDescription: String? {
    switch self {
    case .connectionClosed: "应用关闭了原生连接。"
    case .invalidResponse: "应用返回了无效的原生连接响应。"
    case .responseTooLarge: "应用返回的原生连接响应超过 1 MB。"
    case .timedOut: "连接应用的 Unix Socket 超时。"
    }
  }
}
