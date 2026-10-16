import { act, createElement } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { AiConnectionPlan, AiConnectionResult } from "../contracts/aiConnection";
import type { AiProviderRequest, RepositoryGateway } from "../contracts/repository";
import { AiConnectionPanel } from "./AiConnectionPanel";

(globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const baseConfig: AiProviderRequest = { provider: "openai_compatible", endpoint: "HTTPS://API.EXAMPLE.COM:443/v1/", model: "gpt-test" };
const mountedRoots: Array<ReturnType<typeof createRoot>> = [];

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => { resolve = resolvePromise; reject = rejectPromise; });
  return { promise, resolve, reject };
}

function plan(overrides: Partial<AiConnectionPlan> = {}): AiConnectionPlan {
  return {
    planId: "plan-1",
    operation: "models",
    provider: "openai_compatible",
    endpoint: "https://api.example.com/v1",
    requestUrl: "https://api.example.com/v1/models",
    model: null,
    expiresAt: Date.now() + 60_000,
    requestSummary: "获取模型列表",
    ...overrides,
  };
}

function result(overrides: Partial<AiConnectionResult> = {}): AiConnectionResult {
  return {
    planId: "plan-1",
    operation: "models",
    provider: "openai_compatible",
    endpoint: "https://api.example.com/v1",
    model: null,
    models: ["gpt-test", "small-model", "vision-model"],
    checkedAt: Date.now(),
    status: "models_available",
    warnings: [],
    elapsedMs: 8,
    ...overrides,
  };
}

function mount(gateway: Partial<RepositoryGateway>, extra: Partial<Parameters<typeof AiConnectionPanel>[0]> = {}) {
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  mountedRoots.push(root);
  const props = {
    gateway: gateway as RepositoryGateway,
    config: baseConfig,
    active: true,
    enabled: true,
    disabled: false,
    credentialEpoch: 0,
    onSelectModel: vi.fn(),
    ...extra,
  };
  return { host, root, props };
}

function button(host: HTMLElement, label: string) {
  const found = Array.from(host.querySelectorAll<HTMLButtonElement>("button")).find((entry) => entry.textContent === label);
  if (!found) throw new Error(`Missing button: ${label}`);
  return found;
}

function input(host: HTMLElement, label: string) {
  const found = Array.from(host.querySelectorAll<HTMLLabelElement>("label")).find((entry) => entry.textContent?.startsWith(label))?.querySelector("input");
  if (!found) throw new Error(`Missing input: ${label}`);
  return found as HTMLInputElement;
}

function setInput(element: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  setter.call(element, value);
  element.dispatchEvent(new InputEvent("input", { bubbles: true, data: value, inputType: "insertText" }));
}

async function render(m: ReturnType<typeof mount>, Component = AiConnectionPanel) {
  await act(async () => { m.root.render(createElement(Component, m.props)); });
}

async function makePlan(m: ReturnType<typeof mount>, operation: "models" | "probe" = "models") {
  await act(async () => { button(m.host, operation === "models" ? "获取模型列表" : "测试连接").click(); });
  await act(async () => { await Promise.resolve(); });
}

