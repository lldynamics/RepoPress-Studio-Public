import Testing

@testable import PublishingGitCore

struct RepositorySyncCommandPolicyTests {
  @Test
  func returnsNilWhenRootPathIsEmpty() {
    let result = RepositorySyncCommandPolicy().plan(
      for: input(rootPath: " ", hasGitDirectory: nil)
    )

    #expect(result == nil)
  }

  @Test(arguments: repositorySyncPolicyCases)
  fileprivate func selectsExpectedDecisionAndCommands(for scenario: RepositorySyncPolicyCase) {
    let result = RepositorySyncCommandPolicy().plan(for: scenario.input)

    #expect(result?.decision == scenario.decision)
    #expect(result?.commands == scenario.commands)
  }

  @Test
  func quotesRootAndBranchAsSinglePOSIXArguments() {
    let result = RepositorySyncCommandPolicy().plan(
      for: input(
        rootPath: "/tmp/$(touch /tmp/should-not-run)",
        hasGitDirectory: true,
        preferredBranch: "main; echo bad\n$(id)",
        branchStatus: .init(branchName: nil, upstreamName: nil, isDetached: true)
      )
    )

    #expect(
      result?.commands == [
        "cd '/tmp/$(touch /tmp/should-not-run)'",
        "git status --short --branch",
        "git switch 'main; echo bad\n$(id)'",
      ]
    )
  }
}

private struct RepositorySyncPolicyCase: Sendable {
  let input: RepositorySyncCommandInput
  let decision: RepositorySyncCommandDecision
  let commands: [String]
}

private let repositorySyncPolicyCases: [RepositorySyncPolicyCase] = [
  RepositorySyncPolicyCase(
    input: input(rootPath: "/tmp/site", hasGitDirectory: nil),
    decision: .scanRequired,
    commands: ["cd '/tmp/site'", "git status --short --branch"]
  ),
  RepositorySyncPolicyCase(
    input: input(rootPath: "/tmp/site", hasGitDirectory: false),
    decision: .missingGitDirectory,
    commands: ["cd '/tmp/site'", "git status --short --branch"]
  ),
  RepositorySyncPolicyCase(
    input: input(rootPath: "/tmp/site", hasGitDirectory: true),
    decision: .branchUnknown,
    commands: [
      "cd '/tmp/site'",
      "git status --short --branch",
      "git remote -v",
    ]
  ),
  RepositorySyncPolicyCase(
    input: input(
      rootPath: "/tmp/site",
      hasGitDirectory: true,
      preferredBranch: " release ",
      branchStatus: .init(branchName: nil, upstreamName: nil, isDetached: true)
    ),
    decision: .detachedHead(fallbackBranch: "release"),
    commands: [
      "cd '/tmp/site'",
      "git status --short --branch",
      "git switch 'release'",
    ]
  ),
  RepositorySyncPolicyCase(
    input: input(
      rootPath: "/tmp/site",
      hasGitDirectory: true,
      preferredBranch: "fallback",
      branchStatus: .init(branchName: "feature/read-me", upstreamName: nil)
    ),
    decision: .missingUpstream(branch: "feature/read-me"),
    commands: [
      "cd '/tmp/site'",
      "git status --short --branch",
      "git fetch --prune",
      "git branch --set-upstream-to='origin/feature/read-me' 'feature/read-me'",
    ]
  ),
  RepositorySyncPolicyCase(
    input: input(
      rootPath: "/tmp/site",
      hasGitDirectory: true,
      branchStatus: .init(
        branchName: "main",
        upstreamName: "origin/main",
        aheadCount: 2,
        behindCount: 3
      )
    ),
    decision: .diverged(aheadCount: 2, behindCount: 3),
    commands: [
      "cd '/tmp/site'",
      "git fetch --prune",
      "git status --short --branch",
      "git pull --rebase --autostash",
    ]
  ),
  RepositorySyncPolicyCase(
    input: input(
      rootPath: "/tmp/site",
      hasGitDirectory: true,
      branchStatus: .init(
        branchName: "main",
        upstreamName: "origin/main",
        behindCount: 3
      )
    ),
    decision: .behind(behindCount: 3),
    commands: ["cd '/tmp/site'", "git fetch --prune", "git pull --ff-only"]
  ),
  RepositorySyncPolicyCase(
    input: input(
      rootPath: "/tmp/site",
      hasGitDirectory: true,
      branchStatus: .init(
        branchName: "main",
        upstreamName: "origin/main",
        aheadCount: 2
      )
    ),
    decision: .ahead(aheadCount: 2),
    commands: ["cd '/tmp/site'", "git status --short --branch", "git push"]
  ),
  RepositorySyncPolicyCase(
    input: input(
      rootPath: "/tmp/site",
      hasGitDirectory: true,
      branchStatus: .init(branchName: "main", upstreamName: "origin/main")
    ),
    decision: .synchronized,
    commands: ["cd '/tmp/site'", "git status --short --branch"]
  ),
]

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
