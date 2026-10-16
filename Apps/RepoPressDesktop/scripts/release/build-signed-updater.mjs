import { createHash } from "node:crypto";
import { mkdtemp, readdir, rm, stat, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { desktopRoot, updaterConfiguration } from "./updater-config.mjs";

const configuration = updaterConfiguration();
for (const name of [
  "TAURI_SIGNING_PRIVATE_KEY",
  "TAURI_SIGNING_PRIVATE_KEY_PATH",
  "TAURI_SIGNING_PRIVATE_KEY_PASSWORD",
]) {
  if (process.env[name]) {
    throw new Error(`${name} must not be present while building the unsigned updater candidate.`);
  }
}
if (process.argv.includes("--check")) {
  const fingerprint = createHash("sha256").update(configuration.pubkey).digest("hex");
  console.log(
    `Updater build configuration is valid for ${new URL(configuration.endpoint).hostname} (public key SHA-256 ${fingerprint}).`,
  );
  process.exit(0);
}

const temporaryDirectory = await mkdtemp(path.join(os.tmpdir(), "repopress-updater-"));
const temporaryConfig = path.join(temporaryDirectory, "tauri.updater.conf.json");
try {
  await writeFile(temporaryConfig, `${JSON.stringify(configuration.tauri, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  const binary = path.join(
    desktopRoot,
    "node_modules",
    ".bin",
    process.platform === "win32" ? "tauri.cmd" : "tauri",
  );
  const exitCode = await new Promise((resolve, reject) => {
    const child = spawn(
      binary,
      ["build", "--bundles", "appimage", "--config", temporaryConfig],
      {
        cwd: desktopRoot,
        env: {
          ...process.env,
          REPOPRESS_UPDATER_ENDPOINT: configuration.endpoint,
          REPOPRESS_UPDATER_PUBKEY: configuration.pubkey,
          NO_STRIP: process.env.NO_STRIP || "1",
        },
        stdio: "inherit",
      },
    );
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (signal) reject(new Error(`Tauri updater build ended from signal ${signal}.`));
      else resolve(code ?? 1);
    });
  });
  if (exitCode !== 0) throw new Error(`Tauri updater build failed with exit code ${exitCode}.`);

  const bundleDirectory = path.join(desktopRoot, "src-tauri", "target", "release", "bundle", "appimage");
  const files = await readdir(bundleDirectory);
  const appImages = files.filter((file) => file.endsWith(".AppImage"));
  const signatures = files.filter((file) => file.endsWith(".AppImage.sig"));
  if (appImages.length !== 1 || signatures.length !== 0) {
    throw new Error("Expected exactly one unsigned AppImage and no signature after the build.");
  }
  if ((await stat(path.join(bundleDirectory, appImages[0]))).size === 0) {
    throw new Error(`Updater artifact is empty: ${appImages[0]}`);
  }
  await writeFile(path.join(bundleDirectory, "updater-public-key.txt"), `${configuration.pubkey}\n`, {
    encoding: "utf8",
    mode: 0o644,
  });
  console.log(`Unsigned AppImage updater candidate: ${path.join(bundleDirectory, appImages[0])}`);
} finally {
  await rm(temporaryDirectory, { recursive: true, force: true });
}
