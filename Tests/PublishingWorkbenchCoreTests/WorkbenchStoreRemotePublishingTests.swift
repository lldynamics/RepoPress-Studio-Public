import Foundation
import XCTest

@testable import PublishingWorkbenchCore

@MainActor
class WorkbenchStoreRemotePublishingTestCase: XCTestCase {
  func repositoryTokenStoreForTest() -> KeychainTokenStore {
    KeychainTokenStore(
      service: "PSPMRepoTests.\(UUID().uuidString.prefix(8))",
      accountPrefix: "repo-test",
      inMemory: true
    )
  }

  func preparedGitRepositoryRoot(
    prefix: String = "PersonalSitePublisherMacTests"
  ) throws -> URL {
    let rootURL = try temporaryDirectoryURL(prefix: prefix)
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("content/posts", isDirectory: true),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: rootURL.appendingPathComponent("static/images", isDirectory: true),
      withIntermediateDirectories: true
    )
    try git(["init", "-b", "main"], rootURL: rootURL)
    try git(["config", "user.email", "tests@example.com"], rootURL: rootURL)
    try git(["config", "user.name", "Tests"], rootURL: rootURL)
    try "initial\n".write(
      to: rootURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], rootURL: rootURL)
    try git(["commit", "-m", "Initial"], rootURL: rootURL)
    return rootURL
  }

  func fixedDate() -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = 2026
    components.month = 8
    components.day = 29
    components.hour = 10
    return components.date!
  }

  func remoteArticle(title: String, slug: String, body: String) -> String {
    """
    ---
    title: "\(title)"
    slug: \(slug)
    ---

    \(body)
    """
  }

  @discardableResult
  func git(_ arguments: [String], rootURL: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", rootURL.path] + arguments

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    process.waitUntilExit()

    let output =
      String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let error =
      String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "WorkbenchStoreProfileTests",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output + error]
      )
    }
    return output.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

actor CountingRemoteRepositoryTransport: RemoteRepositoryHTTPTransport {
  private var requests: [URLRequest] = []
  private let failureCode: URLError.Code

  init(failureCode: URLError.Code = .badServerResponse) {
    self.failureCode = failureCode
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests.append(request)
    throw URLError(failureCode)
  }

  func requestCount() -> Int {
    requests.count
  }
}

actor SequencedWorkbenchRemoteRepositoryTransport: RemoteRepositoryHTTPTransport {
  private var responses: [WorkbenchRemoteRepositoryTransportResponse]
  private var requests: [URLRequest] = []
  private let inspectedLocalFileURL: URL?
  private var inspectedLocalFileContents: String?

  init(
    responses: [WorkbenchRemoteRepositoryTransportResponse],
    inspectedLocalFileURL: URL? = nil
  ) {
    self.responses = responses
    self.inspectedLocalFileURL = inspectedLocalFileURL
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    if requests.isEmpty, let inspectedLocalFileURL {
      inspectedLocalFileContents = try? String(
        contentsOf: inspectedLocalFileURL,
        encoding: .utf8
      )
    }
    requests.append(request)
    guard !responses.isEmpty else {
      XCTFail("Unexpected remote repository request: \(request.url?.absoluteString ?? "")")
      return (
        Data(),
        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
      )
    }

    let response = responses.removeFirst()
    return (
      response.data,
      HTTPURLResponse(
        url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
    )
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }

  func replaceResponses(_ responses: [WorkbenchRemoteRepositoryTransportResponse]) {
    self.responses = responses
  }

  func inspectedLocalFileContentsAtFirstRequest() -> String? {
    inspectedLocalFileContents
  }
}

actor SuspendedWorkbenchRemoteRepositoryTransport: RemoteRepositoryHTTPTransport {
  private let response: WorkbenchRemoteRepositoryTransportResponse
  private var responseContinuation: CheckedContinuation<Void, Never>?
  private var requestWaiters: [CheckedContinuation<Void, Never>] = []
  private var requestArrived = false
  private var requests = 0
  private var shouldSuspendNextRequest = true

  init(response: WorkbenchRemoteRepositoryTransportResponse) {
    self.response = response
  }

  func data(for request: URLRequest) async throws -> (Data, URLResponse) {
    requests += 1
    requestArrived = true
    for waiter in requestWaiters {
      waiter.resume()
    }
    requestWaiters.removeAll()
    if shouldSuspendNextRequest {
      shouldSuspendNextRequest = false
      await withCheckedContinuation { continuation in
        responseContinuation = continuation
      }
    }
    return (
      response.data,
      HTTPURLResponse(
        url: request.url!, statusCode: response.statusCode, httpVersion: nil, headerFields: nil)!
    )
  }

  func waitUntilRequestArrives() async {
    guard !requestArrived else { return }
    await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func resume() {
    responseContinuation?.resume()
    responseContinuation = nil
  }

  func requestCount() -> Int {
    requests
  }
}

struct WorkbenchRemoteRepositoryTransportResponse {
  var statusCode: Int
  var data: Data
}

func workbenchRemoteResponse(
  statusCode: Int = 200,
  json: String
) -> WorkbenchRemoteRepositoryTransportResponse {
  WorkbenchRemoteRepositoryTransportResponse(statusCode: statusCode, data: Data(json.utf8))
}

#if DEBUG
  actor RemoteImportTestGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
      entered = true
      await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool {
      entered
    }

    func release() {
      continuation?.resume()
      continuation = nil
    }
  }
#endif
