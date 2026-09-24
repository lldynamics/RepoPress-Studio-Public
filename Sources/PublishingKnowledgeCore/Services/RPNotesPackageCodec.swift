import CryptoKit
import Foundation

/// A portable, user-authored collection of Markdown notes.
public struct RPNotePackage: Sendable, Equatable {
    public var createdAt: Date
    public var notes: [RPNote]

    public init(createdAt: Date = Date(), notes: [RPNote]) {
        self.createdAt = createdAt
        self.notes = notes
    }
}

/// A note as it is exchanged between RepoPress clients. It deliberately has no
/// database, publishing, backup, or AI-related fields.
public struct RPNote: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var isArchived: Bool
    public var sourceURL: URL?
    public var markdown: String
    public var attachments: [RPNoteAttachment]

    public init(
        id: UUID = UUID(),
        title: String = "",
        tags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isArchived: Bool = false,
        sourceURL: URL? = nil,
        markdown: String,
        attachments: [RPNoteAttachment] = []
    ) {
        self.id = id
        self.title = title
        self.tags = tags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.sourceURL = sourceURL
        self.markdown = markdown
        self.attachments = attachments
    }
}

/// Binary content carried by a note. `fileName` is display metadata; it never
/// participates in a package path.
public struct RPNoteAttachment: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var fileName: String
    public var mimeType: String
    public var data: Data

    public init(id: UUID = UUID(), fileName: String, mimeType: String, data: Data) {
        self.id = id
        self.fileName = fileName
        self.mimeType = mimeType
        self.data = data
    }
}

public enum RPNotesPackageError: Error, Equatable, Sendable {
    case invalidStructure(String)
    case invalidManifest(String)
    case unsupportedVersion(Int)
    case invalidMetadata(String)
    case invalidPath(String)
    case duplicateID(String)
    case duplicatePath(String)
    case undeclaredFile(String)
    case integrityMismatch(String)
    case limitExceeded(String)
}

/// Codec for the v1 `.rpnotes` document-package interchange format.
///
/// `decode` validates the full wrapper tree and every byte before constructing
/// the return value, so callers can safely persist only its successful result.
public enum RPNotesPackageCodec {
    public static let format = "com.repopress.notes"
    public static let version = 1

    public static func encode(_ package: RPNotePackage) throws -> FileWrapper {
        try validate(package: package)

        var manifestNotes: [ManifestNote] = []
        var markdownFiles: [String: FileWrapper] = [:]
        var attachmentDirectories: [String: FileWrapper] = [:]

        for note in package.notes.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let bodyData = Data(note.markdown.utf8)
            let bodyPath = "notes/\(note.id.uuidString.lowercased()).md"
            markdownFiles["\(note.id.uuidString.lowercased()).md"] = regularFile(bodyData)

            var manifestAttachments: [ManifestAttachment] = []
            var attachmentFiles: [String: FileWrapper] = [:]
            for attachment in note.attachments.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                let path = "attachments/\(note.id.uuidString.lowercased())/\(attachment.id.uuidString.lowercased())"
                attachmentFiles[attachment.id.uuidString.lowercased()] = regularFile(attachment.data)
                manifestAttachments.append(
                    ManifestAttachment(
                        id: attachment.id.uuidString.lowercased(),
                        fileName: attachment.fileName,
                        mimeType: attachment.mimeType,
                        byteCount: attachment.data.count,
                        path: path,
                        sha256: digest(attachment.data)
                    )
                )
            }
            if !attachmentFiles.isEmpty {
                attachmentDirectories[note.id.uuidString.lowercased()] = FileWrapper(directoryWithFileWrappers: attachmentFiles)
            }

