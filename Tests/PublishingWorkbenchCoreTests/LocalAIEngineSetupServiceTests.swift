import XCTest

@testable import PublishingWorkbenchCore

final class LocalAIEngineSetupServiceTests: XCTestCase {
  private let service = LocalAIEngineSetupService()

  func testApplicationTargetsUseVerifiedMacOSBundleIdentifiers() throws {
    XCTAssertEqual(
      try XCTUnwrap(LocalAIEngineSetupService.applicationTarget(for: .ollama)).bundleIdentifier,
      "com.electron.ollama"
    )
    XCTAssertEqual(
      try XCTUnwrap(LocalAIEngineSetupService.applicationTarget(for: .lmStudio)).bundleIdentifier,
      "ai.elementlabs.lmstudio"
    )
  }

  func testInstalledOllamaAndLMStudioRecommendTheirFixedBundleIdentifiers() {
    XCTAssertEqual(
      service.recommendation(for: .ollama, applicationIsInstalled: true),
      .launchApplication(bundleIdentifier: "com.electron.ollama")
    )
    XCTAssertEqual(
      service.recommendation(for: .lmStudio, applicationIsInstalled: true),
      .launchApplication(bundleIdentifier: "ai.elementlabs.lmstudio")
    )
  }

  func testUninstalledEnginesOnlyOfferFixedOfficialDownloadPages() {
    XCTAssertEqual(
      service.recommendation(for: .ollama, applicationIsInstalled: false),
      .openOfficialDownloadPage(URL(string: "https://ollama.com/download/mac")!)
    )
    XCTAssertEqual(
      service.recommendation(for: .lmStudio, applicationIsInstalled: false),
      .openOfficialDownloadPage(URL(string: "https://lmstudio.ai/download")!)
    )
  }

  func testServerOnlyEnginesDoNotPretendToHaveNativeSetupApplications() {
    XCTAssertEqual(service.recommendation(for: .vLLM, applicationIsInstalled: true), .unavailable)
    XCTAssertEqual(service.recommendation(for: .mlx, applicationIsInstalled: false), .unavailable)
  }
}
