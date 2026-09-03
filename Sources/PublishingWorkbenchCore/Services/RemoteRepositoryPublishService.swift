import Foundation

public struct RemoteRepositoryPublishService: Sendable {
  let transport: RemoteRepositoryHTTPTransport
  let encoder: SerializedJSONEncoder
  let decoder: SerializedJSONDecoder
  private let fileSystem: SendableFileManager
  let expectedContentSHA256: [String: String]?

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
    self.expectedContentSHA256 = nil
  }

  init(
    transport: RemoteRepositoryHTTPTransport,
    encoder: SerializedJSONEncoder,
    decoder: SerializedJSONDecoder,
    fileSystem: SendableFileManager,
    expectedContentSHA256: [String: String]?
  ) {
    self.transport = transport
    self.encoder = encoder
    self.decoder = decoder
    self.fileSystem = fileSystem
    self.expectedContentSHA256 = expectedContentSHA256
  }

  func withPublicationGuards(
    beforeMutation: (@Sendable () async throws -> Void)?,
    expectedContentSHA256: [String: String]?
  ) -> RemoteRepositoryPublishService {
    let guardedTransport: RemoteRepositoryHTTPTransport
    if let beforeMutation {
      guardedTransport = MutationGuardedRemoteRepositoryHTTPTransport(
        underlying: transport, beforeMutation: beforeMutation)
    } else {
      guardedTransport = transport
    }
    return RemoteRepositoryPublishService(
      transport: guardedTransport,
      encoder: encoder,
      decoder: decoder,
      fileSystem: fileSystem,
      expectedContentSHA256: expectedContentSHA256
    )
  }
}
