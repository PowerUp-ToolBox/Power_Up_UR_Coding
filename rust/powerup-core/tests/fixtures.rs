//! The shared fixtures are reachable and well-formed from Rust (#140). An
//! empty or misplaced directory fails here, so no later slice can pass
//! vacuously.

mod support;

use support::{fixtures_dir, json_files, load_case_table, load_session};

#[test]
fn the_shared_fixtures_directory_is_not_empty() {
    let all = json_files("");
    assert!(
        !all.is_empty(),
        "{} holds no JSON fixtures",
        fixtures_dir().display()
    );
    assert!(!json_files("session").is_empty(), "no session scenarios");
}

#[test]
fn every_session_scenario_loads() {
    for path in json_files("session") {
        load_session(&path);
    }
}

#[test]
fn every_case_table_loads() {
    for area in [
        "status",
        "text-safety",
        "mapping",
        "device",
        "harness",
        "config",
        "transcript",
        "hooks",
    ] {
        let files = json_files(area);
        assert!(!files.is_empty(), "no case tables in {area}/");
        for path in files {
            load_case_table(&path);
        }
    }
}

#[test]
fn a_session_scenario_parses_into_its_parts() {
    let path =
        fixtures_dir().join("session/remote-hooks-outside-the-project-folder-are-ignored.json");
    let scenario = load_session(&path);
    assert_eq!(scenario.verified_by, ["swift", "rust"]);
    assert_eq!(scenario.config["controlMode"], "remote");
    assert_eq!(scenario.script.len(), 7);
    assert_eq!(
        scenario.expect["transcript"][1]["text"],
        "[api] API docs written."
    );
}

#[test]
fn every_fixture_is_a_known_format() {
    for path in json_files("") {
        let relative = path.strip_prefix(fixtures_dir()).unwrap_or(&path);
        let area = relative
            .components()
            .next()
            .and_then(|c| c.as_os_str().to_str());
        assert!(
            matches!(
                area,
                Some(
                    "session"
                        | "status"
                        | "text-safety"
                        | "mapping"
                        | "device"
                        | "harness"
                        | "config"
                        | "transcript"
                        | "hooks"
                )
            ),
            "{}: unknown fixture area; teach tests/support how to load it",
            relative.display()
        );
    }
}
