#!/usr/bin/env node

import assert from "node:assert/strict";
import crypto from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright-core";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(SCRIPT_DIR, "..");
const EXTENSION_DIR = path.join(ROOT_DIR, "BrowserExtension");
const OUTPUT_DIR = path.join(ROOT_DIR, "docs", "browser-extension-store-assets");
const SOURCE_DIR = path.join(OUTPUT_DIR, "source");
const BUILD_DIR = path.join(ROOT_DIR, ".build", "browser-extension-store-assets");
const ICON_PATH = path.join(EXTENSION_DIR, "icons", "icon128.png");
const MANIFEST_PATH = path.join(OUTPUT_DIR, "asset-manifest.json");
const executablePath = process.env.CHROMIUM_EXECUTABLE_PATH || chromium.executablePath();

const locales = {
  "zh-CN": {
    browserLocale: "zh-CN",
    pageTitle: "本地语义检索实践",
    author: "示例作者",
    tags: "资料库，语义检索，写作",
    folder: "产品研究",
    secondFolder: "待读",
    domain: "example.com",
    preview: "当问题与原文的措辞不同时，混合检索会同时结合全文匹配与本地语义向量，并将最相关的书籍章节返回给写作助手。",
    connected: "已连接本机资料库",
    expiry: "连接受本机令牌保护",
    captureTitle: "网页内容，一次确认，长期保存",
    captureSubtitle: "净化正文、完整网页、选中文字或仅链接",
    previewTitle: "保存前先预览，分类与 AI 权限都由你决定",
    previewSubtitle: "编辑标题、作者、标签和资料库分类",
    libraryTitle: "网页进入本地资料库，随时检索与引用",
    librarySubtitle: "回执显示分类、归档类型和索引状态",
    promoTitle: "网页 → 本地知识库",
    promoSubtitle: "预览 · 分类 · AI 权限",
    localFirst: "本地优先",
    library: "资料库",
    allSources: "所有资料",
    recent: "最近添加",
    favorites: "收藏分类",
    search: "搜索标题、全文和语义片段",
    reason: "语义命中",
    section: "第 3 节 · 混合召回",
    result: "语义检索能在不同措辞下找到相关章节。",
    saved: "已保存到长期参考"
  },
  "en-US": {
    browserLocale: "en-US",
    pageTitle: "Local semantic search in practice",
    author: "Example Author",
    tags: "knowledge library, semantic search, writing",
    folder: "Product research",
    secondFolder: "Read later",
    domain: "example.com",
    preview: "When a question uses different wording from the source, hybrid retrieval combines full-text matching with local semantic vectors and returns the most relevant book chapters to the writing assistant.",
    connected: "Connected to the local knowledge library",
    expiry: "Protected by a local pairing token",
    captureTitle: "Save web pages with one clear confirmation",
    captureSubtitle: "Clean articles, full pages, selected text, or links",
    previewTitle: "Preview first. You control organization and AI access.",
    previewSubtitle: "Edit the title, author, tags, and knowledge-library folder",
    libraryTitle: "Keep web research local, searchable, and ready to cite",
    librarySubtitle: "Receipts confirm the folder, archive type, and index status",
    promoTitle: "Web pages → local knowledge",
    promoSubtitle: "Preview · Organize · AI access",
    localFirst: "Local-first",
    library: "Knowledge Library",
    allSources: "All sources",
    recent: "Recently added",
    favorites: "Favorite folders",
    search: "Search titles, full text, and semantic passages",
    reason: "Semantic match",
    section: "Section 3 · Hybrid retrieval",
    result: "Semantic search finds the right chapter even when the wording changes.",
    saved: "Saved to long-term reference"
  }
};

await fs.access(executablePath);
await fs.access(ICON_PATH);
await fs.rm(BUILD_DIR, { recursive: true, force: true });
await fs.mkdir(BUILD_DIR, { recursive: true });
await fs.mkdir(OUTPUT_DIR, { recursive: true });

const iconDataURL = await fileDataURL(ICON_PATH);
const captures = {};

for (const [locale, copy] of Object.entries(locales)) {
  captures[locale] = await capturePopupStates(locale, copy);
}

