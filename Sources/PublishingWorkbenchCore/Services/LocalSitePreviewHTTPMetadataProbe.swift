import Foundation
import Network

/// Performs a loopback HTTP request without retaining the response body.
///
/// Foundation's response APIs may wait for the first body byte. This probe uses
/// a bounded loopback TCP exchange so it can stop at the HTTP header boundary,
/// even when a development server never starts or finishes its response body.
struct LocalSitePreviewHTTPMetadataProbe: Sendable {
  static func perform(_ request: URLRequest) async throws -> LocalSitePreviewPageProbeResult {
    try await LocalSitePreviewHTTPMetadataTransaction(request: request).execute()
  }
}

private final class LocalSitePreviewHTTPMetadataTransaction: @unchecked Sendable {
  private enum ParsedHeaderBlock {
    case incomplete
    case interim(nextOffset: Int)
    case final(LocalSitePreviewPageProbeResult, nextOffset: Int)
  }

  private static let maximumHeaderByteCount = 64 * 1_024
  private static let headerBoundary = Data([13, 10, 13, 10])

  private let connection: NWConnection
  private let requestData: Data
  private let responseURL: URL
  private let timeout: TimeInterval
  private let queue = DispatchQueue(label: "LocalSitePreviewHTTPMetadataTransaction")
  private var continuation: CheckedContinuation<LocalSitePreviewPageProbeResult, Error>?
  private var receivedData = Data()
  private var responseParseOffset = 0
  private var cancellationRequested = false
  private var didSendRequest = false
  private var didFinish = false

