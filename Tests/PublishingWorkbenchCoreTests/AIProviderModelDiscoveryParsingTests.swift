import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIProviderModelDiscoveryParsingTests: XCTestCase {
  func testModelDiscoveryServiceParsesOpenAIFormat() throws {
    let service = AIModelDiscoveryService()
    let json = """
      {
        "data": [
          {"id": "deepseek-ai/DeepSeek-V3"},
          {"id": "deepseek-ai/DeepSeek-R1"},
          {"id": "gpt-4o"}
        ]
      }
      """
    let data = Data(json.utf8)
    let models = service.parseModels(from: data)

    XCTAssertEqual(models.count, 3)
    let r1 = models.first { $0.id.contains("R1") }
    XCTAssertNotNil(r1)
    XCTAssertTrue(r1?.isReasoning == true)
  }

  func testModelDiscoveryServiceParsesOllamaFormat() throws {
    let service = AIModelDiscoveryService()
    let json = """
      {
        "models": [
          {"name": "llama3.2:latest"},
          {"name": "deepseek-r1:8b"}
        ]
      }
      """
    let data = Data(json.utf8)
    let models = service.parseModels(from: data)

    XCTAssertEqual(models.count, 2)
    let r1 = models.first { $0.id.contains("deepseek-r1") }
    XCTAssertNotNil(r1)
    XCTAssertTrue(r1?.isReasoning == true)
  }
}
