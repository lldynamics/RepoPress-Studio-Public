import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import vm from "node:vm";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const extensionRoot = path.join(root, "BrowserExtension");
const manifest = JSON.parse(await readFile(path.join(extensionRoot, "manifest.json"), "utf8"));
const protocolDefinition = JSON.parse(await readFile(
  path.join(extensionRoot, "browser-extension-protocol.json"),
  "utf8"
));
assert.deepEqual(
  protocolDefinition.activeExtensions,
  ["safari", "chrome", "firefox"],
  "this release must expose Safari, Chrome, and Firefox"
);
const loopbackProtocol = protocolDefinition.loopback;
const generatedProtocolSource = await readFile(
  path.join(extensionRoot, "protocol.generated.js"),
  "utf8"
);
const firefoxRoot = path.join(extensionRoot, "Firefox");
const firefoxManifest = JSON.parse(await readFile(path.join(firefoxRoot, "manifest.json"), "utf8"));
const safariRoot = path.join(extensionRoot, "Safari");
const safariManifest = JSON.parse(await readFile(path.join(safariRoot, "manifest.json"), "utf8"));
const firefoxRelease = JSON.parse(await readFile(path.join(extensionRoot, "firefox-release.json"), "utf8"));

assert.equal(manifest.manifest_version, 3);
assert.equal(manifest.background.service_worker, "background.js");
assert.equal(manifest.name, "__MSG_extensionName__");
assert.equal(manifest.description, "__MSG_extensionDescription__");
assert.equal(manifest.default_locale, "zh_CN");
assert.deepEqual(manifest.icons, {
  "16": "icons/icon16.png",
  "32": "icons/icon32.png",
  "48": "icons/icon48.png",
  "128": "icons/icon128.png"
});
assert.deepEqual(manifest.action.default_icon, {
  "16": "icons/icon16.png",
  "32": "icons/icon32.png"
});
assert.equal(manifest.action.default_title, "__MSG_actionTitle__");
const expectedExtensionCSP = {
  extension_pages: "script-src 'self'; object-src 'self'"
};
assert.deepEqual(manifest.content_security_policy, expectedExtensionCSP);
const localeMessageKeys = new Map();
for (const locale of ["zh_CN", "en"]) {
  const messages = JSON.parse(await readFile(
    path.join(extensionRoot, "_locales", locale, "messages.json"),
    "utf8"
  ));
  localeMessageKeys.set(locale, Object.keys(messages).sort());
  for (const requiredKey of [
    "actionTitle", "extensionDescription", "extensionName", "popupTitle",
    "nativeConnectionHint", "folderSearchLabel", "folderSearchResultCount",
    "folderSearchEmpty", "queueTitle"
  ]) {
    assert.ok(messages[requiredKey], `${locale}.${requiredKey} is missing`);
  }
  for (const value of Object.values(messages)) {
    assert.deepEqual(Object.keys(value), ["message"]);
    assert.ok(value.message.length > 0);
  }
}
assert.deepEqual(localeMessageKeys.get("zh_CN"), localeMessageKeys.get("en"));
assert.ok(manifest.permissions.includes("pageCapture"));
assert.equal(firefoxManifest.manifest_version, 3);
assert.equal(firefoxManifest.name, "__MSG_extensionName__");
assert.equal(firefoxManifest.description, "__MSG_extensionDescription__");
assert.equal(firefoxManifest.default_locale, "zh_CN");
assert.equal(firefoxManifest.action.default_title, "__MSG_actionTitle__");
assert.deepEqual(firefoxManifest.content_security_policy, expectedExtensionCSP);
assert.deepEqual(firefoxManifest.icons, manifest.icons);
assert.deepEqual(firefoxManifest.action.default_icon, manifest.action.default_icon);
assert.deepEqual(
  firefoxManifest.background.scripts,
  ["protocol.generated.js", "background.js"]
);
assert.equal(firefoxManifest.browser_specific_settings.gecko.strict_min_version, "142.0");
assert.equal(firefoxManifest.version, manifest.version);
assert.equal(
  firefoxManifest.browser_specific_settings.gecko.id,
  protocolDefinition.extensions.firefoxID
);
assert.equal(firefoxRelease.addonID, protocolDefinition.extensions.firefoxID);
assert.deepEqual(
  firefoxManifest.browser_specific_settings.gecko.data_collection_permissions.required,
  ["none"]
);
assert.equal(firefoxManifest.browser_specific_settings.gecko.update_url, undefined);
assert.equal(firefoxRelease.channel, "unlisted");
assert.match(firefoxRelease.updateManifestURL, /^https:\/\//);
assert.match(firefoxRelease.xpiBaseURL, /^https:\/\//);
assert.ok(!firefoxManifest.permissions.includes("pageCapture"));
assert.equal(safariManifest.manifest_version, 3);
assert.equal(safariManifest.name, manifest.name);
assert.equal(safariManifest.description, manifest.description);
assert.equal(safariManifest.default_locale, manifest.default_locale);
assert.equal(safariManifest.version, manifest.version);
assert.deepEqual(safariManifest.icons, manifest.icons);
assert.deepEqual(safariManifest.action, manifest.action);
assert.deepEqual(safariManifest.background, { service_worker: "background.js" });
assert.deepEqual(safariManifest.content_security_policy, expectedExtensionCSP);
assert.equal(safariManifest.key, undefined);
assert.equal(safariManifest.minimum_chrome_version, undefined);
assert.equal(safariManifest.permissions.includes("pageCapture"), false);
assert.equal(safariManifest.permissions.includes("nativeMessaging"), false);
assert.ok(safariManifest.permissions.includes("activeTab"));
assert.ok(safariManifest.permissions.includes("scripting"));
assert.ok(safariManifest.permissions.includes("storage"));
assert.deepEqual(safariManifest.host_permissions, manifest.host_permissions);
assert.deepEqual(safariManifest.optional_host_permissions, manifest.optional_host_permissions);
assert.deepEqual(safariManifest.optional_permissions, manifest.optional_permissions);
assert.deepEqual(safariManifest.commands, manifest.commands);
assert.match(
  protocolDefinition.extensions.safariBundleID,
  /^com\.jinfang\.PersonalSitePublisherMac\.[A-Za-z0-9.-]+$/
);
assert.ok(manifest.permissions.includes("scripting"));
assert.ok(manifest.permissions.includes("alarms"));
assert.ok(manifest.permissions.includes("contextMenus"));
assert.ok(manifest.permissions.includes("unlimitedStorage"));
assert.equal(manifest.permissions.includes("nativeMessaging"), false);
assert.deepEqual(manifest.optional_host_permissions, ["http://*/*", "https://*/*"]);
assert.deepEqual(manifest.optional_permissions, ["tabs"]);
assert.ok(manifest.commands["quick-save-cleaned"]);
assert.ok(manifest.commands["quick-save-selection"]);
assert.deepEqual(
  manifest.host_permissions,
  [`http://${loopbackProtocol.host}:${loopbackProtocol.port}/*`]
);
const chromiumExtensionID = [...createHash("sha256")
  .update(Buffer.from(manifest.key, "base64"))
  .digest()
  .subarray(0, 16)]
  .flatMap((byte) => [byte >> 4, byte & 15])
  .map((nibble) => String.fromCharCode(97 + nibble))
  .join("");
assert.equal(chromiumExtensionID, protocolDefinition.extensions.chromiumDevelopmentID);
for (const field of ["chromeProductionID", "edgeProductionID"]) {
  const extensionID = protocolDefinition.extensions[field];
  assert.ok(extensionID === null || /^[a-p]{32}$/.test(extensionID));
}
assert.ok(firefoxManifest.permissions.includes("scripting"));
assert.ok(firefoxManifest.permissions.includes("alarms"));
assert.ok(firefoxManifest.permissions.includes("dns"));
assert.ok(firefoxManifest.permissions.includes("menus"));
assert.ok(firefoxManifest.permissions.includes("unlimitedStorage"));
assert.ok(firefoxManifest.permissions.includes("webRequest"));
assert.ok(firefoxManifest.permissions.includes("webRequestBlocking"));
assert.deepEqual(firefoxManifest.optional_host_permissions, ["http://*/*", "https://*/*"]);
assert.deepEqual(firefoxManifest.optional_permissions, ["tabs"]);
assert.equal(firefoxManifest.permissions.includes("nativeMessaging"), false);
assert.deepEqual(firefoxManifest.host_permissions, manifest.host_permissions);
assert.equal(manifest.permissions.includes("dns"), false);
assert.equal(manifest.permissions.includes("webRequest"), false);
assert.equal(manifest.permissions.includes("webRequestBlocking"), false);

for (const sharedFile of [
  "protocol.generated.js", "background-capture.js", "background-queue-operations.js",
  "background-queue-storage.js", "background-security.js", "background.js",
  "popup.js", "popup.html", "popup.css",
  "_locales/en/messages.json", "_locales/zh_CN/messages.json",
  "icons/icon16.png", "icons/icon32.png", "icons/icon48.png", "icons/icon128.png"
]) {
  const sharedSource = await readFile(path.join(extensionRoot, sharedFile));
  for (const [browserName, browserRoot] of [
    ["Firefox", firefoxRoot],
    ["Safari", safariRoot]
  ]) {
    assert.equal(
      Buffer.compare(
        await readFile(path.join(browserRoot, sharedFile)),
        sharedSource
      ),
      0,
      `${sharedFile} is not synchronized with the ${browserName} extension`
    );
  }
}

const popupHTML = await readFile(path.join(firefoxRoot, "popup.html"), "utf8");
const popupCSS = await readFile(path.join(firefoxRoot, "popup.css"), "utf8");
assert.match(popupHTML, /<form id="connection-form">/);
assert.match(popupHTML, /id="connect"[^>]*type="submit"/);
assert.match(popupHTML, /<label for="folder-search"[^>]*>/);
assert.match(popupHTML, /id="folder-search-result"/);
assert.match(popupHTML, /id="folder-empty-state"/);
assert.match(popupHTML, /<h2 id="connection-title"/);
assert.match(popupHTML, /<button id="save-now"[^>]*data-i18n="directSaveButton"/);
assert.match(popupHTML, /<details id="organization-panel"[^>]*hidden/);
assert.doesNotMatch(popupHTML, /id="preview-panel"/);
assert.ok(
  popupHTML.indexOf('id="session-panel"') > popupHTML.indexOf('id="queue-panel"'),
  "connected session controls must remain below the queue to reduce accidental disconnects"
);
assert.match(popupHTML, /class="mark" aria-hidden="true"/);
assert.match(popupHTML, /id="status" role="status"[^>]*aria-atomic="true"/);
assert.match(popupHTML, /id="alert" role="alert"[^>]*aria-atomic="true"/);
assert.match(popupHTML, /127\.0\.0\.1/);
assert.match(popupHTML, /本机回环接口/);
assert.doesNotMatch(popupHTML, /Native Messaging|Unix Socket/);
assert.match(popupCSS, /\[hidden\]\s*\{[^}]*display:\s*none\s*!important;/s);
assert.doesNotMatch(popupCSS, /min-width:\s*420px/);
assert.doesNotMatch(popupCSS, /100vw/);
assert.match(popupCSS, /body\s*\{[^}]*width:\s*420px;/s);
assert.match(popupCSS, /@media\s*\(max-width:\s*380px\)/);
assert.match(
  popupCSS,
  /@media\s*\(max-width:\s*380px\)[\s\S]*?body\s*\{[^}]*width:\s*320px;/
);
assert.match(
  popupCSS,
  /\.capture-mode-grid,[\s\S]*?grid-template-columns:\s*minmax\(0,\s*1fr\)/
);
assert.match(popupCSS, /outline:\s*3px solid var\(--focus-ring\)/);
assert.match(
  popupCSS,
  /--control-border:\s*color-mix\(in srgb,\s*CanvasText\s+(?:4[5-9]|[5-9]\d)%,\s*Canvas\)/
);
const relativeLuminance = (hex) => {
  const channels = [1, 3, 5].map((offset) =>
    Number.parseInt(hex.slice(offset, offset + 2), 16) / 255
  ).map((channel) => channel <= 0.04045
    ? channel / 12.92
    : ((channel + 0.055) / 1.055) ** 2.4
  );
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
};
const contrastRatio = (left, right) => {
  const luminances = [relativeLuminance(left), relativeLuminance(right)]
    .sort((a, b) => b - a);
  return (luminances[0] + 0.05) / (luminances[1] + 0.05);
};
const primaryFill = popupCSS.match(/--primary-fill:\s*(#[0-9a-f]{6})/i)?.[1];
const primaryHover = popupCSS.match(/--primary-fill-hover:\s*(#[0-9a-f]{6})/i)?.[1];
const primaryActive = popupCSS.match(/--primary-fill-active:\s*(#[0-9a-f]{6})/i)?.[1];
const lightFocusRing = popupCSS.match(/--focus-ring:\s*(#[0-9a-f]{6})/i)?.[1];
assert.ok(primaryFill, "primary fill token is missing");
assert.ok(primaryHover, "primary hover token is missing");
assert.ok(primaryActive, "primary active token is missing");
assert.ok(lightFocusRing, "focus ring token is missing");
for (const primaryColor of [primaryFill, primaryHover, primaryActive]) {
  assert.ok(contrastRatio(primaryColor, "#ffffff") >= 4.5);
  assert.ok(contrastRatio(primaryColor, "#000000") >= 3);
}
assert.ok(contrastRatio(lightFocusRing, "#ffffff") >= 3);

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
  listeners: new Map(),
  children: [],
  options: [],
  addEventListener(type, listener) { this.listeners.set(type, listener); },
  replaceChildren(...children) {
    this.children = children;
    this.options = children;
  },
  append(...children) { this.children.push(...children); },
  add(option) { this.options.push(option); },
  click() { this.clicked = true; },
  focus() {},
  setAttribute(name, value) {
    this.attributes.set(name, value);
  },
  getAttribute(name) { return this.attributes.get(name) ?? null; }
});
for (const selector of [
  "#token", "#connect", "#connection-form", "#connection-panel", "#session-panel", "#session-title",
  "#token-expiry", "#disconnect", "#re-pair", "#save-panel", "#organization-panel",
  "#folder", "#folder-search", "#folder-search-result", "#folder-empty-state",
  "#folder-shortcuts", "#favorite-folder",
  "#remember-domain", "#remember-domain-label", "#save-options-summary",
  "#new-folder", "#save-now",
  "#batch-save", "#batch-hint",
  "#batch-review-panel", "#batch-settings-summary", "#batch-items", "#batch-retry-failed",
  "#capture-local-index", "#capture-remote-ai", "#status", "#alert", "#page-title", "main",
  "#queue-panel", "#queue-count", "#queue-state", "#queue-summary", "#queue-retention",
  "#queue-privacy-mode", "#queue-allow-private-sites",
  "#queue-items", "#retry-queue", "#export-queue", "#discard-queue",
  "#receipt-panel", "#receipt-title", "#receipt-source", "#receipt-saved-at",
  "#receipt-folder", "#receipt-size",
  "#receipt-archive", "#receipt-index", "#receipt-local-index", "#receipt-remote-ai", "#open-document",
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
const popupPermissionRequests = [];
const popupPermissionRemovals = [];
const popupRuntimeMessages = [];
const popupGrantedPermissions = new Set();
const popupGrantedOrigins = new Set(["https://already.example/*"]);
let popupHighlightedTabFixtures = [];
let popupPermissionRequestGranted = true;
let popupBatchShouldFail = false;
let popupMessageListener;
const popupFailedTabIDs = new Set();
const popupBrowser = {
  runtime: {
    onMessage: {
      addListener(listener) { popupMessageListener = listener; }
    },
    async sendMessage(message) {
      popupRuntimeMessages.push(message);
      if (message.type === "capture-tabs-batch") {
        if (popupBatchShouldFail) return { ok: false, error: "模拟批量失败" };
        const items = message.tabIdentities.map((identity) => {
          popupMessageListener?.({
            type: "capture-tabs-batch-progress",
            batchOperationID: message.batchOperationID,
            tabId: identity.tabId,
            status: "saving"
          });
          const failed = popupFailedTabIDs.has(identity.tabId);
          const item = {
            ...identity,
            status: failed ? "failed" : "saved",
            error: failed ? "模拟单项失败" : null,
            receipt: null
          };
          popupMessageListener?.({
            type: "capture-tabs-batch-progress",
            batchOperationID: message.batchOperationID,
            tabId: identity.tabId,
            status: item.status,
            error: item.error
          });
          return item;
        });
        const errors = items
          .filter((item) => item.status === "failed")
          .map((item) => ({ tabId: item.tabId, message: item.error }));
        return {
          ok: true,
          result: {
            requestedCount: message.tabIdentities.length,
            savedCount: message.tabIdentities.length - errors.length,
            failedCount: errors.length,
            conflictCount: 0,
            queuedDuringBatch: 0,
            errors,
            items,
            receipts: []
          }
        };
      }
      if (message.type === "capture-queue-status") {
        return { ok: true, result: { queuedCount: 0, blockedCount: 0, totalBytes: 0 } };
      }
      if (message.type === "set-capture-queue-privacy") {
        return {
          ok: true,
          result: {
            queueState: "empty",
            retentionDays: 30,
            privacyMode: message.privacyMode,
            allowPrivateSites: message.allowPrivateSites,
            queuedCount: 0,
            quarantinedCount: 0,
            blockedCount: 0,
            minimizedCount: 1,
            purgedCount: 0,
            queueItems: [],
            quarantinedItems: []
          }
        };
      }
      if (message.type === "capture-and-save") {
        return {
          ok: true,
          result: {
            documentID: "22222222-2222-2222-2222-222222222222",
            title: "直接保存测试",
            sourceURL: "https://www.example.com/article",
            savedAt: new Date().toISOString(),
            folder: null,
            fileSizeBytes: 1024,
            archiveType: "none",
            indexStatus: "ready",
            allowsLocalSemanticIndex: message.allowsLocalSemanticIndex,
            allowsRemoteAIUse: message.allowsRemoteAIUse,
            insertedCount: 1,
            updatedCount: 0,
            skippedCount: 0
          }
        };
      }
      return { ok: true, result: {} };
    }
  },
  storage: { local: { async get() { return {}; }, async set() {}, async remove() {} } },
  tabs: {
    async query() {
      return popupHighlightedTabFixtures.map((tab) => popupGrantedPermissions.has("tabs")
        ? { ...tab }
        : { id: tab.id });
    }
  },
  permissions: {
    async contains(details) {
      const named = details.permissions || [];
      const origins = details.origins || [];
      return named.every((permission) => popupGrantedPermissions.has(permission))
        && origins.every((origin) => popupGrantedOrigins.has(origin));
    },
    async request(details) {
      popupPermissionRequests.push({
        permissions: [...(details.permissions || [])],
        origins: [...(details.origins || [])]
      });
      if (!popupPermissionRequestGranted) return false;
      for (const permission of details.permissions || []) popupGrantedPermissions.add(permission);
      for (const origin of details.origins || []) popupGrantedOrigins.add(origin);
      return true;
    },
    async remove(details) {
      popupPermissionRemovals.push({
        permissions: [...(details.permissions || [])],
        origins: [...(details.origins || [])]
      });
      for (const permission of details.permissions || []) popupGrantedPermissions.delete(permission);
      for (const origin of details.origins || []) popupGrantedOrigins.delete(origin);
      return true;
    }
  },
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
  confirm: () => true,
  Option: class {
    constructor(label, value) {
      this.label = label;
      this.text = label;
      this.value = value;
    }
  },
  document: {
    documentElement: { lang: "zh-CN" },
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
let preventedConnectionSubmit = false;
popupElements.get("#connection-form").listeners.get("submit")({
  preventDefault() { preventedConnectionSubmit = true; }
});
assert.equal(preventedConnectionSubmit, true);
assert.match(popupElements.get("#alert").textContent, /粘贴应用连接令牌/);
vm.runInContext('setConnectionState("disconnected")', popupContext);
assert.equal(popupElements.get("#connection-panel").hidden, false);
assert.equal(popupElements.get("#session-panel").hidden, true);
assert.equal(popupElements.get("#save-panel").hidden, true);
assert.equal(popupElements.get("#organization-panel").hidden, true);
assert.equal(popupElements.get("#save-now").disabled, true);
assert.equal(popupElements.get("main").attributes.get("aria-busy"), "false");
assert.equal(vm.runInContext("captureModeShortLabel('full-page')", popupContext), "完整网页");
vm.runInContext(`populateFolderOptions([
  { id: "folder-a", name: "产品研究" },
  { id: "folder-b", name: "技术资料" },
  { id: "folder-c", name: "待读" }
], "folder-a", "技术")`, popupContext);
assert.deepEqual(
  popupElements.get("#folder").options.map((option) => option.value),
  ["", "folder-a", "folder-b"]
);
assert.equal(popupElements.get("#folder-search-result").textContent, "共 1 个分类");
assert.equal(popupElements.get("#folder-empty-state").hidden, true);
vm.runInContext(`populateFolderOptions([
  { id: "folder-a", name: "产品研究" },
  { id: "folder-b", name: "技术资料" },
  { id: "folder-c", name: "待读" }
], "", "不存在")`, popupContext);
assert.equal(popupElements.get("#folder-search-result").textContent, "共 0 个分类");
assert.equal(popupElements.get("#folder-empty-state").hidden, false);
assert.equal(popupElements.get("#folder-empty-state").textContent, "没有匹配的分类。");
vm.runInContext('setConnectionState("connected")', popupContext);
assert.equal(popupElements.get("#organization-panel").hidden, false);
assert.equal(popupElements.get("#session-panel").hidden, false);
assert.equal(popupElements.get("#save-now").disabled, false);
vm.runInContext("updateTokenExpiry('2026-08-18T00:00:00Z')", popupContext);
assert.match(popupElements.get("#token-expiry").textContent, /令牌有效至/);
vm.runInContext(`
  activeTab = { id: 42, url: "https://www.example.com/article", title: "当前文章" };
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
popupElements.get("#save-panel").hidden = false;
popupElements.get("#save-now").disabled = false;
vm.runInContext(`handlePopupKeyboardShortcut({
  metaKey: true,
  ctrlKey: false,
  shiftKey: false,
  key: "Enter",
  preventDefault() {}
})`, popupContext);
assert.equal(popupElements.get("#save-now").clicked, true);
popupElements.get("#capture-local-index").checked = true;
popupElements.get("#capture-remote-ai").checked = false;
await vm.runInContext("saveCurrentPage()", popupContext);
const directSaveMessage = [...popupRuntimeMessages]
  .reverse()
  .find((message) => message.type === "capture-and-save");
assert.ok(directSaveMessage);
assert.equal(directSaveMessage.tabId, 42);
assert.equal(directSaveMessage.captureMode, "cleaned-article");
assert.equal(directSaveMessage.folderID, "folder-a");
assert.equal(directSaveMessage.allowsLocalSemanticIndex, true);
assert.equal(directSaveMessage.allowsRemoteAIUse, false);
assert.equal(popupElements.get("#receipt-panel").hidden, false);
vm.runInContext("resetCaptureFlow()", popupContext);
assert.equal(popupElements.get("#save-panel").hidden, false);
assert.equal(
  vm.runInContext('readableError(new Error("NetworkError when attempting to fetch resource."))', popupContext),
  "无法连接应用。请先打开“RepoPress Studio”，再检查令牌。"
);
vm.runInContext('showStatus("无法连接", "error")', popupContext);
assert.equal(popupElements.get("#status").textContent, "");
assert.equal(popupElements.get("#alert").textContent, "无法连接");
vm.runInContext('showStatus("连接成功", "success")', popupContext);
assert.equal(popupElements.get("#status").textContent, "连接成功");
assert.equal(popupElements.get("#alert").textContent, "");
vm.runInContext("updateQueuePanel({ queueState: 'unknown' })", popupContext);
assert.equal(popupElements.get("#queue-state").textContent, "状态未知");
assert.match(popupElements.get("#queue-summary").textContent, /正在读取/);
vm.runInContext(`updateQueuePanel({
  queueState: "content",
  retentionDays: 30,
  privacyMode: "full-content",
  allowPrivateSites: true,
  fullContentCount: 1,
  queuedCount: 2,
  quarantinedCount: 1,
  blockedCount: 1,
  totalBytes: 2048,
  queueItems: [{
    id: "queued-item",
    title: "离线文章",
    sourceURL: "https://queue.example/article",
    status: "retrying",
    createdAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
    previewText: "等待恢复的正文片段",
    lastError: "暂时无法连接应用",
    byteSize: 1024,
    storedContentMode: "full-content"
  }],
  quarantinedItems: [{
    id: "quarantined-item",
    title: "损坏项目",
    quarantinedAt: new Date().toISOString(),
    expiresAt: new Date(Date.now() + 86_400_000).toISOString(),
    reason: "schema 无法识别",
    originalSchemaVersion: 99,
    byteSize: 1024
  }]
})`, popupContext);
assert.equal(popupElements.get("#queue-panel").hidden, false);
assert.equal(popupElements.get("#queue-state").textContent, "有待处理内容");
assert.equal(popupElements.get("#queue-count").textContent, "3");
assert.match(popupElements.get("#queue-summary").textContent, /1 项等待手动处理/);
assert.equal(popupElements.get("#queue-items").children.length, 2);
assert.equal(popupElements.get("#queue-privacy-mode").value, "full-content");
assert.equal(popupElements.get("#queue-allow-private-sites").checked, true);
popupElements.get("#queue-privacy-mode").value = "links-only";
popupElements.get("#queue-allow-private-sites").checked = false;
await vm.runInContext("updateCaptureQueuePrivacy()", popupContext);
const popupPrivacyMessage = popupRuntimeMessages
  .filter((message) => message.type === "set-capture-queue-privacy")
  .at(-1);
assert.equal(popupPrivacyMessage.privacyMode, "links-only");
assert.equal(popupPrivacyMessage.allowPrivateSites, false);
assert.equal(popupElements.get("#queue-privacy-mode").value, "links-only");
vm.runInContext(`updateQueuePanel({
  queueState: "failed",
  queueSchemaVersion: 99,
  queueError: "未来版本队列无法读取",
  queuedCount: 0,
  quarantinedCount: 0
})`, popupContext);
assert.equal(popupElements.get("#queue-state").textContent, "读取失败");
assert.match(popupElements.get("#queue-summary").textContent, /数据未被修改/);
assert.equal(popupElements.get("#export-queue").disabled, false);
assert.equal(popupElements.get("#retry-queue").disabled, true);
vm.runInContext("updateQueuePanel({ queueState: 'empty', retentionDays: 7 })", popupContext);
assert.equal(popupElements.get("#queue-state").textContent, "队列为空");
assert.match(popupElements.get("#queue-summary").textContent, /保留 7 天/);
vm.runInContext(`showReceipt({
  documentID: "11111111-1111-1111-1111-111111111111",
  title: "长期参考",
  sourceURL: "https://www.example.com/article#saved-section",
  savedAt: new Date().toISOString(),
  folder: { name: "阅读" },
  fileSizeBytes: 2048,
  archiveType: "html",
  indexStatus: "ready",
  allowsLocalSemanticIndex: true,
  allowsRemoteAIUse: true
})`, popupContext);
assert.equal(popupElements.get("#receipt-panel").hidden, false);
assert.equal(popupElements.get("#save-panel").hidden, true);
assert.equal(popupElements.get("#duplicate-panel").hidden, true);
assert.equal(vm.runInContext("captureFlowState", popupContext), "completed");
assert.equal(popupElements.get("#receipt-title").textContent, "长期参考");
assert.equal(popupElements.get("#receipt-source").textContent, "www.example.com");
assert.notEqual(popupElements.get("#receipt-saved-at").textContent, "");
assert.equal(popupElements.get("#receipt-folder").textContent, "阅读");
assert.equal(popupElements.get("#receipt-size").textContent, "2.0 KB");
assert.equal(popupElements.get("#receipt-archive").textContent, "离线 HTML");
assert.equal(popupElements.get("#receipt-index").textContent, "全文与语义索引已就绪");
assert.equal(popupElements.get("#receipt-local-index").textContent, "已建立");
assert.equal(popupElements.get("#receipt-remote-ai").textContent, "允许发送");
vm.runInContext(`
  activeTab = { url: "https://other.example/article" };
  showReceipt({
    documentID: "11111111-1111-1111-1111-111111111111",
    sourceURL: "https://www.example.com/article",
    savedAt: new Date().toISOString()
  });
`, popupContext);
assert.equal(popupElements.get("#receipt-panel").hidden, true);
assert.equal(vm.runInContext("lastReceipt", popupContext), null);
assert.equal(vm.runInContext("captureFlowState", popupContext), "capture");
vm.runInContext(`
  activeTab = { url: "https://www.example.com/article" };
  showReceipt({
    documentID: "11111111-1111-1111-1111-111111111111",
    sourceURL: "https://www.example.com/article",
    savedAt: new Date(Date.now() - RECEIPT_RESTORE_MAX_AGE_MS - 1).toISOString()
  });
`, popupContext);
assert.equal(popupElements.get("#receipt-panel").hidden, true);
vm.runInContext(`showDuplicateConflict({
  queueID: "queue-1",
  sourceURL: "https://www.example.com/article#duplicate",
  createdAt: new Date().toISOString(),
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
assert.equal(popupElements.get("#save-panel").hidden, true);
assert.equal(popupElements.get("#receipt-panel").hidden, true);
assert.equal(vm.runInContext("captureFlowState", popupContext), "duplicate");
assert.equal(popupElements.get("#duplicate-document").textContent, "已有网页");
assert.equal(popupElements.get("#duplicate-folder").textContent, "阅读");
assert.equal(popupElements.get("#duplicate-size").textContent, "4.0 KB");
assert.equal(popupElements.get("#duplicate-target").textContent, "产品研究");
assert.match(popupElements.get("#duplicate-message").textContent, /正文与现有资料不同/);
await vm.runInContext("cancelDuplicateCapture()", popupContext);
assert.equal(vm.runInContext("captureFlowState", popupContext), "capture");
assert.equal(vm.runInContext("activeDuplicateConflict", popupContext), null);
assert.equal(popupElements.get("#duplicate-panel").hidden, true);
assert.equal(popupElements.get("#save-panel").hidden, false);
assert.equal(popupElements.get("#receipt-panel").hidden, true);
popupElements.get("#token").value = "temporary-token";
await vm.runInContext("disconnectFromBridge(true)", popupContext);
assert.equal(popupElements.get("#token").value, "");
assert.equal(popupElements.get("#connection-panel").hidden, false);
assert.match(popupElements.get("#status").textContent, /旧令牌已从插件中清除/);

popupElements.get("#token").value = "batch-token";
vm.runInContext('setConnectionState("connected")', popupContext);
popupHighlightedTabFixtures = [
  { id: 31, url: "https://already.example/article", title: "已有权限" },
  { id: 32, url: "https://new.example:8443/report", title: "新网站" },
  { id: 33, url: "http://third.example/notes", title: "第三个网站" }
];
await vm.runInContext("refreshHighlightedTabs()", popupContext);
await vm.runInContext("batchSaveSelectedTabs()", popupContext);
assert.deepEqual(popupPermissionRequests.at(-1), { permissions: ["tabs"], origins: [] });
assert.deepEqual(popupPermissionRemovals.at(-1), { permissions: ["tabs"], origins: [] });
assert.equal(popupGrantedPermissions.has("tabs"), false);
assert.equal(popupRuntimeMessages.some((message) => message.type === "capture-tabs-batch"), false);
assert.deepEqual(
  Array.from(vm.runInContext("pendingBatchPermissionPlan.requestOrigins", popupContext)),
  ["https://new.example/*", "http://third.example/*"]
);
assert.deepEqual(
  JSON.parse(JSON.stringify(vm.runInContext("pendingBatchPermissionPlan.tabIdentities", popupContext))),
  [
    { tabId: 31, url: "https://already.example/article", title: "已有权限" },
    { tabId: 32, url: "https://new.example:8443/report", title: "新网站" },
    { tabId: 33, url: "http://third.example/notes", title: "第三个网站" }
  ]
);
assert.notEqual(
  vm.runInContext(
    "batchTabSignature([{ id: 31, url: 'https://already.example/article' }])",
    popupContext
  ),
  vm.runInContext(
    "batchTabSignature([{ id: 31, url: 'https://already.example/other' }])",
    popupContext
  )
);
assert.equal(popupElements.get("#batch-review-panel").hidden, false);
assert.match(popupElements.get("#batch-settings-summary").textContent, /分类：产品研究/);
assert.match(popupElements.get("#batch-settings-summary").textContent, /模式：净化正文/);
assert.match(popupElements.get("#batch-settings-summary").textContent, /本地索引：已建立/);
assert.match(popupElements.get("#batch-settings-summary").textContent, /远程 AI：禁止发送/);
assert.equal(popupElements.get("#batch-items").children.length, 3);
assert.equal(popupElements.get("#batch-items").children[0].children[0].textContent, "已有权限");
assert.equal(popupElements.get("#batch-items").children[0].children[1].textContent, "already.example");
assert.match(popupElements.get("#batch-hint").textContent, /核对下方标题/);

await vm.runInContext("batchSaveSelectedTabs()", popupContext);
assert.deepEqual(popupPermissionRequests.at(-1), {
  permissions: [],
  origins: ["https://new.example/*", "http://third.example/*"]
});
const popupBatchMessage = popupRuntimeMessages.find((message) => message.type === "capture-tabs-batch");
assert.deepEqual(
  JSON.parse(JSON.stringify(popupBatchMessage.tabIdentities)),
  [
    { tabId: 31, url: "https://already.example/article", title: "已有权限" },
    { tabId: 32, url: "https://new.example:8443/report", title: "新网站" },
    { tabId: 33, url: "http://third.example/notes", title: "第三个网站" }
  ]
);
assert.deepEqual(
  Array.from(popupBatchMessage.temporaryPermissionOrigins),
  ["https://new.example/*", "http://third.example/*"]
);
assert.deepEqual(popupPermissionRemovals.at(-1), {
  permissions: [],
  origins: ["https://new.example/*", "http://third.example/*"]
});
assert.equal(popupGrantedOrigins.has("https://already.example/*"), true);
assert.equal(popupGrantedOrigins.has("https://new.example/*"), false);
assert.equal(popupGrantedOrigins.has("http://third.example/*"), false);

popupFailedTabIDs.add(32);
const itemFailureMessageCount = popupRuntimeMessages
  .filter((message) => message.type === "capture-tabs-batch").length;
await vm.runInContext("batchSaveSelectedTabs()", popupContext);
await vm.runInContext("batchSaveSelectedTabs()", popupContext);
assert.equal(
  popupRuntimeMessages.filter((message) => message.type === "capture-tabs-batch").length,
  itemFailureMessageCount + 1
);
assert.equal(popupElements.get("#batch-retry-failed").hidden, false);
assert.match(popupElements.get("#batch-retry-failed").textContent, /1/);
assert.equal(
  vm.runInContext("batchReviewItemsState.find((item) => item.tabId === 32).error", popupContext),
  "模拟单项失败"
);
popupFailedTabIDs.clear();
await vm.runInContext("retryFailedBatchItems()", popupContext);
const retryFailedMessage = popupRuntimeMessages
  .filter((message) => message.type === "capture-tabs-batch").at(-1);
assert.equal(retryFailedMessage.tabIdentities.length, 1);
assert.equal(retryFailedMessage.tabIdentities[0].tabId, 32);
assert.equal(vm.runInContext(
  "batchReviewItemsState.every((item) => item.status === 'saved')",
  popupContext
), true);
assert.equal(popupElements.get("#batch-retry-failed").hidden, true);

const successfulBatchMessageCount = popupRuntimeMessages
  .filter((message) => message.type === "capture-tabs-batch").length;
popupBatchShouldFail = true;
await vm.runInContext("batchSaveSelectedTabs()", popupContext);
await vm.runInContext("batchSaveSelectedTabs()", popupContext);
assert.equal(
  popupRuntimeMessages.filter((message) => message.type === "capture-tabs-batch").length,
  successfulBatchMessageCount + 1
);
assert.match(popupElements.get("#alert").textContent, /模拟批量失败/);
assert.equal(popupGrantedOrigins.has("https://new.example/*"), false);
assert.equal(popupGrantedOrigins.has("http://third.example/*"), false);

popupBatchShouldFail = false;
vm.runInContext("pendingBatchPermissionPlan = null", popupContext);
popupPermissionRequestGranted = false;
const batchMessagesBeforeTabsRefusal = popupRuntimeMessages
  .filter((message) => message.type === "capture-tabs-batch").length;
await vm.runInContext("batchSaveSelectedTabs()", popupContext);
assert.equal(
  popupRuntimeMessages.filter((message) => message.type === "capture-tabs-batch").length,
  batchMessagesBeforeTabsRefusal
);
assert.deepEqual(popupPermissionRequests.at(-1), { permissions: ["tabs"], origins: [] });
assert.equal(popupElements.get("#batch-save").attributes.get("aria-busy"), "false");
assert.equal(popupElements.get("#batch-save").disabled, false);
assert.doesNotMatch(popupElements.get("#batch-save").textContent, /正在识别/);
assert.match(popupElements.get("#batch-save").textContent, /批量保存 3 个已选择标签页/);
assert.match(popupElements.get("#alert").textContent, /批量保存已取消/);

popupPermissionRequestGranted = true;
await vm.runInContext("batchSaveSelectedTabs()", popupContext);
assert.notEqual(vm.runInContext("pendingBatchPermissionPlan", popupContext), null);

popupPermissionRequestGranted = false;
const batchMessagesBeforeRefusal = popupRuntimeMessages
  .filter((message) => message.type === "capture-tabs-batch").length;
await vm.runInContext("batchSaveSelectedTabs()", popupContext);
assert.equal(
  popupRuntimeMessages.filter((message) => message.type === "capture-tabs-batch").length,
  batchMessagesBeforeRefusal
);
assert.match(popupElements.get("#alert").textContent, /批量保存已取消/);
popupPermissionRequestGranted = true;

const backgroundModuleNames = [
  "background-security.js",
  "background-queue-storage.js",
  "background-queue-operations.js",
  "background-capture.js"
];
const backgroundModuleSources = await Promise.all(backgroundModuleNames.map((name) =>
  readFile(path.join(firefoxRoot, name), "utf8")
));
const backgroundSource = await readFile(path.join(firefoxRoot, "background.js"), "utf8");
const completeBackgroundSource = [...backgroundModuleSources, backgroundSource].join("\n");
assert.match(completeBackgroundSource, /redirect:\s*"manual"/);
assert.match(completeBackgroundSource, /response\.body\?\.getReader\?\.\(\)/);
assert.match(completeBackgroundSource, /response\.headers\.get\("content-length"\)/);
assert.match(completeBackgroundSource, /reader\.cancel\("resource size limit reached"\)/);
assert.match(completeBackgroundSource, /maximumRedirects\s*=\s*5/);
assert.doesNotMatch(completeBackgroundSource, /await response\.(?:blob|text)\(\)/);
const limitedReaderExpression = completeBackgroundSource.match(
  /const readLimitedResponseBody = (async \(response, maximumBytes, controller\) => \{[\s\S]*?\n    \});\n    const fetchResourceBytes/
)?.[1];
assert.ok(limitedReaderExpression, "streaming resource reader is missing");
const makeLimitedReader = new Function(
  "archiveDeadline",
  `return (${limitedReaderExpression});`
);
const readLimitedResponseBody = makeLimitedReader(Date.now() + 10_000);
const streamingResponse = (chunks, contentLength = null) => {
  let index = 0;
  let cancelled = false;
  return {
    response: {
      headers: {
        get(name) {
          return name === "content-length" ? contentLength : null;
        }
      },
      body: {
        getReader() {
          return {
            async read() {
              if (index >= chunks.length) return { done: true, value: undefined };
              return { done: false, value: chunks[index++] };
            },
            async cancel() {
              cancelled = true;
            }
          };
        }
      }
    },
    wasCancelled: () => cancelled
  };
};
const withinLimit = streamingResponse([
  new Uint8Array([1, 2, 3]),
  new Uint8Array([4, 5])
]);
const withinLimitController = { aborted: false, abort() { this.aborted = true; } };
const withinLimitBytes = await readLimitedResponseBody(
  withinLimit.response,
  5,
  withinLimitController
);
assert.deepEqual(Array.from(withinLimitBytes), [1, 2, 3, 4, 5]);
assert.equal(withinLimitController.aborted, false);
const oversizedHeader = streamingResponse([], "6");
const oversizedHeaderController = { aborted: false, abort() { this.aborted = true; } };
await assert.rejects(
  readLimitedResponseBody(oversizedHeader.response, 5, oversizedHeaderController),
  /content-length exceeds limit/
);
assert.equal(oversizedHeaderController.aborted, true);
const oversizedStream = streamingResponse([
  new Uint8Array([1, 2, 3]),
  new Uint8Array([4, 5, 6])
]);
const oversizedStreamController = { aborted: false, abort() { this.aborted = true; } };
await assert.rejects(
  readLimitedResponseBody(oversizedStream.response, 5, oversizedStreamController),
  /stream exceeds limit/
);
assert.equal(oversizedStreamController.aborted, true);
assert.equal(oversizedStream.wasCancelled(), true);
let messageListener;
let postedBody;
let bridgeAvailable = true;
let bridgeStatus = 200;
let bridgeErrorCode = null;
let lastFetchURL;
let lastFetchOptions;
let fetchCount = 0;
let duplicateMode = false;
let loseNextImportResponseAfterCommit = false;
const completedImportReceipts = new Map();
const backgroundRuntimeMessages = [];
let commandListener;
let menuClickListener;
let headersReceivedListener;
const createdMenus = [];
const toolbarState = {};
const savedDocumentID = "11111111-1111-1111-1111-111111111111";
const backgroundStorage = { bridgeToken: "test-token" };
let backgroundStorageReadFailure = false;
let backgroundTabIncognito = false;
const activeAlarms = new Map();
const backgroundGrantedOrigins = new Set();
const backgroundPermissionRemovals = [];
const page = {
  pageURL: "https://example.com/article",
  documentId: "document-a",
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
const scriptedPageResults = [];
const browser = {
  runtime: {
    onMessage: {
      addListener(listener) {
        messageListener = listener;
      }
    },
    async sendMessage(message) {
      backgroundRuntimeMessages.push(message);
      return undefined;
    },
    onStartup: { addListener() {} },
    onInstalled: { addListener() {} }
  },
  dns: {
    async resolve(hostname, flags) {
      assert.deepEqual(Array.from(flags), ["bypass_cache"]);
      if (hostname === "private-target.example") return { addresses: ["10.0.0.8"] };
      if (hostname === "ipv6-private.example") return { addresses: ["fd00::8"] };
      if (hostname === "dns-failure.example") throw new Error("模拟 DNS 失败");
      return { addresses: ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"] };
    }
  },
  webRequest: {
    onHeadersReceived: {
      addListener(listener, filter, extraInfoSpec) {
        headersReceivedListener = listener;
        assert.deepEqual(Array.from(filter.types), ["xmlhttprequest"]);
        assert.deepEqual(Array.from(extraInfoSpec), ["blocking"]);
      }
    }
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
    async query() {
      return [{ id: 9, url: page.pageURL, title: page.title, incognito: backgroundTabIncognito }];
    },
    async get(tabId) {
      assert.equal(tabId, 9);
      return { id: 9, url: page.pageURL, title: page.title, incognito: backgroundTabIncognito };
    }
  },
  permissions: {
    async contains(details) {
      return (details.origins || []).every((origin) => backgroundGrantedOrigins.has(origin));
    },
    async remove(details) {
      backgroundPermissionRemovals.push([...(details.origins || [])]);
      for (const origin of details.origins || []) backgroundGrantedOrigins.delete(origin);
      return true;
    }
  },
  alarms: {
    onAlarm: { addListener() {} },
    async create(name, options) { activeAlarms.set(name, options); },
    async clear(name) { return activeAlarms.delete(name); }
  },
  storage: {
    local: {
      async get(keys) {
        if (backgroundStorageReadFailure) throw new Error("模拟本地存储读取失败");
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
    async executeScript(details) {
      const scriptedPage = scriptedPageResults.length ? scriptedPageResults.shift() : page;
      const result = details?.func?.name === "readPageIdentity"
        ? { pageURL: scriptedPage.pageURL }
        : scriptedPage;
      return [{ result, documentId: scriptedPage.documentId }];
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
    lastFetchOptions = options;
    postedBody = options.body ? JSON.parse(options.body) : null;
    if (_url.endsWith("/v1/folders")) {
      return {
        ok: true,
        status: 200,
        async json() {
          return { folders: [], tokenExpiresAt: "2026-08-18T00:00:00Z" };
        }
      };
    }
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
            operationID: postedBody.operationID,
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
    const completedReceipt = completedImportReceipts.get(postedBody?.operationID);
    if (completedReceipt) {
      return {
        ok: true,
        status: 200,
        async json() { return { ...completedReceipt, replayed: true }; }
      };
    }
    const successfulReceipt = {
      operationID: postedBody?.operationID,
      insertedCount: 1,
      updatedCount: 0,
      skippedCount: 0,
      action: postedBody?.duplicateResolution === "move-only" ? "moved" : "inserted",
      documentID: savedDocumentID,
      title: page.title,
      folder: { id: "22222222-2222-2222-2222-222222222222", name: "阅读" },
      fileSizeBytes: 2048,
      archiveType: page.archiveReport.format,
      indexStatus: "ready",
      allowsLocalSemanticIndex: postedBody?.capture?.allowsLocalSemanticIndex !== false,
      allowsRemoteAIUse: postedBody?.capture?.allowsRemoteAIUse === true,
      replayed: false
    };
    if (bridgeStatus >= 200 && bridgeStatus < 300) {
      completedImportReceipts.set(postedBody?.operationID, successfulReceipt);
      if (loseNextImportResponseAfterCommit) {
        loseNextImportResponseAfterCommit = false;
        throw new TypeError("Failed to fetch");
      }
    }
    return {
      ok: bridgeStatus >= 200 && bridgeStatus < 300,
      status: bridgeStatus,
      async json() {
        return bridgeStatus >= 200 && bridgeStatus < 300
          ? successfulReceipt
          : { error: "capture rejected", code: bridgeErrorCode };
      }
    };
  },
  globalThis: null
});
context.globalThis = context;
vm.runInContext(generatedProtocolSource, context, { filename: "protocol.generated.js" });
// Production background.js loads the responsibility modules after creating
// extensionAPI. The VM harness mirrors that dependency without implementing
// importScripts itself.
context.extensionAPI = context.browser ?? context.chrome;
for (const [index, source] of backgroundModuleSources.entries()) {
  vm.runInContext(source, context, { filename: backgroundModuleNames[index] });
}
vm.runInContext(backgroundSource, context, { filename: "background.js" });
assert.equal(typeof messageListener, "function");
assert.equal(typeof commandListener, "function");
assert.equal(typeof menuClickListener, "function");
assert.equal(typeof headersReceivedListener, "function");
const sendBackgroundMessage = (
  message,
  sender = { tab: { id: 9 }, url: page.pageURL }
) => new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error(`${message.type} timed out`)), 1_000);
  messageListener(message, sender, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});

const allowedArchiveResource = await sendBackgroundMessage({
  type: "validate-archive-resource-url",
  url: "https://cdn.example.com/image.png#fragment"
});
assert.equal(allowedArchiveResource.ok, true);
assert.equal(allowedArchiveResource.result.allowed, true);
assert.equal(allowedArchiveResource.result.validationMode, "resolved");
assert.equal(allowedArchiveResource.result.peerGuarded, true);
assert.match(allowedArchiveResource.result.peerGuardID, /^[0-9a-f-]{36}$/);
assert.equal(allowedArchiveResource.result.url, "https://cdn.example.com/image.png");
assert.equal(headersReceivedListener({
  url: allowedArchiveResource.result.url,
  tabId: 9,
  ip: "93.184.216.34"
}).cancel, undefined);
assert.equal(headersReceivedListener({
  url: allowedArchiveResource.result.url,
  tabId: 9,
  ip: "127.0.0.1"
}).cancel, true);
const confirmedArchivePeer = await sendBackgroundMessage({
  type: "confirm-archive-resource-peer",
  url: allowedArchiveResource.result.url,
  guardID: allowedArchiveResource.result.peerGuardID
});
assert.equal(confirmedArchivePeer.ok, true);
assert.equal(confirmedArchivePeer.result.verified, true);
const reboundArchiveResource = await sendBackgroundMessage({
  type: "validate-archive-resource-url",
  url: "https://cdn.example.com/rebound.png"
});
assert.equal(reboundArchiveResource.ok, true);
assert.equal(headersReceivedListener({
  url: reboundArchiveResource.result.url,
  tabId: 9,
  ip: "192.168.1.8"
}).cancel, true);
const rejectedReboundConfirmation = await sendBackgroundMessage({
  type: "confirm-archive-resource-peer",
  url: reboundArchiveResource.result.url,
  guardID: reboundArchiveResource.result.peerGuardID
});
assert.equal(rejectedReboundConfirmation.ok, false);
assert.equal(rejectedReboundConfirmation.code, "archive-resource-peer-unverified");
const unobservedArchiveResource = await sendBackgroundMessage({
  type: "validate-archive-resource-url",
  url: "https://cdn.example.com/unobserved.png"
});
const unobservedArchiveConfirmation = await sendBackgroundMessage({
  type: "confirm-archive-resource-peer",
  url: unobservedArchiveResource.result.url,
  guardID: unobservedArchiveResource.result.peerGuardID
});
assert.equal(unobservedArchiveConfirmation.ok, false);
assert.equal(unobservedArchiveConfirmation.code, "archive-resource-peer-unverified");
const allowedPublicIPv6 = await sendBackgroundMessage({
  type: "validate-archive-resource-url",
  url: "https://[2606:4700:4700::1111]/asset.css"
});
assert.equal(allowedPublicIPv6.ok, true);
assert.equal(allowedPublicIPv6.result.validationMode, "literal");
assert.equal(allowedPublicIPv6.result.peerGuarded, false);
for (const blockedURL of [
  "http://127.1/private.png",
  "http://[::1]/private.png",
  "http://169.254.169.254/latest/meta-data/",
  "http://router.local/private.css"
]) {
  const blocked = await sendBackgroundMessage({
    type: "validate-archive-resource-url",
    url: blockedURL
  });
  assert.equal(blocked.ok, false);
  assert.equal(blocked.code, "archive-resource-blocked");
}
for (const hostname of ["private-target.example", "ipv6-private.example"]) {
  const blocked = await sendBackgroundMessage({
    type: "validate-archive-resource-url",
    url: `https://${hostname}/resource`
  });
  assert.equal(blocked.ok, false);
  assert.equal(blocked.code, "archive-resource-blocked");
}
const failedArchiveDNS = await sendBackgroundMessage({
  type: "validate-archive-resource-url",
  url: "https://dns-failure.example/resource"
});
assert.equal(failedArchiveDNS.ok, false);
assert.equal(failedArchiveDNS.code, "archive-resource-dns-failed");
const missingArchiveSender = await sendBackgroundMessage({
  type: "validate-archive-resource-url",
  url: "https://cdn.example.com/no-tab.png"
}, {});
assert.equal(missingArchiveSender.ok, false);
assert.equal(missingArchiveSender.code, "archive-resource-peer-unavailable");
const savedDNSResolve = browser.dns.resolve;
browser.dns.resolve = null;
const unavailableArchivePeerCheck = await sendBackgroundMessage({
  type: "validate-archive-resource-url",
  url: "https://cdn.example.com/no-dns.png"
});
assert.equal(unavailableArchivePeerCheck.ok, false);
assert.equal(unavailableArchivePeerCheck.code, "archive-resource-peer-unavailable");
browser.dns.resolve = savedDNSResolve;

const legacyQueueEntry = {
  schemaVersion: 1,
  id: "legacy-entry",
  createdAt: new Date().toISOString(),
  updatedAt: new Date().toISOString(),
  attempts: 0,
  nextAttemptAt: null,
  blocked: false,
  lastError: "",
  envelope: {
    operationID: "11111111-1111-4111-8111-111111111111",
    folderID: null,
    newFolderName: null,
    capture: {
      sourceURL: page.pageURL,
      title: "旧版队列网页",
      contentText: "旧版离线正文",
      captureMode: "cleaned-article",
      allowsAIUse: false
    }
  },
  archiveReport: null
};
backgroundStorage.pendingKnowledgeCapturesV1 = [
  legacyQueueEntry,
  { schemaVersion: 99, token: "must-not-survive", payload: "损坏内容" }
];
const migratedQueueStatus = await sendBackgroundMessage({ type: "capture-queue-status" });
assert.equal(migratedQueueStatus.ok, true);
assert.equal(migratedQueueStatus.result.queueState, "content");
assert.equal(migratedQueueStatus.result.privacyMode, "full-content");
assert.equal(migratedQueueStatus.result.allowPrivateSites, false);
assert.equal(migratedQueueStatus.result.queuedCount, 1);
assert.equal(migratedQueueStatus.result.quarantinedCount, 1);
assert.equal(migratedQueueStatus.result.queueItems[0].title, "旧版队列网页");
assert.equal(migratedQueueStatus.result.quarantinedItems[0].originalSchemaVersion, 99);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.schemaVersion, 2);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries[0].schemaVersion, 2);
assert.doesNotMatch(
  JSON.stringify(backgroundStorage.pendingKnowledgeCapturesV1.quarantine),
  /must-not-survive/
);

const exportedMigratedQueue = await sendBackgroundMessage({ type: "export-capture-queue" });
assert.equal(exportedMigratedQueue.ok, true);
assert.equal(exportedMigratedQueue.result.export.containsPrivateReadingContent, true);
assert.equal(exportedMigratedQueue.result.export.queue.schemaVersion, 2);
assert.doesNotMatch(JSON.stringify(exportedMigratedQueue.result.export), /must-not-survive/);

const minimizedLegacyQueue = await sendBackgroundMessage({
  type: "set-capture-queue-privacy",
  privacyMode: "links-only",
  allowPrivateSites: false
});
assert.equal(minimizedLegacyQueue.ok, true);
assert.equal(minimizedLegacyQueue.result.privacyMode, "links-only");
assert.equal(minimizedLegacyQueue.result.minimizedCount, 1);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries[0].storedContentMode, "links-only");
assert.equal(
  backgroundStorage.pendingKnowledgeCapturesV1.entries[0].envelope.capture.contentText,
  page.pageURL
);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries[0].envelope.capture.archiveData, null);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.quarantine[0].rawValue, null);
assert.doesNotMatch(
  JSON.stringify(backgroundStorage.pendingKnowledgeCapturesV1),
  /旧版离线正文/
);
const exportedMinimizedQueue = await sendBackgroundMessage({ type: "export-capture-queue" });
assert.equal(exportedMinimizedQueue.result.export.containsPrivateReadingContent, false);
assert.equal(exportedMinimizedQueue.result.export.containsPrivateMetadata, true);

const quarantinedID = migratedQueueStatus.result.quarantinedItems[0].id;
const deletedQuarantine = await sendBackgroundMessage({
  type: "delete-capture-queue-item",
  queueID: quarantinedID,
  quarantined: true
});
assert.equal(deletedQuarantine.ok, true);
assert.equal(deletedQuarantine.result.quarantinedCount, 0);
const deletedLegacyItem = await sendBackgroundMessage({
  type: "delete-capture-queue-item",
  queueID: "legacy-entry",
  quarantined: false
});
assert.equal(deletedLegacyItem.ok, true);
assert.equal(deletedLegacyItem.result.queueState, "empty");

backgroundStorage.pendingKnowledgeCapturesV1 = {
  schemaVersion: 999,
  entries: [{ token: "future-secret", content: "未来版本数据" }]
};
const unknownSchemaStatus = await sendBackgroundMessage({ type: "capture-queue-status" });
assert.equal(unknownSchemaStatus.ok, true);
assert.equal(unknownSchemaStatus.result.queueState, "failed");
assert.equal(unknownSchemaStatus.result.queueErrorCode, "queue-schema-unsupported");
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.schemaVersion, 999);
const rejectedFutureRetention = await sendBackgroundMessage({
  type: "set-capture-queue-retention",
  retentionDays: 7
});
assert.equal(rejectedFutureRetention.ok, false);
assert.equal(backgroundStorage.knowledgeCaptureQueueRetentionDaysV1, 30);
const unknownSchemaExport = await sendBackgroundMessage({ type: "export-capture-queue" });
assert.equal(unknownSchemaExport.result.export.queue.schemaVersion, 999);
assert.doesNotMatch(JSON.stringify(unknownSchemaExport.result.export), /future-secret/);

backgroundStorageReadFailure = true;
const failedReadStatus = await sendBackgroundMessage({ type: "capture-queue-status" });
backgroundStorageReadFailure = false;
assert.equal(failedReadStatus.ok, true);
assert.equal(failedReadStatus.result.queueState, "failed");
assert.match(failedReadStatus.result.queueError, /模拟本地存储读取失败/);

const clearedUnknownSchema = await sendBackgroundMessage({ type: "discard-capture-queue" });
assert.equal(clearedUnknownSchema.ok, true);
assert.equal(clearedUnknownSchema.result.queueState, "empty");
backgroundStorage.knowledgeCaptureQueueRetentionDaysV1 = 30;
backgroundStorage.pendingKnowledgeCapturesV1 = [{
  ...legacyQueueEntry,
  id: "expired-entry",
  createdAt: new Date(Date.now() - 31 * 24 * 60 * 60 * 1_000).toISOString()
}];
const prunedQueueStatus = await sendBackgroundMessage({ type: "capture-queue-status" });
assert.equal(prunedQueueStatus.result.queueState, "empty");
assert.equal(prunedQueueStatus.result.purgedCount, 1);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);
const updatedRetention = await sendBackgroundMessage({
  type: "set-capture-queue-retention",
  retentionDays: 7
});
assert.equal(updatedRetention.ok, true);
assert.equal(updatedRetention.result.retentionDays, 7);
assert.equal(backgroundStorage.knowledgeCaptureQueueRetentionDaysV1, 7);

const callbackTransport = await vm.runInContext(
  'performBridgeRequest("/v1/folders", "GET", "test-token")',
  context
);
assert.equal(callbackTransport.ok, true);
assert.equal(callbackTransport.transport, "loopback");
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
assert.deepEqual(
  JSON.parse(JSON.stringify(previewResponse.result.pageIdentity)),
  { url: page.pageURL, documentId: page.documentId }
);
assert.equal(previewResponse.result.capture.captureMode, "selection");
assert.equal(previewResponse.result.capture.archiveData, null);
assert.equal(previewResponse.result.archiveType, "none");
assert.match(
  previewResponse.result.operationID,
  /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
);

const editedCapture = {
  ...previewResponse.result.capture,
  title: "编辑后的标题",
  authors: ["作者甲", "作者乙"],
  tags: ["研究", "写作"],
  allowsLocalSemanticIndex: false,
  allowsRemoteAIUse: false
};
const preparedSaveResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("prepared save response timed out")), 1_000);
  messageListener({
    type: "save-prepared-capture",
    tabId: 9,
    token: "test-token",
    operationID: previewResponse.result.operationID,
    captureMode: "selection",
    capture: editedCapture
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(preparedSaveResponse.ok, true);
assert.equal(
  lastFetchURL,
  `http://${loopbackProtocol.host}:${loopbackProtocol.port}/v1/import`
);
assert.equal(lastFetchOptions.method, "POST");
assert.equal(lastFetchOptions.headers.Authorization, "Bearer test-token");
assert.equal(
  lastFetchOptions.headers[loopbackProtocol.protocolHeaderName],
  loopbackProtocol.protocolHeaderValue
);
assert.equal(postedBody.capture.title, "编辑后的标题");
assert.deepEqual(postedBody.capture.authors, ["作者甲", "作者乙"]);
assert.deepEqual(postedBody.capture.tags, ["研究", "写作"]);
assert.equal(postedBody.capture.allowsLocalSemanticIndex, false);
assert.equal(postedBody.capture.allowsRemoteAIUse, false);
assert.equal(postedBody.capture.captureMode, "selection");
assert.equal(postedBody.capture.archiveFormat, null);
assert.equal(postedBody.operationID, previewResponse.result.operationID);

const backgroundBatchTabIdentities = [
  { tabId: 9, url: page.pageURL, title: "批量页面一" },
  { tabId: 10, url: page.pageURL, title: "批量页面二" }
];
backgroundGrantedOrigins.add("https://failure.example/*");
const failedBatchCleanupResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("failed batch cleanup timed out")), 1_000);
  messageListener({
    type: "capture-tabs-batch",
    tabIdentities: backgroundBatchTabIdentities,
    token: "",
    captureMode: "link-only",
    temporaryPermissionOrigins: ["https://failure.example/*"]
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(failedBatchCleanupResponse.ok, false);
assert.equal(backgroundGrantedOrigins.has("https://failure.example/*"), false);
assert.deepEqual(backgroundPermissionRemovals.at(-1), ["https://failure.example/*"]);

scriptedPageResults.push({
  ...page,
  pageURL: "https://example.com/navigated",
  documentId: "document-b",
  title: "已经跳转",
  contentText: "不应保存的页面"
});
const navigatedBatchResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("navigated batch response timed out")), 1_000);
  messageListener({
    type: "capture-tabs-batch",
    tabIdentities: backgroundBatchTabIdentities,
    token: "test-token",
    captureMode: "link-only",
    temporaryPermissionOrigins: []
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(navigatedBatchResponse.ok, true);
assert.equal(navigatedBatchResponse.result.requestedCount, 2);
assert.equal(navigatedBatchResponse.result.savedCount, 1);
assert.equal(navigatedBatchResponse.result.failedCount, 1);
assert.equal(navigatedBatchResponse.result.errors[0].tabId, 9);
assert.match(navigatedBatchResponse.result.errors[0].message, /页面已发生跳转/);
assert.equal(navigatedBatchResponse.result.items[0].status, "failed");
assert.equal(navigatedBatchResponse.result.items[0].title, "批量页面一");

backgroundGrantedOrigins.add("https://example.com/*");
const batchResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("batch response timed out")), 1_000);
  messageListener({
    type: "capture-tabs-batch",
    tabIdentities: backgroundBatchTabIdentities,
    token: "test-token",
    captureMode: "link-only",
    allowsLocalSemanticIndex: false,
    allowsRemoteAIUse: false,
    temporaryPermissionOrigins: [
      "https://example.com/*",
      "https://*/*",
      "file:///*"
    ]
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(batchResponse.ok, true);
assert.equal(batchResponse.result.requestedCount, 2);
assert.equal(batchResponse.result.savedCount, 2);
assert.equal(batchResponse.result.failedCount, 0);
assert.deepEqual(
  Array.from(batchResponse.result.items, (item) => item.status),
  ["saved", "saved"]
);
assert.equal(batchResponse.result.temporaryPermissionsReleased, true);
assert.deepEqual(Array.from(batchResponse.result.unreleasedTemporaryOrigins), []);
assert.deepEqual(backgroundPermissionRemovals.at(-1), ["https://example.com/*"]);
assert.equal(backgroundGrantedOrigins.has("https://example.com/*"), false);
assert.equal(postedBody.capture.captureMode, "link-only");
assert.equal(postedBody.capture.allowsLocalSemanticIndex, false);
assert.equal(postedBody.capture.allowsRemoteAIUse, false);
assert.equal(toolbarState.text, "✓");
const progressMessages = backgroundRuntimeMessages.filter((message) =>
  message.type === "capture-tabs-batch-progress"
  && message.batchOperationID === batchResponse.result.batchOperationID
);
assert.deepEqual(
  Array.from(progressMessages, (message) => `${message.tabId}:${message.status}`),
  ["9:saving", "9:saved", "10:saving", "10:saved"]
);

const singleRetryResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("single failed-item retry timed out")), 1_000);
  messageListener({
    type: "capture-tabs-batch",
    tabIdentities: [backgroundBatchTabIdentities[0]],
    token: "test-token",
    captureMode: "link-only",
    temporaryPermissionOrigins: []
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(singleRetryResponse.ok, true);
assert.equal(singleRetryResponse.result.requestedCount, 1);
assert.equal(singleRetryResponse.result.items[0].status, "saved");

const completedImportsBeforeNavigation = completedImportReceipts.size;
scriptedPageResults.push(
  page,
  {
    ...page,
    pageURL: "https://example.com/another-page",
    documentId: "document-c",
    title: "另一个页面",
    originalHTML: "<!doctype html><p>不应与原正文组合</p>"
  }
);
const changedPageResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("changed page response timed out")), 1_000);
  messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    includeArchive: true
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(changedPageResponse.ok, false);
assert.equal(changedPageResponse.code, "page-identity-changed");
assert.match(changedPageResponse.error, /页面已发生跳转/);
assert.equal(completedImportReceipts.size, completedImportsBeforeNavigation);

let mhtmlSaveCount = 0;
browser.pageCapture = {
  saveAsMHTML(_details, callback) {
    mhtmlSaveCount += 1;
    callback(new Blob(["MHTML archive"], { type: "multipart/related" }));
  }
};
scriptedPageResults.push(
  page,
  page,
  { ...page, documentId: "document-reloaded" }
);
const reloadedDuringMHTMLResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("MHTML identity response timed out")), 1_000);
  messageListener({
    type: "capture-and-save",
    tabId: 9,
    token: "test-token",
    includeArchive: true
  }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(reloadedDuringMHTMLResponse.ok, false);
assert.equal(reloadedDuringMHTMLResponse.code, "page-identity-changed");
assert.match(reloadedDuringMHTMLResponse.error, /页面已发生跳转/);
assert.equal(mhtmlSaveCount, 1);
assert.equal(completedImportReceipts.size, completedImportsBeforeNavigation);
delete browser.pageCapture;

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

loseNextImportResponseAfterCommit = true;
const lostReceiptResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("lost receipt response timed out")), 1_000);
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
assert.equal(lostReceiptResponse.ok, true);
assert.equal(lostReceiptResponse.result.queued, true);
assert.equal(lostReceiptResponse.result.queuedCount, 1);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 1);
const lostReceiptOperationID =
  backgroundStorage.pendingKnowledgeCapturesV1.entries[0].envelope.operationID;
assert.equal(completedImportReceipts.has(lostReceiptOperationID), true);
assert.equal("token" in backgroundStorage.pendingKnowledgeCapturesV1.entries[0], false);
assert.equal(
  backgroundStorage.pendingKnowledgeCapturesV1.entries[0].envelope.capture.contentText,
  page.pageURL
);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries[0].storedContentMode, "links-only");
assert.equal(activeAlarms.has("retry-pending-knowledge-captures"), true);

const replayResponse = await new Promise((resolve, reject) => {
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
assert.equal(replayResponse.ok, true);
assert.equal(replayResponse.result.importedCount, 1);
assert.equal(replayResponse.result.queuedCount, 0);
assert.equal(replayResponse.result.receipts[0].operationID, lostReceiptOperationID);
assert.equal(replayResponse.result.receipts[0].replayed, true);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);
assert.equal(activeAlarms.has("retry-pending-knowledge-captures"), false);

bridgeAvailable = false;
for (let index = 0; index < 2; index += 1) {
  const queuedVersion = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error("queue version response timed out")), 1_000);
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
  assert.equal(queuedVersion.ok, true);
  assert.equal(queuedVersion.result.queuedCount, index + 1);
}
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 2);
const queuedVersionOperationIDs = backgroundStorage.pendingKnowledgeCapturesV1.entries
  .map((entry) => entry.envelope.operationID);
