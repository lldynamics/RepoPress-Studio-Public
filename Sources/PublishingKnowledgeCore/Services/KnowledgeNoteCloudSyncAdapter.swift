import CryptoKit
import Darwin
import Foundation

private actor KnowledgeNoteAdapterMutationGate {
  private var occupied = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !occupied {
      occupied = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty { occupied = false } else { waiters.removeFirst().resume() }
  }
}

/// Bridges the shared CloudKit engine to the Mac note library. Sync metadata
/// lives beside (not inside) the library so existing whole-library backups
/// keep their established content semantics.
public actor KnowledgeNoteCloudSyncAdapter: RPNoteCloudSyncLocalAdapter {
  private enum RecordKind: String, Codable {
    case note
    case tombstone
  }

  private struct Entry: Codable {
    var baselineKind: RecordKind? = nil
    var baselineRevision: String? = nil
    var baselineDeletedAt: Date? = nil
    var pendingKind: RecordKind? = nil
    var pendingRevision: String? = nil
    var pendingDeletedAt: Date? = nil
    var currentRevision: String? = nil
    var systemFields: Data? = nil
  }

  private struct PendingAcknowledgement {
    var kind: RecordKind
    var revision: String
    var deletedAt: Date?
  }

  private struct SidecarState: Codable {
    var engineState: Data?
    var boundAccountID: String?
    var libraryRestoreID: UUID?
    var initialFetchComplete = false
    var zoneRecoveryRequired = false
    var zoneEstablished = false
    var attachmentBaselines: [String: RPNoteCloudAttachmentBaseline] = [:]
    var entries: [String: Entry] = [:]

    private enum CodingKeys: String, CodingKey {
      case engineState, boundAccountID, libraryRestoreID, initialFetchComplete,
        zoneRecoveryRequired,
        zoneEstablished
      case attachmentBaselines, entries
    }

    init() {}

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      engineState = try values.decodeIfPresent(Data.self, forKey: .engineState)
      boundAccountID = try values.decodeIfPresent(String.self, forKey: .boundAccountID)
      libraryRestoreID = try values.decodeIfPresent(UUID.self, forKey: .libraryRestoreID)
      initialFetchComplete =
        try values.decodeIfPresent(Bool.self, forKey: .initialFetchComplete) ?? false
      zoneRecoveryRequired =
        try values.decodeIfPresent(Bool.self, forKey: .zoneRecoveryRequired) ?? false
      zoneEstablished = try values.decodeIfPresent(Bool.self, forKey: .zoneEstablished) ?? false
      attachmentBaselines =
        try values.decodeIfPresent(
          [String: RPNoteCloudAttachmentBaseline].self, forKey: .attachmentBaselines
        ) ?? [:]
      entries = try values.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
    }

    var persistentState: RPNoteCloudPersistentState {
      RPNoteCloudPersistentState(
        engineState: engineState,
        boundAccountID: boundAccountID,
        initialFetchComplete: initialFetchComplete,
        zoneRecoveryRequired: zoneRecoveryRequired,
        zoneEstablished: zoneEstablished,
        attachmentBaselines: attachmentBaselines
      )
    }

    mutating func setPersistentState(_ state: RPNoteCloudPersistentState) {
      engineState = state.engineState
      boundAccountID = state.boundAccountID
      initialFetchComplete = state.initialFetchComplete
      zoneRecoveryRequired = state.zoneRecoveryRequired
      zoneEstablished = state.zoneEstablished
      attachmentBaselines = state.attachmentBaselines
    }
  }

  private let service: KnowledgeLibraryService
  private let stateDirectoryURL: URL
  private let stateFileURL: URL
  private var state: SidecarState?
  private let mutationGate = KnowledgeNoteAdapterMutationGate()
  private var remoteApplyHandler: (@Sendable () async -> Void)?
  private var stagedAssetsPruned = false
  // Only the engine's accepted send batches register acknowledgements. A
  // local scan can run many times while a single older save is in flight.
  private var pendingAcknowledgements: [UUID: PendingAcknowledgement] = [:]

  public init(service: KnowledgeLibraryService, stateDirectoryURL: URL? = nil) {
    self.service = service
    let directory =
      stateDirectoryURL
      ?? service.rootURL.deletingLastPathComponent()
      .appendingPathComponent("KnowledgeNoteCloudSync", isDirectory: true)
    self.stateDirectoryURL = directory
    self.stateFileURL = directory.appendingPathComponent("adapter-state.json")
  }

  public func setRemoteApplyHandler(_ handler: (@Sendable () async -> Void)?) {
    remoteApplyHandler = handler
  }

  public func loadPersistentState() async throws -> RPNoteCloudPersistentState {
    await beginMutation()
    defer { endMutation() }
    try loadIfNeeded()
    return state?.persistentState ?? RPNoteCloudPersistentState()
  }

  public func savePersistentState(_ persistentState: RPNoteCloudPersistentState) async throws {
    await beginMutation()
    defer { endMutation() }
    try loadIfNeeded()
    var updated = state ?? SidecarState()
    updated.setPersistentState(persistentState)
    try persist(updated)
    state = updated
  }

  public func localChanges() async throws -> [RPNoteCloudLocalChange] {
    await beginMutation()
    defer { endMutation() }
    try loadIfNeeded()
    guard
      RPNoteCloudBootstrapPolicy.maySeedLocalChanges(
        state?.persistentState ?? RPNoteCloudPersistentState())
    else {
      return []
    }

    let noteIDs = try await service.noteDocumentIDsAsync(includeArchived: true)
    var updated = state ?? SidecarState()
    let currentKeys = Set(noteIDs.map(Self.key))
    var pendingNotesByID: [String: RPNote] = [:]
    var changes: [RPNoteCloudLocalChange] = []
    let now = Date()

    for id in noteIDs {
      guard let storedNote = try await service.noteAsync(documentID: id) else { continue }
      let note = Self.portableNote(storedNote)
      let key = Self.key(id)
      let revision = (try? Self.revision(for: note)) ?? Self.fallbackRevision(for: note)
      var entry = updated.entries[key] ?? Entry()

      // A pre-delete intent whose document still exists means the local delete
      // did not commit or the note was restored. Reconcile it back to an upsert.
      if entry.pendingKind == .tombstone {
        if entry.baselineKind == .note, entry.baselineRevision == revision {
          entry.pendingKind = nil
          entry.pendingRevision = nil
          entry.pendingDeletedAt = nil
        } else {
          entry.pendingKind = .note
          entry.pendingRevision = revision
          entry.pendingDeletedAt = nil
        }
      } else if entry.baselineKind != .note || entry.baselineRevision != revision {
        entry.pendingKind = .note
        entry.pendingRevision = revision
        entry.pendingDeletedAt = nil
      } else if entry.pendingKind == .note {
        entry.pendingKind = nil
        entry.pendingRevision = nil
      }
      entry.currentRevision = revision
      updated.entries[key] = entry
      if entry.pendingKind == .note, let pendingRevision = entry.pendingRevision {
        pendingNotesByID[key] = note
        changes.append(
          .upsert(note: note, revision: pendingRevision, systemFields: entry.systemFields))
      }
    }

    for (key, var entry) in updated.entries where !currentKeys.contains(key) {
      if entry.baselineKind == .note, let revision = entry.baselineRevision {
        if entry.pendingKind != .tombstone {
          let deletedAt = now
          entry.pendingKind = .tombstone
          entry.pendingDeletedAt = deletedAt
          guard let id = UUID(uuidString: key) else {
            throw KnowledgeLibraryError.databaseIntegrity("同步墓碑包含无效笔记标识。")
          }
          entry.pendingRevision = Self.tombstoneRevision(id: id, deletedAt: deletedAt)
        } else if entry.pendingRevision == nil {
          entry.pendingRevision = revision
        }
        updated.entries[key] = entry
      } else if entry.baselineKind == nil {
        // A local note created and deleted before reaching CloudKit has no
        // remote identity to tombstone.
        if entry.pendingKind != .tombstone { updated.entries.removeValue(forKey: key) }
      }
    }

    for (key, entry) in updated.entries.sorted(by: { $0.key < $1.key }) {
      guard let pendingKind = entry.pendingKind, let revision = entry.pendingRevision,
        let id = UUID(uuidString: key)
      else { continue }
      switch pendingKind {
      case .note:
        // Live-note upserts were emitted during the one-at-a-time scan above.
        guard pendingNotesByID[key] != nil else { continue }
      case .tombstone:
        changes.append(
          .tombstone(
            id: id,
            deletedAt: entry.pendingDeletedAt ?? now,
            revision: revision,
            systemFields: entry.systemFields
          ))
      }
    }
    try persist(updated)
    state = updated
    return changes
  }

  public func applyRemote(_ change: RPNoteCloudRemoteChange) async throws -> RPNoteCloudApplyResult
  {
    await beginMutation()
    defer { endMutation() }
    try loadIfNeeded()
    switch change {
    case .note(let note, let sha256, let systemFields):
      guard try Self.revision(for: note) == sha256 else {
        throw KnowledgeLibraryError.databaseIntegrity("iCloud 笔记内容摘要不匹配。")
      }
      try await service.validateNotesForImportAsync([Self.knowledgeNote(note)])
      var updated = state ?? SidecarState()
      let key = Self.key(note.id)
      var entry = updated.entries[key] ?? Entry()
      let local = try await localNoteForSync(documentID: note.id)
      let localNote = local.map(Self.portableNote)
      let localRevision = try localNote.map(Self.revision)

      if entry.pendingKind == .tombstone {
        // A remote live record cannot cancel an explicit local deletion. Keep
        // its server change tag as the base for the pending tombstone save.
        // If the local row still exists, localChanges() will reconcile whether
        // the deletion completed or became a restore/update.
        entry.baselineKind = .note
        entry.baselineRevision = sha256
        entry.baselineDeletedAt = nil
        entry.currentRevision = localRevision
        entry.systemFields = systemFields
        updated.entries[key] = entry
        try persist(updated)
        state = updated
        return .ignoredStale
      }

      if localRevision == sha256 {
        entry.baselineKind = .note
        entry.baselineRevision = sha256
        entry.baselineDeletedAt = nil
        entry.pendingKind = nil
        entry.pendingRevision = nil
        entry.pendingDeletedAt = nil
        entry.currentRevision = sha256
        entry.systemFields = systemFields
        updated.entries[key] = entry
        try persist(updated)
        state = updated
        return .applied
      }

      if entry.baselineKind == .note, entry.baselineRevision == sha256 {
        // A delayed duplicate of the already accepted remote value must not
        // erase newer local edits.
        entry.systemFields = systemFields
        updated.entries[key] = entry
        try persist(updated)
        state = updated
        return .ignoredStale
      }

      let hasLocalChanges =
        localNote != nil
        && (entry.pendingKind != nil || entry.baselineKind != .note
          || localRevision != entry.baselineRevision)
      if hasLocalChanges, let localNote {
        try await preserveConflictCopy(localNote, remoteRevision: sha256)
      }
      _ = try await service.importNotesAsync([Self.knowledgeNote(note)], mode: .replaceExisting)
      entry.baselineKind = .note
      entry.baselineRevision = sha256
      entry.baselineDeletedAt = nil
      entry.pendingKind = nil
      entry.pendingRevision = nil
      entry.pendingDeletedAt = nil
      entry.currentRevision = sha256
      entry.systemFields = systemFields
      updated.entries[key] = entry
      try persist(updated)
      state = updated
      await remoteApplyHandler?()
      return hasLocalChanges ? .keptLocalWithConflictCopy : .applied

    case .tombstone(let id, let deletedAt, let systemFields):
      let remoteRevision = Self.tombstoneRevision(id: id, deletedAt: deletedAt)
      var updated = state ?? SidecarState()
      let key = Self.key(id)
      var entry = updated.entries[key] ?? Entry()
      let local = try await localNoteForSync(documentID: id).map(Self.portableNote)
      let localRevision = try local.map(Self.revision)

      if entry.baselineKind == .tombstone, entry.baselineRevision == remoteRevision {
        entry.systemFields = systemFields
        updated.entries[key] = entry
        try persist(updated)
        state = updated
        return .ignoredStale
      }

      let hasLocalChanges =
        local != nil
        && (entry.pendingKind != nil || entry.baselineKind != .note
          || localRevision != entry.baselineRevision)
      if hasLocalChanges, let local {
        try await preserveConflictCopy(local, remoteRevision: remoteRevision)
      }
      if local != nil {
        _ = try await service.deleteDocumentAsync(id: id)
      }
      entry.baselineKind = .tombstone
      entry.baselineRevision = remoteRevision
      entry.baselineDeletedAt = deletedAt
      entry.pendingKind = nil
      entry.pendingRevision = nil
      entry.pendingDeletedAt = nil
      entry.currentRevision = nil
      entry.systemFields = systemFields
      updated.entries[key] = entry
      try persist(updated)
      state = updated
      if local != nil { await remoteApplyHandler?() }
      return hasLocalChanges ? .keptLocalWithConflictCopy : .applied
    }
  }

  public func prepareForSend(_ change: RPNoteCloudLocalChange) {
    switch change {
    case .upsert(let note, let revision, _):
      pendingAcknowledgements[note.id] = PendingAcknowledgement(
        kind: .note, revision: revision)
    case .tombstone(let id, let deletedAt, let revision, _):
      pendingAcknowledgements[id] = PendingAcknowledgement(
        kind: .tombstone, revision: revision, deletedAt: deletedAt)
    }
  }

  public func abandonPreparedSend(id: UUID, revision: String) {
    guard pendingAcknowledgements[id]?.revision == revision else { return }
    pendingAcknowledgements.removeValue(forKey: id)
  }

  public func markSent(id: UUID, revision: String, systemFields: Data) async throws {
    await beginMutation()
    defer { endMutation() }
    try loadIfNeeded()
    guard let acknowledgement = pendingAcknowledgements[id],
      acknowledgement.revision == revision
    else { return }

    var updated = state ?? SidecarState()
    let key = Self.key(id)
    var entry = updated.entries[key] ?? Entry()
    let current = try await localNoteForSync(documentID: id)
    entry.baselineKind = acknowledgement.kind
    entry.baselineRevision = revision
    entry.baselineDeletedAt = acknowledgement.deletedAt
    entry.systemFields = systemFields

    if let current {
      let currentRevision = try Self.revision(for: Self.portableNote(current))
      entry.currentRevision = currentRevision
      let matchesServer = acknowledgement.kind == .note && currentRevision == revision
      entry.pendingKind = matchesServer ? nil : .note
      entry.pendingRevision = matchesServer ? nil : currentRevision
      entry.pendingDeletedAt = nil
    } else if acknowledgement.kind == .tombstone {
      entry.pendingKind = nil
      entry.pendingRevision = nil
      entry.pendingDeletedAt = nil
      entry.currentRevision = nil
    } else {
      // The note was deleted while its upsert was in flight. The server now
      // has that upsert, so retain the deletion with the new server change tag.
      let deletedAt = entry.pendingDeletedAt ?? Date()
      entry.pendingKind = .tombstone
      entry.pendingRevision = Self.tombstoneRevision(id: id, deletedAt: deletedAt)
      entry.pendingDeletedAt = deletedAt
      entry.currentRevision = nil
    }
    updated.entries[key] = entry
    try persist(updated)
    state = updated
    if pendingAcknowledgements[id]?.revision == revision {
      pendingAcknowledgements.removeValue(forKey: id)
    }
  }

  public func clearSystemFields(id: UUID, revision: String?) async throws {
    await beginMutation()
    defer { endMutation() }
    try loadIfNeeded()
    var updated = state ?? SidecarState()
    let key = Self.key(id)
    guard var entry = updated.entries[key] else { return }
    if let revision,
      entry.pendingRevision != revision && entry.baselineRevision != revision
    {
      return
    }
    entry.systemFields = nil
    updated.entries[key] = entry
    try persist(updated)
    state = updated
  }

  public func prepareZoneRecovery() async throws {
    await beginMutation()
    defer { endMutation() }
    try loadIfNeeded()
    pendingAcknowledgements = [:]
    let noteIDs = try await service.noteDocumentIDsAsync(includeArchived: true)
    var updated = state ?? SidecarState()
    let oldEntries = updated.entries
    updated.engineState = nil
    updated.initialFetchComplete = false
    updated.zoneRecoveryRequired = false
    updated.zoneEstablished = false
    updated.attachmentBaselines = [:]
    for key in updated.entries.keys {
      updated.entries[key]?.baselineKind = nil
      updated.entries[key]?.baselineRevision = nil
      updated.entries[key]?.baselineDeletedAt = nil
      updated.entries[key]?.systemFields = nil
    }
    for id in noteIDs {
      guard let storedNote = try await service.noteAsync(documentID: id) else { continue }
      let note = Self.portableNote(storedNote)
      let key = Self.key(id)
      var entry = updated.entries[key] ?? Entry()
      let revision = (try? Self.revision(for: note)) ?? Self.fallbackRevision(for: note)
      entry.pendingKind = .note
      entry.pendingRevision = revision
      entry.pendingDeletedAt = nil
      entry.currentRevision = revision
      entry.systemFields = nil
      updated.entries[key] = entry
    }
    let liveKeys = Set(noteIDs.map(Self.key))
    for (key, oldEntry) in oldEntries where !liveKeys.contains(key) {
      if oldEntry.pendingKind == .tombstone || oldEntry.baselineKind == .tombstone,
        let id = UUID(uuidString: key)
      {
        let deletedAt = oldEntry.pendingDeletedAt ?? oldEntry.baselineDeletedAt ?? Date()
        updated.entries[key] = Entry(
          pendingKind: .tombstone,
          pendingRevision: Self.tombstoneRevision(id: id, deletedAt: deletedAt),
          pendingDeletedAt: deletedAt
        )
      } else {
        updated.entries.removeValue(forKey: key)
      }
    }
    try persist(updated)
    state = updated
  }

  /// Resets all remote identity when the user explicitly binds this local
  /// library to another iCloud account. Known local deletion intents are
  /// retained, but accepted baselines and all old record change tags are reset.
  public func prepareAccountChange() async throws {
    await beginMutation()
    defer { endMutation() }
    try loadIfNeeded()
    pendingAcknowledgements = [:]
    let noteIDs = try await service.noteDocumentIDsAsync(includeArchived: true)
    var updated = state ?? SidecarState()
    let oldEntries = updated.entries
    updated.engineState = nil
    updated.initialFetchComplete = false
    updated.zoneRecoveryRequired = false
    updated.zoneEstablished = false
    updated.attachmentBaselines = [:]
    updated.entries = [:]
    for id in noteIDs {
      guard let storedNote = try await service.noteAsync(documentID: id) else { continue }
      let note = Self.portableNote(storedNote)
      let revision = (try? Self.revision(for: note)) ?? Self.fallbackRevision(for: note)
      updated.entries[Self.key(id)] = Entry(
        pendingKind: .note,
        pendingRevision: revision,
        currentRevision: revision
      )
    }
    for (key, oldEntry) in oldEntries
    where oldEntry.pendingKind == .tombstone || oldEntry.baselineKind == .tombstone {
      guard let id = UUID(uuidString: key), updated.entries[key] == nil else { continue }
      let deletedAt = oldEntry.pendingDeletedAt ?? oldEntry.baselineDeletedAt ?? Date()
      updated.entries[key] = Entry(
        pendingKind: .tombstone,
        pendingRevision: Self.tombstoneRevision(id: id, deletedAt: deletedAt),
        pendingDeletedAt: deletedAt
      )
    }
    try persist(updated)
    state = updated
  }

  /// Persists deletion intent before a local hard delete or recycle-bin move.
  /// The full note scan in `localChanges()` reconciles an intent if deletion
  /// later fails, closing the save/delete crash window without editing the
  /// library's own backup schema.
  public func prepareLocalDeletion(ids: Set<UUID>) async throws {
    await beginMutation()
    defer { endMutation() }
    try await recordLocalDeletionIntent(ids: ids)
  }

  /// Holds the sync mutation gate until the library has committed deletion.
  /// Remote records and local scans must not observe the prepared-only state.
  public func performLocalDeletion<Result: Sendable>(
    ids: Set<UUID>,
    operation: @Sendable () async throws -> Result
  ) async throws -> Result {
    await beginMutation()
    defer { endMutation() }
    try await recordLocalDeletionIntent(ids: ids)
    return try await operation()
  }

  private func recordLocalDeletionIntent(ids: Set<UUID>) async throws {
    try loadIfNeeded()
    var updated = state ?? SidecarState()
    let deletedAt = Date()
    for id in ids.sorted(by: { Self.key($0) < Self.key($1) }) {
      guard let note = try await service.noteAsync(documentID: id) else { continue }
      let key = Self.key(id)
      var entry = updated.entries[key] ?? Entry()
      let revision = try Self.revision(for: Self.portableNote(note))
      entry.currentRevision = revision
      entry.pendingKind = .tombstone
      entry.pendingDeletedAt = deletedAt
      entry.pendingRevision = Self.tombstoneRevision(id: id, deletedAt: deletedAt)
      updated.entries[key] = entry
    }
    try persist(updated)
    state = updated
  }

  public func stageAsset(_ data: Data) async throws -> URL {
    let directory = stateDirectoryURL.appendingPathComponent("StagedAssets", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).asset")
    try data.write(to: url, options: .atomic)
    return url
  }

  public func finishAsset(_ url: URL) async {
    let stagedRoot =
      stateDirectoryURL.appendingPathComponent("StagedAssets", isDirectory: true)
      .standardizedFileURL.path + "/"
    guard url.standardizedFileURL.path.hasPrefix(stagedRoot) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  public func attachmentData(noteID: UUID, attachmentID: UUID) async throws -> Data? {
    try await service.noteAsync(documentID: noteID)?
      .attachments.first(where: { $0.id == attachmentID })?.data
  }

  private func loadIfNeeded() throws {
    guard state == nil else { return }
    try pruneStaleStagedAssets()
    var loaded = SidecarState()
    var metadata = stat()
    let inspectionResult = stateFileURL.path.withCString { lstat($0, &metadata) }
    if inspectionResult == 0 {
      guard (metadata.st_mode & S_IFMT) == S_IFREG else {
        throw KnowledgeLibraryError.databaseIntegrity(
          "笔记 iCloud 同步状态不是普通文件；为避免丢失待同步操作，已暂停同步。")
      }
      let data: Data
      do {
        data = try Data(contentsOf: stateFileURL)
      } catch {
        throw KnowledgeLibraryError.database("笔记 iCloud 同步状态暂不可读取；已暂停同步，请稍后重试。")
      }
      do {
        loaded = try JSONDecoder().decode(SidecarState.self, from: data)
      } catch {
        throw KnowledgeLibraryError.databaseIntegrity("笔记 iCloud 同步状态文件损坏；为避免丢失待同步操作，已暂停同步。")
      }
    } else if errno != ENOENT {
      throw KnowledgeLibraryError.database("笔记 iCloud 同步状态暂不可检查；已暂停同步，请稍后重试。")
    }
    let restoreID = try KnowledgeNoteCloudRestoreBoundary.restoreID(at: service.rootURL)
    guard loaded.libraryRestoreID == nil || restoreID != nil else {
      throw KnowledgeLibraryError.databaseIntegrity(
        "笔记恢复标识缺失；为避免覆盖云端笔记，已暂停同步。")
    }
    if loaded.libraryRestoreID != restoreID {
      // A restored library is a new local snapshot, not a set of user deletions.
      // Keep account and deleted-zone safeguards, but fetch all cloud records
      // before deriving any new local changes from this snapshot.
      loaded.engineState = nil
      loaded.initialFetchComplete = false
      loaded.attachmentBaselines = [:]
      loaded.entries = [:]
      loaded.libraryRestoreID = restoreID
      try persist(loaded)
      pendingAcknowledgements = [:]
    }
    state = loaded
  }

  private func pruneStaleStagedAssets() throws {
    guard !stagedAssetsPruned else { return }
    let directory = stateDirectoryURL.appendingPathComponent("StagedAssets", isDirectory: true)
    guard FileManager.default.fileExists(atPath: directory.path) else {
      stagedAssetsPruned = true
      return
    }
    let assets = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    for url in assets
    where url.pathExtension == "asset"
      && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    {
      try FileManager.default.removeItem(at: url)
    }
    stagedAssetsPruned = true
  }

  private func beginMutation() async { await mutationGate.acquire() }

  private func endMutation() {
    Task { await mutationGate.release() }
  }

  private func persist(_ updated: SidecarState) throws {
    try FileManager.default.createDirectory(
      at: stateDirectoryURL, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(updated)
    try data.write(to: stateFileURL, options: .atomic)
  }

  /// Match the live-note inventory: a recycle-bin row remains readable for
  /// local recovery, but is absent from cloud synchronization. The note's own
  /// metadata archive flag is separate and must still be synchronized.
  private func localNoteForSync(documentID: UUID) async throws -> KnowledgeNote? {
    let service = self.service
    return try await performKnowledgeLibraryIO {
      guard let document = try service.document(id: documentID), !document.isArchived else {
        return nil
      }
      return try service.note(documentID: documentID)
    }
  }

  private func preserveConflictCopy(_ source: RPNote, remoteRevision: String) async throws {
    let localRevision = try Self.revision(for: source)
    let copyID = Self.deterministicUUID(
      namespace: source.id, name: "\(localRevision):\(remoteRevision)")
    let existing = try await service.noteAsync(documentID: copyID)
    var copy = source
    copy.id = copyID
    copy.attachments = source.attachments.map { attachment in
      var copy = attachment
      copy.id = Self.deterministicUUID(
        namespace: copyID, name: attachment.id.uuidString.lowercased())
      return copy
    }
    if let existing {
      guard try Self.revision(for: Self.portableNote(existing)) == Self.revision(for: copy) else {
        throw KnowledgeLibraryError.databaseIntegrity("iCloud 冲突副本标识已被占用，已停止覆盖。")
      }
      return
    }
    _ = try await service.importNotesAsync([Self.knowledgeNote(copy)], mode: .rejectConflict)
  }

  private static func revision(for note: RPNote) throws -> String {
    SHA256.hash(data: try RPNoteCloudPayload.encode(note)).map { String(format: "%02x", $0) }
      .joined()
  }

  /// Used only when the package encoder rejects a note above its hard limit.
  /// Hash fields and attachment bytes incrementally so one oversized note does
  /// not prevent other notes from entering the sync queue.
  private static func fallbackRevision(for note: RPNote) -> String {
    struct Metadata: Encodable {
      let id: UUID
      let title: String
      let tags: [String]
      let createdAt: Date
      let isArchived: Bool
      let sourceURL: URL?
      let markdown: String
      let attachments: [AttachmentMetadata]
    }
    struct AttachmentMetadata: Encodable {
      let id: UUID
      let fileName: String
      let mimeType: String
      let byteCount: Int
    }
    let metadata = Metadata(
      id: note.id,
      title: note.title,
      tags: note.tags,
      createdAt: note.createdAt,
      isArchived: note.isArchived,
      sourceURL: note.sourceURL,
      markdown: note.markdown,
      attachments: note.attachments.map {
        AttachmentMetadata(
          id: $0.id, fileName: $0.fileName, mimeType: $0.mimeType, byteCount: $0.data.count)
      }
    )
    var hasher = SHA256()
    if let data = try? JSONEncoder().encode(metadata) { hasher.update(data: data) }
    for attachment in note.attachments {
      hasher.update(data: attachment.data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  private static func tombstoneRevision(id: UUID, deletedAt: Date) -> String {
    let value = "tombstone|\(key(id))|\(deletedAt.timeIntervalSince1970.bitPattern)"
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

  private static func deterministicUUID(namespace: UUID, name: String) -> UUID {
    var digest = Array(
      SHA256.hash(data: Data("\(namespace.uuidString.lowercased())|\(name)".utf8)).prefix(16))
    digest[6] = (digest[6] & 0x0f) | 0x50
    digest[8] = (digest[8] & 0x3f) | 0x80
    return UUID(
      uuid: (
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]
      ))
  }

  private static func portableNote(_ note: KnowledgeNote) -> RPNote {
    RPNote(
      id: note.id,
      title: note.title,
      tags: note.tags,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      isArchived: note.isArchived,
      sourceURL: note.sourceURL,
      markdown: note.markdown,
      attachments: note.attachments.map {
        RPNoteAttachment(
          id: $0.id, fileName: $0.fileName, mimeType: $0.mimeType ?? "application/octet-stream",
          data: $0.data)
      }
    )
  }

  private static func knowledgeNote(_ note: RPNote) -> KnowledgeNote {
    KnowledgeNote(
      id: note.id,
      title: note.title,
      tags: note.tags,
      createdAt: note.createdAt,
      updatedAt: note.updatedAt,
      isArchived: note.isArchived,
      sourceURL: note.sourceURL,
      markdown: note.markdown,
      attachments: note.attachments.map {
        KnowledgeNoteAttachment(
          id: $0.id, fileName: $0.fileName, mimeType: $0.mimeType, data: $0.data)
      }
    )
  }
}
