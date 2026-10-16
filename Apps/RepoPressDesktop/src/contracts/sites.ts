export interface SiteProfile {
  profileId: string;
  name: string;
  rootPath: string;
  createdAtEpochMs: number;
}

export interface SiteProfileSnapshot {
  profiles: SiteProfile[];
  revision: number;
  persistent: boolean;
  writable: boolean;
  warning: string | null;
}

export interface RegisterSiteProfileRequest {
  sessionId: string;
  name: string;
  expectedRevision: number;
}

export interface RenameSiteProfileRequest {
  profileId: string;
  name: string;
  expectedRevision: number;
}

export interface RemoveSiteProfileRequest {
  profileId: string;
  expectedRevision: number;
}
