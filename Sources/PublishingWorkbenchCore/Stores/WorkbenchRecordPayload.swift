import CryptoKit
import Foundation

struct WorkbenchStorageRecord: Equatable, Sendable {
  let collection: String
  let id: String
  let position: Int
  let data: Data
}

/// Records are encoded individually. Article bodies are immutable UTF-8 files;
/// the database transaction publishes their references only after file writes.
struct WorkbenchRecordPayload: Sendable {
  let records: [WorkbenchStorageRecord]
  let documents: [String: Data]

  static let collections = [
    "profiles", "aiConnectionProfiles", "drafts", "customMarkdownSnippets",
    "draftVersions", "recycledDrafts", "draftRepositoryCleanupRequests",
    "releaseRecords", "publishExecutionRecords", "maintenanceOperationRecords",
    "aiMetadataApplicationRecords",
    "automationRunRecords", "aiChatCustomPrompts", "aiConversations",
    "seoSocialPreviewSnapshots", "privacyProtectionEvents", "deploymentStatusSnapshots",
    "deferredProjectFileWrites",
  ]
  private static let bodyReferenceKey = "__repopressBodySHA256"

  init(snapshot: WorkbenchSnapshot) throws {
    try WorkbenchSnapshotSemanticValidator.validate(snapshot)
    var records: [WorkbenchStorageRecord] = []
    var documents: [String: Data] = [:]
    let encoder = JSONEncoder.workbench
    var encodedByteCount = 0

    func accountForEncodedBytes(_ data: Data) throws {
      let (total, overflow) = encodedByteCount.addingReportingOverflow(data.count)
      guard !overflow, total <= WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount else {
        throw WorkbenchRecordStorageError.invalidData("工作台逻辑快照大小超出备份限制。")
      }
      encodedByteCount = total
    }

    func append<T: Encodable>(_ values: [T], collection: String) throws {
      var identifiers = Set<String>()
      for (position, value) in values.enumerated() {
        let encoded = try encoder.encode(value)
        try accountForEncodedBytes(encoded)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let transformed = try Self.externalize(object, documents: &documents)
        let objectID = (object as? [String: Any])?["id"] as? String
        let id = objectID ?? "position:\(position)"
        guard identifiers.insert(id).inserted else {
          throw WorkbenchRecordStorageError.invalidData("重复记录：\(collection)/\(id)")
        }
        records.append(
          WorkbenchStorageRecord(
            collection: collection, id: id, position: position,
            data: try JSONSerialization.data(withJSONObject: transformed, options: [.sortedKeys])
          ))
      }
    }

    try append(snapshot.profiles, collection: "profiles")
    try append(snapshot.aiConnectionProfiles, collection: "aiConnectionProfiles")
    try append(snapshot.drafts, collection: "drafts")
    try append(snapshot.customMarkdownSnippets, collection: "customMarkdownSnippets")
    try append(snapshot.draftVersions, collection: "draftVersions")
    try append(snapshot.recycledDrafts, collection: "recycledDrafts")
    try append(
      snapshot.draftRepositoryCleanupRequests, collection: "draftRepositoryCleanupRequests")
    try append(snapshot.releaseRecords, collection: "releaseRecords")
    try append(snapshot.publishExecutionRecords, collection: "publishExecutionRecords")
    try append(snapshot.maintenanceOperationRecords, collection: "maintenanceOperationRecords")
    try append(snapshot.aiMetadataApplicationRecords, collection: "aiMetadataApplicationRecords")
    try append(snapshot.automationRunRecords, collection: "automationRunRecords")
    try append(snapshot.aiChatCustomPrompts, collection: "aiChatCustomPrompts")
    try append(snapshot.aiConversations, collection: "aiConversations")
    try append(snapshot.seoSocialPreviewSnapshots, collection: "seoSocialPreviewSnapshots")
    try append(snapshot.privacyProtectionEvents, collection: "privacyProtectionEvents")
    try append(snapshot.deploymentStatusSnapshots, collection: "deploymentStatusSnapshots")
    try append(snapshot.deferredProjectFileWrites, collection: "deferredProjectFileWrites")

    var envelope = snapshot
    envelope.profiles = []
    envelope.aiConnectionProfiles = []
    envelope.drafts = []
    envelope.customMarkdownSnippets = []
    envelope.draftVersions = []
    envelope.recycledDrafts = []
    envelope.draftRepositoryCleanupRequests = []
    envelope.releaseRecords = []
    envelope.publishExecutionRecords = []
    envelope.maintenanceOperationRecords = []
    envelope.aiMetadataApplicationRecords = []
    envelope.automationRunRecords = []
    envelope.aiChatCustomPrompts = []
    envelope.aiConversations = []
    envelope.seoSocialPreviewSnapshots = []
    envelope.privacyProtectionEvents = []
    envelope.deploymentStatusSnapshots = []
    envelope.deferredProjectFileWrites = []
    let envelopeData = try encoder.encode(envelope)
    try accountForEncodedBytes(envelopeData)
    records.append(
      WorkbenchStorageRecord(
        collection: "workspace", id: "singleton", position: 0, data: envelopeData))
    self.records = records
    self.documents = documents
  }

