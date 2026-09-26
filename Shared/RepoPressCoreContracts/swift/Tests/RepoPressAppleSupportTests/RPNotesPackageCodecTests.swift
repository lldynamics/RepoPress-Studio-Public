import CryptoKit
import Foundation
import RepoPressAppleSupport
import XCTest

final class RPNotesPackageCodecTests: XCTestCase {
    private let attachmentPath = "attachments/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    func testRoundTripChineseMarkdownAndAttachment() throws {
        let noteID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let attachmentID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.125)
        let package = RPNotePackage(createdAt: createdAt, notes: [
            RPNote(
                id: noteID, title: "中文笔记", tags: ["想法", "Markdown"],
                createdAt: createdAt, updatedAt: createdAt.addingTimeInterval(2),
                sourceURL: URL(string: "https://example.com/source?q=1")!,
                markdown: "# 标题\n\n内容含 **Markdown**。",
                attachments: [RPNoteAttachment(id: attachmentID, fileName: "截图.png", mimeType: "image/png", data: Data([0, 1, 2, 255]))]
            )
        ])

        let wrapper = try RPNotesPackageCodec.encode(package)
        let decoded = try RPNotesPackageCodec.decode(wrapper)
        XCTAssertEqual(decoded, package)
    }

    func testManifestEncodingIsStableAndUsesDeclaredPaths() throws {
        let package = fixturePackage()
        let first = try RPNotesPackageCodec.encode(package)
        let second = try RPNotesPackageCodec.encode(package)
        XCTAssertEqual(manifestData(first), manifestData(second))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: manifestData(first)) as? [String: Any])
        let note = try XCTUnwrap((object["notes"] as? [[String: Any]])?.first)
        XCTAssertEqual(note["bodyPath"] as? String, "notes/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.md")
        let attachment = try XCTUnwrap((note["attachments"] as? [[String: Any]])?.first)
        XCTAssertEqual(attachment["path"] as? String, attachmentPath)
    }

    func testRoundTripsSubMillisecondDates() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.123_456_7)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_001.987_654_3)
        let package = RPNotePackage(createdAt: createdAt, notes: [
            RPNote(
                id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                createdAt: createdAt,
                updatedAt: updatedAt,
                markdown: "body"
            )
        ])

        let wrapper = try RPNotesPackageCodec.encode(package)
        let manifest = String(data: manifestData(wrapper), encoding: .utf8)!
        XCTAssertTrue(manifest.contains(".123456"))
        let decoded = try RPNotesPackageCodec.decode(wrapper)
        XCTAssertLessThan(abs(decoded.createdAt.timeIntervalSince(createdAt)), 0.000_001)
        XCTAssertLessThan(abs(decoded.notes[0].updatedAt.timeIntervalSince(updatedAt)), 0.000_001)
    }

    func testEncodeRejectsManifestThatExceedsItsActualByteLimit() throws {
        let title = String(repeating: "x", count: 8 * 1024)
        let notes = (0..<1_024).map { _ in RPNote(title: title, markdown: "") }
        let package = RPNotePackage(notes: notes)
        assertError(.limitExceeded("manifest.json exceeds byte limit")) {
            _ = try RPNotesPackageCodec.encode(package)
        }
    }

    func testRejectsTamperedMarkdownBeforeReturningNotes() throws {
        let wrapper = wrapper(manifest: fixtureManifest(body: Data("body".utf8)), body: Data("changed".utf8))
        assertError(.integrityMismatch("notes/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.md")) {
            _ = try RPNotesPackageCodec.decode(wrapper)
        }
    }

    func testRejectsPathTraversal() throws {
        let wrapper = fixtureWrapper(bodyPath: "notes/../../private.md")
        assertError(.invalidPath("notes/../../private.md")) {
            _ = try RPNotesPackageCodec.decode(wrapper)
        }
    }

    func testRejectsDuplicateNoteID() throws {
        var manifest = fixtureManifest()
        manifest["notes"] = [fixtureNote(), fixtureNote()]
        let wrapper = wrapper(manifest: manifest, body: Data("body".utf8))
        assertError(.duplicateID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")) {
            _ = try RPNotesPackageCodec.decode(wrapper)
        }
    }

    func testRejectsUndeclaredFiles() throws {
        let base = fixtureWrapper()
        var root = try XCTUnwrap(base.fileWrappers)
        root["surprise.txt"] = FileWrapper(regularFileWithContents: Data("no".utf8))
        let wrapper = FileWrapper(directoryWithFileWrappers: root)
        assertError(.undeclaredFile("surprise.txt")) {
            _ = try RPNotesPackageCodec.decode(wrapper)
        }
    }

    func testRejectsSymbolicLinkInDeclaredBodyPath() throws {
        let manifest = fixtureManifest()
        let link = FileWrapper(symbolicLinkWithDestinationURL: URL(fileURLWithPath: "/private/tmp/elsewhere.md"))
        let wrapper = FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: manifest)),
            "notes": FileWrapper(directoryWithFileWrappers: ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.md": link]),
            "attachments": FileWrapper(directoryWithFileWrappers: [:])
        ])
        assertError(.invalidStructure("symbolic link at notes/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.md")) {
            _ = try RPNotesPackageCodec.decode(wrapper)
        }
    }

    func testRejectsUndeclaredAttachmentAndWrongSize() throws {
        let body = Data("body".utf8)
        let attachment = Data([1, 2, 3])
        var manifest = fixtureManifest(body: body, attachment: attachment)
        var note = fixtureNote(body: body, attachment: attachment)
        var attachments = try XCTUnwrap(note["attachments"] as? [[String: Any]])
        attachments[0]["byteCount"] = 4
        note["attachments"] = attachments
        manifest["notes"] = [note]
        let wrapper = wrapper(manifest: manifest, body: body, attachment: attachment)
        assertError(.integrityMismatch(attachmentPath)) {
            _ = try RPNotesPackageCodec.decode(wrapper)
        }
    }

    func testRejectsUnsupportedVersionAndNonHTTPSURL() throws {
        var manifest = fixtureManifest()
        manifest["version"] = 2
        assertError(.unsupportedVersion(2)) {
            _ = try RPNotesPackageCodec.decode(wrapper(manifest: manifest, body: Data("body".utf8)))
        }

        var urlManifest = fixtureManifest()
        var note = fixtureNote()
        note["sourceURL"] = "file:///private/tmp/secret"
        urlManifest["notes"] = [note]
        assertError(.invalidMetadata("sourceURL must be HTTP(S)")) {
            _ = try RPNotesPackageCodec.decode(wrapper(manifest: urlManifest, body: Data("body".utf8)))
        }

        let privateURLPackage = RPNotePackage(notes: [
            RPNote(sourceURL: URL(string: "https://user:secret@example.com/private")!, markdown: "body")
        ])
        assertError(.invalidMetadata("sourceURL must be HTTP(S)")) {
            _ = try RPNotesPackageCodec.encode(privateURLPackage)
        }
    }

    private func fixturePackage() -> RPNotePackage {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return RPNotePackage(createdAt: date, notes: [
            RPNote(
                id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, title: "Fixture", tags: ["tag"],
                createdAt: date, updatedAt: date, markdown: "body",
                attachments: [RPNoteAttachment(
                    id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                    fileName: "a.bin",
                    mimeType: "application/octet-stream",
                    data: Data([1, 2, 3])
                )]
            )
        ])
    }

    private func fixtureWrapper(body: Data = Data("body".utf8), bodyPath: String? = nil) -> FileWrapper {
        var manifest = fixtureManifest(body: body)
        if let bodyPath {
            var note = fixtureNote(body: body)
            note["bodyPath"] = bodyPath
            manifest["notes"] = [note]
        }
        return wrapper(manifest: manifest, body: body)
    }

    private func fixtureManifest(body: Data = Data("body".utf8), attachment: Data? = nil) -> [String: Any] {
        [
            "format": "com.repopress.notes", "version": 1,
            "createdAt": "2023-11-14T22:13:20.000Z",
            "notes": [fixtureNote(body: body, attachment: attachment)]
        ]
    }

    private func fixtureNote(body: Data = Data("body".utf8), attachment: Data? = nil) -> [String: Any] {
        var result: [String: Any] = [
            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "title": "Fixture", "tags": ["tag"],
            "createdAt": "2023-11-14T22:13:20.000Z", "updatedAt": "2023-11-14T22:13:21.000Z",
            "isArchived": false, "bodyPath": "notes/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.md",
            "bodySHA256": sha(body), "attachments": []
        ]
        if let attachment {
            result["attachments"] = [[
                "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "fileName": "a.bin", "mimeType": "application/octet-stream",
                "byteCount": attachment.count, "path": attachmentPath, "sha256": sha(attachment)
            ]]
        }
        return result
    }

    private func wrapper(manifest: [String: Any], body: Data, attachment: Data? = nil) -> FileWrapper {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        } catch {
            XCTFail("Fixture manifest is not JSON-serializable: \(error)")
            data = Data()
        }
        var attachments: [String: FileWrapper] = [:]
        if let attachment {
            attachments["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"] = FileWrapper(directoryWithFileWrappers: [
                "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb": FileWrapper(regularFileWithContents: attachment)
            ])
        }
        return FileWrapper(directoryWithFileWrappers: [
            "manifest.json": FileWrapper(regularFileWithContents: data),
            "notes": FileWrapper(directoryWithFileWrappers: [
                "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.md": FileWrapper(regularFileWithContents: body)
            ]),
            "attachments": FileWrapper(directoryWithFileWrappers: attachments)
        ])
    }

    private func manifestData(_ wrapper: FileWrapper) -> Data {
        wrapper.fileWrappers!["manifest.json"]!.regularFileContents!
    }

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func assertError(_ expected: RPNotesPackageError, _ work: () throws -> Void) {
        XCTAssertThrowsError(try work()) { error in
            XCTAssertEqual(error as? RPNotesPackageError, expected)
        }
    }
}
