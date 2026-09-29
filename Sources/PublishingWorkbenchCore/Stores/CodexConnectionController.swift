import Combine
import Foundation
import PublishingAICore

public enum CodexConnectionPhase: Equatable, Sendable {
  case checking, missingComponent, updateRequired, needsLogin, ready, failed
  public var isReady: Bool { self == .ready }
}

/// One shared status and installation task for every settings and chat window.
/// This is presentation readiness, never a replacement for send-time consent.
@MainActor
public final class CodexConnectionController: ObservableObject {
  public static let shared = CodexConnectionController()
  @Published public private(set) var runtimeStatus: CodexAppServerRuntimeStatus?
  @Published public private(set) var accountStatus: CodexAppServerAccountStatus?
  @Published public private(set) var phase: CodexConnectionPhase = .checking
  @Published public private(set) var isChecking = false
  @Published public private(set) var isPreparing = false
  @Published public private(set) var canCancelPreparation = false
  @Published public private(set) var progress: String?
  @Published public private(set) var failure: String?
  @Published public private(set) var canRollback = false
  @Published public var automaticallyUpdates: Bool {
    didSet { persistAutomaticUpdatePreference() }
  }

  private let service: CodexRuntimeSetupService
  private let inspect: @Sendable () async -> CodexAppServerRuntimeStatus
  private let readAccount: @Sendable () async throws -> CodexAppServerAccountStatus
  private let reconnect: @Sendable () async -> Bool
  private let reconnectPending: @Sendable () async -> Bool
  private var refreshTask: Task<Void, Never>?
  private var refreshID: UUID?
  private var preparationTask: Task<Void, Never>?
  private var restoringPreference = false
  private var lastAutomaticAttempt: String?

  public convenience init() {
    self.init(
      service: CodexRuntimeSetupService(),
      inspect: { await CodexAppServerProcessTransport.inspectRuntime() },
      readAccount: { try await CodexAppServerClient.shared.accountStatus() },
      reconnect: { await CodexAppServerClient.shared.reconnectAfterRuntimeUpdate() },
      reconnectPending: { await CodexAppServerClient.shared.isRuntimeReconnectPending })
  }

  init(
    service: CodexRuntimeSetupService,
    inspect: @escaping @Sendable () async -> CodexAppServerRuntimeStatus,
    readAccount: @escaping @Sendable () async throws -> CodexAppServerAccountStatus,
    reconnect: @escaping @Sendable () async -> Bool = { true },
    reconnectPending: @escaping @Sendable () async -> Bool = { false }
  ) {
    self.service = service
    self.inspect = inspect
    self.readAccount = readAccount
    self.reconnect = reconnect
    self.reconnectPending = reconnectPending
    automaticallyUpdates = service.layout.readableSelection?.automaticallyUpdates ?? false
    canRollback = service.canRollback
  }

  public func refresh() async {
    guard !isPreparing else { return }
    if let refreshTask {
      await refreshTask.value
      return
    }
    let id = UUID()
    refreshID = id
    let task = Task { await checkStatus() }
    refreshTask = task
    await task.value
    if refreshID == id {
      refreshTask = nil
      refreshID = nil
    }
    considerAutomaticUpdate()
  }

  public func accountDidChange() async {
    if let refreshTask { await refreshTask.value }
    // A just-completed account read may have started before login/logout.
    // Invalidate it without letting its original waiter clear the fresh task.
    refreshTask = nil
    refreshID = nil
    await refresh()
  }

  private func checkStatus() async {
    isChecking = true
    phase = .checking
    defer { isChecking = false }
    failure = nil
    canRollback = service.canRollback
    let runtime = await inspect()
    runtimeStatus = runtime
    accountStatus = nil
    guard runtime.isAvailable else {
      phase = .missingComponent
      return
    }
    guard runtime.isCompatible else {
      phase = runtime.compatibility == .unsupportedVersion ? .updateRequired : .failed
      return
    }
    do {
      let account = try await readAccount()
      accountStatus = account
      phase =
        account.isAuthenticated && account.accountType?.lowercased() == "chatgpt"
        ? .ready : .needsLogin
    } catch CodexAppServerError.accountAuthorizationRequired {
      phase = .needsLogin
    } catch {
      phase = .failed
      failure = CoreL10n.text("暂时无法检查 ChatGPT 账户，请重新检测或重新登录。")
    }
  }

