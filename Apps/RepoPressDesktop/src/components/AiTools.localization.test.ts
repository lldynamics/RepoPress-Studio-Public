import { act, createElement, type ReactElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { AiConnectionPlan, AiConnectionResult } from "../contracts/aiConnection";
import type { AiCredentialStatusSnapshot, AiEditPlan, AiEditResponse, CapabilitySnapshot, RepositoryGateway } from "../contracts/repository";
import { I18nProvider } from "../i18n/i18n";
import { AIAssistant } from "./AIAssistant";
import { AiConnectionPanel } from "./AiConnectionPanel";
import { AdvancedTools } from "./AdvancedTools";

Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
let host: HTMLDivElement;
let root: Root;
beforeEach(() => { host = document.createElement("div"); document.body.append(host); root = createRoot(host); });
afterEach(() => { act(() => root.unmount()); host.remove(); vi.useRealTimers(); vi.restoreAllMocks(); });
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}
async function render(locale: "zh-CN" | "en-US", view: ReactElement) {
  await act(async () => { root.render(createElement(I18nProvider, { locale, children: view })); });
}
function button(label: string) {
  const node = [...host.querySelectorAll<HTMLButtonElement>("button")].find((item) => item.textContent === label);
  if (!node) throw new Error(`Missing button: ${label}`);
  return node;
}
function field(label: string) {
  const node = [...host.querySelectorAll("label")].find((item) => item.textContent?.startsWith(label))?.querySelector("input,textarea,select");
  if (!node) throw new Error(`Missing field: ${label}`);
  return node as HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement;
}
async function input(node: HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement, value: string) {
  const proto = node instanceof HTMLSelectElement ? HTMLSelectElement.prototype : node instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  await act(async () => {
    Object.getOwnPropertyDescriptor(proto, "value")!.set!.call(node, value);
    node.dispatchEvent(new Event(node instanceof HTMLSelectElement ? "change" : "input", { bubbles: true }));
  });
}
async function click(label: string) { await act(async () => button(label).click()); }

const selection = { from: 4, to: 8, text: "设置{count}" };
const editPlan: AiEditPlan = {
  planId: "原计划", provider: "ollama_local", endpoint: "http://127.0.0.1:11434/v1", model: "模型{count}",
  selectionBytes: 13, instructionBytes: 9, expiresAt: "2099-01-01T01:02:03.000Z", summary: "智能工具", warnings: ["设置", "<b>{count}</b>"],
};
const config = { provider: "openai_compatible" as const, endpoint: "https://example.test/v1", model: "模型{count}" };
function connectionPlan(expiresAt = Date.now() + 60_000): AiConnectionPlan {
  return { planId: "冻结连接", operation: "models", provider: config.provider, endpoint: config.endpoint, requestUrl: `${config.endpoint}/models`, model: null, expiresAt, requestSummary: "设置" };
}
function connectionResult(): AiConnectionResult {
  return { planId: "冻结连接", operation: "models", provider: config.provider, endpoint: config.endpoint, model: null, models: ["设置", "模型{count}", "model-3"], checkedAt: Date.now(), status: "models_available", warnings: ["remote_service", "SECRET_RAW_WARNING"], elapsedMs: 8 };
}

