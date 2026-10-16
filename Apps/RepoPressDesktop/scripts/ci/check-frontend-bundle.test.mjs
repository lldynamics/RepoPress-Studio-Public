import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "vitest";
import { checkFrontendBundle } from "./check-frontend-bundle.mjs";

function withFixture(manifest, files, run) {
  const root = mkdtempSync(join(tmpdir(), "repopress-bundle-"));
  const distRoot = join(root, "dist");
  try {
    mkdirSync(join(distRoot, ".vite"), { recursive: true });
    writeFileSync(join(distRoot, ".vite/manifest.json"), JSON.stringify(manifest));
    for (const [file, bytes] of Object.entries(files)) {
      const output = join(distRoot, file);
      mkdirSync(resolve(output, ".."), { recursive: true });
      writeFileSync(output, "x".repeat(bytes));
    }
    return run({ distRoot, manifestPath: join(distRoot, ".vite/manifest.json"), requiredLazySurfaces: ["surface"] });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

const normalManifest = {
  "index.html": { file: "assets/entry.js", isEntry: true, dynamicImports: ["surface"] },
  surface: { file: "assets/surface.js", imports: ["vendor"] },
  vendor: { file: "assets/vendor.js" },
};

test("bundle budget accepts one entry and counts a lazy surface static closure", () => {
  const result = withFixture(normalManifest, { "assets/entry.js": 10, "assets/surface.js": 20, "assets/vendor.js": 30 }, (options) => checkFrontendBundle({ ...options, startupBudgetBytes: 10, lazySurfaceBudgetBytes: 50 }));
  assert.equal(result.startupBytes, 10);
  assert.equal(result.lazySurfaceBytes.get("surface"), 50);
});

test("bundle budget fails closed when the manifest is missing", () => {
  const root = mkdtempSync(join(tmpdir(), "repopress-bundle-"));
  try {
    assert.throws(() => checkFrontendBundle({ distRoot: root, manifestPath: join(root, "missing.json"), requiredLazySurfaces: ["surface"] }), /ENOENT/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test("bundle budget rejects ambiguous startup entries", () => {
  const manifest = { ...normalManifest, "admin.html": { file: "assets/admin.js", isEntry: true } };
  withFixture(manifest, { "assets/entry.js": 10, "assets/admin.js": 10, "assets/surface.js": 20, "assets/vendor.js": 30 }, (options) => {
    assert.throws(() => checkFrontendBundle(options), /exactly one startup entry/);
  });
});

test("bundle budget rejects a missing required lazy surface", () => {
  const manifest = { "index.html": { file: "assets/entry.js", isEntry: true } };
  withFixture(manifest, { "assets/entry.js": 10 }, (options) => {
    assert.throws(() => checkFrontendBundle(options), /missing or invalid chunk: surface/);
  });
});

test("bundle budget includes lazy static imports in the surface threshold", () => {
  withFixture(normalManifest, { "assets/entry.js": 10, "assets/surface.js": 60, "assets/vendor.js": 60 }, (options) => {
    assert.throws(() => checkFrontendBundle({ ...options, lazySurfaceBudgetBytes: 100 }), /surface and static imports/);
  });
});

test("bundle budget rejects manifest files that escape dist", () => {
  const manifest = {
    "index.html": { file: "assets/entry.js", isEntry: true, dynamicImports: ["surface"] },
    surface: { file: "../outside.js" },
  };
  withFixture(manifest, { "assets/entry.js": 10 }, (options) => {
    assert.throws(() => checkFrontendBundle(options), /escapes dist/);
  });
});
