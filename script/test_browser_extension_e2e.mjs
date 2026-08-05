#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFile, spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import http from "node:http";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, "..");
const SOURCE_BUILDER = path.join(ROOT_DIR, "script", "build_browser_extension_source.py");
const EXTENSION_STAGE_ROOT = path.join(ROOT_DIR, ".build", "browser-extension-e2e", "sources");
const CHROMIUM_EXTENSION_DIR = path.join(EXTENSION_STAGE_ROOT, "chrome");
const FIREFOX_EXTENSION_DIR = path.join(EXTENSION_STAGE_ROOT, "firefox");
const ARTIFACT_DIR = path.join(ROOT_DIR, "output", "playwright", "browser-extension-e2e");
const CHROMIUM_PROFILE_DIR = path.join(ROOT_DIR, ".build", "browser-extension-e2e", "chromium-profile");
const CHROMIUM_ENGLISH_PROFILE_DIR = path.join(
  ROOT_DIR, ".build", "browser-extension-e2e", "chromium-english-profile"
);
const FIREFOX_PROFILE_DIR = path.join(ROOT_DIR, ".build", "browser-extension-e2e", "firefox-profile");
const FIREFOX_EXTENSION_ID = "knowledge-capture@jinfang.local";
const TEST_TIMEOUT_MS = 15_000;
const execFileAsync = promisify(execFile);

const requestedBrowser = process.argv.find((argument) => argument.startsWith("--browser="))
  ?.split("=", 2)[1] || "all";
assert.ok(
  ["all", "chromium", "firefox"].includes(requestedBrowser),
  "--browser must be all, chromium, or firefox"
);

await fs.mkdir(ARTIFACT_DIR, { recursive: true });
await fs.rm(EXTENSION_STAGE_ROOT, { recursive: true, force: true });
await fs.mkdir(EXTENSION_STAGE_ROOT, { recursive: true });
await Promise.all([
  ["chrome", CHROMIUM_EXTENSION_DIR],
  ["firefox", FIREFOX_EXTENSION_DIR],
].map(([browser, outputDir]) => execFileAsync(
  "python3",
  [SOURCE_BUILDER, "--browser", browser, "--output-dir", outputDir],
  { cwd: ROOT_DIR }
)));

const testResults = [];
let chromiumPageForFailure = null;
let firefoxClientForFailure = null;
let firefoxContextForFailure = null;

async function test(name, operation) {
  const startedAt = Date.now();
  try {
    await operation();
    testResults.push({ name, status: "passed", durationMs: Date.now() - startedAt });
    console.log(`✓ ${name}`);
  } catch (error) {
    testResults.push({
      name,
      status: "failed",
      durationMs: Date.now() - startedAt,
      error: error?.stack || String(error)
    });
    throw error;
  }
}

function withTimeout(promise, message, timeoutMs = TEST_TIMEOUT_MS) {
  let timeoutID;
  const timeout = new Promise((_, reject) => {
    timeoutID = setTimeout(() => reject(new Error(message)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timeoutID));
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

async function startFixtureServer() {
  const server = http.createServer((request, response) => {
    const pageName = request.url === "/article-b" ? "语义检索笔记" : "混合检索笔记";
    response.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store"
    });
    response.end(`<!doctype html>
      <html lang="zh-CN">
        <head><meta charset="utf-8"><title>${pageName}</title></head>
        <body>
          <main>
            <article>
              <h1>${pageName}</h1>
              <p>这是真实浏览器扩展端到端测试页面。</p>
              <p>它用于验证标签页身份、权限请求和正文采集路径。</p>
            </article>
          </main>
        </body>
      </html>`);
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  return {
    urls: [
      `http://127.0.0.1:${address.port}/article-a`,
      `http://127.0.0.1:${address.port}/article-b`
    ],
    close: () => new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
    })
  };
}

async function waitForChromiumServiceWorker(context) {
  const current = context.serviceWorkers()[0];
  if (current) return current;
  return withTimeout(
    context.waitForEvent("serviceworker"),
    "Chromium did not start the extension service worker"
  );
}

async function chromiumServiceWorkerTargets(cdpSession, extensionID) {
  const { targetInfos } = await cdpSession.send("Target.getTargets");
  return targetInfos.filter((target) =>
    target.type === "service_worker"
      && target.url.startsWith(`chrome-extension://${extensionID}/`)
  );
}

async function waitUntil(predicate, message, timeoutMs = TEST_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const value = await predicate();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await delay(100);
  }
  throw new Error(lastError ? `${message}: ${lastError.message}` : message);
}

