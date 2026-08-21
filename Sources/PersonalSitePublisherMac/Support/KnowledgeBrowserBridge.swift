import Combine
import CryptoKit
import Foundation
import BrowserExtensionProtocolSupport
import Network
import PublishingWorkbenchCore

enum KnowledgeBrowserBridgeState: Equatable {
  case stopped
  case starting
  case ready
  case failed(String)

  var localizedDisplayName: String {
    switch self {
    case .stopped: String(localized: "未启动")
    case .starting: String(localized: "正在启动")
    case .ready: String(localized: "可以连接")
    case .failed: String(localized: "连接失败")
    }
  }
}

/// Bounds the amount of work that can be held by the loopback bridge while
/// requests are waiting for a header, an authorization decision, or a body.
/// The lease is deliberately independent of the main actor because Network
/// callbacks run on the bridge's private queue.
final class BrowserBridgeConnectionBudget: @unchecked Sendable {
  static let defaultMaximumConnections = 8
  static let defaultMaximumBufferedBytes = BrowserExtensionProtocol.maximumInputBytes

  final class Lease: @unchecked Sendable {
    private let budget: BrowserBridgeConnectionBudget
    private let lock = NSLock()
    private var released = false
    private var reservedBytes = 0

    fileprivate init(budget: BrowserBridgeConnectionBudget) {
      self.budget = budget
    }

    func reserve(_ bytes: Int) -> Bool {
      guard bytes >= 0 else { return false }
      lock.lock()
      defer { lock.unlock() }
      guard !released, budget.reserve(bytes) else { return false }
      reservedBytes += bytes
      return true
    }

    func release() {
      lock.lock()
      guard !released else {
        lock.unlock()
        return
      }
      released = true
      let bytes = reservedBytes
      reservedBytes = 0
      lock.unlock()
      budget.release(bytes: bytes)
    }

    deinit {
      release()
    }
  }

  private let maximumConnections: Int
  private let maximumBufferedBytes: Int
  private let lock = NSLock()
  private var activeConnections = 0
  private var reservedBufferedBytes = 0

  init(
    maximumConnections: Int = BrowserBridgeConnectionBudget.defaultMaximumConnections,
    maximumBufferedBytes: Int = BrowserBridgeConnectionBudget.defaultMaximumBufferedBytes
  ) {
    self.maximumConnections = max(1, maximumConnections)
    self.maximumBufferedBytes = max(0, maximumBufferedBytes)
  }

  func acquire() -> Lease? {
    lock.lock()
    defer { lock.unlock() }
    guard activeConnections < maximumConnections else { return nil }
    activeConnections += 1
    return Lease(budget: self)
  }

  var activeConnectionCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return activeConnections
  }

  var reservedByteCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return reservedBufferedBytes
  }

  private func reserve(_ bytes: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard bytes >= 0,
          bytes <= maximumBufferedBytes - reservedBufferedBytes else {
      return false
    }
    reservedBufferedBytes += bytes
    return true
  }

  private func release(bytes: Int) {
    lock.lock()
    activeConnections = max(0, activeConnections - 1)
    reservedBufferedBytes = max(0, reservedBufferedBytes - bytes)
    lock.unlock()
  }
}

private final class BrowserBridgeConnectionContext: @unchecked Sendable {
  static let maximumReadIdleDuration: TimeInterval = 10

  let lease: BrowserBridgeConnectionBudget.Lease
  private let queue: DispatchQueue
  private let lock = NSLock()
  private weak var connection: NWConnection?
  private var timeoutWorkItem: DispatchWorkItem?
  private var timeoutToken: UUID?
  private var finished = false

  init(lease: BrowserBridgeConnectionBudget.Lease, queue: DispatchQueue) {
    self.lease = lease
    self.queue = queue
  }

  func attach(to connection: NWConnection) {
    self.connection = connection
  }

  func reserve(_ bytes: Int) -> Bool {
    lease.reserve(bytes)
  }

  func armReadTimeout() {
    let token = UUID()
    let workItem = DispatchWorkItem { [weak self] in
      self?.timeoutElapsed(token: token)
    }
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    timeoutWorkItem?.cancel()
    timeoutWorkItem = workItem
    timeoutToken = token
    lock.unlock()
    queue.asyncAfter(
      deadline: .now() + Self.maximumReadIdleDuration,
      execute: workItem
    )
  }

  func disarmReadTimeout() {
    lock.lock()
    let workItem = timeoutWorkItem
    timeoutWorkItem = nil
    timeoutToken = nil
    lock.unlock()
    workItem?.cancel()
  }

  var isFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return finished
  }

  func finish() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let workItem = timeoutWorkItem
    timeoutWorkItem = nil
    timeoutToken = nil
    lock.unlock()
    workItem?.cancel()
    lease.release()
  }

  private func timeoutElapsed(token: UUID) {
    lock.lock()
    guard !finished, timeoutToken == token else {
      lock.unlock()
      return
    }
    finished = true
    timeoutWorkItem = nil
    timeoutToken = nil
    let connection = self.connection
    lock.unlock()
    lease.release()
    connection?.cancel()
  }
}

@MainActor
final class KnowledgeBrowserBridge: ObservableObject {
  nonisolated static var endpointURL: String {
    BrowserExtensionProtocol.loopbackBaseURL
  }

  @Published private(set) var isEnabled: Bool
  @Published private(set) var state: KnowledgeBrowserBridgeState = .stopped
  @Published private(set) var connectionToken = ""
  @Published private(set) var connectionTokenExpiresAt = Date.distantPast
  @Published private(set) var lastMessage: String?
  @Published private(set) var lastOpenedDocumentID: UUID?

