import Foundation
public struct DeploymentStatusService: Sendable {
  let transport: RemoteRepositoryHTTPTransport
  let decoder: DeploymentStatusJSONDecoder

  public init(
    transport: RemoteRepositoryHTTPTransport = URLSessionRemoteRepositoryHTTPTransport(),
    decoder: JSONDecoder = JSONDecoder()
  ) {
    self.transport = transport
    self.decoder = DeploymentStatusJSONDecoder(decoder)
  }

}

final class DeploymentStatusJSONDecoder: @unchecked Sendable {
  private let lock = NSLock()
  private let decoder: JSONDecoder

  init(_ decoder: JSONDecoder) {
    self.decoder = decoder
  }

  func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    lock.lock()
    defer { lock.unlock() }
    return try decoder.decode(type, from: data)
  }
}
