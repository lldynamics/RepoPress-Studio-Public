import path from "node:path";
import { fileURLToPath } from "node:url";
import { isIP } from "node:net";
import {
  parseTauriPublicKey,
  validateUpdaterArtifactBasename,
} from "./updater-signature.mjs";

export const desktopRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

export function requiredEnvironment(name, environment = process.env) {
  const value = environment[name]?.trim();
  if (!value) throw new Error(`${name} is required.`);
  return value;
}

export function validatedPublicHttpsUrl(value, label) {
  if (typeof value !== "string" || value.length === 0 || value.length > 8_192) {
    throw new Error(`${label} must be between 1 and 8192 characters.`);
  }
  if (/\p{Cc}|\s/u.test(value)) {
    throw new Error(`${label} contains control characters or unencoded whitespace.`);
  }
  const expanded = value
    .replaceAll("{{target}}", "linux")
    .replaceAll("{{arch}}", "x86_64")
    .replaceAll("{{current_version}}", "0.0.0");
  let url;
  try {
    url = new URL(expanded);
  } catch {
    throw new Error(`${label} must be a valid HTTPS URL.`);
  }
  const hostname = url.hostname.toLowerCase().replace(/\.$/, "").replace(/^\[|\]$/g, "");
  const publicHostnameSyntax =
    hostname.length <= 253 &&
    hostname
      .split(".")
      .every((labelPart) =>
        /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/u.test(labelPart),
      );
  if (
    url.protocol !== "https:" ||
    /^https:\/\/[^/?#]*@/iu.test(expanded) ||
    url.username ||
    url.password ||
    expanded.includes("#") ||
    url.hash ||
    url.port ||
    !hostname ||
    !publicHostnameSyntax ||
    hostname === "localhost" ||
    hostname.endsWith(".localhost") ||
    hostname.endsWith(".local") ||
    !hostname.includes(".") ||
    isIP(hostname) !== 0
  ) {
    throw new Error(`${label} must use a public HTTPS origin without credentials or fragments.`);
  }
  return value;
}

export function validatedUpdaterNotes(value, label = "REPOPRESS_UPDATER_NOTES") {
  if (typeof value !== "string" || /\p{Cc}/u.test(value)) {
    throw new Error(`${label} must not contain control characters.`);
  }
  const notes = value.trim();
  if (!notes || [...notes].length > 4_096) {
    throw new Error(`${label} must be 1-4096 characters.`);
  }
  return notes;
}

export function validatedRfc3339(value, label = "REPOPRESS_UPDATER_PUB_DATE") {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-](\d{2}):(\d{2}))$/u.exec(
    value,
  );
  if (!match) throw new Error(`${label} must be RFC 3339.`);
  const [, yearText, monthText, dayText, hourText, minuteText, secondText, zoneHourText, zoneMinuteText] =
    match;
  const year = Number(yearText);
  const month = Number(monthText);
  const day = Number(dayText);
  const hour = Number(hourText);
  const minute = Number(minuteText);
  const second = Number(secondText);
  const zoneHour = Number(zoneHourText || "0");
  const zoneMinute = Number(zoneMinuteText || "0");
  const leapYear = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (
    month < 1 ||
    month > 12 ||
    day < 1 ||
    day > daysInMonth[month - 1] ||
    hour > 23 ||
    minute > 59 ||
    second > 59 ||
    zoneHour > 23 ||
    zoneMinute > 59
  ) {
    throw new Error(`${label} must be RFC 3339.`);
  }
  return value;
}

export function updaterConfiguration(environment = process.env) {
  const pubkey = requiredEnvironment("REPOPRESS_UPDATER_PUBKEY", environment);
  const endpoint = validatedPublicHttpsUrl(
    requiredEnvironment("REPOPRESS_UPDATER_ENDPOINT", environment),
    "REPOPRESS_UPDATER_ENDPOINT",
  );
  parseTauriPublicKey(pubkey);
  return {
    endpoint,
    pubkey,
    tauri: {
      // The private key is deliberately absent during compilation. The locked
      // Tauri signer signs the completed AppImage in a separate CI job.
      bundle: { createUpdaterArtifacts: false },
      plugins: { updater: { endpoints: [endpoint], pubkey } },
    },
  };
}

export function validateManifestBinding({ version, releaseTag, assetUrl, artifactName }) {
  validateUpdaterArtifactBasename(artifactName);
  if (releaseTag !== `v${version}`) {
    throw new Error(`REPOPRESS_RELEASE_TAG must equal v${version}.`);
  }
  let assetFilename;
  try {
    assetFilename = decodeURIComponent(new URL(assetUrl).pathname.split("/").pop() || "");
  } catch {
    throw new Error("REPOPRESS_UPDATER_APPIMAGE_URL has an invalid encoded filename.");
  }
  if (assetFilename !== artifactName) {
    throw new Error("REPOPRESS_UPDATER_APPIMAGE_URL must name the exact AppImage produced by this run.");
  }
}
