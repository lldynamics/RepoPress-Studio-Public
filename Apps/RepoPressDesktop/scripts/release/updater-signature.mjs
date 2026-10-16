import { createHash, createPublicKey, verify as verifyEd25519 } from "node:crypto";
import { createReadStream } from "node:fs";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { TextDecoder } from "node:util";

const PUBLIC_KEY_BYTES = 42;
const SIGNATURE_PACKET_BYTES = 74;
const ED25519_SIGNATURE_BYTES = 64;
const TRUSTED_COMMENT_PREFIX = "trusted comment: ";
const TRUSTED_TIMESTAMP_PREFIX = "timestamp:";
const TRUSTED_FILE_PREFIX = "file:";
const MAX_U64 = 18_446_744_073_709_551_615n;
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function canonicalBase64(value, label, maximumLength) {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > maximumLength ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)
  ) {
    throw new Error(`${label} must be canonical base64.`);
  }
  const decoded = Buffer.from(value, "base64");
  if (decoded.toString("base64") !== value) {
    throw new Error(`${label} must be canonical base64.`);
  }
  return decoded;
}

function decodedText(value, label, maximumLength) {
  const bytes = canonicalBase64(value, label, maximumLength);
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error(`${label} must contain UTF-8 minisign text.`);
  }
}

function exactLines(text, count, label) {
  if (text.includes("\r") || text.includes("\0")) {
    throw new Error(`${label} contains forbidden control characters.`);
  }
  const normalized = text.endsWith("\n") ? text.slice(0, -1) : text;
  const lines = normalized.split("\n");
  if (lines.length !== count || lines.some((line) => line.length === 0)) {
    throw new Error(`${label} must contain exactly ${count} non-empty lines.`);
  }
  return lines;
}

function supportedAlgorithm(packet, label) {
  const algorithm = packet.subarray(0, 2).toString("ascii");
  if (algorithm !== "Ed" && algorithm !== "ED") {
    throw new Error(`${label} uses an unsupported minisign algorithm.`);
  }
  return algorithm;
}

export function validateUpdaterArtifactBasename(value, label = "Updater artifact filename") {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value === "." ||
    value === ".." ||
    /[\\/%]/u.test(value) ||
    /\p{Cc}/u.test(value)
  ) {
    throw new Error(
      `${label} must be a non-empty basename without path separators, percent signs, or control characters.`,
    );
  }
  return value;
}

function parseTrustedComment(value) {
  const fields = value.split("\t");
  if (fields.length !== 2) {
    throw new Error(
      "Tauri updater trusted comment must contain exactly timestamp and file fields separated by one tab.",
    );
  }
  const [timestampField, fileField] = fields;
  if (
    !timestampField.startsWith(TRUSTED_TIMESTAMP_PREFIX) ||
    !fileField.startsWith(TRUSTED_FILE_PREFIX)
  ) {
    throw new Error("Tauri updater trusted comment fields are invalid or out of order.");
  }
  const timestamp = timestampField.slice(TRUSTED_TIMESTAMP_PREFIX.length);
  if (!/^(?:0|[1-9][0-9]{0,19})$/u.test(timestamp) || BigInt(timestamp) > MAX_U64) {
    throw new Error("Tauri updater trusted comment timestamp is not a canonical unsigned integer.");
  }
  const fileName = validateUpdaterArtifactBasename(
    fileField.slice(TRUSTED_FILE_PREFIX.length),
    "Tauri updater trusted comment file field",
  );
  return { fileName, timestamp };
}

export function parseTauriPublicKey(value) {
  const text = decodedText(value, "Tauri updater public key", 8_192);
  const [comment, encodedPacket] = exactLines(text, 2, "Tauri updater public key");
  if (!comment.startsWith("untrusted comment: minisign public key")) {
    throw new Error("Tauri updater public key has an invalid minisign comment.");
  }
  const packet = canonicalBase64(encodedPacket, "Minisign public key packet", 256);
  if (packet.length !== PUBLIC_KEY_BYTES) {
    throw new Error("Minisign public key packet must be exactly 42 bytes.");
  }
  supportedAlgorithm(packet, "Minisign public key");
  const keyId = packet.subarray(2, 10);
  const rawKey = packet.subarray(10);
  const key = createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, rawKey]),
    format: "der",
    type: "spki",
  });
  return { key, keyId: Buffer.from(keyId), keyIdHex: keyId.toString("hex") };
}