assert.equal(new Set(queuedVersionOperationIDs).size, 2);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries
  .every((entry) => entry.envelope.capture.sourceURL === page.sourceURL), true);
assert.ok(fetchCount > 0, "Firefox must use the authenticated loopback bridge");

bridgeAvailable = true;
const retryResponse = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("version retry response timed out")), 1_000);
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
assert.equal(retryResponse.result.importedCount, 2);
assert.equal(retryResponse.result.queuedCount, 0);
assert.deepEqual(
  retryResponse.result.receipts.map((receipt) => receipt.operationID),
  queuedVersionOperationIDs
);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);

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
assert.equal(
  lastFetchURL,
  `http://${loopbackProtocol.host}:${loopbackProtocol.port}/v1/open`
);
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
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 1);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries[0].blocked, true);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries[0].duplicateConflict.title, page.title);
const conflictQueueStatus = await new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error("conflict queue status timed out")), 1_000);
  messageListener({ type: "capture-queue-status" }, {}, (value) => {
    clearTimeout(timeout);
    resolve(value);
  });
});
assert.equal(conflictQueueStatus.ok, true);
assert.equal(conflictQueueStatus.result.duplicateConflicts[0].sourceURL, page.pageURL);
assert.match(conflictQueueStatus.result.duplicateConflicts[0].createdAt, /^\d{4}-\d{2}-\d{2}T/);

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
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);

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
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);

