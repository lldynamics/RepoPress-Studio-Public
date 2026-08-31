import Foundation
import XCTest
import os

@testable import PublishingKnowledgeCore

#if canImport(CoreML)
  private final class CoreMLTokenizerCallRecorder: Sendable {
    private let storedCallCount = OSAllocatedUnfairLock<Int>(uncheckedState: 0)

    func recordCall() {
      storedCallCount.withLock { $0 += 1 }
    }

    var callCount: Int {
      storedCallCount.withLock { $0 }
    }
  }

  private struct RecordingCoreMLTokenizer: KnowledgeCoreMLEmbeddingTokenizer {
    let recorder: CoreMLTokenizerCallRecorder

    func encode(
      _ input: KnowledgeSemanticEmbeddingInput,
      maximumTokenCount: Int
    ) throws -> KnowledgeCoreMLEmbeddingEncodedInput {
      recorder.recordCall()
      return KnowledgeCoreMLEmbeddingEncodedInput(
        tensors: [
          "input_ids": KnowledgeCoreMLEmbeddingTensor(shape: [1, 1], values: [1])
        ]
      )
    }
  }

  final class KnowledgeCoreMLEmbeddingProviderTests: XCTestCase {
    func testMissingCompiledModelDowngradesAvailabilityWithoutTokenizingContent() {
      let recorder = CoreMLTokenizerCallRecorder()
      let provider = KnowledgeCoreMLEmbeddingProvider(
        descriptor: descriptor(availability: .available),
        compiledModelURL: URL(fileURLWithPath: "/private/tmp/missing-knowledge-embedding.mlmodelc"),
        inputNames: ["input_ids"],
        outputName: "embedding",
        tokenizer: RecordingCoreMLTokenizer(recorder: recorder)
      )

      XCTAssertEqual(provider.descriptor.availability, .temporarilyUnavailable)
      XCTAssertNil(
        provider.vector(
          for: KnowledgeSemanticEmbeddingInput(text: "private local knowledge", role: .query)
        )
      )
      XCTAssertEqual(recorder.callCount, 0)
    }

    func testConfiguredUnavailableProviderDoesNotAttemptModelLoadingOrInference() {
      let recorder = CoreMLTokenizerCallRecorder()
      let provider = KnowledgeCoreMLEmbeddingProvider(
        descriptor: descriptor(availability: .temporarilyUnavailable),
        compiledModelURL: URL(fileURLWithPath: "/private/tmp/not-loaded.mlmodelc"),
        inputNames: ["input_ids"],
        outputName: "embedding",
        tokenizer: RecordingCoreMLTokenizer(recorder: recorder)
      )

      XCTAssertEqual(provider.descriptor.availability, .temporarilyUnavailable)
      XCTAssertNil(
        provider.vector(
          for: KnowledgeSemanticEmbeddingInput(text: "indexed passage", role: .passage)
        )
      )
      XCTAssertEqual(recorder.callCount, 0)
    }

    private func descriptor(
      availability: KnowledgeSemanticProviderAvailability
    ) -> KnowledgeSemanticEmbeddingDescriptor {
      KnowledgeSemanticEmbeddingDescriptor(
        modelIdentifier: "test-coreml-provider",
        dimension: 2,
        minimumSimilarity: 0.2,
        maximumTokenCount: 16,
        weightsVersion: "fixture",
        preprocessingVersion: "fixture",
        availability: availability,
        queryInstruction: "query:"
      )
    }
  }
#endif