            manifestNotes.append(
                ManifestNote(
                    id: note.id.uuidString.lowercased(),
                    title: note.title,
                    tags: note.tags,
                    createdAt: dateString(note.createdAt),
                    updatedAt: dateString(note.updatedAt),
                    isArchived: note.isArchived,
                    sourceURL: note.sourceURL?.absoluteString,
                    bodyPath: bodyPath,
                    bodySHA256: digest(bodyData),
                    attachments: manifestAttachments
                )
            )
        }

        let manifest = Manifest(
            format: format,
            version: version,
            createdAt: dateString(package.createdAt),
            notes: manifestNotes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let manifestData: Data
        do {
            manifestData = try encoder.encode(manifest)
        } catch {
            throw RPNotesPackageError.invalidManifest(error.localizedDescription)
        }
        try checkSize(manifestData.count, limit: Limits.maxManifestBytes, subject: "manifest.json")
        try checkEncodedPackageSize(package, manifestBytes: manifestData.count)

        return FileWrapper(directoryWithFileWrappers: [
            "manifest.json": regularFile(manifestData),
            "notes": FileWrapper(directoryWithFileWrappers: markdownFiles),
            "attachments": FileWrapper(directoryWithFileWrappers: attachmentDirectories)
        ])
    }

    public static func decode(_ wrapper: FileWrapper) throws -> RPNotePackage {
        try requireDirectory(wrapper, path: "")
        let root = try children(of: wrapper, path: "")
        try requireExactChildren(root, expected: ["manifest.json", "notes", "attachments"], path: "")

        let manifestFile = try requiredChild(root, "manifest.json", at: "manifest.json")
        try requireRegularFile(manifestFile, path: "manifest.json")
        guard let manifestData = manifestFile.regularFileContents else {
            throw RPNotesPackageError.invalidStructure("manifest.json has no contents")
        }
        try checkSize(manifestData.count, limit: Limits.maxManifestBytes, subject: "manifest.json")

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw RPNotesPackageError.invalidManifest(error.localizedDescription)
        }
        guard manifest.format == format else {
            throw RPNotesPackageError.invalidManifest("unexpected format")
        }
        guard manifest.version == version else { throw RPNotesPackageError.unsupportedVersion(manifest.version) }
        let packageCreatedAt = try parseDate(manifest.createdAt, field: "createdAt")
        try checkCount(manifest.notes.count, limit: Limits.maxNotes, subject: "notes")

        let notesDirectory = try requiredChild(root, "notes", at: "notes")
        let attachmentsDirectory = try requiredChild(root, "attachments", at: "attachments")
        try requireDirectory(notesDirectory, path: "notes")
        try requireDirectory(attachmentsDirectory, path: "attachments")
        let noteFiles = try children(of: notesDirectory, path: "notes")
        let attachmentNoteDirectories = try children(of: attachmentsDirectory, path: "attachments")

        var noteIDs = Set<String>()
        var attachmentIDs = Set<String>()
        var declaredPaths = Set<String>()
        var expectedNoteFiles = Set<String>()
        var expectedAttachmentDirectories = Set<String>()
        var notes: [RPNote] = []
        var totalBytes = manifestData.count
        var totalAttachments = 0

        for entry in manifest.notes {
            let noteID = try canonicalUUID(entry.id, field: "note id")
            guard noteIDs.insert(noteID).inserted else { throw RPNotesPackageError.duplicateID(noteID) }
            try validateText(entry.title, limit: Limits.maxTitleBytes, field: "title")
            try checkCount(entry.tags.count, limit: Limits.maxTagsPerNote, subject: "tags")
            for tag in entry.tags { try validateText(tag, limit: Limits.maxTagBytes, field: "tag") }
            let createdAt = try parseDate(entry.createdAt, field: "note createdAt")
            let updatedAt = try parseDate(entry.updatedAt, field: "note updatedAt")
            let sourceURL = try validatedURL(entry.sourceURL)

            let expectedBodyPath = "notes/\(noteID).md"
            guard entry.bodyPath == expectedBodyPath else { throw RPNotesPackageError.invalidPath(entry.bodyPath) }
            try insertPath(entry.bodyPath, into: &declaredPaths)
            expectedNoteFiles.insert("\(noteID).md")
            let bodyFile = try requiredChild(noteFiles, "\(noteID).md", at: entry.bodyPath)
            try requireRegularFile(bodyFile, path: entry.bodyPath)
            guard let bodyData = bodyFile.regularFileContents else {
                throw RPNotesPackageError.invalidStructure("missing body contents at \(entry.bodyPath)")
            }
            try checkSize(bodyData.count, limit: Limits.maxMarkdownBytes, subject: entry.bodyPath)
            totalBytes += bodyData.count
            try checkSize(totalBytes, limit: Limits.maxPackageBytes, subject: "package")
            guard digest(bodyData) == entry.bodySHA256.lowercased() else {
                throw RPNotesPackageError.integrityMismatch(entry.bodyPath)
            }
            guard let markdown = String(data: bodyData, encoding: .utf8) else {
                throw RPNotesPackageError.invalidMetadata("Markdown is not UTF-8: \(entry.bodyPath)")
            }

            var attachments: [RPNoteAttachment] = []
            var expectedAttachments = Set<String>()
            if !entry.attachments.isEmpty {
                expectedAttachmentDirectories.insert(noteID)
                let noteAttachmentDirectory = try requiredChild(attachmentNoteDirectories, noteID, at: "attachments/\(noteID)")
                try requireDirectory(noteAttachmentDirectory, path: "attachments/\(noteID)")
                let attachmentFiles = try children(of: noteAttachmentDirectory, path: "attachments/\(noteID)")
                try checkCount(entry.attachments.count, limit: Limits.maxAttachmentsPerNote, subject: "attachments")

                for attachment in entry.attachments {
                    totalAttachments += 1
                    try checkCount(totalAttachments, limit: Limits.maxAttachments, subject: "attachments")
                    let attachmentID = try canonicalUUID(attachment.id, field: "attachment id")
                    guard attachmentIDs.insert(attachmentID).inserted else { throw RPNotesPackageError.duplicateID(attachmentID) }
                    try validateText(attachment.fileName, limit: Limits.maxFileNameBytes, field: "attachment fileName", allowEmpty: false)
                    try validateText(attachment.mimeType, limit: Limits.maxMIMETypeBytes, field: "attachment mimeType", allowEmpty: false)
                    let expectedPath = "attachments/\(noteID)/\(attachmentID)"
                    guard attachment.path == expectedPath else { throw RPNotesPackageError.invalidPath(attachment.path) }
                    try insertPath(attachment.path, into: &declaredPaths)
                    expectedAttachments.insert(attachmentID)
                    let file = try requiredChild(attachmentFiles, attachmentID, at: attachment.path)
                    try requireRegularFile(file, path: attachment.path)
                    guard let data = file.regularFileContents else {
                        throw RPNotesPackageError.invalidStructure("missing attachment contents at \(attachment.path)")
                    }
                    guard attachment.byteCount >= 0 else { throw RPNotesPackageError.invalidMetadata("negative attachment size") }
                    guard data.count == attachment.byteCount else { throw RPNotesPackageError.integrityMismatch(attachment.path) }
                    try checkSize(data.count, limit: Limits.maxAttachmentBytes, subject: attachment.path)
                    totalBytes += data.count
                    try checkSize(totalBytes, limit: Limits.maxPackageBytes, subject: "package")
                    guard digest(data) == attachment.sha256.lowercased() else {
                        throw RPNotesPackageError.integrityMismatch(attachment.path)
                    }
                    attachments.append(RPNoteAttachment(id: UUID(uuidString: attachmentID)!, fileName: attachment.fileName, mimeType: attachment.mimeType, data: data))
                }
                try requireExactChildren(attachmentFiles, expected: expectedAttachments, path: "attachments/\(noteID)")
            }

            notes.append(RPNote(
                id: UUID(uuidString: noteID)!, title: entry.title, tags: entry.tags,
                createdAt: createdAt, updatedAt: updatedAt, isArchived: entry.isArchived,
                sourceURL: sourceURL, markdown: markdown, attachments: attachments
            ))
        }
        try requireExactChildren(noteFiles, expected: expectedNoteFiles, path: "notes")
        try requireExactChildren(attachmentNoteDirectories, expected: expectedAttachmentDirectories, path: "attachments")
        return RPNotePackage(createdAt: packageCreatedAt, notes: notes)
    }
}