duplicateMode = false;
bridgeAvailable = false;
const originalPageURL = page.pageURL;
const originalSourceURL = page.sourceURL;
page.pageURL = "http://192.168.1.20/private-notes";
page.sourceURL = page.pageURL;
const blockedPrivateQueue = await sendBackgroundMessage({
  type: "capture-and-save",
  tabId: 9,
  token: "test-token",
  includeArchive: false
});
assert.equal(blockedPrivateQueue.ok, false);
assert.equal(blockedPrivateQueue.code, "capture-queue-private-site-blocked");
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);

const allowPrivateQueue = await sendBackgroundMessage({
  type: "set-capture-queue-privacy",
  privacyMode: "links-only",
  allowPrivateSites: true
});
assert.equal(allowPrivateQueue.ok, true);
const queuedPrivatePage = await sendBackgroundMessage({
  type: "capture-and-save",
  tabId: 9,
  token: "test-token",
  includeArchive: false
});
assert.equal(queuedPrivatePage.ok, true);
assert.equal(queuedPrivatePage.result.queued, true);
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 1);
assert.equal(
  backgroundStorage.pendingKnowledgeCapturesV1.entries[0].envelope.capture.contentText,
  page.pageURL
);
await sendBackgroundMessage({ type: "discard-capture-queue" });

