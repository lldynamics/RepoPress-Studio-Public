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

@MainActor
final class KnowledgeBrowserBridge: ObservableObject {
  nonisolated static var endpointURL: String {
    BrowserExtensionProtocol.loopbackBaseURL
  }

  @Published private(set) var state: KnowledgeBrowserBridgeState = .stopped
  @Published private(set) var connectionToken: String
  @Published private(set) var connectionTokenExpiresAt: Date
  @Published private(set) var lastMessage: String?
  @Published private(set) var lastOpenedDocumentID: UUID?

  private let knowledge: KnowledgeStore
  private let defaults: UserDefaults
  private let connectionTokenStore: KnowledgeBrowserConnectionTokenStore
  private let importOperationLedgerURL: URL?
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
  private var listener: NWListener?
  private var listenerGeneration: UUID?

  init(
    knowledge: KnowledgeStore,
    defaults: UserDefaults = .standard,
    connectionTokenURL: URL? = nil,
    importOperationLedgerURL: URL? = nil,
    now: @escaping () -> Date = Date.init,
    onOpenDocument: @escaping (UUID) -> Void = { _ in }
  ) {
    self.knowledge = knowledge
    self.defaults = defaults
    let resolvedConnectionTokenURL = connectionTokenURL
      ?? (defaults === UserDefaults.standard ? Self.defaultConnectionTokenURL : nil)
    self.connectionTokenStore = KnowledgeBrowserConnectionTokenStore(
      fileURL: resolvedConnectionTokenURL,
      defaults: KnowledgeBrowserConnectionTokenDefaults(defaults),
      legacyDefaultsKey: Self.tokenDefaultsKey
    )
    let resolvedImportOperationLedgerURL = importOperationLedgerURL
      ?? (defaults === UserDefaults.standard ? Self.defaultImportOperationLedgerURL : nil)
    self.importOperationLedgerURL = resolvedImportOperationLedgerURL
    self.importOperationLedgerStore = KnowledgeBrowserImportLedgerStore(
      fileURL: resolvedImportOperationLedgerURL,
      defaults: KnowledgeBrowserImportLedgerDefaults(defaults),
      legacyDefaultsKey: Self.importOperationLedgerDefaultsKey
    )
    self.now = now
    self.onOpenDocument = onOpenDocument
    let currentDate = now()
    var storedOperationRecords: [KnowledgeBrowserImportOperationRecord] = []
    var ledgerPersistenceIssue: String?
    var ledgerIssueKind: KnowledgeBrowserImportLedgerIssueKind?
    do {
      if let ledgerURL = self.importOperationLedgerURL,
         FileManager.default.fileExists(atPath: ledgerURL.path) {
        storedOperationRecords = try PropertyListDecoder().decode(
          [KnowledgeBrowserImportOperationRecord].self,
          from: try BoundedFileReader.data(
            at: ledgerURL,
            maximumByteCount: WorkbenchFileReadLimits.maximumBrowserImportLedgerByteCount
          )
        )
      } else if let legacyData = defaults.data(
        forKey: Self.importOperationLedgerDefaultsKey
      ) {
        storedOperationRecords = try PropertyListDecoder().decode(
          [KnowledgeBrowserImportOperationRecord].self,
          from: legacyData
        )
      }
    } catch {
      ledgerPersistenceIssue = "浏览器保存幂等账本无法读取：\(error.localizedDescription)"
      ledgerIssueKind = .unreadable
    }
    var operationLedger = KnowledgeBrowserImportOperationLedger(records: storedOperationRecords)
    operationLedger.prune(at: currentDate)
    importOperationLedger = operationLedger
    if ledgerPersistenceIssue == nil {
      do {
        if let ledgerURL = self.importOperationLedgerURL {
          try Self.writeImportOperationLedger(operationLedger.records, to: ledgerURL)
          defaults.removeObject(forKey: Self.importOperationLedgerDefaultsKey)
        } else {
          defaults.set(
            try PropertyListEncoder().encode(operationLedger.records),
            forKey: Self.importOperationLedgerDefaultsKey
          )
        }
      } catch {
        ledgerPersistenceIssue = "浏览器保存幂等账本无法持久化：\(error.localizedDescription)"
        ledgerIssueKind = .unwritable
      }
    }
    importOperationLedgerPersistenceIssue = ledgerPersistenceIssue
    importOperationLedgerIssueKind = ledgerIssueKind

    var tokenPersistenceIssue: String?
    let persistedToken: String?
    do {
      persistedToken = try connectionTokenStore.token()
    } catch {
      persistedToken = nil
      tokenPersistenceIssue = "浏览器连接令牌无法从本地安全存储读取：\(error.localizedDescription)"
    }
    let storedToken = persistedToken ?? defaults.string(forKey: Self.tokenDefaultsKey)
    let storedExpiry = defaults.object(forKey: Self.tokenExpiryDefaultsKey) as? Date
    invalidatedExpiredToken = if let storedToken, let storedExpiry, storedExpiry <= currentDate {
      storedToken
    } else {
      nil
    }
    let lease = KnowledgeBrowserConnectionTokenLease(
      storedToken: storedToken,
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
      defaults.set(connectionToken, forKey: Self.tokenDefaultsKey)
      tokenPersistenceIssue = "浏览器连接令牌无法写入本地安全存储：\(error.localizedDescription)"
    }
    connectionTokenPersistenceIssue = tokenPersistenceIssue
    defaults.set(connectionTokenExpiresAt, forKey: Self.tokenExpiryDefaultsKey)
    let warnings = [ledgerPersistenceIssue, tokenPersistenceIssue].compactMap { $0 }
    lastMessage = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
  }

