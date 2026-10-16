//! Validation of the browser-extension capture protocol used by the loopback bridge.
//!
//! This module does not start the listener itself. The application state advertises readiness only
//! when this protocol validates and the P8 browser-capture service is actually running.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

// Generated from the checked-in protocol document. This is separate from the JSON embed below:
// the JSON remains the run-time source of truth while generated constants catch source drift.
mod generated {
    include!("browser_protocol_generated.rs");
}

const PROTOCOL_DOCUMENT: &str =
    include_str!("../../../../../BrowserExtension/browser-extension-protocol.json");

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ProtocolDocument {
    document_version: u32,
    active_extensions: Vec<String>,
    extensions: ExtensionIds,
    loopback: LoopbackDocument,
    capture_protocol: CaptureDocument,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExtensionIds {
    #[serde(rename = "chromiumDevelopmentID")]
    chromium_development_id: String,
    #[serde(rename = "chromeProductionID")]
    chrome_production_id: String,
    #[serde(rename = "firefoxID")]
    firefox_id: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LoopbackDocument {
    host: String,
    port: u16,
    protocol_header_name: String,
    protocol_header_value: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CaptureDocument {
    maximum_input_bytes: u64,
    status_payload_version: u32,
    routes: BTreeMap<String, Vec<String>>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BrowserProtocolSnapshot {
    pub compatible: bool,
    pub import_capability: bool,
    pub loopback_endpoint: String,
    pub protocol_header_name: String,
    pub protocol_header_value: String,
    pub maximum_input_bytes: u64,
    pub allowed_origins: Vec<String>,
    pub reason: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct BrowserProtocol {
    allowed_origins: BTreeSet<String>,
    maximum_input_bytes: u64,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum BrowserProtocolError {
    InvalidDocument,
    IncompatibleDocument,
}

impl std::fmt::Display for BrowserProtocolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::InvalidDocument => "browser protocol document is invalid",
            Self::IncompatibleDocument => "browser protocol document is incompatible",
        })
    }
}

impl std::error::Error for BrowserProtocolError {}

impl BrowserProtocol {
    pub fn load_embedded() -> Result<Self, BrowserProtocolError> {
        Self::from_json(PROTOCOL_DOCUMENT)
    }

    /// Parses a document only after every security-significant field matches the protocol owned
    /// by this desktop release. Future document versions must be explicitly supported.
    pub fn from_json(document: &str) -> Result<Self, BrowserProtocolError> {
        let parsed: ProtocolDocument =
            serde_json::from_str(document).map_err(|_| BrowserProtocolError::InvalidDocument)?;
        if parsed.document_version != 1
            || parsed
                .active_extensions
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>()
                .as_slice()
                != generated::ACTIVE_BROWSER_EXTENSIONS
            || parsed.loopback.host != generated::LOOPBACK_HOST
            || parsed.loopback.port != generated::LOOPBACK_PORT
            || parsed.loopback.protocol_header_name != generated::LOOPBACK_PROTOCOL_HEADER_NAME
            || parsed.loopback.protocol_header_value != generated::LOOPBACK_PROTOCOL_HEADER_VALUE
            || parsed.capture_protocol.maximum_input_bytes != generated::MAXIMUM_INPUT_BYTES as u64
            || parsed.capture_protocol.status_payload_version != generated::STATUS_PAYLOAD_VERSION
            || parsed.extensions.chromium_development_id
                != generated::CHROMIUM_DEVELOPMENT_EXTENSION_ID
            || parsed.extensions.chrome_production_id
                != generated::CHROME_PRODUCTION_EXTENSION_ID.unwrap_or_default()
            || parsed.extensions.firefox_id != generated::FIREFOX_EXTENSION_ID
            || !valid_extension_id(&parsed.extensions.chromium_development_id)
            || !valid_extension_id(&parsed.extensions.chrome_production_id)
            || !valid_firefox_id(&parsed.extensions.firefox_id)
            || !routes_match(&parsed.capture_protocol.routes)
        {
            return Err(BrowserProtocolError::IncompatibleDocument);
        }

        let allowed_origins = BTreeSet::from([
            format!(
                "chrome-extension://{}",
                parsed.extensions.chromium_development_id
            ),
            format!(
                "chrome-extension://{}",
                parsed.extensions.chrome_production_id
            ),
            // Firefox's runtime origin is normally an opaque UUID. The known extension ID is
            // used as the native-policy origin until a signed-host integration supplies UUIDs.
            format!("moz-extension://{}", parsed.extensions.firefox_id),
        ]);
        Ok(Self {
            allowed_origins,
            maximum_input_bytes: generated::MAXIMUM_INPUT_BYTES as u64,
        })
    }

    pub fn snapshot(&self) -> BrowserProtocolSnapshot {
        BrowserProtocolSnapshot {
            compatible: true,
            // Runtime readiness is still gated on the listener and persistent sink in AppState.
            import_capability: true,
            loopback_endpoint: "http://127.0.0.1:17843".to_string(),
            protocol_header_name: "X-RepoPress-Protocol".to_string(),
            protocol_header_value: "1".to_string(),
            maximum_input_bytes: self.maximum_input_bytes,
            allowed_origins: self.allowed_origins.iter().cloned().collect(),
            reason: None,
        }
    }

    #[cfg(test)]
    pub fn is_allowed_origin(&self, origin: &str) -> bool {
        self.allowed_origins.contains(origin)
    }

    #[cfg(test)]
    pub fn allows_request(
        &self,
        origin: &str,
        route: &str,
        method: &str,
        protocol_header_name: Option<&str>,
        protocol_header_value: Option<&str>,
        payload_bytes: u64,
    ) -> bool {
        self.is_allowed_origin(origin)
            && protocol_header_name == Some(generated::LOOPBACK_PROTOCOL_HEADER_NAME)
            && protocol_header_value == Some(generated::LOOPBACK_PROTOCOL_HEADER_VALUE)
            && payload_bytes <= self.maximum_input_bytes
            && generated::ALLOWED_ROUTES
                .iter()
                .find(|(path, _)| *path == route)
                .is_some_and(|(_, methods)| methods.contains(&method))
    }
}

fn routes_match(routes: &BTreeMap<String, Vec<String>>) -> bool {
    if routes.len() != generated::ALLOWED_ROUTES.len() {
        return false;
    }
    generated::ALLOWED_ROUTES
        .iter()
        .all(|(path, expected_methods)| {
            let Some(methods) = routes.get(*path) else {
                return false;
            };
            methods.len() == expected_methods.len()
                && methods
                    .iter()
                    .all(|method| expected_methods.contains(&method.as_str()))
        })
}

fn valid_extension_id(value: &str) -> bool {
    value.len() == 32
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() && (b'a'..=b'p').contains(&byte))
}

fn valid_firefox_id(value: &str) -> bool {
    value.len() <= 255 && value.contains('@') && !value.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embeds_and_validates_the_checked_in_protocol() {
        let protocol = BrowserProtocol::load_embedded().unwrap();
        let snapshot = protocol.snapshot();
        assert!(snapshot.compatible);
        assert!(snapshot.import_capability);
        assert_eq!(snapshot.loopback_endpoint, "http://127.0.0.1:17843");
    }

    #[test]
    fn accepts_only_registered_extension_origins() {
        let protocol = BrowserProtocol::load_embedded().unwrap();
        assert!(protocol.is_allowed_origin("chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam"));
        assert!(protocol.is_allowed_origin("chrome-extension://ginjcibepmeobaaadmfiagigcpcebmcc"));
        assert!(protocol.is_allowed_origin("moz-extension://knowledge-capture@jinfang.local"));
        assert!(!protocol.is_allowed_origin("https://example.test"));
    }

    #[test]
    fn rejects_unknown_routes_methods_and_missing_protocol_header() {
        let protocol = BrowserProtocol::load_embedded().unwrap();
        let origin = "chrome-extension://lnibkmfhfikfbkeehcjbiaalhkiankam";
        assert!(protocol.allows_request(
            origin,
            "/v1/import",
            "POST",
            Some("X-RepoPress-Protocol"),
            Some("1"),
            10
        ));
        assert!(!protocol.allows_request(
            origin,
            "/v1/import",
            "GET",
            Some("X-RepoPress-Protocol"),
            Some("1"),
            10
        ));
        assert!(!protocol.allows_request(
            origin,
            "/v1/unknown",
            "POST",
            Some("X-RepoPress-Protocol"),
            Some("1"),
            10
        ));
        assert!(!protocol.allows_request(origin, "/v1/import", "POST", None, Some("1"), 10));
    }
}