  private let knowledge: KnowledgeStore
  private let defaults: UserDefaults
  private let connectionTokenStore: KnowledgeBrowserConnectionTokenStore
  private let onOpenDocument: (UUID) -> Void
  private let now: () -> Date
  private var invalidatedExpiredToken: String?
  private var importOperationLedger: KnowledgeBrowserImportOperationLedger
  @Published private(set) var importOperationLedgerPersistenceIssue: String?
  private var connectionTokenPersistenceIssue: String?
  private var importOperationLedgerIssueKind: KnowledgeBrowserImportLedgerIssueKind?
  private let importOperationLedgerStore: KnowledgeBrowserImportLedgerStore
  private var activeImportOperations: [UUID: String] = [:]
  private let queue = DispatchQueue(label: "com.jinfang.PersonalSitePublisherMac.browser-bridge")
  private let connectionBudget = BrowserBridgeConnectionBudget()
  private var importOperationLedgerLoadTask: Task<Void, Never>?
  private var listener: NWListener?
  private var listenerGeneration: UUID?

  init(
    knowledge: KnowledgeStore,
    defaults: UserDefaults = .standard,
    connectionTokenKeychainStore: KeychainTokenStore? = nil,
    importOperationLedgerURL: URL? = nil,
    now: @escaping () -> Date = Date.init,
    onOpenDocument: @escaping (UUID) -> Void = { _ in }
  ) {
    self.knowledge = knowledge
    self.defaults = defaults
    self.isEnabled = defaults.bool(forKey: Self.isEnabledDefaultsKey)
    Self.removeLegacyConnectionTokenCopies(from: defaults)
    if let connectionTokenKeychainStore {
      self.connectionTokenStore = KnowledgeBrowserConnectionTokenStore(
        keychain: connectionTokenKeychainStore
      )
    } else {
      self.connectionTokenStore = KnowledgeBrowserConnectionTokenStore()
    }
    let resolvedImportOperationLedgerURL = importOperationLedgerURL
      ?? (defaults === UserDefaults.standard ? Self.defaultImportOperationLedgerURL : nil)
    self.importOperationLedgerStore = KnowledgeBrowserImportLedgerStore(
      fileURL: resolvedImportOperationLedgerURL,
      defaults: KnowledgeBrowserImportLedgerDefaults(defaults),
      legacyDefaultsKey: Self.importOperationLedgerDefaultsKey
    )
    self.now = now
    self.onOpenDocument = onOpenDocument
    importOperationLedger = KnowledgeBrowserImportOperationLedger()
  }

  deinit {
    importOperationLedgerLoadTask?.cancel()
    listener?.cancel()
  }

