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
