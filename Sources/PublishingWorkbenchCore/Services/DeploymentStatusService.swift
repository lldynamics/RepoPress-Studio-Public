import Foundation
public struct DeploymentStatusService {
  let transport: RemoteRepositoryHTTPTransport
  let decoder: JSONDecoder

  public init(
    transport: RemoteRepositoryHTTPTransport = URLSessionRemoteRepositoryHTTPTransport(),
    decoder: JSONDecoder = JSONDecoder()
  ) {
    self.transport = transport
    self.decoder = decoder
  }

}
