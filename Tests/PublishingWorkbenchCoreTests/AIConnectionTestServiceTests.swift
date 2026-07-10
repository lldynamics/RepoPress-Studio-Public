import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class AIConnectionTestServiceTests: XCTestCase {
  func testConnectionUsesOpenAICompatiblePingRequest() async throws {
    let transport = RecordingAIChatTransport(
      data: Data("""
      {
        "model": "deepseek-test",
        "choices": [
          {
            "message": {"role":"assistant","content":"OK"}
          }
        ]
      }
      """.utf8),
      statusCode: 200
    )
    let service = AIConnectionTestService(
      client: AIChatCompletionClient(transport: transport)
    )
    let config = AIProviderConfig(
      preset: .deepSeek,
      baseURL: "https://api.deepseek.com",
      model: "deepseek-v4-flash",
      requiresAPIKey: true
    )

    let report = try await service.testConnection(config: config, apiKey: "secret")

    XCTAssertEqual(report.providerName, "DeepSeek")
    XCTAssertEqual(report.model, "deepseek-test")
    XCTAssertEqual(report.endpoint.absoluteString, "https://api.deepseek.com/chat/completions")
    XCTAssertEqual(report.responsePreview, "OK")

    let requestFromTransport = await transport.capturedRequest()
    let capturedRequest = try XCTUnwrap(requestFromTransport)
    XCTAssertEqual(capturedRequest.url?.absoluteString, "https://api.deepseek.com/chat/completions")
    XCTAssertEqual(capturedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    let body = try XCTUnwrap(capturedRequest.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    XCTAssertEqual(payload["model"] as? String, "deepseek-v4-flash")
    XCTAssertNil(payload["temperature"])
    XCTAssertNil(payload["reasoning_effort"])
    let thinking = try XCTUnwrap(payload["thinking"] as? [String: Any])
    XCTAssertEqual(thinking["type"] as? String, "disabled")
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    XCTAssertTrue(messages.contains { $0["content"] as? String == "ping" })
  }

  func testConnectionRequiresAPIKeyWhenConfigured() async {
    let transport = RecordingAIChatTransport(data: Data(), statusCode: 200)
    let service = AIConnectionTestService(
      client: AIChatCompletionClient(transport: transport)
    )

    await XCTAssertThrowsErrorAsync(
      try await service.testConnection(config: AIProviderConfig(), apiKey: " ")
    ) { error in
      XCTAssertEqual(error as? AIConnectionTestError, .missingAPIKey)
    }
  }

  func testAISettingsConnectionPresentationMatchesMobileReadinessStates() throws {
    let remoteConfig = AIProviderConfig(
      preset: .deepSeek,
      baseURL: "https://api.deepseek.com",
      model: "deepseek-v4-flash",
      requiresAPIKey: true
    )

    let missingToken = AISettingsConnectionPresentationService.presentation(
      config: remoteConfig,
      tokenAvailability: KeychainTokenAvailability(hasToken: false),
      report: nil
    )

    XCTAssertEqual(missingToken.title, "AI API Key 未就绪")
    XCTAssertEqual(missingToken.level, .warning)
    XCTAssertEqual(missingToken.systemImage, "key")
    XCTAssertTrue(missingToken.footnote.contains("DeepSeek 默认 base_url"))

    let untestedRemote = AISettingsConnectionPresentationService.presentation(
      config: remoteConfig,
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      report: nil
    )

    XCTAssertEqual(untestedRemote.title, "AI 连接尚未测试")
    XCTAssertEqual(untestedRemote.level, .info)
    XCTAssertEqual(untestedRemote.systemImage, "network")

    let localConfig = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "llama3.1",
      requiresAPIKey: false
    )
    let untestedLocal = AISettingsConnectionPresentationService.presentation(
      config: localConfig,
      tokenAvailability: KeychainTokenAvailability(hasToken: false),
      report: nil
    )

    XCTAssertEqual(untestedLocal.level, .info)
    XCTAssertTrue(untestedLocal.footnote.contains("本地模型默认不需要 API Key"))

    let report = AIConnectionTestReport(
      providerName: "DeepSeek",
      model: "deepseek-test",
      endpoint: try XCTUnwrap(URL(string: "https://api.deepseek.com/chat/completions")),
      responsePreview: "OK"
    )
    let success = AISettingsConnectionPresentationService.presentation(
      config: remoteConfig,
      tokenAvailability: KeychainTokenAvailability(hasToken: true),
      report: report
    )

    XCTAssertEqual(success.title, "DeepSeek 连接正常")
    XCTAssertEqual(success.level, .success)
    XCTAssertEqual(success.systemImage, "checkmark.circle")
    XCTAssertTrue(success.message.contains("deepseek-test"))
  }
}
