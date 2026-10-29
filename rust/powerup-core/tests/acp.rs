//! Plays the ACP adapter's `Tests/Fixtures/harness/acp-*.json` tables (spec
//! #99, slice 2.4) against the core.

mod support;

use powerup_core::harness::acp::adapter::{AcpAdapter, AcpAdapterEffect};
use powerup_core::harness::acp::agents::{agent_launch, AgentProgram};
use powerup_core::harness::acp::environment::is_scrubbed;
use powerup_core::harness::acp::permission::{permission_choice, PermissionOption};
use powerup_core::harness::HarnessConfiguration;
use serde_json::Value;
use support::{acp_effect_descriptor, acp_snapshot_fields, case_table, line_input_bytes};

fn fail(file: &str, name: &str, reason: &str, expected: &Value, actual: &Value) -> String {
    format!("{file} case {name:?} failed (guards: {reason})\n  expected: {expected}\n  actual:   {actual}")
}

/// Runs one acp step and returns its effects. Every step has exactly one key
/// and every field is required, so a typo fails loudly. The fields ACP
/// ignores are filled as the Swift runner fills them.
fn acp_step(adapter: &mut AcpAdapter, step: &Value) -> Vec<AcpAdapterEffect> {
    let fields = step
        .as_object()
        .unwrap_or_else(|| panic!("a step is not an object: {step}"));
    let keys: Vec<&str> = fields.keys().map(String::as_str).collect();
    let string = |value: &Value, what: &str| -> String {
        value
            .as_str()
            .unwrap_or_else(|| panic!("{what} must be a string: {step}"))
            .to_owned()
    };
    let exit = |value: &Value| -> (i32, String) {
        let code = value["exitCode"]
            .as_i64()
            .and_then(|code| i32::try_from(code).ok())
            .unwrap_or_else(|| panic!("exitCode must be an Int32: {step}"));
        (code, string(&value["stderrTail"], "stderrTail"))
    };
    let current = adapter.generation();
    let retired = current.wrapping_sub(1);
    match keys.as_slice() {
        ["start"] => {
            let config = &fields["start"];
            let command = &config["agentCommand"];
            let agent_command = if command.is_null() {
                None
            } else {
                Some(
                    command
                        .as_array()
                        .unwrap_or_else(|| panic!("agentCommand must be a list or null: {step}"))
                        .iter()
                        .map(|part| string(part, "an agentCommand part"))
                        .collect(),
                )
            };
            adapter.start(&HarnessConfiguration {
                project_dir: string(&config["projectDir"], "projectDir"),
                model: "default".to_owned(),
                permission_mode: "default".to_owned(),
                effort: "default".to_owned(),
                resume_session_id: None,
                binary_path_override: None,
                agent_command,
            })
        }
        ["spawned"] => adapter.spawned(current),
        ["spawnFailed"] => {
            let failure = &fields["spawnFailed"];
            adapter.spawn_failed(
                current,
                &string(&failure["executable"], "executable"),
                &string(&failure["description"], "description"),
            )
        }
        ["send"] => adapter.send(&string(&fields["send"], "send")),
        ["interrupt"] => adapter.interrupt(),
        ["respondToPermission"] => {
            let answer = &fields["respondToPermission"];
            let allow = answer["allow"]
                .as_bool()
                .unwrap_or_else(|| panic!("allow must be a bool: {step}"));
            adapter.respond_to_permission(&string(&answer["id"], "id"), allow)
        }
        ["setModel"] => adapter.set_model(&string(&fields["setModel"], "setModel")),
        ["setPermissionMode"] => {
            adapter.set_permission_mode(&string(&fields["setPermissionMode"], "setPermissionMode"))
        }
        ["stop"] => adapter.stop(),
        ["line"] => adapter.stdout_line(current, &line_input_bytes(&fields["line"])),
        ["retiredLine"] => adapter.stdout_line(retired, &line_input_bytes(&fields["retiredLine"])),
        ["terminated"] => {
            let (code, tail) = exit(&fields["terminated"]);
            adapter.terminated(current, code, &tail)
        }
        ["retiredTerminated"] => {
            let (code, tail) = exit(&fields["retiredTerminated"]);
            adapter.terminated(retired, code, &tail)
        }
        ["watchdog"] => adapter.start_watchdog_fired(current),
        ["retiredWatchdog"] => adapter.start_watchdog_fired(retired),
        _ => panic!("unknown acp step: {step}"),
    }
}

fn descriptors(effects: &[AcpAdapterEffect]) -> Value {
    Value::Array(effects.iter().map(acp_effect_descriptor).collect())
}

