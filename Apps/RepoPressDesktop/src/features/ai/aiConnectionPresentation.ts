import type { AiConnectionOperation, AiConnectionPlan, AiConnectionResult } from "../../contracts/aiConnection";
import type { AiProviderRequest } from "../../contracts/repository";

// Compare the URL spelling returned by Rust without rewriting the user's input
// before backend validation. Rust remains authoritative for endpoint policy.
function canonicalEndpoint(value: string): string | null {
  if (!value || /[\u0000-\u0020\u007f]/.test(value)) return null;
  try {
    const url = new URL(value);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password
      || url.href.includes("?") || url.href.includes("#") || url.pathname.includes("//")) return null;
    if (url.pathname !== "/") url.pathname = url.pathname.replace(/\/+$/, "");
    return url.href;
  } catch {
    return null;
  }
}

export function connectionPlanMatchesRequest(plan: AiConnectionPlan, operation: AiConnectionOperation, request: AiProviderRequest): boolean {
  const endpoint = canonicalEndpoint(request.endpoint);
  if (!endpoint || plan.endpoint !== endpoint || plan.operation !== operation || plan.provider !== request.provider
    || plan.model !== (operation === "models" ? null : request.model) || !plan.planId.trim()) return false;
  const url = new URL(endpoint);
  url.pathname = `${url.pathname.replace(/\/+$/, "")}/${operation === "models" ? "models" : "chat/completions"}`;
  return plan.requestUrl === url.href;
}

export function connectionResultMatchesPlan(result: AiConnectionResult, plan: AiConnectionPlan): boolean {
  return result.planId === plan.planId && result.operation === plan.operation
    && result.provider === plan.provider && result.endpoint === plan.endpoint && result.model === plan.model
    && result.status === (plan.operation === "models" ? "models_available" : "probe_succeeded");
}

export function connectionPlanExpired(plan: AiConnectionPlan): boolean {
  return !Number.isSafeInteger(plan.expiresAt) || plan.expiresAt <= Date.now();
}

// Never render transport messages: a remote response may contain credentials,
// private addresses or other untrusted text. Codes are the presentation contract.
export function connectionErrorLabel(error: unknown): string {
  const code = typeof error === "object" && error !== null && "code" in error && typeof error.code === "string" ? error.code : "";
  switch (code) {
    case "read_only_demo":
      return "浏览器演示不会连接 AI 服务。请在桌面应用中重试。";
    case "ai_endpoint_invalid": case "ai_endpoint_policy_rejected": case "invalid_endpoint": case "endpoint_not_allowed":
      return "服务端点无效或不被允许。请检查服务地址：本机服务使用回环地址，外部服务使用 HTTPS。";
    case "auth": case "credential_missing": case "credential_unavailable":
      return "访问令牌缺失、已更改或验证失败。请检查并重新保存凭据，再生成连接计划。";
    case "ai_credential_store_unavailable": case "ai_secret_service_unavailable": case "ai_secret_service_failed": case "ai_secret_service_invalid": case "ai_secret_service_timeout":
      return "无法读取本机凭据。请检查密钥环是否可用并已解锁，再生成连接计划。";
    case "denied":
      return "服务拒绝访问。请检查令牌权限与模型访问权限，再生成连接计划。";
    case "rate_limit":
      return "请求过于频繁。请稍后重新生成连接计划。";
    case "ai_model_invalid": case "model_required": case "model_not_found": case "unsupported_model":
      return "模型不可用。请手动输入或从模型列表中选择后重试。";
    case "plan_expired": case "plan_not_found":
      return "连接计划已过期或不可用。请重新生成后确认。";
    case "network": case "network_unavailable": case "connection_failed": case "request_failed":
      return "无法连接到服务。请检查地址、本机服务状态和网络，再生成连接计划。";
    case "request_timeout": case "timeout":
      return "服务响应超时。请确认服务可用后重新生成连接计划。";
    case "unsupported":
      return "服务不支持此检查。请确认 OpenAI-compatible 接口地址及所选模型。";
    case "too_large":
      return "服务响应超过大小限制，未采用。请检查服务后重新生成连接计划。";
    case "invalid_response":
      return "连接计划不可用或服务响应格式无效。请检查配置并重新生成计划。";
    case "ai_connection_unavailable": case "ai_connection_plan_task_failed": case "ai_connection_execute_task_failed":
      return "本机连接检查暂不可用。请稍后重试，必要时重新启动应用。";
    default:
      return "请求未完成。请检查服务地址、模型和凭据，再生成连接计划。";
  }
}

export function connectionWarningLabel(code: string): string {
  if (code === "credential_session_only") return "凭据仅在本次运行中可用。";
  if (code === "remote_service") return "该请求会发送到远程服务。";
  if (code === "models_truncated" || code === "Model list is partial; additional pages were not requested.") {
    return "模型列表不完整，尚未获取后续分页。仍可手动输入模型名称。";
  }
  return "服务返回了额外警告；请检查地址、模型和凭据。";
}
