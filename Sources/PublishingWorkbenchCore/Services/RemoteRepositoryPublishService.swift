import Foundation
public struct RemoteRepositoryPublishService {
  let transport: RemoteRepositoryHTTPTransport
  let encoder: JSONEncoder
  let decoder: JSONDecoder
  let fileManager: FileManager

  public init(
    transport: RemoteRepositoryHTTPTransport = URLSessionRemoteRepositoryHTTPTransport(),
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder(),
    fileManager: FileManager = .default
  ) {
    self.transport = transport
    self.encoder = encoder
    self.decoder = decoder
    self.fileManager = fileManager
  }
}
