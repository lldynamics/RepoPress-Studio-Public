import Foundation
import KnowledgeNativeMessagingSupport
import Darwin
import XCTest

final class KnowledgeNativeMessagingProtocolTests: XCTestCase {
  func testNativeHostAcceptsBrowserCallerArguments() {
    let userID: UInt32 = 501
    let expected = KnowledgeNativeMessagingProtocol.unixSocketPath(userID: userID)

    XCTAssertEqual(
      NativeHostLaunchArguments.resolveSocketPath(
        arguments: [
          "/Users/test/Library/Application Support/Mozilla/NativeMessagingHosts/"
            + "\(KnowledgeNativeMessagingProtocol.hostName).json",
          KnowledgeNativeMessagingProtocol.firefoxExtensionID,
        ],
        userID: userID
      ),
      expected
    )
    XCTAssertEqual(
      NativeHostLaunchArguments.resolveSocketPath(
        arguments: [KnowledgeNativeMessagingProtocol.chromiumDevelopmentOrigin],
        userID: userID
      ),
      expected
    )
  }

  func testNativeHostRejectsUnknownCallerArguments() {
    let userID: UInt32 = 501

    XCTAssertNil(NativeHostLaunchArguments.resolveSocketPath(
      arguments: ["moz-extension://untrusted/"],
      userID: userID
    ))
    XCTAssertNil(NativeHostLaunchArguments.resolveSocketPath(
      arguments: [
        "/tmp/other-host.json",
        KnowledgeNativeMessagingProtocol.firefoxExtensionID,
      ],
      userID: userID
    ))
    XCTAssertNil(NativeHostLaunchArguments.resolveSocketPath(
      arguments: ["chrome-extension://untrusted/"],
      userID: userID
    ))
  }

  func testNativeHostAllowsOnlyBoundedAbsoluteTestSocketPath() {
    XCTAssertEqual(
      NativeHostLaunchArguments.resolveSocketPath(
        arguments: ["--socket-path", "/private/tmp/knowledge-test.sock"],
        userID: 501
      ),
      "/private/tmp/knowledge-test.sock"
    )
    XCTAssertNil(NativeHostLaunchArguments.resolveSocketPath(
      arguments: ["--socket-path", "relative.sock"],
      userID: 501
    ))
    XCTAssertNil(NativeHostLaunchArguments.resolveSocketPath(
      arguments: ["--socket-path", "/" + String(repeating: "a", count: 103)],
      userID: 501
    ))
  }

