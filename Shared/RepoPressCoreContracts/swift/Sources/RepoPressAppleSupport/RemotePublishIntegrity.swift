import CryptoKit
import Foundation

/// Canonical SHA-256 transcript shared by remote-publish integrity records.
/// Every string/data element is prefixed by an unsigned 64-bit big-endian byte
/// length. Collection sizes are encoded as unsigned 64-bit big-endian values.
public struct RemotePublishCanonicalTranscript: Sendable {
  private var hasher = SHA256()

  public init(domain: String) {
    appendString(domain)
  }

  public mutating func appendString(_ value: String) {
    appendData(Data(value.utf8))
  }

  public mutating func appendData(_ value: Data) {
    appendUInt64(UInt64(value.count))
    hasher.update(data: value)
  }

  public mutating func appendCount(_ count: Int) {
    precondition(count >= 0, "Canonical transcript counts cannot be negative")
    appendUInt64(UInt64(count))
  }

  public mutating func appendUInt64(_ value: UInt64) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { bytes in
      hasher.update(data: Data(bytes))
    }
  }

  public func digestHex() -> String {
    let copy = hasher
    return copy.finalize().map { String(format: "%02x", $0) }.joined()
  }
}

public enum RemotePublishExpectedState: Codable, Hashable, Sendable {
  case absent
  case blobSHA(String)

  private enum CodingKeys: String, CodingKey {
    case kind
    case blobSHA
  }

  private enum Kind: String, Codable {
    case absent
    case blobSHA
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .absent:
      self = .absent
    case .blobSHA:
      self = .blobSHA(try container.decode(String.self, forKey: .blobSHA))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .absent:
      try container.encode(Kind.absent, forKey: .kind)
    case .blobSHA(let value):
      try container.encode(Kind.blobSHA, forKey: .kind)
      try container.encode(value, forKey: .blobSHA)
    }
  }

  fileprivate var canonicalValue: String {
    switch self {
    case .absent:
      return "absent"
    case .blobSHA(let value):
      return "blob:\(value)"
    }
  }
}

public struct RemotePublishFileExpectation: Codable, Hashable, Sendable {
  public var path: String
  public var expectedState: RemotePublishExpectedState

  public init(path: String, expectedState: RemotePublishExpectedState) {
    self.path = path
    self.expectedState = expectedState
  }
}

public enum RemotePublishIntegrityError: Error, LocalizedError, Equatable, Sendable {
  case malformedPrecondition
  case repositoryBindingMismatch
  case branchBindingMismatch
  case packageBindingMismatch
  case outboundPathsMismatch
  case overrideGrantMissing
  case overrideGrantMismatch
  case overrideGrantExpired
  case overrideGrantConsumed
  case remoteTargetChanged(paths: [String])

  public var errorDescription: String? {
    switch self {
    case .malformedPrecondition:
      return "The remote publish precondition is incomplete or ambiguous."
    case .repositoryBindingMismatch:
      return "The remote publish precondition belongs to a different repository."
    case .branchBindingMismatch:
      return "The remote publish precondition belongs to a different branch."
    case .packageBindingMismatch:
      return "The remote publish precondition belongs to a different frozen package."
    case .outboundPathsMismatch:
      return "The remote publish precondition does not cover every outbound path exactly once."
    case .overrideGrantMissing:
      return "A legacy or missing override authorization cannot bypass the remote check."
    case .overrideGrantMismatch:
      return "The override authorization does not match this remote precondition."
    case .overrideGrantExpired:
      return "The override authorization has expired."
    case .overrideGrantConsumed:
      return "The override authorization has already been consumed."
    case .remoteTargetChanged(let paths):
      return "The remote target changed after confirmation: \(paths.joined(separator: ", "))."
    }
  }
}

public struct RemotePublishPrecondition: Codable, Hashable, Sendable {
  public var repositoryFingerprint: String
  public var branch: String
  public var packageDigest: String
  public var files: [RemotePublishFileExpectation]
  public var capturedAt: Date

  public init(
    repositoryFingerprint: String,
    branch: String,
    packageDigest: String,
    files: [RemotePublishFileExpectation],
    capturedAt: Date = Date()
  ) {
    self.repositoryFingerprint = repositoryFingerprint
    self.branch = branch
    self.packageDigest = packageDigest
    self.files = files
    self.capturedAt = capturedAt
  }