describe("AI editing and connection localization", () => {
  it("retains instruction, pending plan, proposals and accepted IDs while keeping all payload text literal", async () => {
    const planning = deferred<AiEditPlan>();
    const executing = deferred<AiEditResponse>();
    const applyAiEdits = vi.fn(async () => ({ text: "新正文{count}", appliedProposalIds: [7] }));
    const gateway = { planAiEdit: vi.fn(() => planning.promise), executeAiEdit: vi.fn(() => executing.promise), applyAiEdits };
    const onApplyReplacement = vi.fn(() => true);
    const view = () => createElement(AIAssistant, { active: true, enabled: true, isDemo: false, sessionId: "session", documentId: "doc", documentRevision: 4, selection, gateway: gateway as unknown as RepositoryGateway, onApplyReplacement });
    await render("zh-CN", view());
    await input(field("模型"), editPlan.model);
    await input(field("编辑指令"), "原指令{count}<b>");
    const instruction = field("编辑指令");
    await click("生成发送计划");
    await render("en-US", view());
    expect(field("Editing instruction")).toBe(instruction);
    expect(instruction.value).toBe("原指令{count}<b>");
    expect(gateway.planAiEdit).toHaveBeenCalledTimes(1);
    expect(gateway.planAiEdit).toHaveBeenCalledWith(expect.objectContaining({ instruction: instruction.value, sourceText: selection.text, model: editPlan.model }));
    await act(async () => planning.resolve(editPlan));
    expect(host.textContent).toContain("Plan created. The AI service will not be contacted until you confirm.");
    expect(host.textContent).toContain(editPlan.summary);
    expect(host.textContent).toContain("设置");
    expect(host.textContent).toContain("<b>{count}</b>");
    expect(host.textContent).toContain(new Date(editPlan.expiresAt).toLocaleTimeString("en-US"));
    await render("zh-CN", view());
    await click("确认并发送");
    await render("en-US", view());
    expect(gateway.executeAiEdit).toHaveBeenCalledTimes(1);
    expect(gateway.executeAiEdit).toHaveBeenCalledWith(expect.objectContaining({ planId: editPlan.planId, sourceText: selection.text, instruction: instruction.value }));
    const proposal = { id: 7, range: { start: 0, end: selection.text.length }, originalText: selection.text, replacementText: "新正文{count}" };
    await act(async () => executing.resolve({ proposals: [proposal] }));
    expect(host.querySelectorAll(".tool-proposal code")[0].textContent).toBe(selection.text);
    await act(async () => host.querySelector<HTMLInputElement>(".tool-proposal input")!.click());
    await render("zh-CN", view());
    expect(host.querySelector<HTMLInputElement>(".tool-proposal input")!.checked).toBe(true);
    await render("en-US", view());
    await click("Apply selected proposals to buffer");
    expect(applyAiEdits).toHaveBeenCalledWith(expect.objectContaining({ acceptedIds: [7], proposals: [proposal], sourceText: selection.text }));
    expect(onApplyReplacement).toHaveBeenCalledWith(selection, "新正文{count}");
    expect(host.textContent).toContain("Applied 1 proposals to the editor buffer; click Save to write them to disk.");
  });

  it("clears a token before a pending credential save and keeps unknown warning text literal", async () => {
    const saving = deferred<AiCredentialStatusSnapshot>();
    const gateway = { storeAiCredential: vi.fn(() => saving.promise) };
    const view = () => createElement(AIAssistant, { active: true, enabled: true, isDemo: false, sessionId: "session", documentId: "doc", documentRevision: 1, selection, gateway: gateway as unknown as RepositoryGateway, onApplyReplacement: () => true });
    await render("zh-CN", view());
    await input(field("服务类型"), "openai_compatible");
    await input(field("访问令牌"), "TEST_ONLY_TOKEN");
    const token = field("访问令牌");
    await click("保存凭据");
    expect(token.value).toBe("");
    await render("en-US", view());
    expect(field("Access token")).toBe(token);
    expect(token.value).toBe("");
    expect(gateway.storeAiCredential).toHaveBeenCalledTimes(1);
    expect(gateway.storeAiCredential).toHaveBeenCalledWith({ provider: "openai_compatible", endpoint: "https://api.openai.com/v1", model: "", token: "TEST_ONLY_TOKEN" });
    await act(async () => saving.resolve({ configured: true, storage: "session_memory", sessionOnly: true, secretServiceAvailable: false, warning: "设置" }));
    expect(host.textContent).toContain("Credentials are stored only in this process.");
    expect(host.textContent).toContain("Configured (This process memory only)");
    expect(host.textContent).toContain("设置");
    expect(host.textContent).not.toContain("TEST_ONLY_TOKEN");
    await render("zh-CN", view());
    expect(host.textContent).toContain("凭据仅保存在本次进程内。");
  });

  it("translates only local error wrappers and fallback while invalidating responses on selection changes", async () => {
    const pending = deferred<AiEditPlan>();
    const gateway = { planAiEdit: vi.fn().mockRejectedValueOnce(new Error("未知错误{error}<b>")).mockRejectedValueOnce({}).mockReturnValueOnce(pending.promise) };
    const view = (currentSelection = selection) => createElement(AIAssistant, { active: true, enabled: true, isDemo: false, sessionId: "session", documentId: "doc", documentRevision: 1, selection: currentSelection, gateway: gateway as unknown as RepositoryGateway, onApplyReplacement: () => true });
    await render("en-US", view());
    const initialInstruction = field("Editing instruction").value;
    expect(initialInstruction).toBe("Polish the selected text while preserving its meaning and Markdown structure.");
    await render("zh-CN", view());
    expect(field("编辑指令").value).toBe(initialInstruction);
    await render("en-US", view()); await input(field("Model"), editPlan.model);
    await click("Create send plan");
    expect(host.querySelector('[role="status"]')!.textContent).toBe("Unable to create an AI plan: 未知错误{error}<b>");
    await click("Create send plan");
    expect(host.querySelector('[role="status"]')!.textContent).toBe("Unable to create an AI plan: Unknown error");
    await click("Create send plan");
    await render("zh-CN", view({ ...selection, text: "新的选区" }));
    await act(async () => pending.resolve(editPlan));
    expect(host.querySelector(".ai-assistant .operation-plan")).toBeNull();
    expect(gateway.planAiEdit).toHaveBeenCalledTimes(3);
  });

  it("keeps connection approval and pending execution across locale changes, then preserves the model filter", async () => {
    const planning = deferred<AiConnectionPlan>(); const executing = deferred<AiConnectionResult>();
    const gateway = { planAiConnection: vi.fn(() => planning.promise), executeAiConnection: vi.fn(() => executing.promise) };
    const onSelectModel = vi.fn();
    const view = () => createElement(AiConnectionPanel, { active: true, enabled: true, config, gateway, onSelectModel });
    await render("zh-CN", view()); await click("获取模型列表");
    await render("en-US", view());
    expect(gateway.planAiConnection).toHaveBeenCalledTimes(1);
    const frozen = connectionPlan(); await act(async () => planning.resolve(frozen));
    expect(host.textContent).toContain("设置");
    expect(host.textContent).toContain(new Date(frozen.expiresAt).toLocaleTimeString("en-US"));
    await render("zh-CN", view()); await render("en-US", view());
    await act(async () => { const confirm = button("Confirm request"); confirm.click(); confirm.click(); });
    await render("zh-CN", view());
    expect(gateway.executeAiConnection).toHaveBeenCalledTimes(1);
    expect(gateway.executeAiConnection).toHaveBeenCalledWith({ planId: frozen.planId, operation: "models", ...config, model: "" });
    await act(async () => executing.resolve(connectionResult()));
    await input(field("筛选模型"), "模型");
    const filter = field("筛选模型");
    await render("en-US", view());
    expect(field("Filter models")).toBe(filter); expect(filter.value).toBe("模型");
    expect(host.querySelectorAll(".ai-connection-models button")).toHaveLength(1);
    expect(button("模型{count}").title).toBe("Select 模型{count}");
    expect(host.textContent).toContain("This request will be sent to a remote service.");
    expect(host.textContent).not.toContain("SECRET_RAW_WARNING");
    await click("模型{count}");
    expect(onSelectModel).toHaveBeenCalledWith("模型{count}");
    expect(host.textContent).toContain("Selected model 模型{count}; create a new connection plan.");
  });

  it("does not restart the connection expiry timer on locale change and retains safe code-based errors", async () => {
    vi.useFakeTimers();
    const gateway = { planAiConnection: vi.fn().mockResolvedValueOnce(connectionPlan(Date.now() + 1000)).mockRejectedValueOnce({ code: "network", message: "SECRET_RAW" }), executeAiConnection: vi.fn() };
    const view = () => createElement(AiConnectionPanel, { active: true, enabled: true, config, gateway, onSelectModel: vi.fn() });
    await render("zh-CN", view()); await click("获取模型列表");
    await act(async () => vi.advanceTimersByTime(750));
    await render("en-US", view());
    await act(async () => vi.advanceTimersByTime(251));
    expect(host.querySelector(".ai-connection-plan")).toBeNull();
    expect(host.textContent).toContain("The connection plan expired. Create a new plan and confirm it.");
    expect(gateway.executeAiConnection).not.toHaveBeenCalled();
    await click("Get model list");
    expect(host.textContent).toContain("Unable to connect to the service.");
    expect(host.textContent).not.toContain("SECRET_RAW");
    await render("zh-CN", view()); expect(host.textContent).toContain("无法连接到服务。");
  });

  it("localizes controlled probe warnings and sends only the frozen probe request", async () => {
    const frozen = { ...connectionPlan(), operation: "probe" as const, model: config.model, requestUrl: `${config.endpoint}/chat/completions`, requestSummary: "设置" };
    const result = { ...connectionResult(), operation: "probe" as const, model: config.model, models: [], status: "probe_succeeded" as const, warnings: ["credential_session_only", "SECRET_RAW_WARNING"] };
    const gateway = { planAiConnection: vi.fn(async () => frozen), executeAiConnection: vi.fn(async () => result) };
    const view = () => createElement(AiConnectionPanel, { active: true, enabled: true, config, gateway, onSelectModel: vi.fn() });
    await render("en-US", view()); await click("Test connection"); await click("Confirm request");
    expect(host.querySelector('[aria-label="Connection test result"]')).not.toBeNull();
    expect(host.textContent).toContain("Credentials are available only for this run.");
    expect(host.textContent).toContain("Small text conversation completed successfully in 8 ms.");
    expect(host.textContent).not.toContain("SECRET_RAW_WARNING");
    expect(gateway.executeAiConnection).toHaveBeenCalledWith({ planId: frozen.planId, operation: "probe", ...config });
  });

  it("keeps the smart-tool tab and keyboard focus while changing shell labels", async () => {
    const unexpectedCall = vi.fn();
    const gateway = new Proxy({}, { get: () => unexpectedCall }) as RepositoryGateway;
    const view = () => createElement(AdvancedTools, { open: true, onClose: vi.fn(), repository: null, capabilities: { localEdit: false } as CapabilitySnapshot, gateway, document: null, currentDocumentText: "原文", selection, onApplyAiReplacement: () => true, onOpenSemanticPath: vi.fn(), onOpenContentHealthIssue: vi.fn() });
    await render("zh-CN", view()); await click("语义检索");
    const tab = host.querySelector<HTMLButtonElement>("#tool-tab-semantic")!;
    tab.focus();
    await render("en-US", view());
    expect(host.querySelector("#tool-tab-semantic")).toBe(tab);
    expect(tab.getAttribute("aria-selected")).toBe("true");
    expect(document.activeElement).toBe(tab);
    expect(host.querySelector("#tool-panel-semantic")!.hasAttribute("hidden")).toBe(false);
    expect(host.querySelector("#advanced-tools-title")!.textContent).toBe("Smart tools");
    await act(async () => tab.dispatchEvent(new KeyboardEvent("keydown", { key: "ArrowLeft", bubbles: true })));
    expect(host.querySelector("#tool-tab-chat")!.getAttribute("aria-selected")).toBe("true");
    expect(host.querySelector("#tool-tab-chat")!.textContent).toBe("AI chat");
    expect(host.querySelector(".ai-chat-vault")!.textContent).toContain("Encrypted history is unavailable in this environment.");
    expect(host.querySelector(".ai-chat-vault")!.textContent).not.toContain("Reading encrypted history status");
    expect(unexpectedCall).not.toHaveBeenCalled();
  });
});
