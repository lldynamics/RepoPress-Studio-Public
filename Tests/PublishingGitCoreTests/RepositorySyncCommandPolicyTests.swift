import XCTest

@testable import PublishingGitCore

final class RepositorySyncCommandPolicyTests: XCTestCase {
  func testReturnsNilWhenRootPathIsEmpty() {
    let result = RepositorySyncCommandPolicy().plan(
      for: input(rootPath: " ", hasGitDirectory: nil)
    )

    XCTAssertNil(result)
  }

  func testSelectsScanAndRepositoryStateDecisions() {
    let policy = RepositorySyncCommandPolicy()

    let scanRequired = policy.plan(
      for: input(rootPath: "/tmp/site", hasGitDirectory: nil)
    )
    XCTAssertEqual(scanRequired?.decision, .scanRequired)
    XCTAssertEqual(
      scanRequired?.commands,
      ["cd '/tmp/site'", "git status --short --branch"]
    )

    let missingGit = policy.plan(
      for: input(rootPath: "/tmp/site", hasGitDirectory: false)
    )
    XCTAssertEqual(missingGit?.decision, .missingGitDirectory)
    XCTAssertEqual(
      missingGit?.commands,
      ["cd '/tmp/site'", "git status --short --branch"]
    )

    let unknownBranch = policy.plan(
      for: input(rootPath: "/tmp/site", hasGitDirectory: true)
    )
    XCTAssertEqual(unknownBranch?.decision, .branchUnknown)
    XCTAssertEqual(
      unknownBranch?.commands,
      [
        "cd '/tmp/site'",
        "git status --short --branch",
        "git remote -v",
      ]
    )
  }

  func testSelectsDetachedAndMissingUpstreamDecisions() {
    let policy = RepositorySyncCommandPolicy()

    let detached = policy.plan(
      for: input(
        rootPath: "/tmp/site",
        hasGitDirectory: true,
        preferredBranch: " release ",
        branchStatus: .init(branchName: nil, upstreamName: nil, isDetached: true)
      )
    )
    XCTAssertEqual(detached?.decision, .detachedHead(fallbackBranch: "release"))
    XCTAssertEqual(
      detached?.commands,
      [
        "cd '/tmp/site'",
        "git status --short --branch",
        "git switch 'release'",
      ]
    )

    let missingUpstream = policy.plan(
      for: input(
        rootPath: "/tmp/site",
        hasGitDirectory: true,
        preferredBranch: "fallback",
        branchStatus: .init(branchName: "feature/read-me", upstreamName: nil)
      )
    )
    XCTAssertEqual(
      missingUpstream?.decision,
      .missingUpstream(branch: "feature/read-me")
    )
    XCTAssertEqual(
      missingUpstream?.commands,
      [
        "cd '/tmp/site'",
        "git status --short --branch",
        "git fetch --prune",
        "git branch --set-upstream-to='origin/feature/read-me' 'feature/read-me'",
      ]
    )
  }

  func testSelectsDivergedBehindAheadAndSynchronizedDecisions() {
    let policy = RepositorySyncCommandPolicy()

    let diverged = policy.plan(
      for: input(
        rootPath: "/tmp/site",
        hasGitDirectory: true,
        branchStatus: .init(
          branchName: "main",
          upstreamName: "origin/main",
          aheadCount: 2,
          behindCount: 3
        )
      )
    )
    XCTAssertEqual(diverged?.decision, .diverged(aheadCount: 2, behindCount: 3))
    XCTAssertEqual(
      diverged?.commands,
      [
        "cd '/tmp/site'",
        "git fetch --prune",
        "git status --short --branch",
        "git pull --ff-only",
      ]
    )

    let behind = policy.plan(
      for: input(
        rootPath: "/tmp/site",
        hasGitDirectory: true,
        branchStatus: .init(
          branchName: "main",
          upstreamName: "origin/main",
          behindCount: 3
        )
      )
    )
    XCTAssertEqual(behind?.decision, .behind(behindCount: 3))
    XCTAssertEqual(
      behind?.commands,
      ["cd '/tmp/site'", "git fetch --prune", "git pull --ff-only"]
    )

    let ahead = policy.plan(
      for: input(
        rootPath: "/tmp/site",
        hasGitDirectory: true,
        branchStatus: .init(
          branchName: "main",
          upstreamName: "origin/main",
          aheadCount: 2
        )
      )
    )
    XCTAssertEqual(ahead?.decision, .ahead(aheadCount: 2))
    XCTAssertEqual(
      ahead?.commands,
      ["cd '/tmp/site'", "git status --short --branch", "git push"]
    )

    let synchronized = policy.plan(
      for: input(
        rootPath: "/tmp/site",
        hasGitDirectory: true,
        branchStatus: .init(branchName: "main", upstreamName: "origin/main")
      )
    )
    XCTAssertEqual(synchronized?.decision, .synchronized)
    XCTAssertEqual(
      synchronized?.commands,
      ["cd '/tmp/site'", "git status --short --branch"]
    )
  }

  func testQuotesRootAndBranchAsSinglePOSIXArguments() {
    let result = RepositorySyncCommandPolicy().plan(
      for: input(
        rootPath: "/tmp/$(touch /tmp/should-not-run)",
        hasGitDirectory: true,
        preferredBranch: "main; echo bad\n$(id)",
        branchStatus: .init(branchName: nil, upstreamName: nil, isDetached: true)
      )
    )

    XCTAssertEqual(
      result?.commands,
      [
        "cd '/tmp/$(touch /tmp/should-not-run)'",
        "git status --short --branch",
        "git switch 'main; echo bad\n$(id)'",
      ]
    )
  }

  private func input(
    rootPath: String?,
    hasGitDirectory: Bool?,
    preferredBranch: String? = "main",
    branchStatus: RepositoryBranchStatus? = nil
  ) -> RepositorySyncCommandInput {
    RepositorySyncCommandInput(
      rootPath: rootPath,
      hasGitDirectory: hasGitDirectory,
      preferredBranch: preferredBranch,
      branchStatus: branchStatus
    )
  }
}
