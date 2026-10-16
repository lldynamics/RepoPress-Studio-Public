import { act, createElement, startTransition, Suspense, useLayoutEffect } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { useMarkdownDiagnostics, type MarkdownDiagnosticsSession } from "./useMarkdownDiagnostics";

interface Props {
  value: string;
  documentKey?: string;
  knownArticleTitles?: string[];
  enabled?: boolean;
}

class FakeWorker {
  static instances: FakeWorker[] = [];
  readonly url: URL;
  readonly options: WorkerOptions | undefined;
  onmessage: ((event: MessageEvent<unknown>) => void) | null = null;
  onerror: ((event: Event) => void) | null = null;
  onmessageerror: ((event: MessageEvent<unknown>) => void) | null = null;
  postMessage = vi.fn();
  terminate = vi.fn();
  constructor(url: URL, options?: WorkerOptions) {
    this.url = url;
    this.options = options;
    FakeWorker.instances.push(this);
  }
  request() { return this.postMessage.mock.calls[0]?.[0] as { requestId: number; source: string; knownArticleTitles?: string[] }; }
  reply(data: unknown) { this.onmessage?.({ data } as MessageEvent<unknown>); }
}

const longText = (suffix = "") => `${"a".repeat(32 * 1024 + 1)}${suffix}`;
const diagnostic = { id: "test-1", severity: "warning" as const, title: "test", message: "test", range: { from: 0, to: 1 } };

