import { describe, expect, it } from "vitest";
import {
  validateReleaseContext,
  validateReleaseRepository,
} from "./check-updater-release.mjs";

function gitFixture({ tagSha, defaultSha, ancestor = true }) {
  return (_repository, arguments_) => {
    if (arguments_[0] === "rev-parse" && arguments_[2] === "refs/tags/v0.1.0^{commit}") {
      return { status: 0, stdout: `${tagSha}\n`, stderr: "" };
    }
    if (arguments_[0] === "rev-parse" && arguments_[2] === "refs/remotes/origin/main^{commit}") {
      return { status: 0, stdout: `${defaultSha}\n`, stderr: "" };
    }
    if (arguments_[0] === "merge-base") {
      return { status: ancestor ? 0 : 1, stdout: "", stderr: "" };
    }
    return { status: 1, stdout: "", stderr: "unexpected test command" };
  };
}

describe("signed updater release policy", () => {
  it("accepts an exact version tag on the origin default branch", () => {
    const releaseSha = "a".repeat(40);
    const context = validateReleaseContext({
      refType: "tag",
      refName: "v0.1.0",
      releaseSha,
      version: "0.1.0",
      defaultBranch: "main",
    });
    expect(() =>
      validateReleaseRepository(
        {
          repository: "/test/repository",
          refName: context.expectedTag,
          releaseSha: context.releaseSha,
          defaultBranch: context.defaultBranch,
        },
        gitFixture({ tagSha: releaseSha, defaultSha: "b".repeat(40) }),
      ),
    ).not.toThrow();
  });

  it("rejects branches and version-mismatched tags before inspecting Git", () => {
    const common = {
      releaseSha: "a".repeat(40),
      version: "0.1.0",
      defaultBranch: "main",
    };
    expect(() => validateReleaseContext({ ...common, refType: "branch", refName: "main" })).toThrow(
      /only be built from tags/,
    );
    expect(() => validateReleaseContext({ ...common, refType: "tag", refName: "v0.2.0" })).toThrow(
      /exactly match/,
    );
  });

  it("rejects a tag commit outside the origin default branch", () => {
    const unrelatedSha = "c".repeat(40);
    expect(() =>
      validateReleaseRepository(
        {
          repository: "/test/repository",
          refName: "v0.1.0",
          releaseSha: unrelatedSha,
          defaultBranch: "main",
        },
        gitFixture({ tagSha: unrelatedSha, defaultSha: "a".repeat(40), ancestor: false }),
      ),
    ).toThrow(/not an ancestor/);
  });

  it("rejects a tag ref that does not resolve to the workflow commit", () => {
    expect(() =>
      validateReleaseRepository(
        {
          repository: "/test/repository",
          refName: "v0.1.0",
          releaseSha: "a".repeat(40),
          defaultBranch: "main",
        },
        gitFixture({ tagSha: "b".repeat(40), defaultSha: "a".repeat(40) }),
      ),
    ).toThrow(/does not resolve to GITHUB_SHA/);
  });
});