  public var digest: String {
    var transcript = RemotePublishCanonicalTranscript(
      domain: "RepoPress.RemotePublishPrecondition.v2"
    )
    transcript.appendString("repositoryFingerprint")
    transcript.appendString(repositoryFingerprint)
    transcript.appendString("branch")
    transcript.appendString(branch)
    transcript.appendString("packageDigest")
    transcript.appendString(packageDigest)
    transcript.appendString("files")
    let orderedFiles = files.sorted(by: Self.fileOrdering)
    transcript.appendCount(orderedFiles.count)
    for file in orderedFiles {
      transcript.appendString("file")
      transcript.appendString(file.path)
      transcript.appendString(file.expectedState.canonicalValue)
    }
    return transcript.digestHex()
  }

  public var stableSummary: String {
    "precondition=\(digest) package=\(packageDigest) branch=\(branch) files=\(files.count)"
  }

  public func validateBinding(
    repositoryFingerprint expectedRepositoryFingerprint: String,
    branch expectedBranch: String,
    packageDigest expectedPackageDigest: String,
    outboundPaths: [String]
  ) throws {
    let cleanRepository = repositoryFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleanPackage = packageDigest.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanRepository.isEmpty, !cleanBranch.isEmpty, !cleanPackage.isEmpty, !files.isEmpty else {
      throw RemotePublishIntegrityError.malformedPrecondition
    }
    guard repositoryFingerprint == expectedRepositoryFingerprint else {
      throw RemotePublishIntegrityError.repositoryBindingMismatch
    }
    guard branch == expectedBranch else {
      throw RemotePublishIntegrityError.branchBindingMismatch
    }
    guard packageDigest == expectedPackageDigest else {
      throw RemotePublishIntegrityError.packageBindingMismatch
    }

    let expectedPaths = files.map(\.path)
    guard Set(expectedPaths).count == expectedPaths.count,
      expectedPaths.allSatisfy(Self.isValidPath),
      files.allSatisfy(Self.hasValidExpectedState),
      Set(expectedPaths) == Set(outboundPaths),
      Set(outboundPaths).count == outboundPaths.count
    else {
      throw RemotePublishIntegrityError.outboundPathsMismatch
    }
  }

  public func changedPaths(remoteBlobSHAsByPath: [String: String]) -> [String] {
    files.compactMap { file in
      let remoteSHA = remoteBlobSHAsByPath[file.path]
      switch file.expectedState {
      case .absent:
        return remoteSHA == nil ? nil : file.path
      case .blobSHA(let expectedSHA):
        return remoteSHA == expectedSHA ? nil : file.path
      }
    }
    .sorted()
  }

  public func validateRemoteState(remoteBlobSHAsByPath: [String: String]) throws {
    let paths = changedPaths(remoteBlobSHAsByPath: remoteBlobSHAsByPath)
    guard paths.isEmpty else {
      throw RemotePublishIntegrityError.remoteTargetChanged(paths: paths)
    }
  }

  private static func isValidPath(_ path: String) -> Bool {
    !path.isEmpty
      && path == path.trimmingCharacters(in: .whitespacesAndNewlines)
      && !path.hasPrefix("/")
      && !path.hasSuffix("/")
      && !path.contains("//")
      && !path.split(separator: "/").contains(".")
      && !path.split(separator: "/").contains("..")
  }

