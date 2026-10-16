use super::{CommandError, CommandResult};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

const MAX_FRONT_MATTER_BYTES: usize = 64 * 1024;
const MAX_INPUT_BYTES: usize = 8 * 1024;
const MAX_VALUE_CHARS: usize = 128;
const MAX_VALUES: usize = 64;

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase", deny_unknown_fields)]
pub enum MetadataBatchField {
    Tags,
    Categories,
}

impl MetadataBatchField {
    fn key(self) -> &'static str {
        match self {
            Self::Tags => "tags",
            Self::Categories => "categories",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase", deny_unknown_fields)]
pub enum MetadataBatchOperationKind {
    Add,
    Remove,
    Rename,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MetadataBatchOperation {
    pub kind: MetadataBatchOperationKind,
    pub value: String,
    pub replacement: Option<String>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MetadataFieldEdit {
    pub original_values: Vec<String>,
    pub proposed_values: Vec<String>,
    pub text: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum FrontMatterStyle {
    Yaml,
    Toml,
}

#[derive(Clone, Copy, Debug)]
struct FrontMatter<'a> {
    style: FrontMatterStyle,
    content: &'a str,
    content_start: usize,
}

#[derive(Clone, Copy, Debug)]
struct Line<'a> {
    start: usize,
    end: usize,
    text: &'a str,
}

#[derive(Clone, Debug)]
struct ParsedField {
    values: Vec<String>,
    replace_start: usize,
    replace_end: usize,
}

/// Applies a deliberately narrow metadata operation without parsing or rewriting unrelated YAML/TOML.
/// Unsupported syntax fails closed so callers can surface an unavailable preview instead of guessing.
pub fn transform_metadata_field(
    text: &str,
    field: &MetadataBatchField,
    operation: &MetadataBatchOperation,
) -> CommandResult<MetadataFieldEdit> {
    let front_matter = parse_front_matter(text)?;
    let key = field.key();
    let parsed = match front_matter.style {
        FrontMatterStyle::Yaml => parse_yaml_field(front_matter, key)?,
        FrontMatterStyle::Toml => parse_toml_field(front_matter, key)?,
    };
    let original_values = parsed
        .as_ref()
        .map_or_else(Vec::new, |value| value.values.clone());
    validate_source_values(&original_values)?;
    let proposed_values = apply_operation(&original_values, operation)?;

    let replacement = match front_matter.style {
        FrontMatterStyle::Yaml => format!("{key}: {}\n", render_array(&proposed_values)?),
        FrontMatterStyle::Toml => format!("{key} = {}\n", render_array(&proposed_values)?),
    };
    let next_text = match parsed {
        Some(_) if original_values == proposed_values => text.to_string(),
        Some(parsed) => {
            replace_byte_range(text, parsed.replace_start, parsed.replace_end, &replacement)?
        }
        None if proposed_values.is_empty() => text.to_string(),
        None => replace_byte_range(
            text,
            front_matter.content_start + front_matter.content.len(),
            front_matter.content_start + front_matter.content.len(),
            &replacement,
        )?,
    };

    let updated_front_matter = parse_front_matter(&next_text)?;
    let updated_field = match updated_front_matter.style {
        FrontMatterStyle::Yaml => parse_yaml_field(updated_front_matter, key)?,
        FrontMatterStyle::Toml => parse_toml_field(updated_front_matter, key)?,
    };
    if updated_field.map_or_else(Vec::new, |parsed| parsed.values) != proposed_values {
        return Err(unsupported("Updated metadata cannot be verified."));
    }
    Ok(MetadataFieldEdit {
        original_values,
        proposed_values,
        text: next_text,
    })
}

fn parse_front_matter(text: &str) -> CommandResult<FrontMatter<'_>> {
    let (opening, style) = if text.starts_with("---\n") {
        ("---", FrontMatterStyle::Yaml)
    } else if text.starts_with("+++\n") {
        ("+++", FrontMatterStyle::Toml)
    } else {
        return Err(unsupported("A Markdown front matter block is required."));
    };
    let content_start = opening.len() + 1;
    let mut offset = content_start;
    while offset <= text.len() {
        if offset > MAX_FRONT_MATTER_BYTES {
            return Err(unsupported("Front matter exceeds the 64 KiB safety limit."));
        }
        let remaining = &text[offset..];
        let line_end = remaining
            .find('\n')
            .map_or(text.len(), |index| offset + index);
        let line = &text[offset..line_end];
        let closes = match style {
            FrontMatterStyle::Yaml => line == "---" || line == "...",
            FrontMatterStyle::Toml => line == "+++",
        };
        if closes {
            return Ok(FrontMatter {
                style,
                content: &text[content_start..offset],
                content_start,
            });
        }
        if line_end == text.len() {
            break;
        }
        offset = line_end + 1;
    }
    Err(unsupported(
        "Front matter has no unambiguous closing delimiter.",
    ))
}

fn parse_yaml_field(
    front_matter: FrontMatter<'_>,
    key: &str,
) -> CommandResult<Option<ParsedField>> {
    let lines = lines(front_matter.content, front_matter.content_start);
    reject_yaml_complex_syntax(&lines)?;
    let mut target: Option<usize> = None;
    for (index, line) in lines.iter().enumerate() {
        let trimmed = line.text.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if !line.text.starts_with([' ', '\t']) {
            validate_flat_root_line(line.text, ':')?;
        }
        if line.text.starts_with(&format!("{key}:")) {
            if target.replace(index).is_some() {
                return Err(unsupported("The metadata key appears more than once."));
            }
            continue;
        }
        if looks_like_unsupported_key(line.text, key, ':') {
            return Err(unsupported(
                "The metadata key must be an exact unquoted root YAML key.",
            ));
        }
    }
    let Some(index) = target else {
        reject_yaml_nested_outside(&lines, None)?;
        return Ok(None);
    };
    let target_line = lines[index];
    let raw = target_line
        .text
        .strip_prefix(&format!("{key}:"))
        .expect("checked prefix");
    let value = raw.trim();
    if value.starts_with('[') {
        reject_yaml_nested_outside(&lines, Some((index, index + 1)))?;
        return Ok(Some(ParsedField {
            values: parse_json_array(value)?,
            replace_start: target_line.start,
            replace_end: target_line.end,
        }));
    }
    if !raw.is_empty() {
        return Err(unsupported(
            "The YAML metadata key must use `key: [...]` or `key:` exactly.",
        ));
    }

    let mut cursor = index + 1;
    let mut values = Vec::new();
    while cursor < lines.len() {
        let line = lines[cursor];
        if !line.text.starts_with("  - ") || line.text.starts_with("   ") {
            break;
        }
        values.push(parse_yaml_list_value(&line.text[4..])?);
        cursor += 1;
    }
    if values.is_empty() {
        return Err(unsupported(
            "The YAML metadata list must contain simple string values.",
        ));
    }
    reject_yaml_nested_outside(&lines, Some((index, cursor)))?;
    Ok(Some(ParsedField {
        values,
        replace_start: target_line.start,
        replace_end: lines[cursor - 1].end,
    }))
}

fn parse_toml_field(
    front_matter: FrontMatter<'_>,
    key: &str,
) -> CommandResult<Option<ParsedField>> {
    let lines = lines(front_matter.content, front_matter.content_start);
    let mut target: Option<usize> = None;
    for (index, line) in lines.iter().enumerate() {
        let trimmed = line.text.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        validate_flat_root_line(line.text, '=')?;
        if trimmed.starts_with('[') {
            return Err(unsupported(
                "TOML tables make the metadata field scope ambiguous.",
            ));
        }
        let exact_target = !line.text.starts_with([' ', '\t'])
            && line
                .text
                .split_once('=')
                .is_some_and(|(left, _)| left.trim_end_matches([' ', '\t']) == key);
        if exact_target {
            if target.replace(index).is_some() {
                return Err(unsupported("The metadata key appears more than once."));
            }
            continue;
        }
        if looks_like_unsupported_key(line.text, key, '=') {
            return Err(unsupported(
                "The metadata key must be an exact unquoted TOML key.",
            ));
        }
        if !line.text.contains('=') {
            return Err(unsupported(
                "TOML front matter contains an unsupported multiline value.",
            ));
        }
    }
    let Some(index) = target else {
        return Ok(None);
    };
    let target_line = lines[index];
    let (_, raw) = target_line.text.split_once('=').expect("checked equals");
    Ok(Some(ParsedField {
        values: parse_json_array(raw.trim())?,
        replace_start: target_line.start,
        replace_end: target_line.end,
    }))
}

/// Verify that an unrelated value cannot continue across the target's physical line.
/// This deliberately accepts only bare root keys and balanced single-line values.
fn validate_flat_root_line(line: &str, separator: char) -> CommandResult<()> {
    let (key, value) = line
        .split_once(separator)
        .ok_or_else(|| unsupported("Only flat root fields are supported."))?;
    let key = key.trim();
    if key.is_empty()
        || !key.as_bytes()[0].is_ascii_alphabetic()
        || !key
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
    {
        return Err(unsupported(
            "Quoted, escaped, merged or dotted keys are unsupported.",
        ));
    }
    let mut quote = None;
    let mut escaped = false;
    let mut brackets = Vec::new();
    for ch in value.chars() {
        if escaped {
            escaped = false;
            continue;
        }
        if let Some(current) = quote {
            if current == '"' && ch == '\\' {
                escaped = true;
            } else if ch == current {
                quote = None;
            }
            continue;
        }
        match ch {
            '#' => break,
            '"' | '\'' => quote = Some(ch),
            '[' => brackets.push(']'),
            '{' => brackets.push('}'),
            ']' | '}' if brackets.pop() != Some(ch) => {
                return Err(unsupported("Unbalanced collection value."))
            }
            _ => {}
        }
    }
    if quote.is_some() || !brackets.is_empty() || value.contains("\"\"\"") || value.contains("'''")
    {
        return Err(unsupported(
            "Multiline strings or collections are unsupported.",
        ));
    }
    Ok(())
}

fn reject_yaml_complex_syntax(lines: &[Line<'_>]) -> CommandResult<()> {
    for line in lines {
        let trimmed = line.text.trim_start();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        let mut quote = None;
        let mut escaped = false;
        let mut previous = ' ';
        for ch in line.text.chars() {
            if escaped {
                escaped = false;
                continue;
            }
            if let Some(current) = quote {
                if current == '"' && ch == '\\' {
                    escaped = true;
                } else if current == ch {
                    quote = None;
                }
                continue;
            }
            if ch == '#' {
                break;
            }
            if ch == '"' || ch == '\'' {
                quote = Some(ch);
            }
            if matches!(ch, '*' | '&' | '|' | '>')
                && (previous.is_whitespace() || matches!(previous, ':' | '[' | '{' | ','))
            {
                return Err(unsupported(
                    "YAML anchors, aliases, and multiline blocks are unsupported.",
                ));
            }
            previous = ch;
        }
    }
    Ok(())
}

fn reject_yaml_nested_outside(
    lines: &[Line<'_>],
    allowed: Option<(usize, usize)>,
) -> CommandResult<()> {
    for (index, line) in lines.iter().enumerate() {
        if allowed.is_some_and(|(start, end)| index >= start && index < end) {
            continue;
        }
        let trimmed = line.text.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if line.text.starts_with(' ') || line.text.starts_with('\t') {
            return Err(unsupported(
                "Nested YAML front matter is outside the safe metadata subset.",
            ));
        }
    }
    Ok(())
}

fn looks_like_unsupported_key(line: &str, key: &str, separator: char) -> bool {
    let trimmed = line.trim_start();
    if trimmed.starts_with('#') {
        return false;
    }
    let quoted_double = format!("\"{key}\"");
    let quoted_single = format!("'{key}'");
    let has_separator_after = |candidate: &str| {
        trimmed
            .strip_prefix(candidate)
            .is_some_and(|remaining| remaining.trim_start().starts_with(separator))
    };
    has_separator_after(&quoted_double)
        || has_separator_after(&quoted_single)
        || trimmed.strip_prefix(key).is_some_and(|remaining| {
            remaining.starts_with('.')
                || (remaining.chars().next().is_some_and(char::is_whitespace)
                    && remaining.trim_start().starts_with(separator))
        })
        || (trimmed.starts_with(key)
            && (line.starts_with(' ') || line.starts_with('\t'))
            && has_separator_after(key))
}

fn parse_json_array(value: &str) -> CommandResult<Vec<String>> {
    if value.len() > MAX_INPUT_BYTES {
        return Err(unsupported(
            "The metadata field must be a simple single-line string array.",
        ));
    }
    let values = serde_json::from_str::<Vec<String>>(value)
        .map_err(|_| unsupported("The metadata field must be a JSON-style array of strings."))?;
    validate_source_values(&values)?;
    Ok(values)
}

fn parse_yaml_list_value(value: &str) -> CommandResult<String> {
    let value = value.trim();
    if value.is_empty()
        || value.starts_with([
            '"', '\'', '[', '{', '&', '*', '|', '>', '!', '~', '+', '-', '.',
        ])
        || value.chars().next().is_some_and(|c| c.is_ascii_digit())
        || matches!(
            value.to_lowercase().as_str(),
            "true" | "false" | "null" | "yes" | "no" | "on" | "off"
        )
        || value.contains('#')
        || value.contains(": ")
        || value.contains('\t')
    {
        return Err(unsupported(
            "YAML metadata list items must be simple unquoted strings.",
        ));
    }
    validate_value(value)?;
    Ok(value.to_string())
}

fn apply_operation(
    values: &[String],
    operation: &MetadataBatchOperation,
) -> CommandResult<Vec<String>> {
    if operation.value.len() > MAX_INPUT_BYTES
        || operation
            .replacement
            .as_ref()
            .is_some_and(|value| value.len() > MAX_INPUT_BYTES)
    {
        return Err(invalid("Metadata input exceeds the 8 KiB safety limit."));
    }
    let requested = split_values(&operation.value)?;
    match operation.kind {
        MetadataBatchOperationKind::Add => {
            if operation.replacement.is_some() {
                return Err(invalid("Add does not accept a replacement value."));
            }
            let mut next = values.to_vec();
            let mut known = fold_set(&next);
            for value in requested {
                if known.insert(fold(&value)) {
                    next.push(value);
                }
            }
            validate_source_values(&next)?;
            Ok(next)
        }
        MetadataBatchOperationKind::Remove => {
            if operation.replacement.is_some() {
                return Err(invalid("Remove does not accept a replacement value."));
            }
            let requested = fold_set(&requested);
            Ok(values
                .iter()
                .filter(|value| !requested.contains(&fold(value)))
                .cloned()
                .collect())
        }
        MetadataBatchOperationKind::Rename => {
            let replacement = operation
                .replacement
                .as_deref()
                .ok_or_else(|| invalid("Rename requires a replacement value."))?;
            let replacement = split_values(replacement)?;
            if requested.len() != 1 || replacement.len() != 1 {
                return Err(invalid(
                    "Rename accepts exactly one source and one replacement value.",
                ));
            }
            let from = fold(&requested[0]);
            let replacement = replacement.into_iter().next().expect("checked length");
            let replacement_folded = fold(&replacement);
            if values
                .iter()
                .any(|value| fold(value) == replacement_folded && fold(value) != from)
            {
                return Err(unsupported(
                    "Rename would create a duplicate metadata value.",
                ));
            }
            Ok(values
                .iter()
                .map(|value| {
                    if fold(value) == from {
                        replacement.clone()
                    } else {
                        value.clone()
                    }
                })
                .collect())
        }
    }
}

fn split_values(value: &str) -> CommandResult<Vec<String>> {
    let mut values = Vec::new();
    let mut seen = HashSet::new();
    for value in value.split([',', '，', '\n']) {
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        validate_value(value)?;
        if seen.insert(fold(value)) {
            values.push(value.to_string());
        }
    }
    if values.is_empty() {
        return Err(invalid("At least one metadata value is required."));
    }
    if values.len() > MAX_VALUES {
        return Err(invalid("Metadata supports at most 64 values."));
    }
    Ok(values)
}

fn validate_source_values(values: &[String]) -> CommandResult<()> {
    if values.len() > MAX_VALUES {
        return Err(unsupported("The metadata field has more than 64 values."));
    }
    let mut seen = HashSet::new();
    for value in values {
        validate_value(value)?;
        if !seen.insert(fold(value)) {
            return Err(unsupported("The metadata field contains duplicate values."));
        }
    }
    Ok(())
}

fn validate_value(value: &str) -> CommandResult<()> {
    if value.is_empty() || value.chars().count() > MAX_VALUE_CHARS || value.contains('\0') {
        return Err(invalid(
            "Each metadata value must contain 1 to 128 Unicode characters.",
        ));
    }
    Ok(())
}

fn fold(value: &str) -> String {
    value.to_lowercase()
}

fn fold_set(values: &[String]) -> HashSet<String> {
    values.iter().map(|value| fold(value)).collect()
}

fn render_array(values: &[String]) -> CommandResult<String> {
    let rendered = serde_json::to_string(values).map_err(|_| {
        CommandError::new(
            "metadata_serialization_failed",
            "Unable to serialize metadata values.",
        )
    })?;
    if rendered.len() > MAX_INPUT_BYTES {
        return Err(invalid("Serialized metadata exceeds 8 KiB."));
    }
    Ok(rendered)
}

fn replace_byte_range(
    text: &str,
    start: usize,
    end: usize,
    replacement: &str,
) -> CommandResult<String> {
    if start > end
        || end > text.len()
        || !text.is_char_boundary(start)
        || !text.is_char_boundary(end)
    {
        return Err(unsupported(
            "The metadata field has an invalid source range.",
        ));
    }
    Ok(format!("{}{}{}", &text[..start], replacement, &text[end..]))
}

fn lines<'a>(content: &'a str, base: usize) -> Vec<Line<'a>> {
    let mut result = Vec::new();
    let mut offset = 0;
    while offset < content.len() {
        let next = content[offset..]
            .find('\n')
            .map_or(content.len(), |index| offset + index);
        let end = if next < content.len() { next + 1 } else { next };
        result.push(Line {
            start: base + offset,
            end: base + end,
            text: &content[offset..next],
        });
        offset = end;
    }
    result
}

fn unsupported(message: &str) -> CommandError {
    CommandError::new("unsupported_metadata_front_matter", message)
}

fn invalid(message: &str) -> CommandError {
    CommandError::new("invalid_metadata_batch_operation", message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn add(value: &str) -> MetadataBatchOperation {
        MetadataBatchOperation {
            kind: MetadataBatchOperationKind::Add,
            value: value.to_string(),
            replacement: None,
        }
    }

    fn remove(value: &str) -> MetadataBatchOperation {
        MetadataBatchOperation {
            kind: MetadataBatchOperationKind::Remove,
            value: value.to_string(),
            replacement: None,
        }
    }

    fn rename(value: &str, replacement: &str) -> MetadataBatchOperation {
        MetadataBatchOperation {
            kind: MetadataBatchOperationKind::Rename,
            value: value.to_string(),
            replacement: Some(replacement.to_string()),
        }
    }

    #[test]
    fn edits_yaml_flow_arrays_without_touching_comments_or_body() {
        let source = "---\ntitle: Keep # untouched\ntags: [\"Rust\", \"中文\"]\nsummary: keep\n---\nBody\nunchanged\n";
        let edit =
            transform_metadata_field(source, &MetadataBatchField::Tags, &add("rust， 新值\n中文"))
                .unwrap();
        assert_eq!(edit.original_values, ["Rust", "中文"]);
        assert_eq!(edit.proposed_values, ["Rust", "中文", "新值"]);
        assert_eq!(edit.text, "---\ntitle: Keep # untouched\ntags: [\"Rust\",\"中文\",\"新值\"]\nsummary: keep\n---\nBody\nunchanged\n");
    }

    #[test]
    fn removes_renames_and_keeps_noops_byte_identical() {
        let source = "---\ntags: [\"One\", \"Two\"]\n---\nBody\n";
        let removed =
            transform_metadata_field(source, &MetadataBatchField::Tags, &remove("one")).unwrap();
        assert_eq!(removed.proposed_values, ["Two"]);
        let renamed =
            transform_metadata_field(source, &MetadataBatchField::Tags, &rename("two", "Three"))
                .unwrap();
        assert_eq!(renamed.proposed_values, ["One", "Three"]);
        let noop =
            transform_metadata_field(source, &MetadataBatchField::Tags, &add("TWO")).unwrap();
        assert_eq!(noop.text, source);
        assert_eq!(noop.original_values, noop.proposed_values);
    }

    #[test]
    fn edits_yaml_indented_lists_and_toml_arrays() {
        let yaml = "---\ntags:\n  - Rust\n  - 中文\ntitle: Keep\n---\nBody\n";
        let yaml_edit =
            transform_metadata_field(yaml, &MetadataBatchField::Tags, &remove("rust")).unwrap();
        assert_eq!(
            yaml_edit.text,
            "---\ntags: [\"中文\"]\ntitle: Keep\n---\nBody\n"
        );

        let toml = "+++\ntitle = \"Keep\" # untouched\ncategories = [\"News\"]\n+++\nBody\n";
        let toml_edit =
            transform_metadata_field(toml, &MetadataBatchField::Categories, &add("Updates"))
                .unwrap();
        assert_eq!(
            toml_edit.text,
            "+++\ntitle = \"Keep\" # untouched\ncategories = [\"News\",\"Updates\"]\n+++\nBody\n"
        );
    }

    #[test]
    fn inserts_only_additions_when_a_safe_field_is_missing() {
        let source = "---\ntitle: Keep\n---\nBody\n";
        let edit =
            transform_metadata_field(source, &MetadataBatchField::Tags, &add("New")).unwrap();
        assert_eq!(edit.original_values, Vec::<String>::new());
        assert_eq!(edit.text, "---\ntitle: Keep\ntags: [\"New\"]\n---\nBody\n");
        let noop =
            transform_metadata_field(source, &MetadataBatchField::Tags, &remove("New")).unwrap();
        assert_eq!(noop.text, source);
    }

    #[test]
    fn rejects_ambiguous_or_complex_target_syntax() {
        for source in [
            "---\ntags: [\"a\"]\ntags: [\"b\"]\n---\nBody\n",
            "---\n\"tags\": [\"a\"]\n---\nBody\n",
            "---\ntags.extra: [\"a\"]\n---\nBody\n",
            "---\ntags: &shared [\"a\"]\n---\nBody\n",
            "---\ntags:\n  - nested: value\n---\nBody\n",
            "+++\n[metadata]\ntags = [\"a\"]\n+++\nBody\n",
            "+++\ndescription = \"\"\"\ntags = [\"a\"]\nother = \"\"\"\n+++\nBody\n",
            "+++\n\"ta\\u0067s\" = [\"a\"]\n+++\nBody\n",
            "---\n<<: {tags: [a]}\n---\nBody\n",
            "---\ndescription: \"open\ntags: [\"a\"]\nend: closed\"\n---\nBody\n",
            "---\ntags:\n  - true\n---\nBody\n",
            "---\ntags:\n  - !custom string\n---\nBody\n",
        ] {
            assert_eq!(
                transform_metadata_field(source, &MetadataBatchField::Tags, &add("b"))
                    .unwrap_err()
                    .code,
                "unsupported_metadata_front_matter"
            );
        }
    }

    #[test]
    fn rejects_output_that_exceeds_its_own_parser_budget() {
        let values = (20..30)
            .map(|index| format!("{index}{}", "中".repeat(120)))
            .collect::<Vec<_>>()
            .join(",");
        assert!(values.len() < MAX_INPUT_BYTES);
        // Multiple calls can grow a field past the parser budget even with bounded individual input.
        let first = (0..20)
            .map(|index| format!("{index}{}", "中".repeat(120)))
            .collect::<Vec<_>>();
        let source = format!(
            "---\ntags: {}\n---\nBody",
            serde_json::to_string(&first).unwrap()
        );
        assert!(transform_metadata_field(
            &source,
            &MetadataBatchField::Tags,
            &add(&format!("extra{}", "中".repeat(120)))
        )
        .is_ok());
        assert!(
            transform_metadata_field(&source, &MetadataBatchField::Tags, &add(&values)).is_err()
        );
        let source = format!(
            "---\n# {}\n---\nBody",
            "a".repeat(MAX_FRONT_MATTER_BYTES - 20)
        );
        assert!(transform_metadata_field(
            &source,
            &MetadataBatchField::Tags,
            &add(&"b".repeat(128))
        )
        .is_err());
    }

    #[test]
    fn quoted_symbols_round_trip_and_unquoted_aliases_remain_unsupported() {
        for source in ["---\ntags: []\n---\nBody", "+++\ntags = []\n+++\nBody"] {
            let operation = add("C#,Research & Design,*literal,quote\"inside");
            let edit =
                transform_metadata_field(source, &MetadataBatchField::Tags, &operation).unwrap();
            let second =
                transform_metadata_field(&edit.text, &MetadataBatchField::Tags, &operation)
                    .unwrap();
            assert_eq!(second.text, edit.text);
            assert_eq!(
                second.original_values,
                ["C#", "Research & Design", "*literal", "quote\"inside"]
            );
        }
        assert!(transform_metadata_field(
            "---\ntitle: *alias\ntags: []\n---\nBody",
            &MetadataBatchField::Tags,
            &add("x")
        )
        .is_err());
    }

    #[test]
    fn rejects_missing_or_oversized_front_matter_and_invalid_renames() {
        assert!(
            transform_metadata_field("# Body\n", &MetadataBatchField::Tags, &add("a")).is_err()
        );
        let oversized = format!("---\n{}\n---\nBody\n", "x".repeat(MAX_FRONT_MATTER_BYTES));
        assert!(
            transform_metadata_field(&oversized, &MetadataBatchField::Tags, &add("a")).is_err()
        );
        let source = "---\ntags: [\"a\"]\n---\nBody\n";
        assert_eq!(
            transform_metadata_field(source, &MetadataBatchField::Tags, &rename("a,b", "c"))
                .unwrap_err()
                .code,
            "invalid_metadata_batch_operation"
        );
    }
}