async function runChromiumTests(fixture) {
  await fs.rm(CHROMIUM_PROFILE_DIR, { recursive: true, force: true });
  await fs.mkdir(path.dirname(CHROMIUM_PROFILE_DIR), { recursive: true });
  const executablePath = process.env.CHROMIUM_EXECUTABLE_PATH || chromium.executablePath();
  await fs.access(executablePath);
  const context = await chromium.launchPersistentContext(CHROMIUM_PROFILE_DIR, {
    executablePath,
    headless: process.env.BROWSER_EXTENSION_E2E_HEADED !== "1",
    locale: "zh-CN",
    viewport: { width: 1280, height: 900 },
    args: [
      `--disable-extensions-except=${CHROMIUM_EXTENSION_DIR}`,
      `--load-extension=${CHROMIUM_EXTENSION_DIR}`,
      "--no-first-run",
      "--no-default-browser-check"
    ]
  });
  let popup = null;
  try {
    const worker = await waitForChromiumServiceWorker(context);
    const extensionURL = new URL(worker.url());
    const extensionID = extensionURL.host;

    await test("Chromium 加载真实 MV3 扩展和浏览器 API", async () => {
      const capabilities = await worker.evaluate(() => ({
        manifestVersion: chrome.runtime.getManifest().manifest_version,
        runtime: typeof chrome.runtime.sendMessage === "function",
        tabs: typeof chrome.tabs.query === "function",
        permissions: typeof chrome.permissions.request === "function",
        scripting: typeof chrome.scripting.executeScript === "function",
        pageCapture: typeof chrome.pageCapture?.saveAsMHTML === "function",
        nativeMessaging: typeof chrome.runtime.sendNativeMessage === "function",
        loopbackPermission: chrome.runtime.getManifest().host_permissions
          ?.includes("http://127.0.0.1:17843/*") === true,
        action: typeof chrome.action?.setBadgeText === "function",
        serviceWorker: typeof ServiceWorkerGlobalScope !== "undefined"
      }));
      assert.deepEqual(capabilities, {
        manifestVersion: 3,
        runtime: true,
        tabs: true,
        permissions: true,
        scripting: true,
        pageCapture: true,
        nativeMessaging: false,
        loopbackPermission: true,
        action: true,
        serviceWorker: true
      });
    });

    const probePage = await context.newPage();
    chromiumPageForFailure = probePage;
    await probePage.setViewportSize({ width: 320, height: 720 });
    await probePage.goto(`chrome-extension://${extensionID}/popup.html`, { waitUntil: "domcontentloaded" });
    await probePage.locator("#queue-panel[aria-busy='false']").waitFor({ timeout: TEST_TIMEOUT_MS });

    await test("Chromium 320px 宽度无横向裁切并切换为单列", async () => {
      const layout = await probePage.evaluate(() => {
        const savePanel = document.querySelector("#save-panel");
        const organizationPanel = document.querySelector("#organization-panel");
        const wasSavePanelHidden = savePanel.hidden;
        const wasOrganizationPanelHidden = organizationPanel.hidden;
        const wasOrganizationPanelOpen = organizationPanel.open;
        savePanel.hidden = false;
        organizationPanel.hidden = false;
        organizationPanel.open = true;
        const interactive = Array.from(document.querySelectorAll("button, input, select, textarea"))
          .filter((element) => {
            const style = getComputedStyle(element);
            const rectangle = element.getBoundingClientRect();
            return style.display !== "none" && style.visibility !== "hidden"
              && rectangle.width > 0 && rectangle.height > 0;
          })
          .map((element) => {
            const rectangle = element.getBoundingClientRect();
            return { id: element.id, left: rectangle.left, right: rectangle.right };
          });
        const modeCards = Array.from(document.querySelectorAll(".mode-card"));
        const captureColumns = modeCards.length > 1
          && Math.abs(modeCards[0].getBoundingClientRect().top
            - modeCards[1].getBoundingClientRect().top) < 1
          ? 2
          : 1;
        const result = {
          viewportWidth: innerWidth,
          documentScrollWidth: document.documentElement.scrollWidth,
          bodyScrollWidth: document.body.scrollWidth,
          captureColumns,
          overflowing: interactive.filter((element) =>
            element.left < -0.5 || element.right > innerWidth + 0.5
          )
        };
        savePanel.hidden = wasSavePanelHidden;
        organizationPanel.hidden = wasOrganizationPanelHidden;
        organizationPanel.open = wasOrganizationPanelOpen;
        return result;
      });
      assert.equal(layout.viewportWidth, 320);
      assert.ok(layout.documentScrollWidth <= 320, JSON.stringify(layout));
      assert.ok(layout.bodyScrollWidth <= 320, JSON.stringify(layout));
      assert.equal(layout.captureColumns, 1, JSON.stringify(layout));
      assert.deepEqual(layout.overflowing, []);
    });

    await test("Chromium 弹窗使用语义化表单、标题、分类搜索反馈和独立播报区", async () => {
      const semantics = await probePage.evaluate(() => {
        const organizationPanel = document.querySelector("#organization-panel");
        const wasHidden = organizationPanel.hidden;
        organizationPanel.hidden = false;
        populateFolderOptions([
          { id: "folder-a", name: "产品研究" },
          { id: "folder-b", name: "阅读" }
        ], "folder-a", "不存在");
        const result = {
          connectionTag: document.querySelector("#connection-form")?.tagName,
          connectType: document.querySelector("#connect")?.type,
          headingTags: Array.from(document.querySelectorAll("section h2, section h3, details h2, details h3"))
            .map((heading) => heading.tagName),
          organizationHeading: document.querySelector("#organization-title")?.tagName,
          markHidden: document.querySelector(".mark")?.getAttribute("aria-hidden"),
          searchLabel: document.querySelector('label[for="folder-search"]')?.textContent,
          resultCount: document.querySelector("#folder-search-result")?.textContent,
          emptyHidden: document.querySelector("#folder-empty-state")?.hidden,
          emptyText: document.querySelector("#folder-empty-state")?.textContent,
          statusRole: document.querySelector("#status")?.getAttribute("role"),
          alertRole: document.querySelector("#alert")?.getAttribute("role"),
          sessionAfterQueue: Boolean(
            document.querySelector("#queue-panel")?.compareDocumentPosition(
              document.querySelector("#session-panel")
            ) & Node.DOCUMENT_POSITION_FOLLOWING
          )
        };
        organizationPanel.hidden = wasHidden;
        return result;
      });
      assert.equal(semantics.connectionTag, "FORM", JSON.stringify(semantics));
      assert.equal(semantics.connectType, "submit", JSON.stringify(semantics));
      assert.ok(semantics.headingTags.includes("H2"), JSON.stringify(semantics));
      assert.ok(semantics.headingTags.every((tag) => ["H2", "H3"].includes(tag)), JSON.stringify(semantics));
      assert.equal(semantics.organizationHeading, "H2", JSON.stringify(semantics));
      assert.equal(semantics.markHidden, "true", JSON.stringify(semantics));
      assert.equal(semantics.searchLabel, "搜索分类", JSON.stringify(semantics));
      assert.equal(semantics.resultCount, "共 0 个分类", JSON.stringify(semantics));
      assert.equal(semantics.emptyHidden, false, JSON.stringify(semantics));
      assert.equal(semantics.emptyText, "没有匹配的分类。", JSON.stringify(semantics));
      assert.equal(semantics.statusRole, "status", JSON.stringify(semantics));
      assert.equal(semantics.alertRole, "alert", JSON.stringify(semantics));
      assert.equal(semantics.sessionAfterQueue, true, JSON.stringify(semantics));
    });

    await test("Chromium 令牌输入框按 Enter 提交连接表单", async () => {
      await probePage.locator("#token").fill("e2e-invalid-token");
      await probePage.locator("#token").press("Enter");
      await waitUntil(async () => probePage.evaluate(() => {
        const button = document.querySelector("#connect");
        const announcement = `${document.querySelector("#status")?.textContent || ""}${document.querySelector("#alert")?.textContent || ""}`;
        return button?.getAttribute("aria-busy") === "false" && announcement.trim().length > 0;
      }), "Enter did not submit the connection form");
      const submitted = await probePage.evaluate(() => ({
        button: document.querySelector("#connect")?.textContent,
        connectionVisible: !document.querySelector("#connection-panel")?.hidden,
        announcement: `${document.querySelector("#status")?.textContent || ""}${document.querySelector("#alert")?.textContent || ""}`
      }));
      assert.equal(submitted.button, "连接", JSON.stringify(submitted));
      assert.equal(submitted.connectionVisible, true, JSON.stringify(submitted));
      assert.ok(submitted.announcement.trim().length > 0, JSON.stringify(submitted));
      await probePage.reload({ waitUntil: "domcontentloaded" });
      await probePage.locator("#queue-panel[aria-busy='false']").waitFor({ timeout: TEST_TIMEOUT_MS });
    });

    await test("Chromium 键盘 Tab 产生真实可见焦点环", async () => {
      await probePage.evaluate(() => document.activeElement?.blur());
      await probePage.keyboard.press("Tab");
      const focus = await probePage.evaluate(() => {
        const element = document.activeElement;
        const style = getComputedStyle(element);
        return {
          id: element?.id || "",
          outlineStyle: style.outlineStyle,
          outlineWidth: Number.parseFloat(style.outlineWidth),
          outlineColor: style.outlineColor
        };
      });
      assert.equal(focus.id, "token", JSON.stringify(focus));
      assert.notEqual(focus.outlineStyle, "none", JSON.stringify(focus));
      assert.ok(focus.outlineWidth >= 2, JSON.stringify(focus));
      assert.notEqual(focus.outlineColor, "rgba(0, 0, 0, 0)", JSON.stringify(focus));
    });

    await test("Chromium Service Worker 被终止后可由消息唤醒并保留状态", async () => {
      const sentinel = `e2e-${Date.now()}`;
      await worker.evaluate((value) => chrome.storage.local.set({ e2eServiceWorkerSentinel: value }), sentinel);
      const cdpSession = await context.newCDPSession(probePage);
      const currentTargets = await chromiumServiceWorkerTargets(cdpSession, extensionID);
      assert.equal(currentTargets.length, 1, JSON.stringify(currentTargets));
      const oldTargetID = currentTargets[0].targetId;
      await cdpSession.send("Target.closeTarget", { targetId: oldTargetID });
      await waitUntil(async () => {
        const targets = await chromiumServiceWorkerTargets(cdpSession, extensionID);
        return targets.every((target) => target.targetId !== oldTargetID);
      }, "old extension service worker target did not terminate");
      const response = await withTimeout(
        probePage.evaluate(() => chrome.runtime.sendMessage({ type: "capture-queue-status" })),
        "message did not wake the extension service worker"
      );
      assert.equal(response?.ok, true, JSON.stringify(response));
      assert.ok(["empty", "content"].includes(response?.result?.queueState), JSON.stringify(response));
      const stored = await probePage.evaluate(() => chrome.storage.local.get("e2eServiceWorkerSentinel"));
      assert.equal(stored.e2eServiceWorkerSentinel, sentinel);
      await cdpSession.detach();
    });

    await test("Chromium 真实可选权限请求进入浏览器托管提示", async () => {
      const currentWorker = await waitForChromiumServiceWorker(context);
      await currentWorker.evaluate(() => chrome.storage.local.remove([
        "bridgeToken",
        "bridgeTokenExpiresAtV1"
      ]));
      const selectedTabs = await currentWorker.evaluate(async (urls) => {
        const first = await chrome.tabs.create({ url: urls[0], active: false });
        const second = await chrome.tabs.create({ url: urls[1], active: false });
        await chrome.tabs.highlight({
          windowId: first.windowId,
          tabs: [first.index, second.index]
        });
        return [first.id, second.id];
      }, fixture.urls);
      assert.equal(selectedTabs.length, 2);
      popup = probePage;
      chromiumPageForFailure = popup;
      await popup.reload({ waitUntil: "domcontentloaded" });
      await popup.locator("#queue-panel[aria-busy='false']").waitFor({ timeout: TEST_TIMEOUT_MS });
      await popup.evaluate(() => {
        document.querySelector("#save-panel").hidden = false;
        const organizationPanel = document.querySelector("#organization-panel");
        organizationPanel.hidden = false;
        organizationPanel.open = true;
      });
      const batchButton = popup.locator("#batch-save");
      await waitUntil(async () => !(await batchButton.isDisabled()), "batch button did not become available");
      await batchButton.click();
      await delay(750);
      const presentation = await popup.evaluate(() => ({
        busy: document.querySelector("#batch-save")?.getAttribute("aria-busy"),
        disabled: document.querySelector("#batch-save")?.disabled,
        label: document.querySelector("#batch-save")?.textContent,
        status: document.querySelector("#status")?.textContent
      }));
      assert.equal(presentation.busy, "true", JSON.stringify(presentation));
      assert.equal(presentation.disabled, true, JSON.stringify(presentation));
      assert.ok(presentation.label.includes("正在识别所选网站"), JSON.stringify(presentation));
      const tabsPermission = await popup.evaluate(() =>
        chrome.permissions.contains({ permissions: ["tabs"] })
      );
      assert.equal(tabsPermission, false, "browser granted tabs before the user decided the prompt");
      assert.ok(!presentation.status.includes("已生成批量保存清单"), JSON.stringify(presentation));
    });
  } finally {
    if (chromiumPageForFailure && !chromiumPageForFailure.isClosed()) {
      await chromiumPageForFailure.screenshot({
        path: path.join(ARTIFACT_DIR, "chromium-final.png"),
        fullPage: true
      }).catch(() => {});
    }
    await context.close();
    chromiumPageForFailure = null;
  }
}

