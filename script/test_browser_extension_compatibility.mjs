import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const extensionRoot = path.join(root, "BrowserExtension");
const manifest = JSON.parse(await readFile(path.join(extensionRoot, "manifest.json"), "utf8"));
const firefoxRoot = path.join(extensionRoot, "Firefox");
const firefoxManifest = JSON.parse(await readFile(path.join(firefoxRoot, "manifest.json"), "utf8"));
const firefoxRelease = JSON.parse(await readFile(path.join(extensionRoot, "firefox-release.json"), "utf8"));

assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.background.service_worker, "background.js");
assert.ok(manifest.permissions.includes("pageCapture"));
assert.equal(firefoxManifest.manifest_version, 3);
assert.deepEqual(firefoxManifest.background.scripts, ["background.js"]);
assert.equal(firefoxManifest.browser_specific_settings.gecko.strict_min_version, "142.0");
assert.equal(firefoxManifest.version, manifest.version);
assert.equal(firefoxManifest.browser_specific_settings.gecko.id, firefoxRelease.addonID);
assert.deepEqual(
  firefoxManifest.browser_specific_settings.gecko.data_collection_permissions.required,
  ["none"]
);
assert.equal(firefoxManifest.browser_specific_settings.gecko.update_url, undefined);
assert.equal(firefoxRelease.channel, "unlisted");
assert.match(firefoxRelease.updateManifestURL, /^https:\/\//);
assert.match(firefoxRelease.xpiBaseURL, /^https:\/\//);
assert.ok(!firefoxManifest.permissions.includes("pageCapture"));
assert.ok(manifest.permissions.includes("scripting"));
assert.ok(manifest.permissions.includes("alarms"));
assert.ok(manifest.permissions.includes("contextMenus"));
assert.ok(manifest.permissions.includes("unlimitedStorage"));
assert.ok(manifest.permissions.includes("nativeMessaging"));
assert.deepEqual(manifest.optional_host_permissions, ["http://*/*", "https://*/*"]);
assert.ok(manifest.commands["quick-save-cleaned"]);
assert.ok(manifest.commands["quick-save-selection"]);
assert.equal(manifest.host_permissions, undefined);
const chromiumExtensionID = [...createHash("sha256")
  .update(Buffer.from(manifest.key, "base64"))
  .digest()
  .subarray(0, 16)]
  .flatMap((byte) => [byte >> 4, byte & 15])
  .map((nibble) => String.fromCharCode(97 + nibble))
  .join("");
assert.equal(chromiumExtensionID, "lnibkmfhfikfbkeehcjbiaalhkiankam");
assert.ok(firefoxManifest.permissions.includes("scripting"));
assert.ok(firefoxManifest.permissions.includes("alarms"));
assert.ok(firefoxManifest.permissions.includes("menus"));
assert.ok(firefoxManifest.permissions.includes("unlimitedStorage"));
assert.deepEqual(firefoxManifest.optional_host_permissions, ["http://*/*", "https://*/*"]);
assert.ok(firefoxManifest.permissions.includes("nativeMessaging"));
assert.equal(firefoxManifest.host_permissions, undefined);

for (const sharedFile of ["background.js", "popup.js", "popup.html", "popup.css"]) {
  assert.equal(
    await readFile(path.join(firefoxRoot, sharedFile), "utf8"),
    await readFile(path.join(extensionRoot, sharedFile), "utf8"),
    `${sharedFile} is not synchronized with the Firefox extension`
  );
}

const popupHTML = await readFile(path.join(firefoxRoot, "popup.html"), "utf8");
const popupCSS = await readFile(path.join(firefoxRoot, "popup.css"), "utf8");
assert.match(popupHTML, /id="status"[^>]*aria-atomic="true"/);
assert.match(popupCSS, /\[hidden\]\s*\{[^}]*display:\s*none\s*!important;/s);

const popupSource = await readFile(path.join(firefoxRoot, "popup.js"), "utf8");
const popupElements = new Map();
const makePopupElement = () => ({
  hidden: false,
  value: "",
  checked: true,
  disabled: false,
  textContent: "",
  className: "",
  attributes: new Map(),
  children: [],
  options: [],
  addEventListener() {},
  replaceChildren(...children) {
    this.children = children;
    this.options = children;
  },
  append(child) { this.children.push(child); },
  add(option) { this.options.push(option); },
  click() { this.clicked = true; },
  focus() {},
  setAttribute(name, value) {
    this.attributes.set(name, value);
  }
});
for (const selector of [
  "#token", "#connect", "#connection-panel", "#session-panel", "#session-title",
  "#token-expiry", "#disconnect", "#re-pair", "#save-panel", "#organization-panel",
  "#folder", "#folder-search", "#folder-shortcuts", "#favorite-folder",
  "#remember-domain", "#remember-domain-label", "#organization-suggestions",
  "#folder-suggestions", "#tag-suggestions",
  "#new-folder", "#prepare-preview", "#preview-panel", "#preview-mode",
  "#batch-save", "#batch-hint",
  "#preview-size", "#preview-archive", "#capture-title", "#capture-authors",
  "#capture-tags", "#capture-ai", "#capture-preview", "#edit-capture",
  "#save", "#status", "#page-title", "main",
  "#queue-panel", "#queue-count", "#queue-summary", "#retry-queue", "#discard-queue",
  "#receipt-panel", "#receipt-title", "#receipt-folder", "#receipt-size",
  "#receipt-archive", "#receipt-index", "#receipt-ai", "#open-document",
  "#duplicate-panel", "#duplicate-message", "#duplicate-document", "#duplicate-folder",
  "#duplicate-size", "#duplicate-updated", "#duplicate-target",
  "#duplicate-new-version", "#duplicate-move", "#duplicate-copy", "#duplicate-cancel"
]) {
  popupElements.set(selector, makePopupElement());
}
const popupCaptureModes = [
  "cleaned-article", "full-page", "selection", "link-only"
].map((value, index) => ({
  ...makePopupElement(),
  value,
  checked: index === 0
}));
const popupBrowser = {
  runtime: { async sendMessage() { return { ok: true }; } },
  storage: { local: { async get() { return {}; }, async set() {}, async remove() {} } },
  tabs: { async query() { return []; } },
  permissions: { async request() { return true; } },
  scripting: {}
};
const popupContext = vm.createContext({
  browser: popupBrowser,
  console,
  Error,
  fetch: async () => ({
    ok: true,
    async json() {
      return { folders: [], tokenExpiresAt: "2026-08-18T00:00:00Z" };
    }
  }),
  globalThis: null,
  URL,
  Option: class {
    constructor(label, value) {
      this.label = label;
      this.text = label;
      this.value = value;
    }
  },
  document: {
    addEventListener() {},
    createElement() { return makePopupElement(); },
    querySelectorAll(selector) {
      return selector === "input[name='capture-mode']" ? popupCaptureModes : [];
    },
    querySelector(selector) {
      return popupElements.get(selector);
    }
  }
});
popupContext.globalThis = popupContext;
vm.runInContext(popupSource, popupContext, { filename: "popup.js" });
vm.runInContext('setConnectionState("disconnected")', popupContext);
assert.equal(popupElements.get("#connection-panel").hidden, false);
assert.equal(popupElements.get("#session-panel").hidden, true);
assert.equal(popupElements.get("#save-panel").hidden, true);
assert.equal(popupElements.get("#organization-panel").hidden, true);
assert.equal(popupElements.get("#save").disabled, true);
assert.equal(popupElements.get("main").attributes.get("aria-busy"), "false");
assert.equal(vm.runInContext("captureModeLabel('full-page')", popupContext), "完整网页：正文 + 离线页面归档");
assert.deepEqual(
  Array.from(vm.runInContext("splitMetadata('作者甲，作者乙;作者丙', 2)", popupContext)),
  ["作者甲", "作者乙"]
);
assert.equal(
  vm.runInContext("suggestionReasonLabel(['source-domain', 'tag'])", popupContext),
  "同来源、同标签"
);
vm.runInContext(`populateFolderOptions([
  { id: "folder-a", name: "产品研究" },
  { id: "folder-b", name: "技术资料" },
  { id: "folder-c", name: "待读" }
], "folder-a", "技术")`, popupContext);
assert.deepEqual(
  popupElements.get("#folder").options.map((option) => option.value),
  ["", "folder-a", "folder-b"]
);
popupElements.get("#capture-tags").value = "写作";
vm.runInContext("applySuggestedTag('知识管理')", popupContext);
assert.equal(popupElements.get("#capture-tags").value, "写作，知识管理");
vm.runInContext('setConnectionState("connected")', popupContext);
assert.equal(popupElements.get("#organization-panel").hidden, false);
assert.equal(popupElements.get("#session-panel").hidden, false);
vm.runInContext("updateTokenExpiry('2026-08-18T00:00:00Z')", popupContext);
assert.match(popupElements.get("#token-expiry").textContent, /令牌有效至/);
vm.runInContext(`
  activeTab = { url: "https://www.example.com/article" };
  allKnowledgeFolders = [{ id: "folder-a", name: "产品研究" }];
  populateFolderOptions(allKnowledgeFolders, "folder-a");
  rememberDomainInput.checked = true;
`, popupContext);
await vm.runInContext("updateRememberedDomainChoice()", popupContext);
assert.equal(
  vm.runInContext("domainFolderMap['example.com']", popupContext),
  "folder-a"
);
await vm.runInContext("toggleFavoriteFolder()", popupContext);
assert.equal(vm.runInContext("favoriteFolderIDs.has('folder-a')", popupContext), true);
popupElements.get("#preview-panel").hidden = false;
popupElements.get("#save").disabled = false;
vm.runInContext(`handlePopupKeyboardShortcut({
  metaKey: true,
  ctrlKey: false,
  shiftKey: false,
  key: "Enter",
  preventDefault() {}
})`, popupContext);
assert.equal(popupElements.get("#save").clicked, true);
assert.equal(
  vm.runInContext('readableError(new Error("NetworkError when attempting to fetch resource."))', popupContext),
  "无法连接应用。请先打开“个人网站发布控制台”，再检查令牌。"
);
vm.runInContext('showStatus("无法连接", "error")', popupContext);
assert.equal(popupElements.get("#status").attributes.get("role"), "alert");
assert.equal(popupElements.get("#status").attributes.get("aria-live"), "assertive");
vm.runInContext("updateQueuePanel({ queuedCount: 2, blockedCount: 1, totalBytes: 2048 })", popupContext);
assert.equal(popupElements.get("#queue-panel").hidden, false);
assert.equal(popupElements.get("#queue-count").textContent, "2");
assert.match(popupElements.get("#queue-summary").textContent, /1 项需要手动重试/);
vm.runInContext(`showReceipt({
  documentID: "11111111-1111-1111-1111-111111111111",
  title: "长期参考",
  folder: { name: "阅读" },
  fileSizeBytes: 2048,
  archiveType: "html",
  indexStatus: "ready",
  allowsAIUse: true
})`, popupContext);
assert.equal(popupElements.get("#receipt-panel").hidden, false);
assert.equal(popupElements.get("#receipt-title").textContent, "长期参考");
assert.equal(popupElements.get("#receipt-folder").textContent, "阅读");
assert.equal(popupElements.get("#receipt-size").textContent, "2.0 KB");
assert.equal(popupElements.get("#receipt-archive").textContent, "离线 HTML");
assert.equal(popupElements.get("#receipt-index").textContent, "全文与语义索引已就绪");
assert.equal(popupElements.get("#receipt-ai").textContent, "允许 AI 检索");
vm.runInContext(`showDuplicateConflict({
  queueID: "queue-1",
  targetNewFolderName: "产品研究",
  conflict: {
    title: "已有网页",
    folder: { name: "阅读" },
    fileSizeBytes: 4096,
    updatedAt: "2026-07-19T00:00:00Z",
    incomingHasChanges: true
  }
})`, popupContext);
assert.equal(popupElements.get("#duplicate-panel").hidden, false);
assert.equal(popupElements.get("#duplicate-document").textContent, "已有网页");
assert.equal(popupElements.get("#duplicate-folder").textContent, "阅读");
assert.equal(popupElements.get("#duplicate-size").textContent, "4.0 KB");
assert.equal(popupElements.get("#duplicate-target").textContent, "产品研究");
assert.match(popupElements.get("#duplicate-message").textContent, /正文与现有资料不同/);
popupElements.get("#token").value = "temporary-token";
await vm.runInContext("disconnectFromBridge(true)", popupContext);
assert.equal(popupElements.get("#token").value, "");
assert.equal(popupElements.get("#connection-panel").hidden, false);
assert.match(popupElements.get("#status").textContent, /旧令牌已从插件中清除/);

const backgroundSource = await readFile(path.join(firefoxRoot, "background.js"), "utf8");
let messageListener;
let postedBody;
let bridgeAvailable = true;
let bridgeStatus = 200;
let bridgeErrorCode = null;
let nativeHostAvailable = true;
let nativeMessageRequest;
let lastFetchURL;
let fetchCount = 0;
let duplicateMode = false;
let commandListener;
let menuClickListener;
const createdMenus = [];
const toolbarState = {};
const savedDocumentID = "11111111-1111-1111-1111-111111111111";
const backgroundStorage = { bridgeToken: "test-token" };
const activeAlarms = new Map();
const page = {
  sourceURL: "https://example.com/article",
  title: "Firefox fallback",
  authors: [],
  language: "zh-CN",
  summary: "",
  tags: [],
  contentText: "正文",
  originalHTML: "<!doctype html><p>正文</p>",
  archiveReport: {
    format: "html",
    embeddedResourceCount: 3,
    missingResourceCount: 1,
    wasTruncated: false
  }
};
const browser = {
  runtime: {
    onMessage: {
      addListener(listener) {
        messageListener = listener;
      }
    },
    sendNativeMessage(hostName, request, callback) {
      const operation = (async () => {
        nativeMessageRequest = { hostName, request };
        if (!nativeHostAvailable) throw new Error("Native host not found");
        const body = request.bodyJSON ? JSON.parse(request.bodyJSON) : null;
        postedBody = body;
        if (request.path === "/v1/open") return {
          schemaVersion: 1,
          ok: true,
          status: 200,
          payload: { documentID: body.documentID, opened: true },
          transport: "native"
        };
        if (request.path === "/v1/folders") return {
          schemaVersion: 1,
          ok: true,
          status: 200,
          payload: { folders: [], tokenExpiresAt: "2026-08-18T00:00:00Z" },
          transport: "native"
        };
        if (duplicateMode && !body?.duplicateResolution) return {
          schemaVersion: 1,
          ok: true,
          status: 200,
          payload: {
            requiresDuplicateResolution: true,
            conflict: {
              documentID: savedDocumentID,
              title: page.title,
              folder: { id: "22222222-2222-2222-2222-222222222222", name: "阅读" },
              fileSizeBytes: 2048,
              updatedAt: "2026-07-19T00:00:00Z",
              incomingHasChanges: true
            }
          },
          transport: "native"
        };
        return {
        schemaVersion: 1,
        ok: bridgeStatus >= 200 && bridgeStatus < 300,
        status: bridgeStatus,
        payload: bridgeStatus >= 200 && bridgeStatus < 300
          ? {
              insertedCount: 1,
              updatedCount: 0,
              skippedCount: 0,
              action: body?.duplicateResolution === "move-only" ? "moved" : "inserted",
              documentID: savedDocumentID,
              title: page.title,
              folder: { id: "22222222-2222-2222-2222-222222222222", name: "阅读" },
              fileSizeBytes: 2048,
              archiveType: page.archiveReport.format,
              indexStatus: "ready",
              allowsAIUse: true
            }
          : { error: "capture rejected", code: bridgeErrorCode },
        transport: "native"
        };
      })();
      if (typeof callback === "function") {
        operation.then(callback, (error) => {
          this.lastError = { message: error.message };
          callback(undefined);
          this.lastError = null;
        });
        return undefined;
      }
      return operation;
    },
    onStartup: { addListener() {} },
    onInstalled: { addListener() {} }
  },
  action: {
    async setBadgeBackgroundColor(details) { toolbarState.color = details.color; },
    async setBadgeText(details) { toolbarState.text = details.text; },
    async setTitle(details) { toolbarState.title = details.title; }
  },
  menus: {
    onClicked: { addListener(listener) { menuClickListener = listener; } },
    async removeAll() { createdMenus.length = 0; },
    create(details) { createdMenus.push(details); }
  },
  commands: {
    onCommand: { addListener(listener) { commandListener = listener; } }
  },
  tabs: {
    async query() { return [{ id: 9, url: page.sourceURL, title: page.title }]; }
  },
  alarms: {
    onAlarm: { addListener() {} },
    async create(name, options) { activeAlarms.set(name, options); },
    async clear(name) { return activeAlarms.delete(name); }
  },
  storage: {
    local: {
      async get(keys) {
        return Object.fromEntries((keys || []).flatMap((key) =>
          Object.hasOwn(backgroundStorage, key) ? [[key, backgroundStorage[key]]] : []
        ));
      },
      async set(values) {
        Object.assign(backgroundStorage, values);
      },
      async remove(keys) {
        for (const key of keys || []) delete backgroundStorage[key];
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
  Blob,
  console,
  Date,
  Error,
  FileReader: class {
    readAsDataURL(blob) {
      blob.arrayBuffer().then((buffer) => {
        this.result = `data:${blob.type};base64,${Buffer.from(buffer).toString("base64")}`;
        this.onload?.();
      }, (error) => {
        this.error = error;
        this.onerror?.();
      });
    }
  },
  TextEncoder,
  URL,
  fetch: async (_url, options) => {
    fetchCount += 1;
    if (!bridgeAvailable) throw new TypeError("Failed to fetch");
    lastFetchURL = _url;
    postedBody = JSON.parse(options.body);
    if (_url.endsWith("/v1/open")) {
      return {
        ok: true,
        status: 200,
        async json() { return { documentID: postedBody.documentID, opened: true }; }
      };
    }
    if (duplicateMode && !postedBody.duplicateResolution) {
      return {
        ok: true,
        status: 200,
        async json() {
          return {
            requiresDuplicateResolution: true,
            conflict: {
              documentID: savedDocumentID,
              title: page.title,
              folder: { id: "22222222-2222-2222-2222-222222222222", name: "阅读" },
              fileSizeBytes: 2048,
              updatedAt: "2026-07-19T00:00:00Z",
              incomingHasChanges: true
            }
          };
        }
      };
    }
    return {
      ok: bridgeStatus >= 200 && bridgeStatus < 300,
      status: bridgeStatus,
      async json() {
        return bridgeStatus >= 200 && bridgeStatus < 300
          ? {
              insertedCount: 1,
              updatedCount: 0,
              skippedCount: 0,
              action: postedBody.duplicateResolution === "move-only" ? "moved" : "inserted",
              documentID: savedDocumentID,
              title: page.title,
              folder: { id: "22222222-2222-2222-2222-222222222222", name: "阅读" },
              fileSizeBytes: 2048,
              archiveType: page.archiveReport.format,
              indexStatus: "ready",
              allowsAIUse: true
            }
          : { error: "capture rejected", code: bridgeErrorCode };
      }
    };
  },
  globalThis: null
});
context.globalThis = context;
vm.runInContext(backgroundSource, context, { filename: "background.js" });
assert.equal(typeof messageListener, "function");
assert.equal(typeof commandListener, "function");
assert.equal(typeof menuClickListener, "function");
const callbackTransport = await vm.runInContext(`(async () => {
  const savedBrowser = globalThis.browser;
  globalThis.browser = undefined;
  try {
    return await sendNativeHostMessage({
      schemaVersion: 1,
      path: "/v1/folders",
      method: "GET",
      token: "test-token",
      bodyJSON: null
    });
  } finally {
    globalThis.browser = savedBrowser;
  }
})()`, context);
assert.equal(callbackTransport.ok, true);
await vm.runInContext("setupContextMenus()", context);
assert.equal(createdMenus.length, 3);
assert.deepEqual(
  createdMenus.map((item) => item.id),
  ["knowledge-save-cleaned", "knowledge-save-selection", "knowledge-save-link"]
);

const previewResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("preview response timed out")), 1_000);
  messageListener({
    type: "prepare-capture-preview",
    tabId: 9,
    captureMode: "selection"
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(previewResponse.ok, true);
assert.equal(previewResponse.result.captureMode, "selection");
assert.equal(previewResponse.result.capture.captureMode, "selection");
assert.equal(previewResponse.result.capture.archiveData, null);
assert.equal(previewResponse.result.archiveType, "none");

const editedCapture = {
  ...previewResponse.result.capture,
  title: "编辑后的标题",
  authors: ["作者甲", "作者乙"],
  tags: ["研究", "写作"],
  allowsAIUse: false
};
const preparedSaveResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("prepared save response timed out")), 1_000);
  messageListener({
    type: "save-prepared-capture",
    tabId: 9,
    token: "test-token",
    captureMode: "selection",
    capture: editedCapture
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(preparedSaveResponse.ok, true);
assert.equal(nativeMessageRequest.hostName, "com.jinfang.personal_site_publisher.knowledge");
assert.equal(nativeMessageRequest.request.path, "/v1/import");
assert.equal(nativeMessageRequest.request.method, "POST");
assert.equal(postedBody.capture.title, "编辑后的标题");
assert.deepEqual(postedBody.capture.authors, ["作者甲", "作者乙"]);
assert.deepEqual(postedBody.capture.tags, ["研究", "写作"]);
assert.equal(postedBody.capture.allowsAIUse, false);
assert.equal(postedBody.capture.captureMode, "selection");
assert.equal(postedBody.capture.archiveFormat, null);

const batchResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("batch response timed out")), 1_000);
  messageListener({
    type: "capture-tabs-batch",
    tabIDs: [9, 10],
    token: "test-token",
    captureMode: "link-only",
    allowsAIUse: false
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(batchResponse.ok, true);
assert.equal(batchResponse.result.requestedCount, 2);
assert.equal(batchResponse.result.savedCount, 2);
assert.equal(batchResponse.result.failedCount, 0);
assert.equal(postedBody.capture.captureMode, "link-only");
assert.equal(postedBody.capture.allowsAIUse, false);
assert.equal(toolbarState.text, "✓");

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
assert.equal(response.result.documentID, savedDocumentID);
assert.equal(response.result.folder.name, "阅读");
assert.equal(response.result.fileSizeBytes, 2048);
assert.equal(response.result.indexStatus, "ready");
assert.equal(postedBody.capture.archiveFormat, "html");
assert.equal(
  Buffer.from(postedBody.capture.archiveData, "base64").toString("utf8"),
  page.originalHTML
);
assert.equal(postedBody.capture.originalHTML, null);
assert.equal(postedBody.capture.archiveEmbeddedResourceCount, 3);
assert.equal(postedBody.capture.archiveMissingResourceCount, 1);
assert.equal(postedBody.capture.archiveWasTruncated, false);
assert.deepEqual(response.result.archiveReport, page.archiveReport);

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
      assert.equal(postedBody.capture.archiveFormat, null);
      assert.equal(postedBody.capture.archiveData, null);
      resolve();
    } catch (error) {
      reject(error);
    }
  });
});

