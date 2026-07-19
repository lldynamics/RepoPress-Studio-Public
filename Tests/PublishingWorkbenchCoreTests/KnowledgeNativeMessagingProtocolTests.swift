import Foundation
import KnowledgeNativeMessagingSupport
import XCTest

final class KnowledgeNativeMessagingProtocolTests: XCTestCase {
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

  func testHostManifestsUseBrowserSpecificAllowLists() throws {
    let firefox = KnowledgeNativeMessagingProtocol.HostManifest(
      browserFamily: .firefox,
      hostPath: "/Applications/Publisher.app/Contents/MacOS/KnowledgeNativeMessagingHost"
    )
    XCTAssertEqual(firefox.allowedExtensions, [KnowledgeNativeMessagingProtocol.firefoxExtensionID])
    XCTAssertNil(firefox.allowedOrigins)

    let chromium = KnowledgeNativeMessagingProtocol.HostManifest(
      browserFamily: .chromium,
      hostPath: "/Applications/Publisher.app/Contents/MacOS/KnowledgeNativeMessagingHost"
    )
    XCTAssertNil(chromium.allowedExtensions)
    XCTAssertEqual(
      chromium.allowedOrigins,
      ["chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam/"]
    )
    let object = try JSONSerialization.jsonObject(with: chromium.encodedData()) as? [String: Any]
    XCTAssertNil(object?["allowed_extensions"])
    XCTAssertEqual(
      object?["allowed_origins"] as? [String],
      [KnowledgeNativeMessagingProtocol.chromiumDevelopmentOrigin]
    )
  }

  func testUnixSocketPathIsUserScopedAndWithinDarwinLengthLimit() {
    let first = KnowledgeNativeMessagingProtocol.unixSocketPath(userID: 501)
    let second = KnowledgeNativeMessagingProtocol.unixSocketPath(userID: 502)

    XCTAssertNotEqual(first, second)
    XCTAssertEqual(first, "/private/tmp/com.jinfang.personal-site-publisher.501.sock")
    XCTAssertLessThan(first.utf8.count, 104)
  }
}