const browser = await chromium.launch({ executablePath, headless: true });
try {
  for (const [locale, copy] of Object.entries(locales)) {
    const localeDir = path.join(OUTPUT_DIR, locale);
    await fs.mkdir(localeDir, { recursive: true });
    await fs.copyFile(ICON_PATH, path.join(localeDir, "store-icon-128.png"));

    const popupImages = {};
    for (const [state, capturePath] of Object.entries(captures[locale])) {
      popupImages[state] = await fileDataURL(capturePath);
    }

    await render(browser, path.join(localeDir, "screenshot-01-capture.png"), 1280, 800,
      screenshotPage({ copy, iconDataURL, popupDataURL: popupImages.capture, variant: "capture" }));
    await render(browser, path.join(localeDir, "screenshot-02-preview.png"), 1280, 800,
      screenshotPage({ copy, iconDataURL, popupDataURL: popupImages.preview, variant: "preview" }));
    await render(browser, path.join(localeDir, "screenshot-03-library.png"), 1280, 800,
      screenshotPage({ copy, iconDataURL, popupDataURL: popupImages.receipt, variant: "library" }));
    await render(browser, path.join(localeDir, "promo-small-440x280.png"), 440, 280,
      promoPage({ copy, iconDataURL, wide: false }));
    await render(browser, path.join(localeDir, "promo-marquee-1400x560.png"), 1400, 560,
      promoPage({ copy, iconDataURL, wide: true, popupDataURL: popupImages.receipt }));
    await render(browser, path.join(localeDir, "edge-logo-300x300.png"), 300, 300,
      edgeLogoPage({ iconDataURL }));
  }
} finally {
  await browser.close();
}

const assetManifest = await buildAssetManifest();
await fs.writeFile(MANIFEST_PATH, `${JSON.stringify(assetManifest, null, 2)}\n`, "utf8");
console.log(`Generated ${assetManifest.assets.length} verified assets in ${OUTPUT_DIR}`);

async function capturePopupStates(locale, copy) {
  const profileDir = path.join(BUILD_DIR, `profile-${locale}`);
  const sourceDir = path.join(SOURCE_DIR, locale);
  await fs.mkdir(sourceDir, { recursive: true });
  const context = await chromium.launchPersistentContext(profileDir, {
    executablePath,
    headless: true,
    locale: copy.browserLocale,
    viewport: { width: 420, height: 1100 },
    colorScheme: "light",
    args: [
      `--disable-extensions-except=${EXTENSION_DIR}`,
      `--load-extension=${EXTENSION_DIR}`,
      `--lang=${copy.browserLocale}`,
      "--no-first-run",
      "--no-default-browser-check"
    ]
  });

  try {
    const worker = context.serviceWorkers()[0] || await context.waitForEvent("serviceworker");
    const extensionID = new URL(worker.url()).host;
    await worker.evaluate(() => chrome.storage.local.clear());
    const page = await context.newPage();
    await page.goto(`chrome-extension://${extensionID}/popup.html`, { waitUntil: "domcontentloaded" });
    await page.locator("#queue-panel[aria-busy='false']").waitFor({ timeout: 15_000 });
    await page.waitForTimeout(150);

    const outputs = {};
    for (const state of ["capture", "preview", "receipt"]) {
      await configurePopup(page, state, copy, extensionID);
      const outputPath = path.join(sourceDir, `popup-${state}.png`);
      await page.locator("main").screenshot({ path: outputPath, animations: "disabled" });
      outputs[state] = outputPath;
    }
    await page.close();
    return outputs;
  } finally {
    await context.close();
  }
}