export function parseTauriSignature(value) {
  const text = decodedText(value, "Tauri updater signature", 65_536);
  const [untrustedComment, encodedPacket, trustedCommentLine, encodedGlobalSignature] = exactLines(
    text,
    4,
    "Tauri updater signature",
  );
  if (!untrustedComment.startsWith("untrusted comment:")) {
    throw new Error("Tauri updater signature has an invalid untrusted comment.");
  }
  if (!trustedCommentLine.startsWith(TRUSTED_COMMENT_PREFIX)) {
    throw new Error("Tauri updater signature has an invalid trusted comment.");
  }
  const packet = canonicalBase64(encodedPacket, "Minisign signature packet", 256);
  if (packet.length !== SIGNATURE_PACKET_BYTES) {
    throw new Error("Minisign signature packet must be exactly 74 bytes.");
  }
  const algorithm = supportedAlgorithm(packet, "Minisign signature");
  if (algorithm !== "ED") {
    throw new Error("Legacy non-prehashed updater signatures are not accepted by the release gate.");
  }
  const globalSignature = canonicalBase64(
    encodedGlobalSignature,
    "Minisign global signature",
    256,
  );
  if (globalSignature.length !== ED25519_SIGNATURE_BYTES) {
    throw new Error("Minisign global signature must be exactly 64 bytes.");
  }
  const trustedComment = trustedCommentLine.slice(TRUSTED_COMMENT_PREFIX.length);
  const trusted = parseTrustedComment(trustedComment);
  return {
    algorithm,
    keyId: Buffer.from(packet.subarray(2, 10)),
    signature: Buffer.from(packet.subarray(10)),
    trustedComment,
    trustedFileName: trusted.fileName,
    trustedTimestamp: trusted.timestamp,
    globalSignature,
  };
}

async function blake2b512(file) {
  const digest = createHash("blake2b512");
  for await (const chunk of createReadStream(file)) digest.update(chunk);
  return digest.digest();
}

export async function verifyUpdaterSignature({ artifactPath, publicKeyValue, signatureValue }) {
  const publicKey = parseTauriPublicKey(publicKeyValue.trim());
  const signature = parseTauriSignature(signatureValue);
  if (!publicKey.keyId.equals(signature.keyId)) {
    throw new Error("Updater signature key id does not match the configured public key.");
  }

  const globalMessage = Buffer.concat([
    signature.signature,
    Buffer.from(signature.trustedComment, "utf8"),
  ]);
  if (!verifyEd25519(null, globalMessage, publicKey.key, signature.globalSignature)) {
    throw new Error("Updater signature trusted comment failed Ed25519 verification.");
  }

  const artifactName = validateUpdaterArtifactBasename(path.basename(artifactPath));
  if (signature.trustedFileName !== artifactName) {
    throw new Error("Updater signature trusted comment file does not exactly match the artifact filename.");
  }

  const artifactMessage = await blake2b512(artifactPath);
  if (!verifyEd25519(null, artifactMessage, publicKey.key, signature.signature)) {
    throw new Error("Updater artifact failed Ed25519 verification.");
  }
  return { keyId: publicKey.keyIdHex, algorithm: signature.algorithm };
}

function commandLineArguments(values) {
  const result = {};
  for (let index = 0; index < values.length; index += 2) {
    const name = values[index];
    const value = values[index + 1];
    if (!name?.startsWith("--") || value === undefined) {
      throw new Error("Usage: updater-signature.mjs --artifact FILE --signature FILE --public-key FILE");
    }
    result[name.slice(2)] = value;
  }
  return result;
}

async function main() {
  const options = commandLineArguments(process.argv.slice(2));
  if (!options.artifact || !options.signature || !options["public-key"]) {
    throw new Error("Usage: updater-signature.mjs --artifact FILE --signature FILE --public-key FILE");
  }
  const [signatureValue, publicKeyValue] = await Promise.all([
    readFile(options.signature, "utf8"),
    readFile(options["public-key"], "utf8"),
  ]);
  const verified = await verifyUpdaterSignature({
    artifactPath: options.artifact,
    signatureValue,
    publicKeyValue,
  });
  process.stdout.write(
    `${JSON.stringify({ artifact: path.basename(options.artifact), ...verified })}\n`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
