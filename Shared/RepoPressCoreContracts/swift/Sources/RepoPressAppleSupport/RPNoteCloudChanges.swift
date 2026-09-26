import Foundation

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
