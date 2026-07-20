import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const protocol = JSON.parse(await readFile(
  path.join(root, "BrowserExtension", "browser-extension-protocol.json"),
  "utf8"
));
const nativeProtocol = protocol.nativeMessaging;

const hostPath = process.argv[2];
if (!hostPath) throw new Error("usage: node script/test_native_messaging_host.mjs <host-executable>");
await access(hostPath, constants.X_OK);

function sendNativeMessage(message) {
  const request = Buffer.from(JSON.stringify(message));
  const header = Buffer.alloc(4);
  header.writeUInt32LE(request.length);
  const result = spawnSync(hostPath, [], {
    input: Buffer.concat([header, request]),
    maxBuffer: nativeProtocol.maximumOutputBytes + 1024
  });
  assert.equal(result.status, 0);
  assert.equal(result.stderr.length, 0);
  assert.ok(result.stdout.length >= 4);
  const responseLength = result.stdout.readUInt32LE(0);
  assert.equal(result.stdout.length, responseLength + 4);
  return JSON.parse(result.stdout.subarray(4).toString("utf8"));
}

const handshake = sendNativeMessage({
  schemaVersion: nativeProtocol.schemaVersion,
  path: "/native/handshake",
  method: "GET",
  token: ""
});
assert.equal(handshake.schemaVersion, nativeProtocol.schemaVersion);
assert.equal(handshake.ok, true);
assert.equal(handshake.status, 200);
assert.equal(handshake.payload.protocolVersion, nativeProtocol.schemaVersion);
assert.equal(handshake.payload.minimumClientProtocolVersion, nativeProtocol.schemaVersion);
assert.equal(handshake.payload.maximumClientProtocolVersion, nativeProtocol.schemaVersion);
assert.equal(typeof handshake.payload.applicationVersion, "string");
assert.equal(handshake.transport, "native");

const response = sendNativeMessage({
  schemaVersion: nativeProtocol.schemaVersion,
  path: "/v1/not-allowed",
  method: "POST",
  token: "a".repeat(64),
  bodyJSON: "{}"
});
assert.equal(response.schemaVersion, nativeProtocol.schemaVersion);
assert.equal(response.ok, false);
assert.equal(response.status, 0);
assert.equal(response.payload.code, "native-host-error");
assert.match(response.payload.error, /未允许的接口/);

console.log("native messaging host framing: passed");
