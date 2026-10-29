//! Drives the core's ACP adapter against the scripted mock agent,
//! `Tests/Fixtures/harness/acp-mock-agent.py`, across a real process
//! boundary (spec #99, slice 2.4): the twin of Swift's
//! `ACPAdapterIntegrationTests`. The test carries out the adapter's effects
//! in order, the way `ACPAdapter.swift` does (spawn, write a line, close
//! stdin, emit). Publish, the kill grace and the watchdog are only noted,
//! and a write after stdin closed fails the test where Swift would skip it
//! (no case writes one), so those parts of the executor contract (DESIGN
//! v2.13 C) rest on the Swift test alone. The agent is shut down at the end.
//!
//! The mock records every line it reads and writes, and each test checks
//! that record against the matching "mock agent:" case of
//! `acp-adapter.json`: the lines the mock sent are the case's `line` steps,
//! byte for byte; the lines it read are the case's `writeStdin` lines, as
//! JSON; and the events the adapter emitted are the case's, in order.
//!
//! It needs Python 3: `POWERUP_PYTHON`, else `python3`, else `python`. With
//! none, the test is skipped with a note, except on CI (`CI` set), where a
//! missing Python fails it. No real agent is ever started.

mod support;

use std::env;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

use powerup_core::harness::acp::adapter::{AcpAdapter, AcpAdapterEffect};
use powerup_core::harness::acp::environment::is_scrubbed;
use powerup_core::harness::claude::lines::LineBuffer;
use powerup_core::harness::{HarnessConfiguration, HarnessEvent, HarnessState};
use serde_json::Value;
use support::{case_table, harness_event_descriptor};

/// How long one wait for the mock may take, as in the Swift tests.
const TIMEOUT: Duration = Duration::from_secs(10);

/// The project folder the "mock agent:" cases start in; the live run uses
/// its own temporary folder and the comparison maps one onto the other.
const CASE_PROJECT_DIR: &str = "/tmp";

/// The first Python that answers `--version`, or none.
fn python() -> Option<String> {
    let candidates = env::var("POWERUP_PYTHON")
        .ok()
        .into_iter()
        .chain(["python3".to_owned(), "python".to_owned()]);
    for candidate in candidates {
        let answers = Command::new(&candidate)
            .arg("--version")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .is_ok_and(|status| status.success());
        if answers {
            return Some(candidate);
        }
    }
    None
}

/// Python, or `None` after a skip note; on CI a missing Python fails.
fn python_or_skip(test: &str) -> Option<String> {
    let found = python();
    if found.is_none() {
        assert!(
            env::var_os("CI").is_none(),
            "{test}: Python 3 is required on CI (set POWERUP_PYTHON, or put python3 or python on PATH)"
        );
        eprintln!("{test}: skipped, no Python 3 found (set POWERUP_PYTHON to run it)");
    }
    found
}

/// The mock, in place in the shared fixtures. Not canonicalized: on Windows
/// that gives a `\\?\` path, which is no help to Python.
fn mock_script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("Tests")
        .join("Fixtures")
        .join("harness")
        .join("acp-mock-agent.py")
}

