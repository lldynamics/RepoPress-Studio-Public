import PublishingAICore
import XCTest
@testable import PersonalSitePublisherMac

final class AIChatConnectionTestRequestStateTests: XCTestCase {
  func testLateResultForConnectionACannotFinishAfterSwitchToB() {
    var state = AIChatConnectionTestRequestState()
    let requestA = state.begin(for: identity(baseURL: "https://a.example.com/v1", model: "model-a"))
    state.invalidate()
    let identityB = identity(baseURL: "https://b.example.com/v1", model: "model-b")
    _ = state.begin(for: identityB)

    XCTAssertFalse(state.finish(requestA, whileCurrentIdentityIs: identityB))
    XCTAssertTrue(state.isTesting)
  }

  func testOlderGenerationForSameConfigurationCannotFinishNewerRequest() {
    var state = AIChatConnectionTestRequestState()
    let identity = identity(baseURL: "https://same.example.com/v1", model: "model-a")
    let first = state.begin(for: identity)
    let second = state.begin(for: identity)

    XCTAssertFalse(state.finish(first, whileCurrentIdentityIs: identity))
    XCTAssertTrue(state.finish(second, whileCurrentIdentityIs: identity))
    XCTAssertFalse(state.isTesting)
  }

  private func identity(baseURL: String, model: String) -> AIChatConnectionTestRequestIdentity {
    AIChatConnectionTestRequestIdentity(
      connectionProfileID: UUID(),
      config: AIProviderConfig(
        preset: .custom,
        baseURL: baseURL,
        model: model,
        requiresAPIKey: true
      ),
      model: model
    )
  }
}
