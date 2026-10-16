//! Fail-closed updater configuration policy. This module never creates or persists key material.

use serde::Serialize;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum LinuxPackageKind {
    AppImage,
    Deb,
    Other,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct UpdaterConfiguration<'a> {
    pub endpoint: &'a str,
    pub public_key: &'a str,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateReadiness {
    pub package_kind: LinuxPackageKind,
    pub updater_mode: String,
    pub ready: bool,
    pub reason: String,
}

pub fn inspect_update_readiness(
    kind: LinuxPackageKind,
    config: Option<UpdaterConfiguration<'_>>,
) -> UpdateReadiness {
    match kind {
        LinuxPackageKind::AppImage => match config {
            Some(config)
                if super::update_client::configuration_is_valid(
                    config.endpoint,
                    config.public_key,
                ) =>
            {
                UpdateReadiness {
                    package_kind: kind,
                    updater_mode: "signedUpdater".into(),
                    ready: true,
                    reason: "AppImage updates can be checked explicitly and reviewed before installation."
                        .into(),
                }
            }
            Some(_) => UpdateReadiness {
                package_kind: kind,
                updater_mode: "signedUpdater".into(),
                ready: false,
                reason: "AppImage updater configuration is invalid.".into(),
            },
            None => UpdateReadiness {
                package_kind: kind,
                updater_mode: "signedUpdater".into(),
                ready: false,
                reason: "AppImage updater configuration is missing.".into(),
            },
        },
        LinuxPackageKind::Deb => UpdateReadiness {
            package_kind: kind,
            updater_mode: "manualOrRepository".into(),
            ready: true,
            reason:
                "deb updates are provided manually or through the configured package repository"
                    .into(),
        },
        LinuxPackageKind::Other => UpdateReadiness {
            package_kind: kind,
            updater_mode: "unsupported".into(),
            ready: false,
            reason: "package type has no approved updater policy".into(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    #[test]
    fn appimage_requires_real_https_configuration() {
        let missing = inspect_update_readiness(LinuxPackageKind::AppImage, None);
        assert!(!missing.ready);
        let placeholder = inspect_update_readiness(
            LinuxPackageKind::AppImage,
            Some(UpdaterConfiguration {
                endpoint: "http://updates.example.test/latest.json",
                public_key: "replace-with-public-key",
            }),
        );
        assert!(!placeholder.ready);
        let public_key = STANDARD.encode(
            "untrusted comment: minisign public key E7620F1842B4E81F\n\
             RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3",
        );
        let ready = inspect_update_readiness(
            LinuxPackageKind::AppImage,
            Some(UpdaterConfiguration {
                endpoint: "https://updates.repopress.example/latest.json",
                public_key: &public_key,
            }),
        );
        assert!(ready.ready);
        assert_eq!(ready.updater_mode, "signedUpdater");
    }

    #[test]
    fn deb_is_never_claimed_as_a_self_updating_bundle() {
        let readiness = inspect_update_readiness(LinuxPackageKind::Deb, None);
        assert!(readiness.ready);
        assert_eq!(readiness.updater_mode, "manualOrRepository");
    }
}