  init(request: URLRequest) throws {
    guard request.httpMethod?.uppercased() == "GET",
      let url = request.url,
      url.scheme?.lowercased() == "http",
      url.host == "127.0.0.1",
      let portValue = url.port,
      let rawPort = UInt16(exactly: portValue),
      rawPort > 0,
      let port = NWEndpoint.Port(rawValue: rawPort)
    else {
      throw URLError(.badURL)
    }

    responseURL = url
    timeout = min(5, max(0.1, request.timeoutInterval))
    requestData = try Self.makeRequestData(from: request, port: rawPort)

    let tcpOptions = NWProtocolTCP.Options()
    tcpOptions.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: tcpOptions)
    parameters.allowLocalEndpointReuse = false
    connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: port, using: parameters)
  }

  func execute() async throws -> LocalSitePreviewPageProbeResult {
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          start(continuation)
        }
      }
    } onCancel: {
      queue.async { [self] in
        guard !didFinish else { return }
        cancellationRequested = true
        guard continuation != nil else { return }
        finish(.failure(CancellationError()))
      }
    }
  }

  private func start(
    _ continuation: CheckedContinuation<LocalSitePreviewPageProbeResult, Error>
  ) {
    guard !didFinish else {
      continuation.resume(throwing: CancellationError())
      return
    }
    guard !cancellationRequested else {
      didFinish = true
      continuation.resume(throwing: CancellationError())
      return
    }

    self.continuation = continuation
    connection.stateUpdateHandler = { [weak self] state in
      self?.handle(state)
    }
    connection.start(queue: queue)
    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
      self?.finish(.failure(URLError(.timedOut)))
    }
  }

  private func handle(_ state: NWConnection.State) {
    switch state {
    case .ready where !didSendRequest:
      didSendRequest = true
      connection.send(
        content: requestData,
        completion: .contentProcessed { [weak self] error in
          self?.queue.async { [weak self] in
            guard let self else { return }
            if let error {
              finish(.failure(error))
            } else {
              receive()
            }
          }
        })
    case .failed(let error):
      finish(.failure(error))
    case .cancelled where !didFinish:
      finish(.failure(CancellationError()))
    default:
      break
    }
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) {
      [weak self] data, _, isComplete, error in
      self?.queue.async { [weak self] in
        self?.handleReceived(data, isComplete: isComplete, error: error)
      }
    }
  }

  private func handleReceived(
    _ data: Data?,
    isComplete: Bool,
    error: NWError?
  ) {
    guard !didFinish else { return }
    if let error {
      finish(.failure(error))
      return
    }
    if let data, !data.isEmpty {
      receivedData.append(data)
    }
    do {
      while true {
        switch try Self.parseNextHeaderBlock(
          receivedData,
          from: responseParseOffset,
          responseURL: responseURL
        ) {
        case .incomplete:
          if receivedData.count > Self.maximumHeaderByteCount {
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
          } else if isComplete {
            finish(.failure(URLError(.badServerResponse)))
          } else {
            receive()
          }
          return
        case .interim(let nextOffset):
          guard nextOffset <= Self.maximumHeaderByteCount else {
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
          }
          responseParseOffset = nextOffset
        case .final(let result, let nextOffset):
          guard nextOffset <= Self.maximumHeaderByteCount else {
            finish(.failure(URLError(.dataLengthExceedsMaximum)))
            return
          }
          finish(.success(result))
          return
        }
      }
    } catch {
      finish(.failure(error))
    }
  }

  private func finish(_ result: Result<LocalSitePreviewPageProbeResult, any Error>) {
    guard !didFinish else { return }
    didFinish = true
    let continuation = self.continuation
    self.continuation = nil
    connection.stateUpdateHandler = nil
    connection.cancel()
    continuation?.resume(with: result)
  }

  private static func makeRequestData(from request: URLRequest, port: UInt16) throws -> Data {
    guard let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else {
      throw URLError(.badURL)
    }
    var requestTarget = components.percentEncodedPath
    if requestTarget.isEmpty { requestTarget = "/" }
    if let query = components.percentEncodedQuery, !query.isEmpty {
      requestTarget += "?\(query)"
    }
    guard !requestTarget.contains("\r"), !requestTarget.contains("\n") else {
      throw URLError(.badURL)
    }

    let configuredAccept = request.value(forHTTPHeaderField: "Accept") ?? "text/html"
    let accept =
      configuredAccept.contains("\r") || configuredAccept.contains("\n")
      ? "text/html"
      : configuredAccept
    let requestText = [
      "GET \(requestTarget) HTTP/1.1",
      "Host: 127.0.0.1:\(port)",
      "Accept: \(accept)",
      "Cache-Control: no-cache",
      "Connection: close",
      "",
      "",
    ].joined(separator: "\r\n")
    return Data(requestText.utf8)
  }

  private static func parseNextHeaderBlock(
    _ data: Data,
    from offset: Int,
    responseURL: URL
  ) throws -> ParsedHeaderBlock {
    guard offset <= data.count else {
      throw URLError(.badServerResponse)
    }
    guard
      let boundary = data.range(
        of: headerBoundary,
        in: offset..<data.endIndex
      )
    else {
      return .incomplete
    }
    let headerData = data[offset..<boundary.lowerBound]
    guard let headerText = String(data: Data(headerData), encoding: .isoLatin1) else {
      throw URLError(.cannotDecodeRawData)
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let statusLine = lines.first else {
      throw URLError(.badServerResponse)
    }
    let statusParts = statusLine.split(separator: " ", omittingEmptySubsequences: true)
    guard statusParts.count >= 2,
      statusParts[0].hasPrefix("HTTP/"),
      let statusCode = Int(statusParts[1]),
      (100...599).contains(statusCode)
    else {
      throw URLError(.badServerResponse)
    }

    if (100...199).contains(statusCode), statusCode != 101 {
      return .interim(nextOffset: boundary.upperBound)
    }

    let location = lines.dropFirst().compactMap { line -> String? in
      guard let separator = line.firstIndex(of: ":") else { return nil }
      let name = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard name.caseInsensitiveCompare("Location") == .orderedSame else { return nil }
      return String(line[line.index(after: separator)...])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }.first
    let redirectURL = location.flatMap { value in
      URL(string: value, relativeTo: responseURL)?.absoluteURL
    }
    return .final(
      LocalSitePreviewPageProbeResult(
        statusCode: statusCode,
        responseURL: responseURL,
        redirectURL: redirectURL
      ),
      nextOffset: boundary.upperBound
    )
  }
}
