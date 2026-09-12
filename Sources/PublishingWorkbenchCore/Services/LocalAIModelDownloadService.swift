import Foundation
import PublishingCoreSupport

public struct LocalAIModelDownloadProgress: Codable, Hashable, Sendable {
  public let status: String
  public let completedBytes: Int64?
  public let totalBytes: Int64?
  public let isComplete: Bool

  public init(
    status: String,
    completedBytes: Int64? = nil,
    totalBytes: Int64? = nil,
    isComplete: Bool = false
  ) {
    self.status = status
    self.completedBytes = completedBytes
    self.totalBytes = totalBytes
    self.isComplete = isComplete
  }

  public var fractionCompleted: Double? {
    guard let completedBytes, let totalBytes, totalBytes > 0 else { return nil }
    return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
  }
}

public enum LocalAIModelDownloadError: Error, Equatable, LocalizedError, Sendable {
  case invalidModelIdentifier
  case unsafeEndpoint
  case unsafeResponse
  case invalidResponse
  case httpStatus(Int)
  case malformedProgress
  case modelNotFound
  case insufficientStorage
  case serverFailure
  case incompleteResponse
  case responseTooLarge

  public var errorDescription: String? {
    switch self {
    case .invalidModelIdentifier:
      return CoreL10n.text("请输入有效的模型 ID。")
    case .unsafeEndpoint, .unsafeResponse:
      return CoreL10n.text("已阻止非本机模型下载连接。")
    case .invalidResponse:
      return CoreL10n.text("本地模型服务返回了无效响应。")
    case .httpStatus(let statusCode):
      return CoreL10n.format("本地模型服务响应异常（HTTP %d）。", statusCode)
    case .malformedProgress:
      return CoreL10n.text("本地模型服务返回了无法识别的下载进度。")
    case .modelNotFound:
      return CoreL10n.text("找不到指定模型，请检查模型 ID。")
    case .insufficientStorage:
      return CoreL10n.text("本机磁盘空间不足，无法下载该模型。")
    case .serverFailure:
      return CoreL10n.text("本地模型服务拒绝了下载请求。")
    case .incompleteResponse:
      return CoreL10n.text("模型下载未完成，请重新检测或重试。")
    case .responseTooLarge:
      return CoreL10n.text("模型下载进度响应超过安全上限。")
    }
  }
}

public protocol LocalAIModelDownloadTransport: Sendable {
  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  )
}

/// Pulls a model only through Ollama's fixed loopback API. It sends the model
/// identifier and streaming flag, never article text, credentials, or any
/// caller-supplied URL.
public struct LocalAIModelDownloadService: Sendable {
  public static let ollamaPullURL = URL(string: "http://127.0.0.1:11434/api/pull")!
  public static let maximumResponseByteCount = 4 * 1_024 * 1_024
  public static let maximumLineByteCount = 64 * 1_024

  private let transport: any LocalAIModelDownloadTransport

  public init() {
    transport = URLSessionLocalAIModelDownloadTransport()
  }

  public init(transport: any LocalAIModelDownloadTransport) {
    self.transport = transport
  }

  public func pull(modelID: String) -> AsyncThrowingStream<LocalAIModelDownloadProgress, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try makePullRequest(modelID: modelID)
          let (lines, response) = try await transport.lines(for: request)
          try validate(response: response, requestURL: request.url)

