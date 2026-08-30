import Foundation

#if canImport(CoreML)
  import CoreML

  /// Model-specific tokenization is intentionally injected.  In particular, an
  /// OpenAI/o200k tokenizer is not a valid substitute for a BERT-family model.
  package protocol KnowledgeCoreMLEmbeddingTokenizer: Sendable {
    func encode(
      _ input: KnowledgeSemanticEmbeddingInput,
      maximumTokenCount: Int
    ) throws -> KnowledgeCoreMLEmbeddingEncodedInput
  }

  package struct KnowledgeCoreMLEmbeddingTensor: Sendable {
    package let shape: [Int]
    package let values: [Int32]

    package init(shape: [Int], values: [Int32]) {
      self.shape = shape
      self.values = values
    }
  }

  package struct KnowledgeCoreMLEmbeddingEncodedInput: Sendable {
    package let tensors: [String: KnowledgeCoreMLEmbeddingTensor]

    package init(tensors: [String: KnowledgeCoreMLEmbeddingTensor]) {
      self.tensors = tensors
    }
  }

  /// Loads a compiled, bundled Core ML model conforming to an explicit tensor
  /// convention.  No model is downloaded and every load/prediction failure is a
  /// nil result, allowing the composite service to use its local fallback.
  package final class KnowledgeCoreMLEmbeddingProvider: @unchecked Sendable,
    KnowledgeSemanticEmbeddingProvider
  {
    private let configuredDescriptor: KnowledgeSemanticEmbeddingDescriptor
    private let model: MLModel?
    private let tokenizer: any KnowledgeCoreMLEmbeddingTokenizer
    private let inputNames: Set<String>
    private let outputName: String
    private let inferenceLock = NSLock()
    private let availabilityLock = NSLock()
    private var hasRuntimeFailure = false

    package var descriptor: KnowledgeSemanticEmbeddingDescriptor {
      availabilityLock.lock()
      defer { availabilityLock.unlock() }
      return hasRuntimeFailure
        ? configuredDescriptor.replacingAvailability(.temporarilyUnavailable)
        : configuredDescriptor
    }

    package init(
      descriptor: KnowledgeSemanticEmbeddingDescriptor,
      compiledModelURL: URL,
      inputNames: Set<String>,
      outputName: String,
      tokenizer: any KnowledgeCoreMLEmbeddingTokenizer
    ) {
      let model: MLModel?
      if descriptor.availability == .available {
        do {
          model = try MLModel(contentsOf: compiledModelURL)
        } catch {
          model = nil
        }
      } else {
        model = nil
      }
      let hasValidContract =
        model.map { model in
          let description = model.modelDescription
          return descriptor.dimension > 0
            && descriptor.maximumTokenCount > 0
            && !inputNames.isEmpty
            && !outputName.isEmpty
            && inputNames.allSatisfy {
              description.inputDescriptionsByName[$0]?.type == .multiArray
            }
            && description.outputDescriptionsByName[outputName]?.type == .multiArray
        } ?? false
      self.configuredDescriptor =
        hasValidContract
        ? descriptor
        : descriptor.replacingAvailability(.temporarilyUnavailable)
      self.model = hasValidContract ? model : nil
      self.tokenizer = tokenizer
      self.inputNames = inputNames
      self.outputName = outputName
    }

    package func vector(for input: KnowledgeSemanticEmbeddingInput) -> KnowledgeSemanticVector? {
      let activeDescriptor = descriptor
      guard !Task.isCancelled, activeDescriptor.availability == .available, let model else {
        return nil
      }
      let prepared = preparedInput(input)
      let encoded: KnowledgeCoreMLEmbeddingEncodedInput
      do {
        encoded = try tokenizer.encode(
          prepared,
          maximumTokenCount: activeDescriptor.maximumTokenCount
        )
      } catch {
        if !Task.isCancelled { markRuntimeUnavailable() }
        return nil
      }
      guard Set(encoded.tensors.keys) == inputNames,
        let featureProvider = featureProvider(for: encoded),
        let output = prediction(from: featureProvider, model: model),
        let multiArray = output.featureValue(for: outputName)?.multiArrayValue,
        let values = outputValues(from: multiArray),
        values.count == activeDescriptor.dimension,
        values.allSatisfy(\.isFinite)
      else {
        if !Task.isCancelled { markRuntimeUnavailable() }
        return nil
      }
      let vector = KnowledgeSemanticVector(
        modelIdentifier: activeDescriptor.modelIdentifier,
        values: values,
        minimumSimilarity: activeDescriptor.minimumSimilarity,
        encodingVersion: activeDescriptor.encodingVersion
      )
      guard !vector.isEmpty else {
        markRuntimeUnavailable()
        return nil
      }
      return vector
    }

    private func preparedInput(_ input: KnowledgeSemanticEmbeddingInput)
      -> KnowledgeSemanticEmbeddingInput
    {
      guard input.role == .query,
        let instruction = descriptor.queryInstruction?.trimmingCharacters(
          in: .whitespacesAndNewlines),
        !instruction.isEmpty
      else { return input }
      return KnowledgeSemanticEmbeddingInput(text: instruction + "\n" + input.text, role: .query)
    }

    private func featureProvider(
      for encoded: KnowledgeCoreMLEmbeddingEncodedInput
    ) -> MLDictionaryFeatureProvider? {
      var values: [String: MLFeatureValue] = [:]
      for (name, tensor) in encoded.tensors {
        guard !tensor.shape.isEmpty,
          tensor.shape.allSatisfy({ $0 > 0 }),
          tensor.shape.reduce(1, *) == tensor.values.count
        else { return nil }
        let array: MLMultiArray
        do {
          array = try MLMultiArray(
            shape: tensor.shape.map { NSNumber(value: $0) },
            dataType: .int32
          )
        } catch {
          return nil
        }
        for (offset, value) in tensor.values.enumerated() {
          array[multiArrayIndex(for: offset, shape: tensor.shape)] = NSNumber(value: value)
        }
        values[name] = MLFeatureValue(multiArray: array)
      }
      do {
        return try MLDictionaryFeatureProvider(dictionary: values)
      } catch {
        return nil
      }
    }

    private func outputValues(from array: MLMultiArray) -> [Float]? {
      let shape = array.shape.map(\.intValue)
      let count = shape.reduce(1, *)
      guard count == configuredDescriptor.dimension else { return nil }
      var values: [Float] = []
      values.reserveCapacity(count)
      for offset in 0..<count {
        let value = array[multiArrayIndex(for: offset, shape: shape)].floatValue
        guard value.isFinite else { return nil }
        values.append(value)
      }
      return values
    }

    private func prediction(from provider: MLFeatureProvider, model: MLModel) -> MLFeatureProvider?
    {
      // Core ML model instances do not promise that concurrent prediction calls
      // are safe for every custom layer/runtime.  Keep this local adapter
      // serialized; callers can still parallelize other providers.
      inferenceLock.lock()
      defer { inferenceLock.unlock() }
      do {
        return try model.prediction(from: provider)
      } catch {
        return nil
      }
    }

    private func markRuntimeUnavailable() {
      availabilityLock.lock()
      hasRuntimeFailure = true
      availabilityLock.unlock()
    }

    private func multiArrayIndex(for flatOffset: Int, shape: [Int]) -> [NSNumber] {
      var remainder = flatOffset
      var indices = Array(repeating: NSNumber(value: 0), count: shape.count)
      for offset in shape.indices.reversed() {
        let dimension = shape[offset]
        indices[offset] = NSNumber(value: remainder % dimension)
        remainder /= dimension
      }
      return indices
    }
  }
#endif
