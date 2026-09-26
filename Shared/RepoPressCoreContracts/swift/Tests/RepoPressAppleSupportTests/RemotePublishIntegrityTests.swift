import Foundation
@testable import RepoPressAppleSupport
import Testing

@Test func remotePublishPreconditionDigestIsStableAcrossFileOrderingAndCodableRoundTrip() throws {
  let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)
  let first = RemotePublishPrecondition(
    repositoryFingerprint: "repository-fingerprint",
    branch: "main",
    packageDigest: "package-digest",
    files: [
      RemotePublishFileExpectation(path: "static/image.webp", expectedState: .absent),
      RemotePublishFileExpectation(path: "content/post.md", expectedState: .blobSHA("blob-a")),
    ],
    capturedAt: capturedAt
  )
  let reordered = RemotePublishPrecondition(
    repositoryFingerprint: first.repositoryFingerprint,
    branch: first.branch,
    packageDigest: first.packageDigest,
    files: first.files.reversed(),
    capturedAt: capturedAt.addingTimeInterval(30)
  )

  #expect(first.digest == reordered.digest)
  #expect(first.digest == "28773c7ffea5495bb37bf60e01867452531a488b894c4c34bf5ebff2482e4851")
  #expect(!first.stableSummary.contains("token"))
  let decoded = try JSONDecoder().decode(
    RemotePublishPrecondition.self,
    from: JSONEncoder().encode(first)
  )
  #expect(decoded == first)
}

@Test func canonicalTranscriptFramesBoundariesAndCollectionCounts() {
  var first = RemotePublishCanonicalTranscript(domain: "RepoPress.Test.v2")
  first.appendString("values")
  first.appendCount(2)
  first.appendString("a")
  first.appendString("bc")

  var shiftedBoundary = RemotePublishCanonicalTranscript(domain: "RepoPress.Test.v2")
  shiftedBoundary.appendString("values")
  shiftedBoundary.appendCount(2)
  shiftedBoundary.appendString("ab")
  shiftedBoundary.appendString("c")

  var changedCount = RemotePublishCanonicalTranscript(domain: "RepoPress.Test.v2")
  changedCount.appendString("values")
  changedCount.appendCount(1)
  changedCount.appendString("a")
  changedCount.appendString("bc")

  var changedDomain = RemotePublishCanonicalTranscript(domain: "RepoPress.Other.v2")
  changedDomain.appendString("values")
  changedDomain.appendCount(2)
  changedDomain.appendString("a")
  changedDomain.appendString("bc")

  #expect(first.digestHex() != shiftedBoundary.digestHex())
  #expect(first.digestHex() != changedCount.digestHex())
  #expect(first.digestHex() != changedDomain.digestHex())
}

@Test func remotePublishPreconditionRequiresExactOutboundPathCoverage() throws {
  let precondition = RemotePublishPrecondition(
    repositoryFingerprint: "repo",
    branch: "main",
    packageDigest: "package",
    files: [
      RemotePublishFileExpectation(path: "content/post.md", expectedState: .absent),
      RemotePublishFileExpectation(path: "static/post@2x.webp", expectedState: .blobSHA("blob")),
    ]
  )

  #expect(throws: Never.self) {
    try precondition.validateBinding(
      repositoryFingerprint: "repo",
      branch: "main",
      packageDigest: "package",
      outboundPaths: ["static/post@2x.webp", "content/post.md"]
    )
  }
  #expect(throws: RemotePublishIntegrityError.outboundPathsMismatch) {
    try precondition.validateBinding(
      repositoryFingerprint: "repo",
      branch: "main",
      packageDigest: "package",
      outboundPaths: ["content/post.md"]
    )
  }
}

@Test func remotePublishPreconditionAllowsUnrelatedRemoteChangesButRejectsTargetChanges() throws {
  let precondition = RemotePublishPrecondition(
    repositoryFingerprint: "repo",
    branch: "main",
    packageDigest: "package",
    files: [
      RemotePublishFileExpectation(path: "content/post.md", expectedState: .blobSHA("expected")),
      RemotePublishFileExpectation(path: "static/new.webp", expectedState: .absent),
    ]
  )

  #expect(throws: Never.self) {
    try precondition.validateRemoteState(remoteBlobSHAsByPath: [
      "content/post.md": "expected",
      "unrelated.txt": "advanced",
    ])
  }
  #expect(throws: RemotePublishIntegrityError.remoteTargetChanged(paths: ["static/new.webp"])) {
    try precondition.validateRemoteState(remoteBlobSHAsByPath: [
      "content/post.md": "expected",
      "static/new.webp": "created-later",
    ])
  }
}

