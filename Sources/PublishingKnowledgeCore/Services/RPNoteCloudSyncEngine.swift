import CloudKit
import CryptoKit
import Foundation
import Security

/// Server state of one attachment record. Owned by the sync engine; adapters only persist it.
public struct RPNoteCloudAttachmentBaseline: Sendable, Equatable, Codable {
  public var noteID: String
  public var sha256: String
  public var systemFields: Data?

  public init(noteID: String, sha256: String, systemFields: Data?) {
    self.noteID = noteID
    self.sha256 = sha256
    self.systemFields = systemFields
  }
}

public struct RPNoteCloudPersistentState: Sendable, Equatable, Codable {
  public var engineState: Data?
  public var boundAccountID: String?
  public var initialFetchComplete: Bool
  public var zoneRecoveryRequired: Bool
  public var zoneEstablished: Bool
  /// Attachment records known to exist in the zone, keyed by record name.
  public var attachmentBaselines: [String: RPNoteCloudAttachmentBaseline]

  public init(
    engineState: Data? = nil,
    boundAccountID: String? = nil,
    initialFetchComplete: Bool = false,
    zoneRecoveryRequired: Bool = false,
    zoneEstablished: Bool = false,
    attachmentBaselines: [String: RPNoteCloudAttachmentBaseline] = [:]
  ) {
    self.engineState = engineState
    self.boundAccountID = boundAccountID
    self.initialFetchComplete = initialFetchComplete
    self.zoneRecoveryRequired = zoneRecoveryRequired
    self.zoneEstablished = zoneEstablished
    self.attachmentBaselines = attachmentBaselines
  }

  private enum CodingKeys: String, CodingKey {
    case engineState, boundAccountID, initialFetchComplete, zoneRecoveryRequired, zoneEstablished, attachmentBaselines
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    engineState = try values.decodeIfPresent(Data.self, forKey: .engineState)
    boundAccountID = try values.decodeIfPresent(String.self, forKey: .boundAccountID)
    initialFetchComplete = try values.decodeIfPresent(Bool.self, forKey: .initialFetchComplete) ?? false
    zoneRecoveryRequired = try values.decodeIfPresent(Bool.self, forKey: .zoneRecoveryRequired) ?? false
    zoneEstablished = try values.decodeIfPresent(Bool.self, forKey: .zoneEstablished) ?? false
    attachmentBaselines = try values.decodeIfPresent(
      [String: RPNoteCloudAttachmentBaseline].self, forKey: .attachmentBaselines
    ) ?? [:]
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encodeIfPresent(engineState, forKey: .engineState)
    try values.encodeIfPresent(boundAccountID, forKey: .boundAccountID)
    try values.encode(initialFetchComplete, forKey: .initialFetchComplete)
    try values.encode(zoneRecoveryRequired, forKey: .zoneRecoveryRequired)
    try values.encode(zoneEstablished, forKey: .zoneEstablished)
    try values.encode(attachmentBaselines, forKey: .attachmentBaselines)
  }
}

public enum RPNoteCloudBootstrapPolicy {
  public static func accountChanged(_ accountID: String, saved: RPNoteCloudPersistentState) -> Bool {
    saved.boundAccountID != nil && saved.boundAccountID != accountID
  }

  public static func stateForFirstBinding(_ accountID: String, saved: RPNoteCloudPersistentState) -> RPNoteCloudPersistentState {
    guard saved.boundAccountID == nil else { return saved }
    var state = saved
    state.boundAccountID = accountID
    return state
  }

  public static func stateForConfirmedAccountChange(_ accountID: String) -> RPNoteCloudPersistentState {
    RPNoteCloudPersistentState(boundAccountID: accountID, initialFetchComplete: false, zoneEstablished: false)
  }

  public static func resetAfterInvalidEngineState(_ saved: RPNoteCloudPersistentState) -> RPNoteCloudPersistentState {
    var state = saved
    state.engineState = nil
    state.initialFetchComplete = false
    return state
  }

  public static func lockSeedUntilFetch(_ saved: RPNoteCloudPersistentState) -> RPNoteCloudPersistentState {
    var state = saved
    state.initialFetchComplete = false
    return state
  }

  public static func requireZoneRecovery(_ saved: RPNoteCloudPersistentState) -> RPNoteCloudPersistentState {
    var state = saved
    state.initialFetchComplete = false
    state.zoneRecoveryRequired = true
    return state
  }

  public static func confirmZoneRecovery(_ saved: RPNoteCloudPersistentState) -> RPNoteCloudPersistentState {
    var state = saved
    state.engineState = nil
    state.initialFetchComplete = false
    state.zoneRecoveryRequired = false
    state.zoneEstablished = false
    state.attachmentBaselines = [:]
    return state
  }

  public static func maySeedLocalChanges(_ state: RPNoteCloudPersistentState) -> Bool {
    state.boundAccountID != nil && state.initialFetchComplete
  }

  public static func mayCommitFetch(completed: Bool, zoneFetchSucceeded: Bool, allRemoteChangesApplied: Bool) -> Bool {
    completed && zoneFetchSucceeded && allRemoteChangesApplied
  }

  public static func missingZoneRequiresRecovery(_ state: RPNoteCloudPersistentState) -> Bool {
    state.zoneEstablished
  }
}

public enum RPNoteCloudLocalChange: Sendable {
  case upsert(note: RPNote, revision: String, systemFields: Data?)
  case tombstone(id: UUID, deletedAt: Date, revision: String, systemFields: Data?)

  public var id: UUID {
    switch self {
    case let .upsert(note, _, _): note.id
    case let .tombstone(id, _, _, _): id
    }
  }

  public var revision: String {
    switch self {
    case let .upsert(_, revision, _), let .tombstone(_, _, revision, _): revision
    }
  }
}

public enum RPNoteCloudRemoteChange: Sendable {
  case note(RPNote, sha256: String, systemFields: Data)
  case tombstone(id: UUID, deletedAt: Date, systemFields: Data)
}

public enum RPNoteCloudApplyResult: Sendable, Equatable {
  case applied
  case keptLocalWithConflictCopy
  case ignoredStale
}

/// Decides which attachment records a local note change uploads or deletes. Attachments
/// whose server copy already has the same digest are not uploaded again.
public enum RPNoteCloudAttachmentPlan {
  public static let recordNamePrefix = "att-"

