import Foundation

private final class AIChatTransportCache: @unchecked Sendable {
  private struct Entry {
    let transport: AIChatTransport
    var lastAccess: UInt64
  }

  private static let maximumEntryCount = 8

  private let lock = NSLock()
  private var entries: [String: Entry] = [:]
  private var accessCounter: UInt64 = 0

  func transport(
    proxyURL: String?,
    firstByteTimeout: TimeInterval,
    resourceTimeout: TimeInterval
  ) throws -> AIChatTransport {
    let normalizedProxy: CredentialSafeProxyConfiguration?
    let validatedProxyURL: String?
    if let proxyURL {
      let trimmed = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
      validatedProxyURL = trimmed.nilIfEmpty
      normalizedProxy =
        trimmed.isEmpty
        ? nil
        : try CredentialSafeURLSession.validatedProxyConfiguration(trimmed)
    } else {
      validatedProxyURL = nil
      normalizedProxy = nil
    }
    let proxyKey =
      normalizedProxy.map {
        "\($0.scheme)://\($0.host):\($0.port)"
      } ?? "direct"
    let key = "\(proxyKey)|first:\(firstByteTimeout)|resource:\(resourceTimeout)"

    lock.lock()
    defer { lock.unlock() }
    accessCounter &+= 1
    if var entry = entries[key] {
      entry.lastAccess = accessCounter
      entries[key] = entry
      return entry.transport
    }

    let transport = try URLSessionAIChatTransport.makeValidated(
      firstByteTimeout: firstByteTimeout,
      resourceTimeout: resourceTimeout,
      proxyURL: validatedProxyURL
    )
    if entries.count >= Self.maximumEntryCount,
      let oldestKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key
    {
      entries.removeValue(forKey: oldestKey)
    }
    entries[key] = Entry(transport: transport, lastAccess: accessCounter)
    return transport
  }
}

public struct AIChatCompletionClient: Sendable {
  static let maximumSSEEventByteCount = 2 * 1_024 * 1_024

  let transport: AIChatTransport?
  let encoder: SerializedJSONEncoder
  let decoder: SerializedJSONDecoder
  let networkRecoveryPolicy: AIChatNetworkRecoveryPolicy
  let codexAppServerChatService: any CodexAppServerChatServing
  let codexAppServerRequestAuthorizer: (any CodexAppServerRequestAuthorizing)?
  private let transportCache: AIChatTransportCache

  public init(
    transport: AIChatTransport? = nil,
    encoder: JSONEncoder = JSONEncoder(),
    decoder: JSONDecoder = JSONDecoder(),
    networkRecoveryPolicy: AIChatNetworkRecoveryPolicy = .default,
    codexAppServerChatService: (any CodexAppServerChatServing)? = nil,
    codexAppServerRequestAuthorizer: (any CodexAppServerRequestAuthorizing)? = nil
  ) {
    // Do not allocate an idle URLSession here. A default transport is created
    // only for a request, after its profile proxy has been strictly validated.
    self.transport = transport
    encoder.outputFormatting.insert(.sortedKeys)
    self.encoder = SerializedJSONEncoder(encoder)
    self.decoder = SerializedJSONDecoder(decoder)
    self.networkRecoveryPolicy = networkRecoveryPolicy
    self.codexAppServerChatService = codexAppServerChatService ?? CodexAppServerClient.shared
    self.codexAppServerRequestAuthorizer = codexAppServerRequestAuthorizer
    self.transportCache = AIChatTransportCache()
  }

  /// Rebinds only the Codex account authorization dependency while preserving
  /// the caller's transport, codecs, retry policy, and app-server service.
  /// WorkbenchAIStore uses this to inject its existing consent store.
  func withCodexAppServerRequestAuthorizer(
    _ authorizer: (any CodexAppServerRequestAuthorizing)?
  ) -> AIChatCompletionClient {
    AIChatCompletionClient(
      transport: transport,
      encoder: encoder,
      decoder: decoder,
      networkRecoveryPolicy: networkRecoveryPolicy,
      codexAppServerChatService: codexAppServerChatService,
      codexAppServerRequestAuthorizer: authorizer
    )
  }

  private init(
    transport: AIChatTransport?,
    encoder: SerializedJSONEncoder,
    decoder: SerializedJSONDecoder,
    networkRecoveryPolicy: AIChatNetworkRecoveryPolicy,
    codexAppServerChatService: any CodexAppServerChatServing,
    codexAppServerRequestAuthorizer: (any CodexAppServerRequestAuthorizing)?
  ) {
    self.transport = transport
    self.encoder = encoder
    self.decoder = decoder
    self.networkRecoveryPolicy = networkRecoveryPolicy
    self.codexAppServerChatService = codexAppServerChatService
    self.codexAppServerRequestAuthorizer = codexAppServerRequestAuthorizer
    self.transportCache = AIChatTransportCache()
  }

  /// Returns the caller-provided transport unchanged, or creates one bound to
  /// the selected profile's proxy. Keeping the factory at the request boundary
  /// prevents a client shared by multiple profiles from accidentally reusing a
  /// session configured for another profile. A malformed proxy fails before a
  /// request can fall back to a direct connection.
  func transport(for config: AIProviderConfig) throws -> AIChatTransport {
    if let transport {
      return transport
    }
    do {
      return try transportCache.transport(
        proxyURL: config.resolvedAdvancedSettings.proxyURL,
        firstByteTimeout: networkRecoveryPolicy.firstByteTimeout,
        resourceTimeout: networkRecoveryPolicy.resourceTimeout
      )
    } catch {
      throw AIChatCompletionClientError.invalidProxyURL
    }
  }
}