nativeHostAvailable = false;
bridgeAvailable = false;
const queuedResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("queue response timed out")), 1_000);
  messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    includeArchive: false
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(queuedResponse.ok, true);
assert.equal(queuedResponse.result.queued, true);
assert.equal(queuedResponse.result.queuedCount, 1);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.length, 1);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1[0].envelope.capture.sourceURL, page.sourceURL);
assert.equal("token" in backgroundStorage.pendingKnowledgeCapturesV1[0], false);
assert.equal(activeAlarms.has("retry-pending-knowledge-captures"), true);
assert.equal(fetchCount, 0, "Firefox must not fall back to direct localhost HTTP");

nativeHostAvailable = true;
bridgeAvailable = true;
const retryResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("retry response timed out")), 1_000);
  messageListener({
    type: "retry-capture-queue",
    token: "test-token",
    force: true
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(retryResponse.ok, true);
assert.equal(retryResponse.result.importedCount, 1);
assert.equal(retryResponse.result.queuedCount, 0);
assert.equal(retryResponse.result.receipts.length, 1);
assert.equal(retryResponse.result.receipts[0].documentID, savedDocumentID);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.length, 0);
assert.equal(activeAlarms.has("retry-pending-knowledge-captures"), false);

const openResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("open response timed out")), 1_000);
  messageListener({
    type: "open-knowledge-document",
    documentID: savedDocumentID,
    token: "test-token"
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(openResponse.ok, true);
assert.equal(openResponse.result.opened, true);
assert.equal(nativeMessageRequest.request.path, "/v1/open");
assert.equal(postedBody.documentID, savedDocumentID);

duplicateMode = true;
const conflictResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("conflict response timed out")), 1_000);
  messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    folderID: "33333333-3333-3333-3333-333333333333",
    includeArchive: false
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(conflictResponse.ok, true);
assert.equal(conflictResponse.result.requiresDuplicateResolution, true);
assert.equal(conflictResponse.result.conflict.documentID, savedDocumentID);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.length, 1);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1[0].blocked, true);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1[0].duplicateConflict.title, page.title);

