/// Shared, conservative classification for provider errors. A status code by
/// itself is never enough to claim that a capability is unsupported: the
/// bounded error text must name the relevant protocol field/feature and an
/// explicit rejection.
package enum AIProviderCapabilityRejectionClassifier {
  package static func explicitlyRejects(
    _ errorBody: String,
    capability: AIProviderCapabilityProbeKind
  ) -> Bool {
    let text = errorBody.lowercased()
    guard !text.isEmpty else { return false }

    let capabilityMarkers: [String]
    switch capability {
    case .streamingResponse:
      capabilityMarkers = ["stream", "streaming", "stream_options"]
    case .toolCalling:
      capabilityMarkers = ["tool", "tools", "tool_choice", "function_call", "function calling"]
    case .structuredOutput:
      capabilityMarkers = [
        "response_format",
        "json_schema",
        "structured output",
        "structured_output",
        "json object",
      ]
    case .visionInput:
      capabilityMarkers = [
        "image",
        "image_url",
        "vision",
        "multimodal",
      ]
    case .chat:
      return false
    }

    let rejectionMarkers = [
      "not supported",
      "unsupported",
      "does not support",
      "not implemented",
      "unimplemented",
      "unknown parameter",
      "unknown field",
      "unrecognized parameter",
      "unrecognized field",
      "invalid parameter",
      "invalid field",
      "unsupported parameter",
      "unsupported field",
      "not allowed",
      "not permitted",
      "extra inputs are not permitted",
      "extra_forbidden",
    ]

    return capabilityMarkers.contains(where: text.contains)
      && rejectionMarkers.contains(where: text.contains)
  }

  package static func fixedDetail(for capability: AIProviderCapabilityProbeKind) -> String {
    switch capability {
    case .chat:
      return "connection response did not prove chat capability"
    case .streamingResponse:
      return "stream capability was explicitly rejected"
    case .toolCalling:
      return "tool-calling capability was explicitly rejected"
    case .structuredOutput:
      return "structured-output capability was explicitly rejected"
    case .visionInput:
      return "vision capability was explicitly rejected"
    }
  }

  package static let inconclusiveDetail = "probe response was inconclusive"
}
