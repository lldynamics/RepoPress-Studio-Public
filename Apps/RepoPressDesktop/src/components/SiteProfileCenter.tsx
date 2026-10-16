import { useCallback, useId, useLayoutEffect, useRef, useState } from "react";
import type { RepositoryGateway, RepositorySessionSnapshot } from "../contracts/repository";
import type { SiteProfile, SiteProfileSnapshot } from "../contracts/sites";
import { useI18n, type UiTranslator } from "../i18n/i18n";
import { siteProfileMessages } from "../i18n/siteProfileMessages";
import { renderUiMessage, type UiMessage } from "../i18n/uiMessage";
import { useDrawerFocus } from "../features/workspace/drawerFocus";
import "./SiteProfileCenter.css";

export interface SiteProfileCenterProps {
  open: boolean;
  onClose: () => void;
  gateway: RepositoryGateway;
  repository: RepositorySessionSnapshot | null;
  enabled: boolean;
  onSnapshot: (snapshot: SiteProfileSnapshot) => void;
  onSelect: (profile: SiteProfile) => Promise<boolean>;
}
const empty: SiteProfileSnapshot = { profiles: [], revision: 0, persistent: false, writable: false, warning: null };
type SiteFeedback = UiMessage | { raw: string };
function renderFeedback(value: SiteFeedback, t: UiTranslator) { return "raw" in value ? value.raw : renderUiMessage(value, t); }
function message(reason: unknown): SiteFeedback {
  if (reason && typeof reason === "object" && "code" in reason) {
    if (reason.code === "site_profiles_revision_conflict") return { source: "站点列表已变化，请刷新后重试。" };
    if (reason.code === "site_profile_root_exists") return { source: "当前仓库已经登记，请刷新站点列表。" };
  }
  return reason instanceof Error && reason.message ? { raw: reason.message } : { source: "站点登记操作失败，请刷新后重试。" };
}
function validName(value: string) {
  const name = value.trim();
  return name.length > 0 && new TextEncoder().encode(name).length <= 256 && !/[\u0000-\u001f\u007f-\u009f]/.test(name);
}

