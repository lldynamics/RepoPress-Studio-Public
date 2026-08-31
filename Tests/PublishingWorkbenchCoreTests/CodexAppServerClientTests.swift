import Darwin
import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class CodexAppServerClientTests: XCTestCase {
  func testRuntimeDiscoveryUsesExecutableFromSystemPATH() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent("CodexRuntimeDiscoveryTests-\(UUID().uuidString)", isDirectory: true)
    let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
    let executableURL = binURL.appendingPathComponent("codex", isDirectory: false)
    try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    try fileManager.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )

    let location = try XCTUnwrap(
      CodexAppServerProcessTransport.discoverRuntimeLocation(
        environment: ["PATH": binURL.path],
        fallbackCandidates: []
      )
    )

    XCTAssertEqual(location.url.path, executableURL.path)
    XCTAssertEqual(location.source, .path)
  }

  func testRuntimeDiscoveryUsesConventionalFallbackWithoutPATH() throws {
    let fileManager = FileManager.default
    let rootURL = fileManager.temporaryDirectory
      .appendingPathComponent("CodexRuntimeFallbackTests-\(UUID().uuidString)", isDirectory: true)
    let executableURL = rootURL.appendingPathComponent("codex", isDirectory: false)
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: rootURL) }
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    try fileManager.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )

    let location = try XCTUnwrap(
      CodexAppServerProcessTransport.discoverRuntimeLocation(
        environment: [:],
        fallbackCandidates: [(executableURL.path, .homebrew)]
      )
    )

    XCTAssertEqual(location.url.path, executableURL.path)
    XCTAssertEqual(location.source, .homebrew)
  }

  func testRuntimeVersionParsesCodexCLIOutput() throws {
    XCTAssertEqual(
      CodexAppServerRuntimeVersion.parse("codex-cli 0.148.0"),
      CodexAppServerRuntimeVersion(major: 0, minor: 148, patch: 0)
    )
    XCTAssertEqual(
      CodexAppServerRuntimeVersion.parse("Codex-CLI v0.142.0+build.1\n"),
      CodexAppServerRuntimeVersion(major: 0, minor: 142, patch: 0)
    )
  }

  func testRuntimeVersionParserRejectsUnidentifiedOrPrereleaseOutput() {
    XCTAssertNil(CodexAppServerRuntimeVersion.parse("0.148.0"))
    XCTAssertNil(CodexAppServerRuntimeVersion.parse("other-cli 0.148.0"))
    XCTAssertNil(CodexAppServerRuntimeVersion.parse("codex-cli 0.148.0-beta.1"))
    XCTAssertNil(CodexAppServerRuntimeVersion.parse("codex-cli unknown"))
  }

  func testRuntimeCompatibilityDistinguishesMissingAndUnsupportedStates() {
    let executableURL = URL(fileURLWithPath: "/tmp/codex")
    let missingExecutable = CodexAppServerRuntimeStatus()
    XCTAssertEqual(missingExecutable.compatibility, .missingExecutable)
    XCTAssertFalse(missingExecutable.isCompatible)

    let missingVersion = CodexAppServerRuntimeStatus(executableURL: executableURL)
    XCTAssertEqual(missingVersion.compatibility, .missingVersion)
    XCTAssertFalse(missingVersion.isCompatible)

    let unparseableVersion = CodexAppServerRuntimeStatus(
      executableURL: executableURL,
      version: "codex-cli not-a-version"
    )
    XCTAssertEqual(unparseableVersion.compatibility, .unparseableVersion)
    XCTAssertFalse(unparseableVersion.isCompatible)

    let lowVersion = CodexAppServerRuntimeStatus(
      executableURL: executableURL,
      version: "codex-cli 0.141.9"
    )
    XCTAssertEqual(lowVersion.compatibility, .unsupportedVersion)
    XCTAssertFalse(lowVersion.isCompatible)

    let minimumVersion = CodexAppServerRuntimeStatus(
      executableURL: executableURL,
      version: "codex-cli 0.142.0"
    )
    XCTAssertEqual(minimumVersion.compatibility, .compatible)
    XCTAssertTrue(minimumVersion.isCompatible)

    let currentVersion = CodexAppServerRuntimeStatus(
      executableURL: executableURL,
      version: "codex-cli 0.148.0"
    )
    XCTAssertEqual(currentVersion.compatibility, .compatible)
    XCTAssertTrue(currentVersion.isCompatible)
  }

  func testRuntimeVersionProbeReturnsSuccessfulBoundedOutput() async throws {
    let fixture = try makeRuntimeProbeFixture(
      body: "printf 'codex-cli 0.148.0\\n'"
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let value = await CodexAppServerProcessTransport.readVersion(
      executableURL: fixture.executableURL,
      timeout: .seconds(1)
    )

    XCTAssertEqual(value, "codex-cli 0.148.0")
  }

  func testRuntimeEnvironmentRetainsOnlyRequiredKeys() {
    let environment = CodexRuntimeProcessEnvironment.sanitized(from: [
      "HOME": "/tmp/home",
      "CODEX_HOME": "/tmp/codex",
      "LANG": "zh_CN.UTF-8",
      "TMPDIR": "/tmp/",
      "PATH": "/usr/bin:/bin",
      "HTTPS_PROXY": "http://proxy.invalid",
      "SSL_CERT_FILE": "/tmp/cert.pem",
      "OPENAI_API_KEY": "secret",
      "GITHUB_TOKEN": "secret",
      "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
      "NODE_OPTIONS": "--require /tmp/injected.js",
    ])

    XCTAssertEqual(environment["CODEX_HOME"], "/tmp/codex")
    XCTAssertEqual(environment["HTTPS_PROXY"], "http://proxy.invalid")
    XCTAssertEqual(environment["SSL_CERT_FILE"], "/tmp/cert.pem")
    XCTAssertNil(environment["OPENAI_API_KEY"])
    XCTAssertNil(environment["GITHUB_TOKEN"])
    XCTAssertNil(environment["DYLD_INSERT_LIBRARIES"])
    XCTAssertNil(environment["NODE_OPTIONS"])
  }

  func testProcessTransportRejectsUnsupportedRuntimeBeforeAppServerLaunch() async throws {
    let fixture = try makeRuntimeProbeFixture(
      body: "if [ \"$1\" = \"--version\" ]; then printf 'codex-cli 0.141.9\\n'; exit 0; fi; exit 91"
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let transport = CodexAppServerProcessTransport(executableURL: fixture.executableURL)

    do {
      try await transport.start()
      XCTFail("An unsupported runtime must not reach app-server launch")
    } catch {
      XCTAssertEqual(error as? CodexAppServerError, .processExited)
    }
  }

  func testProcessTransportRejectsRuntimeReplacedAfterVersionProbe() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexRuntimeBindingTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let executableURL = rootURL.appendingPathComponent("codex")
    let replacementURL = rootURL.appendingPathComponent("replacement")
    let launchMarkerURL = rootURL.appendingPathComponent("replacement-launched")
    let source = """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        printf 'codex-cli 0.148.0\\n'
        mv '\(replacementURL.path)' "$0"
        exit 0
      fi
      exit 90
      """
    let replacement = """
      #!/bin/sh
      printf launched > '\(launchMarkerURL.path)'
      exit 0
      """
    try Data(source.utf8).write(to: executableURL)
    try Data(replacement.utf8).write(to: replacementURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: replacementURL.path
    )
    let transport = CodexAppServerProcessTransport(executableURL: executableURL)

    do {
      try await transport.start()
      XCTFail("A runtime replaced after its version probe must not launch")
    } catch {
      XCTAssertEqual(error as? CodexAppServerError, .processExited)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: launchMarkerURL.path))
  }

  func testCancellingOneConcurrentStartDoesNotCancelSharedTransportStartup() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexRuntimeConcurrentStartTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let executableURL = rootURL.appendingPathComponent("codex")
    let probeMarkerURL = rootURL.appendingPathComponent("probe-started")
    let source = """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        printf probing > '\(probeMarkerURL.path)'
        sleep 0.2
        printf 'codex-cli 0.148.0\\n'
        exit 0
      fi
      trap 'exit 0' TERM
      while :; do sleep 1; done
      """
    try Data(source.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )
    let transport = CodexAppServerProcessTransport(executableURL: executableURL)
    defer { Task { await transport.terminate() } }

    let cancelledStart = Task { try await transport.start() }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: probeMarkerURL.path) {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: probeMarkerURL.path))
    let survivingStart = Task { try await transport.start() }

    cancelledStart.cancel()
    do {
      try await cancelledStart.value
      XCTFail("The cancelled waiter should retain its own cancellation result")
    } catch is CancellationError {
      // Expected: the caller is cancelled without cancelling shared startup.
    }
    try await survivingStart.value
    await transport.terminate()
  }

  func testRuntimeVersionProbeRejectsNonZeroAndOversizedOutput() async throws {
    let failure = try makeRuntimeProbeFixture(body: "exit 7")
    defer { try? FileManager.default.removeItem(at: failure.rootURL) }
    let failureValue = await CodexAppServerProcessTransport.readVersion(
      executableURL: failure.executableURL,
      timeout: .seconds(1)
    )
    XCTAssertNil(failureValue)

    let oversized = try makeRuntimeProbeFixture(
      body: "i=0; while [ \"$i\" -lt 5000 ]; do printf x; i=$((i + 1)); done"
    )
    defer { try? FileManager.default.removeItem(at: oversized.rootURL) }
    let oversizedValue = await CodexAppServerProcessTransport.readVersion(
      executableURL: oversized.executableURL,
      timeout: .seconds(1)
    )
    XCTAssertNil(oversizedValue)
  }

  func testRuntimeVersionProbeTimesOutAndReapsProcess() async throws {
    let fixture = try makeRuntimeProbeFixture(
      body: "trap '' TERM; while :; do :; done"
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let (launches, launchContinuation) = AsyncStream.makeStream(of: pid_t.self)
    let probe = CodexRuntimeVersionProbe(
      executableURL: fixture.executableURL,
      processDidLaunch: { processIdentifier in
        launchContinuation.yield(processIdentifier)
        launchContinuation.finish()
      }
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    let task = Task {
      await probe.run(timeout: .seconds(1))
    }
    let pid = try await waitForRuntimeProbePID(from: launches)
    let value = await task.value

    XCTAssertNil(value)
    XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(2))
    await assertRuntimeProbeExited(pid)
  }

  func testRuntimeVersionProbeCancellationReapsProcess() async throws {
    let fixture = try makeRuntimeProbeFixture(
      body: "trap '' TERM; while :; do :; done"
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let (launches, launchContinuation) = AsyncStream.makeStream(of: pid_t.self)
    let probe = CodexRuntimeVersionProbe(
      executableURL: fixture.executableURL,
      processDidLaunch: { processIdentifier in
        launchContinuation.yield(processIdentifier)
        launchContinuation.finish()
      }
    )
    let task = Task {
      await probe.run(timeout: .seconds(30))
    }
    let pid = try await waitForRuntimeProbePID(from: launches)

    task.cancel()

    let cancelledValue = await task.value
    XCTAssertNil(cancelledValue)
    await assertRuntimeProbeExited(pid)
  }

  func testRuntimeVersionProbeOutputLimitReapsPublishedProcess() async throws {
    let fixture = try makeRuntimeProbeFixture(
      body: "i=0; while [ \"$i\" -lt 5000 ]; do printf x; i=$((i + 1)); done; "
        + "trap '' TERM; while :; do :; done"
    )
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
    let (launches, launchContinuation) = AsyncStream.makeStream(of: pid_t.self)
    let probe = CodexRuntimeVersionProbe(
      executableURL: fixture.executableURL,
      processDidLaunch: { processIdentifier in
        launchContinuation.yield(processIdentifier)
        launchContinuation.finish()
      }
    )
    let clock = ContinuousClock()
    let startedAt = clock.now

    let task = Task {
      await probe.run(timeout: .seconds(30))
    }
    let pid = try await waitForRuntimeProbePID(from: launches)
    let value = await task.value

    XCTAssertNil(value)
    XCTAssertLessThan(startedAt.duration(to: clock.now), .seconds(2))
    await assertRuntimeProbeExited(pid)
  }

  func testRuntimeVersionProbeReapsDescendantAfterLeaderExits() async throws {
    let fixture = try makeRuntimeProbeDescendantFixture()
    defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

    let value = await CodexAppServerProcessTransport.readVersion(
      executableURL: fixture.executableURL,
      timeout: .seconds(1)
    )
    let childPIDText = try String(contentsOf: fixture.childPIDURL, encoding: .utf8)
    let childPID = try XCTUnwrap(
      pid_t(childPIDText.trimmingCharacters(in: .whitespacesAndNewlines))
    )

    XCTAssertNil(value)
    await assertRuntimeProbeExited(childPID)
  }

  func testProcessTransportReturnsPartialPipeChunkWithoutWaitingForMaximum() async throws {
    let transport = CodexAppServerProcessTransport(
      testExecutableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: []
    )
    try await transport.start()
    let payload = Data("small JSONL response\n".utf8)
    try await transport.send(payload)

    let received = expectation(description: "partial pipe chunk returned")
    let receiveTask = Task {
      let data = try await transport.receive()
      received.fulfill()
      return data
    }
    await fulfillment(of: [received], timeout: 1)
    await transport.terminate()

    let response = try await receiveTask.value
    XCTAssertEqual(response, payload)
  }

  private func makeRuntimeProbeFixture(
    body: String
  ) throws -> (rootURL: URL, executableURL: URL) {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexRuntimeProbeTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let executableURL = rootURL.appendingPathComponent("codex")
    try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )
    return (rootURL, executableURL)
  }

  private func makeRuntimeProbeDescendantFixture() throws -> (
    rootURL: URL,
    executableURL: URL,
    childPIDURL: URL
  ) {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "CodexRuntimeProbeDescendantTests-\(UUID().uuidString)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    let executableURL = rootURL.appendingPathComponent("codex")
    let childPIDURL = rootURL.appendingPathComponent("child.pid")
    let source = """
      #!/bin/sh
      (trap '' TERM; while :; do :; done) &
      printf '%s' "$!" > "\(childPIDURL.path)"
      exit 0
      """
    try Data(source.utf8).write(to: executableURL)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executableURL.path
    )
    return (rootURL, executableURL, childPIDURL)
  }

  private func waitForRuntimeProbePID(
    from launches: AsyncStream<pid_t>
  ) async throws -> pid_t {
    try await withThrowingTaskGroup(of: pid_t.self) { group in
      group.addTask {
        for await processIdentifier in launches {
          return processIdentifier
        }
        throw RuntimeProbeTestError.launchSignalEnded
      }
      group.addTask {
        try await Task.sleep(for: .seconds(5))
        throw RuntimeProbeTestError.launchTimedOut
      }

      guard let processIdentifier = try await group.next() else {
        throw RuntimeProbeTestError.launchSignalEnded
      }
      group.cancelAll()
      return processIdentifier
    }
  }

  private func assertRuntimeProbeExited(
    _ processIdentifier: pid_t,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    for _ in 0..<100 {
      errno = 0
      if Darwin.kill(processIdentifier, 0) == -1, errno == ESRCH {
        return
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("runtime version probe process was not reaped", file: file, line: line)
  }

  func testHandshakeAndAccountReadAreRoutedByRequestID() async throws {
    let transport = ScriptedCodexTransport(mode: .account)
    let client = CodexAppServerClient(transport: transport)

    let account = try await client.accountStatus()

    XCTAssertTrue(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "acct-1")
    XCTAssertEqual(account.accountType, "chatgpt")
    XCTAssertEqual(account.email, "writer@example.com")
    XCTAssertEqual(account.planType, "pro")

    let messages = await transport.sentMessages()
    XCTAssertEqual(
      messages.compactMap { $0["method"]?.stringValue },
      ["initialize", "initialized", "account/read"]
    )
    XCTAssertEqual(messages.compactMap { $0["id"]?.intValue }, [1, 2])
  }

  func testAccountRequiresAuthWinsOverStaleAccountMetadata() async throws {
    let transport = ScriptedCodexTransport(mode: .accountRequiresAuth)
    let client = CodexAppServerClient(transport: transport)

    let account = try await client.accountStatus()

    XCTAssertFalse(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "stale-acct")
  }

  func testAccountMetadataInfersAuthenticationWhenFlagsAreAbsent() async throws {
    let transport = ScriptedCodexTransport(mode: .accountMetadataOnly)
    let client = CodexAppServerClient(transport: transport)

    let account = try await client.accountStatus()

    XCTAssertTrue(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "metadata-acct")
  }

  func testLoginRejectsNonHTTPSOrHostlessAuthURL() async throws {
    for mode in [
      ScriptedCodexTransport.Mode.loginInsecureURL,
      .loginHostlessURL,
      .loginUserInfoURL,
    ] {
      let transport = ScriptedCodexTransport(mode: mode)
      let client = CodexAppServerClient(transport: transport)

      await XCTAssertThrowsErrorAsync(try await client.startChatGPTLogin()) { error in
        XCTAssertEqual(error as? CodexAppServerError, .invalidResponse)
        XCTAssertFalse(String(describing: error).contains("token"))
      }
    }
  }

  func testDeviceCodeLoginRejectsNonHTTPSOrHostlessVerificationURL() async throws {
    for mode in [ScriptedCodexTransport.Mode.deviceCodeInsecureURL, .deviceCodeHostlessURL] {
      let transport = ScriptedCodexTransport(mode: mode)
      let client = CodexAppServerClient(transport: transport)

      await XCTAssertThrowsErrorAsync(try await client.startChatGPTDeviceCodeLogin()) { error in
        XCTAssertEqual(error as? CodexAppServerError, .invalidResponse)
      }
    }
  }

  func testLoginUsesChatGPTTypeAndDoesNotSendCredentials() async throws {
    let transport = ScriptedCodexTransport(mode: .login)
    let client = CodexAppServerClient(transport: transport)

    let login = try await client.startChatGPTLogin()

    XCTAssertEqual(login.loginID, "login-7")
    XCTAssertEqual(login.authURL.absoluteString, "https://auth.example.test/device?state=opaque")
    let messages = await transport.sentMessages()
    let loginMessage = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "account/login/start" })
    XCTAssertEqual(loginMessage["params"]?["type"]?.stringValue, "chatgpt")
    XCTAssertEqual(loginMessage["params"]?["useHostedLoginSuccessPage"]?.boolValue, true)
    XCTAssertEqual(loginMessage["params"]?["appBrand"]?.stringValue, "chatgpt")
    let serialized = String(data: await transport.sentBytes(), encoding: .utf8) ?? ""
    XCTAssertFalse(serialized.localizedCaseInsensitiveContains("token"))
    XCTAssertFalse(serialized.localizedCaseInsensitiveContains("authorization"))
  }

  func testLoginCompletionNotificationResumesWaiter() async throws {
    let transport = ScriptedCodexTransport(mode: .loginCompletion)
    let client = CodexAppServerClient(transport: transport)

    let login = try await client.startChatGPTLogin()
    try await client.waitForLoginCompletion(loginID: login.loginID)

    XCTAssertEqual(login.loginID, "login-7")
  }

  func testLoginFailureNotificationIsSurfaced() async throws {
    let transport = ScriptedCodexTransport(mode: .loginFailure)
    let client = CodexAppServerClient(transport: transport)
    let login = try await client.startChatGPTLogin()

    await XCTAssertThrowsErrorAsync(
      try await client.waitForLoginCompletion(loginID: login.loginID)
    ) { error in
      XCTAssertEqual(
        error as? CodexAppServerError,
        .rpc(code: nil, message: "Browser authorization was denied")
      )
    }
  }

  func testDeviceCodeLoginReturnsVerificationDetails() async throws {
    let transport = ScriptedCodexTransport(mode: .deviceCode)
    let client = CodexAppServerClient(transport: transport)

    let login = try await client.startChatGPTDeviceCodeLogin()

    XCTAssertEqual(login.loginID, "login-device-1")
    XCTAssertEqual(login.verificationURL.absoluteString, "https://auth.example.test/device")
    XCTAssertEqual(login.userCode, "ABCD-EFGH")
    let messages = await transport.sentMessages()
    let loginMessage = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "account/login/start" })
    XCTAssertEqual(loginMessage["params"]?["type"]?.stringValue, "chatgptDeviceCode")
  }

  func testCancellingLoginWaitCancelsRemoteLogin() async throws {
    let transport = ScriptedCodexTransport(mode: .hangingLogin)
    let client = CodexAppServerClient(transport: transport)
    let login = try await client.startChatGPTLogin()
    let task = Task {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }

    task.cancel()
    await XCTAssertThrowsErrorAsync(try await task.value) { error in
      XCTAssertEqual(error as? CodexAppServerError, .cancelled)
    }
    let didSendCancel = await transport.waitUntilSent(method: "account/login/cancel")
    XCTAssertTrue(didSendCancel, "Timed out waiting for account/login/cancel")
    let messages = await transport.sentMessages()
    let cancelMessage = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "account/login/cancel" }
    )
    XCTAssertEqual(cancelMessage["params"]?["loginId"]?.stringValue, "login-7")
  }

  func testLateLoginCompletionAfterCancellationIsNotBufferedAsSuccess() async throws {
    let transport = ScriptedCodexTransport(mode: .lateCompletionAfterCancel)
    let client = CodexAppServerClient(
      transport: transport,
      loginTimeout: .milliseconds(20)
    )
    let login = try await client.startChatGPTLogin()
    let waitTask = Task {
      try await client.waitForLoginCompletion(loginID: login.loginID)
    }

    for _ in 0..<100 {
      if await client.loginWaiterCount != 0 { break }
      await Task.yield()
    }
    let waiterCount = await client.loginWaiterCount
    XCTAssertEqual(waiterCount, 1)

    await client.cancelLogin(loginID: login.loginID)
    await XCTAssertThrowsErrorAsync(try await waitTask.value) { error in
      XCTAssertEqual(error as? CodexAppServerError, .cancelled)
    }

    await XCTAssertThrowsErrorAsync(
      try await client.waitForLoginCompletion(loginID: login.loginID)
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .loginTimedOut)
    }
    let cancelCount = await transport.sentMessageCount(method: "account/login/cancel")
    XCTAssertEqual(cancelCount, 1)
  }

  func testLoginWaitTimeoutCancelsOnceClearsWaiterAndKeepsRPCUsable() async throws {
    let transport = ScriptedCodexTransport(mode: .hangingLogin)
    let client = CodexAppServerClient(
      transport: transport,
      loginTimeout: .milliseconds(20)
    )
    let login = try await client.startChatGPTLogin()

    await XCTAssertThrowsErrorAsync(
      try await client.waitForLoginCompletion(loginID: login.loginID)
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .loginTimedOut)
      XCTAssertFalse(String(describing: error).contains("login-7"))
      XCTAssertFalse(String(describing: error).contains("http"))
    }

    let waiterCountAfterTimeout = await client.loginWaiterCount
    XCTAssertEqual(waiterCountAfterTimeout, 0)
    let didSendCancel = await transport.waitUntilSent(method: "account/login/cancel")
    XCTAssertTrue(didSendCancel, "Timed out waiting for account/login/cancel")
    // Allow the timeout task to finish its best-effort remote cancellation,
    // then ensure a cancellation handler cannot send a second request.
    try await Task.sleep(for: .milliseconds(20))
    let cancelCount = await transport.sentMessageCount(method: "account/login/cancel")
    XCTAssertEqual(cancelCount, 1)

    let account = try await client.accountStatus()
    XCTAssertTrue(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "acct-1")
    let waiterCountAfterRPC = await client.loginWaiterCount
    XCTAssertEqual(waiterCountAfterRPC, 0)
  }

  func testRateLimitsAndLogoutUseTypedResponses() async throws {
    let transport = ScriptedCodexTransport(mode: .rateLimits)
    let client = CodexAppServerClient(transport: transport)

    let limits = try await client.rateLimits()
    try await client.logout()

    XCTAssertEqual(limits.primary?.usedPercent, 25)
    XCTAssertEqual(limits.primary?.windowMinutes, 300)
    XCTAssertEqual(limits.creditsRemaining, 42)
    XCTAssertEqual(limits.planType, "pro")
    let messages = await transport.sentMessages()
    XCTAssertEqual(
      messages.compactMap { $0["method"]?.stringValue },
      ["initialize", "initialized", "account/rateLimits/read", "account/logout"]
    )
  }

  func testModelListReturnsVisibleModelsAndSupportsMissingOptionalFields() async throws {
    let transport = ScriptedCodexTransport(mode: .modelCatalogSingle)
    let client = CodexAppServerClient(transport: transport)

    let models = try await client.models()

    XCTAssertEqual(models.map(\.id), ["visible-model"])
    let model = try XCTUnwrap(models.first)
    XCTAssertEqual(model.model, "visible-model")
    XCTAssertEqual(model.displayName, "Visible Model")
    XCTAssertEqual(model.description, "A visible model")
    XCTAssertFalse(model.hidden)
    XCTAssertEqual(model.defaultReasoningEffort, "medium")
    XCTAssertEqual(model.supportedReasoningEfforts.map(\.reasoningEffort), ["low", "high"])
    XCTAssertEqual(model.inputModalities, ["text"])
    XCTAssertTrue(model.isDefault)
    XCTAssertEqual(model.upgrade, "pro")

    let decoder = JSONDecoder()
    let modelOnly = try decoder.decode(
      CodexAppServerModel.self,
      from: Data(#"{"model":" model-only "}"#.utf8)
    )
    XCTAssertEqual(modelOnly.id, "model-only")
    XCTAssertEqual(modelOnly.displayName, "model-only")
    XCTAssertEqual(modelOnly.inputModalities, ["text", "image"])

    let messages = await transport.sentMessages()
    let request = try XCTUnwrap(messages.first { $0["method"]?.stringValue == "model/list" })
    XCTAssertEqual(request["params"]?["includeHidden"]?.boolValue, false)
    XCTAssertEqual(request["params"]?["limit"]?.intValue, 100)
  }

  func testModelListFollowsCursorPaginationAndCanIncludeHiddenModels() async throws {
    let transport = ScriptedCodexTransport(mode: .modelCatalogPagination)
    let client = CodexAppServerClient(transport: transport)

    let models = try await client.models(includeHidden: true)

    XCTAssertEqual(models.map(\.id), ["page-one-model", "hidden-model", "page-two-model"])
    let messages = await transport.sentMessages()
    let requests = messages.filter { $0["method"]?.stringValue == "model/list" }
    XCTAssertEqual(requests.count, 2)
    XCTAssertNil(requests[0]["params"]?["cursor"]?.stringValue)
    XCTAssertEqual(requests[1]["params"]?["cursor"]?.stringValue, "page-two")
    XCTAssertTrue(requests.allSatisfy { $0["params"]?["includeHidden"]?.boolValue == true })
  }

  func testModelListStopsWhenServerRepeatsCursor() async throws {
    let transport = ScriptedCodexTransport(mode: .modelCatalogLoop)
    let client = CodexAppServerClient(transport: transport)

    let models = try await client.models()

    XCTAssertEqual(models.map(\.id), ["loop-one", "loop-two"])
    let requests = await transport.sentMessages().filter {
      $0["method"]?.stringValue == "model/list"
    }
    XCTAssertEqual(requests.count, 2)
  }

  func testModelListRejectsAbnormalResponse() async throws {
    let transport = ScriptedCodexTransport(mode: .modelCatalogInvalid)
    let client = CodexAppServerClient(transport: transport)

    await XCTAssertThrowsErrorAsync(try await client.models()) { error in
      XCTAssertEqual(error as? CodexAppServerError, .invalidResponse)
    }
  }

  func testChunkedJSONLAndAgentMessageDeltasProduceCompletion() async throws {
    let transport = ScriptedCodexTransport(mode: .completion)
    let client = CodexAppServerClient(transport: transport)

    let completion = try await client.complete(
      prompt: "Write a short title",
      model: " gpt-5-codex ",
      reasoningEffort: " high ",
      workingDirectory: URL(fileURLWithPath: "/tmp/project")
    )

    XCTAssertEqual(completion.text, "Hello world")
    XCTAssertEqual(completion.threadID, "thread-1")
    XCTAssertEqual(completion.turnID, "turn-1")
    XCTAssertEqual(completion.model, "gpt-5-codex")

    let messages = await transport.sentMessages()
    let threadStart = try XCTUnwrap(messages.first { $0["method"]?.stringValue == "thread/start" })
    XCTAssertEqual(threadStart["params"]?["ephemeral"]?.boolValue, true)
    XCTAssertEqual(threadStart["params"]?["sandbox"]?.stringValue, "read-only")
    XCTAssertNil(threadStart["params"]?["dynamicTools"])
    XCTAssertEqual(threadStart["params"]?["approvalPolicy"]?.stringValue, "never")
    XCTAssertTrue(
      threadStart["params"]?["developerInstructions"]?.stringValue?.contains(
        "Never inspect the filesystem") == true
    )
    XCTAssertEqual(threadStart["params"]?["cwd"]?.stringValue, "/tmp/project")
    let turnStart = try XCTUnwrap(messages.first { $0["method"]?.stringValue == "turn/start" })
    XCTAssertEqual(turnStart["params"]?["threadId"]?.stringValue, "thread-1")
    XCTAssertEqual(turnStart["params"]?["effort"]?.stringValue, "high")
    XCTAssertEqual(
      turnStart["params"]?["input"]?.arrayValue?.first?["text"]?.stringValue, "Write a short title")
  }

  func testTurnFailedIsSurfacedAsTypedError() async throws {
    let transport = ScriptedCodexTransport(mode: .turnFailure)
    let client = CodexAppServerClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(prompt: "fail")
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .turnFailed("model unavailable"))
    }
  }

  func testCompletedFailureStatusIsSurfacedAsTypedError() async throws {
    let transport = ScriptedCodexTransport(mode: .completedFailure)
    let client = CodexAppServerClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.complete(prompt: "fail")
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .turnFailed("quota exceeded"))
    }
  }

  func testEOFFailsPendingRequest() async throws {
    let transport = ScriptedCodexTransport(mode: .eofAfterHandshake)
    let client = CodexAppServerClient(transport: transport)

    await XCTAssertThrowsErrorAsync(
      try await client.accountStatus()
    ) { error in
      XCTAssertEqual(error as? CodexAppServerError, .endOfStream)
    }
  }

  func testRPCRequestTimeoutCleansPendingContinuationAndIgnoresLateResponse() async throws {
    let transport = ScriptedCodexTransport(mode: .lateAccountResponse)
    let client = CodexAppServerClient(
      transport: transport,
      requestTimeout: .milliseconds(20)
    )

    await XCTAssertThrowsErrorAsync(try await client.accountStatus()) { error in
      XCTAssertEqual(error as? CodexAppServerError, .requestTimedOut)
    }

    // The delayed response for request 2 must not resume a consumed
    // continuation. A later request remains usable and is routed by its own
    // request ID.
    try await Task.sleep(for: .milliseconds(40))
    let account = try await client.accountStatus()
    XCTAssertEqual(account.accountID, "acct-1")
    let accountReadCount = await transport.sentMessageCount(method: "account/read")
    XCTAssertEqual(accountReadCount, 2)
  }

  func testTurnTimeoutInterruptsAndCleansActiveTurn() async throws {
    let transport = ScriptedCodexTransport(mode: .hangingTurn)
    let client = CodexAppServerClient(
      transport: transport,
      turnTimeout: .milliseconds(20)
    )

    await XCTAssertThrowsErrorAsync(try await client.complete(prompt: "timeout this turn")) {
      error in
      XCTAssertEqual(error as? CodexAppServerError, .turnTimedOut)
    }
    let didSendInterrupt = await transport.waitUntilSent(method: "turn/interrupt")
    XCTAssertTrue(didSendInterrupt, "Timed out waiting for turn/interrupt")
    let activeTurn = await client.activeTurnSnapshot
    XCTAssertNil(activeTurn)
  }

  func testEOFStartsFreshTransportGenerationOnNextOperation() async throws {
    let factory = SequencedCodexTransportFactory()
    let client = CodexAppServerClient(
      transportFactory: { factory.make() },
      requestTimeout: .milliseconds(100)
    )

    await XCTAssertThrowsErrorAsync(try await client.accountStatus()) { error in
      XCTAssertEqual(error as? CodexAppServerError, .endOfStream)
    }

    let account = try await client.accountStatus()
    XCTAssertTrue(account.isAuthenticated)
    XCTAssertEqual(account.accountID, "acct-1")
    XCTAssertEqual(factory.makeCount, 2)
  }

  func testCancellingActiveCompletionInterruptsRemoteTurn() async throws {
    let transport = ScriptedCodexTransport(mode: .hangingTurn)
    let client = CodexAppServerClient(transport: transport)
    let task = Task {
      try await client.complete(prompt: "cancel this turn")
    }

    let didSendTurnStart = await transport.waitUntilSent(method: "turn/start")
    guard didSendTurnStart else {
      task.cancel()
      _ = await task.result
      XCTFail("Timed out waiting for turn/start")
      return
    }
    let activeTurn = await waitForActiveTurn(client: client)
    guard let activeTurn else {
      task.cancel()
      _ = await task.result
      XCTFail("Timed out waiting for an active turn")
      return
    }
    XCTAssertEqual(activeTurn.threadID, "thread-1")
    XCTAssertEqual(activeTurn.turnID, "turn-1")
    task.cancel()
    await XCTAssertThrowsErrorAsync(try await task.value) { error in
      XCTAssertEqual(error as? CodexAppServerError, .cancelled)
    }
    let didSendInterrupt = await transport.waitUntilSent(method: "turn/interrupt")
    XCTAssertTrue(didSendInterrupt, "Timed out waiting for turn/interrupt")

    let messages = await transport.sentMessages()
    let interrupt = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "turn/interrupt" }
    )
    XCTAssertEqual(interrupt["params"]?["threadId"]?.stringValue, "thread-1")
    XCTAssertEqual(interrupt["params"]?["turnId"]?.stringValue, "turn-1")
  }

  func testDynamicToolCallIsReturnedToHostAndAcknowledgedWithoutLocalExecution() async throws {
    let transport = ScriptedCodexTransport(mode: .dynamicTool)
    let client = CodexAppServerClient(
      transport: transport,
      requestTimeout: .seconds(1),
      turnTimeout: .seconds(1)
    )
    let tool = AIToolDefinition(
      function: AIToolFunctionDefinition(
        name: "createDraft",
        description: "Create a blank local draft.",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "value": .object(["type": .string("string")])
          ]),
          "additionalProperties": .bool(false),
        ])
      )
    )

    let completion = try await client.complete(
      prompt: "Create one draft.",
      dynamicTools: [tool]
    )

    XCTAssertEqual(completion.text, "")
    XCTAssertEqual(completion.toolCalls.count, 1)
    XCTAssertEqual(completion.toolCalls.first?.id, "dynamic-call-1")
    XCTAssertEqual(completion.toolCalls.first?.function.name, "createDraft")
    XCTAssertEqual(
      completion.toolCalls.first?.function.arguments,
      #"{"value":"Codex 动态文章"}"#
    )

    let messages = await transport.sentMessages()
    let threadStart = try XCTUnwrap(
      messages.first { $0["method"]?.stringValue == "thread/start" }
    )
    let dynamicTools = try XCTUnwrap(
      threadStart["params"]?["dynamicTools"]?.arrayValue
    )
    XCTAssertEqual(dynamicTools.count, 1)
    XCTAssertEqual(dynamicTools.first?["type"]?.stringValue, "function")
    XCTAssertEqual(dynamicTools.first?["name"]?.stringValue, "createDraft")
    XCTAssertEqual(
      dynamicTools.first?["inputSchema"]?["type"]?.stringValue,
      "object"
    )
    XCTAssertEqual(
      dynamicTools.first?["inputSchema"]?["properties"]?["value"]?["type"]?.stringValue,
      "string"
    )
    let response = try XCTUnwrap(
      messages.first { $0["id"]?.intValue == 91 && $0["method"] == nil }
    )
    XCTAssertEqual(response["result"]?["success"]?.boolValue, true)
    XCTAssertEqual(
      response["result"]?["contentItems"]?.arrayValue?.first?["type"]?.stringValue,
      "inputText"
    )
  }

}