  deinit {
    listener?.cancel()
  }

  func start() {
    guard listener == nil else { return }
    state = .starting
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
      let generation = UUID()
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
      self.listenerGeneration = generation
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
      defaults.set(token, forKey: Self.tokenDefaultsKey)
      connectionTokenPersistenceIssue =
        "浏览器连接令牌无法写入本地安全存储：\(error.localizedDescription)"
      lastMessage = "\(connectionTokenPersistenceIssue!) 已改用兼容存储。"
    }
  }

  @discardableResult
  func refreshExpiredConnectionToken() -> Bool {
    guard now() >= connectionTokenExpiresAt else { return false }
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
    connection.start(queue: queue)
    receiveChunk(on: connection, accumulated: Data())
  }

  nonisolated private func receiveChunk(
    on connection: NWConnection,
    accumulated: Data
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      if error != nil {
        connection.cancel()
        return
      }
      var buffer = accumulated
      if let data { buffer.append(data) }
      guard buffer.count <= BrowserBridgeHTTPRequest.maximumRequestBytes else {
        self.sendResponse(.error(status: 413, message: "页面数据超过 48 MB。"), on: connection)
        return
      }

      switch BrowserBridgeHTTPRequest.completionState(for: buffer) {
      case .complete(let requestLength):
        let requestData = Data(buffer.prefix(requestLength))
        guard let request = BrowserBridgeHTTPRequest(data: requestData) else {
          self.sendResponse(.error(status: 400, message: "请求格式无效。"), on: connection)
          return
        }
        Task { @MainActor [weak self] in
          await self?.handle(request, connection: connection)
        }
      case .incomplete:
        guard !isComplete else {
          self.sendResponse(.error(status: 400, message: "请求内容不完整。"), on: connection)
          return
        }
        self.receiveChunk(on: connection, accumulated: buffer)
      case .invalid:
        self.sendResponse(.error(status: 400, message: "请求头无效。"), on: connection)
      }
    }
  }

  private func handle(
    _ request: BrowserBridgeHTTPRequest,
    connection: NWConnection
  ) async {
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
          allowsAIUse: document.allowsAIUse,
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

  nonisolated private func sendResponse(
    _ response: BrowserBridgeHTTPResponse,
    on connection: NWConnection
  ) {
    let data = response.encodedData()
    connection.send(content: data, completion: .contentProcessed { _ in
      connection.cancel()
    })
  }

  private static let tokenDefaultsKey = "KnowledgeBrowserBridge.connectionToken.v1"
  private static let tokenExpiryDefaultsKey = "KnowledgeBrowserBridge.connectionTokenExpiresAt.v1"
  private static let importOperationLedgerDefaultsKey =
    "KnowledgeBrowserBridge.completedImportOperations.v1"

  private nonisolated static var defaultConnectionTokenURL: URL {
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

  private nonisolated static func writeImportOperationLedger(
    _ records: [KnowledgeBrowserImportOperationRecord],
    to url: URL
  ) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    try encoder.encode(records).write(to: url, options: .atomic)
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

private enum KnowledgeBrowserImportLedgerIssueKind {
  case unreadable
  case unwritable
}

private struct BrowserPreparedImport: @unchecked Sendable {
  var envelope: BrowserImportEnvelope
  var operationID: UUID
  var requestFingerprint: String
}

private struct BrowserImportEnvelope: Codable {
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

private enum BrowserBridgeRequestCompletionState {
  case incomplete
  case complete(Int)
  case invalid
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
      return false
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

private struct BrowserBridgeHTTPRequest {
  static let maximumRequestBytes = BrowserExtensionProtocol.maximumInputBytes
  static let maximumHeaderBytes = 32 * 1_024
  private static let headerSeparator = Data("\r\n\r\n".utf8)

  var method: String
  var path: String
  var headers: [String: String]
  var body: Data

  init?(data: Data) {
    guard let separatorRange = data.range(of: Self.headerSeparator),
          separatorRange.lowerBound <= Self.maximumHeaderBytes,
          let headerText = String(data: data[..<separatorRange.lowerBound], encoding: .utf8) else {
      return nil
    }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
    guard requestParts.count == 3,
          requestParts[2].hasPrefix("HTTP/1.") else { return nil }
    method = String(requestParts[0]).uppercased()
    path = String(requestParts[1]).components(separatedBy: "?").first ?? "/"
    var parsedHeaders: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let separator = line.firstIndex(of: ":") else { return nil }
      let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return nil }
      parsedHeaders[name] = value
    }
    headers = parsedHeaders
    body = Data(data[separatorRange.upperBound...])
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

  static func completionState(for data: Data) -> BrowserBridgeRequestCompletionState {
    guard let separatorRange = data.range(of: headerSeparator) else {
      return data.count > maximumHeaderBytes ? .invalid : .incomplete
    }
    guard separatorRange.lowerBound <= maximumHeaderBytes,
          let headerText = String(data: data[..<separatorRange.lowerBound], encoding: .utf8) else {
      return .invalid
    }
    let contentLengthLine = headerText.components(separatedBy: "\r\n").first {
      $0.lowercased().hasPrefix("content-length:")
    }
    let contentLength: Int
    if let contentLengthLine,
       let separator = contentLengthLine.firstIndex(of: ":"),
       let value = Int(contentLengthLine[contentLengthLine.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)),
       value >= 0 {
      contentLength = value
    } else {
      contentLength = 0
    }
    let requestLength = separatorRange.upperBound + contentLength
    guard requestLength <= maximumRequestBytes else { return .invalid }
    return data.count >= requestLength ? .complete(requestLength) : .incomplete
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
