import CloudKit
import Foundation

/// In-memory CloudKit record conversion. No container, sync engine, network or file I/O.
/// Callers own asset staging and must send each UploadGroup atomically by zone.
public enum RPNoteCloudRecordCodec {
  public static let recordType = "RPNoteV2"
  public static let attachmentRecordType = "RPNoteAttachmentV2"
  public static let schemaVersion: Int64 = 2
  public static let maximumAutomaticPayloadBytes = 64 * 1024 * 1024

  public enum Failure: Error, Equatable {
    case invalidRemoteRecord
    case assetDigestMismatch
    case recordIdentityMismatch
    case noteExceedsAutomaticLimit
    case remotePayloadTooLarge
  }

  public enum Incoming {
    case note(id: UUID, envelopeURL: URL, sha256: String, systemFields: Data)
    case tombstone(id: UUID, deletedAt: Date, systemFields: Data)
    case attachment(recordName: String, noteID: String, assetURL: URL, sha256: String, systemFields: Data)
  }

  public struct Save {
    public let record: CKRecord
    /// A caller stages these bytes and assigns CKAsset to assetField before sending.
    public let assetData: Data?
    public let assetField: String?
    /// The local revision used for compare-and-set acknowledgement, not a change tag.
    public let revision: String
  }

  public struct UploadGroup {
    public let saves: [Save]
    public let deletions: [CKRecord.ID]
    public var byteCount: Int { saves.reduce(0) { $0 + ($1.assetData?.count ?? 0) } }
  }

  /// Validates metadata only. The caller copies assets before CloudKit removes its temporary files.
  public static func incoming(_ record: CKRecord, zoneID: CKRecordZone.ID) throws -> Incoming {
    guard record.recordID.zoneID == zoneID,
      (record["schemaVersion"] as? Int64) == schemaVersion
    else { throw Failure.invalidRemoteRecord }
    let name = record.recordID.recordName
    switch record.recordType {
    case recordType:
      guard let id = UUID(uuidString: name), name == key(id) else { throw Failure.invalidRemoteRecord }
      let fields = archiveSystemFields(record)
      if let deletedAt = record["deletedAt"] as? Date {
        return .tombstone(id: id, deletedAt: deletedAt, systemFields: fields)
      }
      guard let url = (record["payload"] as? CKAsset)?.fileURL,
        let sha256 = record["sha256"] as? String
      else { throw Failure.invalidRemoteRecord }
      return .note(id: id, envelopeURL: url, sha256: sha256, systemFields: fields)
    case attachmentRecordType:
      guard let noteKey = record["noteID"] as? String,
        let noteID = UUID(uuidString: noteKey), noteKey == key(noteID)
      else { throw Failure.invalidRemoteRecord }
      let prefix = RPNoteCloudAttachmentPlan.recordNamePrefix + noteKey + "-"
      guard name.hasPrefix(prefix),
        let attachmentID = UUID(uuidString: String(name.dropFirst(prefix.count))),
        name == RPNoteCloudAttachmentPlan.recordName(noteID: noteID, attachmentID: attachmentID),
        let sha256 = record["sha256"] as? String,
        let url = (record["data"] as? CKAsset)?.fileURL
      else { throw Failure.invalidRemoteRecord }
      return .attachment(
        recordName: name, noteID: noteKey, assetURL: url, sha256: sha256,
        systemFields: archiveSystemFields(record)
      )
    default:
      throw Failure.invalidRemoteRecord
    }
  }

  public static func envelope(_ data: Data, noteID: UUID, sha256: String) throws -> RPNoteCloudEnvelope {
    guard data.count <= RPNoteCloudPayload.maximumEnvelopeBytes else { throw Failure.remotePayloadTooLarge }
    guard RPNoteCloudPayload.attachmentDigest(data) == sha256 else { throw Failure.assetDigestMismatch }
    let result = try RPNoteCloudPayload.decode(data)
    guard result.note.id == noteID else { throw Failure.recordIdentityMismatch }
    return result
  }

  /// Builds a complete plan before any asset file is written or any in-flight revision is changed.
  public static func upload(
    _ change: RPNoteCloudLocalChange,
    baselines: [String: RPNoteCloudAttachmentBaseline],
    zoneID: CKRecordZone.ID
  ) throws -> UploadGroup {
    if case let .upsert(note, _, _) = change, estimatedNoteBytes(note) > maximumAutomaticPayloadBytes {
      throw Failure.noteExceedsAutomaticLimit
    }
    let plan = RPNoteCloudAttachmentPlan.plan(for: change, baselines: baselines)
    var saves: [Save] = []
    for upload in plan.uploads {
      let record = try restoredRecord(
        recordID: CKRecord.ID(recordName: upload.recordName, zoneID: zoneID),
        recordType: attachmentRecordType, systemFields: baselines[upload.recordName]?.systemFields
      )
      record["sha256"] = upload.sha256 as CKRecordValue
      record["byteCount"] = Int64(upload.attachment.data.count) as CKRecordValue
      record["noteID"] = key(change.id) as CKRecordValue
      record["schemaVersion"] = schemaVersion as CKRecordValue
      saves.append(Save(record: record, assetData: upload.attachment.data, assetField: "data", revision: upload.sha256))
    }
    let recordID = CKRecord.ID(recordName: key(change.id), zoneID: zoneID)
    switch change {
    case let .upsert(note, revision, fields):
      let record = try restoredRecord(recordID: recordID, recordType: recordType, systemFields: fields)
      let payload = try RPNoteCloudPayload.encode(note)
      record["sha256"] = RPNoteCloudPayload.attachmentDigest(payload) as CKRecordValue
      record["deletedAt"] = nil
      record["schemaVersion"] = schemaVersion as CKRecordValue
      saves.append(Save(record: record, assetData: payload, assetField: "payload", revision: revision))
    case let .tombstone(_, deletedAt, revision, fields):
      let record = try restoredRecord(recordID: recordID, recordType: recordType, systemFields: fields)
      record["payload"] = nil
      record["sha256"] = nil
      record["deletedAt"] = deletedAt as CKRecordValue
      record["schemaVersion"] = schemaVersion as CKRecordValue
      saves.append(Save(record: record, assetData: nil, assetField: nil, revision: revision))
    }
    return UploadGroup(saves: saves, deletions: plan.deletions.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
  }

  public static func archiveSystemFields(_ record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  private static func restoredRecord(recordID: CKRecord.ID, recordType: String, systemFields: Data?) throws -> CKRecord {
    guard let systemFields else { return CKRecord(recordType: recordType, recordID: recordID) }
    let unarchiver = try NSKeyedUnarchiver(forReadingFrom: systemFields)
    unarchiver.requiresSecureCoding = true
    defer { unarchiver.finishDecoding() }
    guard let record = CKRecord(coder: unarchiver), record.recordType == recordType,
      record.recordID == recordID
    else { throw Failure.invalidRemoteRecord }
    return record
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
}