page.pageURL = originalPageURL;
page.sourceURL = originalSourceURL;
const blockPrivateContexts = await sendBackgroundMessage({
  type: "set-capture-queue-privacy",
  privacyMode: "links-only",
  allowPrivateSites: false
});
assert.equal(blockPrivateContexts.ok, true);
backgroundTabIncognito = true;
const blockedIncognitoQueue = await sendBackgroundMessage({
  type: "capture-and-save",
  tabId: 9,
  token: "test-token",
  includeArchive: false
});
assert.equal(blockedIncognitoQueue.ok, false);
assert.equal(blockedIncognitoQueue.code, "capture-queue-private-site-blocked");
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);
backgroundTabIncognito = false;

const disabledQueue = await sendBackgroundMessage({
  type: "set-capture-queue-privacy",
  privacyMode: "disabled",
  allowPrivateSites: false
});
assert.equal(disabledQueue.ok, true);
const disabledQueueCapture = await sendBackgroundMessage({
  type: "capture-and-save",
  tabId: 9,
  token: "test-token",
  includeArchive: false
});
assert.equal(disabledQueueCapture.ok, false);
assert.equal(disabledQueueCapture.code, "capture-queue-disabled");
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);

bridgeAvailable = true;
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
assert.equal(backgroundStorage.pendingKnowledgeCapturesV1.entries.length, 0);

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