/// A fresh folder for one test: its project folder and the mock's record.
fn scratch_dir() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let dir = env::temp_dir().join(format!(
        "powerup-acp-mock-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&dir).unwrap_or_else(|e| panic!("can't create {}: {e}", dir.display()));
    dir
}

/// One adapter and the agent it runs, with the effects carried out as
/// `ACPAdapter.swift` carries them out.
struct Live {
    adapter: AcpAdapter,
    child: Option<Child>,
    stdin: Option<ChildStdin>,
    lines: Option<Receiver<Vec<u8>>>,
    events: Vec<HarnessEvent>,
    dir: PathBuf,
    project_dir: String,
    record: PathBuf,
}

impl Live {
    /// Starts the adapter on the mock, run with `python`.
    fn start(python: &str) -> Live {
        let dir = scratch_dir();
        let project = dir.join("project");
        fs::create_dir_all(&project)
            .unwrap_or_else(|e| panic!("can't create {}: {e}", project.display()));
        let record = dir.join("record.jsonl");
        let script = mock_script();
        assert!(
            script.is_file(),
            "the mock agent fixture is missing: {}",
            script.display()
        );
        let mut live = Live {
            adapter: AcpAdapter::new(),
            child: None,
            stdin: None,
            lines: None,
            events: Vec::new(),
            project_dir: project.to_string_lossy().into_owned(),
            dir,
            record: record.clone(),
        };
        let path = |p: &Path| p.to_string_lossy().into_owned();
        let effects = live.adapter.start(&HarnessConfiguration {
            project_dir: live.project_dir.clone(),
            model: "default".to_owned(),
            permission_mode: "default".to_owned(),
            effort: "default".to_owned(),
            resume_session_id: None,
            binary_path_override: None,
            agent_command: Some(vec![
                python.to_owned(),
                path(&script),
                "--record".to_owned(),
                path(&record),
            ]),
        });
        live.run(effects);
        live
    }

    /// Carries out the effects in order; a spawn reports back at once and
    /// its effects run before the rest.
    fn run(&mut self, effects: Vec<AcpAdapterEffect>) {
        for effect in effects {
            match effect {
                AcpAdapterEffect::Publish(_)
                | AcpAdapterEffect::TerminateAfterGrace { .. }
                | AcpAdapterEffect::ArmStartWatchdog { .. } => {}
                AcpAdapterEffect::Spawn {
                    generation,
                    executable,
                    arguments,
                    project_dir,
                } => self.spawn(generation, &executable, &arguments, &project_dir),
                AcpAdapterEffect::WriteStdin(line) => {
                    let stdin = self
                        .stdin
                        .as_mut()
                        .unwrap_or_else(|| panic!("a line to write with stdin closed"));
                    stdin
                        .write_all(&line)
                        .and_then(|()| stdin.flush())
                        .unwrap_or_else(|e| panic!("writing to the mock failed: {e}"));
                }
                AcpAdapterEffect::CloseStdin => self.stdin = None,
                AcpAdapterEffect::Emit(event) => self.events.push(event),
            }
        }
    }

    /// Spawns the agent with the scrubbed environment and three pipes;
    /// stderr goes to the test's own, so a Python traceback shows.
    fn spawn(
        &mut self,
        generation: u64,
        executable: &str,
        arguments: &[String],
        project_dir: &str,
    ) {
        let spawned = Command::new(executable)
            .args(arguments)
            .current_dir(project_dir)
            .env_clear()
            .envs(env::vars_os().filter(|(name, _)| !name.to_str().is_some_and(is_scrubbed)))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn();
        let mut child = match spawned {
            Ok(child) => child,
            Err(error) => {
                let effects = self
                    .adapter
                    .spawn_failed(generation, executable, &error.to_string());
                self.run(effects);
                return;
            }
        };
        let mut stdout = child
            .stdout
            .take()
            .unwrap_or_else(|| panic!("the mock has no stdout pipe"));
        let (send, receive) = mpsc::channel();
        thread::spawn(move || {
            let mut buffer = LineBuffer::new();
            let mut chunk = [0_u8; 4096];
            loop {
                match stdout.read(&mut chunk) {
                    Ok(0) | Err(_) => return,
                    Ok(read) => {
                        for line in buffer.ingest(&chunk[..read]) {
                            if send.send(line).is_err() {
                                return;
                            }
                        }
                    }
                }
            }
        });
        self.stdin = child.stdin.take();
        self.child = Some(child);
        self.lines = Some(receive);
        let effects = self.adapter.spawned(generation);
        self.run(effects);
    }

    /// Feeds the mock's lines to the adapter until an emitted event
    /// satisfies `done`.
    fn wait_for(&mut self, what: &str, done: impl Fn(&[HarnessEvent]) -> bool) {
        let deadline = Instant::now() + TIMEOUT;
        while !done(&self.events) {
            let left = deadline.saturating_duration_since(Instant::now());
            let line = match self.lines.as_ref().map(|lines| lines.recv_timeout(left)) {
                Some(Ok(line)) => line,
                Some(Err(RecvTimeoutError::Timeout)) => {
                    panic!(
                        "timed out waiting for {what}; events so far: {:?}",
                        self.events
                    )
                }
                Some(Err(RecvTimeoutError::Disconnected)) | None => {
                    panic!(
                        "the mock closed stdout before {what}; events so far: {:?}",
                        self.events
                    )
                }
            };
            let generation = self.adapter.generation();
            let effects = self.adapter.stdout_line(generation, &line);
            self.run(effects);
        }
    }

    fn count(&self, matches: impl Fn(&HarnessEvent) -> bool) -> usize {
        self.events.iter().filter(|event| matches(event)).count()
    }

    /// Checks the mock's record and the emitted events against the
    /// "mock agent:" case `name` of acp-adapter.json.
    fn assert_transcript_matches(&self, name: &str) {
        let file = "acp-adapter.json";
        let table = case_table("harness", file);
        let case = table
            .cases
            .iter()
            .find(|case| case.name == name)
            .unwrap_or_else(|| panic!("{file} has no case {name:?}"));
        let steps = case.input["steps"]
            .as_array()
            .unwrap_or_else(|| panic!("{file} case {name:?} has no steps"));
        let effect_lists = case.expected["effects"]
            .as_array()
            .unwrap_or_else(|| panic!("{file} case {name:?} has no effects"));
        let table_sent: Vec<&str> = steps
            .iter()
            .filter_map(|step| step["line"].as_str())
            .collect();
        let mut table_written = Vec::new();
        let mut table_events = Vec::new();
        for effect in effect_lists
            .iter()
            .flat_map(|list| list.as_array().into_iter().flatten())
        {
            match effect["effect"].as_str() {
                Some("writeStdin") => table_written.push(self.in_this_project(&effect["line"])),
                Some("emit") => table_events.push(effect["event"].clone()),
                _ => {}
            }
        }

        let record = fs::read_to_string(&self.record).unwrap_or_else(|e| {
            panic!(
                "can't read the mock's record {}: {e}",
                self.record.display()
            )
        });
        let mut sent = Vec::new();
        let mut received = Vec::new();
        // lines() also drops the \r Python writes before each newline on
        // Windows.
        for entry in record.lines() {
            let value: Value = serde_json::from_str(entry)
                .unwrap_or_else(|e| panic!("a record entry is not JSON: {e}: {entry:?}"));
            if let Some(text) = value["sent"].as_str() {
                sent.push(text.to_owned());
            } else if let Some(text) = value["received"].as_str() {
                received.push(serde_json::from_str::<Value>(text).unwrap_or_else(|e| {
                    panic!("the mock read a line that is not JSON: {e}: {text:?}")
                }));
            } else {
                panic!("an unknown record entry: {entry}");
            }
        }
        let events: Vec<Value> = self.events.iter().map(harness_event_descriptor).collect();
        assert_eq!(
            sent, table_sent,
            "the mock's lines differ from {file} case {name:?}"
        );
        assert_eq!(
            received, table_written,
            "the adapter's lines differ from {file} case {name:?}"
        );
        assert_eq!(
            events, table_events,
            "the adapter's events differ from {file} case {name:?}"
        );
    }

    /// A line of the case with the case's project folder replaced by this
    /// run's: only session/new carries it, as `cwd`.
    fn in_this_project(&self, line: &Value) -> Value {
        let mut line = line.clone();
        if let Some(cwd) = line.pointer_mut("/params/cwd") {
            if cwd.as_str() == Some(CASE_PROJECT_DIR) {
                *cwd = Value::from(self.project_dir.clone());
            }
        }
        line
    }
}

impl Drop for Live {
    /// Stops the session as the app does, then waits up to five seconds for
    /// the mock to exit before killing it, and removes the scratch folder.
    fn drop(&mut self) {
        // The stop closes stdin; its grace timer is the wait below.
        let _ = self.adapter.stop();
        self.stdin = None;
        if let Some(mut child) = self.child.take() {
            let deadline = Instant::now() + Duration::from_secs(5);
            while matches!(child.try_wait(), Ok(None)) && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(20));
            }
            if matches!(child.try_wait(), Ok(None)) {
                let _ = child.kill();
            }
            let _ = child.wait();
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn is_session_ready(event: &HarnessEvent) -> bool {
    matches!(event, HarnessEvent::SessionReady { .. })
}

fn is_permission_request(event: &HarnessEvent) -> bool {
    matches!(event, HarnessEvent::PermissionRequest { .. })
}

fn is_turn_completed(event: &HarnessEvent) -> bool {
    matches!(event, HarnessEvent::TurnCompleted { .. })
}

#[test]
fn the_handshake_reaches_session_ready() {
    let Some(python) = python_or_skip("the_handshake_reaches_session_ready") else {
        return;
    };
    let mut live = Live::start(&python);
    live.wait_for("sessionReady", |events| events.iter().any(is_session_ready));
    assert_eq!(
        live.events.last(),
        Some(&HarnessEvent::SessionReady {
            session_id: "mock-session".to_owned(),
            model: "mock/model-1".to_owned(),
        })
    );
    let snapshot = live.adapter.snapshot();
    assert_eq!(snapshot.state, HarnessState::Ready);
    assert_eq!(snapshot.session_id.as_deref(), Some("mock-session"));
    assert_eq!(snapshot.model_name.as_deref(), Some("mock/model-1"));
    live.assert_transcript_matches("mock agent: the handshake gives sessionReady");
}

#[test]
fn a_prompt_streams_a_tool_and_a_permission_and_completes() {
    let Some(python) = python_or_skip("a_prompt_streams_a_tool_and_a_permission_and_completes")
    else {
        return;
    };
    let mut live = Live::start(&python);
    live.wait_for("sessionReady", |events| events.iter().any(is_session_ready));

    let effects = live.adapter.send("do the thing");
    live.run(effects);
    assert_eq!(live.adapter.snapshot().state, HarnessState::Working);

    // A thought (never streamed), a chunk, a tool call, then a permission
    // request.
    live.wait_for("a permission request", |events| {
        events.iter().any(is_permission_request)
    });
    assert!(live
        .events
        .contains(&HarnessEvent::ReplyDelta("Working. ".to_owned())));
    assert!(live.events.contains(&HarnessEvent::ToolUse {
        name: "Edit File".to_owned(),
        detail: "a.swift".to_owned(),
    }));
    assert!(
        !live
            .events
            .contains(&HarnessEvent::ReplyDelta("thinking".to_owned())),
        "thought chunks must not leak into the reply stream"
    );
    let Some(HarnessEvent::PermissionRequest { id, name, kind, .. }) = live
        .events
        .iter()
        .find(|event| is_permission_request(event))
        .cloned()
    else {
        panic!("no permission request captured: {:?}", live.events);
    };
    assert_eq!(name, "Edit a.swift");
    assert_eq!(
        kind, "edit",
        "the harness's tool kind must reach the classifier"
    );

    // Approve: the mock reports which option it got, then ends the turn.
    let effects = live.adapter.respond_to_permission(&id, true);
    live.run(effects);
    live.wait_for("the turn to complete", |events| {
        events.iter().any(is_turn_completed)
    });
    assert_eq!(
        live.events.last(),
        Some(&HarnessEvent::TurnCompleted {
            result_text: Some("Working. choice=allow-once".to_owned()),
            cost_usd: None,
            is_error: false,
            detail: "end_turn".to_owned(),
        }),
        "allow must pick the *_once option, and ACP reports no dollar cost"
    );
    assert!(live.events.contains(&HarnessEvent::Reply(
        "Working. choice=allow-once".to_owned()
    )));
    assert_eq!(live.adapter.snapshot().state, HarnessState::Ready);
    assert_eq!(
        live.adapter.snapshot().total_tokens,
        150,
        "per-turn usage accumulates (100 in + 50 out)"
    );

    // A second turn adds to the total instead of replacing it.
    let effects = live.adapter.send("again");
    live.run(effects);
    live.wait_for("a second permission request", |events| {
        events
            .iter()
            .filter(|event| is_permission_request(event))
            .count()
            == 2
    });
    let Some(HarnessEvent::PermissionRequest { id: second, .. }) = live
        .events
        .iter()
        .rev()
        .find(|event| is_permission_request(event))
        .cloned()
    else {
        panic!("no second permission request: {:?}", live.events);
    };
    let effects = live.adapter.respond_to_permission(&second, true);
    live.run(effects);
    live.wait_for("the second turn to complete", |events| {
        events
            .iter()
            .filter(|event| is_turn_completed(event))
            .count()
            == 2
    });
    assert_eq!(live.count(is_turn_completed), 2);
    assert_eq!(
        live.adapter.snapshot().total_tokens,
        300,
        "usage accumulates across turns"
    );
    live.assert_transcript_matches(
        "mock agent: a prompt streams a reply, a tool and a permission, and completes",
    );
}

#[test]
fn set_model_is_accepted_then_rejected() {
    let Some(python) = python_or_skip("set_model_is_accepted_then_rejected") else {
        return;
    };
    let mut live = Live::start(&python);
    live.wait_for("sessionReady", |events| events.iter().any(is_session_ready));

    let accepted = HarnessEvent::ControlResult {
        action: "set_model".to_owned(),
        ok: true,
        detail: String::new(),
        value: Some("mock/model-2".to_owned()),
    };
    let effects = live.adapter.set_model("mock/model-2");
    live.run(effects);
    live.wait_for("set_model accepted", |events| events.contains(&accepted));
    assert_eq!(
        live.adapter.snapshot().model_name.as_deref(),
        Some("mock/model-2")
    );

    let rejected = HarnessEvent::ControlResult {
        action: "set_model".to_owned(),
        ok: false,
        detail: "unknown model".to_owned(),
        value: Some("bad".to_owned()),
    };
    let effects = live.adapter.set_model("bad");
    live.run(effects);
    live.wait_for("set_model rejected", |events| events.contains(&rejected));
    assert_eq!(
        live.adapter.snapshot().model_name.as_deref(),
        Some("mock/model-2"),
        "a rejected switch must not change the model"
    );
    live.assert_transcript_matches("mock agent: set_model accepted, then rejected");
}
