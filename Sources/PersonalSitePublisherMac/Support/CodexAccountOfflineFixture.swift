import Foundation
import SwiftUI

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  import Combine
  import PublishingAICore
  import PublishingWorkbenchCore
#endif

/// An opt-in host for the production account section with in-memory effects.
@MainActor
struct CodexAccountOfflineFixture: View {
  static let environmentKey = "PERSONAL_SITE_PUBLISHER_CODEX_ACCOUNT_FIXTURE"

  static var isEnabled: Bool {
    #if DEBUG || SCREENSHOT_CAPTURE_BUILD
      let environment = ProcessInfo.processInfo.environment
      return environment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_DEMO"] == "1"
        && environment["PERSONAL_SITE_PUBLISHER_SCREENSHOT_UI_TEST"] == "1"
        && !(environment[environmentKey] ?? "")
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    #else
      return false
    #endif
  }

  #if DEBUG || SCREENSHOT_CAPTURE_BUILD
    @StateObject private var context: CodexAccountOfflineFixtureContext

    init() {
      let mode =
        CodexAccountOfflineFixtureMode(
          rawValue: ProcessInfo.processInfo.environment[Self.environmentKey] ?? ""
        ) ?? .browserFailure
      _context = StateObject(wrappedValue: CodexAccountOfflineFixtureContext(mode: mode))
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        fixtureControls
        if context.showsAccount {
          Form {
            accountSection
          }
          .formStyle(.grouped)
        } else {
          Text(verbatim: "Account section is hidden.")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .padding(16)
      .frame(minWidth: 1000, minHeight: 950)
      .accessibilityElement(children: .contain)
      .accessibilityIdentifier("codex-account-offline-fixture")
    }

    private var fixtureControls: some View {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 16) {
          Text(verbatim: "Offline Codex account fixture")
            .font(.headline)
          Text(verbatim: context.mode.rawValue)
          Spacer()
          Text(verbatim: "Models:")
          Text(verbatim: String(context.modelReadCount))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: String(context.modelReadCount)))
            .accessibilityIdentifier("fixture-model-read-count")
          Text(verbatim: "Tests:")
          Text(verbatim: String(context.testCount))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: String(context.testCount)))
            .accessibilityIdentifier("fixture-test-count")
          Text(verbatim: context.testState)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: context.testState))
            .accessibilityIdentifier("fixture-test-state")
        }
        .accessibilityElement(children: .contain)
        HStack(spacing: 12) {
          Button(action: { context.completeLogin(succeeded: true) }) {
            Text(verbatim: "Complete login")
          }
          .accessibilityIdentifier("fixture-login-success")
          Button(action: { context.completeLogin(succeeded: false) }) {
            Text(verbatim: "Fail login")
          }
          .accessibilityIdentifier("fixture-login-fail")
          Button(action: context.completeTest) {
            Text(verbatim: "Complete test")
          }
          .accessibilityIdentifier("fixture-test-complete")
          Button(action: context.switchConnection) {
            Text(verbatim: "Switch connection")
          }
          .accessibilityIdentifier("fixture-switch-connection")
          Button(action: context.hideAccount) {
            Text(verbatim: "Hide account")
          }
          .accessibilityIdentifier("fixture-hide-account")
        }
      }
    }

    private var accountSection: some View {
      let connectionID = context.connectionID
      return CodexAppServerAccountSection(
        connectionID: connectionID,
        model: $context.model,
        reasoningEffortOverride: $context.reasoningEffortOverride,
        isCodexDataSharingConsentGranted: {
          context.hasConsent(for: $0, connectionID: connectionID)
        },
        grantConsentForConnection: {
          context.grantConsent(for: $0, connectionID: connectionID)
        },
        dependencies: context.dependencies,
        testConnection: { isCurrent in
          await context.testConnection(connectionID: connectionID, isCurrent: isCurrent)
        }
      )
      .id(connectionID)
    }
  #else
    var body: some View { EmptyView() }
  #endif
}