  var localizedStatusDisplayName: String {
    isEnabled ? state.localizedDisplayName : String(localized: "已关闭")
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else {
      if enabled { start() }
      return
    }
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.isEnabledDefaultsKey)
    if enabled {
      start()
    } else {
      stop()
      connectionToken = ""
      connectionTokenExpiresAt = .distantPast
      invalidatedExpiredToken = nil
      connectionTokenPersistenceIssue = nil
      lastMessage = nil
    }
  }

  func start() {
    guard isEnabled,
          listener == nil,
          importOperationLedgerLoadTask == nil else { return }
    prepareConnectionTokenIfNeeded()
    state = .starting
    let generation = UUID()
    listenerGeneration = generation
    let ledgerStore = importOperationLedgerStore
    let currentDate = now()
    importOperationLedgerLoadTask = Task { [weak self] in
      let loadResult = await ledgerStore.loadPruned(at: currentDate)
      guard let self,
            !Task.isCancelled,
            self.listenerGeneration == generation else { return }
      self.importOperationLedger = loadResult.ledger
      self.importOperationLedgerPersistenceIssue = loadResult.persistenceIssue
      self.importOperationLedgerIssueKind = loadResult.issueKind
      self.lastMessage = self.persistenceWarningMessage
      self.importOperationLedgerLoadTask = nil
      self.startListener(generation: generation)
    }
  }

  private func prepareConnectionTokenIfNeeded() {
    guard connectionToken.isEmpty else { return }
    let currentDate = now()
    var tokenPersistenceIssue: String?
    let persistedToken: String?
    do {
      persistedToken = try connectionTokenStore.token()
    } catch {
      persistedToken = nil
      tokenPersistenceIssue = "浏览器连接令牌无法从本地安全存储读取：\(error.localizedDescription)"
    }
    let storedExpiry = defaults.object(forKey: Self.tokenExpiryDefaultsKey) as? Date
    invalidatedExpiredToken = if let persistedToken,
                                 let storedExpiry,
                                 storedExpiry <= currentDate {
      persistedToken
    } else {
      nil
    }
    let lease = KnowledgeBrowserConnectionTokenLease(
      storedToken: persistedToken,
      storedExpiresAt: storedExpiry,
      now: currentDate,
      generateToken: Self.makeConnectionToken
    )
    connectionToken = lease.token
    connectionTokenExpiresAt = lease.expiresAt
    do {
      try connectionTokenStore.persist(connectionToken)
      tokenPersistenceIssue = nil
    } catch {
      tokenPersistenceIssue = "浏览器连接令牌无法写入本地安全存储：\(error.localizedDescription)"
    }
    connectionTokenPersistenceIssue = tokenPersistenceIssue
    defaults.set(connectionTokenExpiresAt, forKey: Self.tokenExpiryDefaultsKey)
    lastMessage = tokenPersistenceIssue
  }

  private func startListener(generation: UUID) {
    guard listenerGeneration == generation, listener == nil else { return }
    do {
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true
      guard let port = NWEndpoint.Port(
        rawValue: BrowserExtensionProtocol.loopbackPort
      ) else {
        throw KnowledgeBrowserBridgeStartError.invalidLoopbackPort
      }
      parameters.requiredLocalEndpoint = .hostPort(
        host: NWEndpoint.Host(BrowserExtensionProtocol.loopbackHost),
        port: port
      )
      let listener = try NWListener(using: parameters)
      listener.newConnectionHandler = { [weak self] connection in
        self?.receiveRequest(on: connection)
      }
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor in
          guard let self, self.listenerGeneration == generation else { return }
          switch state {
          case .ready:
            self.state = .ready
            self.lastMessage = self.persistenceWarningMessage ?? String(
              localized: "浏览器扩展可通过本机回环地址连接，连接令牌仍为必需。"
            )
          case .failed(let error):
            self.failActiveListener(error.localizedDescription, generation: generation)
          case .cancelled:
            guard self.listenerGeneration == generation else { return }
            self.listenerGeneration = nil
            self.listener = nil
            self.state = .stopped
          default:
            break
          }
        }
      }
      self.listener = listener
      listener.start(queue: queue)
    } catch {
      listenerGeneration = nil
      listener?.cancel()
      listener = nil
      let detail = error.localizedDescription
      state = .failed(detail)
      lastMessage = "浏览器桥接启动失败：\(detail)"
    }
  }

  func stop() {
    listenerGeneration = nil
    importOperationLedgerLoadTask?.cancel()
    importOperationLedgerLoadTask = nil
    let listener = listener
    self.listener = nil
    listener?.cancel()
    state = .stopped
  }

  private func failActiveListener(_ detail: String, generation: UUID) {
    guard listenerGeneration == generation else { return }
    listenerGeneration = nil
    let listener = listener
    self.listener = nil
    listener?.cancel()
    state = .failed(detail)
    lastMessage = "浏览器桥接启动失败：\(detail)"
  }

  func rotateConnectionToken() {
    guard isEnabled else { return }
    let token = Self.makeConnectionToken()
    connectionToken = token
    connectionTokenExpiresAt = now().addingTimeInterval(
      KnowledgeBrowserConnectionTokenLease.defaultLifetime
    )
    defaults.set(connectionTokenExpiresAt, forKey: Self.tokenExpiryDefaultsKey)
    do {
      try connectionTokenStore.persist(token)
      connectionTokenPersistenceIssue = nil
      lastMessage = "连接令牌已更新，浏览器插件需要重新连接。"
    } catch {
      connectionTokenPersistenceIssue =
        "浏览器连接令牌无法写入本地安全存储：\(error.localizedDescription)"
      lastMessage = connectionTokenPersistenceIssue
    }
  }

  @discardableResult
  func refreshExpiredConnectionToken() -> Bool {
    guard isEnabled,
          !connectionToken.isEmpty,
          now() >= connectionTokenExpiresAt else { return false }
    rotateConnectionToken()
    lastMessage = "旧连接令牌已过期并失效，请用新令牌重新配对浏览器插件。"
    return true
  }

  var requiresImportOperationLedgerRebuild: Bool {
    importOperationLedgerIssueKind == .unreadable
  }

  func retryImportOperationLedgerPersistence() async {
    guard importOperationLedgerPersistenceIssue != nil else {
      lastMessage = "浏览器保存幂等账本当前可用，无需重试。"
      return
    }
    guard importOperationLedgerIssueKind == .unwritable else {
      lastMessage = "账本内容无法读取，请先备份并重建损坏账本。"
      return
    }
    do {
      try await persistImportOperationLedger()
      lastMessage = "浏览器保存幂等账本已恢复，可以继续导入。"
    } catch {
      recordImportOperationLedgerPersistenceFailure(error)
    }
  }

  func rebuildImportOperationLedger() async {
    guard importOperationLedgerIssueKind == .unreadable else {
      await retryImportOperationLedgerPersistence()
      return
    }
    guard activeImportOperations.isEmpty else {
      lastMessage = "当前仍有浏览器导入操作，暂时不能重建账本。"
      return
    }
    let backupURL: URL?
    do {
      backupURL = try await importOperationLedgerStore.archiveUnreadableLedger()
    } catch {
      importOperationLedgerPersistenceIssue =
        "损坏账本备份失败：\(error.localizedDescription)"
      importOperationLedgerIssueKind = .unreadable
      lastMessage = importOperationLedgerPersistenceIssue
      return
    }

    importOperationLedger = KnowledgeBrowserImportOperationLedger()
    do {
      try await persistImportOperationLedger()
      if let backupURL {
        lastMessage = "损坏账本已备份到 \(backupURL.lastPathComponent)，新账本已建立。"
      } else {
        lastMessage = "新浏览器保存幂等账本已建立。"
      }
    } catch {
      recordImportOperationLedgerPersistenceFailure(error)
      lastMessage = "损坏账本已备份，但新账本写入失败：\(error.localizedDescription)"
    }
  }

  nonisolated private func receiveRequest(on connection: NWConnection) {
    guard let lease = connectionBudget.acquire() else {
      connection.start(queue: queue)
      sendResponse(
        .error(status: 429, message: "浏览器桥接当前连接数已达上限，请稍后重试。"),
        on: connection
      )
      return
    }
    let context = BrowserBridgeConnectionContext(lease: lease, queue: queue)
    context.attach(to: connection)
    connection.stateUpdateHandler = { [weak context] state in
      switch state {
      case .cancelled, .failed:
        context?.finish()
      default:
        break
      }
    }
    connection.start(queue: queue)
    receiveHeader(on: connection, accumulated: Data(), context: context)
  }

  nonisolated private func receiveHeader(
    on connection: NWConnection,
    accumulated: Data,
    context: BrowserBridgeConnectionContext
  ) {
    guard !context.isFinished else { return }
    context.armReadTimeout()
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
      guard let self else {
        context.finish()
        connection.cancel()
        return
      }
      guard !context.isFinished else { return }
      if error != nil {
        context.finish()
        connection.cancel()
        return
      }
      var buffer = accumulated
      if let data { buffer.append(data) }
      switch BrowserBridgeRequestHeaders.parseState(for: buffer) {
      case .complete(let requestHeaders):
        let pendingBody = Data(buffer.dropFirst(requestHeaders.headerLength))
        guard pendingBody.count <= requestHeaders.contentLength else {
          context.finish()
          self.sendResponse(.error(status: 400, message: "请求正文长度无效。"), on: connection)
          return
        }
        Task { @MainActor [weak self] in
          guard let self else {
            context.finish()
            connection.cancel()
            return
          }
          if let rejection = self.headerAuthorizationFailure(for: requestHeaders) {
            context.finish()
            self.sendResponse(rejection, on: connection)
            return
          }
          guard context.reserve(requestHeaders.contentLength) else {
            context.finish()
            self.sendResponse(
              .error(status: 429, message: "浏览器桥接当前缓冲区已满，请稍后重试。"),
              on: connection
            )
            return
          }
          self.receiveBody(
            on: connection,
            requestHeaders: requestHeaders,
            buffer: BrowserBridgeRequestBodyBuffer(data: pendingBody),
            context: context
          )
        }
      case .incomplete:
        guard !isComplete else {
          context.finish()
          self.sendResponse(.error(status: 400, message: "请求内容不完整。"), on: connection)
          return
        }
        self.receiveHeader(on: connection, accumulated: buffer, context: context)
      case .invalid:
        context.finish()
        self.sendResponse(.error(status: 400, message: "请求头无效。"), on: connection)
      }
    }
  }

  nonisolated private func receiveBody(
    on connection: NWConnection,
    requestHeaders: BrowserBridgeRequestHeaders,
    buffer: BrowserBridgeRequestBodyBuffer,
    context: BrowserBridgeConnectionContext
  ) {
    guard !context.isFinished else { return }
    if buffer.data.count == requestHeaders.contentLength {
      context.disarmReadTimeout()
      let request = BrowserBridgeHTTPRequest(headers: requestHeaders, body: buffer.data)
      Task { @MainActor [weak self] in
        guard let self else {
          context.finish()
          connection.cancel()
          return
        }
        await self.handle(request, connection: connection, context: context)
      }
      return
    }
    context.armReadTimeout()
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
      guard let self else {
        context.finish()
        connection.cancel()
        return
      }
      guard !context.isFinished else { return }
      if error != nil {
        context.finish()
        connection.cancel()
        return
      }
      if let data { buffer.data.append(data) }
      guard buffer.data.count <= requestHeaders.contentLength else {
        context.finish()
        self.sendResponse(.error(status: 400, message: "请求正文长度无效。"), on: connection)
        return
      }
      if isComplete, buffer.data.count != requestHeaders.contentLength {
        context.finish()
        self.sendResponse(.error(status: 400, message: "请求内容不完整。"), on: connection)
        return
      }
      self.receiveBody(
        on: connection,
        requestHeaders: requestHeaders,
        buffer: buffer,
        context: context
      )
    }
  }

  private func handle(
    _ request: BrowserBridgeHTTPRequest,
    connection: NWConnection,
    context: BrowserBridgeConnectionContext
  ) async {
    defer { context.finish() }
    if request.method == "OPTIONS" {
      guard request.isApprovedExtensionPreflight else {
        sendResponse(
          .error(status: 403, message: "只接受已安装的浏览器扩展。", code: "invalid-origin"),
          on: connection
        )
        return
      }
      sendResponse(.empty(status: 204), on: connection)
      return
    }
    guard request.isLoopbackBridgeRequest else {
      sendResponse(
        .error(status: 403, message: "只接受已配对的浏览器扩展。", code: "invalid-transport"),
        on: connection
      )
      return
    }
    if request.method == "GET", request.path == "/v1/status" {
      sendResponse(.json(status: 200, value: BrowserStatusResponse(
        ready: state == .ready,
        protocolVersion: BrowserExtensionProtocol.statusPayloadVersion,
        application: "PersonalSitePublisherMac",
        importAvailable: importOperationLedgerPersistenceIssue == nil,
        warning: persistenceWarningMessage
      )), on: connection)
      return
    }
    if let invalidatedExpiredToken,
       request.bearerToken == invalidatedExpiredToken {
      self.invalidatedExpiredToken = nil
      sendResponse(.error(
        status: 401,
        message: "连接令牌已过期，请从应用复制新令牌重新配对。",
        code: "token-expired"
      ), on: connection)
      return
    }
    if refreshExpiredConnectionToken() {
      sendResponse(.error(
        status: 401,
        message: "连接令牌已过期，请从应用复制新令牌重新配对。",
        code: "token-expired"
      ), on: connection)
      return
    }
    guard request.headers["authorization"] == "Bearer \(connectionToken)" else {
      sendResponse(.error(status: 401, message: "连接令牌无效，请重新配对。", code: "invalid-token"), on: connection)
      return
    }

    if request.method == "GET", request.path == "/v1/folders" {
      sendResponse(.json(status: 200, value: BrowserFoldersResponse(
        folders: knowledge.folders.map { BrowserFolderResponse(id: $0.id, name: $0.name) },
        tokenExpiresAt: ISO8601DateFormatter().string(from: connectionTokenExpiresAt)
      )), on: connection)
      return
    }

    if request.method == "POST", request.path == "/v1/suggestions" {
      guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
        sendResponse(.error(status: 415, message: "只接受 JSON 分类建议请求。"), on: connection)
        return
      }
      guard let envelope = try? JSONDecoder().decode(
        BrowserOrganizationSuggestionEnvelope.self,
        from: request.body
      ) else {
        sendResponse(.error(status: 400, message: "分类建议请求无效。"), on: connection)
        return
      }
      let suggestions = KnowledgeSmartCollectionService().browserOrganizationSuggestions(
        sourceURL: envelope.sourceURL,
        authors: envelope.authors,
        tags: envelope.tags,
        documents: knowledge.documents,
        folders: knowledge.folders
      )
      sendResponse(.json(status: 200, value: BrowserOrganizationSuggestionsResponse(
        folders: suggestions.folders.map {
          BrowserFolderSuggestionResponse(
            folder: BrowserFolderResponse(id: $0.folder.id, name: $0.folder.name),
            score: $0.score,
            reasons: $0.reasons.map(\.rawValue)
          )
        },
        tags: suggestions.tags
      )), on: connection)
      return
    }

    if request.method == "POST", request.path == "/v1/open" {
      guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
        sendResponse(.error(status: 415, message: "只接受 JSON 资料定位请求。"), on: connection)
        return
      }
      guard let envelope = try? JSONDecoder().decode(BrowserOpenEnvelope.self, from: request.body) else {
        sendResponse(.error(status: 400, message: "资料定位请求无效。"), on: connection)
        return
      }
      guard knowledge.revealDocument(envelope.documentID) else {
        sendResponse(.error(status: 404, message: "资料库中找不到该资料。"), on: connection)
        return
      }
      lastOpenedDocumentID = envelope.documentID
      onOpenDocument(envelope.documentID)
      lastMessage = "已打开浏览器刚保存的资料。"
      sendResponse(.json(status: 200, value: BrowserOpenResponse(
        documentID: envelope.documentID,
        opened: true
      )), on: connection)
      return
    }

    if request.method == "POST", request.path == "/v1/import" {
      guard request.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
        sendResponse(.error(status: 415, message: "只接受 JSON 页面数据。"), on: connection)
        return
      }
      if importOperationLedgerIssueKind == .unwritable {
        do {
          try await persistImportOperationLedger()
          lastMessage = "浏览器保存幂等账本已自动恢复。"
        } catch {
          recordImportOperationLedgerPersistenceFailure(error)
        }
      }
      guard importOperationLedgerPersistenceIssue == nil else {
        sendResponse(.error(
          status: 503,
          message: "浏览器保存幂等账本不可用，已暂停导入以避免重复写入。",
          code: "operation-ledger-unavailable"
        ), on: connection)
        return
      }
      do {
        let requestBody = request.body
        let preparedImport = try await Task.detached(priority: .userInitiated) {
          try Self.prepareBrowserImport(from: requestBody)
        }.value
        let envelope = preparedImport.envelope
        let operation = (
          id: preparedImport.operationID,
          fingerprint: preparedImport.requestFingerprint
        )
        let lookup = importOperationLedger.lookup(
          operationID: operation.id,
          requestFingerprint: operation.fingerprint,
          now: now(),
          documentExists: { documentID in
            knowledge.documents.contains(where: { $0.id == documentID })
          }
        )
        do {
          try await persistImportOperationLedger()
        } catch {
          recordImportOperationLedgerPersistenceFailure(error)
          sendResponse(.error(
            status: 503,
            message: "浏览器保存幂等账本无法更新，已暂停导入以避免重复写入。",
            code: "operation-ledger-unavailable"
          ), on: connection)
          return
        }
        switch lookup {
        case .replay(let receipt):
          lastMessage = "已返回浏览器保存操作的既有回执，没有重复写入资料库。"
          sendResponse(.json(status: 200, value: receipt), on: connection)
          return
        case .conflictingRequest:
          sendResponse(.error(
            status: 409,
            message: "同一保存操作 ID 被用于不同内容，已拒绝覆盖。请重新生成保存预览。",
            code: "operation-id-conflict"
          ), on: connection)
          return
        case .missingDocument:
          sendResponse(.error(
            status: 410,
            message: "该保存操作对应的资料已被删除，请重新生成保存预览。",
            code: "operation-result-missing"
          ), on: connection)
          return
        case .miss:
          break
        }
        if let activeFingerprint = activeImportOperations[operation.id] {
          if activeFingerprint == operation.fingerprint {
            sendResponse(.error(
              status: 425,
              message: "该保存操作仍在建立索引，请稍后用同一操作 ID 重试。",
              code: "operation-in-progress"
            ), on: connection)
          } else {
            sendResponse(.error(
              status: 409,
              message: "同一保存操作 ID 正在处理其他内容，已拒绝覆盖。",
              code: "operation-id-conflict"
            ), on: connection)
          }
          return
        }
        activeImportOperations[operation.id] = operation.fingerprint
        defer { activeImportOperations.removeValue(forKey: operation.id) }
        let outcome = try await knowledge.importBrowserCapture(
          envelope.capture,
          folderID: envelope.folderID,
          newFolderName: envelope.newFolderName,
          duplicateResolution: envelope.duplicateResolution
        )
        guard case .saved(let result, let action) = outcome else {
          if case .requiresDuplicateResolution(let conflict) = outcome {
            lastMessage = "检测到同网址资料，等待选择处理方式。"
            sendResponse(.json(status: 200, value: BrowserDuplicateResolutionResponse(
              operationID: operation.id,
              requiresDuplicateResolution: true,
              conflict: BrowserDuplicateConflictResponse(
                documentID: conflict.document.id,
                title: conflict.document.title,
                folder: conflict.folder.map { BrowserFolderResponse(id: $0.id, name: $0.name) },
                fileSizeBytes: conflict.document.sourceByteCount,
                updatedAt: conflict.document.updatedAt,
                incomingHasChanges: conflict.incomingHasChanges
              )
            )), on: connection)
          }
          return
        }
        guard
          let documentID = result.documentIDs.first,
          let document = knowledge.documents.first(where: { $0.id == documentID })
        else {
          sendResponse(.error(status: 500, message: "页面已保存，但生成保存回执失败。"), on: connection)
          return
        }
        let folder = document.folderID.flatMap { folderID in
          knowledge.folders.first(where: { $0.id == folderID })
        }
        lastMessage = "已从浏览器保存“\(envelope.capture.title)”。"
        let receipt = KnowledgeBrowserImportReceipt(
          operationID: operation.id,
          insertedCount: result.insertedCount,
          updatedCount: result.updatedCount,
          skippedCount: result.skippedCount,
          action: action.rawValue,
          documentID: document.id,
          title: document.title,
          sourceURL: document.sourceURL,
          folder: folder.map { KnowledgeBrowserReceiptFolder(id: $0.id, name: $0.name) },
          fileSizeBytes: document.sourceByteCount,
          archiveType: envelope.capture.archiveFormat?.lowercased() ?? "none",
          indexStatus: "ready",
          allowsLocalSemanticIndex: document.allowsLocalSemanticIndex,
          allowsRemoteAIUse: document.allowsRemoteAIUse,
          savedAt: document.updatedAt
        )
        importOperationLedger.record(
          operationID: operation.id,
          requestFingerprint: operation.fingerprint,
          receipt: receipt,
          completedAt: now()
        )
        do {
          try await persistImportOperationLedger()
        } catch {
          recordImportOperationLedgerPersistenceFailure(error)
          sendResponse(.error(
            status: 500,
            message: "页面已保存，但保存回执未能持久化；请勿刷新页面或重复提交。",
            code: "operation-receipt-persistence-failed"
          ), on: connection)
          return
        }
        sendResponse(.json(status: 200, value: receipt), on: connection)
      } catch {
        lastMessage = error.localizedDescription
        sendResponse(.error(status: 422, message: error.localizedDescription), on: connection)
      }
      return
    }

    sendResponse(.error(status: 404, message: "接口不存在。"), on: connection)
  }

  private func headerAuthorizationFailure(
    for request: BrowserBridgeRequestHeaders
  ) -> BrowserBridgeHTTPResponse? {
    if request.method == "OPTIONS" {
      guard request.contentLength == 0 else {
        return .error(status: 400, message: "预检请求不应包含正文。")
      }
      return request.isApprovedExtensionPreflight
        ? nil
        : .error(
          status: 403,
          message: "只接受已安装的浏览器扩展。",
          code: "invalid-origin"
        )
    }
    guard request.isLoopbackBridgeRequest else {
      return .error(
        status: 403,
        message: "只接受已配对的浏览器扩展。",
        code: "invalid-transport"
      )
    }
    // The status endpoint is intentionally usable without a bearer token, but
    // only as a bodyless health check. Any request carrying a body must pass
    // the same token gate before the first body byte is accepted.
    if request.method == "GET",
       request.path == "/v1/status",
       request.contentLength == 0 {
      return nil
    }
    if let invalidatedExpiredToken,
       request.bearerToken == invalidatedExpiredToken {
      self.invalidatedExpiredToken = nil
      return .error(
        status: 401,
        message: "连接令牌已过期，请从应用复制新令牌重新配对。",
        code: "token-expired"
      )
    }
    if refreshExpiredConnectionToken() {
      return .error(
        status: 401,
        message: "连接令牌已过期，请从应用复制新令牌重新配对。",
        code: "token-expired"
      )
    }
    guard request.headers["authorization"] == "Bearer \(connectionToken)" else {
      return .error(
        status: 401,
        message: "连接令牌无效，请重新配对。",
        code: "invalid-token"
      )
    }
    return nil
  }

  nonisolated private func sendResponse(
    _ response: BrowserBridgeHTTPResponse,
    on connection: NWConnection
  ) {
    let data = response.encodedData()
    connection.send(content: data, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private static let isEnabledDefaultsKey = "KnowledgeBrowserBridge.isEnabled.v1"
  private static let legacyTokenDefaultsKey = "KnowledgeBrowserBridge.connectionToken.v1"
  private static let tokenExpiryDefaultsKey = "KnowledgeBrowserBridge.connectionTokenExpiresAt.v1"
  private static let importOperationLedgerDefaultsKey =
    "KnowledgeBrowserBridge.completedImportOperations.v1"

  private nonisolated static var legacyConnectionTokenURL: URL {
    defaultBrowserBridgeDirectoryURL
      .appendingPathComponent("connection-token-v1", isDirectory: false)
  }

  private nonisolated static var defaultImportOperationLedgerURL: URL {
    defaultBrowserBridgeDirectoryURL
      .appendingPathComponent("import-operation-ledger-v1.plist")
  }

  private nonisolated static var defaultBrowserBridgeDirectoryURL: URL {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first ?? FileManager.default.temporaryDirectory
    return applicationSupport
      .appendingPathComponent("PersonalSitePublisherMac", isDirectory: true)
      .appendingPathComponent("BrowserBridge", isDirectory: true)
  }

  private static func removeLegacyConnectionTokenCopies(from defaults: UserDefaults) {
    // Older builds wrote the token to UserDefaults or Application Support.
    // Remove those copies without reading or migrating them; Keychain is the
    // only supported persistence backend for the app-side pairing token.
    defaults.removeObject(forKey: legacyTokenDefaultsKey)
    guard defaults === UserDefaults.standard else { return }
    try? FileManager.default.removeItem(at: legacyConnectionTokenURL)
  }

  private func persistImportOperationLedger() async throws {
    try await importOperationLedgerStore.persist(importOperationLedger.records)
    importOperationLedgerPersistenceIssue = nil
    importOperationLedgerIssueKind = nil
  }

  private func recordImportOperationLedgerPersistenceFailure(_ error: Error) {
    importOperationLedgerPersistenceIssue =
      "浏览器保存幂等账本无法持久化：\(error.localizedDescription)"
    importOperationLedgerIssueKind = .unwritable
    lastMessage = importOperationLedgerPersistenceIssue
  }

  private var persistenceWarningMessage: String? {
    let warnings = [
      importOperationLedgerPersistenceIssue,
      connectionTokenPersistenceIssue,
    ].compactMap { $0 }
    return warnings.isEmpty ? nil : warnings.joined(separator: "\n")
  }

  private nonisolated static func prepareBrowserImport(
    from body: Data
  ) throws -> BrowserPreparedImport {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(BrowserImportEnvelope.self, from: body)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(BrowserImportOperationIdentity(
      capture: envelope.capture,
      folderID: envelope.folderID,
      newFolderName: envelope.newFolderName
    ))
    let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    if let operationID = envelope.operationID {
      return BrowserPreparedImport(
        envelope: envelope,
        operationID: operationID,
        requestFingerprint: fingerprint
      )
    }
    let derivedID = "\(fingerprint.prefix(8))-\(fingerprint.dropFirst(8).prefix(4))-"
      + "\(fingerprint.dropFirst(12).prefix(4))-\(fingerprint.dropFirst(16).prefix(4))-"
      + "\(fingerprint.dropFirst(20).prefix(12))"
    guard let operationID = UUID(uuidString: derivedID) else {
      throw KnowledgeLibraryError.invalidBrowserCapture("保存操作 ID 无效。")
    }
    return BrowserPreparedImport(
      envelope: envelope,
      operationID: operationID,
      requestFingerprint: fingerprint
    )
  }

  private static func makeConnectionToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
      return bytes.map { String(format: "%02x", $0) }.joined()
    }
    return UUID().uuidString.replacingOccurrences(of: "-", with: "")
      + UUID().uuidString.replacingOccurrences(of: "-", with: "")
  }

}