@Test func overrideGrantIsShortLivedBoundAndConsumedExactlyOnce() throws {
  let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
  let precondition = RemotePublishPrecondition(
    repositoryFingerprint: "repo",
    branch: "main",
    packageDigest: "package",
    files: [RemotePublishFileExpectation(path: "post.md", expectedState: .blobSHA("remote"))]
  )
  let grant = RemotePublishOverrideGrant(
    precondition: precondition,
    operationID: "operation-1",
    issuedAt: issuedAt,
    lifetime: 60
  )
  let cappedGrant = RemotePublishOverrideGrant(
    precondition: precondition,
    operationID: "operation-1",
    issuedAt: issuedAt,
    lifetime: 3_600
  )
  #expect(cappedGrant.expiresAt == issuedAt.addingTimeInterval(300))
  let consumed = try grant.consuming(
    precondition: precondition,
    operationID: "operation-1",
    at: issuedAt.addingTimeInterval(30)
  )

  #expect(consumed.consumedAt == issuedAt.addingTimeInterval(30))
  #expect(throws: RemotePublishIntegrityError.overrideGrantConsumed) {
    try consumed.validate(
      precondition: precondition,
      operationID: "operation-1",
      at: issuedAt.addingTimeInterval(31)
    )
  }
  #expect(throws: RemotePublishIntegrityError.overrideGrantExpired) {
    try grant.validate(
      precondition: precondition,
      operationID: "operation-1",
      at: issuedAt.addingTimeInterval(61)
    )
  }

  var changedPackage = precondition
  changedPackage.packageDigest = "other-package"
  #expect(throws: RemotePublishIntegrityError.overrideGrantMismatch) {
    try grant.validate(
      precondition: changedPackage,
      operationID: "operation-1",
      at: issuedAt.addingTimeInterval(1)
    )
  }
  #expect(throws: RemotePublishIntegrityError.overrideGrantMismatch) {
    try grant.validate(
      precondition: precondition,
      operationID: "operation-2",
      at: issuedAt.addingTimeInterval(1)
    )
  }
  #expect(throws: RemotePublishIntegrityError.overrideGrantExpired) {
    try grant.validate(
      precondition: precondition,
      operationID: "operation-1",
      at: issuedAt.addingTimeInterval(-1)
    )
  }
}

@Test func legacyOverrideGrantWithoutOperationIDFailsClosed() throws {
  let precondition = RemotePublishPrecondition(
    repositoryFingerprint: "repo",
    branch: "main",
    packageDigest: "package",
    files: [RemotePublishFileExpectation(path: "post.md", expectedState: .absent)]
  )
  let current = RemotePublishOverrideGrant(
    precondition: precondition,
    operationID: "operation-1",
    issuedAt: Date(timeIntervalSince1970: 1_800_000_000),
    lifetime: 60
  )
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
  )
  object.removeValue(forKey: "operationID")
  let legacy = try JSONDecoder().decode(
    RemotePublishOverrideGrant.self,
    from: JSONSerialization.data(withJSONObject: object)
  )

  #expect(legacy.operationID == nil)
  #expect(throws: RemotePublishIntegrityError.overrideGrantMismatch) {
    try legacy.validate(
      precondition: precondition,
      operationID: "operation-1",
      at: Date(timeIntervalSince1970: 1_800_000_001)
    )
  }
}

@Test func receiptAndUnknownOutcomeRoundTripWithoutPayloadFields() throws {
  let receipt = RemotePublishReceipt(
    operationID: "operation-1",
    provider: "github",
    repositoryFingerprint: "repo",
    targetBranch: "main",
    packageDigest: "package",
    preconditionDigest: "precondition",
    commitSHA: "commit",
    publishedBranch: "review/post",
    fileSHAsByPath: ["content/post.md": "blob-1"]
  )
  let outcome = RemotePublishOutcomeUnknown(
    operationID: receipt.operationID,
    provider: receipt.provider,
    phase: .creatingReviewRequest,
    reason: .transport,
    repositoryFingerprint: receipt.repositoryFingerprint,
    targetBranch: receipt.targetBranch,
    packageDigest: receipt.packageDigest,
    preconditionDigest: receipt.preconditionDigest,
    commitSHA: receipt.commitSHA,
    publishedBranch: receipt.publishedBranch,
    knownReceipt: receipt
  )
  let data = try JSONEncoder().encode(outcome)
  let json = try #require(String(bytes: data, encoding: .utf8))
  var changedReceipt = receipt
  changedReceipt.fileSHAsByPath["content/post.md"] = "blob-2"

  #expect(!json.contains("markdown"))
  #expect(!json.contains("token"))
  #expect(receipt.fileSHAsDigest != changedReceipt.fileSHAsDigest)
  #expect(try JSONDecoder().decode(RemotePublishOutcomeUnknown.self, from: data) == outcome)

  var legacyObject = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
  )
  legacyObject.removeValue(forKey: "fileSHAsByPath")
  let legacyReceipt = try JSONDecoder().decode(
    RemotePublishReceipt.self,
    from: JSONSerialization.data(withJSONObject: legacyObject)
  )
  #expect(legacyReceipt.fileSHAsByPath.isEmpty)
}

@Test func receiptFileSHAsDigestUsesCanonicalV2GoldenVectorAndStableOrdering() {
  let first = RemotePublishReceipt(
    operationID: "operation-1",
    provider: "github",
    repositoryFingerprint: "repo",
    targetBranch: "main",
    packageDigest: "package",
    preconditionDigest: "precondition",
    commitSHA: "commit",
    publishedBranch: "main",
    fileSHAsByPath: [
      "static/image.webp": "blob-b",
      "content/post.md": "blob-a",
    ]
  )
  var reordered = first
  reordered.fileSHAsByPath = [
    "content/post.md": "blob-a",
    "static/image.webp": "blob-b",
  ]

  #expect(first.fileSHAsDigest == reordered.fileSHAsDigest)
  #expect(
    first.fileSHAsDigest
      == "c36095358d52e076a942681e8a2d89ee08ad80cd6a5d2997df46903d64a27642"
  )
}
