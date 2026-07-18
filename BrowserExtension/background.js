const BRIDGE_URL = "http://127.0.0.1:47831";
const MAX_ARCHIVE_BYTES = 24 * 1024 * 1024;
const MAX_HTML_BYTES = 6 * 1024 * 1024;
const MAX_TEXT_BYTES = 5 * 1024 * 1024;
const extensionAPI = globalThis.browser ?? globalThis.chrome;

extensionAPI.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "capture-and-save") {
    return false;
  }
  captureAndSave(message)
    .then((result) => sendResponse({ ok: true, result }))
    .catch((error) => sendResponse({ ok: false, error: readableError(error) }));
  return true;
});

async function captureAndSave(message) {
  if (!message.token || !Number.isInteger(message.tabId)) {
    throw new Error("连接信息不完整，请重新打开插件。");
  }

  const injection = await extensionAPI.scripting.executeScript({
    target: { tabId: message.tabId },
    func: extractPage,
    args: [MAX_HTML_BYTES, MAX_TEXT_BYTES]
  });
  const page = injection?.[0]?.result;
  if (!page?.sourceURL || !page?.contentText) {
    throw new Error("没有从当前页面提取到可保存的正文。");
  }

  let archiveData = null;
  let archiveFormat = null;
  if (message.includeArchive && extensionAPI.pageCapture?.saveAsMHTML) {
    const archive = await saveAsMHTML(message.tabId).catch(() => null);
    if (archive && archive.size <= MAX_ARCHIVE_BYTES) {
      archiveData = await blobToBase64(archive);
      archiveFormat = "mhtml";
    }
  }

  const capture = {
    schemaVersion: 1,
    sourceURL: page.sourceURL,
    title: page.title,
    authors: page.authors,
    language: page.language,
    summary: page.summary || "",
    tags: page.tags,
    capturedAt: new Date().toISOString().replace(/\.\d{3}Z$/, "Z"),
    contentText: page.contentText,
    originalHTML: message.includeArchive && !archiveData ? page.originalHTML : null,
    archiveFormat,
    archiveData
  };

  const response = await fetch(BRIDGE_URL + "/v1/import", {
    method: "POST",
    headers: {
      Authorization: "Bearer " + message.token,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      capture,
      folderID: message.folderID || null,
      newFolderName: message.newFolderName || null
    }),
    cache: "no-store"
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || "资料库拒绝了页面（HTTP " + response.status + "）。");
  }
  return payload;
}

function extractPage(maxHTMLBytes, maxTextBytes) {
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
  const contentText = truncateUTF8(
    contentMarkdown || normalize(source?.innerText || document.body?.innerText || ""),
    maxTextBytes
  );

  const clone = document.documentElement.cloneNode(true);
  clone.querySelectorAll("script,noscript,template").forEach((node) => node.remove());
  clone.querySelectorAll("input[type='password']").forEach((input) => {
    input.removeAttribute("value");
    input.setAttribute("value", "");
  });
  const serialized = "<!doctype html>\n" + clone.outerHTML;

  const canonical = document.querySelector("link[rel='canonical']")?.href;
  const sourceURL = canonical && /^https?:/i.test(canonical) ? canonical : location.href;
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
    sourceURL,
    title: readMeta("meta[property='og:title']", "meta[name='twitter:title']")
      || document.title
      || new URL(sourceURL).hostname,
    authors,
    language: document.documentElement.lang || null,
    summary: readMeta(
      "meta[name='description']",
      "meta[property='og:description']",
      "meta[name='twitter:description']"
    ),
    tags,
    contentText,
    originalHTML: truncateUTF8(serialized, maxHTMLBytes)
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