private struct BrowserPreparedImport: Sendable {
  var envelope: BrowserImportEnvelope
  var operationID: UUID
  var requestFingerprint: String
}

private struct BrowserImportEnvelope: Codable, Sendable {
  var operationID: UUID?
  var capture: KnowledgeBrowserCapture
  var folderID: UUID?
  var newFolderName: String?
  var duplicateResolution: KnowledgeBrowserDuplicateResolution?
}

private struct BrowserImportOperationIdentity: Encodable {
  var capture: KnowledgeBrowserCapture
  var folderID: UUID?
  var newFolderName: String?
}

private struct BrowserOpenEnvelope: Decodable {
  var documentID: UUID
}

private struct BrowserOrganizationSuggestionEnvelope: Decodable {
  var sourceURL: URL
  var authors: [String]
  var tags: [String]
}

private struct BrowserStatusResponse: Encodable {
  var ready: Bool
  var protocolVersion: Int
  var application: String
  var importAvailable: Bool
  var warning: String?
}

private struct BrowserFolderResponse: Encodable {
  var id: UUID
  var name: String
}

private struct BrowserFoldersResponse: Encodable {
  var folders: [BrowserFolderResponse]
  var tokenExpiresAt: String
}

private struct BrowserFolderSuggestionResponse: Encodable {
  var folder: BrowserFolderResponse
  var score: Double
  var reasons: [String]
}

