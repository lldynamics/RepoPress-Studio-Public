//! Shared producer output through the real Linux metadata transformer.
//! This does not implement or claim full renderer conformance.
use super::metadata_field::{
    transform_metadata_field, MetadataBatchField, MetadataBatchOperation,
    MetadataBatchOperationKind,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{fs, path::Path};

#[test]
fn shared_yaml_outputs_preserve_taxonomies_and_original_bytes() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Shared/RepoPressCoreContracts/contracts/fixtures/v1");
    let manifest: Value =
        serde_json::from_slice(&fs::read(root.join("manifest.json")).unwrap()).unwrap();
    let cases = manifest["cases"].as_array().unwrap();
    let mut consumed = Vec::new();
    for entry in cases {
        let path = entry["path"].as_str().unwrap();
        if !path.starts_with("front-matter-document/front-yaml-") {
            continue;
        }
        let bytes = fs::read(root.join(path)).unwrap();
        assert_eq!(
            format!("{:x}", Sha256::digest(&bytes)),
            entry["sha256"].as_str().unwrap(),
            "fixture digest: {path}"
        );
        let fixture: Value = serde_json::from_slice(&bytes).unwrap();
        let id = fixture["id"].as_str().unwrap();
        assert_eq!(fixture["capability"], "front-matter-document", "{id}");
        assert_eq!(fixture["validity"], "valid", "{id}");
        assert_eq!(fixture["expected"]["ok"], true, "{id}");
        let source = fixture["expected"]["value"]["text"].as_str().unwrap();
        let document = &fixture["input"]["document"];
        for (key, field) in [
            ("tags", MetadataBatchField::Tags),
            ("categories", MetadataBatchField::Categories),
        ] {
            let expected: Vec<String> = serde_json::from_value(document[key].clone()).unwrap();
            // Removing an absent value is a legitimate no-op through the
            // product transformer and must preserve all unowned metadata/body.
            let operation = MetadataBatchOperation {
                kind: MetadataBatchOperationKind::Remove,
                value: "p60-absent-fixture-value".to_owned(),
                replacement: None,
            };
            assert!(!expected.iter().any(|value| value == &operation.value));
            let edit = transform_metadata_field(source, &field, &operation)
                .unwrap_or_else(|error| panic!("{id}/{key}: {error:?}"));
            assert_eq!(edit.original_values, expected, "{id}/{key}");
            assert_eq!(edit.proposed_values, expected, "{id}/{key}");
            assert_eq!(edit.text, source, "{id}/{key}: original bytes");
        }
        consumed.push(id.to_owned());
    }
    assert_eq!(
        consumed,
        [
            "front-yaml-empty-fields-render",
            "front-yaml-full-render",
            "front-yaml-markdown-trim",
            "front-yaml-minimal-render",
            "front-yaml-unicode-render",
        ]
    );
}
