import Foundation

enum HTTPResponseLimitError: Error, Equatable, LocalizedError, Sendable {
  case invalidLimit
  case responseTooLarge(maximumByteCount: Int)

  var errorDescription: String? {
    switch self {
    case .invalidLimit:
      return "网络响应上限必须大于 0。"
    case let .responseTooLarge(maximumByteCount):
      return "远端响应超过允许的 \(maximumByteCount) 字节，已停止读取。"
    }
  }

  var maximumByteCount: Int {
    switch self {
    case .invalidLimit:
      return 0
    case let .responseTooLarge(maximumByteCount):
      return maximumByteCount
    }
  }
}

enum BoundedHTTPResponseLoader {
  static func data(
    for request: URLRequest,
    using session: URLSession,
    maximumByteCount: Int
  ) async throws -> (Data, URLResponse) {
    guard maximumByteCount > 0 else {
      throw HTTPResponseLimitError.invalidLimit
    }
    let (bytes, response) = try await session.bytes(for: request)
    try validateExpectedLength(response, maximumByteCount: maximumByteCount)

    var data = Data()
    if response.expectedContentLength > 0 {
      data.reserveCapacity(min(Int(response.expectedContentLength), maximumByteCount))
    }
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < maximumByteCount else {
        throw HTTPResponseLimitError.responseTooLarge(maximumByteCount: maximumByteCount)
      }
      data.append(byte)
    }
    return (data, response)
  }

  static func validate(
    _ data: Data,
    response: URLResponse,
    maximumByteCount: Int
  ) throws {
    guard maximumByteCount > 0 else {
      throw HTTPResponseLimitError.invalidLimit
    }
    try validateExpectedLength(response, maximumByteCount: maximumByteCount)
    guard data.count <= maximumByteCount else {
      throw HTTPResponseLimitError.responseTooLarge(maximumByteCount: maximumByteCount)
    }
  }

  static func validateExpectedLength(
    _ response: URLResponse,
    maximumByteCount: Int
  ) throws {
    let expectedLength = response.expectedContentLength
    guard expectedLength == NSURLSessionTransferSizeUnknown
      || expectedLength <= Int64(maximumByteCount) else {
      throw HTTPResponseLimitError.responseTooLarge(maximumByteCount: maximumByteCount)
    }
  }
}