async function configurePopup(page, state, copy, extensionID) {
  await page.evaluate(({ state, copy, extensionID }) => {
    const byID = (id) => document.getElementById(id);
    const showOnly = (...ids) => {
      for (const id of [
        "connection-panel", "session-panel", "save-panel", "organization-panel",
        "batch-review-panel", "preview-panel", "receipt-panel", "duplicate-panel", "queue-panel"
      ]) byID(id).hidden = !ids.includes(id);
    };

    document.documentElement.style.colorScheme = "light";
    document.body.style.width = "420px";
    document.body.style.maxWidth = "420px";
    document.body.style.background = "#ffffff";
    document.querySelector("main").setAttribute("aria-busy", "false");
    byID("page-title").textContent = copy.pageTitle;
    byID("status").textContent = "";
    byID("alert").textContent = "";
    const mark = document.querySelector(".mark");
    mark.textContent = "";
    mark.style.background = `#eaf1ff url(chrome-extension://${extensionID}/icons/icon32.png) center / 28px 28px no-repeat`;
    byID("session-title").textContent = copy.connected;
    byID("token-expiry").textContent = copy.expiry;
    document.querySelector(".session-actions").hidden = true;

    const folderSelect = byID("folder");
    folderSelect.replaceChildren(
      new Option(copy.folder, "folder-product", true, true),
      new Option(copy.secondFolder, "folder-later")
    );
    byID("folder-search-result").textContent = copy.browserLocale.startsWith("zh")
      ? "共 2 个分类" : "2 folders";
    byID("remember-domain").checked = true;
    byID("remember-domain-label").textContent = copy.browserLocale.startsWith("zh")
      ? `记住 ${copy.domain} 的分类选择`
      : `Remember the folder for ${copy.domain}`;
    byID("favorite-folder").textContent = copy.browserLocale.startsWith("zh") ? "★ 已收藏" : "★ Favorite";
    byID("batch-save").hidden = true;
    byID("batch-hint").hidden = true;

    if (state === "capture") {
      showOnly("session-panel", "save-panel", "organization-panel");
      byID("prepare-preview").disabled = false;
    } else if (state === "preview") {
      showOnly("organization-panel", "preview-panel");
      for (const selector of [
        "label[for='folder-search']", "#folder-search", "#folder-search-result",
        "label[for='new-folder']", "#new-folder", "#folder-shortcuts"
      ]) {
        const element = document.querySelector(selector);
        if (element) element.hidden = true;
      }
      byID("capture-title").value = copy.pageTitle;
      byID("capture-authors").value = copy.author;
      byID("capture-tags").value = copy.tags;
      byID("capture-ai").checked = true;
      byID("preview-mode").textContent = copy.browserLocale.startsWith("zh")
        ? "净化正文 · 保存前可编辑" : "Cleaned article · Editable before saving";
      byID("preview-size").textContent = "18.6 KB";
      byID("preview-archive").textContent = copy.browserLocale.startsWith("zh")
        ? "仅正文" : "Text only";
      byID("capture-preview").value = copy.preview;
      byID("organization-suggestions").hidden = true;
    } else {
      showOnly("receipt-panel");
      byID("receipt-title").textContent = copy.pageTitle;
      byID("receipt-source").textContent = copy.domain;
      byID("receipt-saved-at").textContent = copy.browserLocale.startsWith("zh")
        ? "2026/07/19 10:30" : "7/19/26, 10:30 AM";
      byID("receipt-folder").textContent = copy.folder;
      byID("receipt-size").textContent = "18.6 KB";
      byID("receipt-archive").textContent = copy.browserLocale.startsWith("zh")
        ? "仅正文" : "Text only";
      byID("receipt-index").textContent = copy.browserLocale.startsWith("zh")
        ? "全文与语义索引已就绪" : "Full-text and semantic indexes ready";
      byID("receipt-ai").textContent = copy.browserLocale.startsWith("zh")
        ? "允许 AI 检索" : "Available to AI retrieval";
    }
  }, { state, copy, extensionID });
}

function screenshotPage({ copy, iconDataURL, popupDataURL, variant }) {
  const content = {
    capture: { title: copy.captureTitle, subtitle: copy.captureSubtitle },
    preview: { title: copy.previewTitle, subtitle: copy.previewSubtitle },
    library: { title: copy.libraryTitle, subtitle: copy.librarySubtitle }
  }[variant];
  const popupClass = variant === "preview" ? "popup popup-preview" : "popup";
  const leftContent = variant === "library"
    ? libraryWindow(copy, iconDataURL)
    : featureCard(copy, variant);
  return htmlDocument(`
    <main class="store-shot ${variant}">
      <div class="copy-block">
        <div class="brand"><img src="${iconDataURL}" alt=""><span>RepoPress</span><b>${escapeHTML(copy.localFirst)}</b></div>
        <h1>${escapeHTML(content.title)}</h1>
        <p>${escapeHTML(content.subtitle)}</p>
      </div>
      <div class="visual-stage">
        ${leftContent}
        <div class="${popupClass}"><img src="${popupDataURL}" alt=""></div>
      </div>
    </main>
  `, storeStyles());
}

