import Foundation
import XCTest

@testable import PublishingAICore
@testable import PublishingWorkbenchCore

final class AIModelDiscoveryMetadataTests: XCTestCase {

  func testMalformedOptionalMetadataDoesNotRemoveUsableModels() {
    let models = parse(
      #"{"data":[{"id":"usable","name":42,"context_length":"unknown","pricing":{"prompt":{}}}]}"#)
    XCTAssertEqual(models.map(\.id), ["usable"])
    XCTAssertNil(models.first?.contextWindow)
    XCTAssertNil(models.first?.inputPricePerMillionUSD)
  }
  func testOpenAIModelsKeepHeuristicFallbackWithoutMetadata() {
    let models = parse(
      """
      {"data":[{"id":"deepseek-r1"},{"id":"gpt-4o"}]}
      """)
    XCTAssertEqual(models.count, 2)
    XCTAssertFalse(models[0].hasProviderMetadata)
    XCTAssertTrue(models[0].isReasoning)
    XCTAssertTrue(models[1].isVision)
  }

  func testAnthropicMetadataUsesDisplayNameCapabilitiesAndLimits() {
    let models = parse(
      """
      {"data":[{"id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6",
      "capabilities":{"image_input":{"supported":true},"thinking":{"supported":true},"effort":{"supported":true}},
      "max_input_tokens":200000,"max_tokens":8192}]}
      """)
    let model = assertNotNilValue(models.first)
    XCTAssertEqual(model.name, "Claude Sonnet 4.6")
    XCTAssertTrue(model.isVision)
    XCTAssertTrue(model.isReasoning)
    XCTAssertEqual(model.maxInputTokens, 200000)
    XCTAssertEqual(model.maxOutputTokens, 8192)
    XCTAssertTrue(model.hasProviderMetadata)
  }

  func testProviderNameMetadataIsRetainedWithoutCapabilities() {
    let models = parse(
      """
      {"data":[{"id":"provider/model","name":"Provider Display Name"}]}
      """)
    let model = assertNotNilValue(models.first)
    XCTAssertEqual(model.name, "Provider Display Name")
    XCTAssertTrue(model.hasProviderMetadata)
    XCTAssertFalse(model.isVision)
    XCTAssertFalse(model.isReasoning)
  }

  func testOnlyImageModalitiesProveVision() {
    let models = parse(
      """
      {"data":[
        {"id":"audio-video","architecture":{"input_modalities":["audio","video"]}},
        {"id":"image","architecture":{"input_modalities":["text","image"]}}
      ]}
      """)
    XCTAssertFalse(models.first(where: { $0.id == "audio-video" })?.isVision == true)
    XCTAssertTrue(models.first(where: { $0.id == "image" })?.isVision == true)
  }

  func testOpenRouterMetadataUsesModalitiesParametersContextAndPrices() throws {
    let models = parse(
      """
      {"data":[{"id":"provider/model","name":"Provider Model","context_length":131072,
      "architecture":{"input_modalities":["text","image"]},
      "supported_parameters":["temperature","reasoning"],
      "pricing":{"prompt":"0.00000015","completion":"0.0000006"}}]}
      """)
    let model = assertNotNilValue(models.first)
    XCTAssertEqual(model.name, "Provider Model")
    XCTAssertEqual(model.contextWindow, 131072)
    XCTAssertTrue(model.isVision)
    XCTAssertTrue(model.isReasoning)
    XCTAssertEqual(try XCTUnwrap(model.inputPricePerMillionUSD), 0.15, accuracy: 0.00001)
    XCTAssertEqual(try XCTUnwrap(model.outputPricePerMillionUSD), 0.6, accuracy: 0.00001)
    XCTAssertTrue(model.hasProviderMetadata)
  }

  func testInvalidAndNegativePricesAreDiscardedWithoutPoisoningModelMetadata() throws {
    let models = parse(
      """
      {"data":[
        {"id":"negative","pricing":{"prompt":"-0.1","completion":"NaN"}},
        {"id":"infinite","pricing":{"prompt":"Infinity","completion":"inf"}},
        {"id":"valid","pricing":{"prompt":"0.000001","completion":"0"}}
      ]}
      """)
    XCTAssertNil(models[0].inputPricePerMillionUSD)
    XCTAssertNil(models[0].outputPricePerMillionUSD)
    XCTAssertNil(models[1].inputPricePerMillionUSD)
    XCTAssertNil(models[1].outputPricePerMillionUSD)
    XCTAssertEqual(try XCTUnwrap(models[2].inputPricePerMillionUSD), 1, accuracy: 0.00001)
    XCTAssertEqual(try XCTUnwrap(models[2].outputPricePerMillionUSD), 0, accuracy: 0.00001)
  }

  func testOlderCodableDescriptorWithoutOptionalMetadataStillDecodes() throws {
    let data = Data(
      """
      {"id":"legacy","name":"Legacy","isReasoning":false,"isVision":false,"isChat":true}
      """.utf8)
    let model = try JSONDecoder().decode(AIModelDescriptor.self, from: data)
    XCTAssertEqual(model.id, "legacy")
    XCTAssertNil(model.contextWindow)
    XCTAssertFalse(model.hasProviderMetadata)
  }

  private func parse(_ json: String) -> [AIModelDescriptor] {
    AIModelDiscoveryService().parseModels(from: Data(json.utf8))
  }

  private func assertNotNilValue<T>(_ value: T?) -> T {
    XCTAssertNotNil(value)
    return value!
  }
}
