if (!globalThis.KNOWLEDGE_NATIVE_MESSAGING_PROTOCOL
    && typeof globalThis.importScripts === "function") {
  globalThis.importScripts("protocol.generated.js");
}
const NATIVE_MESSAGING_PROTOCOL = globalThis.KNOWLEDGE_NATIVE_MESSAGING_PROTOCOL;
if (!NATIVE_MESSAGING_PROTOCOL) {
  throw new Error("浏览器原生消息协议常量未载入。");
}
const NATIVE_HOST_NAME = NATIVE_MESSAGING_PROTOCOL.hostName;
const NATIVE_MESSAGE_SCHEMA_VERSION = NATIVE_MESSAGING_PROTOCOL.schemaVersion;
const MAX_ARCHIVE_BYTES = 24 * 1024 * 1024;
const MAX_TEXT_BYTES = 5 * 1024 * 1024;
const CAPTURE_QUEUE_KEY = "pendingKnowledgeCapturesV1";
const CAPTURE_QUEUE_ALARM = "retry-pending-knowledge-captures";
const CAPTURE_QUEUE_RETENTION_KEY = "knowledgeCaptureQueueRetentionDaysV1";
const CAPTURE_QUEUE_STORE_SCHEMA_VERSION = 2;
const CAPTURE_QUEUE_ITEM_SCHEMA_VERSION = 2;
const CAPTURE_QUEUE_DEFAULT_RETENTION_DAYS = 30;
const CAPTURE_QUEUE_RETENTION_OPTIONS = new Set([7, 30, 90, 365]);
const MAX_QUEUE_ITEMS = 10;
const MAX_QUEUE_BYTES = 96 * 1024 * 1024;
const CAPTURE_MODES = new Set(["cleaned-article", "full-page", "selection", "link-only"]);
const OPERATION_ID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const extensionAPI = globalThis.browser ?? globalThis.chrome;
const menuAPI = extensionAPI.contextMenus ?? extensionAPI.menus;
let queueOperation = Promise.resolve();

function newOperationID() {
  const nativeID = globalThis.crypto?.randomUUID?.();
  if (nativeID && OPERATION_ID_PATTERN.test(nativeID)) return nativeID.toLowerCase();
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (character) => {
    const value = Math.floor(Math.random() * 16);
    return (character === "x" ? value : ((value & 0x3) | 0x8)).toString(16);
  });
}

function normalizedOperationID(value) {
  const operationID = String(value || "").trim().toLowerCase();
  return OPERATION_ID_PATTERN.test(operationID) ? operationID : null;
}

function envelopeWithOperationID(envelope) {
  const operationID = normalizedOperationID(envelope?.operationID) || newOperationID();
  return { ...envelope, operationID };
}

extensionAPI.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  let operation;
  switch (message?.type) {
  case "toolbar-state":
    operation = setToolbarState(message.state, message.message);
    break;
  case "capture-tabs-batch":
    operation = captureTabsBatch(message);
    break;
  case "prepare-capture-preview":
    operation = prepareCapturePreview(message);
    break;
  case "save-prepared-capture":
    operation = savePreparedCapture(message);
    break;
  case "capture-and-save":
    operation = captureAndSave(message);
    break;
  case "capture-queue-status":
    operation = withQueueLock(captureQueueStatus);
    break;
  case "delete-capture-queue-item":
    operation = deleteCaptureQueueItem(message.queueID, Boolean(message.quarantined));
    break;
  case "export-capture-queue":
    operation = exportCaptureQueue();
    break;
  case "set-capture-queue-retention":
    operation = setCaptureQueueRetention(message.retentionDays);
    break;
  case "retry-capture-queue":
    operation = flushCaptureQueue(message.token, Boolean(message.force));
    break;
  case "open-knowledge-document":
    operation = openKnowledgeDocument(message.documentID, message.token);
    break;
  case "resolve-duplicate-capture":
    operation = resolveDuplicateCapture(message.queueID, message.resolution, message.token);
    break;
  case "cancel-duplicate-capture":
    operation = cancelDuplicateCapture(message.queueID);
    break;
  case "discard-capture-queue":
    operation = discardCaptureQueue();
    break;
  case "validate-archive-resource-url":
    operation = validateArchiveResourceURL(message.url);
    break;
  case "bridge-request":
    operation = bridgeRequestForPopup(message);
    break;
  default:
    return false;
  }
  const reportsCaptureState = [
    "capture-and-save", "save-prepared-capture", "capture-tabs-batch",
    "resolve-duplicate-capture", "retry-capture-queue"
  ].includes(message?.type);
  if (reportsCaptureState) setToolbarState("saving").catch(() => {});
  operation
    .then(async (result) => {
      if (reportsCaptureState) await reflectCaptureResult(result);
      sendResponse({ ok: true, result });
    })
    .catch(async (error) => {
      if (reportsCaptureState) await setToolbarState("error", readableError(error));
      sendResponse({ ok: false, error: readableError(error), code: error?.code || null });
    });
  return true;
});

extensionAPI.alarms?.onAlarm?.addListener((alarm) => {
  if (alarm.name === CAPTURE_QUEUE_ALARM) {
    flushCaptureQueue(null, false).catch(() => {});
  }
});
extensionAPI.runtime.onStartup?.addListener(() => {
  scheduleCaptureQueueRetry().catch(() => {});
  setupContextMenus().catch(() => {});
});
extensionAPI.runtime.onInstalled?.addListener(() => {
  scheduleCaptureQueueRetry().catch(() => {});
  setupContextMenus().catch(() => {});
});
menuAPI?.onClicked?.addListener((info, tab) => {
  handleContextMenuClick(info, tab).catch((error) => {
    setToolbarState("error", readableError(error)).catch(() => {});
  });
});
extensionAPI.commands?.onCommand?.addListener((command, tab) => {
  handleCommand(command, tab).catch((error) => {
    setToolbarState("error", readableError(error)).catch(() => {});
  });
});

async function setToolbarState(state, message = "") {
  const action = extensionAPI.action;
  if (!action) return { state };
  const presentation = {
    connected: { text: "ON", color: "#188038", title: "资料采集：已连接到本机资料库" },
    connecting: { text: "…", color: "#3478f6", title: "资料采集：正在连接" },
    saving: { text: "…", color: "#3478f6", title: "资料采集：正在保存" },
    success: { text: "✓", color: "#188038", title: "资料采集：保存成功" },
    offline: { text: "离", color: "#9a6700", title: "资料采集：应用离线，内容将进入队列" },
    error: { text: "!", color: "#d93025", title: "资料采集：操作失败" },
    disconnected: { text: "", color: "#6e7781", title: "资料采集：尚未连接" }
  }[state] || { text: "", color: "#6e7781", title: "保存到资料库" };
  const title = message ? `${presentation.title}；${message}` : presentation.title;
  await Promise.all([
    action.setBadgeBackgroundColor({ color: presentation.color }),
    action.setBadgeText({ text: presentation.text }),
    action.setTitle({ title })
  ]);
  return { state };
}

async function setQueueToolbarState(count, blocked = 0) {
  if (count <= 0) return setToolbarState("connected");
  const action = extensionAPI.action;
  if (!action) return;
  const text = count > 99 ? "99+" : String(count);
  const title = blocked > 0
    ? `资料采集：${count} 项待处理，其中 ${blocked} 项需要确认`
    : `资料采集：${count} 项等待写入资料库`;
  await Promise.all([
    action.setBadgeBackgroundColor({ color: blocked > 0 ? "#d93025" : "#9a6700" }),
    action.setBadgeText({ text }),
    action.setTitle({ title })
  ]);
}

async function reflectCaptureResult(result) {
  const queuedCount = Number(result?.queuedCount || 0);
  const blockedCount = Number(result?.blockedCount || 0);
  if (queuedCount > 0) return setQueueToolbarState(queuedCount, blockedCount);
  const failures = Number(result?.failedCount || 0);
  if (failures > 0) {
    return setToolbarState("error", `${failures} 个标签页保存失败`);
  }
  if (result?.importedCount === 0 && !result?.documentID
      && !(result?.receipts || []).length && result?.requestedCount == null) {
    return setToolbarState("connected");
  }
  return setToolbarState("success");
}

