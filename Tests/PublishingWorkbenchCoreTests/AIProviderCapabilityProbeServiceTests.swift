import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIProviderCapabilityProbeServiceTests: XCTestCase {
  func testOpenAICompatibleOllamaLMStudioAndVLLMFixturesProbeChat() async throws {
    let fixtures: [(String, AIProviderConfig, String?)] = [
      (
        "openai-compatible",
        AIProviderConfig(
          preset: .openAICompatible,
          baseURL: "https://api.openai.example/v1",
          model: "gpt-fixture",
          requiresAPIKey: true
        ),
        "fixture-token"
      ),
      (
        "ollama",
        AIProviderConfig(
          preset: .local,
          baseURL: "http://127.0.0.1:11434/v1",
          model: "llama3.1",
          requiresAPIKey: false
        ),
        nil
      ),
      (
        "lm-studio",
        AIProviderConfig(
          preset: .local,
          baseURL: "http://127.0.0.1:1234/v1",
          model: "local-model",
          requiresAPIKey: false
        ),
        nil
      ),
      (
        "vllm",
        AIProviderConfig(
          preset: .local,
          baseURL: "http://127.0.0.1:8000/v1",
          model: "Qwen-fixture",
          requiresAPIKey: false
        ),
        nil
      ),
    ]

    for (name, config, apiKey) in fixtures {
      let transport = RecordingAIChatTransport(
        data: responseData(content: #"{"role":"assistant","content":"OK"}"#),
        statusCode: 200
      )
      let service = AIProviderCapabilityProbeService(
        client: AIChatCompletionClient(transport: transport),
        ttl: 60,
        now: { Date(timeIntervalSince1970: 100) }
      )

      let report = try await service.probe(
        config: config,
        apiKey: apiKey,
        capabilities: [.chat]
      )

      XCTAssertEqual(report.results[.chat]?.outcome, .supported, name)
      XCTAssertEqual(report.key.model, config.normalizedModel, name)
      XCTAssertEqual(report.key.endpointIdentity, config.capabilityEndpointIdentity, name)
      let requestCount = await transport.capturedRequestCount()
      XCTAssertEqual(requestCount, 1, name)
    }
  }

  func testProbeCacheBindsEndpointModelTTLAndSchemaVersion() async throws {
    let cache = AIProviderCapabilityProbeCache()
    let now = Date(timeIntervalSince1970: 1_000)
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"OK"}"#),
      statusCode: 200
    )
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "model-a",
      requiresAPIKey: false
    )
    let service = AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: transport),
      cache: cache,
      ttl: 60,
      now: { now }
    )

    let first = try await service.probe(
      config: config,
      apiKey: nil,
      capabilities: [.chat]
    )
    XCTAssertEqual(first.cacheState, .miss)
    XCTAssertFalse(first.results[.chat]?.fromCache ?? true)

    let hit = try await service.probe(
      config: config,
      apiKey: nil,
      capabilities: [.chat]
    )
    XCTAssertEqual(hit.cacheState, .hit)
    XCTAssertTrue(hit.results[.chat]?.fromCache ?? false)
    var requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 1)

    var changedModel = config
    changedModel.model = "model-b"
    let modelMiss = try await service.probe(
      config: changedModel,
      apiKey: nil,
      capabilities: [.chat]
    )
    XCTAssertEqual(modelMiss.cacheState, .miss)
    requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 2)

    var changedEndpoint = changedModel
    changedEndpoint.baseURL = "https://example.com:9443/v1"
    let endpointMiss = try await service.probe(
      config: changedEndpoint,
      apiKey: nil,
      capabilities: [.chat]
    )
    XCTAssertEqual(endpointMiss.cacheState, .miss)
    requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 3)

    let versionMiss = try await AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: transport),
      cache: cache,
      ttl: 60,
      now: { now },
      probeSchemaVersion: 2
    ).probe(
      config: config,
      apiKey: nil,
      capabilities: [.chat]
    )
    XCTAssertEqual(versionMiss.cacheState, .miss)
    XCTAssertEqual(versionMiss.key.probeSchemaVersion, 2)
    requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 4)

    let expired = try await AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: transport),
      cache: cache,
      ttl: 60,
      now: { now.addingTimeInterval(61) }
    ).probe(
      config: config,
      apiKey: nil,
      capabilities: [.chat]
    )
    XCTAssertEqual(expired.cacheState, .expired)
    requestCount = await transport.capturedRequestCount()
    XCTAssertEqual(requestCount, 5)
  }

  func testUnauthorizedRateLimitedAndServerErrorsRemainInconclusive() async throws {
    for statusCode in [401, 403, 429, 500, 502] {
      let transport = RecordingAIChatTransport(
        data: Data(#"{"error":"fixture"}"#.utf8),
        statusCode: statusCode
      )
      let service = AIProviderCapabilityProbeService(
        client: AIChatCompletionClient(transport: transport),
        now: { Date(timeIntervalSince1970: 100) }
      )
      let report = try await service.probe(
        config: fixtureConfig,
        apiKey: nil,
        capabilities: [.toolCalling]
      )

      XCTAssertEqual(report.results[.toolCalling]?.outcome, .inconclusive, "HTTP \(statusCode)")
      XCTAssertEqual(report.results[.toolCalling]?.statusCode, statusCode)
    }
  }

  func testCompatibilityRejectionIsUnsupportedButDoesNotMisclassifyAuth() async throws {
    for statusCode in [400, 404, 405, 422] {
      let transport = RecordingAIChatTransport(
        data: Data(#"{"error":"unsupported tools"}"#.utf8),
        statusCode: statusCode
      )
      let service = AIProviderCapabilityProbeService(
        client: AIChatCompletionClient(transport: transport),
        now: { Date(timeIntervalSince1970: 100) }
      )
      let report = try await service.probe(
        config: fixtureConfig,
        apiKey: nil,
        capabilities: [.toolCalling]
      )

      XCTAssertEqual(report.results[.toolCalling]?.outcome, .unsupported, "HTTP \(statusCode)")
    }

    let streamTransport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 400,
      streamLines: [#"{"error":{"message":"stream parameter is not supported"}}"#]
    )
    let streamReport = try await AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: streamTransport),
      now: { Date(timeIntervalSince1970: 100) }
    ).probe(
      config: fixtureConfig,
      apiKey: nil,
      capabilities: [.streamingResponse]
    )
    XCTAssertEqual(streamReport.results[.streamingResponse]?.outcome, .unsupported)
    let streamRequestCount = await streamTransport.capturedRequestCount()
    XCTAssertEqual(streamRequestCount, 1)
  }

  func testChatAndGenericCapabilityErrorsRemainInconclusive() async throws {
    let cases: [(AIProviderCapabilityProbeKind, Int, String)] = [
      (.chat, 400, #"{"error":{"message":"model does not exist"}}"#),
      (.toolCalling, 404, #"{"error":{"message":"route not found"}}"#),
      (.structuredOutput, 400, #"{"error":{"message":"invalid model name"}}"#),
    ]

    for (capability, statusCode, body) in cases {
      let report = try await AIProviderCapabilityProbeService(
        client: AIChatCompletionClient(
          transport: RecordingAIChatTransport(
            data: Data(body.utf8),
            statusCode: statusCode
          )
        ),
        now: { Date(timeIntervalSince1970: 100) }
      ).probe(
        config: fixtureConfig,
        apiKey: nil,
        capabilities: [capability]
      )

      let result = try XCTUnwrap(report.results[capability])
      XCTAssertEqual(result.outcome, .inconclusive, "\(capability) HTTP \(statusCode)")
      XCTAssertEqual(
        result.evidence.detail, AIProviderCapabilityRejectionClassifier.inconclusiveDetail)
      XCTAssertFalse(result.evidence.detail?.contains("model") ?? true)
      XCTAssertFalse(result.evidence.detail?.contains("route") ?? true)
    }
  }

  func testSelectableStreamingToolsStructuredOutputAndVisionFixtureProbe() async throws {
    let streamTransport = RecordingAIChatTransport(
      data: Data(),
      statusCode: 200,
      streamLines: [
        #"data: {"choices":[{"delta":{"content":"OK"},"finish_reason":"stop"}]}"#,
        "",
        "data: [DONE]",
        "",
      ]
    )
    let streamReport = try await AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: streamTransport),
      now: { Date(timeIntervalSince1970: 100) }
    ).probe(
      config: fixtureConfig,
      apiKey: nil,
      capabilities: [.streamingResponse]
    )
    XCTAssertEqual(streamReport.results[.streamingResponse]?.outcome, .supported)

    let toolTransport = RecordingAIChatTransport(
      data: responseData(
        content:
          #"{"role":"assistant","content":null,"tool_calls":[{"id":"call_probe","type":"function","function":{"name":"capability_probe","arguments":"{\"ok\":true}"}}]}"#
      ),
      statusCode: 200
    )
    let toolReport = try await AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: toolTransport),
      now: { Date(timeIntervalSince1970: 100) }
    ).probe(
      config: fixtureConfig,
      apiKey: nil,
      capabilities: [.toolCalling]
    )
    XCTAssertEqual(toolReport.results[.toolCalling]?.outcome, .supported)
    let toolRequest = await toolTransport.capturedRequest()
    let toolBody = try XCTUnwrap(toolRequest?.httpBody)
    let toolPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: toolBody) as? [String: Any])
    XCTAssertNotNil(toolPayload["tools"])

    let structuredTransport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"{\"ok\":true}"}"#),
      statusCode: 200
    )
    let structuredReport = try await AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: structuredTransport),
      now: { Date(timeIntervalSince1970: 100) }
    ).probe(
      config: fixtureConfig,
      apiKey: nil,
      capabilities: [.structuredOutput]
    )
    XCTAssertEqual(structuredReport.results[.structuredOutput]?.outcome, .supported)

    let visionTransport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"1x1"}"#),
      statusCode: 200
    )
    let visionReport = try await AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: visionTransport),
      now: { Date(timeIntervalSince1970: 100) }
    ).probe(
      config: fixtureConfig,
      apiKey: nil,
      capabilities: [.visionInput]
    )
    XCTAssertEqual(visionReport.results[.visionInput]?.outcome, .supported)
    let visionRequest = await visionTransport.capturedRequest()
    let visionBody = try XCTUnwrap(visionRequest?.httpBody)
    let visionBodyText = try XCTUnwrap(String(data: visionBody, encoding: .utf8))
    XCTAssertTrue(visionBodyText.contains("image_url"))
    let visionPayload = try XCTUnwrap(
      JSONSerialization.jsonObject(with: visionBody) as? [String: Any]
    )
    let visionMessages = try XCTUnwrap(visionPayload["messages"] as? [[String: Any]])
    let visionParts = try XCTUnwrap(visionMessages.first?["content"] as? [[String: Any]])
    let imagePart = try XCTUnwrap(
      visionParts.first(where: { $0["type"] as? String == "image_url" }))
    let imageURL = try XCTUnwrap(imagePart["image_url"] as? [String: Any])
    XCTAssertEqual(
      imageURL["url"] as? String,
      AIProviderCapabilityProbeService.syntheticVisionFixtureDataURL
    )
    XCTAssertFalse(visionBodyText.contains("user-image"))
  }

  func testVisionProbeWrongAnswerRemainsInconclusiveAndDoesNotPersistResponseBody() async throws {
    let transport = RecordingAIChatTransport(
      data: responseData(content: #"{"role":"assistant","content":"I cannot inspect images"}"#),
      statusCode: 200
    )
    let report = try await AIProviderCapabilityProbeService(
      client: AIChatCompletionClient(transport: transport),
      now: { Date(timeIntervalSince1970: 100) }
    ).probe(
      config: fixtureConfig,
      apiKey: nil,
      capabilities: [.visionInput]
    )

    let result = try XCTUnwrap(report.results[.visionInput])
    XCTAssertEqual(result.outcome, .inconclusive)
    XCTAssertEqual(
      result.evidence.detail, AIProviderCapabilityRejectionClassifier.inconclusiveDetail)
    XCTAssertNil(result.responsePreview)
    XCTAssertFalse(result.evidence.detail?.contains("cannot") ?? true)
  }

  private var fixtureConfig: AIProviderConfig {
    AIProviderConfig(
      preset: .custom,
      baseURL: "https://example.com/v1",
      model: "fixture-model",
      requiresAPIKey: false
    )
  }

  private func responseData(content: String) -> Data {
    Data(
      """
      {
        "model": "fixture-model",
        "choices": [
          { "message": \(content) }
        ]
      }
      """.utf8)
  }
}