private enum RuntimeProbeTestError: Error {
  case launchSignalEnded
  case launchTimedOut
}

private actor ScriptedCodexTransport: CodexAppServerTransport {
  enum Mode: Equatable {
    case account
    case accountRequiresAuth
    case accountMetadataOnly
    case login
    case loginInsecureURL
    case loginHostlessURL
    case loginUserInfoURL
    case loginCompletion
    case loginFailure
    case lateCompletionAfterCancel
    case deviceCode
    case deviceCodeInsecureURL
    case deviceCodeHostlessURL
    case hangingLogin
    case rateLimits
    case modelCatalogSingle
    case modelCatalogPagination
    case modelCatalogLoop
    case modelCatalogInvalid
    case completion
    case turnFailure
    case completedFailure
    case hangingTurn
    case dynamicTool
    case lateAccountResponse
    case eofAfterHandshake
  }

  private let mode: Mode
  private var queuedChunks: [Data] = []
  private var waitingReceivers: [CheckedContinuation<Data?, Error>] = []
  private var messages: [CodexAppServerJSONValue] = []
  private var bytes = Data()
  private var isClosed = false

  init(mode: Mode) {
    self.mode = mode
  }

  func start() async throws {}

  func send(_ data: Data) async throws {
    guard !isClosed else { throw CodexAppServerError.endOfStream }
    bytes.append(data)
    let line = data.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D })
    guard let object = try? JSONDecoder().decode(CodexAppServerJSONValue.self, from: line)
    else { return }
    messages.append(object)
    guard let method = object["method"]?.stringValue else {
      if mode == .dynamicTool, object["id"]?.intValue == 91 {
        enqueue(
          json: #"""
            {"method":"turn/completed","params":{"threadId":"thread-1","turnId":"turn-1"}}
            """#
        )
      }
      return
    }
    let requestID = object["id"]?.intValue ?? 0

    switch method {
    case "initialize":
      enqueue(
        json: """
          {"id":\(requestID),"result":{"serverInfo":{"version":"1"}}}
          """
      )
    case "account/read":
      if mode == .lateAccountResponse && requestID == 2 {
        Task { [weak self] in
          try? await Task.sleep(for: .milliseconds(50))
          await self?.enqueue(
            json: """
              {"id":\(requestID),"result":{"authenticated":true,"account":{"id":"late-acct","type":"chatgpt"}}}
              """
          )
        }
      } else if mode == .accountRequiresAuth {
        enqueue(
          json: """
            {"id":\(requestID),"result":{"authenticated":false,"account":{"id":"stale-acct","type":"chatgpt","email":"stale@example.com"},"requiresOpenaiAuth":true}}
            """
        )
      } else if mode == .accountMetadataOnly {
        enqueue(
          json: """
            {"id":\(requestID),"result":{"account":{"id":"metadata-acct","type":"chatgpt","email":"metadata@example.com"}}}
            """
        )
      } else {
        enqueue(
          json: """
            {"id":\(requestID),"result":{"authenticated":true,"account":{"id":"acct-1","type":"chatgpt","email":"writer@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
            """
        )
      }
    case "account/login/start":
      if mode == .deviceCode {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-device-1","verificationUrl":"https://auth.example.test/device","userCode":"ABCD-EFGH"}}
            """#)
      } else if mode == .deviceCodeInsecureURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-device-1","verificationUrl":"http://auth.example.test/device","userCode":"ABCD-EFGH"}}
            """#)
      } else if mode == .deviceCodeHostlessURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-device-1","verificationUrl":"https:///device","userCode":"ABCD-EFGH"}}
            """#)
      } else if mode == .loginInsecureURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"http://auth.example.test/device?token=secret"}}
            """#)
      } else if mode == .loginHostlessURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https:///device?token=secret"}}
            """#)
      } else if mode == .loginUserInfoURL {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://user:password@auth.example.test/device?token=secret"}}
            """#)
      } else if mode == .loginCompletion {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://auth.example.test/device"}}
            {"method":"account/login/completed","params":{"loginId":"login-7","success":true}}
            """#)
      } else if mode == .loginFailure {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://auth.example.test/device"}}
            {"method":"account/login/completed","params":{"loginId":"login-7","success":false,"error":{"message":"Browser authorization was denied"}}}
            """#)
      } else {
        enqueue(
          json: #"""
            {"id":2,"result":{"loginId":"login-7","authUrl":"https://auth.example.test/device?state=opaque"}}
            """#)
      }
    case "account/login/cancel":
      if mode == .lateCompletionAfterCancel {
        enqueue(
          json: """
            {"id":\(requestID),"result":{}}
            {"method":"account/login/completed","params":{"loginId":"login-7","success":true}}
            """
        )
      } else {
        enqueue(
          json: """
            {"id":\(requestID),"result":{}}
            """
        )
      }
    case "account/rateLimits/read":
      enqueue(
        json: #"""
          {"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300},"creditsRemaining":42,"planType":"pro"}}}
          """#)
    case "account/logout":
      enqueue(
        json: #"""
          {"id":3,"result":{}}
          """#)
    case "model/list":
      switch mode {
      case .modelCatalogSingle:
        enqueue(
          json: #"""
            {"id":2,"result":{"data":[{"id":" visible-model ","model":" visible-model ","displayName":" Visible Model ","description":" A visible model ","hidden":false,"defaultReasoningEffort":" medium ","supportedReasoningEfforts":[{"reasoningEffort":" low ","description":" quick "},{"effort":" high "}],"inputModalities":[" text "," "],"isDefault":true,"upgrade":" pro "},{"id":"hidden-model","hidden":true}],"nextCursor":" "}}
            """#)
      case .modelCatalogPagination:
        if object["params"]?["cursor"]?.stringValue == nil {
          enqueue(
            json: #"""
              {"id":2,"result":{"data":[{"id":" page-one-model ","model":" page-one-model ","displayName":"Page One"},{"id":"hidden-model","hidden":true},{"id":"page-one-model","model":"page-one-model"}],"nextCursor":" page-two "}}
              """#)
        } else {
          enqueue(
            json: #"""
              {"id":3,"result":{"data":[{"id":"page-two-model","model":"page-two-model","displayName":"Page Two"}],"nextCursor":" "}}
              """#)
        }
      case .modelCatalogLoop:
        if object["params"]?["cursor"]?.stringValue == nil {
          enqueue(
            json: #"""
              {"id":2,"result":{"data":[{"id":"loop-one","model":"loop-one"}],"nextCursor":" loop "}}
              """#)
        } else {
          enqueue(
            json: #"""
              {"id":3,"result":{"data":[{"id":"loop-two","model":"loop-two"}],"nextCursor":" loop "}}
              """#)
        }
      case .modelCatalogInvalid:
        enqueue(
          json: #"""
            {"id":2,"result":{"data":{"not":"an array"}}}
            """#)
      default:
        break
      }
    case "thread/start":
      enqueue(
        json: #"""
          {"id":2,"result":{"thread":{"id":"thread-1","model":"gpt-5-codex"}}}
          """#)
    case "turn/start":
      switch mode {
      case .turnFailure:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            {"method":"turn/failed","params":{"threadId":"thread-1","turnId":"turn-1","error":{"message":"model unavailable"}}}
            """#)
      case .completedFailure:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            {"method":"turn/completed","params":{"threadId":"thread-1","turnId":"turn-1","turn":{"id":"turn-1","status":"failed","error":{"message":"quota exceeded"}}}}
            """#)
      case .hangingTurn:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            """#)
      case .dynamicTool:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            {"id":91,"method":"item/tool/call","params":{"threadId":"thread-1","turnId":"turn-1","callId":"dynamic-call-1","tool":"createDraft","arguments":{"value":"Codex 动态文章"}}}
            """#)
      default:
        enqueue(
          json: #"""
            {"id":3,"result":{"turn":{"id":"turn-1"}}}
            {"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","delta":"Hello "}}
            {"method":"item/agentMessage/delta","params":{"threadId":"thread-1","turnId":"turn-1","delta":"world"}}
            {"method":"turn/completed","params":{"threadId":"thread-1","turnId":"turn-1"}}
            """#)
      }
    case "turn/interrupt":
      if mode == .hangingTurn {
        enqueue(
          json: #"""
            {"id":4,"result":{}}
            """#)
      }
    case "initialized":
      if mode == .eofAfterHandshake {
        close()
      }
    default:
      break
    }
  }

  func receive() async throws -> Data? {
    if !queuedChunks.isEmpty {
      return queuedChunks.removeFirst()
    }
    if isClosed {
      return nil
    }
    return try await withCheckedThrowingContinuation { continuation in
      waitingReceivers.append(continuation)
    }
  }

  func terminate() async {
    close()
  }

  func sentMessages() -> [CodexAppServerJSONValue] {
    messages
  }

  func sentBytes() -> Data {
    bytes
  }

  func sentMessageCount(method: String) -> Int {
    messages.reduce(into: 0) { count, message in
      if message["method"]?.stringValue == method {
        count += 1
      }
    }
  }

  func waitUntilSent(method: String, timeout: Duration = .seconds(5)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !messages.contains(where: { $0["method"]?.stringValue == method }) {
      guard clock.now < deadline else { return false }
      try? await clock.sleep(for: .milliseconds(1))
    }
    return true
  }

  private func enqueue(json: String) {
    let data = Data((json + "\n").utf8)
    guard mode == .completion || mode == .turnFailure || json.contains("serverInfo") else {
      deliver(data)
      return
    }

    if mode == .completion || mode == .turnFailure {
      // Feed stdout in deliberately awkward chunks so the client must assemble JSONL lines.
      let splitPoints = [min(7, data.count), min(19, data.count)]
      var start = data.startIndex
      for point in splitPoints where point > start {
        let end = data.index(data.startIndex, offsetBy: point)
        deliver(Data(data[start..<end]))
        start = end
      }
      if start < data.endIndex {
        deliver(Data(data[start..<data.endIndex]))
      }
    } else {
      deliver(data)
    }
  }

  private func deliver(_ data: Data) {
    if let receiver = waitingReceivers.first {
      waitingReceivers.removeFirst()
      receiver.resume(returning: data)
    } else {
      queuedChunks.append(data)
    }
  }

  private func close() {
    isClosed = true
    let receivers = waitingReceivers
    waitingReceivers.removeAll()
    for receiver in receivers {
      receiver.resume(returning: nil)
    }
  }
}

private final class SequencedCodexTransportFactory: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var makeCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func make() -> any CodexAppServerTransport {
    lock.lock()
    count += 1
    let generation = count
    lock.unlock()
    return ScriptedCodexTransport(mode: generation == 1 ? .eofAfterHandshake : .account)
  }
}

private func waitForActiveTurn(
  client: CodexAppServerClient,
  timeout: Duration = .seconds(5)
) async -> CodexAppServerClient.ActiveTurnSnapshot? {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while true {
    if let snapshot = await client.activeTurnSnapshot {
      return snapshot
    }
    guard clock.now < deadline else { return nil }
    try? await clock.sleep(for: .milliseconds(1))
  }
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ handler: (Error) -> Void
) async {
  do {
    _ = try await expression()
    XCTFail("Expected expression to throw")
  } catch {
    handler(error)
  }
}
