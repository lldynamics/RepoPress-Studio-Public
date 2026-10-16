use super::*;

const OPML_PRIVACY_MAX_BYTES: usize = 4 * 1024 * 1024;
const OPML_PRIVACY_MAX_OUTLINES: usize = 10_000;
const OPML_PRIVACY_MAX_DEPTH: usize = 256;
const MAX_REPORTED_PARAMETER_NAMES: usize = 32;
const MAX_REPORTED_PARAMETER_NAME_CHARS: usize = 64;
const MAX_DISPLAY_URL_CHARS: usize = 2_048;
const MAX_REVIEWED_TITLE_BYTES: usize = 4 * 1024;
const MAX_TITLE_URL_CHARS: usize = 8_192;
const REDACTED_QUERY_VALUE: &str = "REDACTED";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssOpmlFinding {
    pub index: u32,
    pub location: String,
    pub display_url: String,
    pub parameter_names: Vec<String>,
    pub contains_user_info: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssOpmlReview {
    pub direction: String,
    pub fingerprint: String,
    pub total_count: u32,
    pub affected_count: u32,
    pub blocked_count: u32,
    pub findings: Vec<RssOpmlFinding>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RssOpmlExecution {
    pub opml: Option<String>,
    pub imported_count: u32,
    pub skipped_count: u32,
    pub exported_count: u32,
    pub excluded_count: u32,
}

#[derive(Clone, Debug)]
struct OpmlEntry {
    id: Option<String>,
    title: String,
    feed_url: String,
    site_url: Option<String>,
}

#[derive(Default)]
struct EntryAssessment {
    findings: Vec<RssOpmlFinding>,
    affected: bool,
    blocked: bool,
}

pub fn credential_parameter(name: &str) -> bool {
    let normalized = name
        .chars()
        .filter(|character| character.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect::<String>();
    normalized.contains("token")
        || normalized.contains("signature")
        || normalized.contains("credential")
        || normalized.contains("authorization")
        || normalized.contains("authentication")
        || normalized.contains("password")
        || normalized.contains("passwd")
        || normalized.contains("secret")
        || normalized.contains("apikey")
        || normalized.contains("accesskey")
        || normalized.contains("privatekey")
        || normalized.contains("clientkey")
        || normalized.contains("consumerkey")
        || normalized.contains("subscriptionkey")
        || normalized.starts_with("oauth")
        || (normalized.starts_with("auth") && !normalized.starts_with("author"))
        || matches!(normalized.as_str(), "key" | "sig" | "jwt")
}

pub(super) fn safe_display_url(url: &Url) -> String {
    let mut displayed = url.clone();
    let _ = displayed.set_username("");
    let _ = displayed.set_password(None);
    displayed.set_fragment(None);
    if displayed.query().is_some() {
        let pairs = displayed
            .query_pairs()
            .map(|(name, _)| (name.into_owned(), REDACTED_QUERY_VALUE.to_owned()))
            .collect::<Vec<_>>();
        displayed.query_pairs_mut().clear().extend_pairs(pairs);
    }
    let rendered = displayed.to_string();
    if rendered.chars().count() <= MAX_DISPLAY_URL_CHARS {
        rendered
    } else {
        let mut bounded = rendered
            .chars()
            .take(MAX_DISPLAY_URL_CHARS)
            .collect::<String>();
        bounded.push('…');
        bounded
    }
}

impl RssReaderStore {
    pub fn review_opml(
        &self,
        direction: String,
        opml: Option<String>,
    ) -> CommandResult<RssOpmlReview> {
        match direction.as_str() {
            "import" => {
                let source = required_import_opml(opml)?;
                let entries = parse_privacy_opml(&source)?;
                let connection = self.db.lock().map_err(|_| lock_err())?;
                let allow_private = preferences_from(&connection)?.private_network_access_enabled;
                Ok(build_review(
                    "import",
                    import_fingerprint(&source, allow_private),
                    &entries,
                    allow_private,
                ))
            }
            "export" => {
                require_export_without_opml(opml)?;
                let connection = self.db.lock().map_err(|_| lock_err())?;
                let entries = load_export_entries(&connection)?;
                let allow_private = preferences_from(&connection)?.private_network_access_enabled;
                Ok(build_review(
                    "export",
                    export_fingerprint(&entries, allow_private),
                    &entries,
                    allow_private,
                ))
            }
            _ => Err(CommandError::new(
                "rss_opml_direction_invalid",
                "OPML direction must be import or export.",
            )),
        }
    }

    pub fn execute_opml(
        &self,
        direction: String,
        opml: Option<String>,
        fingerprint: String,
        action: String,
    ) -> CommandResult<RssOpmlExecution> {
        let action = PrivacyAction::parse(&action)?;
        match direction.as_str() {
            "import" => {
                let source = required_import_opml(opml)?;
                let entries = parse_privacy_opml(&source)?;
                self.execute_opml_import(entries, action, &source, &fingerprint)
            }
            "export" => {
                require_export_without_opml(opml)?;
                self.execute_opml_export(&fingerprint, action)
            }
            _ => Err(CommandError::new(
                "rss_opml_direction_invalid",
                "OPML direction must be import or export.",
            )),
        }
    }

    fn execute_opml_import(
        &self,
        entries: Vec<OpmlEntry>,
        action: PrivacyAction,
        source: &str,
        expected_fingerprint: &str,
    ) -> CommandResult<RssOpmlExecution> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let transaction = connection.unchecked_transaction().map_err(db_err)?;
        let allow_private = preferences_from(&transaction)?.private_network_access_enabled;
        if !constant_time_text_eq(
            &import_fingerprint(source, allow_private),
            expected_fingerprint,
        ) {
            return Err(stale_review_error());
        }
        let mut imported_count = 0_u32;
        let mut skipped_count = 0_u32;
        let mut excluded_count = 0_u32;

        for (index, entry) in entries.into_iter().enumerate() {
            let assessment = assess_entry(index, &entry, allow_private);
            if action == PrivacyAction::Exclude && assessment.affected {
                excluded_count = excluded_count.saturating_add(1);
                continue;
            }
            if assessment.blocked {
                return Err(redaction_blocked_error());
            }
            let prepared = prepare_entry(entry, action, allow_private)?;
            let feed = validate_url(&prepared.feed_url, allow_private)?;
            let site = prepared
                .site_url
                .as_deref()
                .map(|value| validate_url(value, allow_private).map(|url| url.to_string()))
                .transpose()?;
            let fallback = feed.host_str().unwrap_or("RSS feed");
            let title = clean_text(prepared.title);
            let changed = transaction
                .execute(
                    "INSERT OR IGNORE INTO feeds(id,url,title,site_url,added_at) VALUES(?,?,?,?,?)",
                    params![
                        Uuid::new_v4().to_string(),
                        feed.to_string(),
                        nonempty_or(&title, fallback),
                        site,
                        now()
                    ],
                )
                .map_err(db_err)?;
            if changed == 1 {
                imported_count = imported_count.saturating_add(1);
            } else {
                skipped_count = skipped_count.saturating_add(1);
            }
        }
        transaction.commit().map_err(db_err)?;
        Ok(RssOpmlExecution {
            opml: None,
            imported_count,
            skipped_count,
            exported_count: 0,
            excluded_count,
        })
    }

    fn execute_opml_export(
        &self,
        expected_fingerprint: &str,
        action: PrivacyAction,
    ) -> CommandResult<RssOpmlExecution> {
        let connection = self.db.lock().map_err(|_| lock_err())?;
        let entries = load_export_entries(&connection)?;
        let allow_private = preferences_from(&connection)?.private_network_access_enabled;
        if !constant_time_text_eq(
            &export_fingerprint(&entries, allow_private),
            expected_fingerprint,
        ) {
            return Err(stale_review_error());
        }
        let mut prepared = Vec::with_capacity(entries.len());
        let mut excluded_count = 0_u32;
        for (index, entry) in entries.into_iter().enumerate() {
            let assessment = assess_entry(index, &entry, allow_private);
            if action == PrivacyAction::Exclude && assessment.affected {
                excluded_count = excluded_count.saturating_add(1);
                continue;
            }
            if assessment.blocked {
                return Err(redaction_blocked_error());
            }
            prepared.push(prepare_entry(entry, action, allow_private)?);
        }
        let exported_count = u32::try_from(prepared.len()).unwrap_or(u32::MAX);
        Ok(RssOpmlExecution {
            opml: Some(serialize_opml(&prepared)),
            imported_count: 0,
            skipped_count: 0,
            exported_count,
            excluded_count,
        })
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum PrivacyAction {
    Redact,
    Exclude,
}

impl PrivacyAction {
    fn parse(value: &str) -> CommandResult<Self> {
        match value {
            "redact" => Ok(Self::Redact),
            "exclude" => Ok(Self::Exclude),
            _ => Err(CommandError::new(
                "rss_opml_action_invalid",
                "OPML privacy action must be redact or exclude.",
            )),
        }
    }
}

fn required_import_opml(opml: Option<String>) -> CommandResult<String> {
    opml.ok_or_else(|| {
        CommandError::new(
            "rss_opml_invalid",
            "Import review requires an OPML document.",
        )
    })
}

fn require_export_without_opml(opml: Option<String>) -> CommandResult<()> {
    if opml.is_none() {
        Ok(())
    } else {
        Err(CommandError::new(
            "rss_opml_invalid",
            "Export review does not accept an OPML document.",
        ))
    }
}

fn stale_review_error() -> CommandError {
    CommandError::new(
        "rss_opml_review_stale",
        "The OPML review no longer matches the requested operation.",
    )
}

fn redaction_blocked_error() -> CommandError {
    CommandError::new(
        "rss_opml_redaction_blocked",
        "This OPML contains an address that cannot be safely redacted. Exclude the affected subscription instead.",
    )
}

fn build_review(
    direction: &str,
    fingerprint: String,
    entries: &[OpmlEntry],
    allow_private: bool,
) -> RssOpmlReview {
    let mut findings = Vec::new();
    let mut affected_count = 0_u32;
    let mut blocked_count = 0_u32;
    for (index, entry) in entries.iter().enumerate() {
        let assessment = assess_entry(index, entry, allow_private);
        if assessment.affected {
            affected_count = affected_count.saturating_add(1);
        }
        if assessment.blocked {
            blocked_count = blocked_count.saturating_add(1);
        }
        findings.extend(assessment.findings);
    }
    RssOpmlReview {
        direction: direction.to_owned(),
        fingerprint,
        total_count: u32::try_from(entries.len()).unwrap_or(u32::MAX),
        affected_count,
        blocked_count,
        findings,
    }
}

fn assess_entry(index: usize, entry: &OpmlEntry, allow_private: bool) -> EntryAssessment {
    let mut result = EntryAssessment::default();
    assess_url(index, "feed", &entry.feed_url, allow_private, &mut result);
    if let Some(site_url) = entry.site_url.as_deref() {
        assess_url(index, "site", site_url, allow_private, &mut result);
    }
    assess_title(index, &entry.title, &mut result);
    result
}

fn assess_title(index: usize, title: &str, result: &mut EntryAssessment) {
    let risks = match title_url_risks(title) {
        Ok(risks) => risks,
        Err(()) => {
            result.affected = true;
            result.blocked = true;
            result.findings.push(RssOpmlFinding {
                index: u32::try_from(index).unwrap_or(u32::MAX),
                location: "title".to_owned(),
                display_url: "Title URL (cannot be safely displayed)".to_owned(),
                parameter_names: Vec::new(),
                contains_user_info: false,
            });
            return;
        }
    };
    for url in risks {
        let contains_user_info = !url.username().is_empty() || url.password().is_some();
        let parameter_names = credential_parameter_names(&url);
        result.affected = true;
        result.findings.push(RssOpmlFinding {
            index: u32::try_from(index).unwrap_or(u32::MAX),
            location: "title".to_owned(),
            display_url: safe_display_url(&url),
            parameter_names,
            contains_user_info,
        });
    }
}

fn title_url_risks(title: &str) -> Result<Vec<Url>, ()> {
    if title.len() > MAX_REVIEWED_TITLE_BYTES {
        return Err(());
    }
    let lower = title.to_ascii_lowercase();
    let mut cursor = 0;
    let mut risks = Vec::new();
    while cursor < lower.len() {
        let Some(start) = next_title_url_start(&lower, cursor) else {
            break;
        };
        let delimiter_end = title[start..]
            .char_indices()
            .find_map(|(offset, character)| {
                (offset > 0 && title_url_delimiter(character)).then_some(start + offset)
            })
            .unwrap_or(title.len());
        let next_start = next_title_url_start(&lower, start.saturating_add("https://".len()))
            .unwrap_or(title.len());
        let end = delimiter_end.min(next_start);
        let raw = &title[start..end];
        if raw.chars().count() > MAX_TITLE_URL_CHARS {
            return Err(());
        }
        let url = Url::parse(raw).map_err(|_| ())?;
        if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
            return Err(());
        }
        let contains_user_info = !url.username().is_empty() || url.password().is_some();
        if contains_user_info || !credential_parameter_names(&url).is_empty() {
            risks.push(url);
        }
        cursor = end.max(start.saturating_add(1));
    }
    Ok(risks)
}

fn next_title_url_start(lower: &str, cursor: usize) -> Option<usize> {
    let http = lower[cursor..]
        .find("http://")
        .map(|offset| cursor + offset);
    let https = lower[cursor..]
        .find("https://")
        .map(|offset| cursor + offset);
    match (http, https) {
        (Some(http), Some(https)) => Some(http.min(https)),
        (Some(http), None) => Some(http),
        (None, Some(https)) => Some(https),
        (None, None) => None,
    }
}

fn title_url_delimiter(character: char) -> bool {
    character.is_whitespace()
        || matches!(
            character,
            '<' | '>'
                | '"'
                | '\''
                | '('
                | ')'
                | '['
                | ']'
                | '{'
                | '}'
                | '，'
                | '。'
                | '；'
                | '：'
                | '！'
                | '？'
                | '【'
                | '】'
                | '《'
                | '》'
                | '「'
                | '」'
                | '『'
                | '』'
        )
}

fn assess_url(
    index: usize,
    location: &str,
    raw_url: &str,
    allow_private: bool,
    result: &mut EntryAssessment,
) {
    let parsed = Url::parse(raw_url).ok();
    let contains_user_info = parsed
        .as_ref()
        .is_some_and(|url| !url.username().is_empty() || url.password().is_some());
    let parameter_names = parsed
        .as_ref()
        .map(credential_parameter_names)
        .unwrap_or_default();
    let candidate = parsed.as_ref().map(redact_credential_query_values);
    let valid_after_redaction = !contains_user_info
        && candidate
            .as_ref()
            .is_some_and(|url| validate_url(url.as_str(), allow_private).is_ok());
    let affected = contains_user_info || !parameter_names.is_empty() || !valid_after_redaction;
    if !affected {
        return;
    }
    result.affected = true;
    result.blocked |= !valid_after_redaction;
    result.findings.push(RssOpmlFinding {
        index: u32::try_from(index).unwrap_or(u32::MAX),
        location: location.to_owned(),
        display_url: parsed
            .as_ref()
            .map(safe_display_url)
            .unwrap_or_else(|| "Subscription URL (cannot be safely displayed)".to_owned()),
        parameter_names,
        contains_user_info,
    });
}

fn credential_parameter_names(url: &Url) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut names = Vec::new();
    for (name, _) in url.query_pairs() {
        if !credential_parameter(&name) {
            continue;
        }
        let deduplication_key = name.to_lowercase();
        if !seen.insert(deduplication_key) {
            continue;
        }
        names.push(safe_parameter_name(&name));
        if names.len() >= MAX_REPORTED_PARAMETER_NAMES {
            break;
        }
    }
    names
}

fn safe_parameter_name(name: &str) -> String {
    let bounded = name
        .chars()
        .take(MAX_REPORTED_PARAMETER_NAME_CHARS)
        .collect::<String>();
    if !bounded.is_empty()
        && bounded
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || "_.-".contains(character))
    {
        bounded
    } else {
        "<credential-parameter>".to_owned()
    }
}

fn redact_credential_query_values(url: &Url) -> Url {
    let mut redacted = url.clone();
    if redacted.query().is_none() {
        return redacted;
    }
    let pairs = redacted
        .query_pairs()
        .map(|(name, value)| {
            let value = if credential_parameter(&name) {
                REDACTED_QUERY_VALUE.to_owned()
            } else {
                value.into_owned()
            };
            (name.into_owned(), value)
        })
        .collect::<Vec<_>>();
    redacted.query_pairs_mut().clear().extend_pairs(pairs);
    redacted
}

fn prepare_entry(
    mut entry: OpmlEntry,
    action: PrivacyAction,
    allow_private: bool,
) -> CommandResult<OpmlEntry> {
    let title_affected = !title_url_risks(&entry.title)
        .map_err(|_| redaction_blocked_error())?
        .is_empty();
    if action == PrivacyAction::Redact {
        let feed = Url::parse(&entry.feed_url).map_err(|_| redaction_blocked_error())?;
        if !feed.username().is_empty() || feed.password().is_some() {
            return Err(redaction_blocked_error());
        }
        entry.feed_url = redact_credential_query_values(&feed).to_string();
        if let Some(site_url) = entry.site_url.as_deref() {
            let site = Url::parse(site_url).map_err(|_| redaction_blocked_error())?;
            if !site.username().is_empty() || site.password().is_some() {
                return Err(redaction_blocked_error());
            }
            entry.site_url = Some(redact_credential_query_values(&site).to_string());
        }
        let validated_feed = validate_url(&entry.feed_url, allow_private)?;
        if title_affected {
            entry.title = validated_feed.host_str().unwrap_or("RSS feed").to_owned();
        }
    }
    validate_url(&entry.feed_url, allow_private)?;
    if let Some(site_url) = entry.site_url.as_deref() {
        validate_url(site_url, allow_private)?;
    }
    Ok(entry)
}

fn parse_privacy_opml(xml: &str) -> CommandResult<Vec<OpmlEntry>> {
    if xml.is_empty() {
        return Err(CommandError::new("rss_opml_invalid", "OPML is empty."));
    }
    if xml.len() > OPML_PRIVACY_MAX_BYTES {
        return Err(CommandError::new(
            "rss_opml_too_large",
            "OPML exceeds the 4 MiB limit.",
        ));
    }
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let mut stack = Vec::<String>::new();
    let mut root_seen = false;
    let mut body_depth = None;
    let mut body_seen = false;
    let mut outline_count = 0_usize;
    let mut entries = Vec::new();

    loop {
        match reader.read_event() {
            Ok(Event::DocType(_)) => {
                return Err(CommandError::new(
                    "rss_opml_invalid",
                    "OPML may not contain DTDs or entity declarations.",
                ))
            }
            Ok(Event::Start(event)) => {
                let name = local_name(event.name().as_ref());
                if stack.is_empty() {
                    if root_seen || name != "opml" {
                        return Err(CommandError::new(
                            "rss_opml_invalid",
                            "OPML root must be opml.",
                        ));
                    }
                    root_seen = true;
                }
                stack.push(name.clone());
                if stack.len() > OPML_PRIVACY_MAX_DEPTH {
                    return Err(CommandError::new(
                        "rss_opml_invalid",
                        "OPML nesting is too deep.",
                    ));
                }
                if name == "body" && stack.len() == 2 && stack.first().is_some_and(|v| v == "opml")
                {
                    body_depth = Some(stack.len());
                    body_seen = true;
                }
                if name == "outline" {
                    outline_count = checked_outline_count(outline_count)?;
                    collect_privacy_outline(&event, body_depth.is_some(), &mut entries)?;
                }
            }
            Ok(Event::Empty(event)) => {
                let name = local_name(event.name().as_ref());
                let event_depth = stack.len().saturating_add(1);
                if event_depth > OPML_PRIVACY_MAX_DEPTH {
                    return Err(CommandError::new(
                        "rss_opml_invalid",
                        "OPML nesting is too deep.",
                    ));
                }
                if stack.is_empty() {
                    if root_seen || name != "opml" {
                        return Err(CommandError::new(
                            "rss_opml_invalid",
                            "OPML root must be opml.",
                        ));
                    }
                    root_seen = true;
                }
                if name == "body" && event_depth == 2 && stack.first().is_some_and(|v| v == "opml")
                {
                    body_seen = true;
                }
                if name == "outline" {
                    outline_count = checked_outline_count(outline_count)?;
                    collect_privacy_outline(&event, body_depth.is_some(), &mut entries)?;
                }
            }
            Ok(Event::End(event)) => {
                let name = local_name(event.name().as_ref());
                if stack.last().is_none_or(|last| last != &name) {
                    return Err(CommandError::new(
                        "rss_opml_invalid",
                        "OPML tags are unbalanced.",
                    ));
                }
                if body_depth == Some(stack.len()) && name == "body" {
                    body_depth = None;
                }
                stack.pop();
            }
            Ok(Event::Text(text)) => {
                let bytes: &[u8] = text.as_ref();
                if stack.is_empty() && !bytes.iter().all(u8::is_ascii_whitespace) {
                    return Err(CommandError::new(
                        "rss_opml_invalid",
                        "OPML contains content outside its root element.",
                    ));
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => return Err(CommandError::new("rss_opml_invalid", "Invalid OPML XML.")),
            _ => {}
        }
    }
    if !root_seen || !body_seen || !stack.is_empty() || entries.is_empty() {
        return Err(CommandError::new(
            "rss_opml_invalid",
            "OPML must contain a complete root, body, and at least one feed.",
        ));
    }
    Ok(entries)
}

fn checked_outline_count(current: usize) -> CommandResult<usize> {
    let next = current.saturating_add(1);
    if next > OPML_PRIVACY_MAX_OUTLINES {
        Err(CommandError::new(
            "rss_opml_too_large",
            "OPML contains too many outlines.",
        ))
    } else {
        Ok(next)
    }
}

fn collect_privacy_outline(
    event: &quick_xml::events::BytesStart<'_>,
    in_body: bool,
    entries: &mut Vec<OpmlEntry>,
) -> CommandResult<()> {
    if !in_body {
        return Ok(());
    }
    let feed_url = attribute_any(event, &["xmlurl", "url"])?;
    let Some(feed_url) = feed_url
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty())
    else {
        return Ok(());
    };
    let text = attribute_any(event, &["text"])?;
    let title = text
        .or(attribute_any(event, &["title"])?)
        .unwrap_or_default()
        .trim()
        .to_owned();
    let site_url = attribute_any(event, &["htmlurl"])?
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());
    entries.push(OpmlEntry {
        id: None,
        title,
        feed_url,
        site_url,
    });
    Ok(())
}

fn attribute_any(
    event: &quick_xml::events::BytesStart<'_>,
    wanted: &[&str],
) -> CommandResult<Option<String>> {
    let mut found = None;
    for attribute in event.attributes() {
        let attribute = attribute
            .map_err(|_| CommandError::new("rss_opml_invalid", "OPML attribute was invalid."))?;
        let name = local_name(attribute.key.as_ref());
        if !wanted.iter().any(|wanted_name| name == *wanted_name) {
            continue;
        }
        if found.is_some() {
            return Err(CommandError::new(
                "rss_opml_invalid",
                "OPML contains duplicate URL or title attributes.",
            ));
        }
        let value = attribute
            .unescape_value()
            .map_err(|_| CommandError::new("rss_opml_invalid", "OPML attribute was invalid."))?;
        found = Some(value.into_owned());
    }
    Ok(found)
}

fn load_export_entries(connection: &Connection) -> CommandResult<Vec<OpmlEntry>> {
    let mut statement = connection
        .prepare("SELECT id,title,url,site_url FROM feeds ORDER BY title,id")
        .map_err(db_err)?;
    let entries = statement
        .query_map([], |row| {
            Ok(OpmlEntry {
                id: Some(row.get(0)?),
                title: row.get(1)?,
                feed_url: row.get(2)?,
                site_url: row.get(3)?,
            })
        })
        .map_err(db_err)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(db_err)?;
    Ok(entries)
}

fn import_fingerprint(source: &str, allow_private: bool) -> String {
    let mut hasher = Sha256::new();
    hash_field(&mut hasher, b"rss-opml-privacy-v1");
    hash_field(&mut hasher, b"import");
    hash_field(&mut hasher, &[u8::from(allow_private)]);
    hash_field(&mut hasher, source.as_bytes());
    hex_digest(&hasher.finalize())
}

fn export_fingerprint(entries: &[OpmlEntry], allow_private: bool) -> String {
    let mut hasher = Sha256::new();
    hash_field(&mut hasher, b"rss-opml-privacy-v1");
    hash_field(&mut hasher, b"export");
    hash_field(&mut hasher, &[u8::from(allow_private)]);
    hash_field(&mut hasher, &entries.len().to_be_bytes());
    for entry in entries {
        hash_optional_field(&mut hasher, entry.id.as_deref());
        hash_field(&mut hasher, entry.title.as_bytes());
        hash_field(&mut hasher, entry.feed_url.as_bytes());
        hash_optional_field(&mut hasher, entry.site_url.as_deref());
    }
    hex_digest(&hasher.finalize())
}

fn hash_field(hasher: &mut Sha256, value: &[u8]) {
    hasher.update(value.len().to_be_bytes());
    hasher.update(value);
}

fn hash_optional_field(hasher: &mut Sha256, value: Option<&str>) {
    match value {
        Some(value) => {
            hasher.update([1]);
            hash_field(hasher, value.as_bytes());
        }
        None => hasher.update([0]),
    }
}

fn hex_digest(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn constant_time_text_eq(left: &str, right: &str) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.as_bytes()
        .iter()
        .zip(right.as_bytes())
        .fold(0_u8, |difference, (left, right)| {
            difference | (left ^ right)
        })
        == 0
}

fn serialize_opml(entries: &[OpmlEntry]) -> String {
    let mut output = String::from(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><opml version=\"2.0\"><head><title>RepoPress RSS</title></head><body>",
    );
    for entry in entries {
        output.push_str("<outline text=\"");
        output.push_str(&escape_xml(&safe_xml_text(&entry.title)));
        output.push_str("\" title=\"");
        output.push_str(&escape_xml(&safe_xml_text(&entry.title)));
        output.push_str("\" type=\"rss\" xmlUrl=\"");
        output.push_str(&escape_xml(&entry.feed_url));
        output.push('"');
        if let Some(site_url) = entry.site_url.as_deref() {
            output.push_str(" htmlUrl=\"");
            output.push_str(&escape_xml(site_url));
            output.push('"');
        }
        output.push_str("/>");
    }
    output.push_str("</body></opml>");
    output
}

fn safe_xml_text(value: &str) -> String {
    value
        .chars()
        .filter(|character| {
            matches!(*character, '\u{9}' | '\u{a}' | '\u{d}')
                || matches!(*character as u32, 0x20..=0xd7ff | 0xe000..=0xfffd | 0x10000..=0x10ffff)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn document(outlines: &str) -> String {
        format!("<?xml version=\"1.0\"?><opml version=\"2.0\"><body>{outlines}</body></opml>")
    }

    fn feed_count(store: &RssReaderStore) -> i64 {
        store
            .db
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM feeds", [], |row| row.get(0))
            .unwrap()
    }

    #[test]
    fn detects_encoded_case_mixed_keys_and_ignores_author() {
        let url = Url::parse(
            "https://example.com/feed?Api%5FToKeN=first&api_token=second&author=name&keyboard=ok",
        )
        .unwrap();
        assert_eq!(credential_parameter_names(&url), vec!["Api_ToKeN"]);
        assert!(credential_parameter("X-Amz-Signature"));
        assert!(!credential_parameter("author"));
        assert!(!credential_parameter("keyboard"));
        assert!(
            title_url_risks("Author https://example.com/post?author=name")
                .unwrap()
                .is_empty()
        );
        let adjacent =
            title_url_risks("https://example.com/safe,https://alice:password@example.com/private")
                .unwrap();
        assert_eq!(adjacent.len(), 1);
        assert_eq!(adjacent[0].username(), "alice");
    }

    #[test]
    fn review_scans_feed_and_site_without_retaining_values_or_titles() {
        let store = RssReaderStore::default();
        let xml = document(
            "<outline text=\"title-secret-token-value\" xmlUrl=\"https://example.com/feed?api_key=feed-secret&amp;topic=swift\" htmlUrl=\"https://example.com/?authToken=site-secret&amp;lang=zh\"/>",
        );
        let review = store.review_opml("import".into(), Some(xml)).unwrap();
        assert_eq!(review.total_count, 1);
        assert_eq!(review.affected_count, 1);
        assert_eq!(review.findings.len(), 2);
        let rendered = serde_json::to_string(&review).unwrap();
        for secret in [
            "feed-secret",
            "site-secret",
            "title-secret-token-value",
            "topic=swift",
            "lang=zh",
        ] {
            assert!(!rendered.contains(secret));
        }
        assert!(rendered.contains("REDACTED"));
    }

    #[test]
    fn review_does_not_mutate_and_redact_import_is_atomic_on_userinfo() {
        let store = RssReaderStore::default();
        let xml = document(
            "<outline text=\"Safe\" xmlUrl=\"https://example.com/safe\"/><outline text=\"Blocked\" xmlUrl=\"https://alice:secret@example.com/feed\"/>",
        );
        let review = store
            .review_opml("import".into(), Some(xml.clone()))
            .unwrap();
        assert_eq!(feed_count(&store), 0);
        assert_eq!(review.blocked_count, 1);
        let error = store
            .execute_opml(
                "import".into(),
                Some(xml),
                review.fingerprint,
                "redact".into(),
            )
            .unwrap_err();
        assert_eq!(error.code, "rss_opml_redaction_blocked");
        assert_eq!(feed_count(&store), 0);
        assert!(!error.message.contains("alice"));
        assert!(!error.message.contains("secret"));
    }

    #[test]
    fn exclude_import_skips_html_url_only_risk_and_preserves_safe_site_url() {
        let store = RssReaderStore::default();
        let xml = document(
            "<outline text=\"Risky site\" xmlUrl=\"https://example.com/risky\" htmlUrl=\"https://example.com/?token=secret\"/><outline text=\"Safe\" xmlUrl=\"https://example.com/safe\" htmlUrl=\"https://example.com/site?author=me\"/>",
        );
        let review = store
            .review_opml("import".into(), Some(xml.clone()))
            .unwrap();
        assert_eq!(review.affected_count, 1);
        assert_eq!(review.findings[0].location, "site");
        let result = store
            .execute_opml(
                "import".into(),
                Some(xml),
                review.fingerprint,
                "exclude".into(),
            )
            .unwrap();
        assert_eq!(result.imported_count, 1);
        assert_eq!(result.skipped_count, 0);
        assert_eq!(result.excluded_count, 1);
        let site: String = store
            .db
            .lock()
            .unwrap()
            .query_row("SELECT site_url FROM feeds", [], |row| row.get(0))
            .unwrap();
        assert_eq!(site, "https://example.com/site?author=me");
    }

    #[test]
    fn redact_import_scrubs_feed_and_site_credentials_but_keeps_benign_queries() {
        let store = RssReaderStore::default();
        let xml = document(
            "<outline text=\"Redacted\" xmlUrl=\"https://example.com/feed?api_key=feed-secret&amp;topic=swift\" htmlUrl=\"https://example.com/site?authToken=site-secret&amp;lang=zh\"/>",
        );
        let review = store
            .review_opml("import".into(), Some(xml.clone()))
            .unwrap();
        let result = store
            .execute_opml(
                "import".into(),
                Some(xml),
                review.fingerprint,
                "redact".into(),
            )
            .unwrap();
        assert_eq!(result.imported_count, 1);
        let (feed, site): (String, String) = store
            .db
            .lock()
            .unwrap()
            .query_row("SELECT url,site_url FROM feeds", [], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })
            .unwrap();
        assert_eq!(
            feed,
            "https://example.com/feed?api_key=REDACTED&topic=swift"
        );
        assert_eq!(site, "https://example.com/site?authToken=REDACTED&lang=zh");
    }

    #[test]
    fn fingerprints_reject_tampered_import_and_stale_export() {
        let store = RssReaderStore::default();
        let first = document("<outline text=\"One\" xmlUrl=\"https://example.com/one\"/>");
        let second = document("<outline text=\"Two\" xmlUrl=\"https://example.com/two\"/>");
        let review = store.review_opml("import".into(), Some(first)).unwrap();
        assert_eq!(
            store
                .execute_opml(
                    "import".into(),
                    Some(second),
                    review.fingerprint,
                    "redact".into(),
                )
                .unwrap_err()
                .code,
            "rss_opml_review_stale"
        );
        store
            .add_feed("https://example.com/one".into(), Some("One".into()))
            .unwrap();
        let export_review = store.review_opml("export".into(), None).unwrap();
        store
            .add_feed("https://example.com/two".into(), Some("Two".into()))
            .unwrap();
        assert_eq!(
            store
                .execute_opml(
                    "export".into(),
                    None,
                    export_review.fingerprint,
                    "redact".into(),
                )
                .unwrap_err()
                .code,
            "rss_opml_review_stale"
        );
    }

    #[test]
    fn preference_drift_requires_a_new_import_and_export_review() {
        let store = RssReaderStore::default();
        {
            let connection = store.db.lock().unwrap();
            set_meta(&connection, "private_network_access", "1").unwrap();
        }
        let xml = document("<outline text=\"Private\" xmlUrl=\"https://10.0.0.1/feed\"/>");
        let import_review = store
            .review_opml("import".into(), Some(xml.clone()))
            .unwrap();
        assert_eq!(import_review.blocked_count, 0);
        {
            let connection = store.db.lock().unwrap();
            set_meta(&connection, "private_network_access", "0").unwrap();
        }
        assert_eq!(
            store
                .execute_opml(
                    "import".into(),
                    Some(xml),
                    import_review.fingerprint,
                    "redact".into(),
                )
                .unwrap_err()
                .code,
            "rss_opml_review_stale"
        );
        assert_eq!(feed_count(&store), 0);

        store
            .add_feed("https://example.com/feed".into(), Some("Feed".into()))
            .unwrap();
        let export_review = store.review_opml("export".into(), None).unwrap();
        {
            let connection = store.db.lock().unwrap();
            set_meta(&connection, "private_network_access", "1").unwrap();
        }
        assert_eq!(
            store
                .execute_opml(
                    "export".into(),
                    None,
                    export_review.fingerprint,
                    "redact".into(),
                )
                .unwrap_err()
                .code,
            "rss_opml_review_stale"
        );
    }

    #[test]
    fn export_redacts_duplicate_credential_values_and_preserves_site_url() {
        let store = RssReaderStore::default();
        store
            .add_feed(
                "https://example.com/feed?token=one&TOKEN=two&author=me".into(),
                Some("Feed".into()),
            )
            .unwrap();
        let id = store.snapshot().unwrap().feeds[0].id.clone();
        store
            .update_feed_site_url(
                &id,
                Some("https://example.com/site?api_key=three&lang=zh".into()),
            )
            .unwrap();
        let review = store.review_opml("export".into(), None).unwrap();
        assert_eq!(review.affected_count, 1);
        let result = store
            .execute_opml(
                "export".into(),
                None,
                review.fingerprint.clone(),
                "redact".into(),
            )
            .unwrap();
        let xml = result.opml.unwrap();
        assert!(!xml.contains("one"));
        assert!(!xml.contains("two"));
        assert!(!xml.contains("three"));
        assert!(xml.contains("token=REDACTED"));
        assert!(xml.contains("TOKEN=REDACTED"));
        assert!(xml.contains("author=me"));
        assert!(xml.contains("htmlUrl="));
        assert_eq!(result.exported_count, 1);

        let excluded = store
            .execute_opml("export".into(), None, review.fingerprint, "exclude".into())
            .unwrap();
        assert_eq!(excluded.exported_count, 0);
        assert_eq!(excluded.excluded_count, 1);
        assert!(!excluded.opml.unwrap().contains("Feed"));
    }

    #[test]
    fn embedded_title_url_is_reported_without_title_or_values_and_redacts_to_feed_host() {
        let store = RssReaderStore::default();
        let xml = document(
            "<outline text=\"作者 author：更新（https://example.com/account?ToKeN=title-secret）请阅读\" xmlUrl=\"https://example.com/feed\"/>",
        );
        let review = store
            .review_opml("import".into(), Some(xml.clone()))
            .unwrap();
        assert_eq!(review.affected_count, 1);
        assert_eq!(review.blocked_count, 0);
        assert_eq!(review.findings.len(), 1);
        assert_eq!(review.findings[0].location, "title");
        assert_eq!(review.findings[0].parameter_names, vec!["ToKeN"]);
        let rendered = serde_json::to_string(&review).unwrap();
        assert!(rendered.contains("ToKeN=REDACTED"));
        for private in ["title-secret", "作者", "请阅读"] {
            assert!(!rendered.contains(private));
        }

        let result = store
            .execute_opml(
                "import".into(),
                Some(xml),
                review.fingerprint,
                "redact".into(),
            )
            .unwrap();
        assert_eq!(result.imported_count, 1);
        let title: String = store
            .db
            .lock()
            .unwrap()
            .query_row("SELECT title FROM feeds", [], |row| row.get(0))
            .unwrap();
        assert_eq!(title, "example.com");
        let exported = store.export_opml().unwrap();
        assert!(!exported.contains("title-secret"));
        assert!(exported.contains("title=\"example.com\""));
    }

    #[test]
    fn legacy_export_rejects_userinfo_in_title_and_long_titles_fail_closed() {
        let store = RssReaderStore::default();
        store
            .add_feed(
                "https://example.com/feed".into(),
                Some("Read https://alice:title-password@example.com/post".into()),
            )
            .unwrap();
        let review = store.review_opml("export".into(), None).unwrap();
        assert_eq!(review.affected_count, 1);
        assert_eq!(review.blocked_count, 0);
        assert_eq!(review.findings[0].location, "title");
        assert!(review.findings[0].contains_user_info);
        let rendered = serde_json::to_string(&review).unwrap();
        assert!(!rendered.contains("alice"));
        assert!(!rendered.contains("title-password"));
        let error = store.export_opml().unwrap_err();
        assert_eq!(error.code, "rss_opml_review_required");
        assert!(!error.message.contains("title-password"));

        let long_store = RssReaderStore::default();
        let long_title = "x".repeat(MAX_REVIEWED_TITLE_BYTES + 1);
        let xml = document(&format!(
            "<outline text=\"{long_title}\" xmlUrl=\"https://example.com/feed\"/>"
        ));
        let long_review = long_store
            .review_opml("import".into(), Some(xml.clone()))
            .unwrap();
        assert_eq!(long_review.affected_count, 1);
        assert_eq!(long_review.blocked_count, 1);
        assert!(!serde_json::to_string(&long_review)
            .unwrap()
            .contains(&long_title));
        assert_eq!(
            long_store
                .execute_opml(
                    "import".into(),
                    Some(xml),
                    long_review.fingerprint,
                    "redact".into(),
                )
                .unwrap_err()
                .code,
            "rss_opml_redaction_blocked"
        );
    }

    #[test]
    fn parser_rejects_malformed_dtd_oversize_too_many_and_deep_documents() {
        for invalid in [
            "<not-opml><body/></not-opml>".to_owned(),
            "<!DOCTYPE opml [<!ENTITY x \"secret\">]><opml><body><outline xmlUrl=\"https://example.com/&x;\"/></body></opml>".to_owned(),
            "<opml><body><outline xmlUrl=\"https://example.com/\"></body></opml>".to_owned(),
        ] {
            assert!(parse_privacy_opml(&invalid).is_err());
        }
        assert!(parse_privacy_opml(&"x".repeat(OPML_PRIVACY_MAX_BYTES + 1)).is_err());

        let too_many = document(&"<outline/>".repeat(OPML_PRIVACY_MAX_OUTLINES + 1));
        assert!(parse_privacy_opml(&too_many).is_err());

        let mut deep = String::from("<opml><body>");
        deep.push_str(&"<group>".repeat(OPML_PRIVACY_MAX_DEPTH));
        deep.push_str("<outline xmlUrl=\"https://example.com/feed\"/>");
        deep.push_str(&"</group>".repeat(OPML_PRIVACY_MAX_DEPTH));
        deep.push_str("</body></opml>");
        assert!(parse_privacy_opml(&deep).is_err());
    }
}
