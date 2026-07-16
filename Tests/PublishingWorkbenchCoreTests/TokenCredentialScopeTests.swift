import XCTest
@testable import PublishingWorkbenchCore

@MainActor
final class TokenCredentialScopeTests: XCTestCase {
  func testKeychainScopesKeepRepositoryAndDeploymentTokensSeparate() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.TokenScope",
      accountPrefix: "token-scope",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()

    try tokenStore.saveToken("github-pat", for: profile, scope: .repository(.github))
    try tokenStore.saveToken("vercel-token", for: profile, scope: .deployment(.vercel))

    XCTAssertEqual(try tokenStore.token(for: profile, scope: .repository(.github)), "github-pat")
    XCTAssertEqual(try tokenStore.token(for: profile, scope: .deployment(.vercel)), "vercel-token")
    XCTAssertNil(try tokenStore.token(for: profile, scope: .deployment(.netlify)))
  }

  func testLegacyTokenMigratesOnlyToRequestedScopedCredential() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.TokenMigration",
      accountPrefix: "token-migration",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    try tokenStore.saveToken("legacy-token", for: profile)

    XCTAssertTrue(try tokenStore.migrateLegacyToken(for: profile, to: .repository(.github)))
    XCTAssertEqual(try tokenStore.token(for: profile, scope: .repository(.github)), "legacy-token")
    XCTAssertNil(try tokenStore.token(for: profile))
    XCTAssertNil(try tokenStore.token(for: profile, scope: .deployment(.githubPages)))
  }

  func testRepositoryLegacyMigrationCannotFanOutOrReviveAfterDeletion() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.RepositoryLegacyMove",
      accountPrefix: "repository-legacy-move",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    profile.repositoryProvider = .github
    try tokenStore.saveToken("legacy-repository-token", for: profile)

    XCTAssertNil(try tokenStore.repositoryToken(for: profile))
    XCTAssertFalse(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)

    try tokenStore.saveRepositoryToken("repository-token", for: profile)
    XCTAssertEqual(try tokenStore.repositoryToken(for: profile), "repository-token")
    XCTAssertNil(try tokenStore.token(for: profile))
    XCTAssertTrue(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)

    try tokenStore.deleteRepositoryToken(for: profile)
    XCTAssertFalse(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)
    XCTAssertNil(try tokenStore.repositoryToken(for: profile))

    profile.repositoryProvider = .gitlab
    XCTAssertNil(try tokenStore.repositoryToken(for: profile))
    XCTAssertFalse(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)
    XCTAssertNil(try tokenStore.token(for: profile, scope: .repository(.github)))
    XCTAssertNil(try tokenStore.token(for: profile, scope: .repository(.gitlab)))
  }

  func testRepositoryDeleteAlsoRemovesLegacyCredentialLeftByOlderRelease() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.RepositoryLegacyCleanup",
      accountPrefix: "repository-legacy-cleanup",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    profile.repositoryProvider = .github
    try tokenStore.saveRepositoryToken("scoped-token", for: profile)
    try tokenStore.saveToken("stale-legacy-token", for: profile)

    try tokenStore.deleteRepositoryToken(for: profile)

    XCTAssertNil(try tokenStore.token(for: profile))
    XCTAssertNil(try tokenStore.repositoryToken(for: profile))
    XCTAssertFalse(try tokenStore.repositoryTokenAvailability(for: profile).hasToken)
  }

  func testRepositoryAndDeploymentCredentialsAreBoundToOrigin() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.OriginBinding",
      accountPrefix: "origin-binding",
      inMemory: true
    )
    var profile = SiteProfile.defaultProfile
    profile.id = UUID()
    profile.repositoryProvider = .github
    profile.repositoryBaseURL = "https://api.github.com"
    try tokenStore.saveRepositoryToken("github-token", for: profile)
    try tokenStore.saveToken(
      "vercel-token",
      for: profile,
      scope: .deployment(.vercel),
      originURLText: "https://api.vercel.com"
    )

    XCTAssertEqual(try tokenStore.repositoryToken(for: profile), "github-token")
    profile.repositoryBaseURL = "https://github-enterprise.example/api/v3"
    XCTAssertNil(try tokenStore.repositoryToken(for: profile))
    XCTAssertNil(try tokenStore.token(
      for: profile,
      scope: .deployment(.vercel),
      originURLText: "https://proxy.example"
    ))
    XCTAssertEqual(try tokenStore.token(
      for: profile,
      scope: .deployment(.vercel),
      originURLText: "https://api.vercel.com/v2"
    ), "vercel-token")
  }

  func testInMemoryBackendSupportsConcurrentMultiScopeReadWriteAndDelete() throws {
    let tokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.ConcurrentTokenScope",
      accountPrefix: "concurrent-token-scope",
      inMemory: true
    )
    var concurrentProfile = SiteProfile.defaultProfile
    concurrentProfile.id = UUID()
    let profile = concurrentProfile
    let credentials = [
      ConcurrentTokenCredential(name: "ai", scope: nil),
      ConcurrentTokenCredential(name: "repository-github", scope: .repository(.github)),
      ConcurrentTokenCredential(name: "repository-gitlab", scope: .repository(.gitlab)),
      ConcurrentTokenCredential(name: "deployment-vercel", scope: .deployment(.vercel)),
      ConcurrentTokenCredential(name: "deployment-netlify", scope: .deployment(.netlify)),
    ]
    let failures = ConcurrentTokenFailureRecorder()

    let mixedRoundCount = 160
    DispatchQueue.concurrentPerform(iterations: mixedRoundCount * credentials.count) { operationIndex in
      let credentialIndex = operationIndex % credentials.count
      let round = operationIndex / credentials.count
      let credential = credentials[credentialIndex]
      let token = credential.token(round: round)

      do {
        switch round % 4 {
        case 0:
          try credential.save(token, in: tokenStore, for: profile)
        case 1:
          _ = try credential.read(from: tokenStore, for: profile)
        case 2:
          try credential.delete(from: tokenStore, for: profile)
        default:
          _ = try credential.availability(in: tokenStore, for: profile)
        }

        if let observed = try credential.read(from: tokenStore, for: profile),
           !observed.hasPrefix("\(credential.name)-round-") {
          failures.record("\(credential.name) read unexpected token: \(observed)")
        }
      } catch {
        failures.record("\(credential.name) operation failed: \(error)")
      }
    }
    XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))

    let finalWriteRoundCount = 96
    DispatchQueue.concurrentPerform(iterations: finalWriteRoundCount * credentials.count) { operationIndex in
      let credentialIndex = operationIndex % credentials.count
      let round = operationIndex / credentials.count
      let credential = credentials[credentialIndex]
      do {
        try credential.save(credential.token(round: round), in: tokenStore, for: profile)
      } catch {
        failures.record("\(credential.name) final write failed: \(error)")
      }
    }

    for credential in credentials {
      let writtenTokens = Set((0..<finalWriteRoundCount).map(credential.token(round:)))
      let observed = try XCTUnwrap(credential.read(from: tokenStore, for: profile))
      XCTAssertTrue(writtenTokens.contains(observed), "\(credential.name) ended with a value that was never written")
      XCTAssertTrue(try credential.availability(in: tokenStore, for: profile).hasToken)
    }
    XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))

    let deleteRoundCount = 64
    DispatchQueue.concurrentPerform(iterations: deleteRoundCount * credentials.count) { operationIndex in
      let credential = credentials[operationIndex % credentials.count]
      do {
        try credential.delete(from: tokenStore, for: profile)
      } catch {
        failures.record("\(credential.name) delete failed: \(error)")
      }
    }

    for credential in credentials {
      XCTAssertNil(try credential.read(from: tokenStore, for: profile))
      XCTAssertFalse(try credential.availability(in: tokenStore, for: profile).hasToken)
    }
    XCTAssertTrue(failures.messages.isEmpty, failures.messages.joined(separator: "\n"))
  }

  func testDeploymentAvailabilityDoesNotReuseRepositoryToken() throws {
    let repositoryTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.RepositoryToken",
      accountPrefix: "repository-token",
      inMemory: true
    )
    let deploymentTokenStore = KeychainTokenStore(
      service: "PersonalSitePublisherMac.Tests.DeploymentToken",
      accountPrefix: "deployment-token",
      inMemory: true
    )
    let store = WorkbenchStore(
      persistence: WorkbenchPersistence(fileURL: try temporaryPersistenceURL()),
      repositoryTokenStore: repositoryTokenStore,
      deploymentTokenStore: deploymentTokenStore
    )
    store.updateActiveProfile { profile in
      profile.deploymentProvider = .vercel
      profile.deploymentProjectID = "personal-site"
    }

    store.saveRepositoryAccessToken("github-pat")
    store.refreshDeploymentTokenAvailability()
    XCTAssertFalse(store.deploymentTokenAvailability.hasToken)
    XCTAssertFalse(store.activeDeploymentStatusReadiness.isAPIReady)

    store.saveDeploymentAccessToken("vercel-token")
    XCTAssertTrue(store.deploymentTokenAvailability.hasToken)
    XCTAssertTrue(store.activeDeploymentStatusReadiness.isAPIReady)
  }
}

