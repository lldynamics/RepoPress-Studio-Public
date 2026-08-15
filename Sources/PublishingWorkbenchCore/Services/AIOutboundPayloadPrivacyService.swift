import Combine
import CryptoKit
import Foundation

public struct AIOutboundPayloadSanitizationResult: Hashable, Sendable {
  public let text: String
  public let strippedFields: Set<AIOutboundPayloadStrippedField>
  public let sensitiveCategories: Set<AIOutboundPayloadSensitiveCategory>

  public init(
    text: String,
    strippedFields: Set<AIOutboundPayloadStrippedField>,
    sensitiveCategories: Set<AIOutboundPayloadSensitiveCategory>
  ) {
    self.text = text
    self.strippedFields = strippedFields
    self.sensitiveCategories = sensitiveCategories
  }
}

public struct AIOutboundPayloadDescriptor: Sendable {
  public var endpoint: URL
  public var model: String
  public var messages: [AIChatMessage]
  public var contextCounts: [AIOutboundPayloadContextCount]
  public var contextBindingValues: [String]

  public init(
    endpoint: URL,
    model: String,
    messages: [AIChatMessage],
    contextCounts: [AIOutboundPayloadContextCount] = [],
    contextBindingValues: [String] = []
  ) {
    self.endpoint = endpoint
    self.model = model
    self.messages = messages
    self.contextCounts = contextCounts
    self.contextBindingValues = contextBindingValues
  }
}

public struct AIPreparedOutboundPayload: Sendable {
  public let messages: [AIChatMessage]
  public let preview: AIOutboundPayloadPreview
  /// The exact request sealed by `AIChatCompletionClient.prepareRequest`.
  /// Legacy descriptor-only previews leave this nil; all interactive chat
  /// previews created by the assistant carry it and send this same value.
  public let preparedRequest: AIPreparedAIChatCompletionRequest?
  /// The task-resolved provider config used to create `preparedRequest`.
  /// Keeping this beside the seal prevents model-grade resolution from being
  /// repeated after confirmation.
  public let taskConfig: AIProviderConfig?

  public init(
    messages: [AIChatMessage],
    preview: AIOutboundPayloadPreview,
    preparedRequest: AIPreparedAIChatCompletionRequest? = nil,
    taskConfig: AIProviderConfig? = nil
  ) {
    self.messages = messages
    self.preview = preview
    self.preparedRequest = preparedRequest
    self.taskConfig = taskConfig
  }

  func withPreparedRequest(
    _ preparedRequest: AIPreparedAIChatCompletionRequest
  ) -> AIPreparedOutboundPayload {
    AIPreparedOutboundPayload(
      messages: messages,
      preview: preview,
      preparedRequest: preparedRequest,
      taskConfig: taskConfig
    )
  }
}

public enum AIOutboundPayloadTransportVariant: String, Sendable {
  case stream
  case complete
}

/// An in-memory, single-use authorization for one immutable prepared payload.
///
/// This object is deliberately not Codable and never exposes the prepared
/// message content. `consume` must be called immediately next to the transport
/// invocation so confirmation expiry is checked after any intervening await.
@MainActor
public final class AIOutboundPayloadTransportAuthorization {
  private let confirmation: AIOutboundPayloadConfirmation
  private let prepared: AIPreparedOutboundPayload
  private let privacyService: AIOutboundPayloadPrivacyService
  private var isConsumed = false

  public init(
    confirmation: AIOutboundPayloadConfirmation,
    prepared: AIPreparedOutboundPayload,
    privacyService: AIOutboundPayloadPrivacyService
  ) {
    self.confirmation = confirmation
    self.prepared = prepared
    self.privacyService = privacyService
  }

  public func consume(now: Date = Date()) throws {
    guard !isConsumed else {
      throw AIOutboundPayloadConfirmationError.alreadyConsumed
    }
    try privacyService.validate(
      confirmation: confirmation,
      prepared: prepared,
      now: now
    )
    isConsumed = true
  }
}

public struct AIOutboundPayloadPrivacyService: Sendable {
  public static let defaultConfirmationLifetime: TimeInterval = 5 * 60

  private let confirmationLifetime: TimeInterval

  public init(confirmationLifetime: TimeInterval = Self.defaultConfirmationLifetime) {
    self.confirmationLifetime = max(0, confirmationLifetime)
  }