const resolvedConflict = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("conflict resolution timed out")), 1_000);
  messageListener({
    type: "resolve-duplicate-capture",
    queueID: conflictResponse.result.conflictQueueID,
    resolution: "move-only",
    token: "test-token"
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(resolvedConflict.ok, true);
assert.equal(resolvedConflict.result.receipt.action, "moved");
assert.equal(postedBody.duplicateResolution, "move-only");
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.length, 0);

const cancellableConflict = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("cancel conflict response timed out")), 1_000);
  messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    includeArchive: false
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
const cancelledConflict = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("cancel response timed out")), 1_000);
  messageListener({
    type: "cancel-duplicate-capture",
    queueID: cancellableConflict.result.conflictQueueID
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(cancelledConflict.ok, true);
assert.equal(cancelledConflict.result.queuedCount, 0);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.length, 0);

duplicateMode = false;
bridgeStatus = 422;
const rejectedResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("rejection response timed out")), 1_000);
  messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    includeArchive: false
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(rejectedResponse.ok, false);
assert.match(rejectedResponse.error, /capture rejected/);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.length, 0);

bridgeStatus = 401;
bridgeErrorCode = "token-expired";
backgroundStorage.bridgeToken = "test-token";
const expiredResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("expired token response timed out")), 1_000);
  messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    includeArchive: false
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(expiredResponse.ok, false);
assert.equal(expiredResponse.code, "token-expired");
assert.equal(backgroundStorage.bridgeToken, undefined);

console.log("browser extension compatibility: passed");
