import CryptoKit
import Foundation

/// Metadata for one attachment inside a note envelope. The bytes travel in their own
/// CloudKit record so that editing note text never re-uploads unchanged attachments.
public struct RPNoteCloudAttachmentDescriptor: Sendable, Equatable {
  public var id: UUID
  public var fileName: String
  public var mimeType: String
  public var byteCount: Int
  public var sha256: String

  public init(id: UUID, fileName: String, mimeType: String, byteCount: Int, sha256: String) {
    self.id = id
    self.fileName = fileName
    self.mimeType = mimeType
    self.byteCount = byteCount
    self.sha256 = sha256
  }
}

/// A decoded note envelope: every note field except attachment bytes.
public struct RPNoteCloudEnvelope: Sendable, Equatable {
  /// The note with an empty `attachments` array; use `RPNoteCloudPayload.assemble` to add bytes.
  public var note: RPNote
  public var attachments: [RPNoteCloudAttachmentDescriptor]
}

/// A bounded, binary representation of one note's envelope for a CloudKit CKAsset.
///
/// The envelope contains the metadata, the Markdown body, and each attachment's size and
/// SHA-256, but not the attachment bytes. `SHA256(encode(note))` is therefore a revision
/// that covers the whole note, and can be computed on any client that holds the full note.
public enum RPNoteCloudPayload {
  public static let format = "com.repopress.note-cloud-payload"
  public static let version: UInt16 = 2
  /// Upper bound for the complete note (Markdown plus attachment bytes).
  public static let maximumNoteBytes = 512 * 1024 * 1024
  public static let maximumAttachmentBytes = 128 * 1024 * 1024
  /// Upper bound for one encoded envelope (header, manifest, and Markdown).
  public static let maximumEnvelopeBytes = 16 * 1024 * 1024

  private static let magic = Data([0x52, 0x50, 0x4e, 0x43]) // RPNC
  private static let headerSize = 10
  private static let maximumManifestBytes = 256 * 1024
  private static let maximumMarkdownBytes = 8 * 1024 * 1024
  private static let maximumAttachments = 100

  private struct Manifest: Codable {
    let format: String
    let version: Int
    let id: String
    let title: String
    let tags: [String]
    let createdAt: String
    let updatedAt: String
    let isArchived: Bool
    let sourceURL: String?
    let markdownBytes: Int
    let markdownSHA256: String
    let attachments: [Attachment]
  }

  private struct Attachment: Codable {
    let id: String
    let fileName: String
    let mimeType: String
    let byteCount: Int
    let sha256: String
  }

  public enum PayloadError: Error, Equatable {
    case malformedHeader
    case unsupportedVersion(UInt16)
    case invalidManifest
    case invalidMetadata(String)
    case integrityMismatch(String)
    case limitExceeded(String)
  }

