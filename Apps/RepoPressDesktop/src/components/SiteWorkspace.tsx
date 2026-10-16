import { useEffect, useRef } from "react";
import type { RepositorySessionSnapshot } from "../contracts/repository";
import { useI18n } from "../i18n/i18n";
import { siteWorkspaceMessages } from "../i18n/siteWorkspaceMessages";
import "./SiteWorkspace.css";

export interface SiteWorkspaceProps {
  repository: RepositorySessionSnapshot | null;
  profileName: string | null;
  busy: boolean;
  canCheck: boolean;
  canManageSites: boolean;
  /** Parent shells can suppress the initial focus when opening another surface. */
  focusOnMount?: boolean;
  onChooseRepository: () => void;
  onCheck: () => void;
  onPublish: () => void;
  onManageSites: () => void;
}

export function SiteWorkspace({ repository, profileName, busy, canCheck, canManageSites, focusOnMount = true, onChooseRepository, onCheck, onPublish, onManageSites }: SiteWorkspaceProps) {
  const { t } = useI18n(siteWorkspaceMessages);
  const title = useRef<HTMLHeadingElement>(null);
  const focusOnMountRef = useRef(focusOnMount);

  // The workspace owns initial focus. An empty dependency list deliberately
  // keeps locale and repository updates from interrupting the user's focus.
  useEffect(() => {
    if (!focusOnMountRef.current) return undefined;
    let frame = requestAnimationFrame(() => {
      const heading = title.current;
      if (!heading || !heading.isConnected) return;
      if (heading.closest("[inert]") || (heading.parentElement && "inert" in heading.parentElement && heading.parentElement.inert)) return;
      const dialog = document.querySelector<HTMLElement>('[role="dialog"][aria-modal="true"]:not([aria-hidden="true"])');
      if (dialog && !dialog.contains(heading)) return;
      heading.focus();
    });
    return () => cancelAnimationFrame(frame);
  }, []);

  const siteName = repository ? profileName ?? repository.displayName : t("尚未选择站点仓库。");
  return (
    <section id="workspace-content" className="site-workspace" aria-labelledby="site-workspace-title" tabIndex={-1}>
      <div className="site-workspace-heading">
        <div>
          <h1 id="site-workspace-title" ref={title} tabIndex={-1}>{t("站点工作区")}</h1>
          <p className="site-workspace-intro">{t("把站点检查、发布与已保存站点集中到当前工作区。")}</p>
        </div>
        {!repository && <button type="button" className="site-workspace-choose" onClick={onChooseRepository} disabled={busy}>{t("选择仓库")}</button>}
      </div>

      <section className="site-workspace-context" aria-label={t("当前站点")}>
        <div className="site-workspace-site-name">
          <span className="site-workspace-label">{t("当前站点")}</span>
          <strong>{siteName}</strong>
        </div>
        {repository ? <dl className="site-workspace-details">
          <div><dt>{t("站点类型")}</dt><dd>{repository.siteKind}</dd></div>
          <div><dt>{t("仓库根路径")}</dt><dd className="site-workspace-path" title={repository.rootPath}>{repository.rootPath}</dd></div>
        </dl> : null}
      </section>

      <p className="site-workspace-buffer-note"><strong>{t("编辑缓冲区会保留")}</strong>{t("返回写作后可继续编辑未保存的内容。")}</p>

      <div className="site-workspace-cards">
        <article className="site-workspace-card">
          <div><h2>{t("站点检查")}</h2><p className="site-workspace-card-kicker">{t("检查文章与链接")}</p><p>{t("打开检查后不会自动扫描；点击扫描按钮后才会读取本地 Markdown。")}</p></div>
          <button type="button" onClick={onCheck} disabled={busy || !repository || !canCheck}>{t("打开站点检查")}</button>
        </article>
        <article className="site-workspace-card">
          <div><h2>{t("发布中心")}</h2><p className="site-workspace-card-kicker">{t("审阅并发布")}</p><p>{t("查看发布计划，确认后再执行。")}</p></div>
          <button type="button" onClick={onPublish} disabled={busy || !repository}>{t("打开发布中心")}</button>
        </article>
        <article className="site-workspace-card">
          <div><h2>{t("站点管理")}</h2><p className="site-workspace-card-kicker">{t("管理常用站点")}</p><p>{t("保存常用站点名称，并在需要时切换已登记的仓库。")}</p></div>
          <button type="button" onClick={onManageSites} disabled={busy || !canManageSites}>{t("管理已保存站点")}</button>
        </article>
      </div>
    </section>
  );
}
