//! Loader for the shared fixtures in `Tests/Fixtures/` (stage 2.1, #140):
//! the same files the Swift suites run, read from the repository root so the
//! two implementations can never drift onto separate copies. The formats are
//! described in `Tests/Fixtures/README.md`. The top-level keys match the Swift
//! loaders (`SessionScenario.swift`, `TextSafetyFixtures`) and the header
//! checks are slightly stricter, so a file that loads here loads there.

// Each test binary uses part of this module. And this is test support, not
// library code: a broken fixture should stop the test with the file named,
// which is what expect does.
#![allow(dead_code, clippy::expect_used)]

use std::fs;
use std::path::{Path, PathBuf};

use powerup_core::action::Action;
use powerup_core::intent::{ControlPhase, Intent};
use powerup_core::mapping::{default_device_mappings, DeviceMappings};
use serde::Deserialize;
use serde_json::Value;

/// `Tests/Fixtures/`, found from this crate's manifest (`rust/powerup-core`).
pub fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../Tests/Fixtures")
        .canonicalize()
        .expect("Tests/Fixtures must exist next to rust/")
}

/// Every `.json` file under `Tests/Fixtures/<area>` (or the whole directory
/// for `area == ""`), sorted for stable test output.
pub fn json_files(area: &str) -> Vec<PathBuf> {
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let entries =
            fs::read_dir(dir).unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()));
        for entry in entries {
            let path = entry.expect("directory entry").path();
            if path.is_dir() {
                walk(&path, out);
            } else if path.extension().is_some_and(|ext| ext == "json") {
                out.push(path);
            }
        }
    }
    let mut files = Vec::new();
    walk(&fixtures_dir().join(area), &mut files);
    files.sort();
    files
}

/// A session scenario (`session/`, format 1). The script and expectations
/// stay JSON until a core slice plays them.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SessionScenario {
    pub format_version: u32,
    pub name: String,
    pub description: String,
    pub reason: String,
    pub source: String,
    pub verified_by: Vec<String>,
    pub config: Value,
    pub script: Vec<Value>,
    pub expect: Value,
}

/// A case table (`text-safety/`, `status/`, `mapping/`).
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CaseTable {
    pub description: String,
    pub function: String,
    pub verified_by: String,
    #[serde(default)]
    pub captured_against: Option<String>,
    pub cases: Vec<Case>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Case {
    pub name: String,
    pub input: Value,
    pub expected: Value,
    pub reason: String,
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

/// Loads and checks one session scenario; panics naming the file on any
/// problem.
pub fn load_session(path: &Path) -> SessionScenario {
    let scenario: SessionScenario =
        serde_json::from_str(&read(path)).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let file = path.display();
    assert_eq!(
        scenario.format_version, 1,
        "{file}: unsupported formatVersion"
    );
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    assert_eq!(scenario.name, stem, "{file}: name must match the file name");
    for (field, value) in [
        ("description", &scenario.description),
        ("reason", &scenario.reason),
        ("source", &scenario.source),
    ] {
        assert!(!value.trim().is_empty(), "{file}: empty {field}");
    }
    assert!(!scenario.verified_by.is_empty(), "{file}: empty verifiedBy");
    assert!(!scenario.script.is_empty(), "{file}: empty script");
    scenario
}

/// Loads and checks one case table; panics naming the file and case on any
/// problem.
pub fn load_case_table(path: &Path) -> CaseTable {
    let table: CaseTable =
        serde_json::from_str(&read(path)).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let file = path.display();
    for (field, value) in [
        ("description", &table.description),
        ("function", &table.function),
        ("verifiedBy", &table.verified_by),
    ] {
        assert!(!value.trim().is_empty(), "{file}: empty {field}");
    }
    assert!(!table.cases.is_empty(), "{file}: no cases");
    let mut names = std::collections::HashSet::new();
    for case in &table.cases {
        assert!(
            !case.name.trim().is_empty(),
            "{file}: a case has a blank name"
        );
        assert!(
            names.insert(case.name.as_str()),
            "{file}: duplicate case {:?}",
            case.name
        );
        assert!(
            !case.reason.trim().is_empty(),
            "{file}: case {:?} has no reason",
            case.name
        );
    }
    table
}

// Value descriptors (`Tests/Fixtures/README.md`, `mapping/`). An unknown name
// panics with the descriptor, so a fixture typo never reads as a real value.

/// `{"case": <name>}`, plus `"prompt"` for sendPrompt.
pub fn action_from_descriptor(descriptor: &Value) -> Action {
    let name = descriptor["case"]
        .as_str()
        .unwrap_or_else(|| panic!("not an action descriptor: {descriptor}"));
    if name == "sendPrompt" {
        let prompt = descriptor["prompt"]
            .as_str()
            .unwrap_or_else(|| panic!("sendPrompt descriptor without a prompt: {descriptor}"));
        return Action::SendPrompt(prompt.to_owned());
    }
    Action::from_wire(&serde_json::json!({ name: {} }))
        .unwrap_or_else(|| panic!("unknown action case in {descriptor}"))
}

pub fn action_descriptor(action: &Action) -> Value {
    match action {
        Action::SendPrompt(prompt) => serde_json::json!({"case": "sendPrompt", "prompt": prompt}),
        other => serde_json::json!({"case": other.wire_name()}),
    }
}

/// `{"intent": <name>}`, plus `"mode"` for beginVoiceCapture and `"prompt"`
/// for sendPrompt.
pub fn intent_descriptor(intent: &Intent) -> Value {
    match intent {
        Intent::BeginVoiceCapture(mode) => {
            serde_json::json!({"intent": intent.name(), "mode": mode.name()})
        }
        Intent::SendPrompt(prompt) => {
            serde_json::json!({"intent": intent.name(), "prompt": prompt})
        }
        other => serde_json::json!({"intent": other.name()}),
    }
}

pub fn phase_from(name: &Value) -> ControlPhase {
    match name.as_str() {
        Some("began") => ControlPhase::Began,
        Some("ended") => ControlPhase::Ended,
        _ => panic!("unknown phase {name}"),
    }
}

/// `{profileID: {controlID: <action descriptor>}}`, or `"defaults"` for the
/// shipped default mappings.
pub fn mappings_from_descriptors(descriptor: &Value) -> DeviceMappings {
    if descriptor == "defaults" {
        return default_device_mappings();
    }
    let profiles = descriptor
        .as_object()
        .unwrap_or_else(|| panic!("not a mappings descriptor: {descriptor}"));
    profiles
        .iter()
        .map(|(profile_id, mapping)| {
            let controls = mapping
                .as_object()
                .unwrap_or_else(|| panic!("not a profile mapping: {mapping}"));
            let mapping = controls
                .iter()
                .map(|(control_id, action)| (control_id.clone(), action_from_descriptor(action)))
                .collect();
            (profile_id.clone(), mapping)
        })
        .collect()
}

pub fn mappings_descriptor(mappings: &DeviceMappings) -> Value {
    mappings
        .iter()
        .map(|(profile_id, mapping)| {
            let controls = mapping
                .iter()
                .map(|(control_id, action)| (control_id.clone(), action_descriptor(action)))
                .collect::<serde_json::Map<_, _>>();
            (profile_id.clone(), Value::Object(controls))
        })
        .collect::<serde_json::Map<_, _>>()
        .into()
}

/// The table at `Tests/Fixtures/<area>/<file>`.
pub fn case_table(area: &str, file: &str) -> CaseTable {
    load_case_table(&fixtures_dir().join(area).join(file))
}