async function runChromiumEnglishLocalizationTest() {
  await fs.rm(CHROMIUM_ENGLISH_PROFILE_DIR, { recursive: true, force: true });
  await fs.mkdir(path.dirname(CHROMIUM_ENGLISH_PROFILE_DIR), { recursive: true });
  const executablePath = process.env.CHROMIUM_EXECUTABLE_PATH || chromium.executablePath();
  const context = await chromium.launchPersistentContext(CHROMIUM_ENGLISH_PROFILE_DIR, {
    executablePath,
    headless: process.env.BROWSER_EXTENSION_E2E_HEADED !== "1",
    locale: "en-US",
    viewport: { width: 420, height: 760 },
    args: [
      `--disable-extensions-except=${CHROMIUM_EXTENSION_DIR}`,
      `--load-extension=${CHROMIUM_EXTENSION_DIR}`,
      "--lang=en-US",
      "--no-first-run",
      "--no-default-browser-check"
    ]
  });
  try {
    const worker = await waitForChromiumServiceWorker(context);
    const extensionID = new URL(worker.url()).host;
    const page = await context.newPage();
    await page.goto(`chrome-extension://${extensionID}/popup.html`, { waitUntil: "domcontentloaded" });
    await page.locator("#queue-panel[aria-busy='false']").waitFor({ timeout: TEST_TIMEOUT_MS });
    await test("Chromium 英文浏览器加载完整英文弹窗正文", async () => {
      const copy = await page.evaluate(() => ({
        lang: document.documentElement.lang,
        title: document.querySelector("h1")?.textContent,
        connection: document.querySelector("#connection-title")?.textContent,
        nativeHint: document.querySelector("#connection-form .hint")?.textContent,
        searchLabel: document.querySelector('label[for="folder-search"]')?.textContent,
        queueTitle: document.querySelector("#queue-title")?.textContent
      }));
      assert.match(copy.lang, /^en/i, JSON.stringify(copy));
      assert.equal(copy.title, "Save to Knowledge Library", JSON.stringify(copy));
      assert.equal(copy.connection, "Connect to Library", JSON.stringify(copy));
      assert.match(copy.nativeHint, /127\.0\.0\.1/, JSON.stringify(copy));
      assert.match(copy.nativeHint, /loopback interface/, JSON.stringify(copy));
      assert.equal(copy.searchLabel, "Search categories", JSON.stringify(copy));
      assert.equal(copy.queueTitle, "Pending queue", JSON.stringify(copy));
    });
  } finally {
    await context.close();
  }
}