private struct BrowserOrganizationSuggestionsResponse: Encodable {
  var folders: [BrowserFolderSuggestionResponse]
  var tags: [String]
}

private struct BrowserDuplicateConflictResponse: Encodable {
  var documentID: UUID
  var title: String
  var folder: BrowserFolderResponse?
  var fileSizeBytes: Int64
  var updatedAt: Date
  var incomingHasChanges: Bool
}

private struct BrowserDuplicateResolutionResponse: Encodable {
  var operationID: UUID
  var requiresDuplicateResolution: Bool
  var conflict: BrowserDuplicateConflictResponse
}

private struct BrowserOpenResponse: Encodable {
  var documentID: UUID
  var opened: Bool
}

enum BrowserExtensionOriginPolicy {
  static func allows(_ origin: String?) -> Bool {
    guard let origin else {
      // Extension service-worker requests can omit Origin. The required custom
      // protocol header still forces ordinary web pages through CORS preflight.
      return true
    }
    guard let components = URLComponents(string: origin),
          let scheme = components.scheme?.lowercased(),
          let host = components.host?.lowercased()
    else {
      return false
    }
    switch scheme {
    case "moz-extension":
      // Firefox assigns each installed extension a per-profile UUID origin;
      // the manifest add-on ID cannot be used as the URL host.
      return UUID(uuidString: host) != nil
    case "safari-web-extension":
      // Safari assigns each installed web extension a per-install UUID origin,
      // so the signed bundle identifier cannot be used as the URL host.
      return UUID(uuidString: host) != nil
    case "chrome-extension":
      let allowedIDs = Set(
        [
          BrowserExtensionProtocol.chromiumDevelopmentExtensionID,
          BrowserExtensionProtocol.chromeProductionExtensionID,
        ].compactMap { $0?.lowercased() }
      )
      return allowedIDs.contains(host)
    default:
      return false
    }
  }
}