  /// Encodes the envelope of exactly one note. Equal note values produce equal bytes on
  /// every platform, independent of attachment order.
  public static func encode(_ note: RPNote) throws -> Data {
    try validate(note)
    let markdown = Data(note.markdown.utf8)
    let descriptors = note.attachments
      .sorted { uuidKey($0.id) < uuidKey($1.id) }
      .map { item in
        RPNoteCloudAttachmentDescriptor(
          id: item.id,
          fileName: item.fileName,
          mimeType: item.mimeType,
          byteCount: item.data.count,
          sha256: attachmentDigest(item.data)
        )
      }
    let manifest = Manifest(
      format: format,
      version: Int(version),
      id: uuidKey(note.id),
      title: note.title,
      tags: note.tags,
      createdAt: dateString(note.createdAt),
      updatedAt: dateString(note.updatedAt),
      isArchived: note.isArchived,
      sourceURL: note.sourceURL?.absoluteString,
      markdownBytes: markdown.count,
      markdownSHA256: digest(markdown),
      attachments: descriptors.map {
        Attachment(
          id: uuidKey($0.id), fileName: $0.fileName, mimeType: $0.mimeType,
          byteCount: $0.byteCount, sha256: $0.sha256
        )
      }
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let manifestBytes = try encoder.encode(manifest)
    guard manifestBytes.count <= maximumManifestBytes else { throw PayloadError.limitExceeded("manifest") }

    var output = Data()
    output.reserveCapacity(headerSize + manifestBytes.count + markdown.count)
    output.append(magic)
    append(UInt16(version), to: &output)
    append(UInt32(manifestBytes.count), to: &output)
    output.append(manifestBytes)
    output.append(markdown)
    return output
  }

  /// Validates the envelope and the Markdown digest. Attachment bytes are verified by `assemble`.
  public static func decode(_ input: Data) throws -> RPNoteCloudEnvelope {
    // Offsets below are absolute; rebase a slice so they start at zero.
    let data = input.startIndex == 0 ? input : Data(input)
    let manifest = try decodeManifest(data)
    let noteID = try parseUUID(manifest.id, field: "note id")
    let createdAt = try parseDate(manifest.createdAt, field: "createdAt")
    let updatedAt = try parseDate(manifest.updatedAt, field: "updatedAt")
    let url = try validatedURL(manifest.sourceURL)
    try validateText(manifest.title, max: 8 * 1024, field: "title")
    guard manifest.tags.count <= 100 else { throw PayloadError.limitExceeded("tags") }
    for tag in manifest.tags { try validateText(tag, max: 1024, field: "tag") }

    let markdownStart = headerSize + Int(readUInt32(data, at: 6))
    guard manifest.markdownBytes >= 0, manifest.markdownBytes <= maximumMarkdownBytes,
      markdownStart + manifest.markdownBytes == data.count
    else { throw PayloadError.invalidManifest }
    let markdownData = data[markdownStart...]
    guard digest(markdownData) == manifest.markdownSHA256 else { throw PayloadError.integrityMismatch("markdown") }
    guard let markdown = String(data: markdownData, encoding: .utf8) else {
      throw PayloadError.invalidMetadata("markdown UTF-8")
    }

    let attachments = try decodeAttachments(manifest.attachments)
    let note = RPNote(
      id: noteID, title: manifest.title, tags: manifest.tags, createdAt: createdAt, updatedAt: updatedAt,
      isArchived: manifest.isArchived, sourceURL: url, markdown: markdown, attachments: []
    )
    return RPNoteCloudEnvelope(note: note, attachments: attachments)
  }

  /// Rebuilds the full note, verifying each attachment's size and SHA-256 against the envelope.
  public static func assemble(
    _ envelope: RPNoteCloudEnvelope,
    attachmentData: (RPNoteCloudAttachmentDescriptor) throws -> Data
  ) throws -> RPNote {
    var note = envelope.note
    var total = Data(note.markdown.utf8).count
    for descriptor in envelope.attachments {
      let data = try attachmentData(descriptor)
      guard data.count == descriptor.byteCount, attachmentDigest(data) == descriptor.sha256 else {
        throw PayloadError.integrityMismatch("attachment \(uuidKey(descriptor.id))")
      }
      let (sum, overflow) = total.addingReportingOverflow(data.count)
      guard !overflow, sum <= maximumNoteBytes else { throw PayloadError.limitExceeded("note") }
      total = sum
      note.attachments.append(RPNoteAttachment(
        id: descriptor.id, fileName: descriptor.fileName, mimeType: descriptor.mimeType, data: data
      ))
    }
    return note
  }

  /// Lowercase hexadecimal SHA-256, as stored in envelopes and attachment records.
  public static func attachmentDigest(_ data: Data) -> String {
    digest(data)
  }

  private static func decodeManifest(_ data: Data) throws -> Manifest {
    guard data.count >= headerSize, data.prefix(4) == magic else { throw PayloadError.malformedHeader }
    let headerVersion = readUInt16(data, at: 4)
    guard headerVersion == version else { throw PayloadError.unsupportedVersion(headerVersion) }
    guard data.count <= maximumEnvelopeBytes else { throw PayloadError.limitExceeded("envelope") }
    let manifestLength = Int(readUInt32(data, at: 6))
    guard manifestLength > 0, manifestLength <= maximumManifestBytes,
      manifestLength <= data.count - headerSize
    else { throw PayloadError.invalidManifest }
    let manifestRange = headerSize..<(headerSize + manifestLength)
    let manifest: Manifest
    do {
      manifest = try JSONDecoder().decode(Manifest.self, from: data[manifestRange])
    } catch {
      throw PayloadError.invalidManifest
    }
    guard manifest.format == format, manifest.version == Int(version) else { throw PayloadError.invalidManifest }
    return manifest
  }

  private static func decodeAttachments(_ items: [Attachment]) throws -> [RPNoteCloudAttachmentDescriptor] {
    guard items.count <= maximumAttachments else { throw PayloadError.limitExceeded("attachments") }
    var descriptors: [RPNoteCloudAttachmentDescriptor] = []
    var lastID = ""
    for item in items {
      let attachmentID = try parseUUID(item.id, field: "attachment id")
      // Strictly ascending IDs make the order canonical and rule out duplicates.
      guard item.id > lastID else { throw PayloadError.invalidManifest }
      lastID = item.id
      try validateText(item.fileName, max: 4 * 1024, field: "fileName", allowEmpty: false)
      try validateText(item.mimeType, max: 1024, field: "mimeType", allowEmpty: false)
      guard item.byteCount >= 0, item.byteCount <= maximumAttachmentBytes else {
        throw PayloadError.limitExceeded("attachment")
      }
      guard item.sha256.count == 64, item.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
        throw PayloadError.invalidMetadata("attachment sha256")
      }
      descriptors.append(RPNoteCloudAttachmentDescriptor(
        id: attachmentID, fileName: item.fileName, mimeType: item.mimeType,
        byteCount: item.byteCount, sha256: item.sha256
      ))
    }
    return descriptors
  }