function firefoxExecutablePath() {
  if (process.env.FIREFOX_EXECUTABLE_PATH) return process.env.FIREFOX_EXECUTABLE_PATH;
  if (process.platform === "darwin") {
    return "/Applications/Firefox.app/Contents/MacOS/firefox";
  }
  return "firefox";
}

async function availablePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const port = address.port;
  await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));
  return port;
}

class BiDiClient {
  constructor(socket) {
    this.socket = socket;
    this.nextID = 0;
    this.pending = new Map();
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(String(event.data));
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.type === "success") pending.resolve(message.result);
      else pending.reject(new Error(`${message.error}: ${message.message || "unknown BiDi error"}`));
    });
    socket.addEventListener("close", () => {
      for (const pending of this.pending.values()) {
        pending.reject(new Error("Firefox BiDi connection closed"));
      }
      this.pending.clear();
    });
  }

  static async connect(url) {
    const socket = new WebSocket(url);
    await withTimeout(new Promise((resolve, reject) => {
      socket.addEventListener("open", resolve, { once: true });
      socket.addEventListener("error", () => reject(new Error("Firefox BiDi WebSocket failed")), {
        once: true
      });
    }), "Firefox BiDi WebSocket did not open");
    return new BiDiClient(socket);
  }

  call(method, params = {}) {
    const id = ++this.nextID;
    return withTimeout(new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.socket.send(JSON.stringify({ id, method, params }));
    }), `Firefox BiDi command timed out: ${method}`);
  }

  async evaluateJSONTarget(target, expression) {
    const result = await this.call("script.evaluate", {
      expression: `JSON.stringify(${expression})`,
      target,
      awaitPromise: true,
      resultOwnership: "none"
    });
    if (result.type === "exception") {
      throw new Error(result.exceptionDetails?.text || "Firefox script evaluation failed");
    }
    assert.equal(result.result?.type, "string", JSON.stringify(result));
    return JSON.parse(result.result.value);
  }

  evaluateJSON(context, expression) {
    return this.evaluateJSONTarget({ context }, expression);
  }

  async close() {
    await this.call("session.end").catch(() => {});
    this.socket.close();
  }
}

