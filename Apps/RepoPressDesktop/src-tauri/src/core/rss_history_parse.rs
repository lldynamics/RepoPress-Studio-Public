//! Small, bounded parsers used by RSS history discovery.
use quick_xml::{events::Event, Reader};
use std::collections::HashSet;
use url::Url;

const MAX_SITEMAP_BYTES: usize = 1024 * 1024;
const MAX_SITEMAP_DEPTH: usize = 64;
const MAX_SITEMAP_NODES: usize = 20_000;
const MAX_SITEMAP_URLS: usize = 5_001;
pub(super) const MAX_DISCOVERY_URLS: usize = 5_000;

pub(super) struct DirectoryLinks {
    pub articles: Vec<(String, String)>,
    pub pages: Vec<String>,
    pub complete: bool,
}

fn same_origin(a: &Url, b: &Url) -> bool {
    a.scheme() == b.scheme()
        && a.host_str().map(str::to_ascii_lowercase) == b.host_str().map(str::to_ascii_lowercase)
        && a.port_or_known_default() == b.port_or_known_default()
}

fn normalize_percent(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut output = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] != b'%' {
            if bytes[index].is_ascii() {
                output.push(bytes[index]);
            } else {
                output.extend_from_slice(format!("%{:02X}", bytes[index]).as_bytes());
            }
            index += 1;
            continue;
        }
        if index + 2 >= bytes.len() {
            return None;
        }
        let hex = std::str::from_utf8(&bytes[index + 1..index + 3]).ok()?;
        let decoded = u8::from_str_radix(hex, 16).ok()?;
        if decoded == b'/' || decoded == b'\\' {
            return None;
        }
        if decoded.is_ascii_alphanumeric() || matches!(decoded, b'-' | b'.' | b'_' | b'~') {
            output.push(decoded);
        } else {
            output.extend_from_slice(format!("%{decoded:02X}").as_bytes());
        }
        index += 3;
    }
    String::from_utf8(output).ok()
}

fn safe_url(raw: &str, base: &Url) -> Option<Url> {
    let url = base.join(raw.trim()).ok()?;
    if !matches!(url.scheme(), "http" | "https")
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || !same_origin(&url, base)
        || normalize_percent(url.path()).is_none()
    {
        return None;
    }
    Some(url)
}

fn safe_canonical(mut url: Url, base: &Url) -> Option<String> {
    let path = normalize_percent(url.path())?;
    let base_path = normalize_percent(base.path())?;
    url.set_path(&path);
    if url.path() == base_path {
        if url.fragment().is_some() {
            return None;
        }
    } else {
        url.set_fragment(None);
    }
    Some(url.to_string())
}

fn decode_entities(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

fn tag_attrs(tag: &str) -> (String, Vec<(String, String)>, bool) {
    let mut s = tag.trim_start();
    let closing = s.starts_with('/');
    if closing {
        s = &s[1..];
    }
    let name_end = s
        .find(|c: char| c.is_whitespace() || c == '/' || c == '>')
        .unwrap_or(s.len());
    let name = s[..name_end].to_ascii_lowercase();
    let mut rest = s[name_end..]
        .trim_end_matches('>')
        .trim()
        .trim_end_matches('/')
        .trim();
    let mut attrs = Vec::new();
    while !rest.is_empty() {
        let end = rest
            .find(|c: char| c.is_whitespace() || c == '=')
            .unwrap_or(rest.len());
        if end == 0 {
            rest = &rest[1..];
            continue;
        }
        let key = rest[..end].to_ascii_lowercase();
        rest = rest[end..].trim_start();
        let mut value = String::new();
        if rest.starts_with('=') {
            rest = rest[1..].trim_start();
            if rest.starts_with('\'') || rest.starts_with('"') {
                let q = rest.as_bytes()[0] as char;
                rest = &rest[1..];
                if let Some(i) = rest.find(q) {
                    value = rest[..i].to_string();
                    rest = &rest[i + 1..];
                } else {
                    value = rest.to_string();
                    rest = "";
                }
            } else {
                let i = rest.find(char::is_whitespace).unwrap_or(rest.len());
                value = rest[..i].trim_end_matches('/').to_string();
                rest = &rest[i..];
            }
        }
        attrs.push((key, decode_entities(&value)));
        rest = rest.trim_start();
    }
    (name, attrs, closing)
}

fn attr<'a>(attrs: &'a [(String, String)], key: &str) -> &'a str {
    attrs
        .iter()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
        .unwrap_or("")
}