  private static func validate(_ note: RPNote) throws {
    try validateText(note.title, max: 8 * 1024, field: "title")
    guard note.tags.count <= 100 else { throw PayloadError.limitExceeded("tags") }
    for tag in note.tags { try validateText(tag, max: 1024, field: "tag") }
    _ = try validatedURL(note.sourceURL?.absoluteString)
    let markdownBytes = Data(note.markdown.utf8).count
    guard markdownBytes <= maximumMarkdownBytes else { throw PayloadError.limitExceeded("markdown") }
    guard note.attachments.count <= maximumAttachments else { throw PayloadError.limitExceeded("attachments") }
    var ids = Set<UUID>()
    var total = markdownBytes
    for item in note.attachments {
      guard ids.insert(item.id).inserted else { throw PayloadError.invalidMetadata("duplicate attachment id") }
      try validateText(item.fileName, max: 4 * 1024, field: "fileName", allowEmpty: false)
      try validateText(item.mimeType, max: 1024, field: "mimeType", allowEmpty: false)
      guard item.data.count <= maximumAttachmentBytes else { throw PayloadError.limitExceeded("attachment") }
      let (sum, overflow) = total.addingReportingOverflow(item.data.count)
      guard !overflow, sum <= maximumNoteBytes else { throw PayloadError.limitExceeded("note") }
      total = sum
    }
  }

  private static func validateText(_ value: String, max: Int, field: String, allowEmpty: Bool = true) throws {
    guard allowEmpty || !value.isEmpty else { throw PayloadError.invalidMetadata(field) }
    guard value.utf8.count <= max else { throw PayloadError.limitExceeded(field) }
  }

  private static func validatedURL(_ string: String?) throws -> URL? {
    guard let string else { return nil }
    guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
      url.host != nil, url.user == nil, url.password == nil
    else { throw PayloadError.invalidMetadata("sourceURL") }
    return url
  }

  private static func parseUUID(_ value: String, field: String) throws -> UUID {
    guard let uuid = UUID(uuidString: value), uuidKey(uuid) == value else { throw PayloadError.invalidMetadata(field) }
    return uuid
  }

  private static func uuidKey(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

  private static func digest(_ bytes: some DataProtocol) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
  }

  private static func dateString(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970
    var whole = floor(seconds)
    var nanos = Int(((seconds - whole) * 1_000_000_000).rounded())
    if nanos == 1_000_000_000 { whole += 1; nanos = 0 }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return "\(formatter.string(from: Date(timeIntervalSince1970: whole))).\(String(format: "%09d", nanos))Z"
  }

  private static func parseDate(_ string: String, field: String) throws -> Date {
    let parts = string.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    if parts.count == 2, parts[1].hasSuffix("Z") {
      let fraction = parts[1].dropLast()
      if (1...9).contains(fraction.count), fraction.allSatisfy(\.isNumber),
        let whole = iso8601(String(parts[0]) + "Z") {
        let nanos = Double("0." + fraction) ?? 0
        return whole.addingTimeInterval(nanos)
      }
    }
    throw PayloadError.invalidMetadata(field)
  }

  private static func iso8601(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
  }

  private static func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xff)); data.append(UInt8(value & 0xff))
  }

  private static func append(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xff)); data.append(UInt8((value >> 16) & 0xff))
    data.append(UInt8((value >> 8) & 0xff)); data.append(UInt8(value & 0xff))
  }

  private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
    let start = data.startIndex + index
    return (UInt16(data[start]) << 8) | UInt16(data[start + 1])
  }

  private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
    let start = data.startIndex + index
    return (UInt32(data[start]) << 24) | (UInt32(data[start + 1]) << 16)
      | (UInt32(data[start + 2]) << 8) | UInt32(data[start + 3])
  }
}