function featureCard(copy, variant) {
  if (variant === "preview") {
    return `<div class="benefit-card">
      <div class="benefit-icon">✓</div>
      <h2>${escapeHTML(copy.pageTitle)}</h2>
      <div class="tag-row"><span>${escapeHTML(copy.folder)}</span><span>${escapeHTML(copy.reason)}</span></div>
      <ul>
        <li>${escapeHTML(copy.browserLocale.startsWith("zh") ? "标题、作者与标签可编辑" : "Edit title, author, and tags")}</li>
        <li>${escapeHTML(copy.browserLocale.startsWith("zh") ? "分类由你确认" : "Confirm the destination folder")}</li>
        <li>${escapeHTML(copy.browserLocale.startsWith("zh") ? "AI 检索权限逐篇设置" : "Set AI access for each item")}</li>
      </ul>
    </div>`;
  }
  return `<div class="flow-card">
    <div class="browser-bar"><i></i><i></i><i></i><span>${escapeHTML(copy.domain)}</span></div>
    <article>
      <small>${escapeHTML(copy.browserLocale.startsWith("zh") ? "研究笔记" : "RESEARCH NOTE")}</small>
      <h2>${escapeHTML(copy.pageTitle)}</h2>
      <p>${escapeHTML(copy.preview)}</p>
      <div class="selection-line"></div><div class="selection-line short"></div>
    </article>
    <div class="flow-arrow">→</div>
  </div>`;
}

function libraryWindow(copy, iconDataURL) {
  return `<div class="app-window">
    <div class="window-bar"><span class="dots">● ● ●</span><strong>${escapeHTML(copy.library)}</strong><span></span></div>
    <div class="app-body">
      <nav>
        <div class="app-brand"><img src="${iconDataURL}" alt=""><b>PSP</b></div>
        <span class="active">▣ ${escapeHTML(copy.allSources)}</span>
        <span>◷ ${escapeHTML(copy.recent)}</span>
        <span>★ ${escapeHTML(copy.favorites)}</span>
        <hr>
        <small>${escapeHTML(copy.browserLocale.startsWith("zh") ? "分类" : "FOLDERS")}</small>
        <span>□ ${escapeHTML(copy.folder)}</span>
        <span>□ ${escapeHTML(copy.secondFolder)}</span>
      </nav>
      <section class="library-content">
        <div class="search-box">🔎 ${escapeHTML(copy.search)}</div>
        <div class="result-card">
          <div><span class="reason">${escapeHTML(copy.reason)}</span><time>18.6 KB</time></div>
          <h2>${escapeHTML(copy.pageTitle)}</h2>
          <h3>${escapeHTML(copy.section)}</h3>
          <p>${escapeHTML(copy.result)}</p>
          <div class="match-line"><mark>${escapeHTML(copy.browserLocale.startsWith("zh") ? "语义检索" : "Semantic search")}</mark> ${escapeHTML(copy.browserLocale.startsWith("zh") ? "与全文检索组合召回相关内容。" : "combines with full-text search to retrieve relevant passages.")}</div>
        </div>
      </section>
    </div>
  </div>`;
}

function promoPage({ copy, iconDataURL, wide, popupDataURL = null }) {
  const popup = wide && popupDataURL
    ? `<div class="promo-popup"><img src="${popupDataURL}" alt=""></div>` : "";
  return htmlDocument(`
    <main class="promo ${wide ? "wide" : "small"}">
      <div class="promo-glow one"></div><div class="promo-glow two"></div>
      <div class="promo-copy">
        <div class="promo-brand"><img src="${iconDataURL}" alt=""><span>RepoPress</span></div>
        <h1>${escapeHTML(copy.promoTitle)}</h1>
        <p>${escapeHTML(copy.promoSubtitle)}</p>
        <b>${escapeHTML(copy.localFirst)}</b>
      </div>
      ${popup}
    </main>
  `, promoStyles());
}

