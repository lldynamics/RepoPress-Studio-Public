//! Bounded, local feed-body capture. Captured descendants never become feed metadata.
use super::{CommandError, CommandResult};
use quick_xml::{events::BytesStart, name::ResolveResult};

pub(super) const ATOM: &str = "http://www.w3.org/2005/Atom";
pub(super) const XHTML: &str = "http://www.w3.org/1999/xhtml";
pub(super) const RSS1: &str = "http://purl.org/rss/1.0/";
pub(super) const CONTENT: &str = "http://purl.org/rss/1.0/modules/content/";
pub(super) const MEDIA: &str = "http://search.yahoo.com/mrss/";
pub(super) const DC: &str = "http://purl.org/dc/elements/1.1/";
pub(super) const DC_TERMS: &str = "http://purl.org/dc/terms/";
const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;

#[derive(Clone)]
pub(super) struct Element {
    pub name: String,
    pub namespace: Option<String>,
}
impl Element {
    pub fn resolved(namespace: ResolveResult<'_>, name: &[u8]) -> CommandResult<Self> {
        let namespace = match namespace {
            ResolveResult::Bound(value) if value.as_ref().len() <= 8192 => Some(
                std::str::from_utf8(value.as_ref())
                    .map_err(|_| invalid())?
                    .to_owned(),
            ),
            ResolveResult::Unbound => None,
            ResolveResult::Unknown(_) | ResolveResult::Bound(_) => return Err(invalid()),
        };
        Ok(Self {
            name: std::str::from_utf8(name)
                .map_err(|_| invalid())?
                .to_ascii_lowercase(),
            namespace,
        })
    }
    pub fn core(&self, atom: bool, core_namespace: Option<&str>) -> bool {
        if atom {
            self.namespace.as_deref() == core_namespace
        } else {
            self.namespace.is_none() || self.namespace.as_deref() == core_namespace
        }
    }
}
#[derive(Clone, Copy)]
enum Format {
    Text,
    Html,
    Markup,
    Ignore,
}
struct MarkupElement {
    name: String,
    emitted: bool,
    void: bool,
}
pub(super) struct Capture {
    pub depth: usize,
    pub summary: bool,
    pub priority: u8,
    format: Format,
    atom: bool,
    strip_wrapper: bool,
    elements: Vec<MarkupElement>,
    html: String,
}
fn invalid() -> CommandError {
    CommandError::new("rss_xml_invalid", "RSS body XML is invalid.")
}
pub(super) fn value(event: &BytesStart<'_>, wanted: &[u8]) -> CommandResult<Option<String>> {
    for attribute in event.attributes() {
        let attribute = attribute.map_err(|_| invalid())?;
        if attribute.key.as_ref().eq_ignore_ascii_case(wanted) {
            return attribute
                .unescape_value()
                .map(|v| Some(v.into_owned()))
                .map_err(|_| invalid());
        }
    }
    Ok(None)
}
impl Capture {
    pub fn new(
        key: &Element,
        event: &BytesStart<'_>,
        depth: usize,
        atom: bool,
        core_namespace: Option<&str>,
    ) -> CommandResult<Option<Self>> {
        let core = key.core(atom, core_namespace);
        let (summary, priority) = if atom && core {
            match key.name.as_str() {
                "summary" => (true, 2),
                "content" => (false, 2),
                _ => return Ok(None),
            }
        } else if !atom && key.name == "encoded" && key.namespace.as_deref() == Some(CONTENT) {
            (false, 3)
        } else if !atom && core {
            match key.name.as_str() {
                "description" => (true, 2),
                "summary" => (true, 1),
                "content" | "encoded" => (false, 1),
                _ => return Ok(None),
            }
        } else if key.namespace.as_deref() == Some(XHTML) && key.name == "body" {
            (false, 1)
        } else {
            return Ok(None);
        };
        let kind = value(event, b"type")?
            .unwrap_or_else(|| "text".into())
            .trim()
            .to_ascii_lowercase();
        let kind = kind.split(';').next().unwrap_or_default().trim();
        let format = if atom && core && !summary && value(event, b"src")?.is_some() {
            Format::Ignore
        } else if key.namespace.as_deref() == Some(XHTML) && key.name == "body" {
            Format::Markup
        } else if !atom || !core {
            Format::Html
        } else {
            match kind {
                "text" => Format::Text,
                "html" => Format::Html,
                "xhtml" => Format::Markup,
                "text/plain" if !summary => Format::Text,
                "text/html" if !summary => Format::Html,
                v if !summary && (v.ends_with("/xml") || v.ends_with("+xml")) => Format::Markup,
                _ => Format::Ignore,
            }
        };
        Ok(Some(Self {
            depth,
            summary,
            priority,
            format,
            atom: atom && core,
            strip_wrapper: atom && core && kind == "xhtml",
            elements: Vec::new(),
            html: String::new(),
        }))
    }
    fn append(&mut self, value: &str) -> CommandResult<()> {
        if value.len() > MAX_BODY_BYTES.saturating_sub(self.html.len()) {
            return Err(CommandError::new(
                "rss_feed_body_too_large",
                "RSS article body or summary exceeds 4 MiB.",
            ));
        }
        self.html.push_str(value);
        Ok(())
    }
    fn escaped(&mut self, value: &str, attribute: bool) -> CommandResult<()> {
        let mut start = 0;
        for (index, character) in value.char_indices() {
            let replacement = match character {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' if attribute => "&quot;",
                '\'' if attribute => "&#39;",
                _ => continue,
            };
            self.append(&value[start..index])?;
            self.append(replacement)?;
            start = index + character.len_utf8();
        }
        self.append(&value[start..])
    }
    pub fn text(&mut self, value: &str) -> CommandResult<()> {
        match self.format {
            Format::Ignore => Ok(()),
            Format::Html => self.append(value),
            Format::Text | Format::Markup => self.escaped(value, false),
        }
    }
    pub fn start(&mut self, key: &Element, event: &BytesStart<'_>) -> CommandResult<()> {
        if matches!(self.format, Format::Ignore) {
            return Ok(());
        }
        if matches!(self.format, Format::Text) || self.atom && matches!(self.format, Format::Html) {
            return Err(invalid());
        }
        let wrapper = self.strip_wrapper
            && self.elements.is_empty()
            && key.name == "div"
            && key.namespace.as_deref() == Some(XHTML);
        let void = matches!(
            key.name.as_str(),
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
                | "source"
                | "track"
                | "wbr"
        );
        if !wrapper {
            self.append("<")?;
            self.append(&key.name)?;
            let mut attributes = Vec::new();
            for value in event.attributes() {
                let value = value.map_err(|_| invalid())?;
                let raw = std::str::from_utf8(value.key.as_ref()).map_err(|_| invalid())?;
                let name = if raw == "xml:lang" { "lang" } else { raw };
                if !matches!(
                    name,
                    "alt"
                        | "class"
                        | "dir"
                        | "height"
                        | "href"
                        | "id"
                        | "lang"
                        | "src"
                        | "title"
                        | "width"
                ) {
                    continue;
                }
                let decoded = value.unescape_value().map_err(|_| invalid())?;
                attributes.push((name.to_owned(), decoded.into_owned()));
            }
            attributes.sort();
            for (name, value) in attributes {
                self.append(" ")?;
                self.append(&name)?;
                self.append("=\"")?;
                self.escaped(&value, true)?;
                self.append("\"")?;
            }
            self.append(">")?;
        }
        self.elements.push(MarkupElement {
            name: key.name.clone(),
            emitted: !wrapper,
            void,
        });
        Ok(())
    }
    pub fn end(&mut self) -> CommandResult<()> {
        if matches!(self.format, Format::Ignore) {
            return Ok(());
        }
        let element = self.elements.pop().ok_or_else(invalid)?;
        if element.emitted && !element.void {
            self.append("</")?;
            self.append(&element.name)?;
            self.append(">")?;
        }
        Ok(())
    }
    pub fn finish(self) -> Option<String> {
        if matches!(self.format, Format::Ignore) {
            None
        } else {
            Some(self.html.trim().to_owned())
        }
    }
}

#[cfg(test)]
#[path = "rss_feed_body_limits_tests.rs"]
mod limits_tests;
