import Foundation
import XCTest
@testable import PublishingWorkbenchCore

final class BoundedHTTPResponseLoaderTests: XCTestCase {
  func testValidateRejectsDeclaredOversizedResponse() throws {
    let response = URLResponse(
      url: try XCTUnwrap(URL(string: "https://example.com/data")),
      mimeType: "application/json",
      expectedContentLength: 9,
      textEncodingName: nil
    )

    XCTAssertThrowsError(
      try BoundedHTTPResponseLoader.validate(Data(), response: response, maximumByteCount: 8)
    ) { error in
      XCTAssertEqual(
        error as? HTTPResponseLimitError,
        .responseTooLarge(maximumByteCount: 8)
      )
    }
  }

  func testValidateRejectsActualOversizedResponseWithoutContentLength() throws {
    let response = URLResponse(
      url: try XCTUnwrap(URL(string: "https://example.com/data")),
      mimeType: "application/json",
      expectedContentLength: Int(NSURLSessionTransferSizeUnknown),
      textEncodingName: nil
    )

    XCTAssertThrowsError(
      try BoundedHTTPResponseLoader.validate(Data(repeating: 0, count: 9), response: response, maximumByteCount: 8)
    )
  }
}
