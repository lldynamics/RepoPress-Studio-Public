import Foundation
import PublishingWorkbenchCore

/// UI-local ownership for a connection test. The store still owns credentials
/// and consent; this state only prevents an old completion from being rendered
/// against a different connection or model.
struct AIChatConnectionTestRequestIdentity: Hashable {
  let connectionProfileID: UUID
  let config: AIProviderConfig
  let model: String

  init(connectionProfileID: UUID, config: AIProviderConfig, model: String) {
    self.connectionProfileID = connectionProfileID
    self.config = config
    self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct AIChatConnectionTestRequest: Equatable {
  let identity: AIChatConnectionTestRequestIdentity
  let generation: UInt64
}

struct AIChatConnectionTestRequestState: Equatable {
  private(set) var activeRequest: AIChatConnectionTestRequest?
  private var nextGeneration: UInt64 = 0

  var isTesting: Bool { activeRequest != nil }

  mutating func begin(for identity: AIChatConnectionTestRequestIdentity) -> AIChatConnectionTestRequest {
    nextGeneration &+= 1
    let request = AIChatConnectionTestRequest(identity: identity, generation: nextGeneration)
    activeRequest = request
    return request
  }

  mutating func invalidate() {
    activeRequest = nil
  }

  mutating func finish(
    _ request: AIChatConnectionTestRequest,
    whileCurrentIdentityIs identity: AIChatConnectionTestRequestIdentity
  ) -> Bool {
    guard activeRequest == request, request.identity == identity else { return false }
    activeRequest = nil
    return true
  }
}
