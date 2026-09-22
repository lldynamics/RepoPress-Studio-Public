import Foundation
import PublishingAICore
import PublishingKnowledgeCore
import XCTest

@testable import PublishingWorkbenchCore

final class RSSTitleAITranslationTests: XCTestCase {
  func testTitleOnlyRequestMapsOpaqueBatchResultsBackToInputIDs() async throws {
    let transport = RSSTitleTranslationTestTransport()
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "test-model",
      requiresAPIKey: false
    )

    let result = try await service.translateRSSTitles(
      [
        RSSArticleTranslationTextRequest(id: "article-1", sourceText: "First title"),
        RSSArticleTranslationTextRequest(id: "article-2", sourceText: "Second title"),
      ],
      target: .simplifiedChinese,
      config: config,
      apiKey: nil
    )

    XCTAssertEqual(
      result,
      [
        "article-1": "翻译：First title",
        "article-2": "翻译：Second title",
      ])
    let capturedRequest = await transport.capturedRequest()
    let request = try XCTUnwrap(capturedRequest)
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let userContent = try XCTUnwrap(messages.last?["content"] as? String)
    XCTAssertTrue(userContent.contains("First title"))
    XCTAssertTrue(userContent.contains("Second title"))
    XCTAssertFalse(userContent.contains("article-1"))
    XCTAssertFalse(userContent.contains("article-2"))
    XCTAssertFalse(userContent.contains("summary"))
    XCTAssertFalse(userContent.contains("http"))
  }

  func testResultsMayBeFencedAndOutOfOrder() async throws {
    for mode in [RSSTitleResponseMode.reversed, .fenced] {
      let transport = RSSTitleTranslationTestTransport(mode: mode)
      let service = AIPublishingAssistantService(
        client: AIChatCompletionClient(transport: transport)
      )
      let result = try await service.translateRSSTitles(
        [
          RSSArticleTranslationTextRequest(id: "first", sourceText: "First"),
          RSSArticleTranslationTextRequest(id: "second", sourceText: "Second"),
        ],
        target: .english,
        config: testConfig,
        apiKey: nil
      )
      XCTAssertEqual(result, ["first": "翻译：First", "second": "翻译：Second"])
    }
  }

  func testPreservesOriginalWhitespaceInValidInputIDs() async throws {
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: RSSTitleTranslationTestTransport())
    )
    let result = try await service.translateRSSTitles(
      [RSSArticleTranslationTextRequest(id: " article-1 ", sourceText: "Title")],
      target: .english,
      config: testConfig,
      apiKey: nil
    )
    XCTAssertEqual(result, [" article-1 ": "翻译：Title"])
  }

  func testRejectsDuplicateIDsAndTitlesBeyondBatchLimit() async {
    let service = AIPublishingAssistantService()
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "test-model",
      requiresAPIKey: false
    )
    let duplicate = [
      RSSArticleTranslationTextRequest(id: "same", sourceText: "One"),
      RSSArticleTranslationTextRequest(id: "same", sourceText: "Two"),
    ]
    await XCTAssertThrowsErrorAsync(
      try await service.translateRSSTitles(
        duplicate, target: .english, config: config, apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? RSSTitleTranslationError, .invalidInput)
    }
    let tooMany = (0..<21).map {
      RSSArticleTranslationTextRequest(id: "id-\($0)", sourceText: "Title")
    }
    await XCTAssertThrowsErrorAsync(
      try await service.translateRSSTitles(
        tooMany, target: .english, config: config, apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? RSSTitleTranslationError, .tooManyTitles)
    }
  }

  func testRejectsUnknownOrMissingResponseIdentifiers() async {
    let transport = StaticRSSTitleTranslationTestTransport(
      response: "[{\"id\":\"unknown\",\"title\":\"Translated\"}]"
    )
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "test-model",
      requiresAPIKey: false
    )
    await XCTAssertThrowsErrorAsync(
      try await service.translateRSSTitles(
        [RSSArticleTranslationTextRequest(id: "one", sourceText: "Title")],
        target: .english,
        config: config,
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? RSSTitleTranslationError, .invalidResponse)
    }
  }

  func testRejectsMalformedFencedJSONWithoutCrashing() async {
    let transport = StaticRSSTitleTranslationTestTransport(response: "```json\n[]")
    let service = AIPublishingAssistantService(
      client: AIChatCompletionClient(transport: transport)
    )
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "test-model",
      requiresAPIKey: false
    )
    await XCTAssertThrowsErrorAsync(
      try await service.translateRSSTitles(
        [RSSArticleTranslationTextRequest(id: "one", sourceText: "Title")],
        target: .english,
        config: config,
        apiKey: nil
      )
    ) { error in
      XCTAssertEqual(error as? RSSTitleTranslationError, .invalidResponse)
    }
  }

  func testRejectsMissingDuplicateEmptyAndOversizedResponses() async {
    for mode in [RSSTitleResponseMode.missing, .duplicate, .empty, .oversized] {
      let service = AIPublishingAssistantService(
        client: AIChatCompletionClient(
          transport: RSSTitleTranslationTestTransport(mode: mode)
        )
      )
      await XCTAssertThrowsErrorAsync(
        try await service.translateRSSTitles(
          [
            RSSArticleTranslationTextRequest(id: "one", sourceText: "One"),
            RSSArticleTranslationTextRequest(id: "two", sourceText: "Two"),
          ],
          target: .english,
          config: testConfig,
          apiKey: nil
        )
      ) { error in
        XCTAssertEqual(error as? RSSTitleTranslationError, .invalidResponse)
      }
    }
  }

  private var testConfig: AIProviderConfig {
    AIProviderConfig(
      preset: .custom,
      baseURL: "https://api.example.com/v1",
      model: "test-model",
      requiresAPIKey: false
    )
  }
}

