use super::super::*;

fn parse(xml: &str) -> Vec<Parsed> {
    parse_xml(
        xml.as_bytes(),
        &Url::parse("https://example.com/feed").unwrap(),
    )
    .unwrap()
}

#[test]
fn rss_dialects_preserve_custom_core_namespaces_and_ignore_foreign_fields() {
    let items = parse(
        r#"<rss xmlns="urn:generator" xmlns:r="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel><item><title>Real</title><guid>real-id</guid><link>https://example.com/real</link><description>Real summary</description><r:title>Wrong title</r:title><r:link>https://evil.example/</r:link><r:description>Wrong summary</r:description><dc:creator>Author</dc:creator></item></channel></rss>"#,
    );
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].title, "Real");
    assert_eq!(items[0].summary, "Real summary");
    assert_eq!(items[0].url.as_deref(), Some("https://example.com/real"));
    assert_eq!(items[0].author.as_deref(), Some("Author"));
    let rdf = parse(
        r#"<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/"><channel/><item><title>RDF</title><link>https://example.com/rdf</link><description>RDF summary</description></item></rdf:RDF>"#,
    );
    assert_eq!(rdf.len(), 1);
    assert_eq!(rdf[0].summary, "RDF summary");
}

#[test]
fn body_priority_and_equal_priority_first_wins_match_the_mac_contract() {
    for body in [
        "<summary>Summary</summary><description>Description</description><summary>Later</summary><description>Later description</description>",
        "<description>Description</description><summary>Summary</summary><description>Later</description>",
    ] {
        let items = parse(&format!("<rss><channel><item><title>T</title>{body}</item></channel></rss>"));
        assert_eq!(items[0].summary, "Description");
    }
    for body in [
        "<content>Fallback</content><encoded>Plain encoded</encoded><content:encoded>Preferred</content:encoded><content:encoded>Later</content:encoded>",
        "<content:encoded>Preferred</content:encoded><content>Fallback</content><encoded>Plain encoded</encoded>",
    ] {
        let items = parse(&format!(r#"<rss xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel><item><title>T</title>{body}</item></channel></rss>"#));
        assert_eq!(items[0].content, "Preferred");
    }
}

#[test]
fn prefixed_xhtml_keeps_text_escapes_sorted_attributes_and_owner_boundaries() {
    let items = parse(
        r#"<a:feed xmlns:a="http://www.w3.org/2005/Atom" xmlns:x="http://www.w3.org/1999/xhtml"><a:entry><a:title>Real</a:title><a:id>real</a:id><a:link href="/p?a=1&amp;b=2"/><a:content type="xhtml"><x:div><x:p title="&quot; &amp; &lt;" class="c" onclick="bad()">Left &lt;literal&gt; <x:b>bold</x:b> right</x:p><x:title>Fake</x:title><a:entry><a:title>Nested</a:title></a:entry></x:div></a:content></a:entry><a:entry><a:title>Second</a:title><a:id>second</a:id></a:entry></a:feed>"#,
    );
    assert_eq!(items.len(), 2);
    assert_eq!(items[0].title, "Real");
    assert_eq!(items[0].guid, "real");
    assert_eq!(
        items[0].url.as_deref(),
        Some("https://example.com/p?a=1&b=2")
    );
    assert!(items[0].content.starts_with(
        "<p class=\"c\" title=\"&quot; &amp; &lt;\">Left &lt;literal&gt; <b>bold</b> right</p>"
    ));
    assert!(items[0].content.contains("<title>Fake</title>"));
    assert!(!items[0].content.contains("onclick"));
    assert_eq!(items[1].guid, "second");
}

#[test]
fn direct_xhtml_body_is_a_fallback_and_xml_media_keeps_its_root() {
    let items = parse(
        r#"<feed xmlns="http://www.w3.org/2005/Atom" xmlns:x="http://www.w3.org/1999/xhtml"><entry><title>T</title><x:body><x:p>Fallback &amp; safe</x:p></x:body></entry><entry><title>Preferred</title><content type="application/vendor+xml"><article><p>Preferred</p></article></content><x:body><x:p>Ignored fallback</x:p></x:body></entry></feed>"#,
    );
    assert_eq!(items[0].content, "<p>Fallback &amp; safe</p>");
    assert_eq!(items[1].content, "<article><p>Preferred</p></article>");
}

#[test]
fn body_limit_applies_after_escaping_and_accepts_the_exact_boundary() {
    let base = Url::parse("https://example.com/feed").unwrap();
    let exact = "x".repeat(4 * 1024 * 1024);
    let xml = format!("<feed><entry><title>T</title><content>{exact}</content></entry></feed>");
    assert_eq!(parse(&xml)[0].content.len(), exact.len());
    let expanded = "&".repeat(1024 * 1024);
    let xml = format!(
        "<feed><entry><title>T</title><content><![CDATA[{expanded}]]></content></entry></feed>"
    );
    assert!(xml.len() < MAX_XML);
    assert_eq!(
        parse_xml(xml.as_bytes(), &base).err().unwrap().code,
        "rss_feed_body_too_large"
    );
    let namespace = "x".repeat(8193);
    let xml = format!("<rss xmlns='{namespace}'><channel/></rss>");
    assert!(parse_xml(xml.as_bytes(), &base).is_err());
}

#[test]
fn article_count_allows_ten_thousand_and_rejects_the_next_entry() {
    let base = Url::parse("https://example.com/feed").unwrap();
    let entry = "<entry><title>T</title><content>Body</content></entry>";
    let mut xml = format!("<feed>{}</feed>", entry.repeat(MAX_ITEMS));
    assert_eq!(parse(&xml).len(), MAX_ITEMS);
    xml.insert_str(xml.len() - "</feed>".len(), entry);
    assert_eq!(
        parse_xml(xml.as_bytes(), &base).err().unwrap().code,
        "rss_feed_too_large"
    );
}

#[test]
fn refresh_persists_xhtml_payloads_and_json_backup_retains_them() {
    let store = RssReaderStore::default();
    let url = "https://example.com/feed";
    let feed = store.add_feed(url.into(), None).unwrap();
    let xml = br#"<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>T</title><id>stable</id><link href="/p"/><summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Short summary</p></div></summary><content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Complete <b>body</b>.</p></div></content></entry></feed>"#;
    let apply = || {
        store
            .apply_feed_response(
                &feed.id,
                url,
                (
                    Url::parse(url).unwrap(),
                    StatusCode::OK,
                    reqwest::header::HeaderMap::new(),
                    xml.to_vec(),
                ),
            )
            .unwrap()
    };
    assert_eq!(apply().inserted, 1);
    let article_id: String = store
        .db
        .lock()
        .unwrap()
        .query_row("SELECT id FROM articles", [], |r| r.get(0))
        .unwrap();
    store
        .db
        .lock()
        .unwrap()
        .execute(
            "UPDATE articles SET read=1,read_at=123,starred=1,tags='[\"keep\"]'",
            [],
        )
        .unwrap();
    assert_eq!(apply().updated, 1);
    let article = store.article(article_id.clone()).unwrap().unwrap();
    assert_eq!(article.content, "<p>Complete <b>body</b>.</p>");
    assert_eq!(article.summary, "<p>Short summary</p>");
    assert!(article.read && article.starred);
    assert_eq!(article.read_at, Some(123));
    assert_eq!(article.tags, ["keep"]);
    let restored = RssReaderStore::default();
    restored
        .restore_backup(store.export_backup().unwrap())
        .unwrap();
    assert_eq!(restored.article(article_id).unwrap().unwrap(), article);
    let mut preferences = store.preferences().unwrap();
    preferences.feed_body_offline_cache_enabled = false;
    store.update_preferences(preferences).unwrap();
    apply();
    let cached: (String, String) = store
        .db
        .lock()
        .unwrap()
        .query_row("SELECT content,summary FROM articles", [], |r| {
            Ok((r.get(0)?, r.get(1)?))
        })
        .unwrap();
    assert!(cached.0.is_empty());
    assert_eq!(cached.1, "<p>Short summary</p>");
}

#[test]
fn invalid_body_parse_cannot_partially_refresh_or_replace_existing_article_state() {
    let store = RssReaderStore::default();
    let url = "https://example.com/feed";
    let feed = store.add_feed(url.into(), None).unwrap();
    let response = |body: Vec<u8>| {
        (
            Url::parse(url).unwrap(),
            StatusCode::OK,
            reqwest::header::HeaderMap::new(),
            body,
        )
    };
    store.apply_feed_response(&feed.id, url, response(b"<rss><channel><item><title>Original</title><guid>g</guid><description>Saved</description></item></channel></rss>".to_vec())).unwrap();
    let before = store.export_backup().unwrap();
    let invalid = format!("<rss><channel><item><title>Replaced</title><guid>g</guid><description>Changed</description></item><item><title>Too large</title><description>{}</description></item></channel></rss>", "x".repeat(4*1024*1024+1));
    assert!(store
        .apply_feed_response(&feed.id, url, response(invalid.into_bytes()))
        .is_err());
    assert_eq!(store.export_backup().unwrap(), before);
}

#[test]
fn html_summary_round_trip_and_read_timestamp_validation_share_storage_bounds() {
    let store = RssReaderStore::default();
    let url = "https://example.com/feed";
    let feed = store.add_feed(url.into(), None).unwrap();
    let summary = format!("<p>{}</p>", "x".repeat(MAX_BACKUP_TEXT + 1));
    let xml = format!("<rss><channel><item><title>Large summary</title><guid>g</guid><description><![CDATA[{summary}]]></description></item></channel></rss>");
    store
        .apply_feed_response(
            &feed.id,
            url,
            (
                Url::parse(url).unwrap(),
                StatusCode::OK,
                reqwest::header::HeaderMap::new(),
                xml.into_bytes(),
            ),
        )
        .unwrap();
    let backup = store.export_backup().unwrap();
    let restored = RssReaderStore::default();
    restored.restore_backup(backup.clone()).unwrap();
    let restored_summary: String = restored
        .db
        .lock()
        .unwrap()
        .query_row("SELECT summary FROM articles", [], |r| r.get(0))
        .unwrap();
    assert_eq!(restored_summary, summary);
    for timestamp in [serde_json::json!(-1), serde_json::json!("123")] {
        let mut invalid: serde_json::Value = serde_json::from_str(&backup).unwrap();
        invalid["articles"][0]["read_at"] = timestamp;
        assert!(store.restore_backup(invalid.to_string()).is_err());
        assert_eq!(store.export_backup().unwrap(), backup);
    }
}