  private static func hasValidExpectedState(_ file: RemotePublishFileExpectation) -> Bool {
    switch file.expectedState {
    case .absent:
      return true
    case .blobSHA(let value):
      return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  private static func fileOrdering(
    _ lhs: RemotePublishFileExpectation,
    _ rhs: RemotePublishFileExpectation
  ) -> Bool {
    if lhs.path == rhs.path {
      return lhs.expectedState.canonicalValue < rhs.expectedState.canonicalValue
    }
    return lhs.path < rhs.path
  }

}

public struct RemotePublishOverrideGrant: Codable, Hashable, Sendable {
  public static let maximumLifetime: TimeInterval = 5 * 60

  public var id: UUID
  /// Optional only so grants written by older builds remain decodable. A nil or
  /// empty value never authorizes a remote operation.
  public var operationID: String?
  public var preconditionDigest: String
  public var repositoryFingerprint: String
  public var branch: String
  public var packageDigest: String
  public var issuedAt: Date
  public var expiresAt: Date
  public var consumedAt: Date?

  public init(
    precondition: RemotePublishPrecondition,
    operationID: String,
    issuedAt: Date = Date(),
    lifetime: TimeInterval = 5 * 60,
    id: UUID = UUID()
  ) {
    self.id = id
    self.operationID = operationID
    preconditionDigest = precondition.digest
    repositoryFingerprint = precondition.repositoryFingerprint
    branch = precondition.branch
    packageDigest = precondition.packageDigest
    self.issuedAt = issuedAt
    expiresAt = issuedAt.addingTimeInterval(min(max(0, lifetime), Self.maximumLifetime))
    consumedAt = nil
  }

  public var stableSummary: String {
    "grant=\(id.uuidString.lowercased()) operation=\(operationID ?? "-") precondition=\(preconditionDigest) expires=\(expiresAt.timeIntervalSince1970) consumed=\(consumedAt != nil)"
  }

  public func validate(
    precondition: RemotePublishPrecondition,
    operationID expectedOperationID: String,
    at date: Date = Date()
  ) throws {
    guard consumedAt == nil else {
      throw RemotePublishIntegrityError.overrideGrantConsumed
    }
    let cleanOperationID = expectedOperationID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanOperationID.isEmpty,
      operationID == cleanOperationID
    else {
      throw RemotePublishIntegrityError.overrideGrantMismatch
    }
    guard expiresAt > issuedAt,
      expiresAt.timeIntervalSince(issuedAt) <= Self.maximumLifetime,
      issuedAt <= date,
      date <= expiresAt
    else {
      throw RemotePublishIntegrityError.overrideGrantExpired
    }
    guard preconditionDigest == precondition.digest,
      repositoryFingerprint == precondition.repositoryFingerprint,
      branch == precondition.branch,
      packageDigest == precondition.packageDigest
    else {
      throw RemotePublishIntegrityError.overrideGrantMismatch
    }
  }

  public func consuming(
    precondition: RemotePublishPrecondition,
    operationID: String,
    at date: Date = Date()
  ) throws -> RemotePublishOverrideGrant {
    try validate(precondition: precondition, operationID: operationID, at: date)
    var consumed = self
    consumed.consumedAt = date
    return consumed
  }
}

public enum RemotePublishOperationPhase: String, Codable, Hashable, Sendable {
  case validatingPrecondition
  case creatingCommit
  case updatingBranch
  case creatingBranch
  case readingPublishedFiles
  case creatingReviewRequest
}

public struct RemotePublishReceipt: Codable, Hashable, Sendable {
  public var operationID: String
  public var provider: String
  public var repositoryFingerprint: String
  public var targetBranch: String
  public var packageDigest: String
  public var preconditionDigest: String
  public var commitSHA: String
  public var publishedBranch: String
  public var reviewNumber: Int?
  /// Exact immutable blob baseline produced by this operation. An empty map is
  /// accepted only while decoding a legacy receipt and fails the application gate.
  public var fileSHAsByPath: [String: String]
  public var receivedAt: Date

  public init(
    operationID: String,
    provider: String,
    repositoryFingerprint: String,
    targetBranch: String,
    packageDigest: String,
    preconditionDigest: String,
    commitSHA: String,
    publishedBranch: String,
    reviewNumber: Int? = nil,
    fileSHAsByPath: [String: String] = [:],
    receivedAt: Date = Date()
  ) {
    self.operationID = operationID
    self.provider = provider
    self.repositoryFingerprint = repositoryFingerprint
    self.targetBranch = targetBranch
    self.packageDigest = packageDigest
    self.preconditionDigest = preconditionDigest
    self.commitSHA = commitSHA
    self.publishedBranch = publishedBranch
    self.reviewNumber = reviewNumber
    self.fileSHAsByPath = fileSHAsByPath
    self.receivedAt = receivedAt
  }

  private enum CodingKeys: String, CodingKey {
    case operationID
    case provider
    case repositoryFingerprint
    case targetBranch
    case packageDigest
    case preconditionDigest
    case commitSHA
    case publishedBranch
    case reviewNumber
    case fileSHAsByPath
    case receivedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    operationID = try container.decode(String.self, forKey: .operationID)
    provider = try container.decode(String.self, forKey: .provider)
    repositoryFingerprint = try container.decode(String.self, forKey: .repositoryFingerprint)
    targetBranch = try container.decode(String.self, forKey: .targetBranch)
    packageDigest = try container.decode(String.self, forKey: .packageDigest)
    preconditionDigest = try container.decode(String.self, forKey: .preconditionDigest)
    commitSHA = try container.decode(String.self, forKey: .commitSHA)
    publishedBranch = try container.decode(String.self, forKey: .publishedBranch)
    reviewNumber = try container.decodeIfPresent(Int.self, forKey: .reviewNumber)
    fileSHAsByPath = try container.decodeIfPresent(
      [String: String].self,
      forKey: .fileSHAsByPath
    ) ?? [:]
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
  }

  public var fileSHAsDigest: String {
    var transcript = RemotePublishCanonicalTranscript(
      domain: "RepoPress.RemotePublishReceipt.FileSHAs.v2"
    )
    transcript.appendString("fileSHAsByPath")
    let orderedFileSHAs = fileSHAsByPath.sorted(by: { $0.key < $1.key })
    transcript.appendCount(orderedFileSHAs.count)
    for (path, sha) in orderedFileSHAs {
      transcript.appendString("file")
      transcript.appendString(path)
      transcript.appendString(sha)
    }
    return transcript.digestHex()
  }

  public var stableSummary: String {
    "operation=\(operationID) provider=\(provider) commit=\(commitSHA) branch=\(publishedBranch) review=\(reviewNumber.map(String.init) ?? "-") files=\(fileSHAsDigest)"
  }
}

public enum RemotePublishOutcomeUnknownReason: String, Codable, Hashable, Sendable {
  case transport
  case timeout
  case cancellation
  case invalidResponse
  case serverError
  case postEffectFailure
}

public struct RemotePublishOutcomeUnknown: Codable, Hashable, Sendable {
  public var operationID: String
  public var provider: String
  public var phase: RemotePublishOperationPhase
  public var reason: RemotePublishOutcomeUnknownReason
  public var repositoryFingerprint: String
  public var targetBranch: String
  public var packageDigest: String
  public var preconditionDigest: String
  public var commitSHA: String?
  public var publishedBranch: String?
  public var reviewNumber: Int?
  /// Provider-reported file facts retained for reconciliation. They are not a
  /// trusted baseline unless an independently validated receipt binds them.
  public var observedFileSHAsByPath: [String: String]?
  /// Raw provider receipt retained when the application gate rejected it. It is
  /// evidence for manual reconciliation, never an authorization baseline.
  public var observedReceipt: RemotePublishReceipt?
  public var knownReceipt: RemotePublishReceipt?
  public var occurredAt: Date

  public init(
    operationID: String,
    provider: String,
    phase: RemotePublishOperationPhase,
    reason: RemotePublishOutcomeUnknownReason,
    repositoryFingerprint: String,
    targetBranch: String,
    packageDigest: String,
    preconditionDigest: String,
    commitSHA: String? = nil,
    publishedBranch: String? = nil,
    reviewNumber: Int? = nil,
    observedFileSHAsByPath: [String: String]? = nil,
    observedReceipt: RemotePublishReceipt? = nil,
    knownReceipt: RemotePublishReceipt? = nil,
    occurredAt: Date = Date()
  ) {
    self.operationID = operationID
    self.provider = provider
    self.phase = phase
    self.reason = reason
    self.repositoryFingerprint = repositoryFingerprint
    self.targetBranch = targetBranch
    self.packageDigest = packageDigest
    self.preconditionDigest = preconditionDigest
    self.commitSHA = commitSHA
    self.publishedBranch = publishedBranch
    self.reviewNumber = reviewNumber
    self.observedFileSHAsByPath = observedFileSHAsByPath
    self.observedReceipt = observedReceipt
    self.knownReceipt = knownReceipt
    self.occurredAt = occurredAt
  }

  public var stableSummary: String {
    "operation=\(operationID) provider=\(provider) phase=\(phase.rawValue) reason=\(reason.rawValue) commit=\(commitSHA ?? "-") branch=\(publishedBranch ?? targetBranch) review=\(reviewNumber.map(String.init) ?? "-")"
  }
}

public struct RemotePublishOutcomeUnknownError: Error, LocalizedError, Sendable {
  public var outcome: RemotePublishOutcomeUnknown

  public init(_ outcome: RemotePublishOutcomeUnknown) {
    self.outcome = outcome
  }

  public var errorDescription: String? {
    "The remote publish outcome is unknown and must be reconciled before retrying (\(outcome.stableSummary))."
  }
}
