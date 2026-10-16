import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AiChatPlan, AiChatStreamSnapshot, AiConversation, AiProviderProfile, KnowledgeItemSummary, RepositoryGateway } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { AIChatPanel } from "./AIChatPanel";

vi.mock("./AiConnectionPanel", () => ({ AiConnectionPanel: () => null }));
Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });

const conversation: AiConversation = {
  conversationId: "conversation-1", title: "新对话", messageCount: 1, totalMessageBytes: 14,
  createdAtEpochSeconds: 1_700_000_000, updatedAtEpochSeconds: 1_700_000_000,
  sessionOnly: true, persistenceWarning: null,
  messages: [{ messageId: "message-1", role: "user", content: "设置 {count}", createdAtEpochSeconds: 1_700_000_000 }],
};
const material: KnowledgeItemSummary = {
  itemId: "material-1", title: "标题 {count}", sourceKind: "text", sourceName: "设置", sourceUrl: null,
  byteSize: 24, createdAtEpochSeconds: 1_700_000_000, updatedAtEpochSeconds: 1_700_000_000,
  readingProgressPercent: 0, allowsLocalSemanticIndex: false, allowsRemoteAiUse: true, archive: null, revisionNumber: 2,
};
const profile: AiProviderProfile = {
  profileId: "profile-1", name: "设置", provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1",
  model: "model-{count}", streaming: true, createdAtEpochSeconds: 1_700_000_000, updatedAtEpochSeconds: 1_700_000_000,
};
const futureEpochSeconds = 1_900_000_000;
const plan: AiChatPlan = {
  planId: "plan-1", conversationId: conversation.conversationId, conversationVersion: 1,
  provider: "ollama_local", endpoint: profile.endpoint, model: profile.model,
  historyMessageCount: 1, userMessageBytes: 15,
  knowledgeItems: [{ itemId: material.itemId, title: material.title, revisionNumber: 2, byteSize: 24, contentSha256: "a".repeat(64) }],
  knowledgeTotalBytes: 24, totalSendBytes: 39, expiresAtEpochSeconds: futureEpochSeconds,
  warnings: ["设置", "<b>{count}</b>"], streaming: true, sessionOnly: true,
};

type StubGateway = Record<string, ReturnType<typeof vi.fn>>;
let host: HTMLDivElement;
let root: Root;
let gateway: StubGateway;

function render(locale: "zh-CN" | "en-US") {
  const panel = createElement(AIChatPanel, { active: true, enabled: true, isDemo: false, gateway: gateway as unknown as RepositoryGateway });
  act(() => root.render(createElement(I18nProvider, { locale, children: panel })));
}
async function settle() { await act(async () => { await Promise.resolve(); await Promise.resolve(); }); }
function button(label: string) {
  const result = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label);
  if (!result) throw new Error(`Missing button: ${label}`);
  return result;
}
async function click(label: string) { await act(async () => button(label).click()); await settle(); }
function field(label: string) {
  const result = [...host.querySelectorAll("label")].find((item) => item.firstChild?.textContent === label)?.querySelector<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>("input,textarea,select");
  if (!result) throw new Error(`Missing field: ${label}`);
  return result;
}
async function setValue(node: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, value: string) {
  await act(async () => {
    const prototype = node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : node instanceof HTMLSelectElement ? HTMLSelectElement.prototype : HTMLInputElement.prototype;
    Object.getOwnPropertyDescriptor(prototype, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event(node instanceof HTMLSelectElement ? "change" : "input", { bubbles: true }));
  });
}

beforeEach(() => {
  host = document.createElement("div"); document.body.append(host); root = createRoot(host);
  gateway = {
    listAiConversations: vi.fn(async () => [conversation]),
    listKnowledgeItems: vi.fn(async () => ({ items: [material], total: 1, truncated: false })),
    getAiChatVaultStatus: vi.fn(async () => ({ state: "unlocked", hasVault: true, persistentConversationCount: 0, summary: "设置", warning: "标题 {count}" })),
    listAiProviderProfiles: vi.fn(async () => [profile]),
    planAiChat: vi.fn(async () => plan),
    executeAiChat: vi.fn(), startAiChatStream: vi.fn(), pollAiChatStream: vi.fn(), cancelAiChatStream: vi.fn(),
    createAiConversation: vi.fn(), deleteAiConversation: vi.fn(), aiCredentialStatus: vi.fn(), storeAiCredential: vi.fn(), deleteAiCredential: vi.fn(),
    saveAiProviderProfile: vi.fn(), deleteAiProviderProfile: vi.fn(), initializeAiChatVault: vi.fn(), unlockAiChatVault: vi.fn(), lockAiChatVault: vi.fn(), deleteAiChatVault: vi.fn(),
  };
});
afterEach(() => { act(() => root.unmount()); host.remove(); vi.restoreAllMocks(); vi.useRealTimers(); });