  public func prepare() { startPreparation(rollback: false) }
  public func rollback() { startPreparation(rollback: true) }
  public func cancelPreparation() {
    guard canCancelPreparation else { return }
    preparationTask?.cancel()
  }

  private func startPreparation(rollback: Bool) {
    guard !isPreparing else { return }
    isPreparing = true
    canCancelPreparation = true
    phase = .checking
    failure = nil
    progress = CoreL10n.text("正在准备连接组件…")
    preparationTask = Task {
      if let refreshTask { await refreshTask.value }
      do {
        if rollback {
          try await service.rollback()
        } else {
          _ = try await service.prepare(plan: .init(method: .managed, runtimeURL: nil)) {
            [weak self] message in
            Task { @MainActor in self?.progress = message }
          }
        }
        // The commit has completed. Finishing activation is now owned by the
        // application, not a cancellable window task.
        canCancelPreparation = false
        progress = CoreL10n.text("组件已准备好，等待当前 AI 操作结束后启用…")
        _ = await reconnect()
        while await reconnectPending() {
          try await Task.sleep(for: .milliseconds(300))
        }
        await checkStatus()
        progress = CoreL10n.text("连接组件已验证。登录并授权后可测试连接。")
      } catch is CancellationError {
        await Task { await self.checkStatus() }.value
        progress = CoreL10n.text("已停止准备，可重新检测后继续。")
      } catch {
        await checkStatus()
        failure = error.localizedDescription
        progress = nil
      }
      canRollback = service.canRollback
      canCancelPreparation = false
      isPreparing = false
      preparationTask = nil
    }
  }

  /// Advanced opt-in: do not update or delete the system installation.
  public func useSystemRuntime() {
    guard !isPreparing else { return }
    do {
      let lock = try CodexRuntimeInstallationLock(directory: service.layout.directory)
      defer { lock.unlock() }
      var selection = try service.layout.selection()
      selection.useSystem = true
      try service.layout.save(selection)
    } catch {
      failure = error.localizedDescription
      return
    }
    isPreparing = true
    phase = .checking
    failure = nil
    progress = CoreL10n.text("等待当前 AI 操作结束后切换连接组件…")
    preparationTask = Task {
      if let refreshTask { await refreshTask.value }
      _ = await reconnect()
      do {
        while await reconnectPending() { try await Task.sleep(for: .milliseconds(300)) }
      } catch {
        // Reconnection remains scheduled after cancellation.
      }
      await checkStatus()
      progress = nil
      isPreparing = false
      preparationTask = nil
    }
  }

  private func persistAutomaticUpdatePreference() {
    guard !restoringPreference else { return }
    do {
      let lock = try CodexRuntimeInstallationLock(directory: service.layout.directory)
      defer { lock.unlock() }
      var selection = try service.layout.selection()
      selection.automaticallyUpdates = automaticallyUpdates
      try service.layout.save(selection)
    } catch {
      restoringPreference = true
      automaticallyUpdates = service.layout.readableSelection?.automaticallyUpdates ?? false
      restoringPreference = false
      failure = error.localizedDescription
    }
  }

  private func considerAutomaticUpdate() {
    guard automaticallyUpdates, let runtimeStatus, runtimeStatus.source == .managed,
      Self.shouldAutomaticallyUpdate(
        selection: service.layout.readableSelection, status: runtimeStatus,
        attemptedVersion: lastAutomaticAttempt)
    else { return }
    lastAutomaticAttempt = CodexRuntimeSetupService.recommendedVersion.description
    prepare()
  }

  static func shouldAutomaticallyUpdate(
    selection: CodexManagedRuntime.Selection?, status: CodexAppServerRuntimeStatus,
    attemptedVersion: String?
  ) -> Bool {
    let target = CodexRuntimeSetupService.recommendedVersion.description
    return selection?.automaticallyUpdates == true && selection?.useSystem == false
      && selection?.deferredVersion != target && attemptedVersion != target
      && status.source == .managed && CodexRuntimeSetupService.needsRecommendedUpdate(status)
  }
}
