use super::*;

fn parse_one(xml: &str) -> Parsed {
    let base = Url::parse("https://example.com/feed.xml").unwrap();
    let mut items = parse_xml(xml.as_bytes(), &base).expect("feed should parse");
    assert_eq!(items.len(), 1);
    items.remove(0)
}

#[test]
fn rss_cdata_description_and_content_encoded_preserve_html() {
    let item = parse_one(
        r#"<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/">
          <channel><item>
            <title>Rich RSS</title>
            <link>https://example.com/posts/rich</link>
            <description><![CDATA[<p>Summary <b>markup</b> & welcome</p>]]></description>
            <content:encoded><![CDATA[<article><h1>Heading</h1><p>Body & detail</p></article>]]></content:encoded>
          </item></channel>
        </rss>"#,
    );

    assert_eq!(item.summary, "<p>Summary <b>markup</b> & welcome</p>");
    assert_eq!(
        item.content,
        "<article><h1>Heading</h1><p>Body & detail</p></article>"
    );
}

#[test]
fn atom_text_and_default_text_are_html_escaped_after_xml_decoding() {
    let base = Url::parse("https://example.com/feed.xml").unwrap();
    let items = parse_xml(
        br#"<feed xmlns="http://www.w3.org/2005/Atom">
          <entry><title>Typed</title><id>typed</id>
            <summary type="text">&lt;b&gt;literal&lt;/b&gt; &amp; safe</summary>
            <content type="text">line &lt;i&gt;one&lt;/i&gt; &amp; two</content>
          </entry>
          <entry><title>Default</title><id>default</id>
            <summary>&lt;em&gt;still text&lt;/em&gt;</summary>
            <content>&lt;strong&gt;also text&lt;/strong&gt;</content>
          </entry>
        </feed>"#,
        &base,
    )
    .unwrap();

    assert_eq!(items.len(), 2);
    assert_eq!(items[0].summary, "&lt;b&gt;literal&lt;/b&gt; &amp; safe");
    assert_eq!(items[0].content, "line &lt;i&gt;one&lt;/i&gt; &amp; two");
    assert_eq!(items[1].summary, "&lt;em&gt;still text&lt;/em&gt;");
    assert_eq!(items[1].content, "&lt;strong&gt;also text&lt;/strong&gt;");
}

