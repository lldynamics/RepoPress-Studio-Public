import { act, createElement, Profiler } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { I18nProvider } from "../i18n/i18n";
import { safePreviewUrl, SitePreview, type SitePreviewProps } from "./SitePreview";
import { StrictMode } from "react";
import type { SitePreviewPageSnapshot, SitePreviewPlan } from "../contracts/sitePreview";

const readiness = {
  siteKind: "Zola",
  supported: true,
  runtimeAvailable: true,
  executable: "zola",
  version: "1",
  reason: null,
  warning: null,
};
const plan = (id = "plan-1"): SitePreviewPlan => ({
  planId: id,
  siteKind: "Zola",
  executable: "zola",
  expiresAtEpochMs: Date.now() + 60_000,
  configFingerprint: "cfg",
  document: null,
  articlePath: "/posts/a/",
});
const snap = (id = "preview-1", url = "http://127.0.0.1:1313/") => ({
  previewId: id,
  running: true,
  url,
  siteKind: "Zola",
  message: "Preview is running on loopback only.",
});
const page = (
  id = "preview-1",
  url = "http://127.0.0.1:1313/posts/a/",
  overrides: Partial<SitePreviewPageSnapshot> = {},
): SitePreviewPageSnapshot => ({
  previewId: id,
  requestedUrl: "http://127.0.0.1:1313/posts/a/",
  url,
  ready: true,
  statusCode: 200,
  reason: "ready",
  ...overrides,
});
let host: HTMLDivElement; let root: Root;
let inspect: ReturnType<typeof vi.fn>;
let planFn: ReturnType<typeof vi.fn>;
let start: ReturnType<typeof vi.fn>;
let check: ReturnType<typeof vi.fn>;
let stop: ReturnType<typeof vi.fn>;
let commitFrames: boolean[];
function render(
  overrides: Record<string, unknown> = {},
  locale: "zh-CN" | "en-US" = "zh-CN",
) {
  root.render(createElement(I18nProvider, {
    locale,
    children: createElement(Profiler, {
      id: "site-preview-test",
      onRender: () => commitFrames.push(Boolean(host.querySelector("iframe"))),
      children: createElement(SitePreview, {
        sessionId: "s1",
        markdownHtml: "<p>draft</p>",
        articlePath: "/posts/a/",
        contextKey: "ctx-1",
        document: null,
        inspect,
        plan: planFn,
        start,
        check,
        stop,
        ...overrides,
      } as SitePreviewProps),
    }),
  }));
}
async function settle() {
  await act(async () => {
    await Promise.resolve();
    await Promise.resolve();
  });
}
function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}
beforeEach(() => {
  host = document.createElement("div");
  document.body.append(host);
  root = createRoot(host);
  inspect = vi.fn(async () => readiness);
  planFn = vi.fn(async () => plan());
  start = vi.fn(async () => snap());
  check = vi.fn(async () => page());
  stop = vi.fn(async () => ({ ...snap(), running: false, previewId: null }));
  commitFrames = [];
  vi.spyOn(window, "confirm").mockReturnValue(true);
});
afterEach(() => {
  vi.restoreAllMocks();
  act(() => root.unmount());
  host.remove();
});
function button(label: string) {
  return [...host.querySelectorAll("button")].find(
    (item) => item.textContent?.includes(label),
  ) as HTMLButtonElement | undefined;
}