function edgeLogoPage({ iconDataURL }) {
  return htmlDocument(`
    <main class="edge-logo">
      <div class="edge-glow"></div>
      <div class="icon-frame"><img src="${iconDataURL}" alt=""></div>
    </main>
  `, `
    *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden}
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    .edge-logo{position:relative;display:grid;width:300px;height:300px;place-items:center;overflow:hidden;background:linear-gradient(145deg,#f4f7f0 0%,#e8f6ef 52%,#e9f0fb 100%)}
    .edge-glow{position:absolute;inset:35px;border-radius:50%;background:rgba(37,99,217,.18);filter:blur(36px)}
    .icon-frame{position:relative;display:grid;width:190px;height:190px;place-items:center;border:1px solid rgba(255,255,255,.9);border-radius:46px;background:rgba(255,255,255,.74);box-shadow:0 24px 70px rgba(28,55,49,.18)}
    img{width:146px;height:146px;image-rendering:auto}
  `);
}

function storeStyles() {
  return `
    :root{color-scheme:light}*{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden}
    body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",sans-serif;color:#17362f;background:#f4f5ed}
    .store-shot{position:relative;width:1280px;height:800px;overflow:hidden;background:radial-gradient(circle at 82% 8%,rgba(185,224,210,.76),transparent 31%),linear-gradient(132deg,#faf7ed 0%,#f1f5ed 49%,#dfeee7 100%)}
    .store-shot:after{content:"";position:absolute;right:-140px;bottom:-190px;width:590px;height:590px;border-radius:50%;background:rgba(68,126,112,.08)}
    .copy-block{position:absolute;z-index:3;left:70px;top:48px;width:1020px}
    .brand{display:flex;align-items:center;gap:10px;color:#36544d;font-size:15px;font-weight:650;letter-spacing:.01em}
    .brand img{width:34px;height:34px;border-radius:8px}.brand b{margin-left:7px;padding:5px 10px;border:1px solid rgba(37,99,217,.18);border-radius:999px;color:#2458a8;background:rgba(255,255,255,.64);font-size:12px}
    h1{max-width:980px;margin:22px 0 8px;font-size:44px;line-height:1.12;letter-spacing:-.035em;color:#1b493c}
    .copy-block>p{margin:0;color:#557069;font-size:20px;line-height:1.45}
    .visual-stage{position:absolute;z-index:2;left:70px;right:70px;top:222px;bottom:42px}
    .popup{position:absolute;z-index:4;right:18px;bottom:0;width:310px;max-height:525px;overflow:hidden;border:1px solid rgba(44,67,61,.14);border-radius:20px;background:white;box-shadow:0 24px 65px rgba(40,67,58,.23)}
    .popup img{display:block;width:100%;height:auto}.popup-preview{width:300px;max-height:535px}.library .popup{width:360px}
    .flow-card,.benefit-card,.app-window{position:absolute;inset:0 260px 0 0;border:1px solid rgba(54,84,75,.14);border-radius:22px;background:rgba(255,255,255,.86);box-shadow:0 24px 60px rgba(45,72,63,.16);overflow:hidden}
    .browser-bar{display:flex;align-items:center;gap:7px;height:44px;padding:0 18px;border-bottom:1px solid #e3e8e5;background:#f9faf9}.browser-bar i{width:9px;height:9px;border-radius:50%;background:#d6ddd9}.browser-bar span{margin-left:16px;min-width:330px;padding:7px 14px;border-radius:9px;color:#70817b;background:#edf1ef;font-size:12px}
    .flow-card article{padding:48px 55px}.flow-card article small{color:#337464;font-weight:750;letter-spacing:.12em}.flow-card article h2{max-width:560px;margin:13px 0 15px;color:#203d35;font-size:30px}.flow-card article p{max-width:570px;color:#647a73;font-size:16px;line-height:1.65}.selection-line{width:78%;height:13px;margin-top:25px;border-radius:6px;background:linear-gradient(90deg,#dceee8,#edf4f1)}.selection-line.short{width:55%;margin-top:10px}.flow-arrow{position:absolute;right:28px;bottom:29px;display:grid;width:58px;height:58px;place-items:center;border-radius:50%;color:#fff;background:#2563d9;font-size:30px;box-shadow:0 12px 25px rgba(37,99,217,.24)}
    .benefit-card{padding:52px 80px 40px}.benefit-icon{display:grid;width:54px;height:54px;place-items:center;border-radius:16px;color:white;background:#2d7d68;font-size:27px;font-weight:800}.benefit-card h2{margin:21px 0 15px;color:#1f4037;font-size:29px}.tag-row{display:flex;gap:10px}.tag-row span,.reason{padding:6px 10px;border-radius:999px;color:#246050;background:#e1f1eb;font-size:12px;font-weight:700}.benefit-card ul{margin:25px 0 0;padding:0;list-style:none;color:#506861;font-size:16px;line-height:2.2}.benefit-card li:before{content:"✓";margin-right:10px;color:#2b806a;font-weight:800}
    .app-window{right:210px;background:white}.window-bar{display:grid;grid-template-columns:1fr 1fr 1fr;align-items:center;height:42px;padding:0 16px;border-bottom:1px solid #e3e8e5;color:#536c65;background:#f7f9f8;font-size:12px}.window-bar strong{text-align:center}.dots{color:#c2cbc7;letter-spacing:4px}.app-body{display:grid;grid-template-columns:190px 1fr;height:calc(100% - 42px)}.app-body nav{display:flex;flex-direction:column;gap:8px;padding:18px 13px;color:#567068;background:#eef3f0;font-size:13px}.app-body nav span{padding:8px 10px;border-radius:8px}.app-body nav .active{color:#174e40;background:#d6e9e2;font-weight:700}.app-body nav hr{width:100%;margin:5px 0;border:0;border-top:1px solid #d8e1dd}.app-body nav small{padding:0 10px;color:#789089;font-size:10px;letter-spacing:.09em}.app-brand{display:flex;align-items:center;gap:8px;margin:0 7px 8px;color:#264f44}.app-brand img{width:26px;height:26px;border-radius:7px}.library-content{padding:24px;background:#fbfcfb}.search-box{padding:12px 15px;border:1px solid #d8e2de;border-radius:10px;color:#7a8d87;background:white;font-size:12px}.result-card{margin-top:18px;padding:22px;border:1px solid #dce5e1;border-radius:14px;background:white;box-shadow:0 10px 28px rgba(35,66,57,.07)}.result-card>div:first-child{display:flex;justify-content:space-between}.result-card time{color:#8a9a95;font-size:11px}.result-card h2{margin:16px 0 9px;color:#21453a;font-size:24px}.result-card h3{margin:0;color:#527168;font-size:14px}.result-card p,.match-line{color:#637b74;font-size:13px;line-height:1.6}.match-line{margin-top:17px;padding:12px;border-radius:8px;background:#f3f7f5}.match-line mark{padding:2px 3px;color:#204e40;background:#cfeadd}
  `;
}

