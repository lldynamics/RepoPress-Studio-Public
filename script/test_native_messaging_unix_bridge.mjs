import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { constants } from "node:fs";
import { access, mkdtemp, readFile, rm } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const protocol = JSON.parse(await readFile(
  path.join(root, "BrowserExtension", "browser-extension-protocol.json"),
  "utf8"
));
const nativeProtocol = protocol.nativeMessaging;

const hostPath = process.argv[2];
if (!hostPath) {
  throw new Error("usage: node script/test_native_messaging_unix_bridge.mjs <host-executable>");
}
await access(hostPath, constants.X_OK);

const directory = await mkdtemp(path.join(tmpdir(), "knowledge-native-bridge-"));
const socketPath = path.join(directory, "bridge.sock");
const token = "a".repeat(64);
let receivedRequest;

function completeHTTPRequest(buffer) {
  const headerEnd = buffer.indexOf("\r\n\r\n");
  if (headerEnd < 0) return false;
  const header = buffer.subarray(0, headerEnd).toString("utf8");
  const contentLengthLine = header
    .split("\r\n")
    .find((line) => line.toLowerCase().startsWith("content-length:"));
  assert.ok(contentLengthLine, "native bridge request omitted Content-Length");
  const contentLength = Number(contentLengthLine.split(":", 2)[1].trim());
  assert.ok(Number.isSafeInteger(contentLength) && contentLength >= 0);
  return buffer.length >= headerEnd + 4 + contentLength;
}

const bridge = createServer((socket) => {
  const chunks = [];
  let responded = false;
  socket.on("data", (chunk) => {
    if (responded) return;
    chunks.push(chunk);
    const request = Buffer.concat(chunks);
    if (!completeHTTPRequest(request)) return;
    responded = true;
    receivedRequest = request.toString("utf8");
    const payload = Buffer.from(JSON.stringify({
      code: "invalid-token",
      error: "invalid token"
    }));
    const headers = Buffer.from(
      "HTTP/1.1 401 Unauthorized\r\n" +
      "Content-Type: application/json\r\n" +
      `Content-Length: ${payload.length}\r\n` +
      "Connection: close\r\n\r\n"
    );
    const response = Buffer.concat([headers, payload]);
    const split = Math.floor(response.length / 2);
    socket.write(response.subarray(0, split));
    setImmediate(() => socket.end(response.subarray(split)));
  });
});

try {
  await new Promise((resolve, reject) => {
    bridge.once("error", reject);
    bridge.listen(socketPath, resolve);
  });

  const request = Buffer.from(JSON.stringify({
    schemaVersion: nativeProtocol.schemaVersion,
    path: "/v1/folders",
    method: "GET",
    token,
    bodyJSON: null
  }));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(request.length);

  const result = await new Promise((resolve, reject) => {
    const child = spawn(hostPath, ["--socket-path", socketPath], {
      stdio: ["pipe", "pipe", "pipe"]
    });
    const stdout = [];
    const stderr = [];
    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.once("error", reject);
    child.once("close", (status, signal) => resolve({
      status,
      signal,
      stdout: Buffer.concat(stdout),
      stderr: Buffer.concat(stderr)
    }));
    child.stdin.end(Buffer.concat([header, request]));
  });

  assert.equal(result.signal, null);
  assert.equal(result.status, 0);
  assert.equal(result.stderr.length, 0);
  assert.ok(result.stdout.length >= 4);
  const responseLength = result.stdout.readUInt32LE(0);
  assert.equal(result.stdout.length, responseLength + 4);
  const response = JSON.parse(result.stdout.subarray(4).toString("utf8"));
  assert.equal(response.schemaVersion, nativeProtocol.schemaVersion);
  assert.equal(response.ok, false);
  assert.equal(response.status, 401);
  assert.equal(response.payload.code, "invalid-token");
  assert.equal(response.transport, "native");

  assert.match(receivedRequest, /^GET \/v1\/folders HTTP\/1\.1\r\n/);
  assert.match(receivedRequest, new RegExp(`\r\nAuthorization: Bearer ${token}\r\n`));
  assert.match(receivedRequest, /\r\nX-Knowledge-Native-Messaging: 1\r\n/);
  assert.match(receivedRequest, /\r\nContent-Length: 0\r\n/);
} finally {
  if (bridge.listening) {
    await new Promise((resolve) => bridge.close(resolve));
  }
  await rm(directory, { recursive: true, force: true });
}

console.log("native messaging Unix socket bridge: passed");
