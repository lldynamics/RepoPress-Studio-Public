import Darwin
import Foundation
import PublishingAICore
import PublishingWorkbenchCore
import XCTest

@testable import PublishingMCPClient

final class PublishingMCPClientTests: XCTestCase {
  override func setUp() {
    super.setUp()
    setenv("MCP_TEST_SECRET", "host-secret-must-not-leak", 1)
  }

  override func tearDown() {
    unsetenv("MCP_TEST_SECRET")
    super.tearDown()
  }

  func testSpawnAttributesRequestAtomicIsolatedProcessGroup() throws {
    var attributes: posix_spawnattr_t?
    XCTAssertEqual(posix_spawnattr_init(&attributes), 0)
    defer { posix_spawnattr_destroy(&attributes) }

    XCTAssertEqual(PublishingMCPProcessLauncher.configureSpawnAttributes(&attributes), 0)
    var flags: Int16 = 0
    var processGroup: pid_t = -1
    XCTAssertEqual(posix_spawnattr_getflags(&attributes, &flags), 0)
    XCTAssertEqual(posix_spawnattr_getpgroup(&attributes, &processGroup), 0)
    XCTAssertNotEqual(flags & Int16(POSIX_SPAWN_SETPGROUP), 0)
    XCTAssertNotEqual(flags & Int16(POSIX_SPAWN_CLOEXEC_DEFAULT), 0)
    XCTAssertEqual(processGroup, 0)
  }

