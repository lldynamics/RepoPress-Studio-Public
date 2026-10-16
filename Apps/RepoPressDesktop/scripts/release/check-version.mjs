import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const read = (file) => fs.readFileSync(path.join(desktopRoot, file), "utf8");

const packageManifest = JSON.parse(read("package.json"));
const packageLock = JSON.parse(read("package-lock.json"));
const tauriConfig = JSON.parse(read("src-tauri/tauri.conf.json"));
const cargoManifest = read("src-tauri/Cargo.toml");

const packageStart = cargoManifest.indexOf("[package]");
const nextSection = packageStart >= 0 ? cargoManifest.indexOf("\n[", packageStart + "[package]".length) : -1;
const packageBody = packageStart >= 0 ? cargoManifest.slice(packageStart, nextSection >= 0 ? nextSection : undefined) : "";
const cargoVersion = packageBody.match(/^version\s*=\s*["']([^"']+)["']\s*$/m)?.[1];
const versions = {
  "package.json": packageManifest.version,
  "package-lock.json": packageLock.version,
  "package-lock.json packages[\"\"]": packageLock.packages?.[""]?.version,
  "src-tauri/Cargo.toml": cargoVersion,
  "src-tauri/tauri.conf.json": tauriConfig.version,
};

const missing = Object.entries(versions).filter(([, version]) => typeof version !== "string" || version.length === 0);
if (missing.length > 0) {
  console.error(`Missing version in ${missing.map(([file]) => file).join(", ")}`);
  process.exit(1);
}

const uniqueVersions = new Set(Object.values(versions));
if (uniqueVersions.size !== 1) {
  console.error("Desktop version mismatch:");
  for (const [file, version] of Object.entries(versions)) console.error(`  ${file}: ${version}`);
  process.exit(1);
}

console.log(`Desktop version consistent: ${[...uniqueVersions][0]}`);
