import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIModelTaskRoutingTests: XCTestCase {
  func testPublishingReviewSendsTheSelectedModelForCustomModelsAndGateways() async throws {
    let configurations = [
      AIProviderConfig(
        preset: .openAICompatible,
        baseURL: "https://api.openai.com/v1",
        model: "selected-review-model",
        requiresAPIKey: false
      ),
      AIProviderConfig(
        preset: .openAICompatible,
        baseURL: "https://gateway.example.com/v1",
        model: "gpt-4.1-mini",
        requiresAPIKey: false
      ),
    ]
    for config in configurations {
      let transport = RecordingAIChatTransport(
        data: Data(#"{"choices":[{"message":{"role":"assistant","content":"审稿完成。"}}]}"#.utf8),
        statusCode: 200
      )
      let service = AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport))
      let profile = SiteProfile.defaultProfile
      let draft = ArticleDraft(
        siteProfileID: profile.id,
        title: "模型选择回归",
        bodyMarkdown: "已有证据的文章正文。"
      )

      _ = try await service.perform(
        AIPublishingActionRequest(kind: .publishingReadiness, draft: draft, profile: profile),
        config: config,
        apiKey: nil
      )

      let request = await transport.capturedRequest()
      let capturedRequest = try XCTUnwrap(request)
      let payload = try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(capturedRequest.httpBody)) as? [String: Any]
      )
      XCTAssertEqual(payload["model"] as? String, config.model)
      XCTAssertEqual(capturedRequest.url?.host, URL(string: config.baseURL)?.host)
    }
  }
}