          var receivedCompletion = false
          var receivedResponseBytes = 0
          for try await line in lines {
            try Task.checkCancellation()
            receivedResponseBytes += line.utf8.count + 1
            guard receivedResponseBytes <= Self.maximumResponseByteCount else {
              throw LocalAIModelDownloadError.responseTooLarge
            }
            guard line.utf8.count <= Self.maximumLineByteCount else {
              throw LocalAIModelDownloadError.responseTooLarge
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let progress = try progress(from: trimmed)
            receivedCompletion = receivedCompletion || progress.isComplete
            continuation.yield(progress)
          }
          guard receivedCompletion else { throw LocalAIModelDownloadError.incompleteResponse }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish(throwing: CancellationError())
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func makePullRequest(modelID: String) throws -> URLRequest {
    let normalizedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isValidModelIdentifier(normalizedModelID) else {
      throw LocalAIModelDownloadError.invalidModelIdentifier
    }
    guard LocalAIEngineDiscoveryService.isStrictLoopbackURL(Self.ollamaPullURL) else {
      throw LocalAIModelDownloadError.unsafeEndpoint
    }
    var request = URLRequest(url: Self.ollamaPullURL)
    request.httpMethod = "POST"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(
      LocalAIModelPullRequest(model: normalizedModelID, stream: true)
    )
    return request
  }

  private func validate(response: URLResponse, requestURL: URL?) throws {
    guard let requestURL,
      LocalAIEngineDiscoveryService.isStrictLoopbackURL(requestURL)
    else {
      throw LocalAIModelDownloadError.unsafeEndpoint
    }
    do {
      try BoundedHTTPResponseLoader.validateExpectedLength(
        response,
        maximumByteCount: Self.maximumResponseByteCount
      )
    } catch is HTTPResponseLimitError {
      throw LocalAIModelDownloadError.responseTooLarge
    }
    guard let responseURL = response.url,
      LocalAIEngineDiscoveryService.isStrictLoopbackURL(responseURL),
      LocalAIEngineDiscoveryService.isSameOrigin(requestURL, responseURL)
    else {
      throw LocalAIModelDownloadError.unsafeResponse
    }
    guard let httpResponse = response as? HTTPURLResponse else {
      throw LocalAIModelDownloadError.invalidResponse
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw LocalAIModelDownloadError.httpStatus(httpResponse.statusCode)
    }
  }

  private func progress(from line: String) throws -> LocalAIModelDownloadProgress {
    let payload: LocalAIModelPullProgress
    do {
      payload = try JSONDecoder().decode(LocalAIModelPullProgress.self, from: Data(line.utf8))
    } catch {
      throw LocalAIModelDownloadError.malformedProgress
    }
    if let error = payload.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
      throw classifiedServerError(error)
    }
    let status = payload.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !status.isEmpty else { throw LocalAIModelDownloadError.malformedProgress }
    return LocalAIModelDownloadProgress(
      status: status,
      completedBytes: payload.completed,
      totalBytes: payload.total,
      isComplete: status.caseInsensitiveCompare("success") == .orderedSame
    )
  }

  private func classifiedServerError(_ error: String) -> LocalAIModelDownloadError {
    let normalized = error.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    if normalized.contains("not found") || normalized.contains("does not exist") {
      return .modelNotFound
    }
    if normalized.contains("no space") || normalized.contains("disk full")
      || normalized.contains("insufficient space")
    {
      return .insufficientStorage
    }
    return .serverFailure
  }

  static func isValidModelIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 256,
      value == value.trimmingCharacters(in: .whitespacesAndNewlines),
      !value.contains("://"), !value.contains("@")
    else {
      return false
    }
    return value.unicodeScalars.allSatisfy { scalar in
      let category = scalar.properties.generalCategory
      return scalar.properties.isWhitespace == false && category != .control && category != .format
    }
  }
}

private struct LocalAIModelPullRequest: Encodable {
  let model: String
  let stream: Bool
}

private struct LocalAIModelPullProgress: Decodable {
  let status: String?
  let error: String?
  let completed: Int64?
  let total: Int64?
}

private struct URLSessionLocalAIModelDownloadTransport: LocalAIModelDownloadTransport {
  private let sessionOwner: ManagedURLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.waitsForConnectivity = false
    sessionOwner = ManagedURLSession(
      session: URLSession(
        configuration: configuration,
        delegate: LocalAIModelDownloadURLSessionDelegate(),
        delegateQueue: nil
      ), ownsSession: true)
  }

  func lines(for request: URLRequest) async throws -> (
    AsyncThrowingStream<String, Error>, URLResponse
  ) {
    defer { withExtendedLifetime(sessionOwner) {} }
    let (bytes, response) = try await sessionOwner.session.bytes(for: request)
    let stream = AsyncThrowingStream<String, Error> { continuation in
      let task = Task { [sessionOwner] in
        defer { withExtendedLifetime(sessionOwner) {} }
        do {
          var lineBytes: [UInt8] = []
          var totalBytes = 0
          for try await byte in bytes {
            try Task.checkCancellation()
            totalBytes += 1
            guard totalBytes <= LocalAIModelDownloadService.maximumResponseByteCount,
              lineBytes.count < LocalAIModelDownloadService.maximumLineByteCount
            else {
              throw LocalAIModelDownloadError.responseTooLarge
            }
            if byte == 0x0A {
              if lineBytes.last == 0x0D { lineBytes.removeLast() }
              continuation.yield(String(decoding: lineBytes, as: UTF8.self))
              lineBytes.removeAll(keepingCapacity: true)
            } else {
              lineBytes.append(byte)
            }
          }
          if !lineBytes.isEmpty {
            continuation.yield(String(decoding: lineBytes, as: UTF8.self))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
    return (stream, response)
  }
}

private final class LocalAIModelDownloadURLSessionDelegate: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