  func testNativeHostReadsVersionFromContainingApplicationBundle() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("native-host-metadata-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let contents = root.appendingPathComponent("Publisher.app/Contents", isDirectory: true)
    let executable = contents.appendingPathComponent("MacOS/KnowledgeNativeMessagingHost")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data().write(to: executable)
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleShortVersionString": "1.2.3",
        "CFBundleVersion": "42",
      ],
      format: .xml,
      options: 0
    )
    try infoData.write(to: contents.appendingPathComponent("Info.plist"))

    XCTAssertEqual(
      NativeHostApplicationMetadata.resolve(forExecutable: executable),
      .init(version: "1.2.3", build: "42")
    )
  }

  func testNativeHostUsesDevelopmentMetadataWithoutPackagedInfoPlist() {
    let executable = FileManager.default.temporaryDirectory
      .appendingPathComponent("KnowledgeNativeMessagingHost-\(UUID().uuidString)")

    XCTAssertEqual(
      NativeHostApplicationMetadata.resolve(forExecutable: executable),
      .init(version: "development", build: "0")
    )
  }

  func testFrameUsesLittleEndianLengthPrefix() throws {
    let payload = Data("{\"ok\":true}".utf8)
    let framed = try KnowledgeNativeMessagingProtocol.frame(payload)

    XCTAssertEqual(try KnowledgeNativeMessagingProtocol.decodeLength(framed.prefix(4)), payload.count)
    XCTAssertEqual(framed.dropFirst(4), payload)
  }

  func testRequestOnlyAllowsKnownBridgeRoutes() throws {
    let token = String(repeating: "a", count: 64)
    XCTAssertNoThrow(try KnowledgeNativeMessagingProtocol.Request(
      path: "/v1/folders",
      method: "GET",
      token: token
    ).validate())
    XCTAssertNoThrow(try KnowledgeNativeMessagingProtocol.Request(
      path: "/v1/import",
      method: "POST",
      token: token,
      bodyJSON: "{}"
    ).validate())
    XCTAssertThrowsError(try KnowledgeNativeMessagingProtocol.Request(
      path: "/v1/status",
      method: "GET",
      token: token
    ).validate())
    XCTAssertThrowsError(try KnowledgeNativeMessagingProtocol.Request(
      path: "/v1/import",
      method: "GET",
      token: token
    ).validate())
  }

  func testRequestRejectsShortTokenAndInvalidJSON() {
    XCTAssertThrowsError(try KnowledgeNativeMessagingProtocol.Request(
      path: "/v1/folders",
      method: "GET",
      token: "short"
    ).validate())
    XCTAssertThrowsError(try KnowledgeNativeMessagingProtocol.Request(
      path: "/v1/import",
      method: "POST",
      token: String(repeating: "b", count: 64),
      bodyJSON: "not-json"
    ).validate())
  }

  func testHandshakeDoesNotRequireLibraryTokenAndRejectsProtocolMismatch() throws {
    let request = KnowledgeNativeMessagingProtocol.Request.handshake()
    XCTAssertTrue(request.isHandshake)
    XCTAssertEqual(request.token, "")
    XCTAssertNoThrow(try request.validate())

    XCTAssertThrowsError(try KnowledgeNativeMessagingProtocol.Request(
      path: KnowledgeNativeMessagingProtocol.handshakePath,
      method: "GET",
      token: "must-not-carry-a-library-token"
    ).validate())
    XCTAssertThrowsError(try KnowledgeNativeMessagingProtocol.Request.handshake(
      schemaVersion: KnowledgeNativeMessagingProtocol.schemaVersion + 1
    ).validate())

    let response = KnowledgeNativeMessagingProtocol.HandshakeResponse(
      payload: .init(applicationVersion: "1.2.3", applicationBuild: "42")
    )
    XCTAssertNoThrow(try response.validate(
      clientProtocolVersion: KnowledgeNativeMessagingProtocol.schemaVersion
    ))

    var incompatible = response
    incompatible.payload.minimumClientProtocolVersion =
      KnowledgeNativeMessagingProtocol.schemaVersion + 1
    incompatible.payload.maximumClientProtocolVersion =
      KnowledgeNativeMessagingProtocol.schemaVersion + 1
    XCTAssertThrowsError(try incompatible.validate(
      clientProtocolVersion: KnowledgeNativeMessagingProtocol.schemaVersion
    ))
  }

  func testInstallationReceiptRejectsChangedHostOrApplicationVersion() throws {
    let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let receipt = NativeMessagingInstallationReceipt(
      manifestPath: "/Users/test/NativeMessagingHosts/host.json",
      hostPath: "/Applications/Publisher.app/Contents/MacOS/KnowledgeNativeMessagingHost",
      hostSHA256: String(repeating: "a", count: 64),
      hostProtocolVersion: KnowledgeNativeMessagingProtocol.schemaVersion,
      applicationBundlePath: "/Applications/Publisher.app",
      applicationVersion: "1.2.3",
      applicationBuild: "42",
      hostSigningIdentifier: "com.jinfang.PersonalSitePublisherMac.KnowledgeNativeMessagingHost",
      teamIdentifier: "TEAM123",
      installedAt: installedAt
    )
    let decoded = try NativeMessagingInstallationReceipt.decode(receipt.encodedData())
    XCTAssertEqual(decoded, receipt)

    func matches(hostSHA256: String, applicationVersion: String) -> Bool {
      decoded.matches(
        manifestPath: "/Users/test/NativeMessagingHosts/host.json",
        hostPath: "/Applications/Publisher.app/Contents/MacOS/KnowledgeNativeMessagingHost",
        hostSHA256: hostSHA256,
        hostProtocolVersion: KnowledgeNativeMessagingProtocol.schemaVersion,
        applicationBundlePath: "/Applications/Publisher.app",
        applicationVersion: applicationVersion,
        applicationBuild: "42",
        hostSigningIdentifier: "com.jinfang.PersonalSitePublisherMac.KnowledgeNativeMessagingHost",
        teamIdentifier: "TEAM123"
      )
    }

    XCTAssertTrue(matches(hostSHA256: String(repeating: "a", count: 64), applicationVersion: "1.2.3"))
    XCTAssertFalse(matches(hostSHA256: String(repeating: "b", count: 64), applicationVersion: "1.2.3"))
    XCTAssertFalse(matches(hostSHA256: String(repeating: "a", count: 64), applicationVersion: "1.2.4"))
  }

  func testHostSignatureTrustPolicyRequiresExpectedIdentifierAndSameTeam() throws {
    let application = NativeCodeSignatureIdentity(
      signingIdentifier: "com.jinfang.PersonalSitePublisherMac",
      teamIdentifier: "TEAM123"
    )
    let expectedIdentifier =
      "com.jinfang.PersonalSitePublisherMac.KnowledgeNativeMessagingHost"
    XCTAssertNoThrow(try NativeHostSignatureTrustPolicy.validate(
      host: .init(signingIdentifier: expectedIdentifier, teamIdentifier: "TEAM123"),
      application: application,
      expectedHostSigningIdentifier: expectedIdentifier
    ))
    XCTAssertThrowsError(try NativeHostSignatureTrustPolicy.validate(
      host: .init(signingIdentifier: "com.attacker.Host", teamIdentifier: "TEAM123"),
      application: application,
      expectedHostSigningIdentifier: expectedIdentifier
    ))
    XCTAssertThrowsError(try NativeHostSignatureTrustPolicy.validate(
      host: .init(signingIdentifier: expectedIdentifier, teamIdentifier: "OTHERTEAM"),
      application: application,
      expectedHostSigningIdentifier: expectedIdentifier
    ))

    let adHocApplication = NativeCodeSignatureIdentity(
      signingIdentifier: "com.jinfang.PersonalSitePublisherMac",
      teamIdentifier: nil
    )
    XCTAssertNoThrow(try NativeHostSignatureTrustPolicy.validate(
      host: .init(signingIdentifier: expectedIdentifier, teamIdentifier: nil),
      application: adHocApplication,
      expectedHostSigningIdentifier: expectedIdentifier
    ))
    XCTAssertThrowsError(try NativeHostSignatureTrustPolicy.validate(
      host: .init(signingIdentifier: expectedIdentifier, teamIdentifier: nil),
      application: adHocApplication,
      expectedHostSigningIdentifier: expectedIdentifier,
      requiresTeamIdentifier: true
    ))
  }

  func testHostManifestsUseBrowserSpecificAllowLists() throws {
    let firefox = KnowledgeNativeMessagingProtocol.HostManifest(
      browserFamily: .firefox,
      hostPath: "/Applications/Publisher.app/Contents/MacOS/KnowledgeNativeMessagingHost"
    )
    XCTAssertEqual(firefox.allowedExtensions, [KnowledgeNativeMessagingProtocol.firefoxExtensionID])
    XCTAssertNil(firefox.allowedOrigins)

    let chrome = KnowledgeNativeMessagingProtocol.HostManifest(
      browserFamily: .chrome,
      hostPath: "/Applications/Publisher.app/Contents/MacOS/KnowledgeNativeMessagingHost"
    )
    XCTAssertNil(chrome.allowedExtensions)
    XCTAssertEqual(
      chrome.allowedOrigins,
      KnowledgeNativeMessagingProtocol.chromeAllowedOrigins
    )
    let object = try JSONSerialization.jsonObject(with: chrome.encodedData()) as? [String: Any]
    XCTAssertNil(object?["allowed_extensions"])
    XCTAssertEqual(
      object?["allowed_origins"] as? [String],
      KnowledgeNativeMessagingProtocol.chromeAllowedOrigins
    )

    let edge = KnowledgeNativeMessagingProtocol.HostManifest(
      browserFamily: .edge,
      hostPath: "/Applications/Publisher.app/Contents/MacOS/KnowledgeNativeMessagingHost"
    )
    XCTAssertNil(edge.allowedExtensions)
    XCTAssertEqual(edge.allowedOrigins, KnowledgeNativeMessagingProtocol.edgeAllowedOrigins)
    XCTAssertTrue(chrome.allowedOrigins?.allSatisfy { $0.hasPrefix("chrome-extension://") } == true)
    XCTAssertFalse(chrome.allowedOrigins?.contains(where: { $0.contains("*") }) == true)
    XCTAssertFalse(edge.allowedOrigins?.contains(where: { $0.contains("*") }) == true)
  }

  func testUnixSocketPathIsUserScopedAndWithinDarwinLengthLimit() {
    let first = KnowledgeNativeMessagingProtocol.unixSocketPath(userID: 501)
    let second = KnowledgeNativeMessagingProtocol.unixSocketPath(userID: 502)

    XCTAssertNotEqual(first, second)
    XCTAssertEqual(first, "/private/tmp/com.jinfang.personal-site-publisher.501.sock")
    XCTAssertLessThan(first.utf8.count, 104)
  }

  func testSocketLeaseIsSendableAndConcurrentReleaseIsIdempotent() async throws {
    let paths = socketLeaseTestPaths("concurrent-release")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let lease = try NativeMessagingSocketLease.acquire(
      socketPath: paths.socket.path,
      lockFileURL: paths.lock
    )
    requireSendable(lease)

    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<16 {
        group.addTask {
          lease.release()
        }
      }
    }

    let nextLease = try NativeMessagingSocketLease.acquire(
      socketPath: paths.socket.path,
      lockFileURL: paths.lock
    )
    nextLease.release()
  }

  func testSocketLeaseRejectsSecondOwnerWithoutTouchingActiveSocket() throws {
    let paths = socketLeaseTestPaths("exclusive")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let firstLease = try NativeMessagingSocketLease.acquire(
      socketPath: paths.socket.path,
      lockFileURL: paths.lock
    )
    let socketDescriptor = try createUnixSocket(at: paths.socket.path)
    defer { close(socketDescriptor) }
    try firstLease.recordBoundSocketAndRestrictPermissions()
    let originalIdentity = try socketIdentity(at: paths.socket.path)

    XCTAssertThrowsError(try NativeMessagingSocketLease.acquire(
      socketPath: paths.socket.path,
      lockFileURL: paths.lock
    )) { error in
      XCTAssertEqual(error as? NativeMessagingSocketLease.LeaseError, .alreadyOwned)
    }
    XCTAssertEqual(try socketIdentity(at: paths.socket.path), originalIdentity)

    firstLease.release()
    XCTAssertFalse(FileManager.default.fileExists(atPath: paths.socket.path))
    let nextLease = try NativeMessagingSocketLease.acquire(
      socketPath: paths.socket.path,
      lockFileURL: paths.lock
    )
    nextLease.release()
  }

  func testSocketLeaseReleasePreservesReplacementSocket() throws {
    let paths = socketLeaseTestPaths("replacement")
    defer { try? FileManager.default.removeItem(at: paths.root) }
    let lease = try NativeMessagingSocketLease.acquire(
      socketPath: paths.socket.path,
      lockFileURL: paths.lock
    )
    let originalDescriptor = try createUnixSocket(at: paths.socket.path)
    try lease.recordBoundSocketAndRestrictPermissions()
    let originalIdentity = try socketIdentity(at: paths.socket.path)

    XCTAssertEqual(unlink(paths.socket.path), 0)
    let replacementDescriptor = try createUnixSocket(at: paths.socket.path)
    defer {
      close(originalDescriptor)
      close(replacementDescriptor)
      _ = unlink(paths.socket.path)
    }
    let replacementIdentity = try socketIdentity(at: paths.socket.path)
    XCTAssertNotEqual(replacementIdentity, originalIdentity)

    lease.release()
    XCTAssertTrue(FileManager.default.fileExists(atPath: paths.socket.path))
    XCTAssertEqual(try socketIdentity(at: paths.socket.path), replacementIdentity)
  }

  func testSocketLeaseRemovesStaleSocketButRefusesRegularFile() throws {
    let stalePaths = socketLeaseTestPaths("stale")
    defer { try? FileManager.default.removeItem(at: stalePaths.root) }
    let staleDescriptor = try createUnixSocket(at: stalePaths.socket.path)
    close(staleDescriptor)
    XCTAssertTrue(FileManager.default.fileExists(atPath: stalePaths.socket.path))
    let lease = try NativeMessagingSocketLease.acquire(
      socketPath: stalePaths.socket.path,
      lockFileURL: stalePaths.lock
    )
    XCTAssertFalse(FileManager.default.fileExists(atPath: stalePaths.socket.path))
    lease.release()

    let occupiedPaths = socketLeaseTestPaths("occupied")
    defer { try? FileManager.default.removeItem(at: occupiedPaths.root) }
    try Data("not-a-socket".utf8).write(to: occupiedPaths.socket)
    XCTAssertThrowsError(try NativeMessagingSocketLease.acquire(
      socketPath: occupiedPaths.socket.path,
      lockFileURL: occupiedPaths.lock
    )) { error in
      XCTAssertEqual(error as? NativeMessagingSocketLease.LeaseError, .socketPathOccupied)
    }
    XCTAssertEqual(try Data(contentsOf: occupiedPaths.socket), Data("not-a-socket".utf8))
  }

  private func socketLeaseTestPaths(
    _ name: String
  ) -> (root: URL, socket: URL, lock: URL) {
    let suffix = UUID().uuidString.prefix(8)
    let root = URL(fileURLWithPath: "/private/tmp/nsl-\(name)-\(suffix)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return (
      root,
      root.appendingPathComponent("bridge.sock"),
      root.appendingPathComponent("locks", isDirectory: true)
        .appendingPathComponent("bridge.lock")
    )
  }

  private func requireSendable<T: Sendable>(_: T) {}

  private func createUnixSocket(at path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXTestError(code: errno) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let didCopyPath = path.withCString { source in
      withUnsafeMutablePointer(to: &address.sun_path) { destination in
        destination.withMemoryRebound(to: CChar.self, capacity: 104) {
          strlcpy($0, source, 104) < 104
        }
      }
    }
    guard didCopyPath else {
      close(descriptor)
      throw POSIXTestError(code: ENAMETOOLONG)
    }
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0, Darwin.listen(descriptor, 1) == 0 else {
      let code = errno
      close(descriptor)
      throw POSIXTestError(code: code)
    }
    return descriptor
  }

  private func socketIdentity(at path: String) throws -> String {
    var status = stat()
    guard lstat(path, &status) == 0 else { throw POSIXTestError(code: errno) }
    return "\(status.st_dev):\(status.st_ino)"
  }
}

private struct POSIXTestError: Error {
  var code: Int32
}
