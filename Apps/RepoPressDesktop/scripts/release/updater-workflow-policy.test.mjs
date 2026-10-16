import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";

const workflow = readFileSync(
  path.resolve(import.meta.dirname, "../../../../.github/workflows/tauri-linux-updater.yml"),
  "utf8",
);
const capability = JSON.parse(
  readFileSync(
    path.resolve(import.meta.dirname, "../../src-tauri/capabilities/default.json"),
    "utf8",
  ),
);

describe("signed updater workflow secret boundary", () => {
  it("gates signing behind policy, an isolated job, and the signing environment", () => {
    expect(workflow).toContain("needs: release-policy");
    expect(workflow).toContain("needs: unsigned-appimage");
    expect(workflow).toContain("environment: linux-release-signing");
    expect(workflow).toContain("npm ci --ignore-scripts");
  });

  it("remains a manual, read-only candidate workflow with full unsigned tests and final validation", () => {
    expect(workflow).toMatch(/^on:\n  workflow_dispatch:\n\npermissions:\n  contents: read$/mu);
    expect(workflow).not.toMatch(/\b(?:push|pull_request|schedule):/u);
    expect(workflow).not.toMatch(/contents:\s*write|releases:\s*write/u);
    expect(workflow).not.toMatch(/gh\s+release|create-release|upload-release-asset|softprops/u);

    const unsignedJob = workflow.slice(
      workflow.indexOf("  unsigned-appimage:"),
      workflow.indexOf("  sign-appimage:"),
    );
    expect(unsignedJob).toContain("npm test -- --run");
    expect(unsignedJob).toContain("bash scripts/ci/test-linux-ci-scripts.sh");
    expect(unsignedJob).toContain("cargo test --manifest-path src-tauri/Cargo.toml --locked");
    expect(unsignedJob).not.toContain("TAURI_SIGNING_PRIVATE_KEY");

    const signJob = workflow.slice(workflow.indexOf("  sign-appimage:"));
    const manifestIndex = signJob.indexOf("npm run manifest:updater");
    const validatorIndex = signJob.indexOf("scripts/ci/validate-updater-manifest.py");
    const uploadIndex = signJob.indexOf("Upload signed updater candidate for release review");
    expect(manifestIndex).toBeGreaterThan(0);
    expect(validatorIndex).toBeGreaterThan(manifestIndex);
    expect(uploadIndex).toBeGreaterThan(validatorIndex);
  });

  it("only exposes signing secrets inside the unique signer step", () => {
    const unsignedJob = workflow.slice(
      workflow.indexOf("  unsigned-appimage:"),
      workflow.indexOf("  sign-appimage:"),
    );
    expect(unsignedJob).not.toContain("secrets.");
    expect(unsignedJob).not.toContain("TAURI_SIGNING_PRIVATE_KEY");

    const signerStepStart = workflow.indexOf("      - name: Sign the unique AppImage");
    const signerStepEnd = workflow.indexOf("      - name: Generate tag-bound updater manifest");
    const signerStep = workflow.slice(signerStepStart, signerStepEnd);
    expect(signerStepStart).toBeGreaterThan(0);
    expect(signerStep).toContain("secrets.TAURI_SIGNING_PRIVATE_KEY");
    expect(signerStep).toContain("node_modules/.bin/tauri signer sign");
    expect(
      `${workflow.slice(0, signerStepStart)}${workflow.slice(signerStepEnd)}`,
    ).not.toContain("${{ secrets.");
    expect(workflow.match(/secrets\.TAURI_SIGNING_PRIVATE_KEY/g)).toHaveLength(2);
    expect(workflow.match(/node_modules\/\.bin\/tauri signer sign/g)).toHaveLength(1);
  });

  it("denies every direct updater plugin operation to the webview", () => {
    const permissions = capability.permissions;
    expect(permissions).toEqual(expect.arrayContaining([
      "updater:deny-check",
      "updater:deny-download",
      "updater:deny-install",
      "updater:deny-download-and-install",
    ]));
    expect(permissions).not.toContain("updater:default");
    expect(permissions.filter((permission) => permission.startsWith("updater:allow-"))).toEqual([]);
  });
});