pub(super) fn find_tag_end(html: &str, start: usize) -> Option<usize> {
    let mut quote = None;
    for (offset, byte) in html.as_bytes()[start..].iter().copied().enumerate() {
        match (quote, byte) {
            (Some(q), b) if q == b => quote = None,
            (None, b'\'' | b'"') => quote = Some(byte),
            (None, b'>') => return Some(start + offset),
            _ => {}
        }
    }
    None
}

#[cfg(test)]
pub(super) fn directory_links(html: &str, base: &Url, limit: usize) -> DirectoryLinks {
    directory_links_with_page_limit(html, base, limit, 10)
}

fn directory_links_with_page_limit(
    html: &str,
    base: &Url,
    limit: usize,
    page_limit: usize,
) -> DirectoryLinks {
    let mut result = DirectoryLinks {
        articles: Vec::new(),
        pages: Vec::new(),
        complete: true,
    };
    if html.len() > 1024 * 1024 || limit == 0 {
        result.complete = false;
        return result;
    }
    let (mut seen_articles, mut seen_pages) = (HashSet::new(), HashSet::new());
    let (mut article_depth, mut main_depth) = (0usize, 0usize);
    let mut open_tags = Vec::<String>::new();
    let mut excluded_tags = Vec::<String>::new();
    let mut active: Option<(String, String, bool)> = None;
    let lower = html.to_ascii_lowercase();
    let mut cursor = 0;
    let mut tags_seen = 0usize;
    while cursor < html.len() {
        let Some(start_rel) = html[cursor..].find('<') else {
            if let Some(a) = active.as_mut() {
                a.1.push_str(&html[cursor..]);
            }
            break;
        };
        let start = cursor + start_rel;
        if html[start..].starts_with("<!--") {
            if let Some(end) = html[start + 4..].find("-->") {
                cursor = start + 4 + end + 3;
                continue;
            }
            result.complete = false;
            break;
        }
        if let Some(a) = active.as_mut() {
            a.1.push_str(&html[cursor..start]);
        }
        let Some(end) = find_tag_end(html, start) else {
            result.complete = false;
            break;
        };
        let raw = html[start + 1..end].trim();
        cursor = end + 1;
        if raw.starts_with('!') || raw.starts_with('?') {
            continue;
        }
        let (name, attrs, closing) = tag_attrs(raw);
        tags_seen += 1;
        if tags_seen > 50_000 {
            result.complete = false;
            break;
        }
        if !closing && matches!(name.as_str(), "script" | "style") {
            let closing_tag = format!("</{name}");
            if let Some(close_rel) = lower[cursor..].find(&closing_tag) {
                let close_start = cursor + close_rel;
                if let Some(close_end) = find_tag_end(html, close_start) {
                    cursor = close_end + 1;
                    continue;
                }
            }
            result.complete = false;
            break;
        }
        if closing {
            if let Some(index) = open_tags.iter().rposition(|tag| tag == &name) {
                open_tags.truncate(index);
            } else {
                result.complete = false;
            }
            match name.as_str() {
                "article" => article_depth = article_depth.saturating_sub(1),
                "main" => main_depth = main_depth.saturating_sub(1),
                "a" => {
                    if let Some((href, text, next)) = active.take() {
                        if next || is_next_text(&text) {
                            if let Some(url) =
                                safe_url(&href, base).and_then(|u| safe_canonical(u, base))
                            {
                                if seen_pages.len() < page_limit && seen_pages.insert(url.clone()) {
                                    result.pages.push(url);
                                }
                            }
                        } else if (article_depth > 0 || main_depth > 0) && excluded_tags.is_empty()
                        {
                            let title = decode_entities(&text)
                                .split_whitespace()
                                .collect::<Vec<_>>()
                                .join(" ");
                            if !title.is_empty() && !is_rejected_href(&href) {
                                if let Some(url) =
                                    safe_url(&href, base).and_then(|u| safe_canonical(u, base))
                                {
                                    if seen_articles.len() < limit
                                        && seen_articles.insert(url.clone())
                                    {
                                        result.articles.push((url, title));
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
            if let Some(index) = excluded_tags.iter().rposition(|tag| tag == &name) {
                excluded_tags.truncate(index);
            }
        } else {
            if !matches!(
                name.as_str(),
                "area"
                    | "base"
                    | "br"
                    | "col"
                    | "embed"
                    | "hr"
                    | "img"
                    | "input"
                    | "link"
                    | "meta"
                    | "param"
                    | "source"
                    | "track"
                    | "wbr"
            ) && !raw.trim_end().ends_with('/')
            {
                open_tags.push(name.clone());
                if open_tags.len() > 256 {
                    result.complete = false;
                    break;
                }
            }
            match name.as_str() {
                "article" => article_depth += 1,
                "main" => main_depth += 1,
                "a" => {
                    let rel = attr(&attrs, "rel").to_ascii_lowercase();
                    let media_type = attr(&attrs, "type").to_ascii_lowercase();
                    let feed_link = rel.split_ascii_whitespace().any(|token| token == "feed")
                        || (rel
                            .split_ascii_whitespace()
                            .any(|token| token == "alternate")
                            && ["rss", "atom", "feed", "rdf+xml"]
                                .iter()
                                .any(|marker| media_type.contains(marker)));
                    let href = if feed_link {
                        String::new()
                    } else {
                        attr(&attrs, "href").to_string()
                    };
                    let next = !feed_link && rel.split_ascii_whitespace().any(|v| v == "next");
                    active = Some((href, String::new(), next));
                }
                "img" => {
                    if let Some(a) = active.as_mut() {
                        a.1.push(' ');
                    }
                }
                _ => {}
            }
            let role = attr(&attrs, "role").trim().to_ascii_lowercase();
            let class = attr(&attrs, "class").to_ascii_lowercase();
            if name == "nav"
                || role == "navigation"
                || class.split_ascii_whitespace().any(|class| {
                    class == "nav"
                        || class.ends_with("-nav")
                        || class.starts_with("nav-")
                        || class == "navigation"
                        || class.ends_with("-navigation")
                        || class == "menu"
                        || class == "pagination"
                })
            {
                excluded_tags.push(name);
            }
        }
    }
    if !open_tags.is_empty() || active.is_some() {
        result.complete = false;
    }
    result
}

pub(super) type DiscoveryLinks = (Vec<(String, String)>, Vec<(String, bool)>);

/// Parses one complete index page for durable discovery. Overflow sentinels
/// prevent callers from persisting a truncated article or source sequence.
pub(super) fn discovery_links(
    html: &str,
    base: &Url,
    sitemap: bool,
) -> Result<DiscoveryLinks, String> {
    if sitemap {
        let (urls, maps) = sitemap_links_with_map_limit(html, base, MAX_DISCOVERY_URLS + 1, 11)?;
        if urls.len() > MAX_DISCOVERY_URLS || maps.len() > 10 {
            return Err("discovery page has too many URLs".into());
        }
        let articles = urls.into_iter().map(|url| (url, String::new())).collect();
        let pages = maps.into_iter().map(|url| (url, true)).collect();
        Ok((articles, pages))
    } else {
        let parsed = directory_links_with_page_limit(html, base, MAX_DISCOVERY_URLS + 1, 11);
        if !parsed.complete {
            return Err("directory page is incomplete".into());
        }
        if parsed.articles.len() > MAX_DISCOVERY_URLS || parsed.pages.len() > 10 {
            return Err("discovery page has too many URLs".into());
        }
        let pages = parsed.pages.into_iter().map(|url| (url, false)).collect();
        Ok((parsed.articles, pages))
    }
}
fn is_next_text(s: &str) -> bool {
    let s = s.trim().to_ascii_lowercase();
    matches!(s.as_str(), "›" | "»" | "→" | "next" | "older" | "下页")
        || s.starts_with("next ")
        || s.starts_with("older ")
        || s.contains("下一页")
        || s.contains("较早文章")
}
fn is_rejected_href(href: &str) -> bool {
    let s = href.trim().to_ascii_lowercase();
    s.is_empty()
        || s.starts_with('#')
        || s.starts_with("mailto:")
        || s.starts_with("javascript:")
        || s.starts_with("data:")
        || [
            ".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".pdf", ".xml", ".rss", ".atom",
        ]
        .iter()
        .any(|ext| s.split(['?', '#']).next().unwrap_or(&s).ends_with(ext))
}

#[cfg(test)]
pub(super) fn sitemap_links(
    xml: &str,
    base: &Url,
    limit: usize,
) -> Result<(Vec<String>, Vec<String>), String> {
    sitemap_links_with_map_limit(xml, base, limit, 10)
}

fn sitemap_links_with_map_limit(
    xml: &str,
    base: &Url,
    limit: usize,
    map_limit: usize,
) -> Result<(Vec<String>, Vec<String>), String> {
    if xml.len() > MAX_SITEMAP_BYTES || limit == 0 {
        return Err("sitemap exceeds bounds".into());
    }
    let upper = xml.to_ascii_uppercase();
    if upper.contains("<!DOCTYPE") || upper.contains("<!ENTITY") {
        return Err("DTD and entities are forbidden".into());
    }
    let mut reader = Reader::from_str(xml);
    reader.config_mut().trim_text(true);
    let (mut stack, mut root, mut loc_text, mut root_closed) =
        (Vec::<String>::new(), None::<String>, false, false);
    let (mut urls, mut sitemaps) = (Vec::new(), Vec::new());
    let (mut seen_urls, mut seen_maps, mut nodes) = (HashSet::new(), HashSet::new(), 0usize);
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) => {
                nodes += 1;
                if nodes > MAX_SITEMAP_NODES || stack.len() >= MAX_SITEMAP_DEPTH {
                    return Err("sitemap structure exceeds bounds".into());
                }
                let name = local_name(e.name().as_ref());
                if stack.is_empty() {
                    if root.is_some() || name != "urlset" && name != "sitemapindex" {
                        return Err("invalid sitemap root".into());
                    }
                    root = Some(name.clone());
                } else {
                    validate_sitemap_child(root.as_deref().unwrap_or(""), &stack, &name)?;
                }
                loc_text = name == "loc";
                stack.push(name);
            }
            Ok(Event::Empty(e)) => {
                nodes += 1;
                if nodes > MAX_SITEMAP_NODES {
                    return Err("sitemap structure exceeds bounds".into());
                }
                let name = local_name(e.name().as_ref());
                if stack.is_empty() {
                    if root.is_some() || name != "urlset" && name != "sitemapindex" {
                        return Err("invalid sitemap root".into());
                    }
                    root = Some(name);
                    root_closed = true;
                    continue;
                }
                validate_sitemap_child(root.as_deref().unwrap_or(""), &stack, &name)?;
                if name == "loc" {
                    return Err("empty sitemap location".into());
                }
            }
            Ok(Event::Text(e)) => {
                let unescaped = e.unescape().map_err(|_| "invalid sitemap text")?;
                if !loc_text {
                    if !unescaped.trim().is_empty() {
                        return Err("unexpected sitemap text".into());
                    }
                    continue;
                }
                let parent = stack.iter().rev().nth(1).map(String::as_str).unwrap_or("");
                let expected_parent = match root.as_deref() {
                    Some("urlset") => "url",
                    Some("sitemapindex") => "sitemap",
                    _ => "",
                };
                if parent == expected_parent {
                    if let Some(url) = safe_url(unescaped.trim(), base).and_then(|u| {
                        if u.fragment().is_some() {
                            None
                        } else {
                            safe_canonical(u, base)
                        }
                    }) {
                        if parent == "url"
                            && urls.len() < limit.min(MAX_SITEMAP_URLS)
                            && seen_urls.insert(url.clone())
                        {
                            urls.push(url);
                        } else if parent == "sitemap"
                            && sitemaps.len() < map_limit
                            && seen_maps.insert(url.clone())
                        {
                            sitemaps.push(url);
                        }
                    }
                }
                loc_text = false;
            }
            Ok(Event::End(e)) => {
                let name = local_name(e.name().as_ref());
                if stack.pop().as_deref() != Some(name.as_str()) {
                    return Err("mismatched sitemap tags".into());
                }
                if stack.is_empty() {
                    root_closed = true;
                }
                loc_text = false;
            }
            Ok(Event::DocType(_)) => return Err("DTD is forbidden".into()),
            Ok(Event::CData(e)) => {
                let bytes = e.into_inner();
                if loc_text {
                    let parent = stack.iter().rev().nth(1).map(String::as_str).unwrap_or("");
                    let expected_parent = match root.as_deref() {
                        Some("urlset") => "url",
                        Some("sitemapindex") => "sitemap",
                        _ => "",
                    };
                    if parent == expected_parent {
                        let raw = String::from_utf8_lossy(bytes.as_ref());
                        if let Some(url) = safe_url(raw.trim(), base).and_then(|u| {
                            if u.fragment().is_some() {
                                None
                            } else {
                                safe_canonical(u, base)
                            }
                        }) {
                            if parent == "url"
                                && urls.len() < limit.min(MAX_SITEMAP_URLS)
                                && seen_urls.insert(url.clone())
                            {
                                urls.push(url);
                            } else if parent == "sitemap"
                                && sitemaps.len() < map_limit
                                && seen_maps.insert(url.clone())
                            {
                                sitemaps.push(url);
                            }
                        }
                    }
                } else if !bytes.as_ref().iter().all(|b| b.is_ascii_whitespace()) {
                    return Err("unexpected sitemap CDATA".into());
                }
            }
            Ok(Event::Eof) => break,
            Ok(_) => {}
            Err(_) => return Err("malformed sitemap XML".into()),
        }
    }
    if !stack.is_empty() || root.is_none() || !root_closed {
        return Err("incomplete sitemap XML".into());
    }
    Ok((urls, sitemaps))
}
fn validate_sitemap_child(root: &str, stack: &[String], child: &str) -> Result<(), String> {
    let allowed = match (root, stack.last().map(String::as_str)) {
        ("urlset", Some("url")) => matches!(child, "loc" | "lastmod" | "changefreq" | "priority"),
        ("urlset", Some("urlset")) => child == "url",
        ("sitemapindex", Some("sitemapindex")) => child == "sitemap",
        ("sitemapindex", Some("sitemap")) => matches!(child, "loc" | "lastmod"),
        _ => false,
    };
    if allowed {
        Ok(())
    } else {
        Err("invalid sitemap structure".into())
    }
}
fn local_name(bytes: &[u8]) -> String {
    let s = String::from_utf8_lossy(bytes);
    s.rsplit(':').next().unwrap_or(&s).to_ascii_lowercase()
}

#[derive(Default)]
struct RobotsGroup {
    agents: Vec<String>,
    rules: Vec<(bool, String)>,
}
pub(super) fn robots_allowed(text: &str, url: &Url) -> bool {
    if text.len() > 1024 * 1024 {
        return false;
    }
    let mut groups = Vec::<RobotsGroup>::new();
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let key = key.trim().to_ascii_lowercase();
        let value = value.trim();
        if key == "user-agent" {
            if groups.last().is_none_or(|g| !g.rules.is_empty()) {
                groups.push(RobotsGroup::default());
            }
            if let Some(g) = groups.last_mut() {
                g.agents.push(value.to_ascii_lowercase());
            }
        } else if key == "allow" || key == "disallow" {
            if let Some(g) = groups.last_mut() {
                if !value.is_empty() {
                    g.rules.push((key == "allow", value.to_string()));
                }
            }
        }
    }
    let exact: Vec<_> = groups
        .iter()
        .filter(|g| g.agents.iter().any(|a| a == "repopress"))
        .collect();
    let selected: Vec<_> = if exact.is_empty() {
        groups
            .iter()
            .filter(|g| g.agents.iter().any(|a| a == "*"))
            .collect()
    } else {
        exact
    };
    let Some(path) = normalize_percent(url.path()) else {
        return false;
    };
    let query = match url.query() {
        Some(query) => {
            let Some(query) = normalize_percent(query) else {
                return false;
            };
            Some(query)
        }
        None => None,
    };
    let target = format!(
        "{path}{}",
        query.map(|q| format!("?{q}")).unwrap_or_default()
    );
    let mut best: Option<(usize, bool)> = None;
    for g in selected {
        for (allow, pattern) in &g.rules {
            if pattern.len() > 2048 {
                continue;
            }
            let (raw_pattern, anchored) = pattern
                .strip_suffix('$')
                .map_or((pattern.as_str(), false), |p| (p, true));
            let Some(pat) = normalize_robots_pattern(raw_pattern) else {
                continue;
            };
            if wildcard_match(&pat, &target, anchored) {
                let specificity = pat.chars().filter(|c| *c != '*').count();
                if best.is_none_or(|(n, old_allow)| {
                    specificity > n || (specificity == n && *allow && !old_allow)
                }) {
                    best = Some((specificity, *allow));
                }
            }
        }
    }
    best.map(|(_, allow)| allow).unwrap_or(true)
}
fn normalize_robots_pattern(pattern: &str) -> Option<String> {
    let mut output = String::new();
    let mut segment = String::new();
    for ch in pattern.chars() {
        if ch == '*' {
            output.push_str(&normalize_percent(&segment)?);
            output.push('*');
            segment.clear();
        } else {
            segment.push(ch);
        }
    }
    output.push_str(&normalize_percent(&segment)?);
    Some(output)
}
fn wildcard_match(pattern: &str, text: &str, anchored: bool) -> bool {
    let mut remainder = text;
    for (i, part) in pattern.split('*').enumerate() {
        if i == 0 {
            if !remainder.starts_with(part) {
                return false;
            }
            remainder = &remainder[part.len()..];
        } else if part.is_empty() {
            continue;
        } else if let Some(pos) = remainder.find(part) {
            remainder = &remainder[pos + part.len()..];
        } else {
            return false;
        }
    }
    !anchored || pattern.ends_with('*') || remainder.is_empty()
}

pub(super) fn robots_sitemaps(text: &str, base: &Url) -> Vec<String> {
    if text.len() > 1024 * 1024 {
        return Vec::new();
    }
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for line in text.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if key.trim().eq_ignore_ascii_case("sitemap") {
            if let Some(url) = safe_url(value.trim(), base).and_then(|u| {
                if u.fragment().is_some() {
                    None
                } else {
                    safe_canonical(u, base)
                }
            }) {
                if seen.insert(url.clone()) {
                    out.push(url);
                    if out.len() == 10 {
                        break;
                    }
                }
            }
        }
    }
    out
}

pub(super) fn no_archive(html: &str) -> bool {
    if html.len() > 1024 * 1024 {
        return true;
    }
    let lower = html.to_ascii_lowercase();
    let mut cursor = 0;
    let mut tags_seen = 0usize;
    while let Some(i) = lower[cursor..].find('<') {
        let start = cursor + i;
        if lower[start..].starts_with("<!--") {
            if let Some(end) = lower[start + 4..].find("-->") {
                cursor = start + 4 + end + 3;
                continue;
            }
            break;
        }
        let Some(end) = find_tag_end(html, start) else {
            break;
        };
        tags_seen += 1;
        if tags_seen > 50_000 {
            return true;
        }
        let (tag_name, attrs, closing) = tag_attrs(&html[start + 1..end]);
        cursor = end + 1;
        if closing {
            continue;
        }
        if matches!(tag_name.as_str(), "script" | "style") {
            let close = format!("</{tag_name}");
            if let Some(close_rel) = lower[cursor..].find(&close) {
                let close_start = cursor + close_rel;
                if let Some(close_end) = find_tag_end(html, close_start) {
                    cursor = close_end + 1;
                    continue;
                }
            }
            break;
        }
        if tag_name == "meta" {
            let name = attr(&attrs, "name").trim().to_ascii_lowercase();
            if name != "robots" && name != "googlebot" {
                continue;
            }
            let content = attr(&attrs, "content").to_ascii_lowercase();
            if content
                .split(|c: char| !c.is_ascii_alphanumeric() && c != '-')
                .any(|v| v == "noarchive" || v == "none")
            {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    fn base() -> Url {
        Url::parse("https://example.com/blog/").unwrap()
    }

    #[test]
    fn directory_filters_cross_origin_and_finds_pagination() {
        let d = directory_links("<main><div class=site-nav><a href='/navigation'>Menu</a></div><a rel=alternate type='application/rss+xml' href='/feed'>Feed</a><!-- <article><a href='/comment'>Comment</a></article> --><script>const x = \"<article><a href='/script'>Script</a></article>\";</script><article><a href='/post#x'>Post</a><a href='https://evil.test/x'>bad</a><a href='/page/2'>Next</a></article></main>", &base(), 20);
        assert_eq!(d.articles.len(), 1);
        assert_eq!(d.articles[0].0, "https://example.com/post");
        assert_eq!(d.articles[0].1, "Post");
        assert_eq!(d.pages, vec!["https://example.com/page/2"]);
    }
    #[test]
    fn sitemap_rejects_dtd_and_cross_origin_and_deduplicates() {
        assert!(sitemap_links(
            "<!DOCTYPE x [<!ENTITY e SYSTEM 'file:///etc/passwd'>]><urlset/>",
            &base(),
            20
        )
        .is_err());
        let xml = "<urlset xmlns='http://www.sitemaps.org/schemas/sitemap/0.9'><url><loc>https://example.com/a</loc></url><url><loc>https://evil.test/b</loc></url><url><loc>https://example.com/a</loc></url></urlset>";
        assert_eq!(
            sitemap_links(xml, &base(), 20).unwrap().0,
            vec!["https://example.com/a"]
        );
        assert!(sitemap_links("<urlset><url>", &base(), 20).is_err());
    }

    #[test]
    fn rss_history_complete_discovery_keeps_more_than_five_hundred_and_rejects_overflow() {
        let mut page = String::from("<main>");
        for index in 0..501 {
            page.push_str(&format!(
                "<article><a href='/post/{index}'>Post {index}</a></article>"
            ));
        }
        page.push_str("</main>");
        let (articles, _) = discovery_links(&page, &base(), false).unwrap();
        assert_eq!(articles.len(), 501);

        let mut overflow = String::from("<main>");
        for index in 0..=MAX_DISCOVERY_URLS {
            overflow.push_str(&format!(
                "<article><a href='/overflow/{index}'>Post</a></article>"
            ));
        }
        overflow.push_str("</main>");
        assert!(discovery_links(&overflow, &base(), false).is_err());
    }

    #[test]
    fn rss_history_malformed_directory_is_not_a_complete_cursor_source() {
        assert!(discovery_links("<main><article>", &base(), false).is_err());
        assert!(discovery_links("<main><!-- unfinished", &base(), false).is_err());
        assert!(discovery_links("<main><script>unfinished", &base(), false).is_err());
    }

    #[test]
    fn rss_history_rejects_directory_page_source_overflow() {
        let mut html = String::from("<main>");
        for index in 0..11 {
            html.push_str(&format!("<a rel='next' href='/archive/{index}'>Next</a>"));
        }
        html.push_str("</main>");
        assert_eq!(directory_links(&html, &base(), 20).pages.len(), 10);
        assert!(discovery_links(&html, &base(), false).is_err());
    }

    #[test]
    fn rss_history_rejects_sitemap_source_overflow() {
        let mut xml = String::from("<sitemapindex>");
        for index in 0..11 {
            xml.push_str(&format!(
                "<sitemap><loc>https://example.com/map/{index}</loc></sitemap>"
            ));
        }
        xml.push_str("</sitemapindex>");
        assert_eq!(sitemap_links(&xml, &base(), 20).unwrap().1.len(), 10);
        assert!(discovery_links(&xml, &base(), true).is_err());
    }
    #[test]
    fn robots_exact_group_wildcard_and_longest_allow() {
        let u = Url::parse("https://example.com/private/open/abc").unwrap();
        let rules = "User-agent: *\nDisallow: /private\n\nUser-agent: RepoPress\nDisallow: /private/*\nAllow: /private/open/*$";
        assert!(robots_allowed(rules, &u));
        let blocked = Url::parse("https://example.com/private/closed/x").unwrap();
        assert!(!robots_allowed(rules, &blocked));
    }
    #[test]
    fn repeated_agent_groups_and_meta_comments_are_handled() {
        let rules = "User-agent: *\nDisallow: /blocked\n\nUser-agent: RepoPress\nDisallow: /blocked/*\nUser-agent: RepoPress\nAllow: /blocked/open/*";
        let allowed = Url::parse("https://example.com/blocked/open/item").unwrap();
        assert!(robots_allowed(rules, &allowed));
        let denied = Url::parse("https://example.com/blocked/closed/item").unwrap();
        assert!(!robots_allowed(rules, &denied));
        assert!(!no_archive("<!-- <meta name=robots content=noarchive> --><script>\"<meta name=robots content=noarchive>\"</script>"));
    }
    #[test]
    fn metadata_and_default_port_normalization() {
        let b = Url::parse("https://example.com:443/").unwrap();
        assert_eq!(
            safe_url("https://example.com/x", &b).unwrap().host_str(),
            Some("example.com")
        );
        assert!(no_archive(
            "<meta name='GoogleBot' content='index, NoArchive'>"
        ));
        assert!(no_archive("<meta name=robots content=none>"));
        assert!(!no_archive("<meta name=robots content=index,follow>"));
        let encoded = Url::parse("https://example.com/%6Fld").unwrap();
        assert_eq!(normalize_percent(encoded.path()).as_deref(), Some("/old"));
        assert!(safe_url("/a%2fb", &b).is_none());
        let blocked = Url::parse("https://example.com/%6Fld/item").unwrap();
        assert!(!robots_allowed(
            "User-agent: RepoPress\nDisallow: /old",
            &blocked
        ));
    }
}