export function SiteProfileCenter({ open, onClose, gateway, repository, enabled, onSnapshot, onSelect }: SiteProfileCenterProps) {
  const { t } = useI18n(siteProfileMessages);
  const root = useRef<HTMLDivElement>(null);
  const generation = useRef(0);
  const actionBusy = useRef(false);
  const titleId = useId();
  const sessionId = repository?.sessionId;
  const cancelButton = useRef<HTMLButtonElement>(null);
  const refreshButton = useRef<HTMLButtonElement>(null);
  const closeButton = useRef<HTMLButtonElement>(null);
  const publishSnapshot = useRef(onSnapshot);
  publishSnapshot.current = onSnapshot;
  const [snapshot, setSnapshot] = useState(empty);
  const [loaded, setLoaded] = useState(false);
  const [loading, setLoading] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<SiteFeedback | null>(null);
  const [status, setStatus] = useState<UiMessage | null>(null);
  const [registerName, setRegisterName] = useState("");
  const [renameName, setRenameName] = useState("");
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [confirmation, setConfirmation] = useState<{ profile: SiteProfile; revision: number } | null>(null);
  const [focusRequest, setFocusRequest] = useState<"cancel" | "refresh" | null>(null);
  const selected = snapshot.profiles.find((profile) => profile.profileId === selectedId) ?? null;
  const close = useCallback(() => { generation.current += 1; onClose(); }, [onClose]);
  useDrawerFocus(open, root, close);

  const read = useCallback(async (current: number) => {
    setLoading(true);
    setError(null);
    setStatus(null);
    try {
      const next = await gateway.getSiteProfiles();
      if (current !== generation.current) return;
      setSnapshot(next);
      setLoaded(true);
      setSelectedId(null);
      publishSnapshot.current(next);
    } catch (reason) {
      if (current === generation.current) setError(message(reason));
    } finally {
      if (current === generation.current) setLoading(false);
    }
  }, [gateway]);

  useLayoutEffect(() => {
    const current = ++generation.current;
    actionBusy.current = false;
    setSnapshot(empty);
    setLoaded(false);
    setLoading(false);
    setBusy(false);
    setError(null);
    setStatus(null);
    setRegisterName("");
    setRenameName("");
    setSelectedId(null);
    setConfirmation(null);
    setFocusRequest(null);
    if (open && enabled) void read(current);
    return () => { generation.current += 1; };
  }, [read, open, sessionId, enabled]);

  useLayoutEffect(() => {
    if (!open || !focusRequest) return;
    const current = generation.current;
    setFocusRequest(null);
    queueMicrotask(() => {
      if (current !== generation.current) return;
      const candidates = focusRequest === "cancel"
        ? [cancelButton.current, closeButton.current]
        : [refreshButton.current, closeButton.current];
      candidates.find((button) => button?.isConnected && !button.disabled)?.focus();
    });
  }, [open, focusRequest]);

  function refresh() {
    if (!open || !enabled || loading || actionBusy.current || confirmation) return;
    void read(++generation.current);
  }

  async function mutate(action: () => Promise<SiteProfileSnapshot>, confirmedRemoval = false) {
    if (!open || !enabled || actionBusy.current || loading || !snapshot.writable || (confirmation && !confirmedRemoval)) return;
    const current = ++generation.current;
    actionBusy.current = true;
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      const next = await action();
      // The registry is global. A completed write must update the parent even when
      // this panel has closed; App rejects snapshots older than its current revision.
      publishSnapshot.current(next);
      if (current !== generation.current) return;
      setSnapshot(next);
      setLoaded(true);
      setSelectedId(null);
      setConfirmation(null);
      setRegisterName("");
      setRenameName("");
      setStatus({ source: "已更新站点登记。" });
      setFocusRequest("refresh");
    } catch (reason) {
      if (current === generation.current) setError(message(reason));
    } finally {
      if (current === generation.current) { actionBusy.current = false; setBusy(false); }
    }
  }

  async function openSelected() {
    if (!selected || actionBusy.current || loading || confirmation) return;
    const current = ++generation.current;
    actionBusy.current = true;
    setBusy(true);
    setError(null);
    setStatus(null);
    try {
      const opened = await onSelect(selected);
      if (current !== generation.current) return;
      if (opened) close();
      else setError({ source: "未切换站点，当前仓库与文章仍保留。请检查工作区提示。" });
    } catch (reason) {
      if (current === generation.current) setError(message(reason));
    } finally {
      if (current === generation.current) { actionBusy.current = false; setBusy(false); }
    }
  }

  function register() {
    if (!sessionId || !validName(registerName)) return;
    void mutate(() => gateway.registerSiteProfile({ sessionId, name: registerName.trim(), expectedRevision: snapshot.revision }));
  }
  function rename() {
    if (!selected || !validName(renameName)) return;
    void mutate(() => gateway.renameSiteProfile({ profileId: selected.profileId, name: renameName.trim(), expectedRevision: snapshot.revision }));
  }
  function remove() {
    if (!confirmation) return;
    const frozen = confirmation;
    void mutate(() => gateway.removeSiteProfile({ profileId: frozen.profile.profileId, expectedRevision: frozen.revision }), true);
  }

  if (!open) return null;
  const locked = busy || loading || Boolean(confirmation);
  const canRegister = Boolean(repository && !snapshot.profiles.some((profile) => profile.rootPath === repository.rootPath));
  return <div className="site-profile-scrim" ref={root}>
    <section className="site-profile" role="dialog" aria-modal="true" aria-labelledby={titleId} aria-busy={loading || busy} tabIndex={-1}>
      <header>
        <div><h2 id={titleId}>{t("站点管理")}</h2><p>{t("保存常用站点名称，便于切换当前仓库。")}</p></div>
        <button ref={closeButton} type="button" onClick={close} aria-label={t("关闭站点管理")}>×</button>
      </header>
      <main>
        <div className="site-profile-actions"><button ref={refreshButton} type="button" onClick={refresh} disabled={locked || !enabled}>{t("刷新")}</button></div>
        {!enabled && <p className="site-profile-empty">{t("站点管理当前不可用，浏览器演示不保存本地站点。")}</p>}
        {loaded && snapshot.warning && <p className="site-profile-warning">{snapshot.warning}</p>}
        {loaded && !snapshot.writable && enabled && <p className="site-profile-warning">{t("当前存储不可写，登记和修改已禁用。")}</p>}
        {canRegister && <div className="site-profile-register">
          <label>{t("为当前仓库登记名称")}<input value={registerName} disabled={locked || !snapshot.writable} onChange={(event) => setRegisterName(event.target.value)} placeholder={t("例如：个人博客")} /></label>
          <button type="button" onClick={register} disabled={!snapshot.writable || locked || !validName(registerName) || snapshot.profiles.length >= 32}>{t("登记")}</button>
        </div>}
        {selected && <div className="site-profile-editor">
          <label>{t("名称")}<input value={renameName} disabled={locked || !snapshot.writable} onChange={(event) => setRenameName(event.target.value)} /></label>
          <button type="button" onClick={rename} disabled={!snapshot.writable || locked || !validName(renameName)}>{t("保存名称")}</button>
          <button type="button" onClick={() => void openSelected()} disabled={locked}>{t("打开此站点")}</button>
        </div>}
        <div className="site-profile-status" aria-live="polite">{loading ? t("正在读取…") : error ? renderFeedback(error, t) : status ? renderUiMessage(status, t) : ""}</div>
        <div className="site-profile-list">{snapshot.profiles.slice(0, 32).map((profile) => <button
          type="button" key={profile.profileId} className={selectedId === profile.profileId ? "selected" : ""}
          onClick={() => { setSelectedId(profile.profileId); setRenameName(profile.name); setError(null); setStatus(null); }} disabled={locked}
        ><strong>{profile.name}</strong><span>{repository?.rootPath === profile.rootPath ? t("{path} · 当前仓库", { path: profile.rootPath }) : profile.rootPath}</span></button>)}
          {loaded && snapshot.profiles.length === 0 && <p className="site-profile-empty">{t("还没有站点登记。先打开仓库，再为它登记名称。")}</p>}
        </div>
        {selected && <div className="site-profile-selected">
          <p>{t("移除登记不会删除仓库或草稿。")}</p>
          <button type="button" onClick={() => { setConfirmation({ profile: { ...selected }, revision: snapshot.revision }); setFocusRequest("cancel"); }} disabled={!snapshot.writable || locked}>{t("移除登记")}</button>
        </div>}
        <p className="site-profile-boundary">{t("每个仓库一项登记；移除保留文件/草稿；跨站点复制使用通用草稿计划流程。")}</p>
        {confirmation && <div className="site-profile-confirm" role="alertdialog" aria-label={t("确认移除登记")}>
          <p>{t("确认移除“{name}”的登记？仓库和草稿不会删除。", { name: confirmation.profile.name })}</p>
          <button ref={cancelButton} type="button" onClick={() => { setConfirmation(null); setFocusRequest("refresh"); }} disabled={busy}>{t("取消")}</button>
          <button type="button" onClick={remove} disabled={busy}>{t("确认移除")}</button>
        </div>}
      </main>
    </section>
  </div>;
}
export default SiteProfileCenter;
