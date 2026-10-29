//! Plays every `Tests/Fixtures/session/` scenario on the core's session
//! machine (spec #98, slice 2.3): the same files `SessionScenarioTests`
//! plays through AppState.

#[path = "support/scenario.rs"]
mod scenario;
mod support;

use std::fs;

use scenario::{run, Scenario};
use serde_json::{json, Value};
use support::json_files;

fn load(path: &std::path::Path) -> Scenario {
    let file = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or_default()
        .to_owned();
    let text = fs::read_to_string(path).unwrap_or_else(|e| panic!("{file}: {e}"));
    let json: Value = serde_json::from_str(&text).unwrap_or_else(|e| panic!("{file}: {e}"));
    Scenario::parse(&json, &file).unwrap_or_else(|e| panic!("{e}"))
}

#[test]
fn every_session_scenario_holds() {
    let files = json_files("session");
    assert!(!files.is_empty(), "no session scenarios");
    let failures: Vec<String> = files.iter().flat_map(|path| run(&load(path))).collect();
    assert!(
        failures.is_empty(),
        "{} failure(s):\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn every_session_scenario_names_the_rust_runner() {
    for path in json_files("session") {
        let scenario = support::load_session(&path);
        assert!(
            scenario.verified_by.iter().any(|name| name == "rust"),
            "{}: verifiedBy must list \"rust\" once this runner plays it",
            path.display()
        );
    }
}

fn inline(script: Value, expect: Value) -> Value {
    json!({
        "formatVersion": 1,
        "name": "inline",
        "description": "A scenario written by the runner's own tests.",
        "reason": "The runner must notice what it is told to check.",
        "source": "tests/session.rs",
        "verifiedBy": ["rust"],
        "config": { "harnessKind": "claude", "project": true },
        "script": script,
        "expect": expect,
    })
}

#[test]
fn the_runner_notices_a_change_tagged_expect_no_change() {
    let json = inline(
        json!([{ "call": "startSessionIfNeeded", "expectNoChange": true }]),
        json!({ "errorShown": false }),
    );
    let failures = run(&Scenario::parse(&json, "inline.json").unwrap());
    assert_eq!(failures.len(), 1, "{failures:?}");
    assert!(
        failures[0].contains("is tagged expectNoChange but changed harnessCalls"),
        "{}",
        failures[0]
    );
}

#[test]
fn the_runner_reports_a_broken_expectation_with_its_path() {
    let json = inline(
        json!([{ "call": "startSessionIfNeeded" }]),
        json!({ "harnessCalls": [ { "type": "start", "resumeSessionID": "stale" } ] }),
    );
    let failures = run(&Scenario::parse(&json, "inline.json").unwrap());
    assert_eq!(
        failures,
        [concat!(
            "[inline] (inline.json) expect.harnessCalls[0].resumeSessionID: expected \"stale\", ",
            "got null — full entry {\"adapter\": \"claude\", \"agentCommand\": null, ",
            "\"binaryPathOverride\": null, \"effort\": \"default\", \"model\": \"default\", ",
            "\"permissionMode\": \"acceptEdits\", \"projectDir\": \"$project\", ",
            "\"resumeSessionID\": null, \"type\": \"start\"}"
        )]
    );
}

#[test]
fn the_runner_rejects_an_unknown_expectation_key() {
    let json = inline(
        json!([{ "call": "startSessionIfNeeded" }]),
        json!({ "lastSesionID": null }),
    );
    let error = Scenario::parse(&json, "inline.json").unwrap_err();
    assert!(
        error.starts_with("inline.json $.expect.lastSesionID: unknown key"),
        "{error}"
    );
}

#[test]
fn the_runner_rejects_a_step_with_two_kinds() {
    let json = inline(
        json!([{ "call": "newSession", "intent": "approve" }]),
        json!({ "errorShown": false }),
    );
    let error = Scenario::parse(&json, "inline.json").unwrap_err();
    assert!(
        error.contains("$.script[0]: a step has exactly one of"),
        "{error}"
    );
}