describe("AIChatPanel live localization", () => {
  it("keeps one pending initial read across zh/en/zh and renders backend and conversation data literally", async () => {
    let resolveConversations!: (items: AiConversation[]) => void;
    gateway.listAiConversations.mockImplementationOnce(() => new Promise((resolve) => { resolveConversations = resolve; }));
    render("zh-CN"); render("en-US"); render("zh-CN");
    expect(gateway.listAiConversations).toHaveBeenCalledTimes(1);
    expect(gateway.listKnowledgeItems).toHaveBeenCalledTimes(1);
    expect(gateway.getAiChatVaultStatus).toHaveBeenCalledTimes(1);
    expect(gateway.listAiProviderProfiles).toHaveBeenCalledTimes(1);
    await act(async () => resolveConversations([conversation])); await settle();
    expect(host.textContent).toContain("新对话（本次）");
    expect(host.textContent).toContain("设置 {count}");
    expect(host.textContent).toContain("标题 {count}");
    render("en-US");
    expect(host.querySelector(".ai-chat-panel")?.getAttribute("aria-label")).toBe("AI chat");
    expect(host.textContent).toContain("新对话 (this run)");
    expect(host.textContent).toContain("设置 {count}");
    expect(host.textContent).toContain("标题 {count}");
    expect(host.textContent).not.toContain("Settings");
    expect(gateway.listAiConversations).toHaveBeenCalledTimes(1);
  });

  it("rerenders local errors while keeping sanitized backend text literal", async () => {
    gateway.listAiConversations.mockRejectedValueOnce(new Error("设置 {count} /tmp/private-token\nline"));
    render("en-US"); await settle();
    const status = host.querySelector('[role="status"]')?.textContent ?? "";
    expect(status).toContain("Unable to load AI chats:");
    expect(status).toContain("设置 {count}"); expect(status).toContain("[本地文件] line");
    expect(status).not.toContain("Settings"); expect(status).not.toContain("private-token");
    render("zh-CN");
    expect(host.querySelector('[role="status"]')?.textContent).toContain("无法加载 AI 对话：设置 {count} [本地文件] line");
    expect(gateway.listAiConversations).toHaveBeenCalledTimes(1);
  });

  it("translates confirmations at click time without changing cancellation behavior", async () => {
    const confirm = vi.spyOn(window, "confirm").mockReturnValue(false);
    render("en-US"); await settle();
    await click("Delete conversation");
    expect(confirm).toHaveBeenLastCalledWith("Delete this conversation? Its encrypted saved history will also be removed.");
    render("zh-CN"); await click("删除对话");
    expect(confirm).toHaveBeenLastCalledWith("删除此对话？已加密保存的历史也会一并移除。");
    expect(gateway.deleteAiConversation).not.toHaveBeenCalled();
  });

  it("preserves form state, selected material, profile, and a pending frozen plan without extra calls", async () => {
    let resolvePlan!: (value: AiChatPlan) => void;
    gateway.planAiChat.mockImplementationOnce(() => new Promise((resolve) => { resolvePlan = resolve; }));
    render("zh-CN"); await settle();
    const profileSelect = field("已存档案") as HTMLSelectElement;
    const message = field("消息") as HTMLTextAreaElement;
    await setValue(profileSelect, profile.profileId);
    await act(async () => host.querySelector<HTMLInputElement>(".ai-chat-materials input")!.click());
    await setValue(message, "用户 {count} 设置");
    await click("生成发送计划");
    expect(gateway.planAiChat).toHaveBeenCalledTimes(1);
    expect(gateway.planAiChat).toHaveBeenCalledWith(expect.objectContaining({ message: "用户 {count} 设置", knowledgeItemIds: [material.itemId], model: profile.model }));
    render("en-US");
    expect(profileSelect.value).toBe(profile.profileId); expect(message.value).toBe("用户 {count} 设置");
    expect(host.querySelector<HTMLInputElement>(".ai-chat-materials input")!.checked).toBe(true);
    expect(gateway.planAiChat).toHaveBeenCalledTimes(1);
    await act(async () => resolvePlan(plan)); await settle();
    expect(host.textContent).toContain("Confirm send");
    expect(host.textContent).toContain("标题 {count}");
    expect(host.textContent).toContain("设置");
    expect(host.textContent).toContain("<b>{count}</b>");
    expect(host.querySelector(".operation-plan b")).toBeNull();
    expect(host.textContent).toContain(new Date(futureEpochSeconds * 1_000).toLocaleTimeString("en-US"));
    render("zh-CN");
    expect(host.textContent).toContain(new Date(futureEpochSeconds * 1_000).toLocaleTimeString("zh-CN"));
    expect(gateway.planAiChat).toHaveBeenCalledTimes(1);
    expect(gateway.executeAiChat).not.toHaveBeenCalled(); expect(gateway.startAiChatStream).not.toHaveBeenCalled();
  });

  it("does not restart a pending stream on locale changes and keeps streamed content literal", async () => {
    let resolveStream!: (value: AiChatStreamSnapshot) => void;
    gateway.startAiChatStream.mockImplementationOnce(() => new Promise((resolve) => { resolveStream = resolve; }));
    render("zh-CN"); await settle();
    await setValue(field("已存档案"), profile.profileId);
    await setValue(field("消息"), "用户流消息");
    await click("生成发送计划");
    await click("确认并发送");
    expect(gateway.startAiChatStream).toHaveBeenCalledTimes(1);
    render("en-US"); render("zh-CN");
    expect(gateway.startAiChatStream).toHaveBeenCalledTimes(1);
    const completed: AiChatStreamSnapshot = {
      operationId: "operation-1", conversationId: conversation.conversationId, state: "completed", cursor: 1,
      delta: "设置 {count}", accumulatedBytes: 14,
      conversation: { ...conversation, messages: [...conversation.messages, { messageId: "message-2", role: "assistant", content: "设置 {count}", createdAtEpochSeconds: 1_700_000_001 }] },
      errorCode: null, errorMessage: null, persistenceWarning: null,
    };
    await act(async () => resolveStream(completed)); await settle();
    render("en-US");
    expect(host.textContent).toContain("设置 {count}");
    expect(host.textContent).not.toContain("Settings");
    expect(host.textContent).toContain("AI response received. The conversation is retained only for this run.");
    expect(gateway.startAiChatStream).toHaveBeenCalledTimes(1);
    expect(gateway.pollAiChatStream).not.toHaveBeenCalled();
  });

  it("keeps an expired plan disabled and does not revive an invalidated plan after locale changes", async () => {
    gateway.planAiChat.mockResolvedValueOnce({ ...plan, expiresAtEpochSeconds: 1 });
    render("zh-CN"); await settle();
    await setValue(field("已存档案"), profile.profileId);
    await setValue(field("消息"), "过期计划");
    await click("生成发送计划");
    expect(button("确认并发送").disabled).toBe(true);
    render("en-US"); expect(button("Confirm and send").disabled).toBe(true);
    await setValue(field("Message"), "已改变");
    expect(host.textContent).not.toContain("Confirm send");
    render("zh-CN"); render("en-US");
    expect(host.textContent).not.toContain("Confirm send");
    expect(gateway.planAiChat).toHaveBeenCalledTimes(1);
    expect(gateway.executeAiChat).not.toHaveBeenCalled(); expect(gateway.startAiChatStream).not.toHaveBeenCalled();
  });

  it("executes a one-use non-streaming plan once while locale changes during the pending execution", async () => {
    let resolveExecution!: (value: unknown) => void;
    gateway.planAiChat.mockResolvedValueOnce({ ...plan, streaming: false });
    gateway.executeAiChat.mockImplementationOnce(() => new Promise((resolve) => { resolveExecution = resolve; }));
    render("zh-CN"); await settle();
    await setValue(field("已存档案"), profile.profileId);
    await setValue(field("消息"), "单次发送");
    await act(async () => host.querySelector<HTMLInputElement>(".ai-chat-mode input")!.click());
    await click("生成发送计划");
    await act(async () => button("确认并发送").click());
    expect(gateway.executeAiChat).toHaveBeenCalledTimes(1);
    render("en-US"); expect(button("Confirm and send").disabled).toBe(true);
    await act(async () => button("Confirm and send").click());
    expect(gateway.executeAiChat).toHaveBeenCalledTimes(1);
    const assistantMessage = { messageId: "message-3", role: "assistant" as const, content: "raw {count}", createdAtEpochSeconds: 1_700_000_002 };
    await act(async () => resolveExecution({ assistantMessage, conversation: { ...conversation, messages: [...conversation.messages, assistantMessage] }, persistenceWarning: null })); await settle();
    expect(host.textContent).not.toContain("Confirm send");
    expect(host.textContent).toContain("raw {count}");
    render("zh-CN"); expect(host.textContent).toContain("raw {count}");
    expect(gateway.executeAiChat).toHaveBeenCalledTimes(1);
  });
});