async function setupContextMenus() {
  if (!menuAPI) return;
  if (globalThis.browser) {
    await menuAPI.removeAll();
  } else {
    await new Promise((resolve) => menuAPI.removeAll(resolve));
  }
  menuAPI.create({
    id: "knowledge-save-cleaned",
    title: "保存净化正文到资料库",
    contexts: ["page"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
  menuAPI.create({
    id: "knowledge-save-selection",
    title: "保存选中文字到资料库",
    contexts: ["selection"],
    documentUrlPatterns: ["http://*/*", "https://*/*"]
  });
  menuAPI.create({
    id: "knowledge-save-link",
    title: "仅保存此链接到资料库",
    contexts: ["link"],
    targetUrlPatterns: ["http://*/*", "https://*/*"]
  });
}

async function handleContextMenuClick(info, tab) {
  if (!tab?.id) throw new Error("没有找到可保存的标签页。");
  if (info.menuItemId === "knowledge-save-cleaned") {
    return quickSaveTab(tab, "cleaned-article");
  }
  if (info.menuItemId === "knowledge-save-selection") {
    const text = String(info.selectionText || "").trim();
    if (!text) throw new Error("没有可保存的选中文字。");
    return quickSavePreparedCapture(tab, contextCapture({
      sourceURL: info.pageUrl || tab.url,
      title: tab.title || "网页摘录",
      contentText: text,
      captureMode: "selection"
    }));
  }
  if (info.menuItemId === "knowledge-save-link") {
    const sourceURL = info.linkUrl;
    if (!/^https?:/i.test(sourceURL || "")) throw new Error("该链接不能保存到资料库。");
    const title = String(info.selectionText || sourceURL).trim();
    return quickSavePreparedCapture(tab, contextCapture({
      sourceURL,
      title,
      contentText: `[${escapedMarkdownLabel(title)}](${sourceURL})`,
      captureMode: "link-only"
    }));
  }
}

async function handleCommand(command, tab) {
  if (!tab?.id) {
    [tab] = await extensionAPI.tabs.query({ active: true, currentWindow: true });
  }
  if (!tab?.id) throw new Error("没有找到当前标签页。");
  if (command === "quick-save-cleaned") return quickSaveTab(tab, "cleaned-article");
  if (command === "quick-save-selection") return quickSaveTab(tab, "selection");
}

async function quickSaveTab(tab, captureMode) {
  const settings = await quickSaveSettings(tab.url);
  await setToolbarState("saving");
  const result = await captureAndSave({
    tabId: tab.id,
    token: settings.token,
    folderID: settings.folderID,
    newFolderName: null,
    captureMode,
    allowsAIUse: settings.allowsAIUse
  });
  await rememberBackgroundReceipt(result);
  await reflectCaptureResult(result);
  return result;
}

async function quickSavePreparedCapture(tab, capture) {
  const settings = await quickSaveSettings(capture.sourceURL || tab.url);
  capture.allowsAIUse = settings.allowsAIUse;
  await setToolbarState("saving");
  const result = await savePreparedCapture({
    tabId: tab.id,
    token: settings.token,
    folderID: settings.folderID,
    newFolderName: null,
    captureMode: capture.captureMode,
    capture
  });
  await rememberBackgroundReceipt(result);
  await reflectCaptureResult(result);
  return result;
}

async function quickSaveSettings(sourceURL) {
  const stored = await extensionAPI.storage.local.get([
    "bridgeToken",
    "selectedKnowledgeFolderID",
    "knowledgeDomainFoldersV1",
    "defaultKnowledgeAllowsAIUseV1"
  ]);
  if (!stored.bridgeToken) throw new Error("请先打开插件并连接本机资料库。");
  const domain = normalizedDomain(sourceURL);
  return {
    token: stored.bridgeToken,
    folderID: stored.knowledgeDomainFoldersV1?.[domain]
      || stored.selectedKnowledgeFolderID
      || null,
    allowsAIUse: stored.defaultKnowledgeAllowsAIUseV1 !== false
  };
}

function contextCapture({ sourceURL, title, contentText, captureMode }) {
  return {
    schemaVersion: 1,
    sourceURL,
    title,
    authors: [],
    language: null,
    summary: "",
    tags: [],
    capturedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    contentText,
    originalHTML: null,
    archiveFormat: null,
    archiveData: null,
    archiveEmbeddedResourceCount: null,
    archiveMissingResourceCount: null,
    archiveWasTruncated: null,
    captureMode,
    allowsAIUse: true
  };
}

function escapedMarkdownLabel(value) {
  return String(value || "")
    .replace(/\\/g, "\\\\")
    .replace(/\[/g, "\\[")
    .replace(/\]/g, "\\]");
}

function normalizedDomain(value) {
  try {
    const host = new URL(value).hostname.toLowerCase();
    return host.startsWith("www.") ? host.slice(4) : host;
  } catch {
    return "";
  }
}

function normalizedPageIdentityURL(value) {
  try {
    const url = new URL(String(value || ""));
    if (!["http:", "https:"].includes(url.protocol)
        || !url.hostname
        || url.username
        || url.password) return null;
    return url.href;
  } catch {
    return null;
  }
}

function archiveResourcePolicyError(message, code = "archive-resource-blocked") {
  const error = new Error(message);
  error.code = code;
  return error;
}

function normalizedArchiveResourceURL(value) {
  let url;
  try {
    url = new URL(String(value || ""));
  } catch {
    throw archiveResourcePolicyError("离线资源网址无效。");
  }
  if (!['http:', 'https:'].includes(url.protocol.toLowerCase())
      || !url.hostname
      || url.username
      || url.password) {
    throw archiveResourcePolicyError("离线资源只允许无凭据的 HTTP 或 HTTPS 网址。");
  }
  url.hash = "";
  return url;
}

function parsedArchiveIPv4(value) {
  const parts = String(value || "").split(".");
  if (parts.length !== 4 || parts.some((part) => !/^\d{1,3}$/.test(part))) return null;
  const numbers = parts.map(Number);
  return numbers.every((part) => part >= 0 && part <= 255) ? numbers : null;
}

function parsedArchiveIPv6(value) {
  let input = String(value || "").toLowerCase();
  if (input.startsWith("[") && input.endsWith("]")) input = input.slice(1, -1);
  if (!input.includes(":") || input.includes("%")) return null;
  let ipv4Words = [];
  const ipv4Match = input.match(/(?:^|:)(\d{1,3}(?:\.\d{1,3}){3})$/);
  if (ipv4Match) {
    const ipv4 = parsedArchiveIPv4(ipv4Match[1]);
    if (!ipv4) return null;
    ipv4Words = [(ipv4[0] << 8) | ipv4[1], (ipv4[2] << 8) | ipv4[3]];
    input = input.slice(0, -ipv4Match[1].length).replace(/:$/, "");
  }
  if ((input.match(/::/g) || []).length > 1) return null;
  const [leftText, rightText] = input.split("::");
  const parseSide = (text) => text
    ? text.split(":").map((part) => /^[0-9a-f]{1,4}$/.test(part) ? Number.parseInt(part, 16) : NaN)
    : [];
  const left = parseSide(leftText);
  const right = parseSide(rightText);
  if ([...left, ...right].some((part) => !Number.isInteger(part))) return null;
  const expectedHextets = 8 - ipv4Words.length;
  let words;
  if (input.includes("::")) {
    const zeros = expectedHextets - left.length - right.length;
    if (zeros < 1) return null;
    words = [...left, ...Array(zeros).fill(0), ...right, ...ipv4Words];
  } else {
    words = [...left, ...ipv4Words];
  }
  return words.length === 8 ? words : null;
}

function isBlockedArchiveIPv4(parts) {
  if (!parts) return true;
  const [a, b, c] = parts;
  return a === 0
    || a === 10
    || a === 127
    || (a === 100 && b >= 64 && b <= 127)
    || (a === 169 && b === 254)
    || (a === 172 && b >= 16 && b <= 31)
    || (a === 192 && b === 0)
    || (a === 192 && b === 168)
    || (a === 192 && b === 88 && c === 99)
    || (a === 198 && (b === 18 || b === 19))
    || (a === 198 && b === 51 && c === 100)
    || (a === 203 && b === 0 && c === 113)
    || a >= 224;
}

function isBlockedArchiveIPv6(words) {
  if (!words) return true;
  const isUnspecified = words.every((word) => word === 0);
  const isLoopback = words.slice(0, 7).every((word) => word === 0) && words[7] === 1;
  if (isUnspecified || isLoopback) return true;
  const isIPv4Mapped = words.slice(0, 5).every((word) => word === 0)
    && words[5] === 0xffff;
  if (isIPv4Mapped) {
    return isBlockedArchiveIPv4([
      words[6] >> 8,
      words[6] & 0xff,
      words[7] >> 8,
      words[7] & 0xff
    ]);
  }
  const first = words[0];
  if ((first & 0xfe00) === 0xfc00
      || (first & 0xffc0) === 0xfe80
      || (first & 0xffc0) === 0xfec0
      || (first & 0xff00) === 0xff00) return true;
  if (words[0] === 0x2001
      && [0x0000, 0x0002, 0x0010, 0x0020, 0x0db8].includes(words[1])) return true;
  if (words[0] === 0x2002) return true;
  return (first & 0xe000) !== 0x2000;
}

function isBlockedArchiveHostname(value) {
  let hostname = String(value || "").trim().toLowerCase();
  if (hostname.startsWith("[") && hostname.endsWith("]")) hostname = hostname.slice(1, -1);
  hostname = hostname.replace(/\.$/, "");
  if (!hostname || hostname === "localhost") return true;
  const ipv4 = parsedArchiveIPv4(hostname);
  if (ipv4) return isBlockedArchiveIPv4(ipv4);
  if (hostname.includes(":")) return isBlockedArchiveIPv6(parsedArchiveIPv6(hostname));
  if (!hostname.includes(".")
      || [".localhost", ".local", ".internal", ".home", ".lan", ".onion"]
        .some((suffix) => hostname.endsWith(suffix))) return true;
  return false;
}

async function validateArchiveResourceURL(value) {
  const url = normalizedArchiveResourceURL(value);
  if (isBlockedArchiveHostname(url.hostname)) {
    throw archiveResourcePolicyError("离线归档已阻止私网、回环或保留地址。");
  }
  const literalHostname = url.hostname.replace(/^\[|\]$/g, "");
  if (parsedArchiveIPv4(literalHostname) || parsedArchiveIPv6(literalHostname)) {
    return { allowed: true, url: url.href, dnsValidated: true };
  }
  const dnsAPI = extensionAPI.dns;
  if (!dnsAPI?.resolve) {
    return { allowed: true, url: url.href, dnsValidated: false };
  }
  let record;
  try {
    record = await dnsAPI.resolve(url.hostname, ["bypass_cache"]);
  } catch {
    throw archiveResourcePolicyError(
      "Firefox 无法验证离线资源的 DNS 地址，已停止下载。",
      "archive-resource-dns-failed"
    );
  }
  const addresses = Array.isArray(record?.addresses) ? record.addresses : [];
  if (!addresses.length || addresses.some((address) => isBlockedArchiveHostname(address))) {
    throw archiveResourcePolicyError("离线归档已阻止解析到私网或保留地址的资源。");
  }
  return { allowed: true, url: url.href, dnsValidated: true };
}

function sanitizedPageIdentity(value) {
  const url = normalizedPageIdentityURL(value?.url || value?.pageURL);
  if (!url) throw new Error("页面身份无效，请重新保存。");
  const documentId = typeof value?.documentId === "string" && value.documentId.trim()
    ? value.documentId.trim()
    : null;
  return { url, documentId };
}

function pageIdentityFromInjection(injection, page) {
  const result = injection?.[0];
  return sanitizedPageIdentity({
    url: page?.pageURL || page?.sourceURL,
    documentId: result?.documentId || null
  });
}

function pageIdentityChangedError() {
  const error = new Error("页面已发生跳转，保存已取消；请重新保存。");
  error.code = "page-identity-changed";
  return error;
}

function assertMatchingPageIdentity(expectedValue, actualValue) {
  const expected = sanitizedPageIdentity(expectedValue);
  const actual = sanitizedPageIdentity(actualValue);
  if (expected.url !== actual.url
      || (expected.documentId && expected.documentId !== actual.documentId)) {
    throw pageIdentityChangedError();
  }
  return actual;
}

async function readTabPageIdentity(tabId) {
  const injection = await extensionAPI.scripting.executeScript({
    target: { tabId },
    func: readPageIdentity
  });
  return pageIdentityFromInjection(injection, injection?.[0]?.result);
}

function readPageIdentity() {
  return { pageURL: location.href };
}

async function rememberBackgroundReceipt(result) {
  const receipt = result?.receipt || result;
  if (receipt?.documentID) {
    await extensionAPI.storage.local.set({ lastKnowledgeSaveReceiptV1: receipt });
  }
}

async function captureAndSave(message) {
  const captureMode = message.captureMode
    || (message.includeArchive ? "full-page" : "cleaned-article");
  const prepared = await prepareCapturePreview({
    tabId: message.tabId,
    captureMode,
    expectedPageIdentity: message.expectedPageIdentity || null
  });
  prepared.capture.allowsAIUse = message.allowsAIUse !== false;
  return savePreparedCapture({
    ...message,
    captureMode,
    operationID: prepared.operationID,
    pageIdentity: prepared.pageIdentity,
    capture: prepared.capture
  });
}

async function captureTabsBatch(message) {
  const temporaryPermissionOrigins = normalizedTemporaryPermissionOrigins(
    message.temporaryPermissionOrigins
  );
  let result;
  let captureError;
  try {
    result = await performCaptureTabsBatch(message);
  } catch (error) {
    captureError = error;
  }
  const unreleasedTemporaryOrigins = await releaseTemporaryPermissionOrigins(
    temporaryPermissionOrigins
  );
  if (captureError) throw captureError;
  return {
    ...result,
    temporaryPermissionsReleased: unreleasedTemporaryOrigins.length === 0,
    unreleasedTemporaryOrigins
  };
}

async function performCaptureTabsBatch(message) {
  const tabIdentities = normalizedBatchTabIdentities(message.tabIdentities);
  if (!message.token || tabIdentities.length < 1) {
    throw new Error("没有可保存的网页标签页。");
  }
  const batchOperationID = normalizedOperationID(message.batchOperationID) || newOperationID();
  const captureMode = normalizedCaptureMode(message.captureMode);
  if (captureMode === "selection") {
    throw new Error("批量保存不支持“选中文字”模式，请选择净化正文、完整网页或仅链接。");
  }
  const receipts = [];
  const errors = [];
  const items = [];
  let conflictCount = 0;
  let queuedDuringBatch = 0;
  for (const plannedTab of tabIdentities) {
    const tabId = plannedTab.tabId;
    await reportBatchProgress(batchOperationID, plannedTab, "saving");
    try {
      const result = await captureAndSave({
        tabId,
        expectedPageIdentity: { url: plannedTab.url },
        token: message.token,
        folderID: message.folderID || null,
        newFolderName: message.newFolderName || null,
        captureMode,
        allowsAIUse: message.allowsAIUse !== false
      });
      let status;
      let receipt = null;
      if (result.requiresDuplicateResolution) {
        conflictCount += 1;
        status = "conflict";
      } else if (result.queued) {
        queuedDuringBatch += 1;
        status = "queued";
      } else if (result.documentID) {
        receipts.push(result);
        receipt = result;
        status = "saved";
      } else {
        throw new Error("资料库未返回该网页的保存结果。");
      }
      const item = {
        tabId,
        url: plannedTab.url,
        title: plannedTab.title,
        status,
        error: null,
        receipt
      };
      items.push(item);
      await reportBatchProgress(batchOperationID, plannedTab, status, null, receipt);
    } catch (error) {
      const message = readableError(error);
      errors.push({ tabId, message });
      items.push({
        tabId,
        url: plannedTab.url,
        title: plannedTab.title,
        status: "failed",
        error: message,
        receipt: null
      });
      await reportBatchProgress(batchOperationID, plannedTab, "failed", message);
    }
  }
  const summary = queueSummary(await readCaptureQueue());
  if (receipts.length) {
    await extensionAPI.storage.local.set({
      lastKnowledgeSaveReceiptV1: receipts[receipts.length - 1]
    });
  }
  return {
    batchOperationID,
    requestedCount: tabIdentities.length,
    savedCount: receipts.length,
    importedCount: receipts.length,
    queuedDuringBatch,
    conflictCount,
    failedCount: errors.length,
    errors,
    items,
    receipts,
    ...summary
  };
}

function normalizedBatchTabIdentities(values) {
  if (!Array.isArray(values)) return [];
  const result = [];
  const seenTabIDs = new Set();
  for (const value of values.slice(0, 10)) {
    const tabId = value?.tabId;
    const url = normalizedPageIdentityURL(value?.url);
    if (!Number.isInteger(tabId) || !url || seenTabIDs.has(tabId)) {
      throw new Error("批量授权计划已失效，请重新选择网页并授权。");
    }
    seenTabIDs.add(tabId);
    result.push({
      tabId,
      url,
      title: String(value?.title || "").trim().slice(0, 300)
    });
  }
  return result;
}

async function reportBatchProgress(batchOperationID, plannedTab, status, error = null, receipt = null) {
  try {
    const delivery = extensionAPI.runtime.sendMessage?.({
      type: "capture-tabs-batch-progress",
      batchOperationID,
      tabId: plannedTab.tabId,
      url: plannedTab.url,
      title: plannedTab.title,
      status,
      error,
      receipt
    });
    if (delivery && typeof delivery.then === "function") await delivery;
  } catch {
    // The popup may close while the background task continues; the final batch result remains authoritative.
  }
}

function normalizedTemporaryPermissionOrigins(values) {
  return Array.from(new Set(Array.isArray(values) ? values : []))
    .slice(0, 10)
    .map((value) => {
      const raw = String(value || "").trim();
      if (!raw.endsWith("/*")) return null;
      try {
        const url = new URL(raw.slice(0, -1));
        if (!["http:", "https:"].includes(url.protocol)
            || !url.hostname
            || url.hostname.includes("*")
            || url.username
            || url.password) return null;
        const normalized = `${url.protocol}//${url.hostname}/*`;
        return raw === normalized ? normalized : null;
      } catch {
        return null;
      }
    })
    .filter(Boolean);
}

async function releaseTemporaryPermissionOrigins(origins) {
  if (!origins.length) return [];
  try {
    await extensionAPI.permissions.remove({ origins });
  } catch {
    // The popup may already have removed them. Verify exact origins below.
  }
  const remaining = [];
  for (const origin of origins) {
    try {
      if (await extensionAPI.permissions.contains({ origins: [origin] })) remaining.push(origin);
    } catch {
      remaining.push(origin);
    }
  }
  return remaining;
}

async function prepareCapturePreview(message) {
  if (!Number.isInteger(message.tabId)) {
    throw new Error("没有找到可采集的浏览器标签页。");
  }
  const captureMode = normalizedCaptureMode(message.captureMode);
  const injection = await extensionAPI.scripting.executeScript({
    target: { tabId: message.tabId },
    func: extractPage,
    args: [MAX_ARCHIVE_BYTES, MAX_TEXT_BYTES, false, captureMode]
  });
  const page = injection?.[0]?.result;
  if (!page?.sourceURL || !page?.contentText) {
    throw new Error(captureMode === "selection"
      ? "当前页面没有选中文字；请先选择内容再保存。"
      : "没有从当前页面提取到可保存的内容。");
  }
  const pageIdentity = pageIdentityFromInjection(injection, page);
  if (message.expectedPageIdentity) {
    assertMatchingPageIdentity(message.expectedPageIdentity, pageIdentity);
  }
  const capture = captureFromPage(page, captureMode);
  const textBytes = new TextEncoder().encode(JSON.stringify(capture)).length;
  const estimatedArchiveBytes = captureMode === "full-page"
    ? Math.min(MAX_ARCHIVE_BYTES, Math.max(0, Number(page.estimatedArchiveBytes || 0)))
    : 0;
  return {
    operationID: newOperationID(),
    captureMode,
    pageIdentity,
    capture,
    previewText: previewExcerpt(capture.contentText),
    estimatedSizeBytes: textBytes + estimatedArchiveBytes,
    archiveType: captureMode === "full-page"
      ? (extensionAPI.pageCapture?.saveAsMHTML ? "mhtml" : "html")
      : "none"
  };
}

async function savePreparedCapture(message) {
  if (!message.token || !Number.isInteger(message.tabId)) {
    throw new Error("连接信息不完整，请重新打开插件。");
  }
  const captureMode = normalizedCaptureMode(message.captureMode);
  const capture = sanitizedPreparedCapture(message.capture, captureMode);
  const expectedPageIdentity = captureMode === "full-page"
    ? sanitizedPageIdentity(message.pageIdentity)
    : null;

  let archiveData = null;
  let archiveFormat = null;
  let archiveReport = null;
  const supportsMHTML = Boolean(extensionAPI.pageCapture?.saveAsMHTML);
  if (captureMode === "full-page" && supportsMHTML) {
    assertMatchingPageIdentity(
      expectedPageIdentity,
      await readTabPageIdentity(message.tabId)
    );
    const archive = await saveAsMHTML(message.tabId).catch(() => null);
    if (archive) {
      assertMatchingPageIdentity(
        expectedPageIdentity,
        await readTabPageIdentity(message.tabId)
      );
    }
    if (archive && archive.size <= MAX_ARCHIVE_BYTES) {
      archiveData = await blobToBase64(archive);
      archiveFormat = "mhtml";
    }
  }
  if (captureMode === "full-page" && !archiveData) {
    const injection = await extensionAPI.scripting.executeScript({
      target: { tabId: message.tabId },
      func: extractPage,
      args: [MAX_ARCHIVE_BYTES, MAX_TEXT_BYTES, true, "full-page"]
    });
    const archivePage = injection?.[0]?.result;
    if (!archivePage?.originalHTML) {
      throw new Error("浏览器没有返回可保存的完整网页归档。");
    }
    assertMatchingPageIdentity(
      expectedPageIdentity,
      pageIdentityFromInjection(injection, archivePage)
    );
    const archive = new Blob([archivePage.originalHTML], { type: "text/html;charset=utf-8" });
    if (archive.size <= MAX_ARCHIVE_BYTES) {
      archiveData = await blobToBase64(archive);
      archiveFormat = "html";
      archiveReport = archivePage?.archiveReport || {
        format: "html",
        embeddedResourceCount: 0,
        missingResourceCount: 0,
        wasTruncated: false
      };
    }
  }

  const finalizedCapture = {
    ...capture,
    originalHTML: null,
    archiveFormat,
    archiveData,
    archiveEmbeddedResourceCount: archiveReport?.embeddedResourceCount ?? null,
    archiveMissingResourceCount: archiveReport?.missingResourceCount ?? null,
    archiveWasTruncated: archiveReport?.wasTruncated ?? null
  };

  const envelope = envelopeWithOperationID({
    operationID: message.operationID,
    capture: finalizedCapture,
    folderID: message.folderID || null,
    newFolderName: message.newFolderName || null
  });
  try {
    const payload = await submitCaptureEnvelope(envelope, message.token);
    if (payload.requiresDuplicateResolution) {
      const queued = await enqueueDuplicateConflict(envelope, payload.conflict, archiveReport);
      return {
        ...payload,
        conflictQueueID: queued.queueID,
        queuedCount: queued.queuedCount,
        blockedCount: queued.blockedCount,
        archiveReport
      };
    }
    return { ...payload, archiveReport };
  } catch (error) {
    if (!error?.retryable) throw error;
    const queue = await enqueueCapture(envelope, archiveReport, error);
    return {
      queued: true,
      queuedCount: queue.queuedCount,
      blockedCount: queue.blockedCount,
      archiveReport
    };
  }
}

function normalizedCaptureMode(value) {
  const mode = String(value || "cleaned-article");
  if (!CAPTURE_MODES.has(mode)) throw new Error("采集模式无效，请重新选择后保存。");
  return mode;
}

function captureFromPage(page, captureMode) {
  return {
    schemaVersion: 1,
    sourceURL: page.sourceURL,
    title: page.title,
    authors: page.authors || [],
    language: page.language || null,
    summary: page.summary || "",
    tags: page.tags || [],
    capturedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    contentText: page.contentText,
    originalHTML: null,
    archiveFormat: null,
    archiveData: null,
    archiveEmbeddedResourceCount: null,
    archiveMissingResourceCount: null,
    archiveWasTruncated: null,
    captureMode,
    allowsAIUse: true
  };
}

function sanitizedPreparedCapture(value, captureMode) {
  if (!value || value.schemaVersion !== 1) {
    throw new Error("采集内容已失效，请重新保存。");
  }
  let sourceURL;
  try {
    sourceURL = new URL(String(value.sourceURL || ""));
  } catch {
    throw new Error("页面地址无效，请重新保存。");
  }
  if (!["http:", "https:"].includes(sourceURL.protocol)
      || sourceURL.username || sourceURL.password) {
    throw new Error("页面地址无效，请重新保存。");
  }
  sourceURL.hash = "";
  const title = String(value.title || "").trim().slice(0, 300);
  const contentText = String(value.contentText || "").trim();
  if (!title) throw new Error("标题不能为空。");
  if (!contentText) throw new Error("保存内容为空，请重新保存。");
  if (new TextEncoder().encode(contentText).length > MAX_TEXT_BYTES) {
    throw new Error("正文超过 5 MB，请缩小选择范围后重试。");
  }
  const normalizedList = (items, maximumCount, maximumLength) => (Array.isArray(items) ? items : [])
    .map((item) => String(item || "").trim().slice(0, maximumLength))
    .filter(Boolean)
    .slice(0, maximumCount);
  return {
    schemaVersion: 1,
    sourceURL: sourceURL.href,
    title,
    authors: normalizedList(value.authors, 30, 120),
    language: String(value.language || "").trim().slice(0, 40) || null,
    summary: String(value.summary || "").trim().slice(0, 20_000),
    tags: normalizedList(value.tags, 50, 80),
    capturedAt: value.capturedAt || new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    contentText,
    originalHTML: null,
    archiveFormat: null,
    archiveData: null,
    archiveEmbeddedResourceCount: null,
    archiveMissingResourceCount: null,
    archiveWasTruncated: null,
    captureMode,
    allowsAIUse: value.allowsAIUse !== false
  };
}

function previewExcerpt(value) {
  const maximumCharacters = 12_000;
  return value.length <= maximumCharacters
    ? value
    : `${value.slice(0, maximumCharacters)}\n\n……片段已截断，实际保存会保留完整正文。`;
}

async function submitCaptureEnvelope(envelope, token) {
  const requestEnvelope = envelopeWithOperationID(envelope);
  const response = await performBridgeRequest("/v1/import", "POST", token, requestEnvelope);
  if (!response.ok) {
    await handleBridgeAuthenticationFailure(response.status, response.payload);
    const retryable = response.status === 0
      || response.status === 408
      || response.status === 425
      || response.status === 429
      || response.status >= 500;
    const error = bridgeError(
      response.payload.error || "资料库拒绝了页面（HTTP " + response.status + "）。",
      response.status,
      retryable
    );
    error.code = response.payload.code || null;
    throw error;
  }
  if (normalizedOperationID(response.payload.operationID)
      !== normalizedOperationID(requestEnvelope.operationID)) {
    const error = bridgeError(
      "应用返回的保存操作回执不匹配；请升级应用和扩展后重新保存。",
      409,
      false
    );
    error.code = "operation-receipt-mismatch";
    throw error;
  }
  return response.payload;
}

async function openKnowledgeDocument(documentID, token) {
  if (!documentID || !token) {
    throw new Error("资料定位信息不完整，请重新连接插件。");
  }
  const response = await performBridgeRequest("/v1/open", "POST", token, { documentID });
  if (!response.ok) {
    await handleBridgeAuthenticationFailure(response.status, response.payload);
    const error = bridgeError(
      response.payload.error || "无法在资料库中打开该资料。",
      response.status,
      false
    );
    error.code = response.payload.code || null;
    throw error;
  }
  return response.payload;
}

async function bridgeRequestForPopup(message) {
  const path = String(message.path || "");
  const method = String(message.method || "GET").toUpperCase();
  const response = await performBridgeRequest(path, method, message.token, message.body ?? null);
  if (!response.ok) {
    await handleBridgeAuthenticationFailure(response.status, response.payload);
    const error = bridgeError(
      response.payload.error || `连接失败（HTTP ${response.status}）`,
      response.status,
      response.status === 0 || response.status >= 500
    );
    error.code = response.payload.code || null;
    throw error;
  }
  return response.payload;
}

async function performBridgeRequest(path, method, token, body = null) {
  const normalizedMethod = String(method || "").toUpperCase();
  if (!NATIVE_MESSAGING_PROTOCOL.routes[path]?.includes(normalizedMethod)) {
    throw new Error("扩展请求了未允许的本机资料库接口。");
  }
  if (!token) {
    return {
      ok: false,
      status: 401,
      payload: { error: "缺少连接令牌，请重新配对。", code: "invalid-token" },
      transport: "none"
    };
  }
  if (supportsNativeMessaging()) {
    try {
      const bodyJSON = body == null ? null : JSON.stringify(body);
      if (bodyJSON != null
          && new TextEncoder().encode(bodyJSON).length
            > NATIVE_MESSAGING_PROTOCOL.maximumInputBytes) {
        throw new Error("原生消息正文超过协议上限。");
      }
      const response = await sendNativeHostMessage({
        schemaVersion: NATIVE_MESSAGE_SCHEMA_VERSION,
        path,
        method: normalizedMethod,
        token,
        bodyJSON
      });
      if (!response || response.schemaVersion !== NATIVE_MESSAGE_SCHEMA_VERSION
          || typeof response.status !== "number" || typeof response.payload !== "object") {
        throw new Error("原生宿主返回了无效响应。");
      }
      return {
        ok: Boolean(response.ok),
        status: response.status,
        payload: response.payload || {},
        transport: "native"
      };
    } catch (nativeError) {
      return {
        ok: false,
        status: 0,
        payload: {
          error: "无法连接浏览器原生宿主。请在应用的浏览器资料采集窗口安装或修复对应浏览器的原生连接。",
          code: "native-host-unavailable",
          detail: readableError(nativeError)
        },
        transport: "native"
      };
    }
  }
  return {
    ok: false,
    status: 0,
    payload: {
      error: "当前浏览器不支持原生连接，请升级浏览器后重试。",
      code: "native-messaging-unsupported"
    },
    transport: "none"
  };
}

function supportsNativeMessaging() {
  return typeof extensionAPI.runtime?.sendNativeMessage === "function";
}

function sendNativeHostMessage(message) {
  if (typeof globalThis.browser !== "undefined") {
    return extensionAPI.runtime.sendNativeMessage(NATIVE_HOST_NAME, message);
  }
  return new Promise((resolve, reject) => {
    extensionAPI.runtime.sendNativeMessage(NATIVE_HOST_NAME, message, (response) => {
      const lastError = extensionAPI.runtime.lastError;
      if (lastError) {
        reject(new Error(lastError.message || "原生宿主连接失败。"));
      } else {
        resolve(response);
      }
    });
  });
}

function bridgeError(message, status, retryable) {
  const error = new Error(message);
  error.status = status;
  error.retryable = retryable;
  return error;
}

async function handleBridgeAuthenticationFailure(status, payload) {
  if (![401, 403].includes(status)
      || !["token-expired", "invalid-token"].includes(payload?.code)) return;
  await extensionAPI.storage.local.remove(["bridgeToken"]);
  await setToolbarState("disconnected", payload.error || "需要重新配对");
}

function withQueueLock(operation) {
  const result = queueOperation.then(operation, operation);
  queueOperation = result.catch(() => {});
  return result;
}

function emptyCaptureQueueStore() {
  return {
    schemaVersion: CAPTURE_QUEUE_STORE_SCHEMA_VERSION,
    updatedAt: new Date().toISOString(),
    entries: [],
    quarantine: []
  };
}

function normalizedQueueRetentionDays(value) {
  const days = Number(value);
  return CAPTURE_QUEUE_RETENTION_OPTIONS.has(days)
    ? days
    : CAPTURE_QUEUE_DEFAULT_RETENTION_DAYS;
}

function normalizedQueueDate(value, fallback = new Date().toISOString()) {
  const timestamp = Date.parse(String(value || ""));
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : fallback;
}

function queueJSONByteSize(value) {
  try {
    return new TextEncoder().encode(JSON.stringify(value)).length;
  } catch {
    return 0;
  }
}

function redactedQueueSnapshot(value) {
  try {
    return JSON.parse(JSON.stringify(value, (key, item) =>
      /(token|secret|authorization|cookie|password|apiKey)/i.test(key)
        ? "[已移除敏感字段]"
        : item
    ));
  } catch {
    return { unavailable: true, description: "损坏数据无法序列化。" };
  }
}

function queueQuarantineRecord(value, reason, index = null) {
  const rawValue = redactedQueueSnapshot(value);
  const capture = rawValue?.envelope?.capture;
  const originalSchemaVersion = Number.isInteger(rawValue?.schemaVersion)
    ? rawValue.schemaVersion
    : null;
  return {
    id: newOperationID(),
    quarantinedAt: new Date().toISOString(),
    reason,
    originalIndex: index,
    originalSchemaVersion,
    title: String(capture?.title || "无法识别的队列项目").slice(0, 300),
    sourceURL: normalizedPageIdentityURL(capture?.sourceURL),
    byteSize: queueJSONByteSize(rawValue),
    rawValue
  };
}

function migrateCaptureQueueEntry(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("队列项目不是可识别的对象。");
  }
  if (![1, CAPTURE_QUEUE_ITEM_SCHEMA_VERSION].includes(value.schemaVersion)) {
    throw new Error(`不支持的队列项目 schema：${String(value.schemaVersion ?? "缺失")}。`);
  }
  const capture = value.envelope?.capture;
  const sourceURL = normalizedPageIdentityURL(capture?.sourceURL);
  if (!sourceURL || typeof capture?.contentText !== "string") {
    throw new Error("队列项目缺少有效的来源网址或正文。");
  }
  const now = new Date().toISOString();
  return {
    ...value,
    schemaVersion: CAPTURE_QUEUE_ITEM_SCHEMA_VERSION,
    id: String(value.id || "").trim() || newOperationID(),
    createdAt: normalizedQueueDate(value.createdAt, now),
    updatedAt: normalizedQueueDate(value.updatedAt, now),
    attempts: Math.max(0, Number.isInteger(value.attempts) ? value.attempts : 0),
    nextAttemptAt: value.nextAttemptAt
      ? normalizedQueueDate(value.nextAttemptAt, null)
      : null,
    blocked: Boolean(value.blocked),
    lastError: String(value.lastError || "").slice(0, 1_000),
    envelope: envelopeWithOperationID({
      ...value.envelope,
      capture: { ...capture, sourceURL }
    })
  };
}

function migrateCaptureQueueStore(rawValue) {
  if (rawValue == null) {
    return { store: emptyCaptureQueueStore(), changed: false };
  }
  let candidates;
  let quarantine = [];
  let changed = false;
  if (Array.isArray(rawValue)) {
    candidates = rawValue;
    changed = true;
  } else if (typeof rawValue === "object") {
    if (rawValue.schemaVersion == null) {
      const store = emptyCaptureQueueStore();
      store.quarantine.push(queueQuarantineRecord(
        rawValue,
        "队列根记录缺少 schema，已隔离以避免丢失。"
      ));
      return { store, changed: true };
    }
    if (rawValue.schemaVersion !== CAPTURE_QUEUE_STORE_SCHEMA_VERSION) {
      const error = new Error(
        `离线队列 schema ${String(rawValue.schemaVersion)} 高于或不兼容当前版本；数据未被修改。`
      );
      error.code = "queue-schema-unsupported";
      error.schemaVersion = rawValue.schemaVersion;
      throw error;
    }
    if (Array.isArray(rawValue.entries)) {
      candidates = rawValue.entries;
    } else {
      candidates = [];
      quarantine.push(queueQuarantineRecord(
        rawValue.entries,
        "队列 entries 字段损坏，已隔离。"
      ));
      changed = true;
    }
    if (Array.isArray(rawValue.quarantine)) {
      quarantine.push(...rawValue.quarantine.map((item) => {
        const rawSnapshot = redactedQueueSnapshot(item?.rawValue);
        if (JSON.stringify(rawSnapshot) !== JSON.stringify(item?.rawValue)) changed = true;
        return {
          ...item,
          id: String(item?.id || "").trim() || newOperationID(),
          quarantinedAt: normalizedQueueDate(item?.quarantinedAt),
          reason: String(item?.reason || "已隔离的损坏项目。").slice(0, 1_000),
          byteSize: Number(item?.byteSize || queueJSONByteSize(rawSnapshot)),
          rawValue: rawSnapshot
        };
      }));
    } else if (rawValue.quarantine != null) {
      quarantine.push(queueQuarantineRecord(
        rawValue.quarantine,
        "队列 quarantine 字段损坏，已重新隔离。"
      ));
      changed = true;
    }
  } else {
    const store = emptyCaptureQueueStore();
    store.quarantine.push(queueQuarantineRecord(
      rawValue,
      "队列根记录类型损坏，已隔离以避免丢失。"
    ));
    return { store, changed: true };
  }

  const entries = [];
  for (const [index, candidate] of candidates.entries()) {
    try {
      const migrated = migrateCaptureQueueEntry(candidate);
      entries.push(migrated);
      if (candidate.schemaVersion !== CAPTURE_QUEUE_ITEM_SCHEMA_VERSION) changed = true;
    } catch (error) {
      quarantine.push(queueQuarantineRecord(candidate, readableError(error), index));
      changed = true;
    }
  }
  entries.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
  return {
    store: {
      schemaVersion: CAPTURE_QUEUE_STORE_SCHEMA_VERSION,
      updatedAt: normalizedQueueDate(rawValue?.updatedAt),
      entries,
      quarantine
    },
    changed
  };
}

function pruneCaptureQueueStore(store, retentionDays, now = Date.now()) {
  const cutoff = now - retentionDays * 24 * 60 * 60 * 1_000;
  const entries = store.entries.filter((entry) => Date.parse(entry.createdAt) >= cutoff);
  const quarantine = store.quarantine.filter(
    (entry) => Date.parse(entry.quarantinedAt) >= cutoff
  );
  return {
    store: { ...store, entries, quarantine },
    purgedCount:
      store.entries.length - entries.length + store.quarantine.length - quarantine.length
  };
}

async function readCaptureQueueStore() {
  const stored = await extensionAPI.storage.local.get([
    CAPTURE_QUEUE_KEY,
    CAPTURE_QUEUE_RETENTION_KEY
  ]);
  const retentionDays = normalizedQueueRetentionDays(stored?.[CAPTURE_QUEUE_RETENTION_KEY]);
  let migration;
  try {
    migration = migrateCaptureQueueStore(stored?.[CAPTURE_QUEUE_KEY]);
  } catch (error) {
    error.retentionDays = retentionDays;
    throw error;
  }
  const pruning = pruneCaptureQueueStore(migration.store, retentionDays);
  const changed = migration.changed || pruning.purgedCount > 0;
  const store = {
    ...pruning.store,
    updatedAt: changed ? new Date().toISOString() : pruning.store.updatedAt
  };
  if (changed) {
    await extensionAPI.storage.local.set({
      [CAPTURE_QUEUE_KEY]: store,
      [CAPTURE_QUEUE_RETENTION_KEY]: retentionDays
    });
  }
  return { ...store, retentionDays, purgedCount: pruning.purgedCount };
}

async function writeCaptureQueueStore(store) {
  const persisted = {
    schemaVersion: CAPTURE_QUEUE_STORE_SCHEMA_VERSION,
    updatedAt: new Date().toISOString(),
    entries: store.entries || [],
    quarantine: store.quarantine || []
  };
  await extensionAPI.storage.local.set({ [CAPTURE_QUEUE_KEY]: persisted });
  await updateCaptureQueueAlarm(persisted.entries.some((entry) => !entry.blocked));
  if (persisted.entries.length || persisted.quarantine.length) {
    const summary = queueSummary(persisted.entries, { quarantine: persisted.quarantine });
    await setQueueToolbarState(
      summary.queuedCount + summary.quarantinedCount,
      summary.blockedCount + summary.quarantinedCount
    );
  } else {
    const stored = await extensionAPI.storage.local.get(["bridgeToken"]);
    await setToolbarState(stored.bridgeToken ? "connected" : "disconnected");
  }
  return persisted;
}

async function readCaptureQueue() {
  return (await readCaptureQueueStore()).entries;
}

async function writeCaptureQueue(queue) {
  const store = await readCaptureQueueStore();
  await writeCaptureQueueStore({ ...store, entries: queue });
}

function captureQueueItemSummary(entry, retentionDays) {
  const capture = entry.envelope?.capture || {};
  const createdAt = normalizedQueueDate(entry.createdAt);
  return {
    id: entry.id,
    title: String(capture.title || "未命名网页").slice(0, 300),
    sourceURL: normalizedPageIdentityURL(capture.sourceURL),
    captureMode: capture.captureMode || "cleaned-article",
    allowsAIUse: capture.allowsAIUse !== false,
    folderID: entry.envelope?.folderID || null,
    newFolderName: entry.envelope?.newFolderName || null,
    createdAt,
    updatedAt: normalizedQueueDate(entry.updatedAt),
    expiresAt: new Date(
      Date.parse(createdAt) + retentionDays * 24 * 60 * 60 * 1_000
    ).toISOString(),
    attempts: Number(entry.attempts || 0),
    blocked: Boolean(entry.blocked),
    status: entry.duplicateConflict
      ? "duplicate"
      : entry.blocked
        ? "failed"
        : Number(entry.attempts || 0) > 0
          ? "retrying"
          : "queued",
    lastError: String(entry.lastError || ""),
    previewText: String(capture.contentText || "").replace(/\s+/g, " ").trim().slice(0, 240),
    byteSize: queueJSONByteSize(entry)
  };
}

function quarantinedQueueItemSummary(entry, retentionDays) {
  const quarantinedAt = normalizedQueueDate(entry.quarantinedAt);
  return {
    id: entry.id,
    title: String(entry.title || "无法识别的队列项目"),
    sourceURL: normalizedPageIdentityURL(entry.sourceURL),
    quarantinedAt,
    expiresAt: new Date(
      Date.parse(quarantinedAt) + retentionDays * 24 * 60 * 60 * 1_000
    ).toISOString(),
    reason: String(entry.reason || "项目已隔离。"),
    originalSchemaVersion: entry.originalSchemaVersion ?? null,
    byteSize: Number(entry.byteSize || 0)
  };
}

function queueSummary(queue, options = {}) {
  const retentionDays = normalizedQueueRetentionDays(options.retentionDays);
  const quarantine = options.quarantine || [];
  const hasContent = queue.length > 0 || quarantine.length > 0;
  const storeValue = options.store || queue;
  return {
    queueState: hasContent ? "content" : "empty",
    queueSchemaVersion: CAPTURE_QUEUE_STORE_SCHEMA_VERSION,
    retentionDays,
    purgedCount: Number(options.purgedCount || 0),
    queuedCount: queue.length,
    quarantinedCount: quarantine.length,
    blockedCount: queue.filter((entry) => entry.blocked).length,
    totalBytes: queueJSONByteSize(storeValue),
    oldestCapturedAt: queue[0]?.createdAt || null,
    queueItems: queue.map((entry) => captureQueueItemSummary(entry, retentionDays)),
    quarantinedItems: quarantine.map((entry) =>
      quarantinedQueueItemSummary(entry, retentionDays)
    ),
    duplicateConflicts: queue
      .filter((entry) => entry.duplicateConflict)
      .map((entry) => ({
        queueID: entry.id,
        conflict: entry.duplicateConflict,
        sourceURL: normalizedPageIdentityURL(entry.envelope?.capture?.sourceURL),
        createdAt: entry.createdAt || null,
        targetFolderID: entry.envelope.folderID || null,
        targetNewFolderName: entry.envelope.newFolderName || null
      }))
  };
}

async function captureQueueStatus() {
  try {
    const store = await readCaptureQueueStore();
    return queueSummary(store.entries, {
      retentionDays: store.retentionDays,
      purgedCount: store.purgedCount,
      quarantine: store.quarantine,
      store
    });
  } catch (error) {
    return {
      queueState: "failed",
      queueSchemaVersion: error?.schemaVersion ?? null,
      retentionDays: normalizedQueueRetentionDays(error?.retentionDays),
      purgedCount: 0,
      queuedCount: 0,
      quarantinedCount: 0,
      blockedCount: 0,
      totalBytes: 0,
      queueItems: [],
      quarantinedItems: [],
      duplicateConflicts: [],
      queueErrorCode: error?.code || "queue-read-failed",
      queueError: readableError(error)
    };
  }
}

function captureOperationKey(envelope) {
  return normalizedOperationID(envelope?.operationID);
}

function queueRetryDelay(attempts) {
  return Math.min(60 * 60 * 1_000, 30 * 1_000 * (2 ** Math.min(attempts, 7)));
}

async function enqueueCapture(envelope, archiveReport, originalError) {
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    const queue = [...store.entries];
    const now = new Date().toISOString();
    envelope = envelopeWithOperationID(envelope);
    const operationKey = captureOperationKey(envelope);
    const existingIndex = queue.findIndex((entry) =>
      captureOperationKey(entry.envelope) === operationKey
    );
    const existing = existingIndex >= 0 ? queue[existingIndex] : null;
    const entry = {
      schemaVersion: CAPTURE_QUEUE_ITEM_SCHEMA_VERSION,
      id: existing?.id || globalThis.crypto?.randomUUID?.()
        || `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      createdAt: existing?.createdAt || now,
      updatedAt: now,
      attempts: 1,
      nextAttemptAt: new Date(Date.now() + queueRetryDelay(1)).toISOString(),
      blocked: false,
      lastError: readableError(originalError),
      envelope,
      archiveReport: archiveReport || null
    };
    if (existingIndex >= 0) {
      queue.splice(existingIndex, 1, entry);
    } else {
      queue.push(entry);
    }
    queue.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
    const nextStore = { ...store, entries: queue };
    const summary = queueSummary(queue, {
      retentionDays: store.retentionDays,
      quarantine: store.quarantine,
      store: nextStore
    });
    if (summary.queuedCount > MAX_QUEUE_ITEMS || summary.totalBytes > MAX_QUEUE_BYTES) {
      throw new Error("待保存队列已满，请先打开应用完成重试，或在插件中清理队列。");
    }
    try {
      await writeCaptureQueueStore(nextStore);
    } catch {
      throw new Error("浏览器无法写入待保存队列，请打开应用后重试。");
    }
    return summary;
  });
}

async function enqueueDuplicateConflict(envelope, conflict, archiveReport) {
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    const queue = [...store.entries];
    const now = new Date().toISOString();
    envelope = envelopeWithOperationID(envelope);
    const operationKey = captureOperationKey(envelope);
    const existingIndex = queue.findIndex((entry) =>
      captureOperationKey(entry.envelope) === operationKey
    );
    const existing = existingIndex >= 0 ? queue[existingIndex] : null;
    const entry = {
      schemaVersion: CAPTURE_QUEUE_ITEM_SCHEMA_VERSION,
      id: existing?.id || globalThis.crypto?.randomUUID?.()
        || `${Date.now()}-${Math.random().toString(16).slice(2)}`,
      createdAt: existing?.createdAt || now,
      updatedAt: now,
      attempts: Number(existing?.attempts || 0),
      nextAttemptAt: null,
      blocked: true,
      lastError: "检测到同网址资料，需要选择处理方式。",
      envelope,
      archiveReport: archiveReport || null,
      duplicateConflict: conflict
    };
    if (existingIndex >= 0) {
      queue.splice(existingIndex, 1, entry);
    } else {
      queue.push(entry);
    }
    queue.sort((left, right) => left.createdAt.localeCompare(right.createdAt));
    const nextStore = { ...store, entries: queue };
    const summary = queueSummary(queue, {
      retentionDays: store.retentionDays,
      quarantine: store.quarantine,
      store: nextStore
    });
    if (summary.queuedCount > MAX_QUEUE_ITEMS || summary.totalBytes > MAX_QUEUE_BYTES) {
      throw new Error("待保存队列已满，无法保留重复网页的处理选择。");
    }
    await writeCaptureQueueStore(nextStore);
    return { queueID: entry.id, ...summary };
  });
}

async function flushCaptureQueue(explicitToken = null, force = false) {
  return withQueueLock(async () => {
    const queue = await readCaptureQueue();
    if (!queue.length) return { importedCount: 0, receipts: [], ...queueSummary(queue) };
    const stored = explicitToken
      ? null
      : await extensionAPI.storage.local.get(["bridgeToken"]);
    const token = explicitToken || stored?.bridgeToken;
    if (!token) return { importedCount: 0, receipts: [], ...queueSummary(queue) };

    const remaining = [];
    let importedCount = 0;
    const receipts = [];
    for (let index = 0; index < queue.length; index += 1) {
      const entry = queue[index];
      if ((!force && entry.blocked)
          || (!force && Date.parse(entry.nextAttemptAt || "") > Date.now())) {
        remaining.push(entry);
        continue;
      }
      try {
        const receipt = await submitCaptureEnvelope(entry.envelope, token);
        if (receipt.requiresDuplicateResolution) {
          remaining.push({
            ...entry,
            blocked: true,
            nextAttemptAt: null,
            updatedAt: new Date().toISOString(),
            lastError: "检测到同网址资料，需要选择处理方式。",
            duplicateConflict: receipt.conflict
          });
          continue;
        }
        receipts.push(receipt);
        importedCount += 1;
      } catch (error) {
        const attempts = Number(entry.attempts || 0) + 1;
        const updated = {
          ...entry,
          attempts,
          updatedAt: new Date().toISOString(),
          nextAttemptAt: error.retryable
            ? new Date(Date.now() + queueRetryDelay(attempts)).toISOString()
            : null,
          blocked: !error.retryable,
          lastError: readableError(error)
        };
        remaining.push(updated);
        if (error.retryable || error.status === 401 || error.status === 403) {
          remaining.push(...queue.slice(index + 1));
          break;
        }
      }
    }
    await writeCaptureQueue(remaining);
    return { importedCount, receipts, ...queueSummary(remaining) };
  });
}

async function resolveDuplicateCapture(queueID, resolution, token) {
  if (!queueID || !["save-new-version", "move-only", "keep-copy"].includes(resolution)) {
    throw new Error("重复网页处理方式无效。");
  }
  if (!token) throw new Error("请先重新连接应用。");
  return withQueueLock(async () => {
    const queue = await readCaptureQueue();
    const index = queue.findIndex((entry) => entry.id === queueID && entry.duplicateConflict);
    if (index < 0) throw new Error("该重复网页处理请求已不存在。");
    const entry = queue[index];
    const receipt = await submitCaptureEnvelope({
      ...entry.envelope,
      duplicateResolution: resolution
    }, token);
    if (receipt.requiresDuplicateResolution) {
      throw new Error("资料库仍需要确认重复网页的处理方式。");
    }
    queue.splice(index, 1);
    await writeCaptureQueue(queue);
    return { receipt, ...queueSummary(queue) };
  });
}

async function cancelDuplicateCapture(queueID) {
  if (!queueID) throw new Error("重复网页处理请求无效。");
  return withQueueLock(async () => {
    const queue = await readCaptureQueue();
    const remaining = queue.filter((entry) => entry.id !== queueID);
    await writeCaptureQueue(remaining);
    return queueSummary(remaining);
  });
}

async function deleteCaptureQueueItem(queueID, quarantined) {
  if (!queueID) throw new Error("待保存项目标识无效。");
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    const entries = quarantined
      ? store.entries
      : store.entries.filter((entry) => entry.id !== queueID);
    const quarantine = quarantined
      ? store.quarantine.filter((entry) => entry.id !== queueID)
      : store.quarantine;
    if (entries.length === store.entries.length
        && quarantine.length === store.quarantine.length) {
      throw new Error("该待保存项目已经不存在。");
    }
    const persisted = await writeCaptureQueueStore({ ...store, entries, quarantine });
    return queueSummary(persisted.entries, {
      retentionDays: store.retentionDays,
      quarantine: persisted.quarantine,
      store: persisted
    });
  });
}

async function exportCaptureQueue() {
  const stored = await extensionAPI.storage.local.get([
    CAPTURE_QUEUE_KEY,
    CAPTURE_QUEUE_RETENTION_KEY
  ]);
  const exportedAt = new Date().toISOString();
  const rawQueue = redactedQueueSnapshot(stored?.[CAPTURE_QUEUE_KEY] ?? null);
  return {
    fileName: `knowledge-capture-queue-${exportedAt.slice(0, 10)}.json`,
    export: {
      exportSchemaVersion: 1,
      exportedAt,
      retentionDays: normalizedQueueRetentionDays(stored?.[CAPTURE_QUEUE_RETENTION_KEY]),
      containsPrivateReadingContent: true,
      queue: rawQueue
    }
  };
}

async function setCaptureQueueRetention(value) {
  const retentionDays = Number(value);
  if (!CAPTURE_QUEUE_RETENTION_OPTIONS.has(retentionDays)) {
    throw new Error("离线队列保留期限无效。");
  }
  return withQueueLock(async () => {
    const store = await readCaptureQueueStore();
    const pruning = pruneCaptureQueueStore(store, retentionDays);
    await extensionAPI.storage.local.set({ [CAPTURE_QUEUE_RETENTION_KEY]: retentionDays });
    const persisted = await writeCaptureQueueStore(pruning.store);
    return queueSummary(persisted.entries, {
      retentionDays,
      purgedCount: pruning.purgedCount,
      quarantine: persisted.quarantine,
      store: persisted
    });
  });
}

async function discardCaptureQueue() {
  return withQueueLock(async () => {
    const stored = await extensionAPI.storage.local.get([CAPTURE_QUEUE_RETENTION_KEY]);
    const retentionDays = normalizedQueueRetentionDays(stored?.[CAPTURE_QUEUE_RETENTION_KEY]);
    const store = emptyCaptureQueueStore();
    await writeCaptureQueueStore(store);
    return {
      importedCount: 0,
      ...queueSummary([], {
        retentionDays,
        quarantine: [],
        store
      })
    };
  });
}

async function updateCaptureQueueAlarm(hasRetryableEntries) {
  if (!extensionAPI.alarms) return;
  if (hasRetryableEntries) {
    await extensionAPI.alarms.create(CAPTURE_QUEUE_ALARM, { periodInMinutes: 1 });
  } else {
    await extensionAPI.alarms.clear(CAPTURE_QUEUE_ALARM);
  }
}

async function scheduleCaptureQueueRetry() {
  const store = await readCaptureQueueStore();
  const queue = store.entries;
  await updateCaptureQueueAlarm(queue.some((entry) => !entry.blocked));
  if (queue.length || store.quarantine.length) {
    const summary = queueSummary(queue, { quarantine: store.quarantine });
    await setQueueToolbarState(
      summary.queuedCount + summary.quarantinedCount,
      summary.blockedCount + summary.quarantinedCount
    );
  } else {
    const stored = await extensionAPI.storage.local.get(["bridgeToken"]);
    await setToolbarState(stored.bridgeToken ? "connected" : "disconnected");
  }
  if (queue.length) await flushCaptureQueue(null, false);
}

async function extractPage(maxHTMLBytes, maxTextBytes, makeSelfContainedArchive, captureMode) {
  const readMeta = (...selectors) => {
    for (const selector of selectors) {
      const value = document.querySelector(selector)?.content?.trim();
      if (value) return value;
    }
    return null;
  };
  const splitList = (value) => (value || "")
    .split(/[,，;；]/)
    .map((item) => item.trim())
    .filter(Boolean)
    .slice(0, 30);
  const normalize = (value) => (value || "")
    .replace(/\u00a0/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  const truncateUTF8 = (value, maximumBytes) => {
    const encoder = new TextEncoder();
    if (encoder.encode(value).length <= maximumBytes) return value;
    let lower = 0;
    let upper = value.length;
    while (lower < upper) {
      const middle = Math.ceil((lower + upper) / 2);
      if (encoder.encode(value.slice(0, middle)).length <= maximumBytes) {
        lower = middle;
      } else {
        upper = middle - 1;
      }
    }
    const truncated = value.slice(0, lower);
    const lastCodeUnit = truncated.charCodeAt(truncated.length - 1);
    return lastCodeUnit >= 0xD800 && lastCodeUnit <= 0xDBFF
      ? truncated.slice(0, -1)
      : truncated;
  };
  const safeLinkDestination = (rawValue) => {
    if (!rawValue) return null;
    try {
      const url = new URL(rawValue, document.baseURI);
      const scheme = url.protocol.toLowerCase();
      if (!["http:", "https:", "mailto:"].includes(scheme)) return null;
      if (["http:", "https:"].includes(scheme) && (url.username || url.password)) {
        return null;
      }
      return url.href
        .replace(/\(/g, "%28")
        .replace(/\)/g, "%29");
    } catch {
      return null;
    }
  };
  const normalizedInline = (value) => value
    .replace(/\s+/g, " ")
    .trim();
  const escapedLinkLabel = (value) => value
    .replace(/\\/g, "\\\\")
    .replace(/\[/g, "\\[")
    .replace(/\]/g, "\\]");
  const skippedElementNames = new Set([
    "SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG", "CANVAS",
    "FORM", "INPUT", "BUTTON", "SELECT", "TEXTAREA", "NAV", "FOOTER",
    "ASIDE", "DIALOG", "IFRAME", "OBJECT", "EMBED"
  ]);
  const noiseTokenPattern = /(^|[-_\s])(nav|menu|sidebar|footer|advert(?:isement)?|ads?|promo|cookie|consent|share|social|related|recommend(?:ed|ation)?|comment|popup|modal|newsletter|subscribe|paywall|breadcrumb|toolbar)([-_\s]|$)/i;
  const isNoiseElement = (element) => {
    if (skippedElementNames.has(element.tagName) || element.hidden) return true;
    if ((element.getAttribute("aria-hidden") || "").toLowerCase() === "true") return true;
    const role = (element.getAttribute("role") || "").toLowerCase();
    if (["navigation", "complementary", "dialog"].includes(role)) return true;
    const identity = `${element.id || ""} ${element.className || ""}`;
    return noiseTokenPattern.test(identity);
  };
  const blockElementNames = new Set([
    "ADDRESS", "ARTICLE", "ASIDE", "DD", "DETAILS", "DIV", "DL", "DT",
    "FIGCAPTION", "FIGURE", "FOOTER", "HEADER", "MAIN", "NAV", "SECTION",
    "SUMMARY", "TABLE", "TBODY", "TFOOT", "THEAD", "TR"
  ]);
  const renderChildren = (element, listDepth = 0) => Array.from(element.childNodes)
    .map((node) => renderNode(node, listDepth))
    .join("");
  const renderList = (list, listDepth) => {
    const ordered = list.tagName === "OL";
    const items = Array.from(list.children).filter((child) => child.tagName === "LI");
    const lines = items.map((item, index) => {
      const nestedLists = Array.from(item.children).filter((child) =>
        child.tagName === "UL" || child.tagName === "OL"
      );
      const body = normalizedInline(Array.from(item.childNodes)
        .filter((node) => !(node.nodeType === Node.ELEMENT_NODE
          && (node.tagName === "UL" || node.tagName === "OL")))
        .map((node) => renderNode(node, listDepth + 1))
        .join(""));
      const marker = ordered ? `${index + 1}. ` : "- ";
      const prefix = "  ".repeat(listDepth) + marker;
      const nested = nestedLists
        .map((nestedList) => renderList(nestedList, listDepth + 1).trimEnd())
        .filter(Boolean)
        .join("\n");
      return prefix + body + (nested ? `\n${nested}` : "");
    });
    return lines.length ? `${lines.join("\n")}\n\n` : "";
  };
  const renderNode = (node, listDepth = 0) => {
    if (node.nodeType === Node.TEXT_NODE) {
      return (node.nodeValue || "").replace(/\s+/g, " ");
    }
    if (node.nodeType !== Node.ELEMENT_NODE || isNoiseElement(node)) {
      return "";
    }

    const tagName = node.tagName;
    if (tagName === "BR") return "\n";
    if (tagName === "HR") return "\n\n---\n\n";
    if (tagName === "UL" || tagName === "OL") return renderList(node, listDepth);
    if (tagName === "LI") return renderChildren(node, listDepth);
    if (/^H[1-6]$/.test(tagName)) {
      const level = Number(tagName.slice(1));
      const heading = normalizedInline(renderChildren(node, listDepth));
      return heading ? `${"#".repeat(level)} ${heading}\n\n` : "";
    }
    if (tagName === "P") {
      const paragraph = normalizedInline(renderChildren(node, listDepth));
      return paragraph ? `${paragraph}\n\n` : "";
    }
    if (tagName === "A") {
      const label = normalizedInline(renderChildren(node, listDepth));
      const destination = safeLinkDestination(node.getAttribute("href"));
      if (!destination) return label;
      return `[${escapedLinkLabel(label || destination)}](${destination})`;
    }
    if (tagName === "IMG") {
      const alt = normalizedInline(node.getAttribute("alt") || "");
      const destination = safeLinkDestination(node.getAttribute("src"));
      if (!destination) return alt;
      return `![${escapedLinkLabel(alt)}](${destination})`;
    }
    if (tagName === "STRONG" || tagName === "B") {
      const text = normalizedInline(renderChildren(node, listDepth));
      return text ? `**${text}**` : "";
    }
    if (tagName === "EM" || tagName === "I") {
      const text = normalizedInline(renderChildren(node, listDepth));
      return text ? `*${text}*` : "";
    }
    if (tagName === "CODE" && node.parentElement?.tagName !== "PRE") {
      const text = normalizedInline(node.textContent || "");
      if (!text) return "";
      return text.includes("`") ? `\`\`${text}\`\`` : `\`${text}\``;
    }
    if (tagName === "PRE") {
      const text = (node.textContent || "").replace(/\n+$/, "");
      return text ? `\n\n\`\`\`\n${text}\n\`\`\`\n\n` : "";
    }
    if (tagName === "BLOCKQUOTE") {
      const text = normalize(renderChildren(node, listDepth));
      return text
        ? `${text.split("\n").map((line) => `> ${line}`).join("\n")}\n\n`
        : "";
    }

    const content = renderChildren(node, listDepth);
    if (tagName === "TD" || tagName === "TH") return `${normalizedInline(content)} | `;
    return blockElementNames.has(tagName) ? `${content}\n\n` : content;
  };

  const source = document.querySelector("article")
    || document.querySelector("main")
    || document.querySelector("[role='main']")
    || document.body;
  const contentMarkdown = normalize(renderNode(source));
  const cleanedContentText = truncateUTF8(
    contentMarkdown || normalize(source?.innerText || document.body?.innerText || ""),
    maxTextBytes
  );

  const canonical = document.querySelector("link[rel='canonical']")?.href;
  const sourceURL = canonical && /^https?:/i.test(canonical) ? canonical : location.href;
  const pageTitle = readMeta("meta[property='og:title']", "meta[name='twitter:title']")
    || document.title
    || new URL(sourceURL).hostname;
  const selectedText = truncateUTF8(
    normalize(globalThis.getSelection?.().toString() || ""),
    maxTextBytes
  );
  const linkText = `[${escapedLinkLabel(pageTitle)}](${safeLinkDestination(sourceURL) || sourceURL})`;
  const contentText = captureMode === "selection"
    ? selectedText
    : captureMode === "link-only"
      ? linkText
      : cleanedContentText;
  const clone = document.documentElement.cloneNode(true);
  clone.querySelectorAll("script,noscript,template,iframe,object,embed").forEach((node) => node.remove());
  clone.querySelectorAll("input,textarea,select").forEach((control) => {
    if (control.tagName === "INPUT") {
      const type = (control.getAttribute("type") || "text").toLowerCase();
      if (type === "hidden") {
        control.remove();
        return;
      }
      control.removeAttribute("value");
      if (["checkbox", "radio"].includes(type)) control.removeAttribute("checked");
    } else if (control.tagName === "TEXTAREA") {
      control.textContent = "";
    } else {
      Array.from(control.options || []).forEach((option) => option.removeAttribute("selected"));
    }
    control.setAttribute("disabled", "");
  });
  clone.querySelectorAll("*").forEach((element) => {
    Array.from(element.attributes).forEach((attribute) => {
      if (/^on/i.test(attribute.name)) element.removeAttribute(attribute.name);
      if (["href", "src", "action", "formaction"].includes(attribute.name.toLowerCase())
          && /^\s*javascript:/i.test(attribute.value)) {
        element.removeAttribute(attribute.name);
      }
    });
  });
  clone.querySelectorAll("base").forEach((base) => base.remove());
  const base = document.createElement("base");
  base.setAttribute("href", document.baseURI);
  (clone.querySelector("head") || clone).prepend(base);

  const basicSerialized = "<!doctype html>\n" + clone.outerHTML;
  const estimatedArchiveBytes = new TextEncoder().encode(basicSerialized).length;
  const archiveReport = {
    format: "html",
    embeddedResourceCount: 0,
    missingResourceCount: 0,
    wasTruncated: false
  };
  let serialized = basicSerialized;
  let archiveKnownResourceCount = 0;

  if (makeSelfContainedArchive) {
    const encoder = new TextEncoder();
    const resourceCache = new Map();
    const stylesheetCache = new Map();
    const embeddedURLs = new Set();
    const missingURLs = new Set();
    const archiveDeadline = Date.now() + 15_000;
    const maximumSingleResourceBytes = 5 * 1_024 * 1_024;
    let remainingBudget = Math.max(maxHTMLBytes - encoder.encode(basicSerialized).length - 64 * 1_024, 0);
    let reachedBudget = remainingBudget === 0;

    const resolvedResourceURL = (rawValue, baseURL = document.baseURI) => {
      if (!rawValue || /^\s*(data:|blob:|#)/i.test(rawValue)) return rawValue || null;
      try {
        const url = new URL(rawValue, baseURL);
        if (!["http:", "https:"].includes(url.protocol.toLowerCase())) return null;
        if (url.username || url.password) return null;
        url.hash = "";
        return url.href;
      } catch {
        return null;
      }
    };
    const markMissing = (url) => {
      if (url && /^https?:/i.test(url)) missingURLs.add(url);
    };
    const responseTimeout = () => Math.max(250, Math.min(4_000, archiveDeadline - Date.now()));
    const extensionRuntime = globalThis.browser?.runtime ?? globalThis.chrome?.runtime;
    const validateResourceURLWithExtension = async (rawURL) => {
      const url = resolvedResourceURL(rawURL);
      if (!url || !extensionRuntime?.sendMessage) {
        throw new Error("archive resource validation unavailable");
      }
      let timeout;
      try {
        const response = await Promise.race([
          extensionRuntime.sendMessage({ type: "validate-archive-resource-url", url }),
          new Promise((_, reject) => {
            timeout = setTimeout(
              () => reject(new Error("archive resource validation timed out")),
              responseTimeout()
            );
          })
        ]);
        const approvedURL = resolvedResourceURL(response?.result?.url);
        if (!response?.ok || !response.result?.allowed || approvedURL !== url) {
          throw new Error(response?.error || "archive resource rejected");
        }
        return approvedURL;
      } finally {
        clearTimeout(timeout);
      }
    };
    const readLimitedResponseBody = async (response, maximumBytes, controller) => {
      const contentLength = response.headers.get("content-length");
      if (/^\d+$/.test(contentLength || "") && Number(contentLength) > maximumBytes) {
        controller.abort();
        throw new Error("resource content-length exceeds limit");
      }
      const reader = response.body?.getReader?.();
      if (!reader) {
        controller.abort();
        throw new Error("streaming response body unavailable");
      }
      const chunks = [];
      let totalBytes = 0;
      try {
        while (true) {
          if (Date.now() >= archiveDeadline) {
            controller.abort();
            throw new Error("archive deadline reached");
          }
          const { done, value } = await reader.read();
          if (done) break;
          const chunk = value instanceof Uint8Array ? value : new Uint8Array(value || []);
          totalBytes += chunk.byteLength;
          if (totalBytes > maximumBytes) {
            controller.abort();
            await reader.cancel("resource size limit reached").catch(() => {});
            throw new Error("resource stream exceeds limit");
          }
          chunks.push(chunk);
        }
      } catch (error) {
        controller.abort();
        throw error;
      }
      const bytes = new Uint8Array(totalBytes);
      let offset = 0;
      for (const chunk of chunks) {
        bytes.set(chunk, offset);
        offset += chunk.byteLength;
      }
      return bytes;
    };
    const fetchResourceBytes = async (rawURL, maximumBytes) => {
      if (!Number.isFinite(maximumBytes) || maximumBytes <= 0) {
        throw new Error("archive budget reached");
      }
      let url = resolvedResourceURL(rawURL);
      if (!url) throw new Error("archive resource URL rejected");
      const maximumRedirects = 5;
      for (let redirectCount = 0; redirectCount <= maximumRedirects; redirectCount += 1) {
        if (Date.now() >= archiveDeadline) throw new Error("archive deadline reached");
        url = await validateResourceURLWithExtension(url);
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), responseTimeout());
        try {
          const target = new URL(url);
          const sameOrigin = target.origin === location.origin;
          const response = await fetch(url, {
            cache: "no-store",
            credentials: sameOrigin ? "include" : "omit",
            redirect: "manual",
            referrerPolicy: sameOrigin ? "same-origin" : "no-referrer",
            signal: controller.signal
          });
          if (response.type === "opaqueredirect" || response.status === 0) {
            controller.abort();
            throw new Error("opaque redirect rejected");
          }
          if ([301, 302, 303, 307, 308].includes(response.status)) {
            if (redirectCount >= maximumRedirects) {
              controller.abort();
              throw new Error("too many resource redirects");
            }
            const locationHeader = response.headers.get("location");
            const redirectedURL = resolvedResourceURL(locationHeader, url);
            controller.abort();
            if (!redirectedURL) throw new Error("resource redirect rejected");
            url = redirectedURL;
            continue;
          }
          if (response.redirected) {
            controller.abort();
            throw new Error("automatic resource redirect rejected");
          }
          if (!response.ok) throw new Error(`HTTP ${response.status}`);
          const bytes = await readLimitedResponseBody(response, maximumBytes, controller);
          return {
            bytes,
            contentType: String(response.headers.get("content-type") || "")
              .split(";", 1)[0]
              .trim(),
            url
          };
        } finally {
          clearTimeout(timeout);
        }
      }
      throw new Error("too many resource redirects");
    };
    const blobAsDataURL = (blob) => new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(reader.error || new Error("resource read failed"));
      reader.onload = () => resolve(String(reader.result || ""));
      reader.readAsDataURL(blob);
    });
    const resourceDataURL = async (rawValue, baseURL = document.baseURI) => {
      if (/^\s*data:/i.test(rawValue || "")) return rawValue;
      const url = resolvedResourceURL(rawValue, baseURL);
      if (!url) return null;
      if (resourceCache.has(url)) return resourceCache.get(url);
      const task = (async () => {
        try {
          const maximumRawBytes = Math.min(
            maximumSingleResourceBytes,
            Math.floor(Math.max(remainingBudget - 128, 0) * 3 / 4)
          );
          const fetched = await fetchResourceBytes(url, maximumRawBytes);
          const blob = new Blob([fetched.bytes], {
            type: fetched.contentType || "application/octet-stream"
          });
          const dataURL = await blobAsDataURL(blob);
          const cost = encoder.encode(dataURL).length;
          if (cost > remainingBudget) {
            reachedBudget = true;
            throw new Error("archive budget reached");
          }
          remainingBudget -= cost;
          embeddedURLs.add(fetched.url);
          return dataURL;
        } catch {
          markMissing(url);
          return null;
        }
      })();
      resourceCache.set(url, task);
      return task;
    };
    const stylesheetText = async (rawValue, baseURL = document.baseURI) => {
      const url = resolvedResourceURL(rawValue, baseURL);
      if (!url) return null;
      if (stylesheetCache.has(url)) return stylesheetCache.get(url);
      const task = (async () => {
        try {
          const fetched = await fetchResourceBytes(
            url,
            Math.min(1 * 1_024 * 1_024, remainingBudget)
          );
          const css = new TextDecoder().decode(fetched.bytes);
          const cost = encoder.encode(css).length;
          if (cost > Math.min(1 * 1_024 * 1_024, remainingBudget)) {
            reachedBudget = true;
            throw new Error("stylesheet too large");
          }
          remainingBudget -= cost;
          embeddedURLs.add(fetched.url);
          return { css, url: fetched.url };
        } catch {
          markMissing(url);
          return null;
        }
      })();
      stylesheetCache.set(url, task);
      return task;
    };
    const inlineCSSResources = async (css, baseURL) => {
      const pattern = /url\(\s*(["']?)([^"')]+)\1\s*\)/gi;
      const matches = Array.from(css.matchAll(pattern));
      if (!matches.length) return css;
      let output = "";
      let cursor = 0;
      for (const match of matches) {
        output += css.slice(cursor, match.index);
        const rawURL = match[2].trim();
        const dataURL = await resourceDataURL(rawURL, baseURL);
        output += dataURL ? `url("${dataURL}")` : match[0];
        cursor = match.index + match[0].length;
      }
      return output + css.slice(cursor);
    };

    const originalImages = Array.from(document.querySelectorAll("img"));
    const clonedImages = Array.from(clone.querySelectorAll("img"));
    for (let index = 0; index < clonedImages.length; index += 1) {
      const original = originalImages[index];
      const target = clonedImages[index];
      const rawURL = original?.currentSrc || original?.getAttribute("src") || target.getAttribute("src");
      const dataURL = await resourceDataURL(rawURL);
      const absoluteURL = resolvedResourceURL(rawURL);
      if (dataURL) target.setAttribute("src", dataURL);
      else if (absoluteURL) target.setAttribute("src", absoluteURL);
      target.removeAttribute("srcset");
      target.removeAttribute("sizes");
      target.removeAttribute("loading");
      target.removeAttribute("crossorigin");
    }
    clone.querySelectorAll("picture source[srcset]").forEach((source) => source.removeAttribute("srcset"));

    for (const style of Array.from(clone.querySelectorAll("style"))) {
      style.textContent = await inlineCSSResources(style.textContent || "", document.baseURI);
    }
    for (const element of Array.from(clone.querySelectorAll("[style]"))) {
      element.setAttribute(
        "style",
        await inlineCSSResources(element.getAttribute("style") || "", document.baseURI)
      );
    }
    for (const link of Array.from(clone.querySelectorAll("link[rel~='stylesheet'][href]"))) {
      const fetched = await stylesheetText(link.getAttribute("href"));
      if (!fetched) {
        const absoluteURL = resolvedResourceURL(link.getAttribute("href"));
        if (absoluteURL) link.setAttribute("href", absoluteURL);
        continue;
      }
      const style = document.createElement("style");
      style.setAttribute("data-knowledge-archive-source", fetched.url);
      style.textContent = await inlineCSSResources(fetched.css, fetched.url);
      link.replaceWith(style);
    }
    for (const icon of Array.from(clone.querySelectorAll("link[rel~='icon'][href]"))) {
      const dataURL = await resourceDataURL(icon.getAttribute("href"));
      const absoluteURL = resolvedResourceURL(icon.getAttribute("href"));
      if (dataURL) icon.setAttribute("href", dataURL);
      else if (absoluteURL) icon.setAttribute("href", absoluteURL);
    }
    clone.querySelectorAll("a[href]").forEach((anchor) => {
      const absoluteURL = resolvedResourceURL(anchor.getAttribute("href"));
      if (absoluteURL) anchor.setAttribute("href", absoluteURL);
    });
    clone.querySelectorAll("video[src],audio[src],video[poster],source[src]").forEach((media) => {
      for (const attribute of ["src", "poster"]) {
        const rawURL = media.getAttribute(attribute);
        const absoluteURL = resolvedResourceURL(rawURL);
        if (absoluteURL) {
          media.setAttribute(attribute, absoluteURL);
          markMissing(absoluteURL);
        }
      }
    });

    archiveReport.embeddedResourceCount = embeddedURLs.size;
    archiveReport.missingResourceCount = missingURLs.size;
    archiveReport.wasTruncated = reachedBudget || Date.now() >= archiveDeadline;
    archiveKnownResourceCount = new Set([...embeddedURLs, ...missingURLs]).size;
    const reportMeta = document.createElement("meta");
    reportMeta.setAttribute("name", "knowledge-archive-report");
    reportMeta.setAttribute(
      "content",
      `embedded=${archiveReport.embeddedResourceCount}; missing=${archiveReport.missingResourceCount}; truncated=${archiveReport.wasTruncated}`
    );
    (clone.querySelector("head") || clone).prepend(reportMeta);
    serialized = "<!doctype html>\n" + clone.outerHTML;
  }

  if (new TextEncoder().encode(serialized).length > maxHTMLBytes) {
    archiveReport.wasTruncated = true;
    archiveReport.embeddedResourceCount = 0;
    archiveReport.missingResourceCount = Math.max(
      archiveReport.missingResourceCount,
      archiveKnownResourceCount
    );
    serialized = basicSerialized;
  }
  if (new TextEncoder().encode(serialized).length > maxHTMLBytes) {
    const escapeHTML = (value) => value
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
    serialized = `<!doctype html><html lang="${escapeHTML(document.documentElement.lang || "")}"><head><meta charset="utf-8"><title>${escapeHTML(document.title || sourceURL)}</title></head><body><main><h1>${escapeHTML(document.title || sourceURL)}</h1><p><a href="${escapeHTML(sourceURL)}">${escapeHTML(sourceURL)}</a></p><pre>${escapeHTML(contentText)}</pre></main></body></html>`;
  }

  const authors = splitList(readMeta(
    "meta[name='author']",
    "meta[property='article:author']",
    "meta[name='byl']"
  ));
  const tags = splitList(readMeta(
    "meta[name='keywords']",
    "meta[property='article:tag']"
  ));

  return {
    pageURL: location.href,
    sourceURL,
    title: pageTitle,
    authors,
    language: document.documentElement.lang || null,
    summary: readMeta(
      "meta[name='description']",
      "meta[property='og:description']",
      "meta[name='twitter:description']"
    ),
    tags,
    contentText,
    originalHTML: serialized,
    archiveReport: makeSelfContainedArchive ? archiveReport : null,
    estimatedArchiveBytes
  };
}

function saveAsMHTML(tabId) {
  return new Promise((resolve, reject) => {
    extensionAPI.pageCapture.saveAsMHTML({ tabId }, (blob) => {
      const runtimeError = extensionAPI.runtime.lastError;
      if (runtimeError) {
        reject(new Error(runtimeError.message));
      } else if (!blob) {
        reject(new Error("浏览器没有返回 MHTML 归档。"));
      } else {
        resolve(blob);
      }
    });
  });
}

function blobToBase64(blob) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error("读取页面归档失败。"));
    reader.onload = () => {
      const result = String(reader.result || "");
      resolve(result.slice(result.indexOf(",") + 1));
    };
    reader.readAsDataURL(blob);
  });
}

function readableError(error) {
  if (String(error?.message || error).includes("Failed to fetch")) {
    return "无法连接应用。请打开“个人网站发布控制台”，并确认连接令牌有效。";
  }
  return error?.message || String(error);
}