private enum Limits {
    static let maxManifestBytes = 8 * 1024 * 1024
    static let maxNotes = 10_000
    static let maxTitleBytes = 8 * 1024
    static let maxTagsPerNote = 100
    static let maxTagBytes = 1024
    static let maxMarkdownBytes = 8 * 1024 * 1024
    static let maxAttachmentsPerNote = 100
    static let maxAttachments = 10_000
    static let maxAttachmentBytes = 128 * 1024 * 1024
    static let maxPackageBytes = 512 * 1024 * 1024
    static let maxFileNameBytes = 4 * 1024
    static let maxMIMETypeBytes = 1024
}

private struct Manifest: Codable {
    let format: String
    let version: Int
    let createdAt: String
    let notes: [ManifestNote]
}

private struct ManifestNote: Codable {
    let id: String
    let title: String
    let tags: [String]
    let createdAt: String
    let updatedAt: String
    let isArchived: Bool
    let sourceURL: String?
    let bodyPath: String
    let bodySHA256: String
    let attachments: [ManifestAttachment]
}

private struct ManifestAttachment: Codable {
    let id: String
    let fileName: String
    let mimeType: String
    let byteCount: Int
    let path: String
    let sha256: String
}

private extension RPNotesPackageCodec {
    static func validate(package: RPNotePackage) throws {
        try checkCount(package.notes.count, limit: Limits.maxNotes, subject: "notes")
        var noteIDs = Set<UUID>()
        var attachmentIDs = Set<UUID>()
        var totalAttachments = 0
        var totalBytes = 0
        for note in package.notes {
            guard noteIDs.insert(note.id).inserted else { throw RPNotesPackageError.duplicateID(note.id.uuidString) }
            try validateText(note.title, limit: Limits.maxTitleBytes, field: "title")
            try checkCount(note.tags.count, limit: Limits.maxTagsPerNote, subject: "tags")
            for tag in note.tags { try validateText(tag, limit: Limits.maxTagBytes, field: "tag") }
            _ = try validatedURL(note.sourceURL?.absoluteString)
            let bodyBytes = Data(note.markdown.utf8).count
            try checkSize(bodyBytes, limit: Limits.maxMarkdownBytes, subject: "note body")
            totalBytes += bodyBytes
            try checkSize(totalBytes, limit: Limits.maxPackageBytes, subject: "package")
            try checkCount(note.attachments.count, limit: Limits.maxAttachmentsPerNote, subject: "attachments")
            for attachment in note.attachments {
                guard attachmentIDs.insert(attachment.id).inserted else { throw RPNotesPackageError.duplicateID(attachment.id.uuidString) }
                totalAttachments += 1
                try checkCount(totalAttachments, limit: Limits.maxAttachments, subject: "attachments")
                try validateText(attachment.fileName, limit: Limits.maxFileNameBytes, field: "attachment fileName", allowEmpty: false)
                try validateText(attachment.mimeType, limit: Limits.maxMIMETypeBytes, field: "attachment mimeType", allowEmpty: false)
                try checkSize(attachment.data.count, limit: Limits.maxAttachmentBytes, subject: "attachment")
                totalBytes += attachment.data.count
                try checkSize(totalBytes, limit: Limits.maxPackageBytes, subject: "package")
            }
        }
    }