  public func prepare(
    _ descriptor: AIOutboundPayloadDescriptor,
    now: Date = Date(),
    nonce: UUID = UUID()
  ) -> AIPreparedOutboundPayload {
    let sanitized = sanitizedMessageScan(descriptor.messages)
    let sanitizedMessages = sanitized.messages
    let stripped = sanitized.strippedFields
    let sensitive = sanitized.sensitiveCategories
    let destination = sanitizedDestination(descriptor.endpoint)
    let normalizedModel = descriptor.model.trimmingCharacters(in: .whitespacesAndNewlines)
    let payloadMetrics = metrics(for: sanitizedMessages)
    let counts = normalizedContextCounts(
      descriptor.contextCounts,
      messageCount: sanitizedMessages.count,
      imageCount: payloadMetrics.imageCount
    )
    let fingerprint = fingerprint(
      // Bind the destination that the user reviewed. Credentials, query
      // values, and fragments are neither persisted nor hashed.
      endpointBinding: destination,
      model: normalizedModel,
      messages: sanitizedMessages,
      contextCounts: counts,
      contextBindingValues: descriptor.contextBindingValues,
      exactEncodedBody: nil
    )
    let preview = AIOutboundPayloadPreview(
      destination: destination,
      model: normalizedModel,
      contextCounts: counts,
      textCharacterCount: payloadMetrics.textCharacterCount,
      imageCount: payloadMetrics.imageCount,
      imageByteCount: payloadMetrics.imageByteCount,
      strippedFields: AIOutboundPayloadStrippedField.allCases.filter(stripped.contains),
      sensitiveCategories: AIOutboundPayloadSensitiveCategory.allCases.filter(sensitive.contains),
      nonce: nonce,
      fingerprint: fingerprint,
      createdAt: now,
      expiresAt: now.addingTimeInterval(confirmationLifetime),
      isLoopback: isLoopback(descriptor.endpoint)
    )
    return AIPreparedOutboundPayload(messages: sanitizedMessages, preview: preview)
  }

  /// Builds the content-free preview around the request that the provider
  /// client has already normalized and encoded. The encoded body is included
  /// in the fingerprint so preview approval binds temperature, max tokens,
  /// reasoning, tools, response format, stream fields, and the final system
  /// prompt without reconstructing any of those fields here.
  public func prepare(
    preparedRequest: AIPreparedAIChatCompletionRequest,
    taskConfig: AIProviderConfig,
    contextCounts: [AIOutboundPayloadContextCount] = [],
    contextBindingValues: [String] = [],
    now: Date = Date(),
    nonce: UUID = UUID()
  ) -> AIPreparedOutboundPayload {
    let scanned = sanitizedMessageScan(preparedRequest.normalizedRequest.messages)
    let messages = preparedRequest.normalizedRequest.messages
    let destination = taskConfig.usesCodexAppServer
      ? "codex-app-server://chatgpt"
      : sanitizedDestination(preparedRequest.endpointURL)
    let payloadMetrics = metrics(for: messages)
    let counts = normalizedContextCounts(
      contextCounts,
      messageCount: messages.count,
      imageCount: payloadMetrics.imageCount
    )
    let fingerprint = fingerprint(
      endpointBinding: destination,
      model: preparedRequest.normalizedRequest.model,
      messages: messages,
      contextCounts: counts,
      contextBindingValues: contextBindingValues,
      exactEncodedBody: preparedRequest.encodedBody
    )
    let preview = AIOutboundPayloadPreview(
      destination: destination,
      model: taskConfig.usesCodexAppServer
        ? CoreL10n.text("账户默认模型")
        : preparedRequest.normalizedRequest.model,
      contextCounts: counts,
      textCharacterCount: payloadMetrics.textCharacterCount,
      imageCount: payloadMetrics.imageCount,
      imageByteCount: payloadMetrics.imageByteCount,
      strippedFields: AIOutboundPayloadStrippedField.allCases.filter(
        scanned.strippedFields.contains
      ),
      sensitiveCategories: AIOutboundPayloadSensitiveCategory.allCases.filter(
        scanned.sensitiveCategories.contains
      ),
      nonce: nonce,
      fingerprint: fingerprint,
      createdAt: now,
      expiresAt: now.addingTimeInterval(confirmationLifetime),
      isLoopback: taskConfig.usesCodexAppServer
        ? false
        : isLoopback(preparedRequest.endpointURL)
    )
    return AIPreparedOutboundPayload(
      messages: messages,
      preview: preview,
      preparedRequest: preparedRequest,
      taskConfig: taskConfig
    )
  }