  public struct Upload: Sendable, Equatable {
    public let recordName: String
    public let attachment: RPNoteAttachment
    public let sha256: String
  }

  public struct Plan: Sendable, Equatable {
    public var uploads: [Upload]
    /// Record names of attachments the note no longer references (or all of them for a tombstone).
    public var deletions: [String]
  }

  public static func recordName(noteID: UUID, attachmentID: UUID) -> String {
    "\(recordNamePrefix)\(noteID.uuidString.lowercased())-\(attachmentID.uuidString.lowercased())"
  }

  public static func plan(
    for change: RPNoteCloudLocalChange,
    baselines: [String: RPNoteCloudAttachmentBaseline]
  ) -> Plan {
    let noteKey = change.id.uuidString.lowercased()
    let existing = baselines.filter { $0.value.noteID == noteKey }
    guard case let .upsert(note, _, _) = change else {
      return Plan(uploads: [], deletions: existing.keys.sorted())
    }
    var uploads: [Upload] = []
    var referenced = Set<String>()
    for attachment in note.attachments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
      let name = recordName(noteID: note.id, attachmentID: attachment.id)
      referenced.insert(name)
      let sha256 = RPNoteCloudPayload.attachmentDigest(attachment.data)
      if existing[name]?.sha256 != sha256 {
        uploads.append(Upload(recordName: name, attachment: attachment, sha256: sha256))
      }
    }
    return Plan(uploads: uploads, deletions: existing.keys.filter { !referenced.contains($0) }.sorted())
  }
}

/// The app owns its local database; this adapter is the only bridge from the
/// shared CloudKit engine into that database.
public protocol RPNoteCloudSyncLocalAdapter: Sendable {
  func loadPersistentState() async throws -> RPNoteCloudPersistentState
  func savePersistentState(_ state: RPNoteCloudPersistentState) async throws
  func localChanges() async throws -> [RPNoteCloudLocalChange]
  func applyRemote(_ change: RPNoteCloudRemoteChange) async throws -> RPNoteCloudApplyResult
  func markSent(id: UUID, revision: String, systemFields: Data) async throws
  func clearSystemFields(id: UUID, revision: String?) async throws
  /// Clears account-scoped CloudKit baselines and requeues retained local notes/tombstones.
  /// Called only after an explicit account-change confirmation.
  func prepareAccountChange() async throws
  func prepareZoneRecovery() async throws
  func stageAsset(_ data: Data) async throws -> URL
  func finishAsset(_ url: URL) async
  /// The local bytes of one attachment, or nil when this device does not have it. Used to
  /// rebuild a fetched note whose unchanged attachments were not sent again.
  func attachmentData(noteID: UUID, attachmentID: UUID) async throws -> Data?
}

public enum RPNoteCloudSyncStatus: Sendable, Equatable {
  case disabled
  case checkingAccount
  case waitingForAccount
  case accountChangeNeedsReview
  case syncing
  case conflict
  case remoteZoneDeletedNeedsRecovery
  case failed(String)
}