private struct ConcurrentTokenCredential: Sendable {
  let name: String
  let scope: KeychainTokenScope?

  func token(round: Int) -> String {
    "\(name)-round-\(round)"
  }

  func read(from store: KeychainTokenStore, for profile: SiteProfile) throws -> String? {
    if let scope {
      return try store.token(for: profile, scope: scope)
    }
    return try store.token(for: profile)
  }

  func availability(
    in store: KeychainTokenStore,
    for profile: SiteProfile
  ) throws -> KeychainTokenAvailability {
    if let scope {
      return try store.availability(for: profile, scope: scope)
    }
    return try store.availability(for: profile)
  }

  func save(_ token: String, in store: KeychainTokenStore, for profile: SiteProfile) throws {
    if let scope {
      try store.saveToken(token, for: profile, scope: scope)
    } else {
      try store.saveToken(token, for: profile)
    }
  }

  func delete(from store: KeychainTokenStore, for profile: SiteProfile) throws {
    if let scope {
      try store.deleteToken(for: profile, scope: scope)
    } else {
      try store.deleteToken(for: profile)
    }
  }
}

private final class ConcurrentTokenFailureRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedMessages: [String] = []

  var messages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedMessages
  }

  func record(_ message: String) {
    lock.lock()
    defer { lock.unlock() }
    if recordedMessages.count < 20 {
      recordedMessages.append(message)
    }
  }
}
