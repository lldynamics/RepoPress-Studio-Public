import Foundation
import XCTest

@testable import PublishingWorkbenchCore

final class AIToolCallingModelsTests: XCTestCase {
  func testToolChoiceModesUseOpenAICompatibleStringEncoding() throws {
    let encoder = JSONEncoder()

    XCTAssertEqual(
      String(decoding: try encoder.encode(AIToolChoice.none), as: UTF8.self),
      #""none""#
    )
    XCTAssertEqual(
      String(decoding: try encoder.encode(AIToolChoice.auto), as: UTF8.self),
      #""auto""#
    )
    XCTAssertEqual(
      String(decoding: try encoder.encode(AIToolChoice.required), as: UTF8.self),
      #""required""#
    )
  }

  func testSpecificFunctionToolChoiceRoundTripsOpenAICompatibleObject() throws {
    let choice = AIToolChoice.function(name: "draft.read")
    let data = try JSONEncoder().encode(choice)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(Set(object.keys), Set(["type", "function"]))
    XCTAssertEqual(object["type"] as? String, "function")
    let function = try XCTUnwrap(object["function"] as? [String: Any])
    XCTAssertEqual(Set(function.keys), Set(["name"]))
    XCTAssertEqual(function["name"] as? String, "draft.read")
    XCTAssertEqual(try JSONDecoder().decode(AIToolChoice.self, from: data), choice)
  }

  func testMinimalToolDefinitionOmitsNilDescriptionAndStrict() throws {
    let tool = AIToolDefinition(
      function: AIToolFunctionDefinition(
        name: "knowledge.search",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([:]),
        ])
      )
    )

    let data = try JSONEncoder().encode(tool)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), Set(["type", "function"]))
    let function = try XCTUnwrap(object["function"] as? [String: Any])
    XCTAssertEqual(Set(function.keys), Set(["name", "parameters"]))
    XCTAssertNil(function["description"])
    XCTAssertNil(function["strict"])
  }

  func testStructuredOutputFormatsRoundTripWithoutLosingSchemaValues() throws {
    let formats: [AIStructuredOutputFormat] = [
      .text,
      .jsonObject,
      .jsonSchema(
        AIStructuredOutputJSONSchema(
          name: "answer",
          schema: .object([
            "type": .string("object"),
            "required": .array([.string("value")]),
            "minimum": .number(0),
            "additionalProperties": .bool(false),
            "default": .null,
          ]),
          strict: true
        )
      ),
    ]

    for format in formats {
      let data = try JSONEncoder().encode(format)
      XCTAssertEqual(try JSONDecoder().decode(AIStructuredOutputFormat.self, from: data), format)
    }
  }
}
