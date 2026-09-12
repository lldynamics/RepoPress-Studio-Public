import XCTest

@testable import PublishingAICore

final class AIConnectionRecoveryHintTests: XCTestCase {
  func testAuthenticationPermissionAndPathHints() {
    XCTAssertTrue(error(status: 401).recoverySuggestion?.contains("API Key") == true)
    XCTAssertTrue(error(status: 403).recoverySuggestion?.contains("权限") == true)
    XCTAssertTrue(error(status: 404).recoverySuggestion?.contains("模型 ID") == true)
  }

  func testStructuredBalanceEvidenceSuggestsCheckingBalance() {
    let body = #"{"error":{"code":"insufficient_quota","message":"quota"}}"#
    let error = error(status: 429, body: body)
    XCTAssertTrue(error.recoverySuggestion?.contains("余额") == true)
    XCTAssertTrue(error.errorDescription?.contains(body) == true)
  }

  func testStructuredQuotaTypeAlsoCountsAsBalanceEvidence() {
    let body = #"{"error":{"type":"insufficient_balance","message":"billing"}}"#
    XCTAssertTrue(error(status: 429, body: body).recoverySuggestion?.contains("余额") == true)
  }

  func testOrdinaryRateLimitAndUnstructuredBalanceTextDoNotSuggestRecharge() {
    let rateLimit = error(
      status: 429,
      body: #"{"error":{"type":"rate_limit_error","message":"quota exceeded"}}"#
    )
    XCTAssertTrue(rateLimit.recoverySuggestion?.contains("稍后重试") == true)
    XCTAssertFalse(rateLimit.recoverySuggestion?.contains("余额") == true)

    let plainText = error(status: 429, body: "insufficient_quota: please add funds")
    XCTAssertTrue(plainText.recoverySuggestion?.contains("稍后重试") == true)
    XCTAssertFalse(plainText.recoverySuggestion?.contains("余额") == true)
  }

  func testServerAndNetworkFailuresHaveManualRecoveryHints() {
    XCTAssertTrue(error(status: 503).recoverySuggestion?.contains("服务暂时异常") == true)
    XCTAssertTrue(
      AIChatCompletionClientError.networkFailure("断开").recoverySuggestion?.contains("网络") == true
    )
    XCTAssertTrue(
      AIChatCompletionClientError.firstByteTimedOut(10).recoverySuggestion?.contains("超时") == true
    )
  }

  func testUnknownHTTPStatusDoesNotGuessARecoveryAction() {
    XCTAssertNil(error(status: 418, body: "payment required").recoverySuggestion)
  }

  private func error(status: Int, body: String = "body") -> AIChatCompletionClientError {
    .httpStatus(status, body, retryAfterSeconds: 2)
  }
}