enum BrowserBridgeRequestHeaderParseState {
  case incomplete
  case complete(BrowserBridgeRequestHeaders)
  case invalid
}

private final class BrowserBridgeRequestBodyBuffer: @unchecked Sendable {
  var data: Data

  init(data: Data) {
    self.data = data
  }
}

struct BrowserBridgeRequestHeaders: Sendable {
  static let maximumRequestBytes = BrowserExtensionProtocol.maximumInputBytes
  static let maximumHeaderBytes = 32 * 1_024
  private static let headerSeparator = Data("\r\n\r\n".utf8)

  var method: String
  var path: String
  var headers: [String: String]
  var contentLength: Int
  var headerLength: Int

  static func parseState(for data: Data) -> BrowserBridgeRequestHeaderParseState {
    guard let separatorRange = data.range(of: headerSeparator) else {
      return data.count > maximumHeaderBytes ? .invalid : .incomplete
    }
    guard separatorRange.lowerBound <= maximumHeaderBytes,
          let headerText = String(data: data[..<separatorRange.lowerBound], encoding: .utf8) else {
      return .invalid
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .invalid }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3,
          requestParts[2].hasPrefix("HTTP/1.") else { return .invalid }
    let method = String(requestParts[0]).uppercased()
    let path = String(requestParts[1]).components(separatedBy: "?").first ?? "/"
    var parsedHeaders: [String: String] = [:]
    var contentLength = 0
    var foundContentLength = false
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { return .invalid }
      let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return .invalid }
      if name == "content-length" {
        guard !foundContentLength,
              let parsedLength = parseContentLength(String(value)) else {
          return .invalid
        }
        foundContentLength = true
        contentLength = parsedLength
      }
      parsedHeaders[name] = value
    }
    let headerLength = separatorRange.upperBound
    guard headerLength <= maximumRequestBytes,
          contentLength <= maximumRequestBytes - headerLength else {
      return .invalid
    }
    return .complete(Self(
      method: method,
      path: path,
      headers: parsedHeaders,
      contentLength: contentLength,
      headerLength: headerLength
    ))
  }

  private static func parseContentLength(_ value: String) -> Int? {
    guard !value.isEmpty,
          value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
          let parsed = Int(value) else {
      return nil
    }
    return parsed
  }

  var isLoopbackBridgeRequest: Bool {
    headers[BrowserExtensionProtocol.loopbackProtocolHeaderName.lowercased()]
      == BrowserExtensionProtocol.loopbackProtocolHeaderValue
      && isApprovedExtensionOrigin
  }

  var isApprovedExtensionPreflight: Bool {
    guard method == "OPTIONS",
          isApprovedExtensionOrigin,
          let requestedMethod = headers["access-control-request-method"]?.uppercased(),
          ["GET", "POST"].contains(requestedMethod),
          let requestedHeaders = headers["access-control-request-headers"]?.lowercased()
    else {
      return false
    }
    let headerNames = Set(
      requestedHeaders.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
    )
    return headerNames.contains("authorization")
      && headerNames.contains(
        BrowserExtensionProtocol.loopbackProtocolHeaderName.lowercased()
      )
  }

  private var isApprovedExtensionOrigin: Bool {
    BrowserExtensionOriginPolicy.allows(headers["origin"])
  }

  var bearerToken: String? {
    let prefix = "Bearer "
    guard let authorization = headers["authorization"],
          authorization.hasPrefix(prefix) else { return nil }
    return String(authorization.dropFirst(prefix.count))
  }
}