  /// Sanitizes the messages after provider normalization. This is intended for
  /// `AIChatCompletionClient.prepareRequest(transformMessages:)`; it keeps the
  /// client as the single owner of model/provider normalization while this
  /// service remains the single owner of privacy redaction.
  public func sanitizedMessagesForTransport(_ messages: [AIChatMessage]) -> [AIChatMessage] {
    sanitizedMessageScan(messages).messages
  }

  public func validate(
    confirmation: AIOutboundPayloadConfirmation?,
    prepared: AIPreparedOutboundPayload,
    now: Date = Date()
  ) throws {
    guard let confirmation else {
      throw AIOutboundPayloadConfirmationError.confirmationRequired
    }
    guard confirmation.expiresAt == prepared.preview.expiresAt,
      confirmation.confirmedAt >= prepared.preview.createdAt
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
    guard confirmation.confirmedAt <= prepared.preview.expiresAt,
      now <= prepared.preview.expiresAt
    else {
      throw AIOutboundPayloadConfirmationError.expired
    }
    guard confirmation.nonce == prepared.preview.nonce,
      confirmation.fingerprint == prepared.preview.fingerprint
    else {
      throw AIOutboundPayloadConfirmationError.drifted
    }
  }

  public func sanitize(_ text: String) -> AIOutboundPayloadSanitizationResult {
    var sanitized = text
    var stripped = Set<AIOutboundPayloadStrippedField>()
    var sensitive = Set<AIOutboundPayloadSensitiveCategory>()

    sanitized = replacingMatches(
      in: sanitized,
      pattern: #"(?<![A-Za-z0-9._-])/(?:Users|home)/[^\s<>\"']*"#,
      replacement: "[home path removed]"
    ) { _ in
      stripped.insert(.absoluteLocalPath)
      sensitive.insert(.absoluteLocalPath)
      stripped.insert(.homeUsername)
      sensitive.insert(.homeUsername)
    }
    sanitized = replacingMatches(
      in: sanitized,
      pattern:
        #"(?<![A-Za-z0-9._-])/(?:Volumes|private|tmp|var|Applications|Library|System|opt|usr|etc|workspace|root|mnt)/[^\s<>\"']*"#,
      replacement: "[local path removed]"
    ) { _ in
      stripped.insert(.absoluteLocalPath)
      sensitive.insert(.absoluteLocalPath)
    }
    sanitized = replacingMatches(
      in: sanitized,
      pattern: #"(?i)(?:file://(?:localhost)?|[A-Z]:\\|\\\\)[^\s<>\"']+"#,
      replacement: "[local path removed]"
    ) { _ in
      stripped.insert(.absoluteLocalPath)
      sensitive.insert(.absoluteLocalPath)
    }
    sanitized = replacingMatches(
      in: sanitized,
      pattern: #"(?im)^\s*(?:Proxy-)?Authorization\s*[:=]\s*.*$"#,
      replacement: "[secret removed]"
    ) { _ in
      stripped.insert(.credentialLikeSecret)
      sensitive.insert(.credentialLikeSecret)
    }
    sanitized = replacingMatches(
      in: sanitized,
      pattern:
        #"(?i)(?:\"?[A-Z][A-Z0-9_-]*(?:_API_KEY|_ACCESS_TOKEN)\"?|\"?(?:api[_ -]?key|access[_ -]?token|authorization|password|token)\"?)\s*[:=]\s*(?:Bearer\s+)?(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;}\]]+)"#,
      replacement: "[secret removed]"
    ) { _ in
      stripped.insert(.credentialLikeSecret)
      sensitive.insert(.credentialLikeSecret)
    }
    sanitized = replacingMatches(
      in: sanitized,
      pattern: #"(?i)\bBearer\s+(?:\"[^\"\r\n]+\"|'[^'\r\n]+'|[A-Za-z0-9._~+/=-]+)"#,
      replacement: "[secret removed]"
    ) { _ in
      stripped.insert(.credentialLikeSecret)
      sensitive.insert(.credentialLikeSecret)
    }
    sanitized = replacingMatches(
      in: sanitized,
      pattern:
        #"(?im)^\s*(?:[-*]\s*)?(?:command|shell|preview command|build command|命令|预览命令|构建命令)\s*[:：].*$"#,
      replacementForMatch: commandRemovalMarker
    ) { matched in
      stripped.insert(.shellCommand)
      sensitive.insert(.shellCommand)
      let lower = matched.lowercased()
      if lower.contains("preview") || matched.contains("预览") {
        stripped.insert(.previewCommand)
        sensitive.insert(.previewCommand)
      }
      if lower.contains("build") || matched.contains("构建") {
        stripped.insert(.buildCommand)
        sensitive.insert(.buildCommand)
      }
    }
    sanitized = replacingMatches(
      in: sanitized,
      pattern:
        #"(?im)^\s*(?:\$\s*)?(?:cd|pwd|open|xcodebuild|swift\s+(?:build|run|test)|npm\s+(?:run|start)|zola\s+(?:serve|build)|make|cmake)\b.*$"#,
      replacementForMatch: commandRemovalMarker
    ) { matched in
      stripped.insert(.shellCommand)
      sensitive.insert(.shellCommand)
      let lower = matched.lowercased()
      if lower.contains("open ") || lower.contains("serve") || lower.contains("run") {
        stripped.insert(.previewCommand)
        sensitive.insert(.previewCommand)
      }
      if lower.contains("build") || lower.contains("xcodebuild") || lower.contains("make") {
        stripped.insert(.buildCommand)
        sensitive.insert(.buildCommand)
      }
    }

    // Requests are minimized once while they are assembled, then inspected a
    // second time when the exact transport messages are fingerprinted. Keep
    // the hit categories visible in that second pass without retaining the
    // removed value itself.
    if sanitized.contains("[home path removed]") {
      stripped.formUnion([.absoluteLocalPath, .homeUsername])
      sensitive.formUnion([.absoluteLocalPath, .homeUsername])
    } else if sanitized.contains("[local path removed]") {
      stripped.insert(.absoluteLocalPath)
      sensitive.insert(.absoluteLocalPath)
    }
    if sanitized.contains("[secret removed]") {
      stripped.insert(.credentialLikeSecret)
      sensitive.insert(.credentialLikeSecret)
    }
    if sanitized.contains("[local command removed]")
      || sanitized.contains("[preview command removed]")
      || sanitized.contains("[build command removed]")
    {
      stripped.insert(.shellCommand)
      sensitive.insert(.shellCommand)
    }
    if sanitized.contains("[preview command removed]") {
      stripped.insert(.previewCommand)
      sensitive.insert(.previewCommand)
    }
    if sanitized.contains("[build command removed]") {
      stripped.insert(.buildCommand)
      sensitive.insert(.buildCommand)
    }

    return AIOutboundPayloadSanitizationResult(
      text: sanitized,
      strippedFields: stripped,
      sensitiveCategories: sensitive
    )
  }

