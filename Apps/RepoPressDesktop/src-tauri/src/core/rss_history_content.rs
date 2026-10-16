//! Pure content and URL hints shared by RSS history backfill.
use url::Url;

fn same_origin(a: &Url, b: &Url) -> bool {
    a.scheme() == b.scheme()
        && a.host_str().map(str::to_ascii_lowercase) == b.host_str().map(str::to_ascii_lowercase)
        && a.port_or_known_default() == b.port_or_known_default()
}

fn path_segments(path: &str) -> Vec<&str> {
    path.split('/').filter(|part| !part.is_empty()).collect()
}

/// A hint for checking a possible slash alias. This never defines URL identity.
pub(super) fn may_be_slash_alias(a: &Url, b: &Url) -> bool {
    if !same_origin(a, b) || a.query() != b.query() {
        return false;
    }
    let safe_path = |path: &str| {
        !path.contains('\\')
            && !path.as_bytes().windows(3).any(|v| {
                v[0] == b'%' && v[1] == b'2' && v[2].eq_ignore_ascii_case(&b'f')
                    || v[0] == b'%' && v[1] == b'5' && v[2].eq_ignore_ascii_case(&b'c')
            })
    };
    if !safe_path(a.path()) || !safe_path(b.path()) {
        return false;
    }
    path_segments(a.path()) == path_segments(b.path())
}

/// Mirrors the macOS teaser check. A short article alone is not a truncation signal.
pub(super) fn needs_full_text(content_html: &str, summary_text: &str, readable_text: &str) -> bool {
    let content = content_html.trim();
    let summary = summary_text.trim();
    let readable = readable_text.trim();
    if content.is_empty() {
        return true;
    }
    if !summary.is_empty() && content == summary && readable.chars().count() < 1_200 {
        return true;
    }
    let lower = readable.to_lowercase();
    let suffix = lower
        .chars()
        .rev()
        .take(160)
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();
    [
        "阅读全文",
        "继续阅读",
        "查看全文",
        "点击阅读",
        "read more",
        "continue reading",
        "view full post",
    ]
    .iter()
    .any(|marker| suffix.contains(marker))
        || suffix.ends_with('…')
        || suffix.ends_with("...")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn url(value: &str) -> Url {
        Url::parse(value).unwrap()
    }

    #[test]
    fn rss_history_slash_alias_is_only_a_same_origin_path_hint() {
        assert!(may_be_slash_alias(
            &url("https://example.com/a/b"),
            &url("https://example.com//a///b/")
        ));
        assert!(!may_be_slash_alias(
            &url("https://example.com/A/b"),
            &url("https://example.com/a/b")
        ));
        assert!(!may_be_slash_alias(
            &url("https://example.com/a/b?x=1"),
            &url("https://example.com/a/b?x=2")
        ));
        assert!(!may_be_slash_alias(
            &url("https://example.com/a%2Fb"),
            &url("https://example.com/a/b")
        ));
        assert!(!may_be_slash_alias(
            &url("https://example.com/a%5Cb"),
            &url("https://example.com/a/b")
        ));
    }

    #[test]
    fn rss_history_full_text_hint_distinguishes_teasers_from_short_complete_articles() {
        assert!(needs_full_text("  ", "", ""));
        assert!(!needs_full_text(
            "<p>摘要 &amp; 内容</p>",
            "摘要 & 内容",
            "摘要 & 内容"
        ));
        assert!(needs_full_text("摘要 & 内容", "摘要 & 内容", "摘要 & 内容"));
        assert!(needs_full_text(
            "<p>Short story.</p>",
            "",
            "Short story. Read more"
        ));
        assert!(!needs_full_text(
            "<p>Short story.</p>",
            "Different summary",
            "Short story."
        ));
    }
}
