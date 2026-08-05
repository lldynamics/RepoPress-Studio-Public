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
        const validationMode = response?.result?.validationMode;
        const hasEffectivePeerGuard = validationMode === "literal"
          || response?.result?.peerGuarded === true;
        if (!response?.ok
            || !response.result?.allowed
            || approvedURL !== url
            || !hasEffectivePeerGuard) {
          throw new Error(response?.error || "archive resource rejected");
        }
        return {
          url: approvedURL,
          validationMode,
          peerGuardID: response.result?.peerGuardID || null
        };
      } finally {
        clearTimeout(timeout);
      }
    };
    const confirmResourcePeerWithExtension = async (approval) => {
      if (approval.validationMode === "literal") return;
      let timeout;
      try {
        const response = await Promise.race([
          extensionRuntime.sendMessage({
            type: "confirm-archive-resource-peer",
            url: approval.url,
            guardID: approval.peerGuardID
          }),
          new Promise((_, reject) => {
            timeout = setTimeout(
              () => reject(new Error("archive peer confirmation timed out")),
              responseTimeout()
            );
          })
        ]);
        if (!response?.ok || response.result?.verified !== true) {
          throw new Error(response?.error || "archive peer was not verified");
        }
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
        const approval = await validateResourceURLWithExtension(url);
        url = approval.url;
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
          await confirmResourcePeerWithExtension(approval);
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
        } catch (error) {
          controller.abort();
          throw error;
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


globalThis.KNOWLEDGE_BACKGROUND_MODULES_LOADED = true;