  public func sanitizedChatMessages(
    _ messages: [AIPublishingChatMessage]
  ) -> [AIPublishingChatMessage] {
    messages.map { message in
      var updated = message
      updated.content = sanitize(message.content).text
      return updated
    }
  }

  public func sanitizedKnowledgeContext(
    _ context: KnowledgeContextSnapshot?
  ) -> KnowledgeContextSnapshot? {
    guard let context else { return nil }
    return KnowledgeContextSnapshot(
      query: sanitize(context.query).text,
      citations: context.citations.map { citation in
        var updated = citation
        updated.title = sanitize(citation.title).text
        updated.authors = citation.authors.map { sanitize($0).text }
        updated.locator = citation.locator.map { sanitize($0).text }
        updated.excerpt = sanitize(citation.excerpt).text
        return updated
      }
    )
  }

  public func sanitizedDraft(_ draft: ArticleDraft) -> ArticleDraft {
    var updated = draft
    updated.title = sanitize(draft.title).text
    updated.slug = sanitize(draft.slug).text
    updated.summary = sanitize(draft.summary).text
    updated.tags = draft.tags.map { sanitize($0).text }
    updated.categories = draft.categories.map { sanitize($0).text }
    updated.bodyMarkdown = sanitize(draft.bodyMarkdown).text
    return updated
  }

  public func sanitizedEditorSelection(
    _ selection: ActiveEditorSelection?
  ) -> ActiveEditorSelection? {
    guard var selection else { return nil }
    selection.selectedText = sanitize(selection.selectedText).text
    return selection
  }

