import XCTest

@testable import PublishingWorkbenchCore

final class AIConnectionEndpointValidationTests: XCTestCase {
  func testRejectsMalformedAndCredentialedHTTPURLs() {
    XCTAssertEqual(
      AIConnectionEndpointValidation.validate(
        config: AIProviderConfig(
          preset: .custom,
          baseURL: "not a url",
          model: "model",
          requiresAPIKey: false
        )
      ),
      .invalidURL
    )
    XCTAssertEqual(
      AIConnectionEndpointValidation.validate(
        config: AIProviderConfig(
          preset: .custom,
          baseURL: "http://127.0.0.1:11434/v1",
          model: "model",
          requiresAPIKey: true
        )
      ),
      .insecureCredentialURL
    )
  }

  func testAllowsLocalHTTPWithoutKeyAndHTTPSAPIKeyService() {
    XCTAssertEqual(
      AIConnectionEndpointValidation.validate(
        config: AIProviderConfig(
          preset: .local,
          baseURL: "http://127.0.0.1:11434/v1",
          model: "model",
          requiresAPIKey: false
        )
      ),
      .ready
    )
    XCTAssertEqual(
      AIConnectionEndpointValidation.validate(
        config: AIProviderConfig(
          preset: .custom,
          baseURL: "https://api.example.com/v1",
          model: "model",
          requiresAPIKey: true
        )
      ),
      .ready
    )
  }

  func testKeepsCodexAppServerOutsideOrdinaryEndpointValidation() {
    XCTAssertEqual(
      AIConnectionEndpointValidation.validate(config: AIProviderConfig(preset: .codexAppServer)),
      .ready
    )
  }
}
