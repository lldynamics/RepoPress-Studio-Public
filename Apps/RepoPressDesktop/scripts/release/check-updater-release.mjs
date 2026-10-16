import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const repositoryRoot = path.resolve(desktopRoot, "../..");

export function expectedReleaseTag(version) {
  if (typeof version !== "string" || !/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error("Desktop package version is not a supported semantic version.");
  }
  return `v${version}`;
}

export function validateReleaseContext({ refType, refName, releaseSha, version, defaultBranch }) {
  const expectedTag = expectedReleaseTag(version);
  if (refType !== "tag") throw new Error("Signed updater candidates can only be built from tags.");
  if (refName !== expectedTag) {
    throw new Error(`Release tag must exactly match desktop version: expected ${expectedTag}.`);
  }
  if (!/^[0-9a-f]{40,64}$/i.test(releaseSha ?? "")) {
    throw new Error("Release commit must be an explicit Git object id.");
  }
  if (
    typeof defaultBranch !== "string" ||
    !defaultBranch ||
    /[\0-\x20~^:?*[\\]/.test(defaultBranch) ||
    defaultBranch.startsWith("-") ||
    defaultBranch.includes("..") ||
    defaultBranch.includes("@{") ||
    defaultBranch.includes("//") ||
    defaultBranch.endsWith("/") ||
    defaultBranch.endsWith(".") ||
    defaultBranch === "@" ||
    defaultBranch
      .split("/")
      .some((component) => component.startsWith(".") || component.endsWith(".lock"))
  ) {
    throw new Error("Repository default branch is missing or invalid.");
  }
  return { expectedTag, releaseSha: releaseSha.toLowerCase(), defaultBranch };
}

function git(repository, arguments_) {
  return spawnSync("git", ["-C", repository, ...arguments_], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
  });
}

function resolvedCommit(repository, revision, label, runGit) {
  const result = runGit(repository, ["rev-parse", "--verify", `${revision}^{commit}`]);
  if (result.status !== 0) throw new Error(`${label} is unavailable in the checked-out Git history.`);
  return result.stdout.trim().toLowerCase();
}

export function validateReleaseRepository(
  { repository, refName, releaseSha, defaultBranch },
  runGit = git,
) {
  const tagCommit = resolvedCommit(repository, `refs/tags/${refName}`, "Release tag", runGit);
  if (tagCommit !== releaseSha.toLowerCase()) {
    throw new Error("Release tag does not resolve to GITHUB_SHA.");
  }
  const defaultRevision = `refs/remotes/origin/${defaultBranch}`;
  resolvedCommit(repository, defaultRevision, "Origin default branch", runGit);
  const ancestry = runGit(repository, ["merge-base", "--is-ancestor", releaseSha, defaultRevision]);
  if (ancestry.status !== 0) {
    throw new Error("Release tag commit is not an ancestor of the origin default branch.");
  }
}

export function validateUpdaterRelease(environment = process.env, options = {}) {
  const packageManifest = JSON.parse(readFileSync(path.join(desktopRoot, "package.json"), "utf8"));
  const context = validateReleaseContext({
    refType: environment.GITHUB_REF_TYPE,
    refName: environment.GITHUB_REF_NAME,
    releaseSha: environment.GITHUB_SHA,
    version: packageManifest.version,
    defaultBranch: environment.REPOPRESS_DEFAULT_BRANCH,
  });
  validateReleaseRepository({
    repository: options.repository ?? repositoryRoot,
    refName: environment.GITHUB_REF_NAME,
    releaseSha: context.releaseSha,
    defaultBranch: context.defaultBranch,
  });
  return context;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    const context = validateUpdaterRelease();
    console.log(
      `Updater release policy passed for ${context.expectedTag} on origin/${context.defaultBranch}.`,
    );
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