private enum RSSTitleResponseMode: Sendable {
  case ordered
  case reversed
  case fenced
  case missing
  case duplicate
  case empty
  case oversized
}

private actor RSSTitleTranslationTestTransport: AIChatTransport {
  private var request: URLRequest?
  private let mode: RSSTitleResponseMode

  init(mode: RSSTitleResponseMode = .ordered) {
    self.mode = mode
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    self.request = request
    let body = try XCTUnwrap(request.httpBody)
    let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
    let content = try XCTUnwrap(messages.last?["content"] as? String)
    let start = try XCTUnwrap(content.firstIndex(of: "["))
    let end = try XCTUnwrap(content.lastIndex(of: "]"))
    let source = String(content[start...end]).data(using: .utf8)!
    let entries = try JSONDecoder().decode([OpaqueTitleEntry].self, from: source)
    var response = entries.map {
      OpaqueTitleEntry(id: $0.id, title: "翻译：\($0.title)")
    }
    switch mode {
    case .ordered:
      break
    case .reversed:
      response.reverse()
    case .fenced:
      let encoded = String(data: try JSONEncoder().encode(response), encoding: .utf8)!
      return try makeAIResponse("```json\n\(encoded)\n```", request: request)
    case .missing:
      response.removeLast()
    case .duplicate:
      response.append(response[0])
    case .empty:
      response[0] = OpaqueTitleEntry(id: response[0].id, title: " ")
    case .oversized:
      response[0] = OpaqueTitleEntry(
        id: response[0].id,
        title: String(repeating: "x", count: 501)
      )
    }
    return try makeAIResponse(
      String(data: try JSONEncoder().encode(response), encoding: .utf8)!,
      request: request
    )
  }

  func capturedRequest() -> URLRequest? { request }
}

private struct OpaqueTitleEntry: Codable {
  let id: String
  let title: String
}

private actor StaticRSSTitleTranslationTestTransport: AIChatTransport {
  let response: String

  init(response: String) { self.response = response }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    try makeAIResponse(response, request: request)
  }
}

private func makeAIResponse(_ content: String, request: URLRequest) throws -> (Data, URLResponse) {
  let body = Data(
    "{\"choices\":[{\"message\":{\"content\":\(String(data: try JSONEncoder().encode(content), encoding: .utf8)!)}}]}"
      .utf8
  )
  let response = HTTPURLResponse(
    url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
  return (body, response)
}