private struct BrowserBridgeHTTPRequest: Sendable {
  let requestHeaders: BrowserBridgeRequestHeaders
  let body: Data

  init(headers: BrowserBridgeRequestHeaders, body: Data) {
    requestHeaders = headers
    self.body = body
  }

  var method: String { requestHeaders.method }
  var path: String { requestHeaders.path }
  var headers: [String: String] { requestHeaders.headers }

  var isLoopbackBridgeRequest: Bool {
    requestHeaders.isLoopbackBridgeRequest
  }

  var isApprovedExtensionPreflight: Bool {
    requestHeaders.isApprovedExtensionPreflight
  }

  var bearerToken: String? {
    requestHeaders.bearerToken
  }
}

private struct BrowserBridgeHTTPResponse {
  var status: Int
  var contentType: String
  var body: Data

  static func empty(status: Int) -> Self {
    Self(status: status, contentType: "application/json; charset=utf-8", body: Data())
  }

  static func json<Value: Encodable>(status: Int, value: Value) -> Self {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
    return Self(status: status, contentType: "application/json; charset=utf-8", body: data)
  }

  static func error(status: Int, message: String, code: String? = nil) -> Self {
    var value = ["error": message]
    if let code { value["code"] = code }
    return json(status: status, value: value)
  }

  func encodedData() -> Data {
    let reason: String
    switch status {
    case 204: reason = "No Content"
    case 200: reason = "OK"
    case 400: reason = "Bad Request"
    case 401: reason = "Unauthorized"
    case 403: reason = "Forbidden"
    case 429: reason = "Too Many Requests"
    case 404: reason = "Not Found"
    case 409: reason = "Conflict"
    case 410: reason = "Gone"
    case 413: reason = "Payload Too Large"
    case 415: reason = "Unsupported Media Type"
    case 425: reason = "Too Early"
    case 422: reason = "Unprocessable Content"
    default: reason = "Error"
    }
    let header = """
    HTTP/1.1 \(status) \(reason)\r
    Content-Type: \(contentType)\r
    Content-Length: \(body.count)\r
    Cache-Control: no-store\r
    Access-Control-Allow-Origin: *\r
    Access-Control-Allow-Methods: GET, POST, OPTIONS\r
    Access-Control-Allow-Headers: \(BrowserExtensionProtocol.accessControlAllowHeaders)\r
    Access-Control-Max-Age: 600\r
    Connection: close\r
    \r

    """
    var output = Data(header.utf8)
    output.append(body)
    return output
  }
}

private enum KnowledgeBrowserBridgeStartError: LocalizedError {
  case invalidLoopbackPort

  var errorDescription: String? {
    "浏览器本机回环端口配置无效。"
  }
}
