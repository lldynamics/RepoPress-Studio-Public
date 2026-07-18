import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const extensionRoot = path.join(root, "BrowserExtension");
const manifest = JSON.parse(await readFile(path.join(extensionRoot, "manifest.json"), "utf8"));
const firefoxRoot = path.join(extensionRoot, "Firefox");
const firefoxManifest = JSON.parse(await readFile(path.join(firefoxRoot, "manifest.json"), "utf8"));

assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.background.service_worker, "background.js");
assert.ok(manifest.permissions.includes("pageCapture"));
assert.equal(firefoxManifest.manifest_version, 3);
assert.deepEqual(firefoxManifest.background.scripts, ["background.js"]);
assert.equal(firefoxManifest.browser_specific_settings.gecko.strict_min_version, "121.0");
assert.ok(!firefoxManifest.permissions.includes("pageCapture"));
assert.ok(manifest.permissions.includes("scripting"));
assert.ok(manifest.host_permissions.includes("http://127.0.0.1:47831/*"));
assert.ok(firefoxManifest.permissions.includes("scripting"));
assert.ok(firefoxManifest.host_permissions.includes("http://127.0.0.1:47831/*"));

for (const sharedFile of ["background.js", "popup.js", "popup.html", "popup.css"]) {
  assert.equal(
    await readFile(path.join(firefoxRoot, sharedFile), "utf8"),
    await readFile(path.join(extensionRoot, sharedFile), "utf8"),
    `${sharedFile} is not synchronized with the Firefox extension`
  );
}

const backgroundSource = await readFile(path.join(firefoxRoot, "background.js"), "utf8");
let messageListener;
let postedBody;
const page = {
  sourceURL: "https://example.com/article",
  title: "Firefox fallback",
  authors: [],
  language: "zh-CN",
  summary: "",
  tags: [],
  contentText: "正文",
  originalHTML: "<!doctype html><p>正文</p>"
};
const browser = {
  runtime: {
    onMessage: {
      addListener(listener) {
        messageListener = listener;
      }
    }
  },
  scripting: {
    async executeScript() {
      return [{ result: page }];
    }
  }
};
const context = vm.createContext({
  browser,
  console,
  Date,
  Error,
  FileReader: class {},
  TextEncoder,
  URL,
  fetch: async (_url, options) => {
    postedBody = JSON.parse(options.body);
    return {
      ok: true,
      async json() {
        return { insertedCount: 1, updatedCount: 0 };
      }
    };
  },
  globalThis: null
});
context.globalThis = context;
vm.runInContext(backgroundSource, context, { filename: "background.js" });
assert.equal(typeof messageListener, "function");

const response = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("extension response timed out")), 1_000);
  const keepsChannelOpen = messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    folderID: null,
    newFolderName: null,
    includeArchive: true
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
  assert.equal(keepsChannelOpen, true);
});

assert.equal(response.ok, true);
assert.equal(postedBody.capture.archiveFormat, null);
assert.equal(postedBody.capture.archiveData, null);
assert.equal(postedBody.capture.originalHTML, page.originalHTML);

await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("extension response timed out")), 1_000);
  messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    includeArchive: false
  }, {}, (value) => {
    clearTimeout(timeout);
    try {
      assert.equal(value.ok, true);
      assert.equal(postedBody.capture.originalHTML, null);
      resolve();
    } catch (error) {
      reject(error);
    }
  });
});

console.log("browser extension compatibility: passed");
