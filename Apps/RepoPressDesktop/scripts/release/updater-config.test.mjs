import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import {
  updaterConfiguration,
  validateManifestBinding,
  validatedPublicHttpsUrl,
  validatedRfc3339,
  validatedUpdaterNotes,
} from "./updater-config.mjs";

const validEnvironment = {
  REPOPRESS_UPDATER_PUBKEY:
    "dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IEMxMjNGNDBDNTk3QTlCQ0MKUldUTW0zcFpEUFFqd1lwTjBUVjBNWnlqRUlMWTJJcHlsMlBTSDVJc2gzZ0V0bkFKcnZUMklhZE0K",
  REPOPRESS_UPDATER_ENDPOINT:
    "https://github.com/example/repopress/releases/latest/download/latest.json",
};

describe("signed updater configuration", () => {
  it("keeps the ordinary desktop build launchable with a fail-closed updater config", () => {
    const baseConfig = JSON.parse(
      readFileSync(path.resolve(import.meta.dirname, "../../src-tauri/tauri.conf.json"), "utf8"),
    );

    expect(baseConfig.plugins.updater).toEqual({ endpoints: [], pubkey: "" });
  });

  it("builds a private-key-free Tauri merge config", () => {
    const configuration = updaterConfiguration(validEnvironment);
    const serialized = JSON.stringify(configuration.tauri);

    expect(configuration.tauri.bundle.createUpdaterArtifacts).toBe(false);
    expect(serialized).toContain("github.com");
    expect(serialized).not.toContain("TAURI_SIGNING_PRIVATE_KEY");
  });

  it("rejects loopback, private-network, credentialed and plaintext endpoints", () => {
    for (const endpoint of [
      "http://updates.example.com/latest.json",
      "https://127.0.0.1/latest.json",
      "https://192.168.1.2/latest.json",
      "https://[::1]/latest.json",
      "https://%40updates.example.com/latest.json",
      "https://updates_example.com/latest.json",
      "https://updates.local/latest.json",
      "https://updates.example.com:444/latest.json",
      "https://user:secret@updates.example.com/latest.json",
      "https://@updates.example.com/latest.json",
      "https://updates.example.com/latest.json#candidate",
      "https://updates.example.com/latest.json#",
    ]) {
      expect(() => validatedPublicHttpsUrl(endpoint, "endpoint")).toThrow();
    }
    expect(() =>
      validatedPublicHttpsUrl("https://updates.example.com:443/latest.json", "endpoint"),
    ).not.toThrow();
  });

  it("enforces bounded control-free notes and strict RFC 3339 publication dates", () => {
    expect(validatedUpdaterNotes("  release notes  ")).toBe("release notes");
    expect(() => validatedUpdaterNotes("release\nnotes")).toThrow(/control characters/);
    expect(() => validatedUpdaterNotes("x".repeat(4_097))).toThrow(/1-4096/);
    for (const date of [
      "2026-01-01",
      "2026-01-01 00:00:00Z",
      "2026-02-29T00:00:00Z",
      "2026-01-01T24:00:00Z",
      "2026-01-01T00:00:00",
    ]) {
      expect(() => validatedRfc3339(date)).toThrow(/RFC 3339/);
    }
    expect(validatedRfc3339("2028-02-29T23:59:59.123Z")).toBe(
      "2028-02-29T23:59:59.123Z",
    );
    expect(validatedRfc3339("2026-01-01T00:00:00+08:00")).toBe(
      "2026-01-01T00:00:00+08:00",
    );
  });

  it("rejects placeholder public keys", () => {
    expect(() =>
      updaterConfiguration({ ...validEnvironment, REPOPRESS_UPDATER_PUBKEY: "replace-me-with-public-key-material" }),
    ).toThrow(/canonical base64/i);
  });

  it("binds the manifest tag and encoded URL basename to the unique artifact", () => {
    expect(() =>
      validateManifestBinding({
        version: "0.1.0",
        releaseTag: "v0.1.0",
        assetUrl: "https://downloads.example.com/RepoPress%20Studio_0.1.0_amd64.AppImage",
        artifactName: "RepoPress Studio_0.1.0_amd64.AppImage",
      }),
    ).not.toThrow();
    expect(() =>
      validateManifestBinding({
        version: "0.1.0",
        releaseTag: "v0.2.0",
        assetUrl: "https://downloads.example.com/RepoPress.AppImage",
        artifactName: "RepoPress.AppImage",
      }),
    ).toThrow(/must equal/);
    expect(() =>
      validateManifestBinding({
        version: "0.1.0",
        releaseTag: "v0.1.0",
        assetUrl: "https://downloads.example.com/Other.AppImage",
        artifactName: "RepoPress.AppImage",
      }),
    ).toThrow(/exact AppImage/);
    for (const artifactName of ["../RepoPress.AppImage", "dir\\RepoPress.AppImage", "Repo%2FPress.AppImage"]) {
      expect(() =>
        validateManifestBinding({
          version: "0.1.0",
          releaseTag: "v0.1.0",
          assetUrl: "https://downloads.example.com/RepoPress.AppImage",
          artifactName,
        }),
      ).toThrow(/basename/);
    }
  });
});