/// Shared CloudKit transport for one private-database note zone.
/// Constructing it never starts network traffic; callers must opt in and call `start()`.
public actor RPNoteCloudSyncEngine: CKSyncEngineDelegate {
  public static let containerIdentifier = "iCloud.com.chengjinfang.repopress"
  public static let zoneName = "RepoPressNotesV2"
  public static let recordType = "RPNoteV2"
  public static let attachmentRecordType = "RPNoteAttachmentV2"
  public static let schemaVersion: Int64 = 2
  /// Bounds transient memory during encoding; oversized notes remain local and get a visible per-note error.
  public static let maximumAutomaticPayloadBytes = 64 * 1024 * 1024

  private static let payloadField = "payload"
  private static let payloadDigestField = "sha256"
  private static let deletedAtField = "deletedAt"
  private static let schemaVersionField = "schemaVersion"
  private static let attachmentDataField = "data"
  private static let attachmentByteCountField = "byteCount"
  private static let attachmentNoteField = "noteID"
  private static let maximumRecordsPerBatch = 200
  private static let maximumBytesPerBatch = 128 * 1024 * 1024

  private let injectedContainer: CKContainer?
  private let entitlementCheck: (@Sendable () -> Bool)?
  private var activeContainer: CKContainer?
  private let adapter: any RPNoteCloudSyncLocalAdapter
  private var isEnabled: Bool
  private let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
  private var engine: CKSyncEngine?
  private var persistentState = RPNoteCloudPersistentState()
  private var deferredSerialization: CKSyncEngine.State.Serialization?
  private var fetchInProgress = false
  private var zoneReady = false
  private var status: RPNoteCloudSyncStatus
  private var unsafeStateAfterApplyFailure = false
  private struct InFlightSave {
    var revision: String
    var assetURLs: [URL]
  }
  private var inFlight: [String: InFlightSave] = [:]
  private struct StagedAttachment {
    var url: URL
    var sha256: String
  }
  private enum BufferedRemoteChange {
    case note(id: UUID, envelopeURL: URL, sha256: String, systemFields: Data)
    case tombstone(id: UUID, deletedAt: Date, systemFields: Data)
  }
  /// Attachment records fetched in the current fetch, keyed by record name.
  private var stagedRemoteAttachments: [String: StagedAttachment] = [:]
  /// Note records fetched in the current zone fetch, applied once it completes.
  private var bufferedRemoteChanges: [BufferedRemoteChange] = []
  /// Notes already put into a batch during the current send, so a failed group is not retried in a loop.
  private var attemptedInCurrentSend: Set<String> = []
  private var perNoteErrors: [UUID: String] = [:]
  private var startInProgress = false
  private var lifecycleGeneration = 0
  private var restartRequested = false
  private var queuedAccountConfirmation = false
  private var queuedZoneConfirmation = false

  public init(
    adapter: any RPNoteCloudSyncLocalAdapter,
    isEnabled: Bool = false,
    container: CKContainer? = nil,
    entitlementCheck: (@Sendable () -> Bool)? = nil
  ) {
    self.adapter = adapter
    self.isEnabled = isEnabled
    self.injectedContainer = container
    self.entitlementCheck = entitlementCheck
    self.activeContainer = nil
    self.status = isEnabled ? .checkingAccount : .disabled
  }

  public func currentStatus() -> RPNoteCloudSyncStatus { status }
  public func noteErrors() -> [UUID: String] { perNoteErrors }

  /// Starts only after explicit user opt-in and a usable iCloud account.
  public func start(confirmAccountChange: Bool = false, confirmZoneRecovery: Bool = false) async throws {
    guard isEnabled else { status = .disabled; return }
    if engine != nil { return }
    guard !startInProgress else {
      queuedAccountConfirmation = queuedAccountConfirmation || confirmAccountChange
      queuedZoneConfirmation = queuedZoneConfirmation || confirmZoneRecovery
      restartRequested = true
      return
    }
    startInProgress = true
    let generation = lifecycleGeneration
    defer {
      startInProgress = false
      if restartRequested, isEnabled {
        let accountConfirmation = queuedAccountConfirmation
        let zoneConfirmation = queuedZoneConfirmation
        restartRequested = false
        queuedAccountConfirmation = false
        queuedZoneConfirmation = false
        Task { try? await self.start(confirmAccountChange: accountConfirmation, confirmZoneRecovery: zoneConfirmation) }
      }
    }
    unsafeStateAfterApplyFailure = false
    deferredSerialization = nil
    fetchInProgress = false
    zoneReady = false
    status = .checkingAccount
    do {
      // CKContainer construction can trap when the signed app lacks the iCloud
      // entitlement. Defer it until the user explicitly enables sync.
      let cloudContainer: CKContainer
      if let activeContainer {
        cloudContainer = activeContainer
      } else if let injectedContainer {
        cloudContainer = injectedContainer
      } else {
        let hasEntitlement = entitlementCheck?() ?? Self.hasRequiredCloudKitEntitlements()
        cloudContainer = try Self.makeCloudContainerIfAuthorized(hasEntitlement) {
          CKContainer(identifier: Self.containerIdentifier)
        }
      }
      activeContainer = cloudContainer
      let accountStatus = try await cloudContainer.accountStatus()
      guard generation == lifecycleGeneration, isEnabled else { return }
      guard accountStatus == .available else { status = .waitingForAccount; return }
      let accountID = try await cloudContainer.userRecordID().recordName
      guard generation == lifecycleGeneration, isEnabled else { return }
      let oldState = try await adapter.loadPersistentState()
      guard generation == lifecycleGeneration, isEnabled else { return }
      let accountChanged = RPNoteCloudBootstrapPolicy.accountChanged(accountID, saved: oldState)
      if accountChanged, !confirmAccountChange {
        status = .accountChangeNeedsReview
        return
      }
      if oldState.zoneRecoveryRequired, !accountChanged, !confirmZoneRecovery {
        status = .remoteZoneDeletedNeedsRecovery
        return
      }
      if accountChanged { try await adapter.prepareAccountChange() }
      if oldState.zoneRecoveryRequired, !accountChanged { try await adapter.prepareZoneRecovery() }
      guard generation == lifecycleGeneration, isEnabled else { return }
      var saved: RPNoteCloudPersistentState
      if accountChanged {
        saved = RPNoteCloudBootstrapPolicy.stateForConfirmedAccountChange(accountID)
      } else if oldState.zoneRecoveryRequired {
        saved = RPNoteCloudBootstrapPolicy.confirmZoneRecovery(oldState)
      } else {
        saved = RPNoteCloudBootstrapPolicy.stateForFirstBinding(accountID, saved: oldState)
      }
      let serialization: CKSyncEngine.State.Serialization?
      if let bytes = saved.engineState {
        if let decoded = try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: bytes) {
          serialization = decoded
        } else {
          saved = RPNoteCloudBootstrapPolicy.resetAfterInvalidEngineState(saved)
          serialization = nil
        }
      } else {
        serialization = nil
      }
      saved = RPNoteCloudBootstrapPolicy.lockSeedUntilFetch(saved)
      try await adapter.savePersistentState(saved)
      guard generation == lifecycleGeneration, isEnabled else { return }
      persistentState = saved
      var configuration = CKSyncEngine.Configuration(
        database: cloudContainer.privateCloudDatabase,
        stateSerialization: serialization,
        delegate: self
      )
      configuration.automaticallySync = true
      engine = CKSyncEngine(configuration)
      engine?.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
      status = .syncing
    } catch {
      status = .failed(error.localizedDescription)
      throw error
    }
  }

  /// Refreshes local changes. Initial local seeding remains locked until the first zone fetch succeeds.
  public func syncNow() async throws {
    guard isEnabled, let engine else { return }
    guard zoneReady else { return }
    let generation = lifecycleGeneration
    try await engine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .all))
    guard generation == lifecycleGeneration, self.engine === engine, persistentState.initialFetchComplete else { return }
    try await enqueueLocalChanges(on: engine)
    guard generation == lifecycleGeneration, self.engine === engine else { return }
    try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .all))
  }

  /// Queues local edits without a remote fetch. With `automaticallySync` the engine schedules
  /// the send itself; launch and foreground still call `syncNow()`, which fetches first.
  public func enqueueLocalChangesForSend() async throws {
    guard isEnabled, let engine, zoneReady, persistentState.initialFetchComplete,
      !unsafeStateAfterApplyFailure
    else { return }
    try await enqueueLocalChanges(on: engine)
  }

  public func setEnabled(_ enabled: Bool) async throws {
    lifecycleGeneration += 1
    guard enabled else {
      isEnabled = false
      engine = nil
      status = .disabled
      return
    }
    isEnabled = true
    if startInProgress { restartRequested = true; return }
    try await start()
  }

  public func confirmAccountChangeAndStart() async throws {
    try await start(confirmAccountChange: true)
  }

  public func confirmZoneRecoveryAndStart() async throws {
    try await start(confirmZoneRecovery: true)
  }

  public func retryAfterFailure() async throws {
    engine = nil
    try await start()
  }

  public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    guard isEnabled, engine === syncEngine else { return }
    switch event {
    case let .stateUpdate(update):
      await handleStateUpdate(update, syncEngine: syncEngine)
    case .accountChange:
      // Never let an engine continue under a different signed-in account.
      engine = nil
      unsafeStateAfterApplyFailure = true
      discardBufferedRemoteChanges()
      status = .waitingForAccount
    case .willFetchChanges:
      fetchInProgress = true
      deferredSerialization = nil
      discardBufferedRemoteChanges()
    case let .fetchedDatabaseChanges(changes):
      await handleFetchedDatabaseChanges(changes)
    case let .fetchedRecordZoneChanges(changes):
      await handleFetchedRecordZoneChanges(changes, syncEngine: syncEngine)
    case let .didFetchRecordZoneChanges(result):
      await handleDidFetchRecordZoneChanges(result, syncEngine: syncEngine)
    case .didFetchChanges:
      await handleDidFetchChanges(syncEngine: syncEngine)
    case let .sentDatabaseChanges(result):
      await handleSentDatabaseChanges(result, syncEngine: syncEngine)
    case .willSendChanges, .didSendChanges:
      attemptedInCurrentSend = []
    case let .sentRecordZoneChanges(result):
      await handleSentRecordZoneChanges(result, syncEngine: syncEngine)
    default:
      break
    }
  }

  public func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    guard isEnabled, RPNoteCloudBootstrapPolicy.maySeedLocalChanges(persistentState), !unsafeStateAfterApplyFailure else {
      return nil
    }
    let scope = context.options.scope
    let pendingSaves = syncEngine.state.pendingRecordZoneChanges.compactMap { change -> CKRecord.ID? in
      guard scope.contains(change), case let .saveRecord(recordID) = change, recordID.zoneID == zoneID else { return nil }
      return recordID
    }
    guard !pendingSaves.isEmpty else { return nil }
    do {
      let changes = try await adapter.localChanges()
      let changedNames = Set(changes.map { Self.key($0.id) })
      // Pending saves without a local change were already sent, or name records this
      // engine no longer produces. Groups are rebuilt from local changes on every batch.
      let stale = pendingSaves.filter { !changedNames.contains($0.recordName) }
      if !stale.isEmpty { syncEngine.state.remove(pendingRecordZoneChanges: stale.map { .saveRecord($0) }) }
      let pendingNames = Set(pendingSaves.map(\.recordName))

      var recordsToSave: [CKRecord] = []
      var recordIDsToDelete: [CKRecord.ID] = []
      var batchBytes = 0
      for change in changes.sorted(by: { Self.key($0.id) < Self.key($1.id) }) {
        let name = Self.key(change.id)
        guard pendingNames.contains(name), !attemptedInCurrentSend.contains(name) else { continue }
        let group: RecordGroup
        do {
          group = try await makeRecordGroup(for: change)
        } catch {
          setNoteFailure(id: change.id, error: error)
          attemptedInCurrentSend.insert(name)
          syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(Self.recordID(change.id, zoneID: zoneID))])
          continue
        }
        let wouldOverflow = recordsToSave.count + group.records.count > Self.maximumRecordsPerBatch
          || batchBytes + group.byteCount > Self.maximumBytesPerBatch
        if !recordsToSave.isEmpty, wouldOverflow {
          await releaseStagedAssets(of: group)
          break
        }
        attemptedInCurrentSend.insert(name)
        recordsToSave += group.records
        recordIDsToDelete += group.deletions
        batchBytes += group.byteCount
      }
      guard !recordsToSave.isEmpty || !recordIDsToDelete.isEmpty else { return nil }
      // A note and the attachment records it references commit together or not at all,
      // so no other device can fetch a note whose attachments are missing.
      return CKSyncEngine.RecordZoneChangeBatch(
        recordsToSave: recordsToSave,
        recordIDsToDelete: recordIDsToDelete,
        atomicByZone: true
      )
    } catch {
      status = .failed(error.localizedDescription)
      return nil
    }
  }

  // MARK: - Fetch

  private func handleStateUpdate(_ update: CKSyncEngine.Event.StateUpdate, syncEngine: CKSyncEngine) async {
    guard !unsafeStateAfterApplyFailure else { return }
    if fetchInProgress || !persistentState.initialFetchComplete {
      deferredSerialization = update.stateSerialization
      return
    }
    do {
      persistentState.engineState = try JSONEncoder().encode(update.stateSerialization)
      try await adapter.savePersistentState(persistentState)
    } catch {
      guard isEnabled, engine === syncEngine else { return }
      status = .failed("Could not persist iCloud sync state: \(error.localizedDescription)")
    }
  }

  private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) async {
    guard changes.deletions.contains(where: { $0.zoneID == zoneID }) else { return }
    // Do not silently re-seed old local data after the entire remote zone was removed.
    await requireZoneRecovery(message: "Could not persist the deleted iCloud zone state")
  }

  private func handleFetchedRecordZoneChanges(
    _ changes: CKSyncEngine.Event.FetchedRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) async {
    do {
      for modification in changes.modifications where modification.record.recordID.zoneID == zoneID {
        try bufferRemoteRecord(modification.record)
      }
      for deletion in changes.deletions where deletion.recordID.zoneID == zoneID {
        let name = deletion.recordID.recordName
        // Notes are deleted with tombstone records; only attachment records are removed physically.
        guard Self.isAttachmentRecordName(name) else { throw SyncError.unexpectedCloudDeletion(name) }
        removeStagedAttachment(name)
        persistentState.attachmentBaselines.removeValue(forKey: name)
      }
    } catch {
      guard isEnabled, engine === syncEngine else { return }
      unsafeStateAfterApplyFailure = true
      status = .failed("Remote note was not applied; restart sync to retry safely: \(error.localizedDescription)")
    }
  }

  private func handleDidFetchRecordZoneChanges(
    _ result: CKSyncEngine.Event.DidFetchRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) async {
    guard result.zoneID == zoneID, !unsafeStateAfterApplyFailure else { return }
    if let error = result.error {
      discardBufferedRemoteChanges()
      guard error.code == .zoneNotFound else {
        unsafeStateAfterApplyFailure = true
        status = .failed("Could not fetch iCloud notes: \(error.localizedDescription)")
        return
      }
      zoneReady = false
      if RPNoteCloudBootstrapPolicy.missingZoneRequiresRecovery(persistentState) {
        // A missing zone can invalidate every stored record changeTag; require explicit recovery.
        await requireZoneRecovery(message: "Could not persist the missing iCloud zone state")
      } else {
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        status = .syncing
      }
      return
    }
    zoneReady = true
    persistentState.zoneEstablished = true
    do {
      // Apply only after the whole zone page set arrived, so attachment records fetched
      // after their note are available when the note is rebuilt.
      try await applyBufferedRemoteChanges(syncEngine: syncEngine)
    } catch {
      guard isEnabled, engine === syncEngine else { return }
      unsafeStateAfterApplyFailure = true
      status = .failed("Remote note was not applied; restart sync to retry safely: \(error.localizedDescription)")
    }
  }

  private func handleDidFetchChanges(syncEngine: CKSyncEngine) async {
    fetchInProgress = false
    let canCommit = RPNoteCloudBootstrapPolicy.mayCommitFetch(
      completed: true,
      zoneFetchSucceeded: zoneReady,
      allRemoteChangesApplied: !unsafeStateAfterApplyFailure
    )
    guard canCommit else { deferredSerialization = nil; return }
    do {
      persistentState.initialFetchComplete = true
      if let deferredSerialization {
        persistentState.engineState = try JSONEncoder().encode(deferredSerialization)
      }
      try await adapter.savePersistentState(persistentState)
      guard isEnabled, engine === syncEngine else { return }
      deferredSerialization = nil
      try await enqueueLocalChanges(on: syncEngine)
      guard isEnabled, engine === syncEngine else { return }
      status = .syncing
    } catch {
      guard isEnabled, engine === syncEngine else { return }
      status = .failed(error.localizedDescription)
    }
  }

  private func requireZoneRecovery(message: String) async {
    unsafeStateAfterApplyFailure = true
    discardBufferedRemoteChanges()
    persistentState = RPNoteCloudBootstrapPolicy.requireZoneRecovery(persistentState)
    status = .remoteZoneDeletedNeedsRecovery
    engine = nil
    let generation = lifecycleGeneration
    do {
      try await adapter.savePersistentState(persistentState)
    } catch {
      guard isEnabled, lifecycleGeneration == generation else { return }
      status = .failed("\(message): \(error.localizedDescription)")
    }
  }

  /// Copies a fetched record's asset out of CloudKit's temporary storage and queues it.
  private func bufferRemoteRecord(_ record: CKRecord) throws {
    let name = record.recordID.recordName
    guard record.recordID.zoneID == zoneID,
      (record[Self.schemaVersionField] as? Int64) == Self.schemaVersion
    else { throw SyncError.invalidRemoteRecord }
    switch record.recordType {
    case Self.attachmentRecordType:
      guard let noteKey = record[Self.attachmentNoteField] as? String,
        let noteID = UUID(uuidString: noteKey), noteKey == Self.key(noteID),
        name.hasPrefix(Self.attachmentRecordPrefix(noteID: noteID)),
        let sha256 = record[Self.payloadDigestField] as? String,
        let asset = record[Self.attachmentDataField] as? CKAsset, let sourceURL = asset.fileURL
      else { throw SyncError.invalidRemoteRecord }
      removeStagedAttachment(name)
      stagedRemoteAttachments[name] = StagedAttachment(url: try Self.copyAssetToStaging(sourceURL), sha256: sha256)
      persistentState.attachmentBaselines[name] = RPNoteCloudAttachmentBaseline(
        noteID: noteKey, sha256: sha256, systemFields: try Self.archiveSystemFields(record)
      )
    case Self.recordType:
      guard let id = UUID(uuidString: name), name == Self.key(id) else { throw SyncError.invalidRemoteRecord }
      let fields = try Self.archiveSystemFields(record)
      if let deletedAt = record[Self.deletedAtField] as? Date {
        bufferedRemoteChanges.append(.tombstone(id: id, deletedAt: deletedAt, systemFields: fields))
        return
      }
      guard let asset = record[Self.payloadField] as? CKAsset, let sourceURL = asset.fileURL,
        let sha256 = record[Self.payloadDigestField] as? String
      else { throw SyncError.invalidRemoteRecord }
      bufferedRemoteChanges.append(.note(
        id: id, envelopeURL: try Self.copyAssetToStaging(sourceURL), sha256: sha256, systemFields: fields
      ))
    default:
      throw SyncError.invalidRemoteRecord
    }
  }

  private func applyBufferedRemoteChanges(syncEngine: CKSyncEngine) async throws {
    let buffered = bufferedRemoteChanges
    bufferedRemoteChanges = []
    defer {
      for change in buffered { if case let .note(_, url, _, _) = change { Self.removeStagedFile(url) } }
      discardStagedAttachments()
    }
    for change in buffered {
      switch change {
      case let .tombstone(id, deletedAt, fields):
        _ = try await adapter.applyRemote(.tombstone(id: id, deletedAt: deletedAt, systemFields: fields))
      case let .note(id, url, sha256, fields):
        try await applyRemoteNote(id: id, envelopeURL: url, sha256: sha256, systemFields: fields)
      }
      guard isEnabled, engine === syncEngine else { return }
    }
  }

  private func applyRemoteNote(id: UUID, envelopeURL: URL, sha256: String, systemFields: Data) async throws {
    let values = try envelopeURL.resourceValues(forKeys: [.fileSizeKey])
    guard let fileSize = values.fileSize, fileSize <= RPNoteCloudPayload.maximumEnvelopeBytes else {
      throw SyncError.remotePayloadTooLarge
    }
    let payload = try Data(contentsOf: envelopeURL)
    guard Self.digest(payload) == sha256 else { throw SyncError.assetDigestMismatch }
    let envelope = try RPNoteCloudPayload.decode(payload)
    guard envelope.note.id == id else { throw SyncError.recordIdentityMismatch }
    var bytes: [UUID: Data] = [:]
    for descriptor in envelope.attachments {
      bytes[descriptor.id] = try await attachmentBytes(noteID: id, descriptor: descriptor)
    }
    let note = try RPNoteCloudPayload.assemble(envelope) { descriptor in
      guard let data = bytes[descriptor.id] else { throw SyncError.missingRemoteAttachment(descriptor.id.uuidString) }
      return data
    }
    _ = try await adapter.applyRemote(.note(note, sha256: sha256, systemFields: systemFields))
  }

  /// Unchanged attachments are not re-sent, so a note's bytes come from this fetch or,
  /// when their digest still matches, from the local copy.
  private func attachmentBytes(noteID: UUID, descriptor: RPNoteCloudAttachmentDescriptor) async throws -> Data {
    let name = RPNoteCloudAttachmentPlan.recordName(noteID: noteID, attachmentID: descriptor.id)
    if let staged = stagedRemoteAttachments[name], staged.sha256 == descriptor.sha256 {
      return try Data(contentsOf: staged.url)
    }
    if let local = try await adapter.attachmentData(noteID: noteID, attachmentID: descriptor.id),
      RPNoteCloudPayload.attachmentDigest(local) == descriptor.sha256 {
      return local
    }
    throw SyncError.missingRemoteAttachment(name)
  }

  private func discardBufferedRemoteChanges() {
    for change in bufferedRemoteChanges { if case let .note(_, url, _, _) = change { Self.removeStagedFile(url) } }
    bufferedRemoteChanges = []
    discardStagedAttachments()
  }

  private func removeStagedAttachment(_ name: String) {
    if let staged = stagedRemoteAttachments.removeValue(forKey: name) { Self.removeStagedFile(staged.url) }
  }

  private func discardStagedAttachments() {
    for staged in stagedRemoteAttachments.values { Self.removeStagedFile(staged.url) }
    stagedRemoteAttachments = [:]
  }

  // MARK: - Send

  private func enqueueLocalChanges(on engine: CKSyncEngine) async throws {
    let changes = try await adapter.localChanges()
    let pending = changes.map { CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID($0.id, zoneID: zoneID)) }
    if !pending.isEmpty { engine.state.add(pendingRecordZoneChanges: pending) }
  }

  private struct RecordGroup {
    var records: [CKRecord]
    var deletions: [CKRecord.ID]
    var byteCount: Int
    var assetURLs: [URL]
  }

  /// The note record plus the attachment records it adds, replaces, or no longer uses.
  private func makeRecordGroup(for change: RPNoteCloudLocalChange) async throws -> RecordGroup {
    if case let .upsert(note, _, _) = change, Self.estimatedNoteBytes(note) > Self.maximumAutomaticPayloadBytes {
      throw SyncError.noteExceedsAutomaticLimit
    }
    let plan = RPNoteCloudAttachmentPlan.plan(for: change, baselines: persistentState.attachmentBaselines)
    var group = RecordGroup(records: [], deletions: [], byteCount: 0, assetURLs: [])
    do {
      for upload in plan.uploads {
        let record = try await makeAttachmentRecord(upload, noteID: change.id, group: &group)
        group.records.append(record)
        group.byteCount += upload.attachment.data.count
      }
      group.records.append(try await makeRecord(for: change, group: &group))
    } catch {
      await releaseStagedAssets(of: group)
      throw error
    }
    group.deletions = plan.deletions.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
    return group
  }

  private func makeAttachmentRecord(
    _ upload: RPNoteCloudAttachmentPlan.Upload,
    noteID: UUID,
    group: inout RecordGroup
  ) async throws -> CKRecord {
    let recordID = CKRecord.ID(recordName: upload.recordName, zoneID: zoneID)
    let record = try Self.makeRecord(
      recordID: recordID,
      recordType: Self.attachmentRecordType,
      systemFields: persistentState.attachmentBaselines[upload.recordName]?.systemFields
    )
    let staged = try await adapter.stageAsset(upload.attachment.data)
    group.assetURLs.append(staged)
    record[Self.attachmentDataField] = CKAsset(fileURL: staged)
    record[Self.payloadDigestField] = upload.sha256 as CKRecordValue
    record[Self.attachmentByteCountField] = Int64(upload.attachment.data.count) as CKRecordValue
    record[Self.attachmentNoteField] = Self.key(noteID) as CKRecordValue
    record[Self.schemaVersionField] = Self.schemaVersion as CKRecordValue
    trackInFlight(recordID.recordName, revision: upload.sha256, assetURL: staged)
    return record
  }

  private func makeRecord(for change: RPNoteCloudLocalChange, group: inout RecordGroup) async throws -> CKRecord {
    let recordID = Self.recordID(change.id, zoneID: zoneID)
    let record: CKRecord
    switch change {
    case let .upsert(note, revision, systemFields):
      record = try Self.makeRecord(recordID: recordID, recordType: Self.recordType, systemFields: systemFields)
      let payload = try RPNoteCloudPayload.encode(note)
      let staged = try await adapter.stageAsset(payload)
      group.assetURLs.append(staged)
      group.byteCount += payload.count
      record[Self.payloadField] = CKAsset(fileURL: staged)
      record[Self.payloadDigestField] = Self.digest(payload) as CKRecordValue
      record[Self.deletedAtField] = nil
      record[Self.schemaVersionField] = Self.schemaVersion as CKRecordValue
      trackInFlight(recordID.recordName, revision: revision, assetURL: staged)
    case let .tombstone(_, deletedAt, revision, systemFields):
      record = try Self.makeRecord(recordID: recordID, recordType: Self.recordType, systemFields: systemFields)
      record[Self.payloadField] = nil
      record[Self.payloadDigestField] = nil
      record[Self.deletedAtField] = deletedAt as CKRecordValue
      record[Self.schemaVersionField] = Self.schemaVersion as CKRecordValue
      trackInFlight(recordID.recordName, revision: revision, assetURL: nil)
    }
    perNoteErrors.removeValue(forKey: change.id)
    return record
  }

  private func trackInFlight(_ recordName: String, revision: String, assetURL: URL?) {
    var entry = inFlight[recordName] ?? InFlightSave(revision: revision, assetURLs: [])
    entry.revision = revision
    if let assetURL { entry.assetURLs.append(assetURL) }
    inFlight[recordName] = entry
  }

  private func releaseStagedAssets(of group: RecordGroup) async {
    for record in group.records { inFlight.removeValue(forKey: record.recordID.recordName) }
    for url in group.assetURLs { await adapter.finishAsset(url) }
  }

  private func handleSentDatabaseChanges(
    _ result: CKSyncEngine.Event.SentDatabaseChanges,
    syncEngine: CKSyncEngine
  ) async {
    if let failedZone = result.failedZoneSaves.first(where: { $0.zone.zoneID == zoneID }) {
      status = .failed("Could not create the private notes zone: \(failedZone.error.localizedDescription)")
      return
    }
    guard result.savedZones.contains(where: { $0.zoneID == zoneID }) else { return }
    zoneReady = true
    persistentState.zoneEstablished = true
    try? await adapter.savePersistentState(persistentState)
    guard isEnabled, engine === syncEngine else { return }
    Task { try? await syncEngine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .all)) }
  }

  private func handleSentRecordZoneChanges(
    _ result: CKSyncEngine.Event.SentRecordZoneChanges,
    syncEngine: CKSyncEngine
  ) async {
    var attachmentStateChanged = false
    for record in result.savedRecords where record.recordID.zoneID == zoneID {
      guard isEnabled, engine === syncEngine else { return }
      let name = record.recordID.recordName
      guard let sent = inFlight.removeValue(forKey: name) else { continue }
      do {
        if record.recordType == Self.attachmentRecordType {
          if let noteKey = record[Self.attachmentNoteField] as? String {
            persistentState.attachmentBaselines[name] = RPNoteCloudAttachmentBaseline(
              noteID: noteKey, sha256: sent.revision, systemFields: try Self.archiveSystemFields(record)
            )
            attachmentStateChanged = true
          }
        } else if let id = UUID(uuidString: name) {
          try await adapter.markSent(id: id, revision: sent.revision, systemFields: Self.archiveSystemFields(record))
        }
      } catch {
        guard isEnabled, engine === syncEngine else { return }
        status = .failed("CloudKit saved a note, but local sync status could not be updated: \(error.localizedDescription)")
      }
      for url in sent.assetURLs { await adapter.finishAsset(url) }
    }
    for recordID in result.deletedRecordIDs where recordID.zoneID == zoneID {
      if persistentState.attachmentBaselines.removeValue(forKey: recordID.recordName) != nil {
        attachmentStateChanged = true
      }
    }
    for failed in result.failedRecordSaves where failed.record.recordID.zoneID == zoneID {
      guard isEnabled, engine === syncEngine else { return }
      if failed.record.recordType == Self.attachmentRecordType {
        await handleFailedAttachmentSave(failed, syncEngine: syncEngine)
        attachmentStateChanged = true
      } else {
        await handleFailedRecordSave(failed, syncEngine: syncEngine)
      }
    }
    for (recordID, error) in result.failedRecordDeletes where recordID.zoneID == zoneID {
      guard isEnabled, engine === syncEngine else { return }
      if error.code == .unknownItem {
        persistentState.attachmentBaselines.removeValue(forKey: recordID.recordName)
        attachmentStateChanged = true
      } else if error.code != .batchRequestFailed {
        status = .failed(error.localizedDescription)
      }
    }
    if attachmentStateChanged {
      do {
        try await adapter.savePersistentState(persistentState)
      } catch {
        guard isEnabled, engine === syncEngine else { return }
        status = .failed("Could not persist iCloud attachment state: \(error.localizedDescription)")
      }
    }
  }

  private func handleFailedAttachmentSave(
    _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
    syncEngine: CKSyncEngine
  ) async {
    let name = failure.record.recordID.recordName
    if let sent = inFlight.removeValue(forKey: name) {
      for url in sent.assetURLs { await adapter.finishAsset(url) }
    }
    guard let noteKey = failure.record[Self.attachmentNoteField] as? String,
      let noteID = UUID(uuidString: noteKey)
    else { return }
    let noteChange = CKSyncEngine.PendingRecordZoneChange.saveRecord(Self.recordID(noteID, zoneID: zoneID))
    switch failure.error.code {
    case .serverRecordChanged:
      // Another device already created this attachment record; adopt its change tag and
      // let the note's next group re-upload only if the content differs.
      if let serverRecord = failure.error.serverRecord,
        let sha256 = serverRecord[Self.payloadDigestField] as? String,
        let fields = try? Self.archiveSystemFields(serverRecord) {
        persistentState.attachmentBaselines[name] = RPNoteCloudAttachmentBaseline(
          noteID: noteKey, sha256: sha256, systemFields: fields
        )
      }
      syncEngine.state.add(pendingRecordZoneChanges: [noteChange])
    case .unknownItem:
      persistentState.attachmentBaselines.removeValue(forKey: name)
      syncEngine.state.add(pendingRecordZoneChanges: [noteChange])
    case .batchRequestFailed, .zoneNotFound:
      // The note record in the same atomic batch reports and handles the actual failure.
      break
    case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
      .operationCancelled, .requestRateLimited, .accountTemporarilyUnavailable:
      status = .failed(failure.error.localizedDescription)
    default:
      syncEngine.state.remove(pendingRecordZoneChanges: [noteChange])
      perNoteErrors[noteID] = failure.error.localizedDescription
      status = .failed(failure.error.localizedDescription)
    }
  }

  private func handleFailedRecordSave(
    _ failure: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave,
    syncEngine: CKSyncEngine
  ) async {
    let recordID = failure.record.recordID
    guard let id = UUID(uuidString: recordID.recordName) else {
      status = .failed(failure.error.localizedDescription)
      return
    }
    let code = failure.error.code
    do {
      switch code {
      case .serverRecordChanged:
        guard let serverRecord = failure.error.serverRecord else {
          unsafeStateAfterApplyFailure = true
          status = .failed("CloudKit reported a conflict without returning the server record.")
          return
        }
        try await applyServerRecord(serverRecord, syncEngine: syncEngine)
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        status = .conflict
      case .zoneNotFound:
        zoneReady = false
        if RPNoteCloudBootstrapPolicy.missingZoneRequiresRecovery(persistentState) {
          // A previously established zone disappearing is a destructive remote event.
          // Stop before CloudKit can recreate it and replay local records.
          await requireZoneRecovery(message: "Could not persist the missing iCloud zone state")
          return
        }
        try await adapter.clearSystemFields(id: id, revision: inFlight[recordID.recordName]?.revision)
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        status = .syncing
      case .unknownItem:
        try await adapter.clearSystemFields(id: id, revision: inFlight[recordID.recordName]?.revision)
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
        status = .syncing
      case .batchRequestFailed:
        // Another record in the atomic batch failed; keep the change pending for the next send.
        await releaseInFlight(recordID.recordName)
      case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
        .operationCancelled, .requestRateLimited, .accountTemporarilyUnavailable:
        // The next send rebuilds this note's group; keep the pending change.
        await releaseInFlight(recordID.recordName)
        status = .failed(failure.error.localizedDescription)
      default:
        syncEngine.state.remove(pendingRecordZoneChanges: [.saveRecord(recordID)])
        await releaseInFlight(recordID.recordName)
        perNoteErrors[id] = failure.error.localizedDescription
        status = .failed(failure.error.localizedDescription)
      }
    } catch {
      unsafeStateAfterApplyFailure = true
      status = .failed("The failed iCloud save could not be reconciled safely: \(error.localizedDescription)")
    }
  }

  /// Applies the server's version of a conflicting note. If it references attachment
  /// bytes this device has not fetched yet, a fetch delivers them together with the note.
  private func applyServerRecord(_ record: CKRecord, syncEngine: CKSyncEngine) async throws {
    guard record.recordType == Self.recordType, record.recordID.zoneID == zoneID,
      (record[Self.schemaVersionField] as? Int64) == Self.schemaVersion,
      let id = UUID(uuidString: record.recordID.recordName), record.recordID.recordName == Self.key(id)
    else { throw SyncError.invalidRemoteRecord }
    let fields = try Self.archiveSystemFields(record)
    if let deletedAt = record[Self.deletedAtField] as? Date {
      _ = try await adapter.applyRemote(.tombstone(id: id, deletedAt: deletedAt, systemFields: fields))
      return
    }
    guard let asset = record[Self.payloadField] as? CKAsset, let sourceURL = asset.fileURL,
      let sha256 = record[Self.payloadDigestField] as? String
    else { throw SyncError.invalidRemoteRecord }
    let stagedURL = try Self.copyAssetToStaging(sourceURL)
    defer { Self.removeStagedFile(stagedURL) }
    do {
      try await applyRemoteNote(id: id, envelopeURL: stagedURL, sha256: sha256, systemFields: fields)
    } catch SyncError.missingRemoteAttachment {
      Task { try? await syncEngine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .all)) }
    }
  }

  private func releaseInFlight(_ recordName: String) async {
    guard let sent = inFlight.removeValue(forKey: recordName) else { return }
    for url in sent.assetURLs { await adapter.finishAsset(url) }
  }

  private func setNoteFailure(id: UUID, error: Error) {
    if let syncError = error as? SyncError, syncError == .noteExceedsAutomaticLimit {
      perNoteErrors[id] = "该笔记超过 iCloud 自动同步的 64 MiB 上限；本地笔记已保留。"
    } else {
      perNoteErrors[id] = error.localizedDescription
    }
  }

  private enum SyncError: Error, LocalizedError, Equatable {
    case missingCloudKitEntitlement
    case invalidRemoteRecord
    case assetDigestMismatch
    case recordIdentityMismatch
    case unexpectedCloudDeletion(String)
    case noteExceedsAutomaticLimit
    case remotePayloadTooLarge
    case missingRemoteAttachment(String)
    var errorDescription: String? {
      switch self {
      case .missingCloudKitEntitlement:
        "iCloud 笔记同步不可用：此 app 签名未包含目标 iCloud 容器和 CloudKit 服务权限。请使用配置了 iCloud CloudKit capability 的签名版本。"
      case .invalidRemoteRecord: "The iCloud note has an unsupported record schema or identity."
      case .assetDigestMismatch: "The iCloud note payload failed its SHA-256 check."
      case .recordIdentityMismatch: "The iCloud record UUID does not match its note payload."
      case let .unexpectedCloudDeletion(id): "CloudKit physically deleted note record \(id); a tombstone is required."
      case .noteExceedsAutomaticLimit: "This note exceeds the 64 MiB automatic iCloud sync limit. The local note remains unchanged."
      case .remotePayloadTooLarge: "The iCloud note payload exceeds the supported maximum size."
      case let .missingRemoteAttachment(name): "The iCloud note references attachment \(name), which is not available yet."
      }
    }
  }

  private static func estimatedNoteBytes(_ note: RPNote) -> Int {
    var total = note.markdown.utf8.count
    for attachment in note.attachments {
      let (next, overflow) = total.addingReportingOverflow(attachment.data.count)
      if overflow { return Int.max }
      total = next
    }
    let (estimated, overflow) = total.addingReportingOverflow(512 * 1024)
    return overflow ? Int.max : estimated
  }

  private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

  private static func recordID(_ id: UUID, zoneID: CKRecordZone.ID) -> CKRecord.ID {
    CKRecord.ID(recordName: key(id), zoneID: zoneID)
  }

  private static func attachmentRecordPrefix(noteID: UUID) -> String {
    RPNoteCloudAttachmentPlan.recordNamePrefix + key(noteID) + "-"
  }

  private static func isAttachmentRecordName(_ name: String) -> Bool {
    name.hasPrefix(RPNoteCloudAttachmentPlan.recordNamePrefix)
  }

  private static func makeRecord(recordID: CKRecord.ID, recordType: String, systemFields: Data?) throws -> CKRecord {
    guard let systemFields else { return CKRecord(recordType: recordType, recordID: recordID) }
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: systemFields)
    unarchiver.requiresSecureCoding = true
    defer { unarchiver.finishDecoding() }
    guard let record = CKRecord(coder: unarchiver), record.recordType == recordType,
      record.recordID == recordID
    else { throw SyncError.invalidRemoteRecord }
    return record
  }

  private static func archiveSystemFields(_ record: CKRecord) throws -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  private static func copyAssetToStaging(_ source: URL) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RepoPressCloudAssets", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent("record.asset")
    try FileManager.default.copyItem(at: source, to: destination)
    return destination
  }

  private static func removeStagedFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func hasRequiredCloudKitEntitlements() -> Bool {
#if os(macOS)
    guard let task = SecTaskCreateFromSelf(kCFAllocatorDefault) else { return false }
    let containers = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.developer.icloud-container-identifiers" as CFString,
      nil
    ) as? [String]
    let services = SecTaskCopyValueForEntitlement(
      task,
      "com.apple.developer.icloud-services" as CFString,
      nil
    ) as? [String]
    return Self.hasRequiredCloudKitEntitlements(containerIdentifiers: containers, services: services)
#elseif targetEnvironment(simulator)
    // Simulator signing commonly omits the app's real CloudKit container
    // entitlement. Do not construct CKContainer or attempt real sync there.
    return false
#else
    // iOS does not expose SecTask entitlement inspection in its public SDK.
    // Device builds rely on the signed provisioning profile and Xcode capability.
    return true
#endif
  }

  static func hasRequiredCloudKitEntitlements(
    containerIdentifiers: [String]?,
    services: [String]?
  ) -> Bool {
    containerIdentifiers?.contains(Self.containerIdentifier) == true
      && services?.contains("CloudKit") == true
  }

  static func makeCloudContainerIfAuthorized<T>(
    _ isAuthorized: Bool,
    create: () -> T
  ) throws -> T {
    guard isAuthorized else { throw SyncError.missingCloudKitEntitlement }
    return create()
  }
}