describe("AiConnectionPanel", () => {
  afterEach(async () => {
    await act(async () => { for (const root of mountedRoots.splice(0)) root.unmount(); });
    document.body.innerHTML = "";
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("does not execute before the user confirms a generated models plan", async () => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn() };
    const m = mount(gateway); await render(m);
    await makePlan(m);
    expect(gateway.planAiConnection).toHaveBeenCalledWith({ operation: "models", provider: "openai_compatible", endpoint: baseConfig.endpoint.trim(), model: "" });
    expect(gateway.executeAiConnection).not.toHaveBeenCalled();
    expect(m.host.textContent).toContain("确认后");
  });

  it("allows models discovery with an empty model but blocks probe until a model exists", async () => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()) };
    const m = mount(gateway, { config: { ...baseConfig, model: "" } }); await render(m);
    expect(button(m.host, "测试连接").disabled).toBe(true);
    expect(button(m.host, "获取模型列表").disabled).toBe(false);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    expect(gateway.planAiConnection).toHaveBeenCalledWith(expect.objectContaining({ operation: "models", model: "" }));
  });

  it("requires a two-stage confirmation for probe and sends no document text", async () => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan({ operation: "probe", model: "gpt-test", requestUrl: "https://api.example.com/v1/chat/completions", requestSummary: "固定文本" })), executeAiConnection: vi.fn().mockResolvedValue(result({ operation: "probe", model: "gpt-test", status: "probe_succeeded", models: [] })) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "测试连接").click(); });
    expect(gateway.executeAiConnection).not.toHaveBeenCalled();
    await act(async () => { button(m.host, "确认请求").click(); });
    expect(gateway.executeAiConnection).toHaveBeenCalledWith({
      planId: "plan-1", operation: "probe", provider: "openai_compatible", endpoint: "https://api.example.com/v1", model: "gpt-test",
    });
    expect(m.host.querySelector('[aria-label="连接测试结果"]')).not.toBeNull();
  });

  it("accepts the canonical endpoint returned by the backend for a slash, host-case, and default-port equivalent", async () => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn().mockResolvedValue(result()) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "确认请求").click(); });
    expect(gateway.executeAiConnection).toHaveBeenCalledWith(expect.objectContaining({ endpoint: "https://api.example.com/v1" }));
    expect(m.host.querySelector('[aria-label="模型列表"]')).not.toBeNull();
    expect(button(m.host, "small-model")).toBeTruthy();
  });

  it("keeps the root slash in the canonical endpoint without adding an API path", async () => {
    const gateway = {
      planAiConnection: vi.fn().mockResolvedValue(plan({ endpoint: "https://api.example.com/", requestUrl: "https://api.example.com/models" })),
      executeAiConnection: vi.fn().mockResolvedValue(result({ endpoint: "https://api.example.com/" })),
    };
    const m = mount(gateway, { config: { ...baseConfig, endpoint: "https://api.example.com" } }); await render(m);
    await makePlan(m);
    await act(async () => { button(m.host, "确认请求").click(); });
    expect(gateway.executeAiConnection).toHaveBeenCalledWith(expect.objectContaining({ endpoint: "https://api.example.com/" }));
    expect(m.host.querySelector('[aria-label="模型列表"]')).not.toBeNull();
  });

  it.each([
    ["different host", { endpoint: "https://other.example.com/v1" }],
    ["different path", { endpoint: "https://api.example.com/v2" }],
    ["different provider", { provider: "ollama_local" as const }],
    ["different model", { model: "other-model" }],
    ["different request URL", { requestUrl: "https://api.example.com/v1/other" }],
  ])("rejects a %s plan and never executes it", async (_label, mismatch) => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan(mismatch)), executeAiConnection: vi.fn() };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    if (m.host.querySelector("button.danger-action")) await act(async () => { button(m.host, "确认请求").click(); });
    expect(gateway.executeAiConnection).not.toHaveBeenCalled();
    expect(m.host.textContent).toMatch(/改变|无效|重新生成|未完成/);
  });

  it("drops an old pending plan response after config changes", async () => {
    const first = deferred<AiConnectionPlan>();
    const gateway = { planAiConnection: vi.fn().mockReturnValue(first.promise) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { m.root.render(createElement(AiConnectionPanel, { ...m.props, config: { ...baseConfig, endpoint: "https://new.example.com/" } })); });
    await act(async () => { first.resolve(plan()); });
    expect(m.host.querySelector(".ai-connection-plan")).toBeNull();
  });

  it("drops a pending execute result when the credential epoch changes", async () => {
    const execution = deferred<AiConnectionResult>();
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn().mockReturnValue(execution.promise) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "确认请求").click(); });
    await act(async () => { m.root.render(createElement(AiConnectionPanel, { ...m.props, credentialEpoch: 1 })); });
    await act(async () => { execution.resolve(result()); });
    expect(m.host.querySelector('[aria-label="模型列表"]')).toBeNull();
  });

  it("removes an expired approval and requires a fresh plan", async () => {
    vi.useFakeTimers();
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan({ expiresAt: Date.now() + 1_000 })), executeAiConnection: vi.fn() };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { vi.advanceTimersByTime(1_001); });
    expect(m.host.querySelector(".danger-action")).toBeNull();
    expect(m.host.textContent).toContain("过期");
    expect(gateway.executeAiConnection).not.toHaveBeenCalled();
  });

  it("does not execute twice when confirmation is clicked twice in one event turn", async () => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn().mockResolvedValue(result()) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { const confirm = button(m.host, "确认请求"); confirm.click(); confirm.click(); });
    expect(gateway.executeAiConnection).toHaveBeenCalledTimes(1);
  });

  it("does not create two plans when discovery is clicked twice in one event turn", async () => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()) };
    const m = mount(gateway); await render(m);
    await act(async () => { const discover = button(m.host, "获取模型列表"); discover.click(); discover.click(); });
    expect(gateway.planAiConnection).toHaveBeenCalledTimes(1);
  });

  it("requires a fresh plan after a failed execution", async () => {
    const executeAiConnection = vi.fn().mockRejectedValueOnce({ code: "network", message: "SECRET_RAW" });
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "确认请求").click(); });
    expect(m.host.textContent).toContain("网络");
    expect(m.host.textContent).not.toContain("SECRET_RAW");
    expect(m.host.querySelector(".ai-connection-plan")).toBeNull();
    await act(async () => { button(m.host, "获取模型列表").click(); });
    expect(gateway.planAiConnection).toHaveBeenCalledTimes(2);
  });

  it.each([
    { planId: "other-plan" },
    { status: "probe_succeeded" as const },
  ])("rejects a result with mismatched approval evidence: %j", async (mismatch) => {
    const bad = result(mismatch);
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn().mockResolvedValue(bad) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "确认请求").click(); });
    expect(m.host.querySelector('[aria-label="模型列表"]')).toBeNull();
    expect(m.host.textContent).not.toContain("small-model");
    expect(m.host.querySelector('[role="status"]')?.textContent).toContain("未采用");
  });

  it("drops a pending result after the panel is disabled", async () => {
    const execution = deferred<AiConnectionResult>();
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn().mockReturnValue(execution.promise) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "确认请求").click(); });
    await act(async () => { m.root.render(createElement(AiConnectionPanel, { ...m.props, disabled: true })); });
    await act(async () => { execution.resolve(result()); });
    expect(m.host.querySelector('[aria-label="模型列表"]')).toBeNull();
  });

  it("discards a plan and does not execute after cancel", async () => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn() };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "取消").click(); });
    expect(gateway.executeAiConnection).not.toHaveBeenCalled();
    expect(m.host.querySelector(".ai-connection-plan")).toBeNull();
  });

  it("selecting a returned model invokes the callback and invalidates the old plan", async () => {
    const onSelectModel = vi.fn();
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn().mockResolvedValue(result()) };
    const m = mount(gateway, { onSelectModel }); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "确认请求").click(); });
    await act(async () => { button(m.host, "gpt-test").click(); });
    expect(onSelectModel).toHaveBeenCalledWith("gpt-test");
    expect(m.host.querySelector(".ai-connection-plan")).toBeNull();
  });

  it("filters model names and caps the displayed list", async () => {
    const models = Array.from({ length: 51 }, (_, index) => `model-${index}`);
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn().mockResolvedValue(result({ models })) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "确认请求").click(); });
    expect(m.host.querySelectorAll(".ai-connection-models button")).toHaveLength(50);
    await act(async () => { setInput(input(m.host, "筛选模型"), "model-5"); });
    const filtered = Array.from(m.host.querySelectorAll(".ai-connection-models button"));
    expect(filtered.length).toBeGreaterThan(0);
    expect(filtered.map((entry) => entry.textContent)).toContain("model-5");
    expect(filtered.map((entry) => entry.textContent)).toContain("model-50");
  });

  it.each([
    ["auth", "auth", "验证失败"], ["network", "network", "网络"], ["invalid endpoint", "ai_endpoint_invalid", "地址"],
    ["policy", "ai_endpoint_policy_rejected", "允许"], ["denied", "denied", "权限"], ["rate limit", "rate_limit", "频繁"],
    ["unsupported", "unsupported", "支持"], ["too large", "too_large", /大小|过大|超限/], ["invalid response", "invalid_response", "格式"], ["timeout", "timeout", "超时"],
    ["keyring", "ai_secret_service_failed", "密钥环"], ["unknown", "unknown_code", "请求未完成"],
  ])("maps %s errors to a safe user message without exposing raw details", async (_label, code, keyword) => {
    const gateway = { planAiConnection: vi.fn().mockRejectedValue({ code, message: "SECRET_RAW_PROVIDER_RESPONSE" }) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    expect(m.host.querySelector('[role="status"]')?.textContent).toEqual(expect.stringMatching(keyword));
    expect(m.host.textContent).not.toContain("SECRET_RAW_PROVIDER_RESPONSE");
  });

  it("does not operate while inactive, disabled, or unavailable", async () => {
    const gateway = { planAiConnection: vi.fn(), executeAiConnection: vi.fn() };
    const m = mount(gateway, { active: false }); await render(m);
    expect(m.host.textContent).toBe("");
    const second = mount(gateway, { disabled: true }); await render(second);
    expect(button(second.host, "获取模型列表").disabled).toBe(true);
    expect(gateway.planAiConnection).not.toHaveBeenCalled();
  });

  it("renders warnings through fixed labels rather than raw warning text", async () => {
    const gateway = { planAiConnection: vi.fn().mockResolvedValue(plan()), executeAiConnection: vi.fn().mockResolvedValue(result({ warnings: ["credential_session_only", "remote_service", "Model list is partial; additional pages were not requested.", "SECRET_RAW_WARNING"] })) };
    const m = mount(gateway); await render(m);
    await act(async () => { button(m.host, "获取模型列表").click(); });
    await act(async () => { button(m.host, "确认请求").click(); });
    expect(m.host.textContent).toContain("凭据");
    expect(m.host.textContent).toContain("远程");
    expect(m.host.textContent).toContain("分页");
    expect(m.host.textContent).not.toContain("SECRET_RAW_WARNING");
  });
});
