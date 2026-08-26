/// The edit categories emitted by the structured proofreading contract.
///
/// Keep these raw values stable: they are part of the JSON contract sent to AI
/// providers and may also be persisted in local, content-free feedback records.
public enum AIStructuredEditCategory: String, Codable, CaseIterable, Hashable, Sendable {
  case spelling
  case grammar
  case punctuation
  case clarity
  case concision
  case style
  case structure
  case formatting
  case terminology
  case factualCaution = "factual_caution"
}