  public func sanitizedProviderConfig(_ config: AIProviderConfig) -> AIProviderConfig {
    var updated = config
    guard var advancedSettings = config.advancedSettings else { return updated }
    advancedSettings.systemPrompt = sanitize(advancedSettings.systemPrompt).text
    updated.advancedSettings = advancedSettings
    return updated
  }

  public func sanitizedDestination(_ endpoint: URL) -> String {
    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
      return "invalid-destination"
    }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string ?? "invalid-destination"
  }

  private func replacingMatches(
    in value: String,
    pattern: String,
    replacement: String,
    onMatch: (String) -> Void
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    for match in expression.matches(in: value, range: range).reversed() {
      guard let swiftRange = Range(match.range, in: value) else { continue }
      onMatch(String(value[swiftRange]))
    }
    return expression.stringByReplacingMatches(
      in: value,
      range: range,
      withTemplate: replacement
    )
  }

  private func replacingMatches(
    in value: String,
    pattern: String,
    replacementForMatch: (String) -> String,
    onMatch: (String) -> Void
  ) -> String {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
    let source = value as NSString
    let mutable = NSMutableString(string: value)
    let range = NSRange(location: 0, length: source.length)
    for match in expression.matches(in: value, range: range).reversed() {
      let matched = source.substring(with: match.range)
      onMatch(matched)
      mutable.replaceCharacters(in: match.range, with: replacementForMatch(matched))
    }
    return mutable as String
  }

  private func commandRemovalMarker(_ matched: String) -> String {
    let lower = matched.lowercased()
    let base: String
    if lower.contains("preview") || matched.contains("预览") || lower.contains("open ")
      || lower.contains("serve") || lower.contains("run")
    {
      base = "[preview command removed]"
    } else if lower.contains("build") || matched.contains("构建")
      || lower.contains("xcodebuild") || lower.contains("make")
    {
      base = "[build command removed]"
    } else {
      base = "[local command removed]"
    }
    let nestedMarkers = [
      "[home path removed]",
      "[local path removed]",
      "[secret removed]",
    ].filter(matched.contains)
    return ([base] + nestedMarkers).joined(separator: " ")
  }

  private func normalizedContextCounts(
    _ counts: [AIOutboundPayloadContextCount],
    messageCount: Int,
    imageCount: Int
  ) -> [AIOutboundPayloadContextCount] {
    var values: [AIOutboundPayloadContextCategory: Int] = [:]
    for item in counts {
      values[item.category, default: 0] += item.count
    }
    if values[.conversationHistory] == nil {
      values[.conversationHistory] = messageCount
    }
    values[.imageAttachment, default: 0] += imageCount
    return AIOutboundPayloadContextCategory.allCases.compactMap { category in
      guard let count = values[category], count > 0 else { return nil }
      return AIOutboundPayloadContextCount(category: category, count: count)
    }
  }

  private func metrics(
    for messages: [AIChatMessage]
  ) -> (textCharacterCount: Int, imageCount: Int, imageByteCount: Int64) {
    var textCount = 0
    var imageCount = 0
    var imageByteCount: Int64 = 0
    for message in messages {
      guard let content = message.content else { continue }
      switch content {
      case .text(let text):
        textCount += text.count
      case .parts(let parts):
        for part in parts {
          if let text = part.text { textCount += text.count }
          guard part.type == .imageURL, let value = part.imageURL?.url else { continue }
          imageCount += 1
          imageByteCount += imagePayloadByteCount(value)
        }
      }
    }
    return (textCount, imageCount, imageByteCount)
  }

  private func imagePayloadByteCount(_ value: String) -> Int64 {
    guard value.hasPrefix("data:"), let comma = value.firstIndex(of: ",") else { return 0 }
    let encoded = value[value.index(after: comma)...]
    let padding = encoded.suffix(2).filter { $0 == "=" }.count
    return Int64(max(0, (encoded.count * 3) / 4 - padding))
  }

  private func fingerprint(
    endpointBinding: String,
    model: String,
    messages: [AIChatMessage],
    contextCounts: [AIOutboundPayloadContextCount],
    contextBindingValues: [String],
    exactEncodedBody: Data?
  ) -> String {
    var data = Data()
    appendFingerprintField(endpointBinding, to: &data)
    appendFingerprintField(model, to: &data)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    if let encoded = try? encoder.encode(messages) {
      data.append(encoded)
    }
    for count in contextCounts {
      appendFingerprintField(count.category.rawValue, to: &data)
      appendFingerprintField(String(count.count), to: &data)
    }
    for value in contextBindingValues {
      appendFingerprintField(value, to: &data)
    }
    if let exactEncodedBody {
      appendFingerprintData(exactEncodedBody, to: &data)
    }
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func appendFingerprintField(_ value: String, to data: inout Data) {
    let bytes = Data(value.utf8)
    var length = UInt64(bytes.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(bytes)
  }

  private func appendFingerprintData(_ value: Data, to data: inout Data) {
    var length = UInt64(value.count).bigEndian
    withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
    data.append(value)
  }

  private func sanitizedMessageScan(
    _ messages: [AIChatMessage]
  ) -> (
    messages: [AIChatMessage],
    strippedFields: Set<AIOutboundPayloadStrippedField>,
    sensitiveCategories: Set<AIOutboundPayloadSensitiveCategory>
  ) {
    var stripped = Set<AIOutboundPayloadStrippedField>()
    var sensitive = Set<AIOutboundPayloadSensitiveCategory>()
    let sanitizedMessages = messages.map { message in
      var updated = message
      updated.content = message.content.map { content in
        switch content {
        case .text(let text):
          let result = sanitize(text)
          stripped.formUnion(result.strippedFields)
          sensitive.formUnion(result.sensitiveCategories)
          return .text(result.text)
        case .parts(let parts):
          return .parts(
            parts.map { part in
              guard part.type == .text, let text = part.text else { return part }
              let result = sanitize(text)
              stripped.formUnion(result.strippedFields)
              sensitive.formUnion(result.sensitiveCategories)
              var sanitizedPart = part
              sanitizedPart.text = result.text
              return sanitizedPart
            })
        }
      }
      if let toolCalls = message.toolCalls {
        updated.toolCalls = toolCalls.map { toolCall in
          var updatedToolCall = toolCall
          let result = sanitize(toolCall.function.arguments)
          updatedToolCall.function.arguments = result.text
          stripped.formUnion(result.strippedFields)
          sensitive.formUnion(result.sensitiveCategories)
          return updatedToolCall
        }
      }
      return updated
    }
    return (sanitizedMessages, stripped, sensitive)
  }

  private func isLoopback(_ endpoint: URL) -> Bool {
    guard let host = endpoint.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
      || host.hasSuffix(".localhost")
  }
}

extension AIPublishingAssistantService {
  func outboundPayload(
    for request: AIChatRequest,
    config: AIProviderConfig,
    privacyService: AIOutboundPayloadPrivacyService,
    transportVariant: AIOutboundPayloadTransportVariant = .stream,
    now: Date = Date(),
    nonce: UUID = UUID()
  ) -> AIPreparedOutboundPayload? {
    guard let endpoint = config.chatCompletionsURL else { return nil }
    let currentModel = request.selectedModel?.nilIfEmpty ?? config.normalizedModel
    let selectedModel = AIChatModelCatalog.model(
      for: request.modelGrade,
      config: config,
      currentModel: currentModel
    )
    let model = config.requestModel(resolving: selectedModel)
    return privacyService.prepare(
      AIOutboundPayloadDescriptor(
        endpoint: endpoint,
        model: model,
        messages: chatMessages(for: request),
        contextCounts: outboundContextCounts(
          references: request.context.explicitContextReferences,
          hasAutomaticKnowledge: request.context.knowledgeContext?.citations.isEmpty == false,
          includesImplicitArticleContext: false,
          conversationMessageCount: request.messages.suffix(12).count
        ),
        contextBindingValues: outboundContextBindingValues(
          references: request.context.explicitContextReferences,
          contextMode: request.context.mode,
          knowledgePolicy: request.context.knowledgePolicy,
          reasoningLevel: request.reasoningLevel,
          modelGrade: request.modelGrade,
          includesImplicitArticleContext: false,
          transportVariant: transportVariant,
          config: config
        )
      ),
      now: now,
      nonce: nonce
    )
  }

  func outboundPayload(
    for request: AIPublishingChatRequest,
    config: AIProviderConfig,
    privacyService: AIOutboundPayloadPrivacyService,
    transportVariant: AIOutboundPayloadTransportVariant = .stream,
    now: Date = Date(),
    nonce: UUID = UUID()
  ) -> AIPreparedOutboundPayload? {
    guard let endpoint = config.chatCompletionsURL else { return nil }
    let currentModel = request.selectedModel?.nilIfEmpty ?? config.normalizedModel
    let selectedModel = AIChatModelCatalog.model(
      for: request.modelGrade,
      config: config,
      currentModel: currentModel
    )
    let model = config.requestModel(resolving: selectedModel)
    return privacyService.prepare(
      AIOutboundPayloadDescriptor(
        endpoint: endpoint,
        model: model,
        messages: chatMessages(for: request),
        contextCounts: outboundContextCounts(
          references: request.explicitContextReferences,
          hasAutomaticKnowledge: request.knowledgeContext?.citations.isEmpty == false,
          includesImplicitArticleContext: request.contextMode == .site,
          conversationMessageCount: request.messages.suffix(12).count
        ),
        contextBindingValues: outboundContextBindingValues(
          references: request.explicitContextReferences,
          contextMode: request.contextMode,
          knowledgePolicy: request.knowledgePolicy,
          reasoningLevel: request.reasoningLevel,
          modelGrade: request.modelGrade,
          includesImplicitArticleContext: request.contextMode == .site,
          transportVariant: transportVariant,
          config: config
        )
      ),
      now: now,
      nonce: nonce
    )
  }

  func outboundContextCounts(
    references: [AIContextReference],
    hasAutomaticKnowledge: Bool,
    includesImplicitArticleContext: Bool,
    conversationMessageCount: Int
  ) -> [AIOutboundPayloadContextCount] {
    var values: [AIOutboundPayloadContextCategory: Int] = [:]
    if conversationMessageCount > 0 {
      values[.conversationHistory] = conversationMessageCount
    }
    if includesImplicitArticleContext {
      values[.currentArticle, default: 0] += 1
      values[.siteProfile, default: 0] += 1
      values[.publishCheck, default: 0] += 1
    }
    for reference in references {
      let category: AIOutboundPayloadContextCategory
      switch reference.kind {
      case .currentSelection: category = .currentSelection
      case .currentArticle: category = .currentArticle
      case .specifiedArticle: category = .specifiedArticle
      case .siteProfile: category = .siteProfile
      case .knowledgeEntry: category = .knowledgeEntry
      case .publishCheck: category = .publishCheck
      }
      values[category, default: 0] += 1
    }
    if hasAutomaticKnowledge {
      values[.automaticKnowledge, default: 0] += 1
    }
    return AIOutboundPayloadContextCategory.allCases.compactMap { category in
      guard let count = values[category], count > 0 else { return nil }
      return AIOutboundPayloadContextCount(category: category, count: count)
    }
  }

  func outboundContextBindingValues(
    references: [AIContextReference],
    contextMode: AIPublishingChatContextMode,
    knowledgePolicy: KnowledgeRetrievalPolicy,
    reasoningLevel: AIChatReasoningLevel,
    modelGrade: AIChatModelGrade,
    includesImplicitArticleContext: Bool,
    transportVariant: AIOutboundPayloadTransportVariant,
    config: AIProviderConfig
  ) -> [String] {
    let advancedSettings = config.resolvedAdvancedSettings
    let temperature = advancedSettings.normalizedTemperature.map { String($0) } ?? ""
    let maximumOutputTokens =
      advancedSettings.normalizedMaximumOutputTokens.map {
        String($0)
      } ?? ""
    var values = [
      "context-mode:\(contextMode.rawValue)",
      "knowledge-policy:\(knowledgePolicy.rawValue)",
      "reasoning-level:\(reasoningLevel.rawValue)",
      "model-grade:\(modelGrade.rawValue)",
      "implicit-article:\(includesImplicitArticleContext)",
      "temperature:\(temperature)",
      "max-output:\(maximumOutputTokens)",
      "reasoning-preference:\(advancedSettings.reasoningPreference.rawValue)",
      "authorization-required:\(config.requiresAPIKey)",
      "transport-variant:\(transportVariant.rawValue)",
    ]
    values.append(
      contentsOf: references.map { reference in
        [
          reference.kind.rawValue,
          reference.resourceID ?? "",
          String(reference.characterCount),
          reference.sourceRange.map { "\($0.location):\($0.length)" } ?? "",
        ].joined(separator: "|")
      })
    return values
  }
}

@MainActor
public final class AIOutboundPayloadApprovalBroker: ObservableObject {
  public static let shared = AIOutboundPayloadApprovalBroker()

  @Published private var pendingRequestsByID: [UUID: AIOutboundPayloadApprovalRequest] = [:]
  @Published private var lastPreviewsByScopeID: [UUID: AIOutboundPayloadPreview] = [:]
  private var continuationsByRequestID:
    [UUID: CheckedContinuation<AIOutboundPayloadApprovalOutcome, Never>] = [:]
  var testingDecisionProvider:
    (@MainActor @Sendable (AIOutboundPayloadPreview) async -> AIOutboundPayloadApprovalDecision)?
  var testingConfirmationDateProvider: (@MainActor @Sendable (AIOutboundPayloadPreview) -> Date)?

  public init() {}

  public func requestApproval(
    for preview: AIOutboundPayloadPreview,
    scopeID: UUID
  ) async -> AIOutboundPayloadApprovalOutcome {
    cancelPendingRequests(for: scopeID)
    lastPreviewsByScopeID[scopeID] = preview
    trimPreviewHistoryIfNeeded()
    if let testingDecisionProvider {
      switch await testingDecisionProvider(preview) {
      case .confirm:
        return confirmedOutcome(for: preview)
      case .cancel:
        return .cancelled
      }
    }
    // Production sends are authorized automatically after the exact,
    // sanitized preview has been recorded. The returned confirmation remains
    // single-use and is still checked for nonce, fingerprint, expiry, and
    // drift immediately before transport. A testing decision provider above
    // is the only supported way to inject cancellation or delayed approval;
    // production must never create a UI continuation for remote payloads.
    return confirmedOutcome(for: preview)
  }

  public func pendingRequest(for scopeID: UUID) -> AIOutboundPayloadApprovalRequest? {
    pendingRequestsByID.values
      .filter { $0.scopeID == scopeID }
      .max { $0.preview.createdAt < $1.preview.createdAt }
  }

  public func lastPreview(for scopeID: UUID) -> AIOutboundPayloadPreview? {
    lastPreviewsByScopeID[scopeID]
  }

  public func confirm(requestID: UUID) {
    resolve(.confirm, requestID: requestID)
  }

  public func cancel(requestID: UUID) {
    resolve(.cancel, requestID: requestID)
  }

  public func cancelPendingRequest() {
    for requestID in Array(pendingRequestsByID.keys) {
      resolve(.cancel, requestID: requestID)
    }
  }

  public func cancelPendingRequests(for scopeID: UUID) {
    let requestIDs = pendingRequestsByID.values
      .filter { $0.scopeID == scopeID }
      .map(\.id)
    for requestID in requestIDs {
      resolve(.cancel, requestID: requestID)
    }
  }

  private func resolve(
    _ decision: AIOutboundPayloadApprovalDecision,
    requestID: UUID
  ) {
    guard let request = pendingRequestsByID.removeValue(forKey: requestID) else { return }
    let continuation = continuationsByRequestID.removeValue(forKey: requestID)
    let outcome: AIOutboundPayloadApprovalOutcome
    switch decision {
    case .confirm:
      outcome = confirmedOutcome(for: request.preview)
    case .cancel:
      outcome = .cancelled
    }
    continuation?.resume(returning: outcome)
  }

  private func confirmedOutcome(
    for preview: AIOutboundPayloadPreview
  ) -> AIOutboundPayloadApprovalOutcome {
    let confirmedAt = testingConfirmationDateProvider?(preview) ?? Date()
    return .confirmed(
      AIOutboundPayloadConfirmation(
        nonce: preview.nonce,
        fingerprint: preview.fingerprint,
        confirmedAt: confirmedAt,
        expiresAt: preview.expiresAt
      )
    )
  }

  private func trimPreviewHistoryIfNeeded() {
    let maximumScopeCount = 64
    guard lastPreviewsByScopeID.count > maximumScopeCount,
      let oldest = lastPreviewsByScopeID.min(by: {
        $0.value.createdAt < $1.value.createdAt
      })
    else { return }
    lastPreviewsByScopeID.removeValue(forKey: oldest.key)
  }

  var pendingRequestCountForTesting: Int {
    pendingRequestsByID.count
  }

  var continuationCountForTesting: Int {
    continuationsByRequestID.count
  }
}
