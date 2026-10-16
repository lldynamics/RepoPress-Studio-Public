import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { fileURLToPath } from "node:url";
import { parseTauriPublicKey, verifyUpdaterSignature } from "./updater-signature.mjs";

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const tauri = path.join(desktopRoot, "node_modules", ".bin", process.platform === "win32" ? "tauri.cmd" : "tauri");
let fixture;

function replaceTrustedComment(signatureValue, trustedComment) {
  const lines = Buffer.from(signatureValue, "base64").toString("utf8").split("\n");
  lines[2] = `trusted comment: ${trustedComment}`;
  return Buffer.from(lines.join("\n")).toString("base64");
}

beforeAll(() => {
  const directory = mkdtempSync(path.join(os.tmpdir(), "repopress-updater-signature-"));
  const privateKey = path.join(directory, "test-only.key");
  const artifact = path.join(directory, "RepoPress_0.1.0_amd64.AppImage");
  execFileSync(tauri, ["signer", "generate", "--ci", "--write-keys", privateKey], {
    stdio: "ignore",
  });
  writeFileSync(artifact, "test-only AppImage payload\n");
  execFileSync(tauri, ["signer", "sign", "--private-key-path", privateKey, "--password", "", artifact], {
    stdio: "ignore",
  });
  fixture = {
    directory,
    artifactPath: artifact,
    publicKeyValue: readFileSync(`${privateKey}.pub`, "utf8").trim(),
    signatureValue: readFileSync(`${artifact}.sig`, "utf8"),
  };
});

afterAll(() => {
  if (fixture?.directory) rmSync(fixture.directory, { recursive: true });
});

describe("Tauri updater signature verification", () => {
  it("accepts a signature produced by the locked Tauri CLI", async () => {
    const decoded = Buffer.from(fixture.signatureValue, "base64").toString("utf8");
    expect(decoded.split("\n")[2]).toMatch(
      /^trusted comment: timestamp:(?:0|[1-9][0-9]*)\tfile:RepoPress_0\.1\.0_amd64\.AppImage$/u,
    );
    const result = await verifyUpdaterSignature(fixture);
    expect(result).toMatchObject({ algorithm: "ED" });
    expect(result.keyId).toMatch(/^[0-9a-f]{16}$/);
  });

  it("rejects the same signed bytes after the AppImage is copied to a different filename", async () => {
    const renamed = path.join(fixture.directory, "RepoPress_0.1.0_renamed.AppImage");
    copyFileSync(fixture.artifactPath, renamed);
    await expect(
      verifyUpdaterSignature({ ...fixture, artifactPath: renamed }),
    ).rejects.toThrow(/file does not exactly match the artifact filename/);
  });

  it("rejects a modified AppImage", async () => {
    const tamperedDirectory = path.join(fixture.directory, "tampered");
    mkdirSync(tamperedDirectory);
    const tampered = path.join(tamperedDirectory, path.basename(fixture.artifactPath));
    writeFileSync(tampered, "test-only AppImage payload changed\n");
    await expect(
      verifyUpdaterSignature({ ...fixture, artifactPath: tampered }),
    ).rejects.toThrow(/failed Ed25519 verification/);
  });

  it("rejects a different but structurally valid public key", async () => {
    const outer = Buffer.from(fixture.publicKeyValue, "base64").toString("utf8");
    const [comment, packetValue] = outer.trimEnd().split("\n");
    const packet = Buffer.from(packetValue, "base64");
    packet[packet.length - 1] ^= 1;
    const wrongPublicKey = Buffer.from(`${comment}\n${packet.toString("base64")}\n`).toString("base64");
    expect(() => parseTauriPublicKey(wrongPublicKey)).not.toThrow();
    await expect(
      verifyUpdaterSignature({ ...fixture, publicKeyValue: wrongPublicKey }),
    ).rejects.toThrow(/failed Ed25519 verification/);
  });

  it("verifies the Minisign global signature over the trusted comment", async () => {
    const decoded = Buffer.from(fixture.signatureValue, "base64").toString("utf8");
    const timestamp = decoded.match(/trusted comment: timestamp:([0-9]+)\t/u)?.[1];
    expect(timestamp).toBeDefined();
    const changedSignature = replaceTrustedComment(
      fixture.signatureValue,
      `timestamp:${BigInt(timestamp) + 1n}\tfile:${path.basename(fixture.artifactPath)}`,
    );
    await expect(
      verifyUpdaterSignature({ ...fixture, signatureValue: changedSignature }),
    ).rejects.toThrow(/trusted comment failed/);
  });

  it("rejects missing, duplicate, path-like, control-character, and percent-ambiguous file fields", async () => {
    const timestamp = "1788442298";
    for (const trustedComment of [
      `timestamp:${timestamp}`,
      `timestamp:${timestamp}\tfile:RepoPress.AppImage\tfile:RepoPress.AppImage`,
      `timestamp:${timestamp}\tfile:../RepoPress.AppImage`,
      `timestamp:${timestamp}\tfile:directory/RepoPress.AppImage`,
      `timestamp:${timestamp}\tfile:directory\\RepoPress.AppImage`,
      `timestamp:${timestamp}\tfile:RepoPress%2Fother.AppImage`,
      `timestamp:${timestamp}\tfile:RepoPress\u0001.AppImage`,
    ]) {
      await expect(
        verifyUpdaterSignature({
          ...fixture,
          signatureValue: replaceTrustedComment(fixture.signatureValue, trustedComment),
        }),
      ).rejects.toThrow(/trusted comment|file field/);
    }
  });

  it("rejects the previous heuristic-only pseudo key", () => {
    expect(() =>
      parseTauriPublicKey(
        "untrusted comment: minisign public key RWR0dGVzdHB1YmxpY2tleW1hdGVyaWFsMTIzNDU2Nzg5",
      ),
    ).toThrow(/canonical base64/);
  });
});
