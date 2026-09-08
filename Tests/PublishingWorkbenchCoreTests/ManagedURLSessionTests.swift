import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class ManagedURLSessionTests: XCTestCase {
  func testSessionIsLazyAndSharedByOwnerCopies() {
    let factory = SessionFactoryProbe()
    let owner = ManagedURLSession { factory.makeSession() }
    let copy = owner
    XCTAssertFalse(owner.hasCreatedSession)
    XCTAssertEqual(factory.creationCount, 0)
    XCTAssertTrue(owner.session === copy.session)
    XCTAssertEqual(factory.creationCount, 1)
  }

  func testOnlyLastOwnedReferenceInvalidatesSession() {
    let session = InvalidationCountingSession()
    var owner: ManagedURLSession? = ManagedURLSession(session: session, ownsSession: true)
    var copy = owner
    owner = nil
    XCTAssertEqual(session.invalidationCount, 0)
    XCTAssertNotNil(copy)
    copy = nil
    XCTAssertEqual(session.invalidationCount, 1)
  }

  func testBorrowedSessionIsNeverInvalidatedByTransportOwner() {
    let session = InvalidationCountingSession()
    autoreleasepool {
      let owner = ManagedURLSession(session: session)
      XCTAssertTrue(owner.session === session)
    }
    XCTAssertEqual(session.invalidationCount, 0)
  }

  func testURLOnlyDeploymentCalculationsNeverCreateNetworkSessions() throws {
    let service = DeploymentStatusService()
    let transport = try XCTUnwrap(service.transport as? URLSessionRemoteRepositoryHTTPTransport)
    var profile = SiteProfile.defaultProfile
    profile.deploymentSiteURL = "https://example.com"
    for index in 0..<500 {
      XCTAssertNotNil(service.publicArticleURL(profile: profile, publicPath: "posts/\(index)/"))
    }
    XCTAssertFalse(transport.hasCreatedSession)
  }

  func testRealSessionDelegateReceivesInvalidationWhenOwnerEnds() async {
    let invalidated = expectation(description: "Owned session invalidated")
    autoreleasepool {
      let delegate = InvalidationObserver(invalidated: invalidated)
      let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
      let owner = ManagedURLSession(session: session, ownsSession: true)
      withExtendedLifetime(owner) {}
    }
    await fulfillment(of: [invalidated], timeout: 3)
  }
}

private final class SessionFactoryProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var creationCount: Int { lock.withLock { count } }
  func makeSession() -> URLSession {
    lock.withLock { count += 1 }
    return InvalidationCountingSession()
  }
}

private final class InvalidationCountingSession: URLSession, @unchecked Sendable {
  private let countLock = NSLock()
  private var count = 0
  var invalidationCount: Int { countLock.withLock { count } }
  override func finishTasksAndInvalidate() {
    countLock.withLock { count += 1 }
  }
}

private final class InvalidationObserver: NSObject, URLSessionDelegate, @unchecked Sendable {
  let invalidated: XCTestExpectation
  init(invalidated: XCTestExpectation) { self.invalidated = invalidated }
  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    invalidated.fulfill()
  }
}
