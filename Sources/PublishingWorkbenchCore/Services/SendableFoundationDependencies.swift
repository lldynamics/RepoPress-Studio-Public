import Foundation

/// Foundation's reference-type helpers are immutable dependencies in the
/// publishing services, but they do not all expose Sendable conformances on
/// every supported SDK. These wrappers make the ownership contract explicit.
final class SendableFileManager: @unchecked Sendable {
  let value: FileManager

  init(_ value: FileManager) {
    self.value = value
  }
}

final class SerializedJSONEncoder: @unchecked Sendable {
  private let encoder: JSONEncoder
  private let lock = NSLock()

  init(_ encoder: JSONEncoder) {
    self.encoder = encoder
  }

  func encode<Value: Encodable>(_ value: Value) throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    return try encoder.encode(value)
  }
}

final class SerializedJSONDecoder: @unchecked Sendable {
  private let decoder: JSONDecoder
  private let lock = NSLock()

  init(_ decoder: JSONDecoder) {
    self.decoder = decoder
  }

  func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    lock.lock()
    defer { lock.unlock() }
    return try decoder.decode(type, from: data)
  }
}