  func testConnectDiscoverAndCallEchoWithoutInheritingSecret() async throws {
    let configuration = try fixtureConfiguration()
    let client = PublishingMCPClient(configuration: configuration)
    let tools = try await client.discoverTools()
    XCTAssertEqual(tools.map(\.remoteName), ["echo"])

    let echoed = try await client.call(remoteToolName: "echo", argumentsJSON: #"{"text":"hello"}"#)
    XCTAssertEqual(echoed.content, "hello")
    XCTAssertFalse(echoed.isError)

    let secret = try await client.call(remoteToolName: "echo", argumentsJSON: #"{"text":"secret"}"#)
    XCTAssertEqual(secret.content, "missing")
    await client.disconnect()
  }

  func testSpawnedServerRunsInItsOwnProcessGroup() async throws {
    let client = PublishingMCPClient(configuration: try fixtureConfiguration())
    _ = try await client.discoverTools()
    let result = try await client.call(
      remoteToolName: "echo",
      argumentsJSON: #"{"text":"process_identity"}"#
    )
    let components: [String: Int32] = Dictionary(
      uniqueKeysWithValues: result.content.split(separator: ",").compactMap { component in
        let pair = component.split(separator: ":", maxSplits: 1)
        guard pair.count == 2, let value = Int32(pair[1]) else { return nil }
        return (String(pair[0]), value)
      }
    )
    XCTAssertEqual(components["pid"], components["pgrp"])
    await client.disconnect()
  }

  func testTimeoutFailsClosedAndDisconnectsSession() async throws {
    let configuration = try fixtureConfiguration(commandTimeoutMilliseconds: 50)
    let client = PublishingMCPClient(configuration: configuration)
    _ = try await client.discoverTools()
    do {
      _ = try await client.call(remoteToolName: "echo", argumentsJSON: #"{"text":"sleep"}"#)
      XCTFail("Expected timeout")
    } catch let error as PublishingMCPClientError {
      XCTAssertEqual(error, .requestTimedOut)
    }
    await client.disconnect()
  }

  func testParentCancellationDisconnectsPendingRequest() async throws {
    let client = PublishingMCPClient(
      configuration: try fixtureConfiguration(commandTimeoutMilliseconds: 5_000)
    )
    _ = try await client.discoverTools()
    let pending = Task {
      try await client.call(remoteToolName: "echo", argumentsJSON: #"{"text":"sleep"}"#)
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    pending.cancel()

    do {
      _ = try await pending.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected: cancellation tears down the SDK continuation and child.
    }
    await client.disconnect()
  }

  func testUnsupportedAndOverLimitContentAreSafeErrors() async throws {
    let client = PublishingMCPClient(
      configuration: try fixtureConfiguration(maximumOutputByteCount: 32)
    )
    _ = try await client.discoverTools()
    let image = try await client.call(remoteToolName: "echo", argumentsJSON: #"{"text":"image"}"#)
    XCTAssertTrue(image.isError)
    XCTAssertEqual(image.content, "External MCP tool returned unsupported content.")
    let large = try await client.call(remoteToolName: "echo", argumentsJSON: #"{"text":"large"}"#)
    XCTAssertTrue(large.isError)
    XCTAssertEqual(large.content, "External MCP tool returned more content than allowed.")
    await client.disconnect()
  }

  func testStructuredAndExcessiveBlockResultsFailClosed() async throws {
    let client = PublishingMCPClient(configuration: try fixtureConfiguration())
    _ = try await client.discoverTools()

    let structured = try await client.call(
      remoteToolName: "echo",
      argumentsJSON: #"{"text":"structured"}"#
    )
    XCTAssertTrue(structured.isError)
    XCTAssertEqual(
      structured.content,
      "External MCP tool returned unsupported structured content."
    )

    let blocks = try await client.call(
      remoteToolName: "echo",
      argumentsJSON: #"{"text":"empty_blocks"}"#
    )
    XCTAssertTrue(blocks.isError)
    XCTAssertEqual(blocks.content, "External MCP tool returned too many content blocks.")
    await client.disconnect()
  }

  func testRawFrameLimitStopsUnterminatedServerOutput() async throws {
    let client = PublishingMCPClient(
      configuration: try fixtureConfiguration(
        commandTimeoutMilliseconds: 500,
        maximumInputByteCount: 512,
        maximumOutputByteCount: 128,
        maximumRawMessageByteCount: 512
      )
    )
    _ = try await client.discoverTools()
    do {
      _ = try await client.call(
        remoteToolName: "echo",
        argumentsJSON: #"{"text":"raw_frame"}"#
      )
      XCTFail("Expected raw frame rejection")
    } catch let error as PublishingMCPClientError {
      XCTAssertEqual(error, .outputLimitExceeded)
    }
    await client.disconnect()
  }

  func testDiscoveryRejectsSchemaOverConfiguredLimit() async throws {
    let client = PublishingMCPClient(
      configuration: try fixtureConfiguration(maximumInputByteCount: 8)
    )
    do {
      _ = try await client.discoverTools()
      XCTFail("Expected schema limit rejection")
    } catch let error as PublishingMCPClientError {
      XCTAssertEqual(error, .invalidRemoteTool)
    }
    await client.disconnect()
  }

  func testRegistryProducesStableBindingAndRejectsArgumentDrift() throws {
    let configuration = try fixtureConfiguration()
    let registry = try PublishingMCPToolRegistry(
      configuration: configuration,
      tools: [
        PublishingMCPDiscoveredTool(
          remoteName: "echo",
          description: "Echo",
          inputSchema: .object(["type": .string("object")])
        )
      ]
    )
    let name = try XCTUnwrap(registry.catalog.descriptors.first?.definition.function.name)
    let call = AIToolCall(id: "call-1", function: .init(name: name, arguments: #"{"text":"one"}"#))
    let invocation = try registry.prepare(
      call: call,
      context: WorkbenchAIAgentContext(goal: "test")
    )
    XCTAssertEqual(invocation.externalToolBinding?.sourceID, configuration.sourceID)
    XCTAssertEqual(invocation.externalToolBinding?.argumentsJSON, #"{"text":"one"}"#)

    XCTAssertThrowsError(
      try registry.revalidate(
        invocation: invocation,
        matching: AIToolCall(
          id: "call-1", function: .init(name: name, arguments: #"{"text":"two"}"#)),
        context: WorkbenchAIAgentContext(goal: "test")
      )
    )
  }

  func testExecutorRejectsUndiscoveredToolAndMismatchedClient() async throws {
    let configuration = try fixtureConfiguration()
    let client = PublishingMCPClient(configuration: configuration)
    let registry = try PublishingMCPToolRegistry(
      configuration: configuration,
      tools: try await client.discoverTools()
    )
    let executor = try PublishingMCPToolExecutor(client: client, registry: registry)
    let descriptor = try XCTUnwrap(registry.catalog.descriptors.first)
    let invocation = try registry.prepare(
      call: AIToolCall(
        id: "allowed",
        function: .init(
          name: descriptor.definition.function.name,
          arguments: #"{"text":"hello"}"#
        )
      ),
      context: WorkbenchAIAgentContext(goal: "allowed")
    )
    let allowed = try await executor.execute(invocation)
    XCTAssertEqual(allowed.content, "hello")

    let forged = WorkbenchAIAgentToolInvocation(
      toolCallID: "forged",
      toolID: PublishingMCPToolRegistry.toolID(
        sourceID: configuration.sourceID,
        remoteToolName: "hidden"
      ),
      modelToolName: descriptor.definition.function.name,
      executionPolicy: descriptor.executionPolicy,
      catalogRevision: registry.catalog.revision,
      externalToolBinding: AIAgentExternalToolBinding(
        sourceID: configuration.sourceID,
        sourceRevision: configuration.sourceRevision,
        remoteToolName: "hidden",
        argumentsJSON: #"{"text":"must-not-run"}"#
      )
    )
    do {
      _ = try await executor.execute(forged)
      XCTFail("Expected undiscovered tool rejection")
    } catch let error as PublishingMCPClientError {
      XCTAssertEqual(error, .invocationMismatch)
    }

    let otherConfiguration = try fixtureConfiguration(
      sourceRevision: "fixture-v2",
      configurationDigest: "fixture-config-v2"
    )
    XCTAssertThrowsError(
      try PublishingMCPToolExecutor(
        client: PublishingMCPClient(configuration: otherConfiguration),
        registry: registry
      )
    )
    await client.disconnect()
  }

  func testCatalogRevisionCoversDescriptionAndRejectsMalformedNestedSchema() throws {
    let configuration = try fixtureConfiguration()
    let schema: AIStructuredOutputJSONValue = .object([
      "type": .string("object"),
      "properties": .object([
        "text": .object(["type": .string("string")])
      ]),
    ])
    let first = try PublishingMCPToolRegistry(
      configuration: configuration,
      tools: [.init(remoteName: "echo", description: "first", inputSchema: schema)]
    )
    let second = try PublishingMCPToolRegistry(
      configuration: configuration,
      tools: [.init(remoteName: "echo", description: "second", inputSchema: schema)]
    )
    XCTAssertNotEqual(first.catalog.revision, second.catalog.revision)

    XCTAssertThrowsError(
      try PublishingMCPToolRegistry(
        configuration: configuration,
        tools: [
          .init(
            remoteName: "bad",
            description: nil,
            inputSchema: .object([
              "type": .string("object"),
              "properties": .string("not-a-schema-map"),
            ])
          )
        ]
      )
    )
  }

  func testExecutableIdentityDriftIsRejectedBeforeLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PublishingMCPClientTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let executableURL = directory.appendingPathComponent("fixture-server")
    try Data("#!/bin/sh\nexec /usr/bin/python3 \"$1\"\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)

    let configuration = try PublishingMCPSourceConfiguration(
      sourceID: "identity-fixture",
      executableURL: executableURL,
      arguments: [fixtureScriptURL.path],
      sourceRevision: "fixture-v1",
      configurationDigest: "fixture-config-v1",
      requiredScopes: [.localRead]
    )
    try Data("#!/bin/sh\n# replaced after review\nexit 7\n".utf8).write(to: executableURL)
    XCTAssertEqual(chmod(executableURL.path, 0o700), 0)

    let client = PublishingMCPClient(configuration: configuration)
    do {
      _ = try await client.discoverTools()
      XCTFail("Expected executable identity rejection")
    } catch let error as PublishingMCPClientError {
      XCTAssertEqual(error, .connectionFailed)
    }
  }

  func testConfigurationRejectsEnvironmentValueContainingNUL() throws {
    XCTAssertThrowsError(
      try PublishingMCPSourceConfiguration(
        sourceID: "invalid-environment",
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [fixtureScriptURL.path],
        environmentOverrides: ["SAFE_NAME": "unsafe\0value"],
        authorityKey: fixtureAuthorityKey(),
        sourceRevision: "fixture-v1",
        configurationDigest: "fixture-config-v1",
        requiredScopes: [.localRead]
      )
    ) { error in
      XCTAssertEqual(error as? PublishingMCPClientError, .invalidConfiguration)
    }
  }

  func testEnvironmentAuthorityRequiresAHostOwnedKey() throws {
    XCTAssertThrowsError(
      try PublishingMCPSourceConfiguration(
        sourceID: "missing-authority-key",
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [fixtureScriptURL.path],
        environmentOverrides: ["MCP_TEST_SECRET": "1234"],
        sourceRevision: "fixture-v1",
        configurationDigest: "fixture-config-v1",
        requiredScopes: [.localRead]
      )
    ) { error in
      XCTAssertEqual(error as? PublishingMCPClientError, .invalidConfiguration)
    }
  }

  func testEnvironmentAuthorityUsesStableKeyedCatalogRevision() throws {
    let firstKey = try fixtureAuthorityKey(byte: 0x11)
    let secondKey = try fixtureAuthorityKey(byte: 0x22)
    let first = try fixtureConfiguration(
      environmentOverrides: ["MCP_TEST_SECRET": "1234"],
      authorityKey: firstKey
    )
    let sameAuthority = try fixtureConfiguration(
      environmentOverrides: ["MCP_TEST_SECRET": "1234"],
      authorityKey: firstKey
    )
    let changedValue = try fixtureConfiguration(
      environmentOverrides: ["MCP_TEST_SECRET": "5678"],
      authorityKey: firstKey
    )
    let changedKey = try fixtureConfiguration(
      environmentOverrides: ["MCP_TEST_SECRET": "1234"],
      authorityKey: secondKey
    )
    let tool = PublishingMCPDiscoveredTool(
      remoteName: "echo",
      description: "Echo",
      inputSchema: .object(["type": .string("object")])
    )

    let firstRevision = try PublishingMCPToolRegistry(
      configuration: first,
      tools: [tool]
    ).catalog.revision
    let sameRevision = try PublishingMCPToolRegistry(
      configuration: sameAuthority,
      tools: [tool]
    ).catalog.revision
    let changedValueRevision = try PublishingMCPToolRegistry(
      configuration: changedValue,
      tools: [tool]
    ).catalog.revision
    let changedKeyRevision = try PublishingMCPToolRegistry(
      configuration: changedKey,
      tools: [tool]
    ).catalog.revision

    XCTAssertTrue(firstRevision.hasPrefix("mcp-v2/"))
    XCTAssertEqual(firstRevision, sameRevision)
    XCTAssertNotEqual(firstRevision, changedValueRevision)
    XCTAssertNotEqual(firstRevision, changedKeyRevision)
  }

  func testConcurrentFirstDiscoveryStartsOnlyOneServerProcess() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PublishingMCPConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let counterURL = directory.appendingPathComponent("launches.txt")
    let client = PublishingMCPClient(
      configuration: try fixtureConfiguration(
        environmentOverrides: ["MCP_TEST_LAUNCH_COUNTER": counterURL.path]
      )
    )

    let discoveredNames = try await withThrowingTaskGroup(of: [String].self) { group in
      for _ in 0..<8 {
        group.addTask {
          try await client.discoverTools().map(\.remoteName)
        }
      }
      var output: [[String]] = []
      for try await names in group {
        output.append(names)
      }
      return output
    }
    XCTAssertEqual(discoveredNames.count, 8)
    XCTAssertTrue(discoveredNames.allSatisfy { $0 == ["echo"] })
    await client.disconnect()

    let launches = try String(contentsOf: counterURL, encoding: .utf8)
      .split(separator: "\n")
    XCTAssertEqual(launches.count, 1)
  }

  func testStaleDiscoveryFailureDoesNotClearReplacementSession() async throws {
    try await assertStaleFailureDoesNotClearReplacement(.listTools)
  }

  func testStaleCallFailureDoesNotClearReplacementSession() async throws {
    try await assertStaleFailureDoesNotClearReplacement(.call)
  }

  func testPinnedLaunchArtifactContentDriftInvalidatesAuthority() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PublishingMCPArtifactTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifactURL = directory.appendingPathComponent("server-entry.py")
    try Data("first-content".utf8).write(to: artifactURL)
    let originalDate = try XCTUnwrap(
      try FileManager.default.attributesOfItem(atPath: artifactURL.path)[.modificationDate] as? Date
    )

    let firstConfiguration = try fixtureConfiguration(
      pinnedLaunchArtifactURLs: [artifactURL]
    )
    let tool = PublishingMCPDiscoveredTool(
      remoteName: "echo",
      description: "Echo",
      inputSchema: .object(["type": .string("object")])
    )
    let firstRegistry = try PublishingMCPToolRegistry(
      configuration: firstConfiguration,
      tools: [tool]
    )

    try Data("other-content".utf8).write(to: artifactURL)
    try FileManager.default.setAttributes(
      [.modificationDate: originalDate],
      ofItemAtPath: artifactURL.path
    )
    let staleClient = PublishingMCPClient(configuration: firstConfiguration)
    do {
      _ = try await staleClient.discoverTools()
      XCTFail("Expected pinned launch artifact drift rejection")
    } catch let error as PublishingMCPClientError {
      XCTAssertEqual(error, .connectionFailed)
    }

    let secondConfiguration = try fixtureConfiguration(
      pinnedLaunchArtifactURLs: [artifactURL]
    )
    let secondRegistry = try PublishingMCPToolRegistry(
      configuration: secondConfiguration,
      tools: [tool]
    )
    XCTAssertNotEqual(firstRegistry.catalog.revision, secondRegistry.catalog.revision)
  }

  func testDisconnectKillsDescendantProcessGroup() async throws {
    let client = PublishingMCPClient(configuration: try fixtureConfiguration())
    _ = try await client.discoverTools()
    let result = try await client.call(
      remoteToolName: "echo",
      argumentsJSON: #"{"text":"descendant"}"#
    )
    let processIdentifier = try XCTUnwrap(
      Int32(result.content.replacingOccurrences(of: "pid:", with: ""))
    )
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), 0)

    await client.disconnect()
    let deadline = Date().addingTimeInterval(2)
    while Darwin.kill(processIdentifier, 0) == 0, Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    errno = 0
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
    XCTAssertEqual(errno, ESRCH)
  }

  func testLeaderExitKillsDescendantProcessGroupWithoutExplicitDisconnect() async throws {
    let client = PublishingMCPClient(configuration: try fixtureConfiguration())
    _ = try await client.discoverTools()
    let result = try await client.call(
      remoteToolName: "echo",
      argumentsJSON: #"{"text":"descendant_exit"}"#
    )
    let processIdentifier = try XCTUnwrap(
      Int32(result.content.replacingOccurrences(of: "pid:", with: ""))
    )
    defer { _ = Darwin.kill(processIdentifier, SIGKILL) }

    let deadline = Date().addingTimeInterval(2)
    while Darwin.kill(processIdentifier, 0) == 0, Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    errno = 0
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    await client.disconnect()
  }

  func testImmediateLeaderExitStillCleansInheritedDescendant() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PublishingMCPImmediateExit-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let processIdentifierURL = directory.appendingPathComponent("descendant-pid")
    let configuration = try PublishingMCPSourceConfiguration(
      sourceID: "immediate-exit-fixture",
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: [
        fixtureScriptURL.path,
        "--record-descendant-and-exit",
        processIdentifierURL.path,
      ],
      sourceRevision: "fixture-v1",
      configurationDigest: "fixture-config-v1",
      requiredScopes: [.localRead],
      connectionTimeoutMilliseconds: 500
    )
    let client = PublishingMCPClient(configuration: configuration)
    do {
      _ = try await client.discoverTools()
      XCTFail("Expected an immediate server exit")
    } catch {
      // The transport error is expected; process-group cleanup is asserted below.
    }

    let recordDeadline = Date().addingTimeInterval(1)
    while !FileManager.default.fileExists(atPath: processIdentifierURL.path),
      Date() < recordDeadline
    {
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    let record = try String(contentsOf: processIdentifierURL, encoding: .utf8)
    let processIdentifier = try XCTUnwrap(Int32(record))
    defer { _ = Darwin.kill(processIdentifier, SIGKILL) }

    let cleanupDeadline = Date().addingTimeInterval(2)
    while Darwin.kill(processIdentifier, 0) == 0, Date() < cleanupDeadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    errno = 0
    XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
    XCTAssertEqual(errno, ESRCH)
    await client.disconnect()
  }

  private func fixtureConfiguration(
    sourceRevision: String = "fixture-v1",
    configurationDigest: String = "fixture-config-v1",
    commandTimeoutMilliseconds: UInt64 = 1_000,
    maximumInputByteCount: Int = 16 * 1_024,
    maximumOutputByteCount: Int = 64 * 1_024,
    maximumRawMessageByteCount: Int = 256 * 1_024,
    pinnedLaunchArtifactURLs: [URL] = [],
    environmentOverrides: [String: String] = [:],
    authorityKey: PublishingMCPAuthorityKey? = nil
  ) throws -> PublishingMCPSourceConfiguration {
    let resolvedAuthorityKey =
      try (authorityKey ?? (environmentOverrides.isEmpty ? nil : fixtureAuthorityKey()))
    return try PublishingMCPSourceConfiguration(
      sourceID: "fixture",
      executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
      arguments: [fixtureScriptURL.path],
      pinnedLaunchArtifactURLs: pinnedLaunchArtifactURLs,
      environmentOverrides: environmentOverrides,
      authorityKey: resolvedAuthorityKey,
      sourceRevision: sourceRevision,
      configurationDigest: configurationDigest,
      requiredScopes: [.localRead],
      commandTimeoutMilliseconds: commandTimeoutMilliseconds,
      maximumInputByteCount: maximumInputByteCount,
      maximumOutputByteCount: maximumOutputByteCount,
      maximumRawMessageByteCount: maximumRawMessageByteCount
    )
  }

  private func fixtureAuthorityKey(byte: UInt8 = 0x5A) throws
    -> PublishingMCPAuthorityKey
  {
    try PublishingMCPAuthorityKey(rawRepresentation: Data(repeating: byte, count: 32))
  }

  private func assertStaleFailureDoesNotClearReplacement(
    _ failure: PublishingMCPControlledFailure
  ) async throws {
    let staleSession = PublishingMCPControlledSession(failure: failure)
    let replacementSession = PublishingMCPControlledSession()
    let unexpectedThirdSession = PublishingMCPControlledSession()
    let factory = PublishingMCPControlledSessionFactory(
      sessions: [staleSession, replacementSession, unexpectedThirdSession]
    )
    let client = PublishingMCPClient(
      configuration: try fixtureConfiguration(),
      sessionFactory: { _ in await factory.makeSession() }
    )
    _ = try await client.discoverTools()

    let staleOperation = Task<Void, Error> {
      switch failure {
      case .listTools:
        _ = try await client.discoverTools()
      case .call:
        _ = try await client.call(
          remoteToolName: "echo",
          argumentsJSON: #"{"text":"stale"}"#
        )
      }
    }
    await staleSession.waitUntilFailureStarted()
    await client.disconnect()
    _ = try await client.discoverTools()
    await staleSession.releaseFailure()
    do {
      try await staleOperation.value
      XCTFail("Expected the stale session operation to fail")
    } catch let error as PublishingMCPClientError {
      XCTAssertEqual(error, .connectionFailed)
    }

    _ = try await client.discoverTools()
    let creationCount = await factory.creationCount()
    XCTAssertEqual(creationCount, 2)
    await client.disconnect()
  }

  private var fixtureScriptURL: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Fixtures/MCP/stdio_fixture.py")
  }
}

private enum PublishingMCPControlledFailure: Sendable {
  case listTools
  case call
}

private actor PublishingMCPControlledSession: PublishingMCPClientSession {
  private let failure: PublishingMCPControlledFailure?
  private var listToolsCallCount = 0
  private var failureStarted = false
  private var failureStartWaiters: [CheckedContinuation<Void, Never>] = []
  private var failureContinuation: CheckedContinuation<Void, Never>?

  init(failure: PublishingMCPControlledFailure? = nil) {
    self.failure = failure
  }

  func connect() async throws {}

  func listTools() async throws -> [PublishingMCPDiscoveredTool] {
    listToolsCallCount += 1
    if failure == .listTools, listToolsCallCount == 2 {
      try await suspendThenFail()
    }
    return [Self.echoTool]
  }

  func call(
    remoteToolName _: String,
    argumentsJSON _: String
  ) async throws -> WorkbenchAIAgentToolResult {
    if failure == .call {
      try await suspendThenFail()
    }
    return WorkbenchAIAgentToolResult(content: "ok", isError: false)
  }

  func close() async {}

  func waitUntilFailureStarted() async {
    guard !failureStarted else { return }
    await withCheckedContinuation { continuation in
      failureStartWaiters.append(continuation)
    }
  }

  func releaseFailure() {
    failureContinuation?.resume()
    failureContinuation = nil
  }

  private func suspendThenFail() async throws {
    failureStarted = true
    let waiters = failureStartWaiters
    failureStartWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    await withCheckedContinuation { continuation in
      failureContinuation = continuation
    }
    throw PublishingMCPClientError.connectionFailed
  }

  private static let echoTool = PublishingMCPDiscoveredTool(
    remoteName: "echo",
    description: "Echo",
    inputSchema: .object(["type": .string("object")])
  )
}

private actor PublishingMCPControlledSessionFactory {
  private var sessions: [PublishingMCPControlledSession]
  private var count = 0

  init(sessions: [PublishingMCPControlledSession]) {
    self.sessions = sessions
  }

  func makeSession() -> any PublishingMCPClientSession {
    count += 1
    if sessions.isEmpty {
      return PublishingMCPControlledSession()
    }
    return sessions.removeFirst()
  }

  func creationCount() -> Int {
    count
  }
}