#[test]
fn atom_html_is_xml_decoded_then_kept_as_html() {
    let item = parse_one(
        r#"<feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>HTML</title><id>html-id</id>
          <summary type="html">&lt;p class=&quot;lede&quot;&gt;A &amp;amp; B&lt;/p&gt;</summary>
          <content type="html">&lt;section&gt;&lt;p&gt;First &amp;amp; second&lt;/p&gt;&lt;/section&gt;</content>
        </entry></feed>"#,
    );

    assert_eq!(item.summary, r#"<p class="lede">A &amp; B</p>"#);
    assert_eq!(item.content, "<section><p>First &amp; second</p></section>");
}

#[test]
fn atom_xhtml_keeps_nested_markup_text_entities_and_body_whitespace() {
    let item = parse_one(
        r#"<feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>XHTML</title><id>xhtml-id</id>
          <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>Independent <em>summary</em></p></div></summary>
          <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>First &amp; second</p>
            <p> third <strong>word</strong> </p></div></content>
        </entry></feed>"#,
    );

    assert_eq!(item.summary, "<p>Independent <em>summary</em></p>");
    assert!(item.content.starts_with("<p>"), "{}", item.content);
    assert!(
        item.content.contains("<p>First &amp; second</p>"),
        "{}",
        item.content
    );
    assert!(
        item.content
            .contains("<p> third <strong>word</strong> </p>"),
        "{}",
        item.content
    );
    assert!(
        item.content.contains("</p>\n            <p>"),
        "body-significant whitespace was lost: {}",
        item.content
    );
}

#[test]
fn atom_xml_media_type_keeps_its_root_and_only_safe_html_attributes() {
    let item = parse_one(
        r#"<feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>XML media</title><id>xml-media</id>
          <content type="application/xhtml+xml"><article class="story" onclick="bad()"><p>Body<br/><img src="/cover.png" alt="Cover" onerror="bad()"/></p></article></content>
        </entry></feed>"#,
    );

    assert!(item.content.starts_with(r#"<article class="story">"#));
    assert!(item.content.contains("<p>Body<br"), "{}", item.content);
    assert!(item.content.contains(r#"alt="Cover""#), "{}", item.content);
    assert!(
        item.content.contains(r#"src="/cover.png""#),
        "{}",
        item.content
    );
    assert!(!item.content.contains("onclick"));
    assert!(!item.content.contains("onerror"));
}

#[test]
fn extension_namespace_fields_do_not_override_atom_metadata() {
    let item = parse_one(
        r#"<feed xmlns="http://www.w3.org/2005/Atom" xmlns:ext="urn:example:extension"><entry>
          <title>Real title</title><ext:id>extension-id</ext:id><id>real-id</id>
          <ext:link href="https://evil.example/extension"/><link rel="alternate" href="/real"/>
          <ext:author><ext:name>Extension author</ext:name></ext:author>
          <author><name>Real author</name></author>
          <summary type="text">Body</summary>
        </entry></feed>"#,
    );

    assert_eq!(item.guid, "real-id");
    assert_eq!(item.url.as_deref(), Some("https://example.com/real"));
    assert_eq!(item.author.as_deref(), Some("Real author"));
}

#[test]
fn body_descendants_cannot_change_entry_identity_url_or_author() {
    let item = parse_one(
        r#"<feed xmlns="http://www.w3.org/2005/Atom"><entry>
          <title>Outer title</title><id>outer-id</id>
          <link rel="alternate" href="/outer"/>
          <author><name>Outer author</name></author>
          <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
            <p><id>body-id</id><name>Body name</name><link href="https://evil.example/body">Body link</link></p>
          </div></content>
        </entry></feed>"#,
    );

    assert_eq!(item.guid, "outer-id");
    assert_eq!(item.url.as_deref(), Some("https://example.com/outer"));
    assert_eq!(item.author.as_deref(), Some("Outer author"));
    assert!(item.content.contains("body-id"));
    assert!(item.content.contains("Body name"));
    assert!(item.content.contains("Body link"));
}

#[test]
fn atom_src_and_unsupported_media_types_ignore_inline_payloads() {
    let base = Url::parse("https://example.com/feed.xml").unwrap();
    let items = parse_xml(
        br#"<feed xmlns="http://www.w3.org/2005/Atom">
          <entry><title>External</title><id>external</id>
            <summary type="html">&lt;p&gt;External fallback&lt;/p&gt;</summary>
            <content type="html" src="https://cdn.example/payload">&lt;b&gt;must be ignored&lt;/b&gt;</content>
          </entry>
          <entry><title>Binary</title><id>binary</id>
            <summary type="text">Binary fallback</summary>
            <content type="application/octet-stream">not html &lt;b&gt;either&lt;/b&gt;</content>
          </entry>
        </feed>"#,
        &base,
    )
    .unwrap();

    assert_eq!(items.len(), 2);
    assert_eq!(items[0].content, "<p>External fallback</p>");
    assert!(!items[0].content.contains("must be ignored"));
    assert_eq!(items[1].content, "Binary fallback");
    assert!(!items[1].content.contains("not html"));
}

#[test]
fn malformed_dtd_and_excessive_depth_feeds_remain_rejected() {
    let base = Url::parse("https://example.com/feed.xml").unwrap();
    assert!(parse_xml(
        br#"<!DOCTYPE feed [<!ENTITY x "expanded">]><feed xmlns="http://www.w3.org/2005/Atom"/>"#,
        &base
    )
    .is_err());
    assert!(parse_xml(
        br#"<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Broken</entry></feed>"#,
        &base
    )
    .is_err());

    let mut deep = String::from("<feed>");
    for _ in 0..MAX_DEPTH {
        deep.push_str("<x>");
    }
    for _ in 0..MAX_DEPTH {
        deep.push_str("</x>");
    }
    deep.push_str("</feed>");
    assert!(parse_xml(deep.as_bytes(), &base).is_err());
}

#[test]
fn individual_serialized_summary_and_content_are_capped_at_four_mib() {
    let base = Url::parse("https://example.com/feed.xml").unwrap();
    for field in ["summary", "content"] {
        let oversized = "x".repeat(4 * 1024 * 1024 + 1);
        let xml = format!(
            "<feed xmlns='http://www.w3.org/2005/Atom'><entry><title>Large</title><id>large</id><{field} type='text'>{oversized}</{field}></entry></feed>"
        );
        assert!(
            parse_xml(xml.as_bytes(), &base).is_err(),
            "oversized {field} must be rejected"
        );
    }
}