    static func regularFile(_ data: Data) -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func dateString(_ date: Date) -> String {
        var wholeSeconds = floor(date.timeIntervalSince1970)
        var nanoseconds = Int(((date.timeIntervalSince1970 - wholeSeconds) * 1_000_000_000).rounded())
        if nanoseconds == 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return "\(formatter.string(from: Date(timeIntervalSince1970: wholeSeconds))).\(String(format: "%09d", nanoseconds))Z"
    }

    static func parseDate(_ string: String, field: String) throws -> Date {
        if let preciseDate = parsePreciseUTCDate(string) { return preciseDate }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        throw RPNotesPackageError.invalidMetadata("invalid ISO-8601 date for \(field)")
    }

    static func validatedURL(_ raw: String?) throws -> URL? {
        guard let raw else { return nil }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil, url.user == nil, url.password == nil else {
            throw RPNotesPackageError.invalidMetadata("sourceURL must be HTTP(S)")
        }
        return url
    }

    static func canonicalUUID(_ value: String, field: String) throws -> String {
        guard let uuid = UUID(uuidString: value) else { throw RPNotesPackageError.invalidMetadata("invalid \(field)") }
        return uuid.uuidString.lowercased()
    }

    static func validateText(_ text: String, limit: Int, field: String, allowEmpty: Bool = true) throws {
        guard allowEmpty || !text.isEmpty else { throw RPNotesPackageError.invalidMetadata("\(field) is empty") }
        try checkSize(Data(text.utf8).count, limit: limit, subject: field)
    }

