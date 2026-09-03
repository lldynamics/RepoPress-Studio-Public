import XCTest
@testable import PublishingWorkbenchCore

final class RepositorySyncCommandBuilderTests: XCTestCase {
  func testPlansRebaseAutostashFallbackForDivergedBranch() {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/tmp/My Site"
    let report = report(
      branchStatus: RepositoryBranchStatus(
        branchName: "main",
        upstreamName: "origin/main",
        aheadCount: 2,
        behindCount: 3
      )
    )

    let plan = RepositorySyncCommandBuilder().plan(report: report, profile: profile)

    XCTAssertEqual(plan?.title, "先处理分叉")
    XCTAssertEqual(
      plan?.commands,
      [
        "cd '/tmp/My Site'",
        "git fetch --prune",
        "git status --short --branch",
        "git pull --rebase --autostash",
      ]
    )
    XCTAssertTrue(plan?.summary.contains("本地领先 2，落后 3") == true)
    XCTAssertTrue(plan?.notes.first?.contains("变基同步审阅") == true)
    XCTAssertTrue(plan?.notes.last?.contains("不要直接强制推送") == true)
  }

  func testPlansSwitchBackForDetachedHead() {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/tmp/site"
    profile.branch = "release"
    let report = report(
      branchStatus: RepositoryBranchStatus(
        branchName: nil,
        upstreamName: nil,
        isDetached: true
      )
    )

    let plan = RepositorySyncCommandBuilder().plan(report: report, profile: profile)

    XCTAssertEqual(plan?.title, "切回发布分支")
    XCTAssertEqual(plan?.commands.last, "git switch 'release'")
  }

  func testPlansUpstreamSetupWithoutExecutingIt() {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/tmp/site"
    let report = report(
      branchStatus: RepositoryBranchStatus(
        branchName: "main",
        upstreamName: nil
      )
    )

    let plan = RepositorySyncCommandBuilder().plan(report: report, profile: profile)

    XCTAssertEqual(plan?.title, "设置上游分支")
    XCTAssertTrue(plan?.commands.contains("git fetch --prune") == true)
    XCTAssertTrue(plan?.commands.contains("git branch --set-upstream-to='origin/main' 'main'") == true)
  }

  func testPlansStatusOnlyWhenBranchIsSynchronized() {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/tmp/site"
    let report = report(
      branchStatus: RepositoryBranchStatus(
        branchName: "main",
        upstreamName: "origin/main"
      )
    )

    let plan = RepositorySyncCommandBuilder().plan(report: report, profile: profile)

    XCTAssertEqual(plan?.title, "分支已同步")
    XCTAssertEqual(plan?.commands, ["cd '/tmp/site'", "git status --short --branch"])
  }

  func testQuotesHostileBranchAndRootValuesAsSinglePOSIXArguments() {
    var profile = SiteProfile.defaultProfile
    profile.localRepositoryRootPath = "/tmp/$(touch /tmp/should-not-run)"
    profile.branch = "main; echo bad\n$(id)"
    let report = report(branchStatus: .init(branchName: nil, upstreamName: nil, isDetached: true))

    let plan = RepositorySyncCommandBuilder().plan(report: report, profile: profile)

    XCTAssertEqual(plan?.commands.first, "cd '/tmp/$(touch /tmp/should-not-run)'")
    XCTAssertEqual(plan?.commands.last, "git switch 'main; echo bad\n$(id)'")
  }

  private func report(branchStatus: RepositoryBranchStatus?) -> RepositoryScanReport {
    RepositoryScanReport(
      rootPath: "/tmp/site",
      detectedKind: .zola,
      expectedKind: .zola,
      hasGitDirectory: true,
      contentRootExists: true,
      assetRootExists: true,
      markdownFileCount: 0,
      imageFileCount: 0,
      branchStatus: branchStatus,
      changedFiles: [],
      preflightIssues: []
    )
  }
}