async function waitForFirefoxBiDi(processHandle, port) {
  let stderr = "";
  processHandle.stderr.setEncoding("utf8");
  processHandle.stderr.on("data", (chunk) => { stderr += chunk; });
  processHandle.stdout.setEncoding("utf8");
  processHandle.stdout.on("data", (chunk) => { stderr += chunk; });
  return waitUntil(async () => {
    if (processHandle.exitCode != null) {
      throw new Error(`Firefox exited before BiDi was ready: ${stderr.trim()}`);
    }
    try {
      return await BiDiClient.connect(`ws://127.0.0.1:${port}/session`);
    } catch {
      return null;
    }
  }, `Firefox BiDi did not start: ${stderr.trim()}`);
}

async function firefoxInternalUUID(profilePath) {
  const preferencesPath = path.join(profilePath, "prefs.js");
  return waitUntil(async () => {
    const preferences = await fs.readFile(preferencesPath, "utf8").catch(() => "");
    const match = preferences.match(/user_pref\("extensions\.webextensions\.uuids", "((?:\\.|[^"\\])*)"\);/);
    if (!match) return null;
    const encodedJSON = JSON.parse(`"${match[1]}"`);
    return JSON.parse(encodedJSON)[FIREFOX_EXTENSION_ID] || null;
  }, "Firefox did not persist the temporary extension UUID");
}

