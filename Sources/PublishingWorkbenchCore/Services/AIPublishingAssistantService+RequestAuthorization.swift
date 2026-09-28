import Foundation
import PublishingAICore

extension AIPublishingAssistantService {
  func cancellingStreamingRequests(
    with cancellation: AIChatStreamingRequestCancellation
  ) -> AIPublishingAssistantService {
    var copy = client
    copy.streamingRequestCancellation = cancellation
    return AIPublishingAssistantService(client: copy)
  }

  func authorizingNonStreamingRequests(
    _ authorization: @escaping @Sendable () async throws -> Void
  ) -> AIPublishingAssistantService {
    AIPublishingAssistantService(client: client.authorizingNonStreamingRequests(authorization))
  }

  func authorizingStreamingRequests(
    _ authorization: @escaping @Sendable () async throws -> Void
  ) -> AIPublishingAssistantService {
    AIPublishingAssistantService(client: client.authorizingStreamingRequests(authorization))
  }
}