    static func checkCount(_ value: Int, limit: Int, subject: String) throws {
        guard value <= limit else { throw RPNotesPackageError.limitExceeded("too many \(subject)") }
    }

    static func checkSize(_ value: Int, limit: Int, subject: String) throws {
        guard value <= limit else { throw RPNotesPackageError.limitExceeded("\(subject) exceeds byte limit") }
    }

    static func checkEncodedPackageSize(_ package: RPNotePackage, manifestBytes: Int) throws {
        var totalBytes = manifestBytes
        for note in package.notes {
            try addToEncodedPackageSize(Data(note.markdown.utf8).count, total: &totalBytes)
            for attachment in note.attachments {
                try addToEncodedPackageSize(attachment.data.count, total: &totalBytes)
            }
        }
    }

    static func addToEncodedPackageSize(_ byteCount: Int, total: inout Int) throws {
        let (next, overflow) = total.addingReportingOverflow(byteCount)
        guard !overflow else { throw RPNotesPackageError.limitExceeded("package exceeds byte limit") }
        total = next
        try checkSize(total, limit: Limits.maxPackageBytes, subject: "package")
    }

    static func parsePreciseUTCDate(_ value: String) -> Date? {
        let parts = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].hasSuffix("Z") else { return nil }
        let fraction = parts[1].dropLast()
        guard (1...9).contains(fraction.count), fraction.allSatisfy(\.isNumber) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        guard let seconds = formatter.date(from: "\(parts[0])Z") else { return nil }
        let paddedFraction = String(fraction) + String(repeating: "0", count: 9 - fraction.count)
        guard let nanoseconds = Double(paddedFraction) else { return nil }
        return Date(timeInterval: nanoseconds / 1_000_000_000, since: seconds)
    }

    static func requireDirectory(_ wrapper: FileWrapper, path: String) throws {
        if wrapper.isSymbolicLink { throw RPNotesPackageError.invalidStructure("symbolic link at \(path)") }
        guard wrapper.isDirectory else { throw RPNotesPackageError.invalidStructure("expected directory at \(path)") }
    }

    static func requireRegularFile(_ wrapper: FileWrapper, path: String) throws {
        if wrapper.isSymbolicLink { throw RPNotesPackageError.invalidStructure("symbolic link at \(path)") }
        guard wrapper.isRegularFile else { throw RPNotesPackageError.invalidStructure("expected regular file at \(path)") }
    }

    static func children(of wrapper: FileWrapper, path: String) throws -> [String: FileWrapper] {
        try requireDirectory(wrapper, path: path)
        guard let children = wrapper.fileWrappers else { throw RPNotesPackageError.invalidStructure("unreadable directory at \(path)") }
        return children
    }

    static func requiredChild(_ children: [String: FileWrapper], _ name: String, at path: String) throws -> FileWrapper {
        guard let child = children[name] else { throw RPNotesPackageError.invalidStructure("missing \(path)") }
        return child
    }

    static func requireExactChildren(_ children: [String: FileWrapper], expected: Set<String>, path: String) throws {
        let actual = Set(children.keys)
        if let extra = actual.subtracting(expected).sorted().first { throw RPNotesPackageError.undeclaredFile(pathJoin(path, extra)) }
        if let missing = expected.subtracting(actual).sorted().first { throw RPNotesPackageError.invalidStructure("missing \(pathJoin(path, missing))") }
    }

    static func insertPath(_ path: String, into paths: inout Set<String>) throws {
        guard paths.insert(path).inserted else { throw RPNotesPackageError.duplicatePath(path) }
    }

    static func pathJoin(_ directory: String, _ name: String) -> String {
        directory.isEmpty ? name : "\(directory)/\(name)"
    }
}
