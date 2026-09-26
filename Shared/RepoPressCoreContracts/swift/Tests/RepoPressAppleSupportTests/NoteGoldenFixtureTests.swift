import Foundation
@testable import RepoPressAppleSupport
import XCTest

final class NoteGoldenFixtureTests: XCTestCase {
  // These bytes were generated once from the identical pre-migration iOS and macOS
  // implementations and checked in as a contract; they are not device-sync evidence.
  private struct Fixture: Codable {
    let name: String
    let packageCreatedAt: String
    let note: NoteValue
    let packageFiles: [String: String]
    let packageDirectories: [String]
    let cloudPayload: String
  }
  private struct NoteValue: Codable {
    let id: String; let title: String; let tags: [String]
    let createdAt: String; let updatedAt: String; let isArchived: Bool
    let sourceURL: String?; let markdown: String; let attachments: [AttachmentValue]
  }
  private struct AttachmentValue: Codable { let id: String; let fileName: String; let mimeType: String; let data: String }

  func testFrozenPackageAndCloudBytesRoundTrip() throws {
    for fixture in try loadFixtures() {
      let note = try makeNote(fixture.note)
      let package = try makePackage(fixture, note: note)
      let packageWrapper = try RPNotesPackageCodec.encode(package)
      XCTAssertEqual(flatten(packageWrapper), try decodedFiles(fixture), fixture.name)
      XCTAssertEqual(Set(directoryPaths(packageWrapper)), Set(fixture.packageDirectories), fixture.name)
      let frozenPackage = makeWrapper(try decodedFiles(fixture), directories: fixture.packageDirectories)
      let decodedPackage = try RPNotesPackageCodec.decode(frozenPackage)
      XCTAssertEqual(normalizedPackage(decodedPackage), normalizedPackage(package), fixture.name)

      let cloudBytes = try Data(base64Encoded: fixture.cloudPayload).unwrap("cloud payload")
      XCTAssertEqual(try RPNoteCloudPayload.encode(note), cloudBytes, fixture.name)
      let envelope = try RPNoteCloudPayload.decode(cloudBytes)
      let rebuilt = try RPNoteCloudPayload.assemble(envelope) { descriptor in
        guard let attachment = note.attachments.first(where: { $0.id == descriptor.id }) else { throw FixtureError.missingAttachment }
        return attachment.data
      }
      XCTAssertEqual(normalized(rebuilt), normalized(note), fixture.name)
    }
  }

  func testChangingOneGoldenBodyByteFailsChecksumValidation() throws {
    let fixture = try XCTUnwrap(try loadFixtures().first(where: { $0.name == "unicode-and-archive" }))
    var files = try decodedFiles(fixture)
    let bodyPath = try XCTUnwrap(files.keys.first(where: { $0.hasSuffix(".md") }))
    var body = files[bodyPath]!
    body[body.startIndex] ^= 0x01
    files[bodyPath] = body
    XCTAssertThrowsError(try RPNotesPackageCodec.decode(makeWrapper(files, directories: fixture.packageDirectories))) { error in
      guard case RPNotesPackageError.integrityMismatch(bodyPath) = error else {
        return XCTFail("expected checksum failure for \(bodyPath), got \(error)")
      }
    }
  }

  private enum FixtureError: Error { case missingAttachment, invalidDate, invalidData }

  private func loadFixtures() throws -> [Fixture] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "note-golden", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url))
  }

  private func makeNote(_ value: NoteValue) throws -> RPNote {
    RPNote(id: try XCTUnwrap(UUID(uuidString: value.id)), title: value.title, tags: value.tags,
           createdAt: try parseDate(value.createdAt), updatedAt: try parseDate(value.updatedAt),
           isArchived: value.isArchived, sourceURL: value.sourceURL.flatMap(URL.init(string:)),
           markdown: value.markdown, attachments: try value.attachments.map {
      RPNoteAttachment(id: try XCTUnwrap(UUID(uuidString: $0.id)), fileName: $0.fileName, mimeType: $0.mimeType,
                       data: try XCTUnwrap(Data(base64Encoded: $0.data)))
    })
  }

  private func makePackage(_ fixture: Fixture, note: RPNote) throws -> RPNotePackage {
    RPNotePackage(createdAt: try parseDate(fixture.packageCreatedAt), notes: [note])
  }

  private func parseDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = formatter.date(from: value) else { throw FixtureError.invalidDate }
    return date
  }

  private func decodedFiles(_ fixture: Fixture) throws -> [String: Data] {
    try fixture.packageFiles.mapValues { value in
      guard let data = Data(base64Encoded: value) else { throw FixtureError.invalidData }
      return data
    }
  }

  private func makeWrapper(_ files: [String: Data], directories: [String]) -> FileWrapper {
    func directory(_ prefix: String) -> FileWrapper {
      let names = Set((files.keys + directories).compactMap { path -> String? in
        let remainder: String
        if prefix.isEmpty {
          remainder = path
        } else if path.hasPrefix(prefix + "/") {
          remainder = String(path.dropFirst(prefix.count + 1))
        } else { return nil }
        return remainder.split(separator: "/").first.map(String.init)
      })
      var wrappers: [String: FileWrapper] = [:]
      for name in names {
        let path = prefix.isEmpty ? name : prefix + "/" + name
        if let data = files[path] {
          wrappers[name] = FileWrapper(regularFileWithContents: data)
        } else { wrappers[name] = directory(path) }
      }
      return FileWrapper(directoryWithFileWrappers: wrappers)
    }
    return directory("")
  }

  private func flatten(_ wrapper: FileWrapper, _ prefix: String = "") -> [String: Data] {
    guard wrapper.isDirectory, let children = wrapper.fileWrappers else { return [prefix: wrapper.regularFileContents ?? Data()] }
    return children.reduce(into: [:]) { result, item in
      let path = prefix.isEmpty ? item.key : "\(prefix)/\(item.key)"
      result.merge(flatten(item.value, path)) { $1 }
    }
  }

  private func directoryPaths(_ wrapper: FileWrapper, _ prefix: String = "") -> [String] {
    guard wrapper.isDirectory, let children = wrapper.fileWrappers else { return [] }
    return [prefix] + children.keys.sorted().flatMap {
      directoryPaths(children[$0]!, prefix.isEmpty ? $0 : "\(prefix)/\($0)")
    }
  }

  private func normalized(_ note: RPNote) -> RPNote {
    var result = note
    result.attachments.sort { $0.id.uuidString < $1.id.uuidString }
    return result
  }

  private func normalizedPackage(_ package: RPNotePackage) -> RPNotePackage {
    RPNotePackage(createdAt: package.createdAt, notes: package.notes.map(normalized))
  }
}

private extension Optional {
  func unwrap(_ message: String) throws -> Wrapped {
    guard let value = self else { throw NSError(domain: "NoteGoldenFixtureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    return value
  }
}