#if DEBUG || SCREENSHOT_CAPTURE_BUILD
  private enum CodexAccountOfflineFixtureMode: String {
    case browserFailure, device, ready
  }

  @MainActor
  private final class CodexAccountOfflineFixtureContext: ObservableObject {
    let mode: CodexAccountOfflineFixtureMode
    let connection: CodexConnectionController
    let login: CodexAccountLoginCoordinator
    private let service: FakeCodexLoginService
    private var consentConnectionIDs: Set<UUID>
    private var latestTestID: UUID?

    @Published var connectionID: UUID
    @Published var showsAccount = true
    @Published var model = AIProviderPreset.codexDefaultModel
    @Published var reasoningEffortOverride: String?
    @Published private(set) var modelReadCount = 0
    @Published private(set) var testCount = 0
    @Published private(set) var testState = "空闲"
    private(set) var openURLCount = 0
    private(set) var copiedCodes: [String] = []

    init(mode: CodexAccountOfflineFixtureMode) {
      let connectionID = UUID()
      let service = FakeCodexLoginService(
        authenticated: mode == .ready, holdsCancelledTests: mode == .ready
      )
      // No directory or executable is created. Runtime setup only reads this
      // isolated, nonexistent location; the compatible status exposes no setup
      // action that could prepare or download a component.
      let runtimeDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexAccountOfflineFixture", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let runtime = CodexAppServerRuntimeStatus(
        executableURL: runtimeDirectory.appendingPathComponent("nonexecutable-codex"),
        version: "codex-cli \(CodexRuntimeSetupService.recommendedVersion.description)"
      )
      let connection = CodexConnectionController(
        service: CodexRuntimeSetupService(directory: runtimeDirectory),
        inspect: { runtime },
        readAccount: { await service.accountStatus() },
        readRateLimits: { await service.rateLimits() }
      )
      self.mode = mode
      self.connectionID = connectionID
      self.service = service
      self.connection = connection
      consentConnectionIDs = mode == .ready ? [connectionID] : []
      login = CodexAccountLoginCoordinator(
        service: service,
        accountDidChange: { await connection.accountDidChange() },
        accountStatus: { connection.accountStatus }
      )
    }

    deinit {
      let service = service
      Task { await service.shutdown() }
    }

    var dependencies: CodexAccountSectionDependencies {
      .init(
        connection: connection,
        login: login,
        loadModels: { [weak self] in
          guard let self else { return [] }
          return await self.loadModels()
        },
        openURL: { [weak self] _ in
          self?.openURLCount += 1
          return false
        },
        copyCode: { [weak self] code in self?.copiedCodes.append(code) }
      )
    }

    private func loadModels() async -> [CodexAppServerModel] {
      modelReadCount += 1
      return await service.models()
    }

    func hasConsent(for account: CodexAppServerAccountStatus?, connectionID: UUID) -> Bool {
      account?.isAuthenticated == true && consentConnectionIDs.contains(connectionID)
    }

    func grantConsent(for account: CodexAppServerAccountStatus, connectionID: UUID) {
      guard account.isAuthenticated, self.connectionID == connectionID, showsAccount else { return }
      consentConnectionIDs.insert(connectionID)
      objectWillChange.send()
    }

    func completeLogin(succeeded: Bool) {
      Task { await service.completeActiveLogin(succeeded: succeeded) }
    }

    func completeTest() {
      guard let latestTestID else { return }
      Task { await service.completeConnectionTest(id: latestTestID) }
    }

    func switchConnection() {
      connectionID = UUID()
      if mode == .ready { consentConnectionIDs.insert(connectionID) }
      showsAccount = true
    }

    func hideAccount() { showsAccount = false }

    func testConnection(
      connectionID: UUID, isCurrent: @MainActor () -> Bool
    ) async -> AIConnectionTestReport? {
      guard self.connectionID == connectionID, showsAccount,
        !Task.isCancelled, isCurrent()
      else { return nil }
      let testID = UUID()
      latestTestID = testID
      let requestedModel = model
      testCount += 1
      testState = "等待"
      do {
        try await service.waitForConnectionTest(id: testID)
      } catch {
        recordDiscardedTest(id: testID)
        return nil
      }
      guard self.connectionID == connectionID, showsAccount,
        !Task.isCancelled, isCurrent(), latestTestID == testID
      else {
        recordDiscardedTest(id: testID)
        return nil
      }
      testState = "通过"
      return AIConnectionTestReport(
        providerName: "ChatGPT",
        model: "fixture-model",
        endpoint: FakeCodexLoginService.fixtureURL,
        responsePreview: "Offline fixture response",
        requestedModel: requestedModel
      )
    }

    private func recordDiscardedTest(id: UUID) {
      // This is a host diagnostic, not a write to the originating section.
      // An older completion cannot overwrite a newer fixture test's state.
      guard latestTestID == id else { return }
      testState = "丢弃"
    }
  }

  /// Login and test waiters are independent so a catalog refresh cannot finish
  /// a held connection test. Ready-mode tests deliberately ignore cancellation
  /// until released, exercising the originating view's stale-context guard.
  /// Every terminal transition resumes once, with a bounded wait as a fallback.
  private actor FakeCodexLoginService: CodexAccountLoginServing {
    static let fixtureURL =
      URL(string: "https://fixture.invalid/activate")
      ?? URL(fileURLWithPath: "/offline-fixture/activate")

    private enum LoginOutcome: Equatable {
      case succeeded, failed, cancelled
    }

    private struct LoginSession {
      var outcome: LoginOutcome?
      var continuation: CheckedContinuation<Void, Error>?
    }

    private enum TestSession {
      case waiting(CheckedContinuation<Void, Error>)
      case completed, cancelled
    }

    private var authenticated: Bool
    private let holdsCancelledTests: Bool
    private var activeLoginID: String?
    private var logins: [String: LoginSession] = [:]
    private var tests: [UUID: TestSession] = [:]
    private var testExpiryTasks: [UUID: Task<Void, Never>] = [:]

    init(authenticated: Bool, holdsCancelledTests: Bool) {
      self.authenticated = authenticated
      self.holdsCancelledTests = holdsCancelledTests
    }

    func accountStatus() -> CodexAppServerAccountStatus {
      guard authenticated else { return .init(isAuthenticated: false) }
      return .init(
        isAuthenticated: true,
        accountID: "offline-fixture-account",
        accountType: "chatgpt",
        email: "fixture@example.invalid",
        planType: "plus"
      )
    }

    func rateLimits() -> CodexAppServerRateLimits {
      .init(
        primary: .init(usedPercent: 24, windowMinutes: 300),
        secondary: .init(usedPercent: 12, windowMinutes: 10080),
        planType: "plus"
      )
    }

    func models() -> [CodexAppServerModel] {
      [
        .init(
          id: "fixture-model",
          displayName: "Offline fixture model",
          defaultReasoningEffort: "medium",
          supportedReasoningEfforts: [
            .init(reasoningEffort: "low"),
            .init(reasoningEffort: "medium"),
            .init(reasoningEffort: "high"),
          ],
          isDefault: true
        )
      ]
    }

    func startChatGPTLogin() async throws -> CodexAppServerLoginResult {
      try Task.checkCancellation()
      return .init(loginID: beginLogin(), authURL: Self.fixtureURL)
    }

    func startChatGPTDeviceCodeLogin() async throws -> CodexAppServerDeviceCodeLoginResult {
      try Task.checkCancellation()
      return .init(
        loginID: beginLogin(), verificationURL: Self.fixtureURL, userCode: "ABCD-EFGH"
      )
    }

    private func beginLogin() -> String {
      if let activeLoginID { finishLogin(id: activeLoginID, outcome: .cancelled) }
      let loginID = UUID().uuidString
      // Retain only unfinished sessions plus the new attempt. The coordinator
      // owns one login flow and never waits again on a completed attempt.
      logins = logins.filter { $0.value.outcome == nil }
      logins[loginID] = .init()
      activeLoginID = loginID
      return loginID
    }

    func waitForLoginCompletion(loginID: String) async throws {
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          guard var session = logins[loginID] else {
            continuation.resume(throwing: CodexAppServerError.invalidResponse)
            return
          }
          if Task.isCancelled {
            finishLogin(id: loginID, outcome: .cancelled)
            continuation.resume(throwing: CancellationError())
          } else if let outcome = session.outcome {
            resumeLogin(continuation, outcome: outcome)
          } else if session.continuation != nil {
            continuation.resume(throwing: CodexAppServerError.invalidResponse)
          } else {
            session.continuation = continuation
            logins[loginID] = session
          }
        }
      } onCancel: {
        Task { await self.cancelLogin(loginID: loginID) }
      }
    }

    func cancelLogin(loginID: String) async { finishLogin(id: loginID, outcome: .cancelled) }

    func completeActiveLogin(succeeded: Bool) {
      guard let activeLoginID else { return }
      finishLogin(id: activeLoginID, outcome: succeeded ? .succeeded : .failed)
    }

    private func finishLogin(id: String, outcome: LoginOutcome) {
      guard var session = logins[id], session.outcome == nil else { return }
      session.outcome = outcome
      let continuation = session.continuation
      session.continuation = nil
      logins[id] = session
      if activeLoginID == id { activeLoginID = nil }
      if case .succeeded = outcome { authenticated = true }
      if let continuation { resumeLogin(continuation, outcome: outcome) }
    }

    private func resumeLogin(
      _ continuation: CheckedContinuation<Void, Error>, outcome: LoginOutcome
    ) {
      switch outcome {
      case .succeeded: continuation.resume()
      case .cancelled: continuation.resume(throwing: CancellationError())
      case .failed:
        continuation.resume(
          throwing: CodexAppServerError.rpc(code: -1, message: "Offline fixture login failed."))
      }
    }

    func logout() async throws {
      try Task.checkCancellation()
      if let activeLoginID { finishLogin(id: activeLoginID, outcome: .cancelled) }
      authenticated = false
    }

    func waitForConnectionTest(id: UUID) async throws {
      try await withTaskCancellationHandler {
        if !holdsCancelledTests { try Task.checkCancellation() }
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          if Task.isCancelled, !holdsCancelledTests {
            cancelConnectionTest(id: id)
            continuation.resume(throwing: CancellationError())
            return
          }
          switch tests[id] {
          case .completed: continuation.resume()
          case .cancelled: continuation.resume(throwing: CancellationError())
          case .waiting: continuation.resume(throwing: CodexAppServerError.invalidResponse)
          case nil:
            tests = tests.filter { _, value in
              if case .waiting = value { return true }
              return false
            }
            tests[id] = .waiting(continuation)
            testExpiryTasks[id] = Task { [weak self] in
              do { try await Task.sleep(for: .seconds(60)) } catch { return }
              await self?.cancelConnectionTest(id: id, force: true)
            }
          }
        }
      } onCancel: {
        Task { await self.cancelConnectionTest(id: id) }
      }
    }

    func completeConnectionTest(id: UUID) {
      testExpiryTasks.removeValue(forKey: id)?.cancel()
      switch tests[id] {
      case .waiting(let continuation):
        tests[id] = .completed
        continuation.resume()
      case nil: tests[id] = .completed
      case .completed, .cancelled: break
      }
    }

    private func cancelConnectionTest(id: UUID, force: Bool = false) {
      guard force || !holdsCancelledTests else { return }
      testExpiryTasks.removeValue(forKey: id)?.cancel()
      switch tests[id] {
      case .waiting(let continuation):
        tests[id] = .cancelled
        continuation.resume(throwing: CancellationError())
      case nil: tests[id] = .cancelled
      case .completed, .cancelled: break
      }
    }

    func shutdown() {
      for id in Array(logins.keys) { finishLogin(id: id, outcome: .cancelled) }
      for id in Array(tests.keys) { cancelConnectionTest(id: id, force: true) }
    }
  }
#endif
