import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import RepoPressCore

final class FixtureConformanceTests: XCTestCase {
  func testManifestRegistersAllFixtures() throws {
    let suite = try FixtureSuite.load(filePath: #filePath)
    XCTAssertEqual(suite.manifest.formatVersion, 1)
    XCTAssertEqual(suite.manifest.minimumReaderVersion, 1)
    XCTAssertEqual(suite.manifest.cases.count, 40)
    XCTAssertEqual(Set(suite.manifest.cases.map(\.id)).count, 40)

    let cases = try suite.loadCases()
    XCTAssertEqual(cases.count, 40)
    XCTAssertEqual(cases.filter { $0.validity == "valid" }.count, 33)
    XCTAssertEqual(cases.filter { $0.validity == "invalid" }.count, 7)
    XCTAssertEqual(cases.filter { $0.capability == "repository-endpoint" }.count, 16)
    XCTAssertEqual(cases.filter { $0.capability == "front-matter-document" }.count, 12)
    XCTAssertEqual(cases.filter { $0.capability == "publish-conflict-diff" }.count, 12)

    for entry in suite.manifest.cases {
      let fixture = try XCTUnwrap(
        cases.first(where: { $0.id == entry.id }),
        "fixture \(entry.id): manifest ID is not present in the case"
      )
      XCTAssertEqual(
        entry.path,
        fixture.relativePath,
        "fixture \(entry.id): manifest path does not match case path"
      )
    }
    XCTAssertEqual(
      Set(cases.map { $0.relativePath }),
      Set(suite.manifest.cases.map(\.path)),
      "manifest paths must cover every fixture exactly once"
    )
  }

  func testAllValidFixturesConformToCore() throws {
    let suite = try FixtureSuite.load(filePath: #filePath)
    for fixture in try suite.loadCases().filter({ $0.validity == "valid" }) {
      do {
        switch fixture.capability {
        case "repository-endpoint":
          try verifyEndpoint(fixture)
        case "front-matter-document":
          try verifyFrontMatter(fixture)
        case "publish-conflict-diff":
          try verifyDiff(fixture)
        default:
          XCTFail("fixture \(fixture.id): unknown capability \(fixture.capability)")
        }
      } catch {
        XCTFail("fixture \(fixture.id): \(error)")
      }
    }
  }

  func testInvalidFixturesExposeStableErrorCodes() throws {
    let suite = try FixtureSuite.load(filePath: #filePath)
    for fixture in try suite.loadCases().filter({ $0.validity == "invalid" }) {
      let expectedCode = try fixture.expectedErrorCode()
      switch fixture.id {
      case "front-invalid-null-optional":
        XCTAssertThrowsError(try FixtureAdapter.front(fixture.input), "fixture \(fixture.id)") { error in
          XCTAssertEqual((error as? FixtureAdapterError)?.errorCode, expectedCode, "fixture \(fixture.id)")
        }
      case "endpoint-invalid-input-missing-operation":
        XCTAssertThrowsError(try FixtureAdapter.endpoint(fixture.input), "fixture \(fixture.id)") { error in
          XCTAssertEqual((error as? FixtureAdapterError)?.errorCode, expectedCode, "fixture \(fixture.id)")
        }
      default:
        XCTAssertEqual(expectedCode, RepositoryEndpointError.invalidURL.rawValue, "fixture \(fixture.id)")
        let request = try FixtureAdapter.endpoint(fixture.input)
        XCTAssertThrowsError(try RepositoryEndpoint.validated(baseURL: request.baseURL), "fixture \(fixture.id)") { error in
          guard let endpointError = error as? RepositoryEndpointError else {
            return XCTFail("fixture \(fixture.id): unexpected error \(error)")
          }
          XCTAssertEqual(endpointError.rawValue, expectedCode, "fixture \(fixture.id)")
        }
      }
    }
  }

  func testEndpointAuthenticationHeadersAndEnterprisePath() throws {
    let endpoint = try RepositoryEndpoint.validated(baseURL: "https://github.example.test/api/v3")
    let url = try endpoint.url(
      path: "/repos/owner/repo/contents/docs%2Findex.md",
      queryItems: [URLQueryItem(name: "ref", value: "main")]
    )
    XCTAssertEqual(
      url.absoluteString,
      "https://github.example.test/api/v3/repos/owner/repo/contents/docs%2Findex.md?ref=main"
    )

    var githubRequest = URLRequest(url: URL(string: "https://api.example.test/user")!)
    RepositoryAuthentication.githubBearer("fixture-secret").apply(to: &githubRequest)
    XCTAssertEqual(githubRequest.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-secret")
    XCTAssertEqual(githubRequest.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    XCTAssertEqual(githubRequest.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
    XCTAssertEqual(githubRequest.value(forHTTPHeaderField: "User-Agent"), "RepoPress")

    var gitLabRequest = URLRequest(url: URL(string: "https://gitlab.example.test/api/v4/user")!)
    RepositoryAuthentication.gitLabPrivateToken("fixture-secret").apply(to: &gitLabRequest)
    XCTAssertEqual(gitLabRequest.value(forHTTPHeaderField: "PRIVATE-TOKEN"), "fixture-secret")
    XCTAssertNil(gitLabRequest.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(gitLabRequest.value(forHTTPHeaderField: "Accept"), "application/json")
  }

  func testPublicCodableRoundTrips() throws {
    let document = FrontMatterDocument(
      syntax: .toml,
      title: "Codable 🧪",
      formattedDate: "2026-08-09",
      slug: "codable",
      draftFlag: false,
      summaryField: "summary",
      summary: "Round trip",
      authors: ["author"],
      tags: ["swift"],
      categories: ["contract"],
      taxonomyLayout: .table,
      coverField: "cover",
      coverPath: "images/cover.jpg",
      writesCoverInExtraTable: true,
      bodyMarkdown: "Body"
    )
    let documentData = try JSONEncoder().encode(document)
    let decodedDocument = try JSONDecoder().decode(FrontMatterDocument.self, from: documentData)
    XCTAssertEqual(decodedDocument.syntax.rawValue, document.syntax.rawValue)
    XCTAssertEqual(decodedDocument.title, document.title)
    XCTAssertEqual(decodedDocument.summary, document.summary)
    XCTAssertEqual(decodedDocument.tags, document.tags)
    XCTAssertEqual(decodedDocument.taxonomyLayout.rawValue, document.taxonomyLayout.rawValue)
    XCTAssertEqual(decodedDocument.bodyMarkdown, document.bodyMarkdown)

    for syntax in [FrontMatterDocumentSyntax.yaml, .toml] {
      let data = try JSONEncoder().encode(syntax)
      XCTAssertEqual(try JSONDecoder().decode(FrontMatterDocumentSyntax.self, from: data), syntax)
    }
    for layout in [FrontMatterTaxonomyLayout.inlineTable, .table] {
      let data = try JSONEncoder().encode(layout)
      XCTAssertEqual(try JSONDecoder().decode(FrontMatterTaxonomyLayout.self, from: data), layout)
    }

    let line = PublishConflictDiffLine(id: 3, kind: .remote, text: "old")
    let lineData = try JSONEncoder().encode(line)
    let decodedLine = try JSONDecoder().decode(PublishConflictDiffLine.self, from: lineData)
    XCTAssertEqual(decodedLine.id, line.id)
    XCTAssertEqual(decodedLine.kind, line.kind)
    XCTAssertEqual(decodedLine.text, line.text)
    XCTAssertEqual(decodedLine.marker, "-")
  }

  func testDiffThresholdBoundaryAndFallback() {
    let builder = PublishConflictDiffBuilder()
    let boundaryRemote = Array(repeating: "remote", count: 500).joined(separator: "\n")
    let boundaryLocal = Array(repeating: "local", count: 500).joined(separator: "\n")
    let boundaryLines = builder.diff(remote: boundaryRemote, local: boundaryLocal)
    XCTAssertEqual(boundaryLines.count, 1_000)
    XCTAssertTrue(boundaryLines.allSatisfy { $0.kind == .remote || $0.kind == .local })
    XCTAssertEqual(boundaryLines.first?.kind, .remote)
    XCTAssertEqual(boundaryLines.last?.kind, .local)

    let coarseRemote = Array(repeating: "remote", count: 501).joined(separator: "\n")
    let coarseLocal = Array(repeating: "local", count: 500).joined(separator: "\n")
    let coarseLines = builder.diff(remote: coarseRemote, local: coarseLocal)
    XCTAssertEqual(coarseLines.count, 1_001)
    XCTAssertTrue(coarseLines.prefix(501).allSatisfy { $0.kind == .remote })
    XCTAssertTrue(coarseLines.suffix(500).allSatisfy { $0.kind == .local })
  }
}

private struct FixtureSuite {
  struct Manifest: Decodable {
    let formatVersion: Int
    let minimumReaderVersion: Int
    let cases: [Entry]
  }

  struct Entry: Decodable {
    let id: String
    let path: String
    let sha256: String
  }

  let root: URL
  let manifest: Manifest

  static func load(filePath: String) throws -> FixtureSuite {
    guard let root = findRoot(filePath: filePath) else {
      throw FixtureError.message(
        "Unable to locate repo root from \(filePath); searched ancestors for contracts/fixtures/v1/manifest.json"
      )
    }
    let manifestURL = root.appendingPathComponent("contracts/fixtures/v1/manifest.json")
    let data = try Data(contentsOf: manifestURL)
    return FixtureSuite(root: root, manifest: try JSONDecoder().decode(Manifest.self, from: data))
  }

  func loadCases() throws -> [FixtureCase] {
    try manifest.cases.map { entry in
      let fixtureURL = root.appendingPathComponent("contracts/fixtures/v1").appendingPathComponent(entry.path)
      let data = try Data(contentsOf: fixtureURL)
      var fixture = try JSONDecoder().decode(FixtureCase.self, from: data)
      fixture.relativePath = entry.path
      return fixture
    }
  }

  private static func findRoot(filePath: String) -> URL? {
    var candidate = URL(fileURLWithPath: filePath).deletingLastPathComponent()
    for _ in 0..<10 {
      let manifest = candidate.appendingPathComponent("contracts/fixtures/v1/manifest.json")
      if FileManager.default.fileExists(atPath: manifest.path) {
        return candidate
      }
      let parent = candidate.deletingLastPathComponent()
      if parent.path == candidate.path { break }
      candidate = parent
    }
    return nil
  }
}

private struct FixtureCase: Decodable {
  let id: String
  let capability: String
  let validity: String
  let description: String
  let input: JSONValue
  let expected: JSONValue
  var relativePath = ""

  enum CodingKeys: String, CodingKey {
    case id, capability, validity, description, input, expected
  }

  func expectedErrorCode() throws -> String {
    let object = try expected.object("\(id).expected")
    return try object["errorCode"].unwrapString("\(id).expected.errorCode")
  }
}

private enum JSONValue: Decodable {
  case object([String: JSONValue])
  case array([JSONValue])
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  init(from decoder: Decoder) throws {
    if let container = try? decoder.singleValueContainer(), container.decodeNil() {
      self = .null
    } else if let container = try? decoder.singleValueContainer(), let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let container = try? decoder.singleValueContainer(), let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let container = try? decoder.singleValueContainer(), let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let container = try? decoder.unkeyedContainer() {
      var values = container
      var array: [JSONValue] = []
      while !values.isAtEnd { array.append(try values.decode(JSONValue.self)) }
      self = .array(array)
    } else {
      let container = try decoder.container(keyedBy: DynamicCodingKey.self)
      var object: [String: JSONValue] = [:]
      for key in container.allKeys { object[key.stringValue] = try container.decode(JSONValue.self, forKey: key) }
      self = .object(object)
    }
  }

  func object(_ context: String) throws -> [String: JSONValue] {
    guard case .object(let value) = self else { throw FixtureError.message("expected object \(context)") }
    return value
  }

  func string(_ context: String) throws -> String {
    guard case .string(let value) = self else { throw FixtureError.message("expected string \(context)") }
    return value
  }

  var isNull: Bool {
    if case .null = self { return true }
    return false
  }

  subscript(key: String) -> JSONValue? {
    guard case .object(let value) = self else { return nil }
    return value[key]
  }

  func array(_ key: String) throws -> [JSONValue] {
    guard case .array(let value) = self[key] else { throw FixtureError.message("expected array \(key)") }
    return value
  }
}

private extension Optional where Wrapped == JSONValue {
  func unwrapString(_ context: String) throws -> String {
    guard case .some(.string(let value)) = self else { throw FixtureError.message("expected string \(context)") }
    return value
  }

  func array(_ context: String) throws -> [JSONValue] {
    guard case .some(.array(let value)) = self else { throw FixtureError.message("expected array \(context)") }
    return value
  }
}

private struct DynamicCodingKey: CodingKey {
  let stringValue: String
  init?(stringValue: String) { self.stringValue = stringValue }
  let intValue: Int? = nil
  init?(intValue: Int) { return nil }
}

private enum FixtureError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self { case .message(let text): return text }
  }
}

private enum FixtureAdapterError: Error, CustomStringConvertible {
  case invalidInput(String)

  var errorCode: String {
    "contract.invalid_input"
  }

  var description: String {
    switch self {
    case .invalidInput(let context):
      return "\(errorCode): \(context)"
    }
  }
}

private enum FixtureAdapter {
  struct EndpointRequest {
    let operation: String
    let baseURL: String
    let path: String
    let queryItems: [URLQueryItem]
  }

  struct FrontRequest {
    let operation: String
    let document: FrontMatterDocument
  }

  struct DiffRequest {
    let remote: String
    let local: String
  }

  static func endpoint(_ raw: JSONValue) throws -> EndpointRequest {
    let object = try raw.object("endpoint input")
    let operation = try requiredString(object, "operation")
    guard operation == "validate" || operation == "build-url" else {
      throw FixtureAdapterError.invalidInput("unknown endpoint operation")
    }
    let baseURL = try requiredString(object, "baseURL")
    let path = try optionalString(object, "path") ?? ""
    var queryItems: [URLQueryItem] = []
    if let rawItems = object["queryItems"] {
      guard case .array(let items) = rawItems else {
        throw FixtureAdapterError.invalidInput("queryItems must be an array")
      }
      queryItems = try items.enumerated().map { index, rawItem in
        let item = try rawItem.object("queryItems[\(index)]")
        let name = try requiredString(item, "name")
        let value = try optionalNullableString(item, "value")
        return URLQueryItem(name: name, value: value)
      }
    }
    return EndpointRequest(operation: operation, baseURL: baseURL, path: path, queryItems: queryItems)
  }

  static func front(_ raw: JSONValue) throws -> FrontRequest {
    let object = try raw.object("front matter input")
    let operation = try requiredString(object, "operation")
    guard operation == "render" || operation == "markdown-document" else {
      throw FixtureAdapterError.invalidInput("unknown front matter operation")
    }
    let documentObject = try object["document"].object("document")
    for key in ["slug", "draftFlag", "summaryField", "summary", "coverField", "coverPath"] {
      if documentObject[key]?.isNull == true {
        throw FixtureAdapterError.invalidInput("optional document field \(key) must be omitted, not null")
      }
    }
    return FrontRequest(operation: operation, document: try makeDocument(documentObject, fixtureID: "front matter"))
  }

  static func diff(_ raw: JSONValue) throws -> DiffRequest {
    let object = try raw.object("diff input")
    return DiffRequest(
      remote: try requiredString(object, "remote"),
      local: try requiredString(object, "local")
    )
  }

  private static func requiredString(_ object: [String: JSONValue], _ key: String) throws -> String {
    guard let value = object[key], case .string(let string) = value else {
      throw FixtureAdapterError.invalidInput("\(key) must be a string")
    }
    return string
  }

  private static func optionalString(_ object: [String: JSONValue], _ key: String) throws -> String? {
    guard let value = object[key] else { return nil }
    guard case .string(let string) = value else {
      throw FixtureAdapterError.invalidInput("\(key) must be a string when present")
    }
    return string
  }

  private static func optionalNullableString(_ object: [String: JSONValue], _ key: String) throws -> String? {
    guard let value = object[key] else { return nil }
    switch value {
    case .null: return nil
    case .string(let string): return string
    default: throw FixtureAdapterError.invalidInput("\(key) must be a string or null")
    }
  }
}

private func verifyEndpoint(_ fixture: FixtureCase) throws {
  let request = try FixtureAdapter.endpoint(fixture.input)
  let endpoint = try RepositoryEndpoint.validated(baseURL: request.baseURL)
  let expected = try fixture.expected.object("\(fixture.id).expected")
  let expectedValue = try expected["value"].object("\(fixture.id).expected.value")
  if request.operation == "validate" {
    XCTAssertEqual(
      try expectedValue["baseURL"].unwrapString("\(fixture.id).expected.value.baseURL"),
      endpoint.baseURL.absoluteString,
      "fixture \(fixture.id)"
    )
  } else {
    let actual = try endpoint.url(path: request.path, queryItems: request.queryItems).absoluteString
    XCTAssertEqual(
      try expectedValue["absoluteURL"].unwrapString("\(fixture.id).expected.value.absoluteURL"),
      actual,
      "fixture \(fixture.id)"
    )
  }
}

private func verifyFrontMatter(_ fixture: FixtureCase) throws {
  let request = try FixtureAdapter.front(fixture.input)
  let actual = request.operation == "render" ? FrontMatterDocumentRenderer().render(request.document) : FrontMatterDocumentRenderer().markdownDocument(request.document)
  let expected = try fixture.expected.object("\(fixture.id).expected")["value"].object("\(fixture.id).expected.value")["text"].unwrapString("\(fixture.id).expected.value.text")
  XCTAssertEqual(Data(actual.utf8), Data(expected.utf8), "fixture \(fixture.id)")
}

private func makeDocument(_ object: [String: JSONValue], fixtureID: String) throws -> FrontMatterDocument {
  guard let syntax = FrontMatterDocumentSyntax(rawValue: try object["syntax"].unwrapString("\(fixtureID).syntax")) else {
    throw FixtureError.message("unknown syntax \(fixtureID)")
  }
  guard let layout = FrontMatterTaxonomyLayout(rawValue: try object["taxonomyLayout"].unwrapString("\(fixtureID).taxonomyLayout")) else {
    throw FixtureError.message("unknown taxonomy layout \(fixtureID)")
  }
  return FrontMatterDocument(
    syntax: syntax,
    title: try object["title"].unwrapString("\(fixtureID).title"),
    formattedDate: try object["formattedDate"].unwrapString("\(fixtureID).formattedDate"),
    slug: object["slug"]?.stringValue,
    draftFlag: object["draftFlag"]?.boolValue,
    summaryField: object["summaryField"]?.stringValue,
    summary: object["summary"]?.stringValue,
    authors: try object.stringArray("authors", "\(fixtureID).authors"),
    tags: try object.stringArray("tags", "\(fixtureID).tags"),
    categories: try object.stringArray("categories", "\(fixtureID).categories"),
    taxonomyLayout: layout,
    coverField: object["coverField"]?.stringValue,
    coverPath: object["coverPath"]?.stringValue,
    writesCoverInExtraTable: try object["writesCoverInExtraTable"].boolValue.unwrap("\(fixtureID).writesCoverInExtraTable"),
    bodyMarkdown: try object["bodyMarkdown"].unwrapString("\(fixtureID).bodyMarkdown")
  )
}

private func verifyDiff(_ fixture: FixtureCase) throws {
  let request = try FixtureAdapter.diff(fixture.input)
  let remote = request.remote
  let local = request.local
  let remoteCount = remote.components(separatedBy: .newlines).count
  let localCount = local.components(separatedBy: .newlines).count
  let expected = try fixture.expected.object("\(fixture.id).expected")["value"].object("\(fixture.id).expected.value")
  let expectedStrategy = remoteCount * localCount <= 250_000 ? "lcs" : "coarse"
  XCTAssertEqual(try expected["strategy"].unwrapString("\(fixture.id).strategy"), expectedStrategy, "fixture \(fixture.id)")
  let expectedLines = try expected["lines"].array("\(fixture.id).lines")
  let actualLines = PublishConflictDiffBuilder().diff(remote: remote, local: local)
  XCTAssertEqual(actualLines.count, expectedLines.count, "fixture \(fixture.id): line count")
  for (index, actual) in actualLines.enumerated() {
    let expectedLine = try expectedLines[index].object("\(fixture.id)[\(index)]")
    XCTAssertEqual(try expectedLine["id"].intValue.unwrap("\(fixture.id)[\(index)].id"), actual.id, "fixture \(fixture.id)[\(index)]")
    XCTAssertEqual(try expectedLine["kind"].unwrapString("\(fixture.id)[\(index)].kind"), actual.kind.rawValue, "fixture \(fixture.id)[\(index)]")
    XCTAssertEqual(try expectedLine["marker"].unwrapString("\(fixture.id)[\(index)].marker"), actual.marker, "fixture \(fixture.id)[\(index)]")
    XCTAssertEqual(try expectedLine["text"].unwrapString("\(fixture.id)[\(index)].text"), actual.text, "fixture \(fixture.id)[\(index)]")
  }
}

private extension JSONValue {
  var stringValue: String? { if case .string(let value) = self { return value }; return nil }
  var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
  var intValue: Int? { if case .number(let value) = self { return Int(value) }; return nil }
  var arrayValue: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
}

private extension Optional where Wrapped == Bool {
  func unwrap(_ context: String) throws -> Bool {
    guard let value = self else { throw FixtureError.message("expected bool \(context)") }
    return value
  }
}

private extension Optional where Wrapped == Int {
  func unwrap(_ context: String) throws -> Int {
    guard let value = self else { throw FixtureError.message("expected integer \(context)") }
    return value
  }
}

private extension Optional where Wrapped == JSONValue {
  var stringValue: String? { flatMap(\.stringValue) }
  var boolValue: Bool? { flatMap(\.boolValue) }
  var intValue: Int? { flatMap(\.intValue) }
  func object(_ context: String) throws -> [String: JSONValue] {
    try self.unwrapObject(context)
  }
  private func unwrapObject(_ context: String) throws -> [String: JSONValue] {
    guard case .some(.object(let value)) = self else { throw FixtureError.message("expected object \(context)") }
    return value
  }
}

private extension Dictionary where Key == String, Value == JSONValue {
  func stringArray(_ key: String, _ context: String) throws -> [String] {
    guard let value = self[key], case .array(let values) = value else {
      throw FixtureError.message("expected string array \(context)")
    }
    return try values.enumerated().map { index, value in
      try value.string("\(context)[\(index)]")
    }
  }
}