describe("SitePreview readiness", () => {
  it("inspects once and does not start on plan cancellation", async () => {
    render();
    await settle();
    expect(inspect).toHaveBeenCalledTimes(1);
    vi.spyOn(window, "confirm").mockReturnValue(false);
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(planFn).toHaveBeenCalledTimes(1);
    expect(start).not.toHaveBeenCalled();
  });

  it("rejects an expired plan without starting", async () => {
    planFn.mockImplementationOnce(async () => ({
      ...plan(),
      expiresAtEpochMs: Date.now() - 1,
    }));
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(start).not.toHaveBeenCalled();
  });

  it("starts then checks before creating an iframe", async () => {
    const pending = deferred<SitePreviewPageSnapshot>();
    check.mockReturnValueOnce(pending.promise);
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(start).toHaveBeenCalledWith("s1", "plan-1", true);
    expect(host.querySelector("iframe")).toBeNull();
    pending.resolve(page());
    await settle();
    expect(host.querySelector("iframe")?.getAttribute("src"))
      .toBe("http://127.0.0.1:1313/posts/a/");
  });

  it.each([
    [404, "http_error"],
    [500, "invalid_response"],
    [null, "timeout"],
    [null, "process_exited"],
    [302, "redirect_rejected"],
  ])("keeps %s/%s page unembedded", async (statusCode, reason) => {
    check.mockResolvedValueOnce(page(
      "preview-1",
      "http://127.0.0.1:1313/posts/a/",
      { ready: false, statusCode, reason },
    ));
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(host.querySelector("iframe")).toBeNull();
  });

  it("accepts a safe same-origin redirect and embeds final URL", async () => {
    check.mockResolvedValueOnce(page(
      "preview-1",
      "http://127.0.0.1:1313/rendered/a/",
    ));
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(host.querySelector("iframe")?.getAttribute("src"))
      .toBe("http://127.0.0.1:1313/rendered/a/");
  });

  it("rejects unsafe or cross-origin final URLs", async () => {
    check.mockResolvedValueOnce(page("preview-1", "https://evil.example/a/"));
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(host.querySelector("iframe")).toBeNull();
  });

  it("ignores an old check after target changes", async () => {
    const first = deferred<SitePreviewPageSnapshot>();
    check.mockReturnValueOnce(first.promise).mockResolvedValueOnce(page(
      "preview-1",
      "http://127.0.0.1:1313/",
      { requestedUrl: "http://127.0.0.1:1313/" },
    ));
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    await act(async () => button("站点首页")!.click());
    await settle();
    expect(check).toHaveBeenLastCalledWith("s1", "preview-1", "home");
    expect(host.querySelector("iframe")?.getAttribute("src"))
      .toBe("http://127.0.0.1:1313/");
    first.resolve(page());
    await settle();
    expect(host.querySelector("iframe")?.getAttribute("src"))
      .toBe("http://127.0.0.1:1313/");
  });

  it("stops a prior preview on context change", async () => {
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    render({ contextKey: "ctx-2" });
    await settle();
    expect(stop).toHaveBeenCalledTimes(1);
    expect(stop).toHaveBeenCalledWith("s1", "preview-1");
  });

  it("hides a verified page in the first commit for a new context", async () => {
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(host.querySelector("iframe")).not.toBeNull();
    commitFrames = [];
    render({ contextKey: "ctx-2" });
    await settle();
    expect(commitFrames[0]).toBe(false);
    expect(host.querySelector("iframe")).toBeNull();
  });

  it("preserves preview id when explicit stop fails for retry", async () => {
    stop.mockRejectedValueOnce(new Error("stop failed"));
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    await act(async () => button("停止")!.click());
    await settle();
    expect(button("停止")?.disabled).toBe(false);
  });

  it("ignores a late start and stops only its returned id", async () => {
    const pending = deferred<ReturnType<typeof snap>>();
    start.mockReturnValueOnce(pending.promise);
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    render({ contextKey: "ctx-2" });
    await settle();
    pending.resolve(snap("old"));
    await settle();
    expect(stop).toHaveBeenCalledTimes(1);
    expect(stop).toHaveBeenCalledWith("s1", "old");
  });

  it("handles repeated clicks while planning", async () => {
    const pending = deferred<SitePreviewPlan>();
    planFn.mockReturnValueOnce(pending.promise);
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => {
      button("启动")!.click();
      button("启动")!.click();
    });
    expect(planFn).toHaveBeenCalledTimes(1);
    pending.resolve(plan());
    await settle();
  });

  it("survives StrictMode effect replay and can start", async () => {
    root.render(createElement(I18nProvider, {
      locale: "zh-CN",
      children: createElement(StrictMode, {
        children: createElement(SitePreview, {
          sessionId: "s1",
          markdownHtml: "",
          articlePath: "/posts/a/",
          contextKey: "ctx-1",
          document: null,
          inspect,
          plan: planFn,
          start,
          check,
          stop,
        } as SitePreviewProps),
      }),
    }));
    await settle();
    expect(inspect).toHaveBeenCalledTimes(1);
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(start).toHaveBeenCalledTimes(1);
    expect(check).toHaveBeenCalledWith("s1", "preview-1", "article");
    expect(host.querySelector("iframe")?.getAttribute("src"))
      .toBe("http://127.0.0.1:1313/posts/a/");
  });

  it("localizes and shows the saved-file warning", async () => {
    render({ unsaved: true }, "en-US");
    await settle();
    await act(async () => button("Live site")!.click());
    expect(host.textContent).toContain("saved file");
  });

  it("uses the shared editor translation for the readiness trust warning", async () => {
    inspect.mockResolvedValueOnce({
      ...readiness,
      warning: "A real preview processes content from this trusted repository.",
    });
    render({}, "en-US");
    await settle();
    await act(async () => button("Live site")!.click());
    expect(host.textContent).toContain(
      "Live preview processes content from the local repository.",
    );
    expect(host.textContent).not.toContain("真实预览会处理");
  });

  it.each([
    ["preview_site_kind_unsupported", "supports only Zola and Hugo"],
    ["runtime_not_found_in_trusted_locations", "trusted system or user tool directories"],
    ["repository_root_not_safe", "did not pass the live preview safety check"],
    ["preview_page_unsafe_url", "unsafe preview address"],
  ])("uses the shared editor translation for readiness reason %s", async (reason, expected) => {
    inspect.mockResolvedValueOnce({
      ...readiness,
      supported: false,
      runtimeAvailable: false,
      reason,
    });
    render({}, "en-US");
    await settle();
    await act(async () => button("Live site")!.click());
    expect(host.textContent).toContain(expected);
  });

  it("keeps the session inspect alive across a context change", async () => {
    const pending = deferred<typeof readiness>();
    inspect.mockReturnValueOnce(pending.promise);
    render();
    await settle();
    render({ contextKey: "ctx-2" });
    await settle();
    pending.resolve(readiness);
    await settle();
    await act(async () => button("真实站点")!.click());
    expect(inspect).toHaveBeenCalledTimes(1);
    expect(button("启动 zola")).toBeDefined();
  });

  it("does not let an old operation release a new operation latch", async () => {
    const oldPlan = deferred<SitePreviewPlan>();
    const newPlan = deferred<SitePreviewPlan>();
    planFn.mockReturnValueOnce(oldPlan.promise).mockReturnValueOnce(newPlan.promise);
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    render({ contextKey: "ctx-2" });
    await settle();
    await act(async () => button("启动")!.click());
    expect(planFn).toHaveBeenCalledTimes(2);
    oldPlan.resolve(plan("old-plan"));
    await settle();
    expect(button("处理中")?.disabled).toBe(true);
    expect(window.confirm).not.toHaveBeenCalled();
    newPlan.resolve(plan("new-plan"));
    await settle();
    expect(start).toHaveBeenCalledTimes(1);
    expect(start).toHaveBeenCalledWith("s1", "new-plan", true);
  });

  it("does not trust a plan when the external context becomes stale", async () => {
    const pending = deferred<SitePreviewPlan>();
    let current = true;
    planFn.mockReturnValueOnce(pending.promise);
    render({ isContextCurrent: () => current });
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    current = false;
    pending.resolve(plan());
    await settle();
    expect(window.confirm).not.toHaveBeenCalled();
    expect(start).not.toHaveBeenCalled();
  });

  it("stops a start result when the external context becomes stale", async () => {
    const pending = deferred<ReturnType<typeof snap>>();
    let current = true;
    start.mockReturnValueOnce(pending.promise);
    render({ isContextCurrent: () => current });
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    current = false;
    pending.resolve(snap("stale-start"));
    await settle();
    expect(stop).toHaveBeenCalledTimes(1);
    expect(stop).toHaveBeenCalledWith("s1", "stale-start");
    expect(check).not.toHaveBeenCalled();
  });

  it("does not embed a check result when the external context becomes stale", async () => {
    const pending = deferred<SitePreviewPageSnapshot>();
    let current = true;
    check.mockReturnValueOnce(pending.promise);
    render({ isContextCurrent: () => current });
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    current = false;
    pending.resolve(page());
    await settle();
    expect(host.querySelector("iframe")).toBeNull();
    expect(host.textContent).not.toContain("页面已就绪");
  });

  it("uses the home target and exposes revalidation without an article path", async () => {
    const homePage = page("preview-1", "http://127.0.0.1:1313/", {
      requestedUrl: "http://127.0.0.1:1313/",
    });
    check.mockResolvedValue(homePage);
    render({ articlePath: null });
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(check).toHaveBeenNthCalledWith(1, "s1", "preview-1", "home");
    expect(host.querySelector("iframe")?.getAttribute("src")).toBe("http://127.0.0.1:1313/");
    expect(button("当前文章")).toBeUndefined();
    await act(async () => button("重新验证页面")!.click());
    await settle();
    expect(check).toHaveBeenCalledTimes(2);
    expect(check).toHaveBeenNthCalledWith(2, "s1", "preview-1", "home");
  });

  it("clears a probe error when revalidation succeeds", async () => {
    check
      .mockRejectedValueOnce({ code: "http_error", message: "raw backend" })
      .mockResolvedValueOnce(page());
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(host.querySelector('[role="alert"]')?.textContent).toContain("页面核验失败");
    expect(host.textContent).not.toContain("正在核验页面");
    await act(async () => button("重新验证页面")!.click());
    await settle();
    expect(check).toHaveBeenCalledTimes(2);
    expect(host.querySelector('[role="alert"]')).toBeNull();
    expect(host.textContent).toContain("页面已就绪");
    expect(host.querySelector("iframe")?.getAttribute("src"))
      .toBe("http://127.0.0.1:1313/posts/a/");
  });

  it("keeps a replacement owner when an older same-session start finishes", async () => {
    const oldStart = deferred<ReturnType<typeof snap>>();
    start.mockReturnValueOnce(oldStart.promise).mockResolvedValueOnce(snap("new"));
    check.mockResolvedValue(page("new"));
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    render({ contextKey: "ctx-2" });
    await settle();
    await act(async () => button("启动")!.click());
    await settle();
    oldStart.resolve(snap("old"));
    await settle();
    expect(stop).toHaveBeenNthCalledWith(1, "s1", "old");
    await act(async () => button("停止")!.click());
    await settle();
    expect(stop).toHaveBeenNthCalledWith(2, "s1", "new");
  });

  it("invalidates an old probe rejection when the session changes", async () => {
    const pending = deferred<SitePreviewPageSnapshot>();
    check.mockReturnValueOnce(pending.promise);
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    render({ sessionId: "s2", contextKey: "ctx-s2" });
    await settle();
    pending.reject({ code: "http_error", message: "raw" });
    await settle();
    expect(inspect).toHaveBeenCalledTimes(2);
    expect(host.querySelector('[role="alert"]')).toBeNull();
  });

  it("does not inspect or probe again when only the locale changes", async () => {
    render();
    await settle();
    await act(async () => button("真实站点")!.click());
    await act(async () => button("启动")!.click());
    await settle();
    expect(inspect).toHaveBeenCalledTimes(1);
    expect(check).toHaveBeenCalledTimes(1);
    render({}, "en-US");
    await settle();
    expect(inspect).toHaveBeenCalledTimes(1);
    expect(check).toHaveBeenCalledTimes(1);
    expect(host.querySelector("iframe")?.title).toContain("current article");
  });

  it.each([
    ["ready", "The page is ready."],
    ["http_error", "The page check failed."],
    ["timeout", "The page check timed out."],
    ["invalid_response", "The page returned an invalid response."],
    ["redirect_rejected", "The page redirected to an unsafe address"],
    ["process_exited", "The preview process exited before the page was ready."],
  ])("localizes backend page reason %s", async (reason, expected) => {
    check.mockResolvedValueOnce(page("preview-1", "http://127.0.0.1:1313/posts/a/", {
      ready: false,
      reason,
    }));
    render({}, "en-US");
    await settle();
    await act(async () => button("Live site")!.click());
    await act(async () => button("Start")!.click());
    await settle();
    expect(host.textContent).toContain(expected);
  });

  it("localizes a GatewayError code without displaying the raw code", async () => {
    planFn.mockRejectedValueOnce({ code: "preview_plan_expired", message: "raw backend" });
    render({}, "en-US");
    await settle();
    await act(async () => button("Live site")!.click());
    await act(async () => button("Start")!.click());
    await settle();
    expect(host.textContent).toContain("The preview plan expired");
    expect(host.textContent).not.toContain("preview_plan_expired");
  });

  it.each([
    "http://127.1:1313/",
    "http://0x7f000001:1313/",
    "http://2130706433:1313/",
    "http://user@127.0.0.1:1313/",
    "http://127.0.0.1:1313/?query=1",
    "http://127.0.0.1:1313/#fragment",
    "http://127.0.0.1:1313/%0a",
  ])("rejects non-literal or decorated loopback URL %s", (value) => {
    expect(safePreviewUrl(value)).toBeNull();
  });
});
