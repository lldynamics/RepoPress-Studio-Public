import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { access } from "node:fs/promises";
import { constants } from "node:fs";

const hostPath = process.argv[2];
if (!hostPath) throw new Error("usage: node script/test_native_messaging_host.mjs <host-executable>");
await access(hostPath, constants.X_OK);

const request = Buffer.from(JSON.stringify({
  schemaVersion: 1,
  path: "/v1/not-allowed",
  method: "POST",
  token: "a".repeat(64),
  bodyJSON: "{}"
}));
const header = Buffer.alloc(4);
header.writeUInt32LE(request.length);

const result = spawnSync(hostPath, [], {
  input: Buffer.concat([header, request]),
  maxBuffer: 2 * 1024 * 1024
});
assert.equal(result.status, 0);
assert.equal(result.stderr.length, 0);
assert.ok(result.stdout.length >= 4);
const responseLength = result.stdout.readUInt32LE(0);
assert.equal(result.stdout.length, responseLength + 4);
const response = JSON.parse(result.stdout.subarray(4).toString("utf8"));
assert.equal(response.schemaVersion, 1);
assert.equal(response.ok, false);
assert.equal(response.status, 0);
assert.equal(response.payload.code, "native-host-error");
assert.match(response.payload.error, /未允许的接口/);

console.log("native messaging host framing: passed");
