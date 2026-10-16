import { useI18n } from "../i18n/i18n";
import type { RepositorySessionSnapshot } from "../contracts/repository";
import type { SiteProfileSnapshot, SiteProfile } from "../contracts/sites";
import "./SiteProfileCenter.css";

export interface SiteProfileSwitcherProps {
  snapshot: SiteProfileSnapshot | null;
  repository: RepositorySessionSnapshot | null;
  enabled: boolean;
  busy: boolean;
  onSelect: (profile: SiteProfile) => void;
  onManage: () => void;
}
export function SiteProfileSwitcher({ snapshot, repository, enabled, busy, onSelect, onManage }: SiteProfileSwitcherProps) {
  const { t } = useI18n();
  const current = snapshot?.profiles.find((profile) => profile.rootPath === repository?.rootPath)?.profileId ?? "";
  return <div className="site-profile-switcher">
    <label>{t("当前站点")}<select
      aria-label={t("当前站点")}
      value={current}
      onChange={(event) => {
        const profile = snapshot?.profiles.find((item) => item.profileId === event.target.value);
        if (profile) onSelect(profile);
      }}
      disabled={!enabled || busy || !snapshot || snapshot.profiles.length === 0}
    >
      <option value="">{repository ? t("当前仓库未登记") : t("未打开仓库")}</option>
      {(snapshot?.profiles ?? []).slice(0, 32).map((profile) => <option key={profile.profileId} value={profile.profileId}>{profile.name}</option>)}
    </select></label>
    <button type="button" onClick={onManage} disabled={!enabled || busy} title={!enabled ? t("站点管理当前不可用") : undefined}>{t("管理站点")}</button>
  </div>;
}
export default SiteProfileSwitcher;
