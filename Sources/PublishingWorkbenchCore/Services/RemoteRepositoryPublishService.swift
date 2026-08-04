import Foundation
public struct RemoteRepositoryPublishService: Sendable {
  let transport: RemoteRepositoryHTTPTransport
  let encoder: SerializedJSONEncoder
  let decoder: SerializedJSONDecoder
  private let fileSystem: SendableFileManager

  var fileManager: FileManager { fileSystem.value }

  public init(
    transport: RemoteRepositoryHTTPTransport = URLSessionRemoteRepositoryHTTPTransport(),
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder(),
    fileManager: FileManager = .default
  ) {
    self.transport = transport
    self.encoder = SerializedJSONEncoder(encoder)
    self.decoder = SerializedJSONDecoder(decoder)
    self.fileSystem = SendableFileManager(fileManager)
  }
}