async function runFirefoxTests() {
  const executablePath = firefoxExecutablePath();
  if (path.isAbsolute(executablePath)) await fs.access(executablePath);
  await fs.rm(FIREFOX_PROFILE_DIR, { recursive: true, force: true });
  await fs.mkdir(FIREFOX_PROFILE_DIR, { recursive: true });
  const port = await availablePort();
  const firefoxProcess = spawn(executablePath, [
    "--headless",
    "--no-remote",
    "--remote-allow-system-access",
    "--remote-debugging-port", String(port),
    "--profile", FIREFOX_PROFILE_DIR,
    "about:blank"
  ], { stdio: ["ignore", "pipe", "pipe"] });
  let client = null;
  let contextID = null;
  try {
    client = await waitForFirefoxBiDi(firefoxProcess, port);
    firefoxClientForFailure = client;
    const session = await client.call("session.new", {
      capabilities: { alwaysMatch: { acceptInsecureCerts: true } }
    });
    assert.equal(session.capabilities.browserName, "firefox");
    const installation = await client.call("webExtension.install", {
      extensionData: { type: "path", path: FIREFOX_EXTENSION_DIR }
    });
    assert.equal(installation.extension, FIREFOX_EXTENSION_ID);
    const extensionUUID = await firefoxInternalUUID(FIREFOX_PROFILE_DIR);
    const created = await client.call("browsingContext.create", { type: "tab" });
    contextID = created.context;
    firefoxContextForFailure = contextID;
    await client.call("browsingContext.setViewport", {
      context: contextID,
      viewport: { width: 320, height: 720 },
      devicePixelRatio: 1
    });
    await client.call("browsingContext.navigate", {
      context: contextID,
      url: `moz-extension://${extensionUUID}/popup.html`,
      wait: "complete"
    });
    await delay(500);

    await test("Firefox 通过 BiDi 安装真实扩展并读取实际 API 差异", async () => {
      const capabilities = await client.evaluateJSON(contextID, `(() => ({
        manifestVersion: browser.runtime.getManifest().manifest_version,
        runtime: typeof browser.runtime.sendMessage === "function",
        tabs: typeof browser.tabs.query === "function",
        permissions: typeof browser.permissions.request === "function",
        scripting: typeof browser.scripting.executeScript === "function",
        pageCapture: typeof browser.pageCapture?.saveAsMHTML === "function",
        nativeMessaging: typeof browser.runtime.sendNativeMessage === "function",
        loopbackPermission: browser.runtime.getManifest().host_permissions
          ?.includes("http://127.0.0.1:17843/*") === true,
        action: typeof browser.action?.setBadgeText === "function",
        menus: typeof browser.menus?.create === "function",
        icons: browser.runtime.getManifest().icons,
        actionIcons: browser.runtime.getManifest().action?.default_icon,
        userAgent: navigator.userAgent
      }))()`);
      assert.equal(capabilities.manifestVersion, 3);
      assert.equal(capabilities.runtime, true);
      assert.equal(capabilities.tabs, true);
      assert.equal(capabilities.permissions, true);
      assert.equal(capabilities.scripting, true);
      assert.equal(capabilities.pageCapture, false);
      assert.equal(capabilities.nativeMessaging, false);
      assert.equal(capabilities.loopbackPermission, true);
      assert.equal(capabilities.action, true);
      assert.equal(capabilities.menus, true);
      for (const size of ["16", "32", "48", "128"]) {
        assert.match(capabilities.icons[size], new RegExp(`/icons/icon${size}\\.png$`));
      }
      for (const size of ["16", "32"]) {
        assert.match(capabilities.actionIcons[size], new RegExp(`/icons/icon${size}\\.png$`));
      }
      assert.match(capabilities.userAgent, /Firefox\//);
    });

    await client.call("browsingContext.setViewport", {
      context: contextID,
      viewport: { width: 800, height: 720 },
      devicePixelRatio: 1
    });
    await test("Firefox 工具栏弹窗具有非循环的首选内容宽度", async () => {
      const sizing = await client.evaluateJSON(contextID, `(() => ({
        viewportWidth: innerWidth,
        bodyWidth: document.body.getBoundingClientRect().width,
        bodyCSSWidth: getComputedStyle(document.body).width,
        horizontalOverflow: document.documentElement.scrollWidth > innerWidth
      }))()`);
      assert.equal(sizing.viewportWidth, 800, JSON.stringify(sizing));
      assert.equal(sizing.bodyWidth, 420, JSON.stringify(sizing));
      assert.equal(sizing.bodyCSSWidth, "420px", JSON.stringify(sizing));
      assert.equal(sizing.horizontalOverflow, false, JSON.stringify(sizing));
    });
    await client.call("browsingContext.setViewport", {
      context: contextID,
      viewport: { width: 320, height: 720 },
      devicePixelRatio: 1
    });

    await test("Firefox 320px 宽度无横向裁切并切换为单列", async () => {
      const layout = await client.evaluateJSON(contextID, `(() => {
        const savePanel = document.querySelector("#save-panel");
        const organizationPanel = document.querySelector("#organization-panel");
        const wasSavePanelHidden = savePanel.hidden;
        const wasOrganizationPanelHidden = organizationPanel.hidden;
        const wasOrganizationPanelOpen = organizationPanel.open;
        savePanel.hidden = false;
        organizationPanel.hidden = false;
        organizationPanel.open = true;
        const interactive = Array.from(document.querySelectorAll("button, input, select, textarea"))
          .filter((element) => {
            const style = getComputedStyle(element);
            const rectangle = element.getBoundingClientRect();
            return style.display !== "none" && style.visibility !== "hidden"
              && rectangle.width > 0 && rectangle.height > 0;
          })
          .map((element) => {
            const rectangle = element.getBoundingClientRect();
            return { id: element.id, left: rectangle.left, right: rectangle.right };
          });
        const modeCards = Array.from(document.querySelectorAll(".mode-card"));
        const captureColumns = modeCards.length > 1
          && Math.abs(modeCards[0].getBoundingClientRect().top
            - modeCards[1].getBoundingClientRect().top) < 1
          ? 2
          : 1;
        const result = {
          viewportWidth: innerWidth,
          bodyWidth: document.body.getBoundingClientRect().width,
          documentScrollWidth: document.documentElement.scrollWidth,
          bodyScrollWidth: document.body.scrollWidth,
          captureColumns,
          overflowing: interactive.filter((element) =>
            element.left < -0.5 || element.right > innerWidth + 0.5
          )
        };
        savePanel.hidden = wasSavePanelHidden;
        organizationPanel.hidden = wasOrganizationPanelHidden;
        organizationPanel.open = wasOrganizationPanelOpen;
        return result;
      })()`);
      assert.equal(layout.viewportWidth, 320);
      assert.equal(layout.bodyWidth, 320, JSON.stringify(layout));
      assert.ok(layout.documentScrollWidth <= 320, JSON.stringify(layout));
      assert.ok(layout.bodyScrollWidth <= 320, JSON.stringify(layout));
      assert.equal(layout.captureColumns, 1, JSON.stringify(layout));
      assert.deepEqual(layout.overflowing, []);
    });

    await test("Firefox 弹窗加载英文语义化表单和固定播报区", async () => {
      const semantics = await client.evaluateJSON(contextID, `(() => ({
        lang: document.documentElement.lang,
        connectionTag: document.querySelector("#connection-form")?.tagName,
        connectType: document.querySelector("#connect")?.type,
        markHidden: document.querySelector(".mark")?.getAttribute("aria-hidden"),
        searchLabel: document.querySelector('label[for="folder-search"]')?.textContent,
        statusRole: document.querySelector("#status")?.getAttribute("role"),
        alertRole: document.querySelector("#alert")?.getAttribute("role"),
        sessionAfterQueue: Boolean(
          document.querySelector("#queue-panel")?.compareDocumentPosition(
            document.querySelector("#session-panel")
          ) & Node.DOCUMENT_POSITION_FOLLOWING
        )
      }))()`);
      assert.equal(semantics.connectionTag, "FORM", JSON.stringify(semantics));
      assert.equal(semantics.connectType, "submit", JSON.stringify(semantics));
      assert.equal(semantics.markHidden, "true", JSON.stringify(semantics));
      assert.match(semantics.lang, /^en/i, JSON.stringify(semantics));
      assert.equal(semantics.searchLabel, "Search categories", JSON.stringify(semantics));
      assert.equal(semantics.statusRole, "status", JSON.stringify(semantics));
      assert.equal(semantics.alertRole, "alert", JSON.stringify(semantics));
      assert.equal(semantics.sessionAfterQueue, true, JSON.stringify(semantics));
    });

    await test("Firefox 键盘 Tab 产生真实可见焦点环", async () => {
      await client.call("script.evaluate", {
        expression: "document.activeElement?.blur()",
        target: { context: contextID },
        awaitPromise: false,
        resultOwnership: "none"
      });
      await client.call("input.performActions", {
        context: contextID,
        actions: [{
          type: "key",
          id: "keyboard",
          actions: [
            { type: "keyDown", value: "\uE004" },
            { type: "keyUp", value: "\uE004" }
          ]
        }]
      });
      await client.call("input.releaseActions", { context: contextID });
      const focus = await client.evaluateJSON(contextID, `(() => {
        const element = document.activeElement;
        const style = getComputedStyle(element);
        return {
          id: element?.id || "",
          outlineStyle: style.outlineStyle,
          outlineWidth: Number.parseFloat(style.outlineWidth),
          outlineColor: style.outlineColor
        };
      })()`);
      assert.equal(focus.id, "token", JSON.stringify(focus));
      assert.notEqual(focus.outlineStyle, "none", JSON.stringify(focus));
      assert.ok(focus.outlineWidth >= 2, JSON.stringify(focus));
      assert.notEqual(focus.outlineColor, "rgba(0, 0, 0, 0)", JSON.stringify(focus));
    });
  } finally {
    if (client && contextID) {
      const screenshot = await client.call("browsingContext.captureScreenshot", {
        context: contextID,
        origin: "viewport"
      }).catch(() => null);
      if (screenshot?.data) {
        await fs.writeFile(
          path.join(ARTIFACT_DIR, "firefox-final.png"),
          Buffer.from(screenshot.data, "base64")
        ).catch(() => {});
      }
    }
    if (client) await client.close();
    if (firefoxProcess.exitCode == null) firefoxProcess.kill("SIGTERM");
    await new Promise((resolve) => {
      if (firefoxProcess.exitCode != null) resolve();
      else firefoxProcess.once("exit", resolve);
      setTimeout(resolve, 3_000);
    });
    firefoxClientForFailure = null;
    firefoxContextForFailure = null;
  }
}

let fixture = null;
try {
  fixture = await startFixtureServer();
  if (["all", "chromium"].includes(requestedBrowser)) {
    await runChromiumTests(fixture);
    await runChromiumEnglishLocalizationTest();
  }
  if (["all", "firefox"].includes(requestedBrowser)) await runFirefoxTests();
  await fs.writeFile(
    path.join(ARTIFACT_DIR, "results.json"),
    `${JSON.stringify({ generatedAt: new Date().toISOString(), tests: testResults }, null, 2)}\n`
  );
  console.log(`Browser extension real-browser E2E: ${testResults.length} checks passed`);
} catch (error) {
  if (chromiumPageForFailure && !chromiumPageForFailure.isClosed()) {
    await chromiumPageForFailure.screenshot({
      path: path.join(ARTIFACT_DIR, "failure-chromium.png"),
      fullPage: true
    }).catch(() => {});
  }
  if (firefoxClientForFailure && firefoxContextForFailure) {
    const screenshot = await firefoxClientForFailure.call("browsingContext.captureScreenshot", {
      context: firefoxContextForFailure,
      origin: "viewport"
    }).catch(() => null);
    if (screenshot?.data) {
      await fs.writeFile(
        path.join(ARTIFACT_DIR, "failure-firefox.png"),
        Buffer.from(screenshot.data, "base64")
      ).catch(() => {});
    }
  }
  await fs.writeFile(
    path.join(ARTIFACT_DIR, "results.json"),
    `${JSON.stringify({
      generatedAt: new Date().toISOString(),
      tests: testResults,
      error: error?.stack || String(error)
    }, null, 2)}\n`
  ).catch(() => {});
  console.error(error?.stack || String(error));
  process.exitCode = 1;
} finally {
  if (fixture) await fixture.close().catch(() => {});
}
