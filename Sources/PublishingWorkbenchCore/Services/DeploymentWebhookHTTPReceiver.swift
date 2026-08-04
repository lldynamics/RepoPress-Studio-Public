import Foundation
import Network

public struct DeploymentWebhookHTTPReceiverState: Codable, Hashable, Sendable {
  public var isRunning: Bool
  public var port: UInt16
  public var endpointURLText: String?
  public var message: String

  public init(
    isRunning: Bool = false,
    port: UInt16 = 8787,
    endpointURLText: String? = nil,
    message: String = DeploymentWebhookHTTPReceiverState.defaultMessage
  ) {
    self.isRunning = isRunning
    self.port = port
    self.endpointURLText = endpointURLText
    self.message = message
  }

  public static let idle = DeploymentWebhookHTTPReceiverState()

  public static var defaultMessage: String {
    CoreL10n.text("Webhook 接收器未启动。")
  }
}

public struct DeploymentWebhookHTTPRequest: Equatable, Sendable {
  public var provider: DeploymentProvider
  public var payloadText: String

  public init(provider: DeploymentProvider, payloadText: String) {
    self.provider = provider
    self.payloadText = payloadText
  }

  public static func parse(_ data: Data) -> DeploymentWebhookHTTPRequest? {
    guard let requestText = String(data: data, encoding: .utf8),
          let headerRange = requestText.range(of: "\r\n\r\n") else {
      return nil
    }

    let head = String(requestText[..<headerRange.lowerBound])
    let body = String(requestText[headerRange.upperBound...])
    guard let requestLine = head.split(separator: "\r\n").first else {
      return nil
    }
    let parts = requestLine.split(separator: " ")
    guard parts.count >= 2, parts[0].uppercased() == "POST" else {
      return nil
    }

    guard let headers = parseHeaders(
      head
        .split(separator: "\r\n", omittingEmptySubsequences: false)
        .dropFirst()
    ) else {
      return nil
    }
    guard let rawContentLength = headers["content-length"]?.first,
          let contentLength = Int(rawContentLength),
          contentLength >= 0,
          contentLength == body.lengthOfBytes(using: .utf8) else {
      return nil
    }

    let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
    let pathParts = path.split(separator: "/").map(String.init)
    guard pathParts.count >= 2,
          pathParts[0] == "deployment-webhook",
          let provider = provider(from: pathParts[1]) else {
      return nil
    }

    return DeploymentWebhookHTTPRequest(provider: provider, payloadText: body)
  }

  private static func parseHeaders(
    _ lines: ArraySlice<Substring>
  ) -> [String: [String]]? {
    var headers: [String: [String]] = [:]
    for line in lines {
      guard !line.isEmpty,
            let separator = line.firstIndex(of: ":") else {
        return nil
      }
      let name = line[..<separator]
        .trimmingCharacters(in: .whitespaces)
        .lowercased()
      guard !name.isEmpty else {
        return nil
      }
      let value = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
      headers[name, default: []].append(value)
    }

    let nonRepeatableHeaders = [
      "content-length",
      "content-type",
      "host",
      "transfer-encoding",
    ]
    guard nonRepeatableHeaders.allSatisfy({
      headers[$0, default: []].count <= 1
    }) else {
      return nil
    }
    return headers
  }

  private static func provider(from rawValue: String) -> DeploymentProvider? {
    let normalized = rawValue.lowercased()
    switch normalized {
    case "github", "githubpages", "github-pages":
      return .githubPages
    case "gitlab", "gitlabpages", "gitlab-pages":
      return .gitlabPages
    case "netlify":
      return .netlify
    case "vercel":
      return .vercel
    case "cloudflare", "cloudflarepages", "cloudflare-pages":
      return .cloudflarePages
    case "custom":
      return .custom
    default:
      return DeploymentProvider(rawValue: rawValue)
    }
  }
}

public final class DeploymentWebhookHTTPReceiver: @unchecked Sendable {
  private var listener: NWListener?
  private let listenerLock = NSLock()
  private let queue = DispatchQueue(label: "PersonalSitePublisherMac.DeploymentWebhookHTTPReceiver")

  public init() {}

  deinit {
    stop()
  }

  public func start(
    port: UInt16,
    handler: @escaping @Sendable (DeploymentProvider, String) async -> Bool
  ) throws -> String {
#if !DEBUG
    throw DeploymentWebhookHTTPReceiverError.unavailableInRelease
#else
    stop()

    guard let nwPort = NWEndpoint.Port(rawValue: port) else {
      throw DeploymentWebhookHTTPReceiverError.invalidPort
    }
    let listener = try NWListener(using: .tcp, on: nwPort)
    listener.newConnectionHandler = { [weak self] connection in
      self?.handle(connection: connection, handler: handler)
    }
    listener.start(queue: queue)
    listenerLock.lock()
    self.listener = listener
    listenerLock.unlock()
    return "http://127.0.0.1:\(port)/deployment-webhook/{provider}"
#endif
  }

  public func stop() {
    listenerLock.lock()
    let activeListener = listener
    listener = nil
    listenerLock.unlock()
    activeListener?.cancel()
  }

  private func handle(
    connection: NWConnection,
    handler: @escaping @Sendable (DeploymentProvider, String) async -> Bool
  ) {
    let state = DeploymentWebhookConnectionState()
    connection.start(queue: queue)
    receiveMore(connection: connection, state: state, handler: handler)
  }

  private func receiveMore(
    connection: NWConnection,
    state: DeploymentWebhookConnectionState,
    handler: @escaping @Sendable (DeploymentProvider, String) async -> Bool
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let data {
        state.append(data)
      }
      let received = state.snapshot()

      if let request = DeploymentWebhookHTTPRequest.parse(received) {
        Task {
          let accepted = await handler(request.provider, request.payloadText)
          self.sendResponse(accepted ? 200 : 400, connection: connection)
        }
        return
      }

      if isComplete || error != nil || received.count > 1_048_576 {
        self.sendResponse(400, connection: connection)
        return
      }

      self.receiveMore(connection: connection, state: state, handler: handler)
    }
  }

  private func sendResponse(_ statusCode: Int, connection: NWConnection) {
    let reason = statusCode == 200 ? "OK" : "Bad Request"
    let body = statusCode == 200 ? "accepted" : "rejected"
    let response = """
    HTTP/1.1 \(statusCode) \(reason)\r
    Content-Type: text/plain; charset=utf-8\r
    Content-Length: \(body.utf8.count)\r
    Connection: close\r
    \r
    \(body)
    """
    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
      connection.cancel()
    })
  }
}

private final class DeploymentWebhookConnectionState: @unchecked Sendable {
  private let lock = NSLock()
  private var received = Data()

  func append(_ data: Data) {
    lock.lock()
    received.append(data)
    lock.unlock()
  }

  func snapshot() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return received
  }
}

public enum DeploymentWebhookHTTPReceiverError: LocalizedError, Equatable {
  case invalidPort
  case unavailableInRelease

  public var errorDescription: String? {
    switch self {
    case .invalidPort:
      return CoreL10n.text("Webhook 接收端口无效。")
    case .unavailableInRelease:
      return CoreL10n.text("Webhook 接收器仅用于 Debug 构建，不会包含在 Release/App Store 构建中。")
    }
  }
}
