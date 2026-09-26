import CloudKit
import Foundation
import RepoPressAppleSupport
import XCTest

final class RPNoteCloudRecordCodecTests: XCTestCase {
  private let zone = CKRecordZone.ID(zoneName: "Notes", ownerName: CKCurrentUserDefaultName)
  private let noteID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  private let attachmentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

  private func note(_ attachments: [RPNoteAttachment] = []) -> RPNote {
    RPNote(
      id: noteID, title: "A note", tags: ["test"],
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
      markdown: "# Body", attachments: attachments)
  }

  private func attachment(_ data: Data = Data("bytes".utf8), id: UUID? = nil) -> RPNoteAttachment {
    RPNoteAttachment(
      id: id ?? attachmentID, fileName: "file.txt", mimeType: "text/plain", data: data)
  }

  private func asset(_ name: String) -> CKAsset {
    CKAsset(fileURL: URL(fileURLWithPath: "/private/tmp/fake-\(name)"))
  }

  private func expectCodecFailure<T>(
    _ expression: @autoclosure () throws -> T,
    _ expected: RPNoteCloudRecordCodec.Failure,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      _ = try expression()
      XCTFail("expected \(expected) \(message)", file: file, line: line)
    } catch let error as RPNoteCloudRecordCodec.Failure {
      XCTAssertEqual(error, expected, message, file: file, line: line)
    } catch {
      XCTFail("expected \(expected), got \(error) \(message)", file: file, line: line)
    }
  }

  func testCompleteUploadIncomingEnvelopeAndAssembleRoundTrip() throws {
    let item = attachment(Data([0, 1, 2, 255]))
    let change = RPNoteCloudLocalChange.upsert(
      note: note([item]), revision: "local-r7", systemFields: nil)
    let group = try RPNoteCloudRecordCodec.upload(change, baselines: [:], zoneID: zone)
    XCTAssertEqual(group.saves.count, 2)
    XCTAssertEqual(group.deletions, [])
    let noteSave = try XCTUnwrap(
      group.saves.first { $0.record.recordType == RPNoteCloudRecordCodec.recordType })
    let attachmentSave = try XCTUnwrap(
      group.saves.first { $0.record.recordType == RPNoteCloudRecordCodec.attachmentRecordType })
    XCTAssertEqual(noteSave.revision, "local-r7")
    XCTAssertEqual(noteSave.assetField, "payload")
    XCTAssertEqual(attachmentSave.assetField, "data")
    XCTAssertEqual(group.byteCount, noteSave.assetData!.count + item.data.count)
    XCTAssertEqual(
      noteSave.record["sha256"] as? String, RPNoteCloudPayload.attachmentDigest(noteSave.assetData!)
    )
    XCTAssertEqual(
      attachmentSave.record["sha256"] as? String, RPNoteCloudPayload.attachmentDigest(item.data))
    XCTAssertEqual(attachmentSave.record["byteCount"] as? Int64, Int64(item.data.count))
    XCTAssertEqual(attachmentSave.record["noteID"] as? String, noteID.uuidString.lowercased())
    XCTAssertEqual(
      attachmentSave.record["schemaVersion"] as? Int64, RPNoteCloudRecordCodec.schemaVersion)
    XCTAssertFalse(RPNoteCloudRecordCodec.archiveSystemFields(noteSave.record).isEmpty)
    XCTAssertFalse(RPNoteCloudRecordCodec.archiveSystemFields(attachmentSave.record).isEmpty)
    let payload = try XCTUnwrap(noteSave.assetData)
    let incomingRecord = noteSave.record
    incomingRecord["payload"] = asset("payload")
    let incoming = try RPNoteCloudRecordCodec.incoming(incomingRecord, zoneID: zone)
    guard case .note(let id, _, let digest, _) = incoming else { return XCTFail("expected note") }
    XCTAssertEqual(id, noteID)
    XCTAssertEqual(digest, RPNoteCloudPayload.attachmentDigest(payload))
    let incomingAttachmentRecord = attachmentSave.record
    incomingAttachmentRecord["data"] = asset("attachment")
    guard
      case .attachment(let recordName, let noteKey, _, let attachmentDigest, let attachmentFields) =
        try RPNoteCloudRecordCodec.incoming(incomingAttachmentRecord, zoneID: zone)
    else { return XCTFail("expected attachment") }
    XCTAssertEqual(recordName, attachmentSave.record.recordID.recordName)
    XCTAssertEqual(noteKey, noteID.uuidString.lowercased())
    XCTAssertEqual(attachmentDigest, RPNoteCloudPayload.attachmentDigest(item.data))
    XCTAssertFalse(attachmentFields.isEmpty)
    let envelope = try RPNoteCloudRecordCodec.envelope(payload, noteID: noteID, sha256: digest)
    let rebuilt = try RPNoteCloudPayload.assemble(envelope) { descriptor in
      XCTAssertEqual(descriptor.id, item.id)
      return item.data
    }
    XCTAssertEqual(rebuilt, note([item]))
  }

  func testUploadSkipsUnchangedAttachmentAndUploadsModifiedOne() throws {
    let old = attachment(Data("same".utf8))
    let changed = attachment(Data("changed".utf8))
    let name = RPNoteCloudAttachmentPlan.recordName(noteID: noteID, attachmentID: attachmentID)
    let remoteAttachment = CKRecord(
      recordType: RPNoteCloudRecordCodec.attachmentRecordType,
      recordID: CKRecord.ID(recordName: name, zoneID: zone))
    let remoteFields = RPNoteCloudRecordCodec.archiveSystemFields(remoteAttachment)
    let baseline = RPNoteCloudAttachmentBaseline(
      noteID: noteID.uuidString.lowercased(),
      sha256: RPNoteCloudPayload.attachmentDigest(old.data), systemFields: remoteFields)
    let unchanged = try RPNoteCloudRecordCodec.upload(
      .upsert(note: note([old]), revision: "r1", systemFields: nil), baselines: [name: baseline],
      zoneID: zone)
    XCTAssertEqual(unchanged.saves.count, 1)
    let modified = try RPNoteCloudRecordCodec.upload(
      .upsert(note: note([changed]), revision: "r2", systemFields: nil),
      baselines: [name: baseline], zoneID: zone)
    XCTAssertEqual(modified.saves.count, 2)
    let changedSave = try XCTUnwrap(modified.saves.first { $0.assetField == "data" })
    XCTAssertEqual(changedSave.assetData, changed.data)
    XCTAssertEqual(changedSave.record.recordID.recordName, name)
    XCTAssertFalse(RPNoteCloudRecordCodec.archiveSystemFields(changedSave.record).isEmpty)
    changedSave.record["data"] = asset("changed")
    guard case .attachment = try RPNoteCloudRecordCodec.incoming(changedSave.record, zoneID: zone)
    else {
      return XCTFail("expected changed attachment")
    }
    let wrongType = CKRecord(
      recordType: RPNoteCloudRecordCodec.recordType,
      recordID: CKRecord.ID(recordName: name, zoneID: zone))
    let wrongZone = CKRecord(
      recordType: RPNoteCloudRecordCodec.attachmentRecordType,
      recordID: CKRecord.ID(
        recordName: name,
        zoneID: CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)))
    expectCodecFailure(
      try RPNoteCloudRecordCodec.upload(
        .upsert(note: note([changed]), revision: "r3", systemFields: nil),
        baselines: [
          name: RPNoteCloudAttachmentBaseline(
            noteID: noteID.uuidString.lowercased(), sha256: baseline.sha256,
            systemFields: RPNoteCloudRecordCodec.archiveSystemFields(wrongType))
        ], zoneID: zone), .invalidRemoteRecord)
    expectCodecFailure(
      try RPNoteCloudRecordCodec.upload(
        .upsert(note: note([changed]), revision: "r4", systemFields: nil),
        baselines: [
          name: RPNoteCloudAttachmentBaseline(
            noteID: noteID.uuidString.lowercased(), sha256: baseline.sha256,
            systemFields: RPNoteCloudRecordCodec.archiveSystemFields(wrongZone))
        ], zoneID: zone), .invalidRemoteRecord)
  }

  func testUploadDeletesRemovedAttachmentsAndKeepsOtherNoteBaselineIsolated() throws {
    let removedName = RPNoteCloudAttachmentPlan.recordName(
      noteID: noteID, attachmentID: attachmentID)
    let otherID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    let otherName = RPNoteCloudAttachmentPlan.recordName(
      noteID: otherID, attachmentID: attachmentID)
    let baselines = [
      removedName: RPNoteCloudAttachmentBaseline(
        noteID: noteID.uuidString.lowercased(), sha256: "a", systemFields: nil),
      otherName: RPNoteCloudAttachmentBaseline(
        noteID: otherID.uuidString.lowercased(), sha256: "b", systemFields: nil),
    ]
    let group = try RPNoteCloudRecordCodec.upload(
      .upsert(note: note(), revision: "r", systemFields: nil), baselines: baselines, zoneID: zone)
    XCTAssertEqual(group.deletions.map(\.recordName), [removedName])
  }

  func testTombstoneHasNoPayloadAndDeletesAllOwnAttachments() throws {
    let one = RPNoteCloudAttachmentPlan.recordName(noteID: noteID, attachmentID: attachmentID)
    let secondID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    let two = RPNoteCloudAttachmentPlan.recordName(noteID: noteID, attachmentID: secondID)
    let baselines = [
      one: RPNoteCloudAttachmentBaseline(
        noteID: noteID.uuidString.lowercased(), sha256: "a", systemFields: nil),
      two: RPNoteCloudAttachmentBaseline(
        noteID: noteID.uuidString.lowercased(), sha256: "b", systemFields: nil),
    ]
    let date = Date(timeIntervalSince1970: 1_700_000_010)
    let group = try RPNoteCloudRecordCodec.upload(
      .tombstone(id: noteID, deletedAt: date, revision: "delete-r", systemFields: nil),
      baselines: baselines, zoneID: zone)
    let save = try XCTUnwrap(group.saves.first)
    XCTAssertNil(save.assetData)
    XCTAssertNil(save.assetField)
    XCTAssertEqual(save.revision, "delete-r")
    XCTAssertNil(save.record["payload"] as? CKAsset)
    XCTAssertNil(save.record["sha256"] as? String)
    XCTAssertEqual(save.record["deletedAt"] as? Date, date)
    XCTAssertEqual(save.record["schemaVersion"] as? Int64, RPNoteCloudRecordCodec.schemaVersion)
    XCTAssertEqual(group.deletions.map(\.recordName), [one, two])
    guard
      case .tombstone(let id, let deletedAt, _) = try RPNoteCloudRecordCodec.incoming(
        save.record, zoneID: zone)
    else { return XCTFail("Expected a tombstone record") }
    XCTAssertEqual(id, noteID)
    XCTAssertEqual(deletedAt, date)
  }

  func testRevisionIsPreservedForCompareAndSet() throws {
    let group = try RPNoteCloudRecordCodec.upload(
      .upsert(note: note(), revision: "caller-revision", systemFields: nil), baselines: [:],
      zoneID: zone)
    XCTAssertEqual(group.saves.last?.revision, "caller-revision")
  }

  func testIncomingRejectsWrongZoneTypeSchemaNameAndMissingFields() throws {
    let record = CKRecord(
      recordType: RPNoteCloudRecordCodec.recordType,
      recordID: CKRecord.ID(recordName: noteID.uuidString.lowercased(), zoneID: zone))
    record["schemaVersion"] = RPNoteCloudRecordCodec.schemaVersion as CKRecordValue
    record["payload"] = asset("p")
    record["sha256"] = "x" as CKRecordValue
    expectCodecFailure(
      try RPNoteCloudRecordCodec.incoming(
        record, zoneID: CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)),
      .invalidRemoteRecord)
    let wrongType = CKRecord(recordType: "Other", recordID: record.recordID)
    wrongType["schemaVersion"] = RPNoteCloudRecordCodec.schemaVersion as CKRecordValue
    expectCodecFailure(
      try RPNoteCloudRecordCodec.incoming(wrongType, zoneID: zone), .invalidRemoteRecord)
    record["schemaVersion"] = Int64(1) as CKRecordValue
    expectCodecFailure(
      try RPNoteCloudRecordCodec.incoming(record, zoneID: zone), .invalidRemoteRecord)
    record["schemaVersion"] = RPNoteCloudRecordCodec.schemaVersion as CKRecordValue
    record["payload"] = nil
    expectCodecFailure(
      try RPNoteCloudRecordCodec.incoming(record, zoneID: zone), .invalidRemoteRecord)
    let badName = CKRecord(
      recordType: RPNoteCloudRecordCodec.recordType,
      recordID: CKRecord.ID(recordName: "not-a-uuid", zoneID: zone))
    badName["schemaVersion"] = RPNoteCloudRecordCodec.schemaVersion as CKRecordValue
    expectCodecFailure(
      try RPNoteCloudRecordCodec.incoming(badName, zoneID: zone), .invalidRemoteRecord)
    let caseSensitiveID = UUID(uuidString: "abcdefab-cdef-abcd-efab-cdefabcdefab")!
    let uppercase = CKRecord(
      recordType: RPNoteCloudRecordCodec.recordType,
      recordID: CKRecord.ID(recordName: caseSensitiveID.uuidString.uppercased(), zoneID: zone))
    uppercase["schemaVersion"] = RPNoteCloudRecordCodec.schemaVersion as CKRecordValue
    uppercase["payload"] = asset("uppercase")
    uppercase["sha256"] = "x" as CKRecordValue
    expectCodecFailure(
      try RPNoteCloudRecordCodec.incoming(uppercase, zoneID: zone), .invalidRemoteRecord)
  }

  func testIncomingRejectsMalformedAttachmentNamesAndFields() throws {
    let validNoteKey = noteID.uuidString.lowercased()
    let valid = RPNoteCloudAttachmentPlan.recordName(noteID: noteID, attachmentID: attachmentID)
    let wrongSuffix = CKRecord(
      recordType: RPNoteCloudRecordCodec.attachmentRecordType,
      recordID: CKRecord.ID(recordName: "att-\(validNoteKey)-not-uuid", zoneID: zone))
    wrongSuffix["schemaVersion"] = RPNoteCloudRecordCodec.schemaVersion as CKRecordValue
    wrongSuffix["noteID"] = validNoteKey as CKRecordValue
    wrongSuffix["data"] = asset("d")
    wrongSuffix["sha256"] = "x" as CKRecordValue
    expectCodecFailure(
      try RPNoteCloudRecordCodec.incoming(wrongSuffix, zoneID: zone), .invalidRemoteRecord)
    let missing = CKRecord(
      recordType: RPNoteCloudRecordCodec.attachmentRecordType,
      recordID: CKRecord.ID(recordName: valid, zoneID: zone))
    missing["schemaVersion"] = RPNoteCloudRecordCodec.schemaVersion as CKRecordValue
    missing["noteID"] = validNoteKey as CKRecordValue
    missing["data"] = asset("d")
    expectCodecFailure(
      try RPNoteCloudRecordCodec.incoming(missing, zoneID: zone), .invalidRemoteRecord)
  }

  func testEnvelopeRejectsBadHashMismatchedIDAndOversize() throws {
    let data = try RPNoteCloudPayload.encode(note())
    expectCodecFailure(
      try RPNoteCloudRecordCodec.envelope(
        data, noteID: noteID, sha256: String(repeating: "0", count: 64)), .assetDigestMismatch)
    let other = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    expectCodecFailure(
      try RPNoteCloudRecordCodec.envelope(
        data, noteID: other, sha256: RPNoteCloudPayload.attachmentDigest(data)),
      .recordIdentityMismatch)
    expectCodecFailure(
      try RPNoteCloudRecordCodec.envelope(
        Data(repeating: 0, count: RPNoteCloudPayload.maximumEnvelopeBytes + 1), noteID: noteID,
        sha256: "x"), .remotePayloadTooLarge)
  }

  func testSystemFieldsRestoreValidRecordAndRejectWrongIdentityTypeAndZone() throws {
    let source = CKRecord(
      recordType: RPNoteCloudRecordCodec.recordType,
      recordID: CKRecord.ID(recordName: noteID.uuidString.lowercased(), zoneID: zone))
    let fields = RPNoteCloudRecordCodec.archiveSystemFields(source)
    let group = try RPNoteCloudRecordCodec.upload(
      .upsert(note: note(), revision: "r", systemFields: fields), baselines: [:], zoneID: zone)
    XCTAssertEqual(group.saves.last?.record.recordID, source.recordID)
    let wrongID = CKRecord(
      recordType: RPNoteCloudRecordCodec.recordType,
      recordID: CKRecord.ID(recordName: "55555555-5555-5555-5555-555555555555", zoneID: zone))
    expectCodecFailure(
      try RPNoteCloudRecordCodec.upload(
        .upsert(
          note: note(), revision: "r",
          systemFields: RPNoteCloudRecordCodec.archiveSystemFields(wrongID)), baselines: [:],
        zoneID: zone), .invalidRemoteRecord)
    let wrongType = CKRecord(
      recordType: RPNoteCloudRecordCodec.attachmentRecordType, recordID: source.recordID)
    expectCodecFailure(
      try RPNoteCloudRecordCodec.upload(
        .upsert(
          note: note(), revision: "r",
          systemFields: RPNoteCloudRecordCodec.archiveSystemFields(wrongType)), baselines: [:],
        zoneID: zone), .invalidRemoteRecord)
    let wrongZone = CKRecord(
      recordType: RPNoteCloudRecordCodec.recordType,
      recordID: CKRecord.ID(
        recordName: noteID.uuidString.lowercased(),
        zoneID: CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)))
    expectCodecFailure(
      try RPNoteCloudRecordCodec.upload(
        .upsert(
          note: note(), revision: "r",
          systemFields: RPNoteCloudRecordCodec.archiveSystemFields(wrongZone)), baselines: [:],
        zoneID: zone), .invalidRemoteRecord)
  }

  func testUploadEnforces64MiBAutomaticSendLimit() throws {
    let huge = RPNote(
      id: noteID, title: "huge", createdAt: Date(), updatedAt: Date(),
      markdown: String(repeating: "x", count: RPNoteCloudRecordCodec.maximumAutomaticPayloadBytes),
      attachments: [])
    expectCodecFailure(
      try RPNoteCloudRecordCodec.upload(
        .upsert(note: huge, revision: "r", systemFields: nil), baselines: [:], zoneID: zone),
      .noteExceedsAutomaticLimit)
  }
}
