const BRIDGE_URL = "http://127.0.0.1:47831";
const extensionAPI = globalThis.browser ?? globalThis.chrome;

const tokenInput = document.querySelector("#token");
const connectButton = document.querySelector("#connect");
const connectionPanel = document.querySelector("#connection-panel");
const savePanel = document.querySelector("#save-panel");
const folderSelect = document.querySelector("#folder");
const newFolderInput = document.querySelector("#new-folder");
const includeArchiveInput = document.querySelector("#include-archive");
const archiveLabel = document.querySelector("#archive-label");
const archiveHint = document.querySelector("#archive-hint");
const saveButton = document.querySelector("#save");
const statusLabel = document.querySelector("#status");
const pageTitle = document.querySelector("#page-title");

let activeTab = null;

document.addEventListener("DOMContentLoaded", async () => {
  const supportsMHTML = Boolean(extensionAPI.pageCapture?.saveAsMHTML);
  archiveLabel.textContent = supportsMHTML
    ? "保存完整 MHTML 页面归档"
    : "保存网页 HTML 归档";
  archiveHint.textContent = supportsMHTML
    ? "MHTML 会把页面资源保存为单个本机文件。"
    : "Firefox 不提供 MHTML 接口，将保存正文和清理后的原始 HTML。";
  [activeTab] = await extensionAPI.tabs.query({ active: true, currentWindow: true });
  pageTitle.textContent = activeTab?.title || "当前页面";
  const stored = await extensionAPI.storage.local.get(["bridgeToken"]);
  if (stored.bridgeToken) {
    tokenInput.value = stored.bridgeToken;
    await connect();
  }
});

connectButton.addEventListener("click", connect);
saveButton.addEventListener("click", saveCurrentPage);
newFolderInput.addEventListener("input", () => {
  folderSelect.disabled = newFolderInput.value.trim().length > 0;
});

async function connect() {
  const token = tokenInput.value.trim();
  if (!token) {
    showStatus("请先粘贴应用连接令牌。", "error");
    return;
  }
  setBusy(connectButton, true, "连接中…");
  try {
    const response = await bridgeFetch("/v1/folders", token);
    folderSelect.replaceChildren(new Option("未分类", ""));
    for (const folder of response.folders || []) {
      folderSelect.add(new Option(folder.name, folder.id));
    }
    await extensionAPI.storage.local.set({ bridgeToken: token });
    connectionPanel.hidden = true;
    savePanel.hidden = false;
    showStatus("已连接到本机资料库。");
  } catch (error) {
    connectionPanel.hidden = false;
    savePanel.hidden = true;
    showStatus(readableError(error), "error");
  } finally {
    setBusy(connectButton, false, "连接");
  }
}

async function saveCurrentPage() {
  if (!activeTab?.id || !/^https?:/i.test(activeTab.url || "")) {
    showStatus("只能保存 HTTP 或 HTTPS 网页。", "error");
    return;
  }
  setBusy(saveButton, true, "正在采集并保存…");
  showStatus("正在提取正文和页面归档…");
  try {
    const token = tokenInput.value.trim();
    const response = await extensionAPI.runtime.sendMessage({
      type: "capture-and-save",
      tabId: activeTab.id,
      token,
      folderID: newFolderInput.value.trim() ? null : (folderSelect.value || null),
      newFolderName: newFolderInput.value.trim() || null,
      includeArchive: includeArchiveInput.checked
    });
    if (!response?.ok) {
      throw new Error(response?.error || "保存失败。");
    }
    const result = response.result;
    const action = result.insertedCount > 0
      ? "新增"
      : result.updatedCount > 0
        ? "更新"
        : "已存在";
    showStatus(`${action}完成，页面已进入资料库。`, "success");
  } catch (error) {
    showStatus(readableError(error), "error");
  } finally {
    setBusy(saveButton, false, "保存当前页面");
  }
}

async function bridgeFetch(path, token) {
  const response = await fetch(`${BRIDGE_URL}${path}`, {
    headers: { Authorization: `Bearer ${token}` },
    cache: "no-store"
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `连接失败（HTTP ${response.status}）`);
  }
  return payload;
}

function setBusy(button, busy, label) {
  button.disabled = busy;
  button.textContent = label;
}

function showStatus(message, kind = "") {
  statusLabel.textContent = message;
  statusLabel.className = kind;
}

function readableError(error) {
  if (String(error?.message || error).includes("Failed to fetch")) {
    return "无法连接应用。请先打开“个人网站发布控制台”，再检查令牌。";
  }
  return error?.message || String(error);
}