  static func snapshot(
    records: [WorkbenchStorageRecord],
    maximumByteCount: Int = WorkbenchFileReadLimits.maximumRecoverySnapshotByteCount,
    readDocument: (String) throws -> Data
  ) throws -> WorkbenchSnapshot {
    var logicalBytes = 0
    func accountForBytes(_ count: Int) throws {
      let (total, overflow) = logicalBytes.addingReportingOverflow(count)
      guard !overflow, total <= maximumByteCount else {
        throw WorkbenchRecordStorageError.invalidData("工作台逻辑快照大小超出恢复限制。")
      }
      logicalBytes = total
    }
    for row in records { try accountForBytes(row.data.count) }
    var documentCache: [String: Data] = [:]
    func readCachedDocument(_ digest: String) throws -> Data {
      let data: Data
      if let cached = documentCache[digest] {
        data = cached
      } else {
        data = try readDocument(digest)
        documentCache[digest] = data
      }
      // Count every logical reference, not just unique files. Repeated large
      // history entries must not expand a tiny database into unbounded memory.
      try accountForBytes(data.count)
      return data
    }
    let envelopes = records.filter { $0.collection == "workspace" && $0.id == "singleton" }
    guard envelopes.count == 1,
      var object = try JSONSerialization.jsonObject(with: envelopes[0].data) as? [String: Any]
    else { throw WorkbenchRecordStorageError.invalidData("工作台记录不完整。") }
    if let version = object["formatVersion"] as? Int,
      version > WorkbenchSnapshot.currentFormatVersion
    {
      throw WorkbenchRecordStorageError.unsupportedVersion("工作台版本较新，请使用更新版本的应用打开。")
    }
    guard
      records.allSatisfy({ $0.collection == "workspace" || collections.contains($0.collection) })
    else {
      throw WorkbenchRecordStorageError.invalidData("工作台包含未知记录集合。")
    }
    for collection in collections {
      let rows = records.filter { $0.collection == collection }.sorted { $0.position < $1.position }
      guard rows.enumerated().allSatisfy({ $0.offset == $0.element.position }) else {
        throw WorkbenchRecordStorageError.invalidData("记录顺序损坏：\(collection)")
      }
      object[collection] = try rows.map {
        try materialize(
          JSONSerialization.jsonObject(with: $0.data), readDocument: readCachedDocument)
      }
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let snapshot = try JSONDecoder.workbench.decode(WorkbenchSnapshot.self, from: data)
    try WorkbenchSnapshotSemanticValidator.validate(snapshot)
    return snapshot
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func isValidDigest(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  static func documentDigests(in records: [WorkbenchStorageRecord]) throws -> Set<String> {
    var result = Set<String>()
    func collect(_ value: Any) throws {
      if let object = value as? [String: Any] {
        if let reference = object[bodyReferenceKey] {
          guard let digest = reference as? String, isValidDigest(digest) else {
            throw WorkbenchRecordStorageError.invalidData("文章正文引用无效。")
          }
          result.insert(digest)
        }
        for value in object.values { try collect(value) }
      } else if let array = value as? [Any] {
        for value in array { try collect(value) }
      }
    }
    for record in records { try collect(JSONSerialization.jsonObject(with: record.data)) }
    return result
  }

  private static func externalize(_ value: Any, documents: inout [String: Data]) throws -> Any {
    if var object = value as? [String: Any] {
      guard object[bodyReferenceKey] == nil else {
        throw WorkbenchRecordStorageError.invalidData("文章字段与存储保留字段冲突。")
      }
      if let body = object["bodyMarkdown"] as? String {
        object.removeValue(forKey: "bodyMarkdown")
        let data = Data(body.utf8)
        let digest = digest(data)
        documents[digest] = data
        object[bodyReferenceKey] = digest
      }
      for key in object.keys where key != bodyReferenceKey {
        object[key] = try externalize(object[key]!, documents: &documents)
      }
      return object
    }
    if let array = value as? [Any] {
      return try array.map { try externalize($0, documents: &documents) }
    }
    return value
  }

  private static func materialize(_ value: Any, readDocument: (String) throws -> Data) throws -> Any
  {
    if var object = value as? [String: Any] {
      if let reference = object.removeValue(forKey: bodyReferenceKey) {
        guard let digest = reference as? String, isValidDigest(digest),
          object["bodyMarkdown"] == nil
        else {
          throw WorkbenchRecordStorageError.invalidData("文章正文引用无效。")
        }
        let data = try readDocument(digest)
        guard self.digest(data) == digest, let body = String(data: data, encoding: .utf8) else {
          throw WorkbenchRecordStorageError.invalidData("文章正文校验失败：\(digest)")
        }
        object["bodyMarkdown"] = body
      }
      for key in object.keys where key != "bodyMarkdown" {
        object[key] = try materialize(object[key]!, readDocument: readDocument)
      }
      return object
    }
    if let array = value as? [Any] {
      return try array.map { try materialize($0, readDocument: readDocument) }
    }
    return value
  }
}

enum WorkbenchRecordStorageError: LocalizedError {
  case invalidData(String)
  case database(String)
  case unsupportedVersion(String)

  var errorDescription: String? {
    switch self {
    case .invalidData(let message), .database(let message), .unsupportedVersion(let message):
      return message
    }
  }
}