function promoStyles() {
  return `
    *{box-sizing:border-box}html,body{margin:0;width:100%;height:100%;overflow:hidden}body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC",sans-serif;color:#173d33}
    .promo{position:relative;width:100%;height:100%;overflow:hidden;background:linear-gradient(135deg,#fbf7ea 0%,#eef5ec 54%,#dceee7 100%)}.promo-glow{position:absolute;border-radius:50%;filter:blur(4px)}.promo-glow.one{right:-12%;top:-35%;width:55%;height:100%;background:rgba(92,166,143,.18)}.promo-glow.two{left:-12%;bottom:-55%;width:50%;height:90%;background:rgba(37,99,217,.09)}
    .promo-copy{position:relative;z-index:2}.promo-brand{display:flex;align-items:center;gap:9px;color:#3c5d54;font-weight:700}.promo-brand img{border-radius:9px}.promo h1{margin:0;color:#1b493c;letter-spacing:-.04em}.promo p{margin:0;color:#58736b}.promo-copy>b{display:inline-block;border:1px solid rgba(37,99,217,.19);border-radius:999px;color:#2359aa;background:rgba(255,255,255,.66)}
    .small .promo-copy{padding:32px 30px}.small .promo-brand{font-size:12px}.small .promo-brand img{width:30px;height:30px}.small h1{max-width:370px;margin-top:26px;font-size:31px;line-height:1.05}.small p{margin-top:10px;font-size:14px}.small .promo-copy>b{margin-top:17px;padding:5px 10px;font-size:10px}
    .wide .promo-copy{padding:76px 0 0 92px}.wide .promo-brand{font-size:17px}.wide .promo-brand img{width:42px;height:42px}.wide h1{max-width:760px;margin-top:42px;font-size:62px;line-height:1.04}.wide p{margin-top:18px;font-size:23px}.wide .promo-copy>b{margin-top:27px;padding:8px 14px;font-size:13px}.promo-popup{position:absolute;z-index:3;right:84px;top:44px;width:330px;max-height:480px;overflow:hidden;border:1px solid rgba(45,70,63,.15);border-radius:24px;background:white;box-shadow:0 28px 75px rgba(38,69,59,.23);transform:rotate(1.5deg)}.promo-popup img{display:block;width:100%;height:auto}
  `;
}

