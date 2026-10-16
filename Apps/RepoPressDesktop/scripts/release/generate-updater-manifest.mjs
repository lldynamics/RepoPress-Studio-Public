import { randomUUID } from "node:crypto";
import { readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import {
  desktopRoot,
  requiredEnvironment,
  validateManifestBinding,
  validatedPublicHttpsUrl,
  validatedRfc3339,
  validatedUpdaterNotes,
} from "./updater-config.mjs";
import { parseTauriSignature } from "./updater-signature.mjs";

const assetUrl = validatedPublicHttpsUrl(
  requiredEnvironment("REPOPRESS_UPDATER_APPIMAGE_URL"),
  "REPOPRESS_UPDATER_APPIMAGE_URL",
);
const bundleDirectory = path.join(desktopRoot, "src-tauri", "target", "release", "bundle", "appimage");
const files = await readdir(bundleDirectory);
const appImages = files.filter((file) => file.endsWith(".AppImage"));
const signatures = files.filter((file) => file.endsWith(".AppImage.sig"));
if (appImages.length !== 1 || signatures.length !== 1) {
  throw new Error("Expected exactly one AppImage and one AppImage.sig before writing latest.json.");
}
if (signatures[0] !== `${appImages[0]}.sig`) {
  throw new Error("The updater signature filename must exactly match the AppImage filename.");
}
if ((await stat(path.join(bundleDirectory, appImages[0]))).size === 0) {
  throw new Error("The AppImage updater artifact is empty.");
}
const signature = await readFile(path.join(bundleDirectory, signatures[0]), "utf8");
const parsedSignature = parseTauriSignature(signature);
if (parsedSignature.trustedFileName !== appImages[0]) {
  throw new Error("The updater signature trusted comment must name the exact AppImage.");
}
const packageManifest = JSON.parse(await readFile(path.join(desktopRoot, "package.json"), "utf8"));
const releaseTag = requiredEnvironment("REPOPRESS_RELEASE_TAG");
validateManifestBinding({
  version: packageManifest.version,
  releaseTag,
  assetUrl,
  artifactName: appImages[0],
});
const pubDate = validatedRfc3339(
  process.env.REPOPRESS_UPDATER_PUB_DATE || new Date().toISOString(),
);
const notes = validatedUpdaterNotes(
  process.env.REPOPRESS_UPDATER_NOTES || "RepoPress Studio Linux update",
);

const manifest = {
  version: packageManifest.version,
  notes,
  pub_date: pubDate,
  platforms: {
    "linux-x86_64": { signature, url: assetUrl },
  },
};
const destination = path.join(bundleDirectory, "latest.json");
const temporary = path.join(bundleDirectory, `.latest.json.${randomUUID()}.tmp`);
try {
  await writeFile(temporary, `${JSON.stringify(manifest, null, 2)}\n`, {
    encoding: "utf8",
    flag: "wx",
    mode: 0o644,
  });
  await rename(temporary, destination);
} finally {
  await rm(temporary, { force: true });
}
console.log(`Updater manifest: ${destination}`);
