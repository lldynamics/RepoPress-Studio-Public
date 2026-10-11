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
  @Published public private(set) var accountRevision: UInt64 = 0
  @Published public private(set) var rateLimits: CodexAppServerRateLimits?
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
  private let readRateLimits: @Sendable () async throws -> CodexAppServerRateLimits
  private let reconnect: @Sendable () async -> Bool
  private let reconnectPending: @Sendable () async -> Bool
  private var refreshTask: Task<Void, Never>?
  private var refreshID: UUID?
  private var preparationTask: Task<Void, Never>?
  private var accountEventTask: Task<Void, Never>?
  private var accountEventStreamTask: Task<AsyncStream<CodexAppServerAccountEvent>, Never>?
  private var quotaTask: Task<Void, Never>?
  private var quotaID: UUID?
  private var quotaEventSequence: UInt64 = 0
  private var pendingEventQuota: (revision: UInt64, value: CodexAppServerRateLimits)?
  private var observedEventGeneration: Int?
  private var observedEventRevision: UInt64?
  private var observedEventSequence: UInt64 = 0
  private var statusRefreshNeeded = false
  private var statusCheckID: UUID?
  private var hasRequestedRefresh = false
  private var lastStatusCheck: ContinuousClock.Instant?
  private var restoringPreference = false
  private var lastAutomaticAttempt: String?

  public convenience init() {
    self.init(
      service: CodexRuntimeSetupService(),
      inspect: { await CodexAppServerProcessTransport.inspectRuntime() },
      readAccount: { try await CodexAppServerClient.shared.accountStatus() },
      readRateLimits: { try await CodexAppServerClient.shared.rateLimits() },
      accountEvents: { await CodexAppServerClient.shared.accountEvents() },
      reconnect: { await CodexAppServerClient.shared.reconnectAfterRuntimeUpdate() },
      reconnectPending: { await CodexAppServerClient.shared.isRuntimeReconnectPending })
  }

  public init(
    service: CodexRuntimeSetupService,
    inspect: @escaping @Sendable () async -> CodexAppServerRuntimeStatus,
    readAccount: @escaping @Sendable () async throws -> CodexAppServerAccountStatus,
    readRateLimits: @escaping @Sendable () async throws -> CodexAppServerRateLimits = { .init() },
    accountEvents: (@Sendable () async -> AsyncStream<CodexAppServerAccountEvent>)? = nil,
    reconnect: @escaping @Sendable () async -> Bool = { true },
    reconnectPending: @escaping @Sendable () async -> Bool = { false }
  ) {
    self.service = service
    self.inspect = inspect
    self.readAccount = readAccount
    self.readRateLimits = readRateLimits
    self.reconnect = reconnect
    self.reconnectPending = reconnectPending
    automaticallyUpdates = service.layout.readableSelection?.automaticallyUpdates ?? false
    canRollback = service.canRollback
    if let accountEvents {
      let streamTask = Task { await accountEvents() }
      accountEventStreamTask = streamTask
      accountEventTask = Task { [weak self] in
        let stream = await streamTask.value
        for await event in stream {
          guard !Task.isCancelled else { break }
          self?.receiveAccountEvent(event)
        }
      }
    }
  }

  deinit {
    accountEventTask?.cancel()
    accountEventStreamTask?.cancel()
    quotaTask?.cancel()
    refreshTask?.cancel()
    preparationTask?.cancel()
  }

  public func refresh() async {
    hasRequestedRefresh = true
    guard !isPreparing else { return }
    // Subscribe before an explicit check can start the shared process.
    _ = await accountEventStreamTask?.value
    await beginStatusRefresh().value
  }

  /// Application activation only rechecks a controller the user has already used.
  public func refreshOnForeground() async {
    guard hasRequestedRefresh, !isPreparing else { return }
    if let lastStatusCheck, ContinuousClock().now - lastStatusCheck < .seconds(30) { return }
    await refresh()
  }

  public func accountDidChange() async {
    invalidateAccount()
    statusRefreshNeeded = true
    if let refreshTask {
      // Its loop will perform one fresh read after any invalidated in-flight read.
      await refreshTask.value
    } else {
      await refresh()
    }
  }

  /// Concurrent views share the read; newer events and account changes always win.
  @discardableResult
  public func refreshRateLimits() async -> Bool {
    guard phase == .ready else { return false }
    await beginQuotaRefresh().value
    return rateLimits != nil
  }

  private func beginStatusRefresh() -> Task<Void, Never> {
    if let refreshTask { return refreshTask }
    let id = UUID()
    refreshID = id
    let task = Task { [weak self] in
      while !Task.isCancelled {
        guard let self, self.refreshID == id else { return }
        self.statusRefreshNeeded = false
        await self.checkStatus()
        guard self.refreshID == id else { return }
        if !self.statusRefreshNeeded { break }
      }
      guard let self, self.refreshID == id else { return }
      self.refreshTask = nil
      self.refreshID = nil
      self.considerAutomaticUpdate()
    }
    refreshTask = task
    return task
  }

  private func checkStatus() async {
    let id = UUID()
    let revision = accountRevision
    statusCheckID = id
    lastStatusCheck = ContinuousClock().now
    isChecking = true
    phase = .checking
    defer { if statusCheckID == id { isChecking = false } }
    failure = nil
    canRollback = service.canRollback
    let runtime = await inspect()
    guard !Task.isCancelled, revision == accountRevision, statusCheckID == id else { return }
    runtimeStatus = runtime
    guard runtime.isAvailable else {
      clearAccountIfNeeded()
      phase = .missingComponent
      return
    }
    guard runtime.isCompatible else {
      clearAccountIfNeeded()
      phase = runtime.compatibility == .unsupportedVersion ? .updateRequired : .failed
      return
    }
    do {
      let account = try await readAccount()
      guard !Task.isCancelled, revision == accountRevision, statusCheckID == id else { return }
      if let previous = accountStatus, previous != account { invalidateAccount() }
      accountStatus = account
      phase =
        account.isAuthenticated && account.accountType?.lowercased() == "chatgpt"
        ? .ready : .needsLogin
      if phase == .ready {
        if let pending = pendingEventQuota, pending.revision == accountRevision {
          rateLimits = pending.value
          pendingEventQuota = nil
        } else {
          _ = beginQuotaRefresh()
        }
      } else {
        rateLimits = nil
        pendingEventQuota = nil
      }
    } catch {
      guard !Task.isCancelled, revision == accountRevision, statusCheckID == id else { return }
      clearAccountIfNeeded()
      if error as? CodexAppServerError == .accountAuthorizationRequired {
        phase = .needsLogin
      } else {
        phase = .failed
        failure = CoreL10n.text("暂时无法检查 ChatGPT 账户，请重新检测或重新登录。")
      }
    }
  }

  private func beginQuotaRefresh() -> Task<Void, Never> {
    if let quotaTask { return quotaTask }
    let id = UUID()
    let revision = accountRevision
    let sequence = quotaEventSequence
    quotaID = id
    let task = Task { [weak self, readRateLimits] in
      do {
        let value = try await readRateLimits()
        guard !Task.isCancelled else { return }
        self?.finishQuotaRead(value, id: id, revision: revision, sequence: sequence)
      } catch {
        guard !Task.isCancelled else { return }
        // Quota metadata is optional; preserve readiness while callers receive false.
        self?.finishQuotaRead(nil, id: id, revision: revision, sequence: sequence)
      }
    }
    quotaTask = task
    return task
  }

  private func finishQuotaRead(
    _ value: CodexAppServerRateLimits?, id: UUID, revision: UInt64, sequence: UInt64
  ) {
    guard quotaID == id else { return }
    quotaTask = nil
    quotaID = nil
    guard revision == accountRevision, sequence == quotaEventSequence,
      accountStatus?.isAuthenticated == true, accountStatus?.accountType?.lowercased() == "chatgpt"
    else { return }
    rateLimits = value
  }

  // Synchronizes deterministic event tests without exposing raw protocol state to the UI.
  var accountEventSequence: UInt64 { observedEventSequence }

  private func receiveAccountEvent(_ event: CodexAppServerAccountEvent) {
    guard event.sequence > observedEventSequence,
      observedEventGeneration.map({ event.generation >= $0 }) ?? true,
      observedEventRevision.map({ event.accountRevision >= $0 }) ?? true
    else { return }
    observedEventSequence = event.sequence
    let changedRevision =
      observedEventRevision.map { $0 != event.accountRevision }
      ?? (event.accountRevision != 0)
    let changedGeneration = observedEventGeneration.map { $0 != event.generation } ?? false
    observedEventRevision = event.accountRevision
    observedEventGeneration = event.generation
    if changedRevision || changedGeneration { invalidateAccount() }

    switch event.kind {
    case .accountChanged:
      if !changedRevision && !changedGeneration { invalidateAccount() }
      phase = .checking
      statusRefreshNeeded = true
      if !isPreparing { _ = beginStatusRefresh() }
    case .rateLimitsUpdated(let value):
      quotaEventSequence = event.sequence
      if phase == .ready, accountStatus?.isAuthenticated == true {
        rateLimits = value
      } else {
        pendingEventQuota = (accountRevision, value)
      }
      if changedRevision || changedGeneration {
        phase = .checking
        statusRefreshNeeded = true
        if !isPreparing { _ = beginStatusRefresh() }
      }
    case .connectionClosed:
      if !changedRevision && !changedGeneration { invalidateAccount() }
      refreshTask?.cancel()
      refreshTask = nil
      refreshID = nil
      statusRefreshNeeded = false
      statusCheckID = nil
      isChecking = false
      phase = .failed
      failure = CoreL10n.text("暂时无法检查 ChatGPT 账户，请重新检测或重新登录。")
    }
  }

  private func clearAccountIfNeeded() {
    if accountStatus != nil || rateLimits != nil || quotaTask != nil { invalidateAccount() }
  }

  private func invalidateAccount() {
    accountRevision &+= 1
    accountStatus = nil
    rateLimits = nil
    pendingEventQuota = nil
    quotaTask?.cancel()
    quotaTask = nil
    quotaID = nil
  }

  private func checkPreparedStatus() async {
    repeat {
      statusRefreshNeeded = false
      await checkStatus()
    } while statusRefreshNeeded && !Task.isCancelled
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
    preparationTask = Task { [self] in
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
        await checkPreparedStatus()
        progress = CoreL10n.text("连接组件已验证。登录并授权后可测试连接。")
      } catch is CancellationError {
        await Task { await self.checkPreparedStatus() }.value
        progress = CoreL10n.text("已停止准备，可重新检测后继续。")
      } catch {
        await checkPreparedStatus()
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
      await checkPreparedStatus()
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
