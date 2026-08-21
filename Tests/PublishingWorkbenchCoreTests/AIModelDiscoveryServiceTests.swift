import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIModelDiscoveryServiceTests: XCTestCase {
  @MainActor
  func testStoreRejectsUnappliedEndpointBeforeReadingCredentialOrTransport() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AIModelDiscoveryIdentityTests")
    let connection = store.activeAIConnectionProfile
    var requestedConfig = connection.config
    requestedConfig.baseURL = "https://different.example/v1"
    let endpoint = URL(string: "https://different.example/v1/models")!
    let transport = ModelDiscoveryStubTransport(
      data: Data(#"{"data":[]}"#.utf8),
      response: httpResponse(url: endpoint)
    )
    let service = AIModelDiscoveryService(transport: transport)

    do {
      _ = try await store.aiStore.discoverAIModels(
        forConnectionProfileID: connection.id,
        requestedConfig: requestedConfig,
        service: service
      )
      XCTFail("Expected credential destination mismatch")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error, .configurationChanged)
      XCTAssertNil(transport.lastRequest)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  @MainActor
  func testStoreUsesAppliedProxyWhenRequestedConfigOmitsAdvancedSettings() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AIModelDiscoveryProxyBindingTests")
    var connection = store.activeAIConnectionProfile
    let expectedProxy = "socks5://127.0.0.1:1080"
    connection.config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "llama3.2",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(proxyURL: expectedProxy)
    )
    XCTAssertTrue(store.updateAIConnectionProfile(connection))

    var requestedConfig = connection.config
    requestedConfig.advancedSettings = nil
    let endpoint = URL(string: "http://127.0.0.1:11434/api/tags")!
    let transport = ModelDiscoveryStubTransport(
      data: Data(#"{"models":[{"name":"proxy-model"}]}"#.utf8),
      response: httpResponse(url: endpoint)
    )
    let service = AIModelDiscoveryService(
      cache: AIModelDiscoveryCache(),
      defaultTransportFactory: { proxyURL in
        guard proxyURL == expectedProxy else {
          throw ModelDiscoveryStubError.invalidProxyConfiguration
        }
        return transport
      }
    )

    let models = try await store.aiStore.discoverAIModels(
      forConnectionProfileID: connection.id,
      requestedConfig: requestedConfig,
      service: service
    )

    XCTAssertEqual(models.map(\.id), ["proxy-model"])
    XCTAssertNotNil(transport.lastRequest)
  }

  @MainActor
  func testStoreRejectsResultWhenAppliedProxyChangesDuringRequest() async throws {
    let store = try TestWorkbenchFactory.makeStore(prefix: "AIModelDiscoveryProxyDriftTests")
    var connection = store.activeAIConnectionProfile
    let initialProxy = "socks5://127.0.0.1:1080"
    connection.config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "llama3.2",
      requiresAPIKey: false,
      advancedSettings: AIProviderAdvancedSettings(proxyURL: initialProxy)
    )
    XCTAssertTrue(store.updateAIConnectionProfile(connection))

    var requestedConfig = connection.config
    requestedConfig.advancedSettings = nil
    let endpoint = URL(string: "http://127.0.0.1:11434/api/tags")!
    let barrier = ModelDiscoveryRequestBarrier()
    let transport = BlockingModelDiscoveryStubTransport(
      barrier: barrier,
      data: Data(#"{"models":[{"name":"stale-proxy-result"}]}"#.utf8),
      response: httpResponse(url: endpoint)
    )
    let service = AIModelDiscoveryService(
      transport: transport,
      cache: AIModelDiscoveryCache()
    )

    let requestTask = Task {
      try await store.aiStore.discoverAIModels(
        forConnectionProfileID: connection.id,
        requestedConfig: requestedConfig,
        service: service
      )
    }
    await barrier.waitUntilEntered()

    var changedConnection = store.activeAIConnectionProfile
    changedConnection.config.advancedSettings = AIProviderAdvancedSettings(
      proxyURL: "socks5://127.0.0.1:1081"
    )
    XCTAssertTrue(store.updateAIConnectionProfile(changedConnection))
    await barrier.release()

    do {
      _ = try await requestTask.value
      XCTFail("Expected applied proxy drift rejection")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error, .configurationChanged)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testOpenAIUsesBearerHeaderAndParsesModels() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let transport = ModelDiscoveryStubTransport(
      data: Data(#"{"data":[{"id":"gpt-4o"}]}"#.utf8),
      response: httpResponse(url: endpoint)
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    let models = try await service.discoverModels(for: config, apiKey: "sk-test-model-key")

    XCTAssertEqual(models.map(\.id), ["gpt-4o"])
    XCTAssertEqual(
      transport.lastRequest?.value(forHTTPHeaderField: "Authorization"),
      "Bearer sk-test-model-key"
    )
    XCTAssertNil(transport.lastRequest?.value(forHTTPHeaderField: "x-api-key"))
  }

  func testAnthropicUsesAPIKeyAndVersionHeaders() async throws {
    let endpoint = URL(string: "https://api.anthropic.com/v1/models")!
    let transport = ModelDiscoveryStubTransport(
      data: Data(#"{"data":[{"id":"claude-sonnet-4-6"}]}"#.utf8),
      response: httpResponse(url: endpoint)
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .anthropic,
      baseURL: "https://api.anthropic.com/v1",
      model: "claude-sonnet-4-6",
      requiresAPIKey: true
    )

    _ = try await service.discoverModels(for: config, apiKey: "anthropic-secret-key")

    XCTAssertEqual(
      transport.lastRequest?.value(forHTTPHeaderField: "x-api-key"),
      "anthropic-secret-key"
    )
    XCTAssertEqual(
      transport.lastRequest?.value(forHTTPHeaderField: "anthropic-version"),
      "2023-06-01"
    )
    XCTAssertNil(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"))
  }

  func testDefaultTransportFactoryReceivesProfileProxy() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let expectedProxy = "socks5://127.0.0.1:1080"
    let transport = ModelDiscoveryStubTransport(
      data: openAIPage(ids: ["proxy-model"], hasMore: false),
      response: httpResponse(url: endpoint)
    )
    let service = AIModelDiscoveryService(
      cache: AIModelDiscoveryCache(),
      defaultTransportFactory: { proxyURL in
        guard proxyURL == expectedProxy else {
          throw ModelDiscoveryStubError.invalidProxyConfiguration
        }
        return transport
      }
    )
    var config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )
    config.advancedSettings = AIProviderAdvancedSettings(proxyURL: expectedProxy)

    let models = try await service.discoverModels(
      for: config,
      apiKey: "proxy-profile-key"
    )

    XCTAssertEqual(models.map(\.id), ["proxy-model"])
    XCTAssertNotNil(transport.lastRequest)
  }

  func testInvalidProxyFailsClosedBeforeAnyTransportRequest() async {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let transport = ModelDiscoveryStubTransport(
      data: openAIPage(ids: ["should-not-be-requested"], hasMore: false),
      response: httpResponse(url: endpoint)
    )
    let invalidProxy = "ftp://proxy.example:1080"
    let service = AIModelDiscoveryService(
      cache: AIModelDiscoveryCache(),
      defaultTransportFactory: { proxyURL in
        guard proxyURL == invalidProxy else {
          throw ModelDiscoveryStubError.invalidProxyConfiguration
        }
        throw ModelDiscoveryStubError.invalidProxyConfiguration
      }
    )
    var config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )
    config.advancedSettings = AIProviderAdvancedSettings(proxyURL: invalidProxy)

    do {
      _ = try await service.discoverModels(for: config, apiKey: "proxy-profile-key")
      XCTFail("Expected invalid proxy rejection")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error, .invalidProxyURL)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
    XCTAssertNil(transport.lastRequest)
    XCTAssertThrowsError(try URLSessionAIModelDiscoveryTransport(proxyURL: invalidProxy))
  }

  func testLocalDiscoveryDoesNotSendCredential() async throws {
    let endpoint = URL(string: "http://127.0.0.1:11434/api/tags")!
    let transport = ModelDiscoveryStubTransport(
      data: Data(#"{"models":[{"name":"llama3.2"}]}"#.utf8),
      response: httpResponse(url: endpoint)
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .local,
      baseURL: "http://127.0.0.1:11434/v1",
      model: "llama3.2",
      requiresAPIKey: false
    )

    let models = try await service.discoverModels(for: config, apiKey: nil)

    XCTAssertEqual(models.map(\.id), ["llama3.2"])
    XCTAssertNil(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(transport.lastRequest?.value(forHTTPHeaderField: "x-api-key"))
    XCTAssertEqual(transport.lastRequest?.url?.path, "/api/tags")
  }

  func testCredentialedExternalHTTPIsRejectedBeforeTransport() async {
    let transport = ModelDiscoveryStubTransport(
      data: Data(),
      response: httpResponse(url: URL(string: "http://example.com/models")!)
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .custom,
      baseURL: "http://example.com/v1",
      model: "custom",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: "secret-key")
      XCTFail("Expected insecure endpoint rejection")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error, .insecureEndpoint)
      XCTAssertNil(transport.lastRequest)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCrossOriginRedirectIsRejected() async {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let redirectEndpoint = URL(string: "https://attacker.example/models")!
    let transport = ModelDiscoveryStubTransport(
      data: Data(#"{"data":[]}"#.utf8),
      response: httpResponse(url: redirectEndpoint)
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: endpoint.deletingLastPathComponent().absoluteString,
      model: "gpt-4o",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: "secret-key")
      XCTFail("Expected cross-origin redirect rejection")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error, .redirectBlocked)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testBlockedRedirectStatusIsNotPresentedAsOrdinaryHTTPError() async {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let transport = ModelDiscoveryStubTransport(
      data: Data(),
      response: httpResponse(
        url: endpoint,
        statusCode: 302,
        headers: ["Location": "https://attacker.example/models"]
      )
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: "secret-key")
      XCTFail("Expected redirect rejection")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error, .redirectBlocked)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testResponseLimitIsEnforced() async {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let data = Data(repeating: 0x61, count: AIModelDiscoveryService.maximumResponseByteCount + 1)
    let transport = ModelDiscoveryStubTransport(
      data: data,
      response: httpResponse(url: endpoint, contentLength: data.count)
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: "secret-key")
      XCTFail("Expected response limit rejection")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(
        error,
        .responseTooLarge(maximumBytes: AIModelDiscoveryService.maximumResponseByteCount)
      )
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testHTTPErrorBodyDoesNotLeakAPIKey() async {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let apiKey = "super-secret-model-key"
    let body = Data("invalid key: \(apiKey)".utf8)
    let transport = ModelDiscoveryStubTransport(
      data: body,
      response: httpResponse(url: endpoint, statusCode: 401, contentLength: body.count)
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: apiKey)
      XCTFail("Expected HTTP error")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error.localizedDescription.contains(apiKey), false)
      XCTAssertEqual(error.localizedDescription.contains("[REDACTED]"), true)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testRateLimitPreservesDeltaSecondsRetryAfter() async {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let transport = ModelDiscoveryStubTransport(
      data: Data(#"{"error":"busy"}"#.utf8),
      response: httpResponse(
        url: endpoint,
        statusCode: 429,
        headers: ["Retry-After": "7"]
      )
    )
    let service = AIModelDiscoveryService(transport: transport)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: "secret-key")
      XCTFail("Expected rate limit error")
    } catch let error as AIModelDiscoveryError {
      guard case .httpStatus(_, _, let retryAfterSeconds) = error else {
        return XCTFail("Expected HTTP status error")
      }
      XCTAssertEqual(retryAfterSeconds, 7)
      XCTAssertTrue(error.localizedDescription.contains("7 秒"))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testOpenAIPaginationAggregatesPagesAndRebuildsSameOriginCursorURL() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let secondURL = URL(string: "https://api.openai.com/v1/models?after=cursor-1")!
    let transport = ModelDiscoveryStubTransport(
      pages: [
        (
          openAIPage(ids: ["gpt-a"], hasMore: true, lastID: "cursor-1"),
          httpResponse(url: endpoint)
        ),
        (
          openAIPage(ids: ["gpt-b"], hasMore: false),
          httpResponse(url: secondURL)
        ),
      ]
    )
    let service = AIModelDiscoveryService(
      transport: transport,
      cache: AIModelDiscoveryCache()
    )
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    let models = try await service.discoverModels(
      for: config,
      apiKey: "pagination-key"
    )

    XCTAssertEqual(models.map(\.id), ["gpt-a", "gpt-b"])
    XCTAssertEqual(transport.requests.count, 2)
    XCTAssertEqual(transport.requests[1].url, secondURL)
    XCTAssertEqual(
      transport.requests[1].value(forHTTPHeaderField: "Authorization"),
      "Bearer pagination-key"
    )
  }

  func testAnthropicPaginationUsesAfterIDAndBoundedLimit() async throws {
    let endpoint = URL(string: "https://api.anthropic.com/v1/models")!
    let secondURL = URL(
      string: "https://api.anthropic.com/v1/models?after_id=first-page&limit=1000")!
    let transport = ModelDiscoveryStubTransport(
      pages: [
        (
          openAIPage(ids: ["claude-sonnet-4-6"], hasMore: true, lastID: "first-page"),
          httpResponse(url: endpoint)
        ),
        (
          openAIPage(ids: ["claude-opus-4-1"], hasMore: false),
          httpResponse(url: secondURL)
        ),
      ]
    )
    let service = AIModelDiscoveryService(
      transport: transport,
      cache: AIModelDiscoveryCache()
    )
    let config = AIProviderConfig(
      preset: .anthropic,
      baseURL: "https://api.anthropic.com/v1",
      model: "claude-sonnet-4-6",
      requiresAPIKey: true
    )

    let models = try await service.discoverModels(
      for: config,
      apiKey: "anthropic-pagination-key"
    )

    XCTAssertEqual(models.map(\.id), ["claude-opus-4-1", "claude-sonnet-4-6"])
    XCTAssertEqual(transport.requests.count, 2)
    XCTAssertEqual(transport.requests[1].url, secondURL)
    XCTAssertNil(
      URLComponents(url: secondURL, resolvingAgainstBaseURL: false)?.queryItems?.first {
        $0.name == "after"
      })
    XCTAssertEqual(
      transport.requests[1].value(forHTTPHeaderField: "x-api-key"),
      "anthropic-pagination-key"
    )
  }

  func testPaginationIgnoresProviderNextURLAndKeepsCursorRequestSameOrigin() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let providerSuppliedURL = "https://attacker.example/models?key=ignored"
    let transport = ModelDiscoveryStubTransport(
      pages: [
        (
          openAIPage(ids: ["first-model"], hasMore: true, lastID: providerSuppliedURL),
          httpResponse(url: endpoint)
        ),
        (
          openAIPage(ids: ["second-model"], hasMore: false),
          // The stub does not need to emulate the exact query in the response
          // URL; the origin check intentionally ignores path/query changes.
          httpResponse(url: endpoint)
        ),
      ]
    )
    let service = AIModelDiscoveryService(
      transport: transport,
      cache: AIModelDiscoveryCache()
    )
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    _ = try await service.discoverModels(for: config, apiKey: "same-origin-key")

    let secondRequestURL = try XCTUnwrap(transport.requests[1].url)
    XCTAssertEqual(secondRequestURL.host, "api.openai.com")
    XCTAssertEqual(
      URLComponents(url: secondRequestURL, resolvingAgainstBaseURL: false)?.queryItems?.first {
        $0.name == "after"
      }?.value,
      providerSuppliedURL
    )
  }

  func testRepeatedCursorFailsAndDoesNotPopulateCache() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let repeatedURL = URL(string: "https://api.openai.com/v1/models?after=repeated")!
    let successData = openAIPage(ids: ["fresh-model"], hasMore: false)
    let transport = ModelDiscoveryStubTransport(
      results: [
        .success(
          (
            openAIPage(ids: ["first-model"], hasMore: true, lastID: "repeated"),
            httpResponse(url: endpoint)
          )),
        .success(
          (
            openAIPage(ids: ["second-model"], hasMore: true, lastID: "repeated"),
            httpResponse(url: repeatedURL)
          )),
        .success((successData, httpResponse(url: endpoint))),
      ]
    )
    let cache = AIModelDiscoveryCache()
    let service = AIModelDiscoveryService(transport: transport, cache: cache)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: "loop-key")
      XCTFail("Expected repeated cursor rejection")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error, .paginationLoop)
    }

    let freshModels = try await service.discoverModels(
      for: config,
      apiKey: "loop-key",
      forceRefresh: false
    )
    XCTAssertEqual(freshModels.map(\.id), ["fresh-model"])
    XCTAssertEqual(transport.requests.count, 3, "Failed pagination must not be served from cache")
  }

  func testPaginationStopsAtMaximumPageCount() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    var pages: [(Data, URLResponse)] = []
    for index in 0..<AIModelDiscoveryService.maximumPageCount {
      let requestURL =
        index == 0
        ? endpoint
        : URL(string: "https://api.openai.com/v1/models?after=cursor-\(index - 1)")!
      pages.append(
        (
          openAIPage(ids: ["model-\(index)"], hasMore: true, lastID: "cursor-\(index)"),
          httpResponse(url: requestURL)
        ))
    }
    let transport = ModelDiscoveryStubTransport(pages: pages)
    let service = AIModelDiscoveryService(
      transport: transport,
      cache: AIModelDiscoveryCache()
    )
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: "page-limit-key")
      XCTFail("Expected page limit rejection")
    } catch let error as AIModelDiscoveryError {
      XCTAssertEqual(error, .paginationLimitExceeded)
    }
    XCTAssertEqual(transport.requests.count, AIModelDiscoveryService.maximumPageCount)
  }

  func testModelCatalogIsBoundedAndTruncatedResultIsNotCached() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let manyIDs = (0...AIModelDiscoveryService.maximumModelCount).map { "model-\($0)" }
    let transport = ModelDiscoveryStubTransport(
      pages: [
        (openAIPage(ids: manyIDs, hasMore: false), httpResponse(url: endpoint)),
        (openAIPage(ids: ["fresh-model"], hasMore: false), httpResponse(url: endpoint)),
      ]
    )
    let cache = AIModelDiscoveryCache()
    let service = AIModelDiscoveryService(transport: transport, cache: cache)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    let bounded = try await service.discoverModels(for: config, apiKey: "bounded-key")
    XCTAssertEqual(bounded.count, AIModelDiscoveryService.maximumModelCount)

    let fresh = try await service.discoverModels(
      for: config,
      apiKey: "bounded-key",
      forceRefresh: false
    )
    XCTAssertEqual(fresh.map(\.id), ["fresh-model"])
    XCTAssertEqual(transport.requests.count, 2, "Truncated catalogs must not be cached")
  }

  func testCacheSeparatesCredentialAccountsAndReusesMatchingAccount() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let cache = AIModelDiscoveryCache(ttl: 60, maximumEntryCount: 4)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )
    let firstTransport = ModelDiscoveryStubTransport(
      data: openAIPage(ids: ["account-a-model"], hasMore: false),
      response: httpResponse(url: endpoint)
    )
    let firstService = AIModelDiscoveryService(transport: firstTransport, cache: cache)
    _ = try await firstService.discoverModels(
      for: config,
      apiKey: "account-a-key"
    )

    let secondTransport = ModelDiscoveryStubTransport(
      data: openAIPage(ids: ["account-b-model"], hasMore: false),
      response: httpResponse(url: endpoint)
    )
    let secondService = AIModelDiscoveryService(transport: secondTransport, cache: cache)
    let accountBModels = try await secondService.discoverModels(
      for: config,
      apiKey: "account-b-key",
      forceRefresh: false
    )
    XCTAssertEqual(accountBModels.map(\.id), ["account-b-model"])
    XCTAssertEqual(secondTransport.requests.count, 1)

    let noNetworkTransport = ModelDiscoveryStubTransport(
      error: ModelDiscoveryStubError.unexpectedRequest)
    let noNetworkService = AIModelDiscoveryService(transport: noNetworkTransport, cache: cache)
    let accountAModels = try await noNetworkService.discoverModels(
      for: config,
      apiKey: "account-a-key",
      forceRefresh: false
    )
    XCTAssertEqual(accountAModels.map(\.id), ["account-a-model"])
    XCTAssertNil(noNetworkTransport.lastRequest)
  }

  func testCacheExpiresEntriesAndEvictsLeastRecentlyUsedKeys() async {
    let cache = AIModelDiscoveryCache(ttl: 10, maximumEntryCount: 1)
    let now = Date(timeIntervalSince1970: 10_000)
    let modelA = [AIModelDescriptor(id: "model-a")]
    let modelB = [AIModelDescriptor(id: "model-b")]

    _ = await cache.insert(modelA, for: "opaque-a", now: now)
    let stillFresh = await cache.value(for: "opaque-a", now: now.addingTimeInterval(9))
    XCTAssertEqual(stillFresh, modelA)
    _ = await cache.insert(modelB, for: "opaque-b", now: now.addingTimeInterval(9))
    let evictedA = await cache.value(for: "opaque-a", now: now.addingTimeInterval(9))
    XCTAssertNil(evictedA)
    let freshB = await cache.value(for: "opaque-b", now: now.addingTimeInterval(9))
    XCTAssertEqual(freshB, modelB)
    let expiredB = await cache.value(for: "opaque-b", now: now.addingTimeInterval(19))
    XCTAssertNil(expiredB)
  }

  func testCacheGenerationDoesNotRemoveConcurrentReplacement() async throws {
    let cache = AIModelDiscoveryCache()
    let first = [AIModelDescriptor(id: "first-refresh")]
    let replacement = [AIModelDescriptor(id: "replacement-refresh")]

    let optionalFirstToken = await cache.insert(first, for: "same-account")
    let firstToken = try XCTUnwrap(optionalFirstToken)
    _ = await cache.insert(replacement, for: "same-account")
    await cache.removeValue(for: "same-account", ifGeneration: firstToken)

    let cachedReplacement = await cache.value(for: "same-account")?.map(\.id)
    XCTAssertEqual(
      cachedReplacement,
      ["replacement-refresh"]
    )
  }

  func testCancellationDuringPaginationDoesNotCachePartialModels() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let transport = ModelDiscoveryStubTransport(
      results: [
        .success(
          (
            openAIPage(ids: ["partial-model"], hasMore: true, lastID: "next"),
            httpResponse(url: endpoint)
          )),
        .failure(CancellationError()),
        .success(
          (
            openAIPage(ids: ["fresh-model"], hasMore: false),
            httpResponse(url: endpoint)
          )),
      ]
    )
    let cache = AIModelDiscoveryCache()
    let service = AIModelDiscoveryService(transport: transport, cache: cache)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )

    do {
      _ = try await service.discoverModels(for: config, apiKey: "cancel-key")
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected: the first page must not be persisted as a partial result.
    }

    let freshModels = try await service.discoverModels(
      for: config,
      apiKey: "cancel-key",
      forceRefresh: false
    )
    XCTAssertEqual(freshModels.map(\.id), ["fresh-model"])
    XCTAssertEqual(transport.requests.count, 3)
  }

  func testCancellationDuringCacheInsertionRemovesOnlyThatRefreshEntry() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let insertionBarrier = CacheInsertionBarrier()
    let cache = AIModelDiscoveryCache(
      insertionBarrier: { await insertionBarrier.waitForFirstInsertion() }
    )
    let transport = ModelDiscoveryStubTransport(
      results: [
        .success(
          (
            openAIPage(ids: ["cancelled-model"], hasMore: false),
            httpResponse(url: endpoint)
          )),
        .success(
          (
            openAIPage(ids: ["network-model"], hasMore: false),
            httpResponse(url: endpoint)
          )),
      ]
    )
    let service = AIModelDiscoveryService(transport: transport, cache: cache)
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )
    let discoveryTask = Task<[AIModelDescriptor], Error> {
      try await service.discoverModels(for: config, apiKey: "insertion-cancel-key")
    }

    await insertionBarrier.waitUntilEntered()
    discoveryTask.cancel()
    await insertionBarrier.release()

    do {
      _ = try await discoveryTask.value
      XCTFail("Expected cancellation during cache insertion")
    } catch is CancellationError {
      // The cache insertion window was crossed while cancellation was active.
    }

    let networkModels = try await service.discoverModels(
      for: config,
      apiKey: "insertion-cancel-key",
      forceRefresh: false
    )
    XCTAssertEqual(networkModels.map(\.id), ["network-model"])
    XCTAssertEqual(
      transport.requests.count,
      2,
      "A cancelled insertion must be removed rather than served from cache"
    )
  }

  func testFailedRequestDoesNotCacheResult() async throws {
    let endpoint = URL(string: "https://api.openai.com/v1/models")!
    let cache = AIModelDiscoveryCache()
    let config = AIProviderConfig(
      preset: .openAICompatible,
      baseURL: "https://api.openai.com/v1",
      model: "gpt-4o",
      requiresAPIKey: true
    )
    let transport = ModelDiscoveryStubTransport(
      results: [
        .failure(ModelDiscoveryStubError.failed),
        .success(
          (
            openAIPage(ids: ["recovered-model"], hasMore: false),
            httpResponse(url: endpoint)
          )),
      ]
    )
    let service = AIModelDiscoveryService(transport: transport, cache: cache)

    do {
      _ = try await service.discoverModels(for: config, apiKey: "failure-key")
      XCTFail("Expected transport failure")
    } catch is ModelDiscoveryStubError {
      // Expected.
    }

    let recovered = try await service.discoverModels(
      for: config,
      apiKey: "failure-key",
      forceRefresh: false
    )
    XCTAssertEqual(recovered.map(\.id), ["recovered-model"])
    XCTAssertEqual(transport.requests.count, 2)
  }

  private func httpResponse(
    url: URL,
    statusCode: Int = 200,
    contentLength: Int? = nil,
    headers additionalHeaders: [String: String] = [:]
  ) -> HTTPURLResponse {
    var headers = additionalHeaders
    if let contentLength {
      headers["Content-Length"] = String(contentLength)
    }
    return HTTPURLResponse(
      url: url,
      statusCode: statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: headers
    )!
  }

  private func openAIPage(
    ids: [String],
    hasMore: Bool,
    lastID: String? = nil
  ) -> Data {
    var payload: [String: Any] = [
      "data": ids.map { ["id": $0] },
      "has_more": hasMore,
    ]
    if let lastID {
      payload["last_id"] = lastID
    }
    return try! JSONSerialization.data(withJSONObject: payload)
  }
}