function htmlDocument(body, styles) {
  return `<!doctype html><html><head><meta charset="utf-8"><style>${styles}</style></head><body>${body}</body></html>`;
}

async function render(browser, outputPath, width, height, documentHTML) {
  const page = await browser.newPage({ viewport: { width, height }, colorScheme: "light", deviceScaleFactor: 1 });
  try {
    await page.setContent(documentHTML, { waitUntil: "load" });
    await page.evaluate(() => document.fonts.ready);
    await page.screenshot({ path: outputPath, animations: "disabled" });
  } finally {
    await page.close();
  }
  const dimensions = await pngDimensions(outputPath);
  assert.deepEqual(dimensions, { width, height }, `${path.basename(outputPath)} has wrong dimensions`);
}

async function fileDataURL(filePath) {
  const bytes = await fs.readFile(filePath);
  return `data:image/png;base64,${bytes.toString("base64")}`;
}

async function pngDimensions(filePath) {
  const bytes = await fs.readFile(filePath);
  assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a", `${filePath} is not PNG`);
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}

async function sha256(filePath) {
  return crypto.createHash("sha256").update(await fs.readFile(filePath)).digest("hex");
}

async function buildAssetManifest() {
  const assets = [];
  for (const locale of Object.keys(locales)) {
    const files = [
      ["store-icon-128.png", "store-icon", "existing extension icon"],
      ["edge-logo-300x300.png", "edge-logo", "existing extension icon in a deterministic presentation frame"],
      ["screenshot-01-capture.png", "store-screenshot", "real extension popup capture composed with synthetic example.com content"],
      ["screenshot-02-preview.png", "store-screenshot", "real extension preview UI composed with synthetic example.com content"],
      ["screenshot-03-library.png", "store-screenshot", "real extension receipt UI composed with a representative local-library view"],
      ["promo-small-440x280.png", "small-promo", "deterministic brand composition"],
      ["promo-marquee-1400x560.png", "marquee-promo", "deterministic brand composition with real extension receipt UI"]
    ];
    for (const [filename, kind, provenance] of files) {
      const filePath = path.join(OUTPUT_DIR, locale, filename);
      const dimensions = await pngDimensions(filePath);
      assets.push({
        locale,
        filename: `${locale}/${filename}`,
        kind,
        ...dimensions,
        sha256: await sha256(filePath),
        provenance
      });
    }
  }
  return {
    schemaVersion: 1,
    generationMode: "deterministic",
    generator: "script/generate_browser_extension_store_assets.mjs",
    extensionVersion: JSON.parse(await fs.readFile(path.join(EXTENSION_DIR, "manifest.json"), "utf8")).version,
    privacy: "All depicted page content is synthetic and uses example.com. No user library or browsing data is read.",
    assets
  };
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