describe("useMarkdownDiagnostics", () => {
  Object.assign(globalThis, { IS_REACT_ACT_ENVIRONMENT: true });
  let host: HTMLDivElement;
  let root: Root;
  let latest: MarkdownDiagnosticsSession;
  let afterLayout: (() => void) | undefined;

  function Harness(props: Props) {
    latest = useMarkdownDiagnostics(props.value, props.documentKey, props.knownArticleTitles, props.enabled);
    useLayoutEffect(() => {
      const callback = afterLayout;
      afterLayout = undefined;
      callback?.();
    });
    return null;
  }

  function render(props: Props) {
    act(() => root.render(createElement(Harness, props)));
    return latest!;
  }

  async function advance(milliseconds: number) {
    await act(async () => { await vi.advanceTimersByTimeAsync(milliseconds); });
  }

  beforeEach(() => {
    vi.useFakeTimers();
    FakeWorker.instances = [];
    afterLayout = undefined;
    vi.stubGlobal("Worker", FakeWorker);
    host = document.createElement("div");
    document.body.append(host);
    root = createRoot(host);
  });

  afterEach(() => {
    act(() => root.unmount());
    host.remove();
    vi.useRealTimers();
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
  });

  it("keeps small documents synchronous, bounded, and independent of Worker support", () => {
    vi.stubGlobal("Worker", undefined);
    let session = render({ value: "https://example.test", documentKey: "a" });
    expect(session).toMatchObject({ status: "ready", documentKey: "a", truncated: false });
    expect(session.diagnostics).toHaveLength(1);
    const crowded = Array.from({ length: 501 }, (_, index) => `https://e.test/${index}`).join("\n");
    session = render({ value: crowded, documentKey: "a" });
    expect(session).toMatchObject({ status: "ready", truncated: true });
    expect(session.diagnostics).toHaveLength(500);
    expect(FakeWorker.instances).toHaveLength(0);
  });

  it("returns idle without analyzing when disabled", () => {
    const session = render({ value: "https://example.test", documentKey: "a", enabled: false });
    expect(session).toMatchObject({ status: "idle", diagnostics: [], truncated: false });
    expect(FakeWorker.instances).toHaveLength(0);
  });

  it("debounces long documents and accepts only the matching request", async () => {
    const source = longText("https://example.test");
    expect(render({ value: source, documentKey: "a", knownArticleTitles: ["Known"] }).status).toBe("pending");
    await advance(199);
    expect(FakeWorker.instances).toHaveLength(0);
    await advance(1);
    const worker = FakeWorker.instances[0];
    expect(worker.options).toEqual({ type: "module" });
    expect(worker.url.pathname).toContain("markdownDiagnostics.worker.ts");
    expect(worker.request()).toMatchObject({ source, knownArticleTitles: ["Known"] });
    act(() => worker.reply({ requestId: worker.request().requestId + 1, diagnostics: [diagnostic], truncated: false }));
    expect(latest.status).toBe("pending");
    act(() => worker.reply({ requestId: worker.request().requestId, diagnostics: [diagnostic], truncated: false }));
    expect(latest).toMatchObject({ status: "ready", source, documentKey: "a", diagnostics: [diagnostic] });
    expect(worker.terminate).toHaveBeenCalledTimes(1);
  });

  it("hides results and terminates work on source, key, or title-context changes", async () => {
    const source = longText();
    render({ value: source, documentKey: "a", knownArticleTitles: ["One"] });
    await advance(200);
    const first = FakeWorker.instances[0];
    act(() => first.reply({ requestId: first.request().requestId, diagnostics: [diagnostic], truncated: false }));
    expect(latest.status).toBe("ready");

    expect(render({ value: `${source}b`, documentKey: "a", knownArticleTitles: ["One"] })).toMatchObject({ status: "pending", diagnostics: [] });
    expect(first.terminate).toHaveBeenCalledTimes(1);
    expect(render({ value: `${source}b`, documentKey: "b", knownArticleTitles: ["One"] })).toMatchObject({ status: "pending", diagnostics: [], documentKey: "b" });
    expect(render({ value: `${source}b`, documentKey: "b", knownArticleTitles: ["Two"] })).toMatchObject({ status: "pending", diagnostics: [] });
    await advance(200);
    expect(FakeWorker.instances[FakeWorker.instances.length - 1]?.request().knownArticleTitles).toEqual(["Two"]);
  });

  it("treats identical text in different documents as distinct sessions", async () => {
    const source = longText();
    render({ value: source, documentKey: "a" });
    await advance(200);
    const first = FakeWorker.instances[0];
    act(() => first.reply({ requestId: first.request().requestId, diagnostics: [diagnostic], truncated: false }));
    expect(render({ value: source, documentKey: "b" })).toMatchObject({ status: "pending", diagnostics: [], documentKey: "b" });
    await advance(200);
    expect(FakeWorker.instances).toHaveLength(2);
  });

  it("never resurrects an earlier result after an A-to-B-to-A transition", async () => {
    const sourceA = longText("A");
    const sourceB = longText("B");
    render({ value: sourceA, documentKey: "doc" });
    await advance(200);
    const first = FakeWorker.instances[0];
    act(() => first.reply({ requestId: first.request().requestId, diagnostics: [diagnostic], truncated: false }));
    expect(latest.status).toBe("ready");
    render({ value: sourceB, documentKey: "doc" });
    expect(render({ value: sourceA, documentKey: "doc" })).toMatchObject({ status: "pending", diagnostics: [] });
    await advance(200);
    expect(FakeWorker.instances).toHaveLength(2);
    expect(FakeWorker.instances[1].request().source).toBe(sourceA);
  });

  it("starts a new generation after diagnostics are disabled and re-enabled", async () => {
    const source = longText();
    render({ value: source, documentKey: "doc" });
    await advance(200);
    const first = FakeWorker.instances[0];
    act(() => first.reply({ requestId: first.request().requestId, diagnostics: [diagnostic], truncated: false }));
    expect(render({ value: source, documentKey: "doc", enabled: false })).toMatchObject({ status: "idle", diagnostics: [] });
    expect(render({ value: source, documentKey: "doc", enabled: true })).toMatchObject({ status: "pending", diagnostics: [] });
    await advance(200);
    expect(FakeWorker.instances).toHaveLength(2);
  });

  it("makes callbacks generation-specific across A-to-B-to-A transitions and retries", async () => {
    const sourceA = longText("A");
    render({ value: sourceA, documentKey: "doc" });
    const oldCancel = latest.cancel;
    const oldRetry = latest.retry;
    render({ value: longText("B"), documentKey: "doc" });
    render({ value: sourceA, documentKey: "doc" });
    await advance(200);
    const current = FakeWorker.instances[0];
    act(() => { oldCancel(); oldRetry(); });
    expect(latest.status).toBe("pending");
    expect(current.terminate).not.toHaveBeenCalled();
    await advance(200);
    expect(FakeWorker.instances).toHaveLength(1);

    const beforeRetryCancel = latest.cancel;
    const beforeRetryRetry = latest.retry;
    act(() => latest.retry());
    await advance(200);
    const retried = FakeWorker.instances[1];
    act(() => { beforeRetryCancel(); beforeRetryRetry(); oldCancel(); oldRetry(); });
    expect(latest.status).toBe("pending");
    expect(retried.terminate).not.toHaveBeenCalled();
    await advance(200);
    expect(FakeWorker.instances).toHaveLength(2);
  });

  it("ignores a stale response after the replacement commits and before its passive cleanup", async () => {
    const sourceA = longText("A");
    render({ value: sourceA, documentKey: "doc" });
    await advance(200);
    const worker = FakeWorker.instances[0];
    const staleMessage = worker.onmessage!;
    afterLayout = () => staleMessage({ data: { requestId: worker.request().requestId, diagnostics: [diagnostic], truncated: false } } as MessageEvent);
    expect(render({ value: longText("B"), documentKey: "doc" })).toMatchObject({ status: "pending", diagnostics: [] });
    expect(worker.terminate).toHaveBeenCalledTimes(1);
    expect(render({ value: sourceA, documentKey: "doc" })).toMatchObject({ status: "pending", diagnostics: [] });
  });

  it("keeps the committed A worker valid when a speculative B transition suspends", async () => {
    const sourceA = longText("A");
    const sourceB = longText("B");
    const never = new Promise<void>(() => {});
    let committed: MarkdownDiagnosticsSession | undefined;
    function TransitionHarness({ value, suspend }: { value: string; suspend: boolean }) {
      const session = useMarkdownDiagnostics(value, "doc");
      useLayoutEffect(() => { committed = session; }, [session]);
      if (suspend) throw never;
      return null;
    }
    const tree = (value: string, suspend: boolean) => createElement(
      Suspense,
      { fallback: null },
      createElement(TransitionHarness, { value, suspend }),
    );
    act(() => root.render(tree(sourceA, false)));
    await advance(200);
    const worker = FakeWorker.instances[0];
    expect(committed).toMatchObject({ source: sourceA, status: "pending" });
    act(() => startTransition(() => root.render(tree(sourceB, true))));
    expect(committed).toMatchObject({ source: sourceA, status: "pending" });
    act(() => worker.reply({ requestId: worker.request().requestId, diagnostics: [diagnostic], truncated: false }));
    expect(committed).toMatchObject({ source: sourceA, status: "ready", diagnostics: [diagnostic] });
  });

  it("cancels, ignores late success and error callbacks, then retries with a new generation", async () => {
    const source = longText();
    render({ value: source, documentKey: "a" });
    await advance(200);
    const first = FakeWorker.instances[0];
    const lateMessage = first.onmessage!;
    const lateError = first.onerror!;
    act(() => latest.cancel());
    expect(latest).toMatchObject({ status: "cancelled", diagnostics: [] });
    expect(first.terminate).toHaveBeenCalledTimes(1);
    act(() => {
      lateMessage({ data: { requestId: first.request().requestId, diagnostics: [diagnostic], truncated: false } } as MessageEvent);
      lateError(new Event("error"));
    });
    expect(latest.status).toBe("cancelled");
    act(() => latest.retry());
    expect(latest).toMatchObject({ status: "pending", diagnostics: [] });
    await advance(200);
    expect(FakeWorker.instances).toHaveLength(2);
    expect(FakeWorker.instances[1].request().requestId).not.toBe(first.request().requestId);
  });

  it("fails closed for unavailable, send-failure, worker-error, malformed, and timed-out workers", async () => {
    const source = longText();
    vi.stubGlobal("Worker", undefined);
    render({ value: source, documentKey: "missing" });
    await advance(200);
    expect(latest).toMatchObject({ status: "unavailable", diagnostics: [] });

    class BrokenWorker extends FakeWorker { postMessage = vi.fn(() => { throw new Error("clone"); }); }
    vi.stubGlobal("Worker", BrokenWorker);
    render({ value: `${source}1`, documentKey: "send" });
    await advance(200);
    expect(latest.status).toBe("error");

    vi.stubGlobal("Worker", FakeWorker);
    render({ value: `${source}2`, documentKey: "worker" });
    await advance(200);
    const failed = FakeWorker.instances[FakeWorker.instances.length - 1]!;
    act(() => failed.onerror?.(new Event("error")));
    expect(latest.status).toBe("error");

    render({ value: `${source}3`, documentKey: "malformed" });
    await advance(200);
    const malformed = FakeWorker.instances[FakeWorker.instances.length - 1]!;
    act(() => malformed.reply({ requestId: malformed.request().requestId, diagnostics: "bad", truncated: false }));
    expect(latest.status).toBe("error");

    render({ value: `${source}bad-range`, documentKey: "bad-range" });
    await advance(200);
    const badRange = FakeWorker.instances[FakeWorker.instances.length - 1]!;
    act(() => badRange.reply({ requestId: badRange.request().requestId, diagnostics: [{ ...diagnostic, range: { from: -1, to: 1 } }], truncated: false }));
    expect(latest.status).toBe("error");

    render({ value: `${source}bad-related`, documentKey: "bad-related" });
    await advance(200);
    const badRelated = FakeWorker.instances[FakeWorker.instances.length - 1]!;
    act(() => badRelated.reply({ requestId: badRelated.request().requestId, diagnostics: [{ ...diagnostic, related: { range: { from: 0, to: source.length + 100 }, line: 0 } }], truncated: false }));
    expect(latest.status).toBe("error");

    render({ value: `${source}null-error`, documentKey: "null-error" });
    await advance(200);
    const missing = FakeWorker.instances[FakeWorker.instances.length - 1]!;
    act(() => missing.reply({ requestId: missing.request().requestId, error: null }));
    expect(latest.status).toBe("error");

    render({ value: `${source}empty-error`, documentKey: "empty-error" });
    await advance(200);
    const emptyError = FakeWorker.instances[FakeWorker.instances.length - 1]!;
    act(() => emptyError.reply({ requestId: emptyError.request().requestId, error: "" }));
    expect(latest.status).toBe("error");

    render({ value: `${source}4`, documentKey: "timeout" });
    await advance(200);
    const timedOut = FakeWorker.instances[FakeWorker.instances.length - 1]!;
    await advance(5_000);
    expect(latest).toMatchObject({ status: "error", diagnostics: [] });
    expect(timedOut.terminate).toHaveBeenCalledTimes(1);
  });

  it("terminates on unmount and collapses rapid edits to the latest snapshot", async () => {
    const firstSource = longText("first");
    render({ value: firstSource, documentKey: "a" });
    await advance(100);
    const finalSource = longText("final");
    render({ value: finalSource, documentKey: "a" });
    await advance(199);
    expect(FakeWorker.instances).toHaveLength(0);
    await advance(1);
    const worker = FakeWorker.instances[0];
    expect(worker.request().source).toBe(finalSource);
    act(() => root.unmount());
    expect(worker.terminate).toHaveBeenCalledTimes(1);
    root = createRoot(host);
  });

  it("rejects oversized source and title contexts without constructing a Worker", () => {
    expect(render({ value: "a".repeat(512 * 1024 + 1), documentKey: "source" })).toMatchObject({ status: "too-large", diagnostics: [] });
    expect(render({ value: "small", documentKey: "count", knownArticleTitles: Array(20_001).fill("a") })).toMatchObject({ status: "too-large", diagnostics: [] });
    expect(render({ value: "small", documentKey: "chars", knownArticleTitles: ["a".repeat(1024 * 1024 + 1)] })).toMatchObject({ status: "too-large", diagnostics: [] });
    expect(FakeWorker.instances).toHaveLength(0);
  });
});