private final class ModelDiscoveryStubTransport: @unchecked Sendable, AIModelDiscoveryTransport {
  private var results: [Result<(Data, URLResponse), Error>]
  private(set) var lastRequest: URLRequest?
  private(set) var requests: [URLRequest] = []

  init(data: Data, response: URLResponse) {
    results = [.success((data, response))]
  }

  init(pages: [(Data, URLResponse)]) {
    results = pages.map { .success($0) }
  }

  init(results: [Result<(Data, URLResponse), Error>]) {
    self.results = results
  }

  init(error: Error) {
    results = [.failure(error)]
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    lastRequest = request
    requests.append(request)
    guard !results.isEmpty else {
      throw ModelDiscoveryStubError.unexpectedRequest
    }
    return try results.removeFirst().get()
  }
}

private final class BlockingModelDiscoveryStubTransport: @unchecked Sendable,
  AIModelDiscoveryTransport
{
  private let barrier: ModelDiscoveryRequestBarrier
  private let dataValue: Data
  private let response: URLResponse

  init(barrier: ModelDiscoveryRequestBarrier, data: Data, response: URLResponse) {
    self.barrier = barrier
    dataValue = data
    self.response = response
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    await barrier.waitForRelease()
    return (dataValue, response)
  }
}

private enum ModelDiscoveryStubError: Error {
  case failed
  case unexpectedRequest
  case invalidProxyConfiguration
}

private actor ModelDiscoveryRequestBarrier {
  private var hasEntered = false
  private var isReleased = false
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func waitForRelease() async {
    hasEntered = true
    enteredContinuation?.resume()
    enteredContinuation = nil
    guard !isReleased else { return }
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !hasEntered else { return }
    await withCheckedContinuation { continuation in
      enteredContinuation = continuation
    }
  }

  func release() {
    isReleased = true
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor CacheInsertionBarrier {
  private var blocksNextInsertion = true
  private var entered = false
  private var enteredContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func waitForFirstInsertion() async {
    guard blocksNextInsertion else { return }
    blocksNextInsertion = false
    entered = true
    enteredContinuation?.resume()
    enteredContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    guard !entered else { return }
    await withCheckedContinuation { continuation in
      enteredContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}