#[test]
fn acp_adapter_cases() {
    let file = "acp-adapter.json";
    let mut failures = Vec::new();
    for case in case_table("harness", file).cases {
        let steps = case.input["steps"]
            .as_array()
            .unwrap_or_else(|| panic!("{file} case {:?}: no steps", case.name));
        let mut adapter = AcpAdapter::new();
        let effects: Vec<Value> = steps
            .iter()
            .map(|step| descriptors(&acp_step(&mut adapter, step)))
            .collect();
        let actual = serde_json::json!({
            "effects": effects,
            "snapshot": acp_snapshot_fields(&adapter.snapshot()),
        });
        if actual != case.expected {
            failures.push(fail(
                file,
                &case.name,
                &case.reason,
                &case.expected,
                &actual,
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// The handshake every `acp-agent-lines.json` case starts from (the file's
/// `function` spells it out); it must end in sessionReady(s1, m1).
fn ready_adapter() -> AcpAdapter {
    let mut adapter = AcpAdapter::new();
    let steps = [
        serde_json::json!({"start": {"projectDir": "/work/app", "agentCommand": ["agent"]}}),
        serde_json::json!({"spawned": true}),
        serde_json::json!({"line": r#"{"jsonrpc":"2.0","id":1,"result":{}}"#}),
        serde_json::json!({"line": r#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1","models":{"currentModelId":"m1"}}}"#}),
    ];
    let mut last = Vec::new();
    for step in &steps {
        last = acp_step(&mut adapter, step);
    }
    assert_eq!(
        descriptors(&last),
        serde_json::json!([
            {"effect": "publish", "state": "ready", "sessionID": "s1", "modelName": "m1", "totalTokens": 0},
            {"effect": "emit", "event": {"type": "sessionReady", "sessionID": "s1", "model": "m1"}},
        ]),
        "the acp-agent-lines.json handshake no longer reaches sessionReady"
    );
    adapter
}

#[test]
fn acp_agent_lines_cases() {
    let file = "acp-agent-lines.json";
    let mut failures = Vec::new();
    for case in case_table("harness", file).cases {
        let mut adapter = ready_adapter();
        let generation = adapter.generation();
        let actual = descriptors(&adapter.stdout_line(generation, &line_input_bytes(&case.input)));
        if actual != case.expected {
            failures.push(fail(
                file,
                &case.name,
                &case.reason,
                &case.expected,
                &actual,
            ));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// Collects one table's failures and panics with all of them.
fn play_table(file: &str, mut actual: impl FnMut(&Value) -> Value) {
    let mut failures = Vec::new();
    for case in case_table("harness", file).cases {
        let got = actual(&case.input);
        if got != case.expected {
            failures.push(fail(file, &case.name, &case.reason, &case.expected, &got));
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn acp_permission_choice_cases() {
    play_table("acp-permission-choice.json", |input| {
        let options: Vec<PermissionOption> = input["options"]
            .as_array()
            .unwrap_or_else(|| panic!("options must be a list: {input}"))
            .iter()
            .map(|option| PermissionOption {
                option_id: option["optionId"]
                    .as_str()
                    .unwrap_or_else(|| panic!("optionId must be a string: {option}"))
                    .to_owned(),
                kind: option["kind"]
                    .as_str()
                    .unwrap_or_else(|| panic!("kind must be a string: {option}"))
                    .to_owned(),
            })
            .collect();
        let allow = input["allow"]
            .as_bool()
            .unwrap_or_else(|| panic!("allow must be a bool: {input}"));
        permission_choice(&options, allow).into()
    });
}

#[test]
fn acp_environment_cases() {
    play_table("acp-environment.json", |input| {
        let name = input
            .as_str()
            .unwrap_or_else(|| panic!("a variable name must be a string: {input}"));
        is_scrubbed(name).into()
    });
}

#[test]
fn acp_agent_launch_cases() {
    play_table("acp-agent-launch.json", |input| {
        let field = |key: &str| {
            input[key]
                .as_str()
                .unwrap_or_else(|| panic!("{key} must be a string: {input}"))
        };
        match agent_launch(field("agent"), field("customCommand")) {
            None => Value::Null,
            Some(launch) => {
                let program = match launch.program {
                    AgentProgram::Opencode => "opencode".into(),
                    AgentProgram::Npx => "npx".into(),
                    AgentProgram::Command(executable) => serde_json::json!({"command": executable}),
                };
                serde_json::json!({"program": program, "arguments": launch.arguments})
            }
        }
    });
}
