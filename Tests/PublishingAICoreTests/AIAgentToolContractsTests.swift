import Foundation
import XCTest

@testable import PublishingAICore

final class AIAgentToolContractsTests: XCTestCase {
  private func descriptor(
    id: String,
    name: String,
    scopes: Set<AIAgentPermissionScope> = [.localRead]
  ) -> AIAgentToolDescriptor {
    AIAgentToolDescriptor(
      id: AIAgentToolID(id),
      definition: AIToolDefinition(
        function: AIToolFunctionDefinition(
          name: name,
          description: "test",
          parameters: .object(["type": .string("object")]),
          strict: true
        )
      ),
      requiredScopes: scopes,
      executionPolicy: .automatic
    )
  }

  func testValidCatalogAndContractRoundTrip() throws {
    let snapshot = try AIAgentToolCatalogSnapshot(
      revision: "catalog-v1",
      descriptors: [descriptor(id: "workbench/createDraft", name: "draft.create")]
    )

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(AIAgentToolCatalogSnapshot.self, from: data)
    XCTAssertEqual(decoded, snapshot)
    XCTAssertEqual(snapshot.descriptors[0].id.rawValue, "workbench/createDraft")
    XCTAssertEqual(snapshot.descriptors[0].definition.function.name, "draft.create")
  }

  func testExternalToolBindingPreservesAuthorityFieldsAndExactArguments() throws {
    let binding = AIAgentExternalToolBinding(
      sourceID: "local.echo",
      sourceRevision: "config-digest-v1",
      remoteToolName: "echo",
      argumentsJSON: #"{ "value" : "hello" }"#
    )

    let data = try JSONEncoder().encode(binding)
    let decoded = try JSONDecoder().decode(AIAgentExternalToolBinding.self, from: data)

    XCTAssertEqual(decoded, binding)
    XCTAssertEqual(decoded.argumentsJSON, #"{ "value" : "hello" }"#)
  }

  func testRejectsDuplicateStableIDs() {
    XCTAssertThrowsError(
      try AIAgentToolCatalogSnapshot(
        revision: "v1",
        descriptors: [
          descriptor(id: "same", name: "first"),
          descriptor(id: "same", name: "second"),
        ]
      )
    ) { error in
      XCTAssertEqual(
        error as? AIAgentToolCatalogValidationError, .duplicateToolID(AIAgentToolID("same")))
    }
  }

  func testRejectsDuplicateModelVisibleFunctionNames() {
    XCTAssertThrowsError(
      try AIAgentToolCatalogSnapshot(
        revision: "v1",
        descriptors: [
          descriptor(id: "first", name: "same"),
          descriptor(id: "second", name: "same"),
        ]
      )
    ) { error in
      XCTAssertEqual(error as? AIAgentToolCatalogValidationError, .duplicateFunctionName("same"))
    }
  }

  func testRejectsBlankRevisionIDsAndFunctionNames() {
    XCTAssertThrowsError(try AIAgentToolCatalogSnapshot(revision: " \n", descriptors: [])) {
      error in
      XCTAssertEqual(error as? AIAgentToolCatalogValidationError, .blankRevision)
    }
    XCTAssertThrowsError(
      try AIAgentToolCatalogSnapshot(
        revision: "v1", descriptors: [descriptor(id: " \t", name: "name")]
      )
    ) { error in
      XCTAssertEqual(error as? AIAgentToolCatalogValidationError, .blankToolID)
    }
    XCTAssertThrowsError(
      try AIAgentToolCatalogSnapshot(
        revision: "v1", descriptors: [descriptor(id: "id", name: " \n")]
      )
    ) { error in
      XCTAssertEqual(error as? AIAgentToolCatalogValidationError, .blankFunctionName)
    }
  }
}
