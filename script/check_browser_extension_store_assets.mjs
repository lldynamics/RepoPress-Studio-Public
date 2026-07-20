#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const ASSET_DIR = path.join(ROOT_DIR, "docs", "browser-extension-store-assets");
const manifest = JSON.parse(await fs.readFile(path.join(ASSET_DIR, "asset-manifest.json"), "utf8"));
const extensionVersion = JSON.parse(
  await fs.readFile(path.join(ROOT_DIR, "BrowserExtension", "manifest.json"), "utf8")
).version;

const expected = new Map();
for (const locale of ["zh-CN", "en-US"]) {
  for (const [filename, width, height, kind] of [
    ["store-icon-128.png", 128, 128, "store-icon"],
    ["edge-logo-300x300.png", 300, 300, "edge-logo"],
    ["screenshot-01-capture.png", 1280, 800, "store-screenshot"],
    ["screenshot-02-preview.png", 1280, 800, "store-screenshot"],
    ["screenshot-03-library.png", 1280, 800, "store-screenshot"],
    ["promo-small-440x280.png", 440, 280, "small-promo"],
    ["promo-marquee-1400x560.png", 1400, 560, "marquee-promo"]
  ]) expected.set(`${locale}/${filename}`, { locale, width, height, kind });
}

assert.equal(manifest.schemaVersion, 1, "unsupported asset manifest schema");
assert.equal(manifest.generationMode, "deterministic", "asset generation must be deterministic");
assert.equal(manifest.extensionVersion, extensionVersion, "asset and extension versions differ");
assert.match(manifest.privacy, /example\.com/i, "asset privacy statement must name synthetic source");
assert.equal(manifest.assets?.length, expected.size, "asset manifest has a missing or unexpected deliverable");

const observed = new Set();
for (const asset of manifest.assets) {
  assert.ok(expected.has(asset.filename), `unexpected asset: ${asset.filename}`);
  assert.ok(!observed.has(asset.filename), `duplicate asset: ${asset.filename}`);
  observed.add(asset.filename);
  const specification = expected.get(asset.filename);
  assert.equal(asset.locale, specification.locale, `${asset.filename}: wrong locale`);
  assert.equal(asset.kind, specification.kind, `${asset.filename}: wrong kind`);
  assert.equal(asset.width, specification.width, `${asset.filename}: wrong manifest width`);
  assert.equal(asset.height, specification.height, `${asset.filename}: wrong manifest height`);

  const filePath = path.join(ASSET_DIR, asset.filename);
  const bytes = await fs.readFile(filePath);
  assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a", `${asset.filename}: not PNG`);
  assert.equal(bytes.readUInt32BE(16), specification.width, `${asset.filename}: wrong PNG width`);
  assert.equal(bytes.readUInt32BE(20), specification.height, `${asset.filename}: wrong PNG height`);
  assert.equal(
    crypto.createHash("sha256").update(bytes).digest("hex"),
    asset.sha256,
    `${asset.filename}: SHA-256 mismatch`
  );
}

assert.deepEqual(observed, new Set(expected.keys()), "asset set does not match required matrix");
console.log(`Browser extension store assets: ${observed.size} files verified for ${extensionVersion}`);
