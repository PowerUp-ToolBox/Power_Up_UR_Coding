//! The ACP harness half of slice 2.4: the ACP adapter's JSON-RPC rules, the
//! permission choice, the agent presets and the environment scrub list
//! (DESIGN v2.13 A).
//!
//! As in `harness`, the types are the uniffi faces of their `powerup-core`
//! twins with a `Core` prefix, converted with exhaustive matches, and the
//! harness configuration, event and state types are reused from there. The
//! object here, `CoreAcpAdapter`, is owned by Swift and never calls back:
//! every call returns effects, and Swift carries them out in order.

use std::sync::{Arc, Mutex};

use powerup_core::harness::acp::adapter::{AcpAdapter, AcpAdapterEffect, AcpSnapshot};
use powerup_core::harness::acp::agents::{self, AgentLaunch, AgentProgram};
use powerup_core::harness::acp::environment::{SCRUBBED_NAMES, SCRUBBED_PREFIXES};
use powerup_core::harness::acp::permission::{self, PermissionOption};
use powerup_core::harness::HarnessConfiguration;

use crate::harness::{CoreHarnessConfiguration, CoreHarnessEvent, CoreHarnessState};
use crate::{contain, locked, CoreBridgeError};

/// The ACP adapter's published state.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreAcpSnapshot {
    pub state: CoreHarnessState,
    pub session_id: Option<String>,
    pub model_name: Option<String>,
    /// Summed per-turn usage; ACP reports no dollars (HK-141, HK-142).
    pub total_tokens: i64,
}

impl From<AcpSnapshot> for CoreAcpSnapshot {
    fn from(snapshot: AcpSnapshot) -> Self {
        CoreAcpSnapshot {
            state: snapshot.state.into(),
            session_id: snapshot.session_id,
            model_name: snapshot.model_name,
            total_tokens: snapshot.total_tokens,
        }
    }
}

/// What the ACP adapter asks the platform to do, case for case with
/// `powerup_core::harness::acp::adapter::AcpAdapterEffect`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreAcpEffect {
    Publish {
        snapshot: CoreAcpSnapshot,
    },
    Spawn {
        generation: u64,
        executable: String,
        arguments: Vec<String>,
        project_dir: String,
    },
    WriteStdin {
        line: Vec<u8>,
    },
    CloseStdin,
    TerminateAfterGrace {
        seconds: f64,
    },
    ArmStartWatchdog {
        generation: u64,
        seconds: f64,
    },
    Emit {
        event: CoreHarnessEvent,
    },
}

impl From<AcpAdapterEffect> for CoreAcpEffect {
    fn from(effect: AcpAdapterEffect) -> Self {
        match effect {
            AcpAdapterEffect::Publish(snapshot) => CoreAcpEffect::Publish {
                snapshot: snapshot.into(),
            },
            AcpAdapterEffect::Spawn {
                generation,
                executable,
                arguments,
                project_dir,
            } => CoreAcpEffect::Spawn {
                generation,
                executable,
                arguments,
                project_dir,
            },
            AcpAdapterEffect::WriteStdin(line) => CoreAcpEffect::WriteStdin { line },
            AcpAdapterEffect::CloseStdin => CoreAcpEffect::CloseStdin,
            AcpAdapterEffect::TerminateAfterGrace { seconds } => {
                CoreAcpEffect::TerminateAfterGrace { seconds }
            }
            AcpAdapterEffect::ArmStartWatchdog {
                generation,
                seconds,
            } => CoreAcpEffect::ArmStartWatchdog {
                generation,
                seconds,
            },
            AcpAdapterEffect::Emit(event) => CoreAcpEffect::Emit {
                event: event.into(),
            },
        }
    }
}

fn converted(effects: Vec<AcpAdapterEffect>) -> Vec<CoreAcpEffect> {
    effects.into_iter().map(Into::into).collect()
}

/// The ACP adapter's rules (`adapter::AcpAdapter`). Swift creates one per
/// `ACPAdapter` and keeps it across launches; the launch generation and the
/// JSON-RPC ids live inside. Every call returns effects for Swift to run in
/// order before the next call. It is called on the main actor; the lock
/// only keeps the object sound.
#[derive(Debug, uniffi::Object)]
pub struct CoreAcpAdapter {
    adapter: Mutex<AcpAdapter>,
}

impl CoreAcpAdapter {
    fn run(
        &self,
        call: impl FnOnce(&mut AcpAdapter) -> Vec<AcpAdapterEffect>,
    ) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        contain(|| Ok(converted(call(&mut locked(&self.adapter)))))
    }
}

#[uniffi::export]
impl CoreAcpAdapter {
    /// A stopped adapter at generation 0.
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CoreBridgeError> {
        contain(|| {
            Ok(Arc::new(CoreAcpAdapter {
                adapter: Mutex::new(AcpAdapter::new()),
            }))
        })
    }

    /// The current launch's generation.
    pub fn generation(&self) -> Result<u64, CoreBridgeError> {
        contain(|| Ok(locked(&self.adapter).generation()))
    }

    /// The published state as it is now.
    pub fn snapshot(&self) -> Result<CoreAcpSnapshot, CoreBridgeError> {
        contain(|| Ok(locked(&self.adapter).snapshot().into()))
    }

    pub fn start(
        &self,
        configuration: CoreHarnessConfiguration,
    ) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        let configuration = HarnessConfiguration::from(configuration);
        self.run(|adapter| adapter.start(&configuration))
    }

    pub fn spawned(&self, generation: u64) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.spawned(generation))
    }

    pub fn spawn_failed(
        &self,
        generation: u64,
        executable: String,
        description: String,
    ) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.spawn_failed(generation, &executable, &description))
    }

    pub fn send(&self, text: String) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.send(&text))
    }

    pub fn interrupt(&self) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(AcpAdapter::interrupt)
    }

    pub fn set_model(&self, model: String) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.set_model(&model))
    }

    pub fn set_permission_mode(&self, mode: String) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.set_permission_mode(&mode))
    }

    pub fn respond_to_permission(
        &self,
        id: String,
        allow: bool,
    ) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.respond_to_permission(&id, allow))
    }

    pub fn stop(&self) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(AcpAdapter::stop)
    }

    /// One raw stdout line of `generation`, without its newline, fed one at
    /// a time.
    pub fn stdout_line(
        &self,
        generation: u64,
        line: Vec<u8>,
    ) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.stdout_line(generation, &line))
    }

    /// The agent of `generation` exited.
    pub fn terminated(
        &self,
        generation: u64,
        exit_code: i32,
        stderr_tail: String,
    ) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.terminated(generation, exit_code, &stderr_tail))
    }

    /// The start watchdog armed for `generation` fired.
    pub fn start_watchdog_fired(
        &self,
        generation: u64,
    ) -> Result<Vec<CoreAcpEffect>, CoreBridgeError> {
        self.run(|adapter| adapter.start_watchdog_fired(generation))
    }
}

/// One option of a permission request.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreAcpPermissionOption {
    pub option_id: String,
    pub kind: String,
}

/// The option that answers a permission request, or none (answered
/// cancelled) (`permission::permission_choice`, HK-131).
#[uniffi::export]
pub fn acp_permission_choice(
    options: Vec<CoreAcpPermissionOption>,
    allow: bool,
) -> Result<Option<String>, CoreBridgeError> {
    contain(|| {
        let options: Vec<PermissionOption> = options
            .into_iter()
            .map(|option| PermissionOption {
                option_id: option.option_id,
                kind: option.kind,
            })
            .collect();
        Ok(permission::permission_choice(&options, allow).map(str::to_owned))
    })
}

/// The program an ACP agent runs, case for case with
/// `powerup_core::harness::acp::agents::AgentProgram`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreAcpProgram {
    Opencode,
    Npx,
    Command { executable: String },
}

/// An agent's program and the arguments that follow it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreAcpAgentLaunch {
    pub program: CoreAcpProgram,
    pub arguments: Vec<String>,
}

impl From<AgentLaunch> for CoreAcpAgentLaunch {
    fn from(launch: AgentLaunch) -> Self {
        let program = match launch.program {
            AgentProgram::Opencode => CoreAcpProgram::Opencode,
            AgentProgram::Npx => CoreAcpProgram::Npx,
            AgentProgram::Command(executable) => CoreAcpProgram::Command { executable },
        };
        CoreAcpAgentLaunch {
            program,
            arguments: launch.arguments,
        }
    }
}

/// How the stored ACP agent is launched before the platform looks its
/// program up, or none (`agents::agent_launch`, HK-129, HK-130).
#[uniffi::export]
pub fn acp_agent_launch(
    agent: String,
    custom_command: String,
) -> Result<Option<CoreAcpAgentLaunch>, CoreBridgeError> {
    contain(|| Ok(agents::agent_launch(&agent, &custom_command).map(Into::into)))
}

/// The variables removed from a spawned agent's environment: exact names,
/// and prefixes (HK-127).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreAcpEnvironmentScrub {
    pub names: Vec<String>,
    pub prefixes: Vec<String>,
}

/// The scrub list as data; the platform applies it to its own environment
/// (`environment::SCRUBBED_NAMES`, `SCRUBBED_PREFIXES`).
#[uniffi::export]
pub fn acp_environment_scrub() -> Result<CoreAcpEnvironmentScrub, CoreBridgeError> {
    contain(|| {
        Ok(CoreAcpEnvironmentScrub {
            names: SCRUBBED_NAMES
                .iter()
                .map(|name| (*name).to_owned())
                .collect(),
            prefixes: SCRUBBED_PREFIXES
                .iter()
                .map(|prefix| (*prefix).to_owned())
                .collect(),
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use powerup_core::harness::{HarnessEvent, HarnessState};

    #[test]
    fn every_acp_effect_converts() {
        let snapshot = AcpSnapshot {
            state: HarnessState::Ready,
            session_id: Some("s".to_owned()),
            model_name: None,
            total_tokens: i64::MAX,
        };
        let pairs = [
            (
                AcpAdapterEffect::Publish(snapshot),
                CoreAcpEffect::Publish {
                    snapshot: CoreAcpSnapshot {
                        state: CoreHarnessState::Ready,
                        session_id: Some("s".to_owned()),
                        model_name: None,
                        total_tokens: i64::MAX,
                    },
                },
            ),
            (
                AcpAdapterEffect::Spawn {
                    generation: 3,
                    executable: "agent".to_owned(),
                    arguments: vec!["acp".to_owned()],
                    project_dir: "/work".to_owned(),
                },
                CoreAcpEffect::Spawn {
                    generation: 3,
                    executable: "agent".to_owned(),
                    arguments: vec!["acp".to_owned()],
                    project_dir: "/work".to_owned(),
                },
            ),
            (
                AcpAdapterEffect::WriteStdin(b"{}\n".to_vec()),
                CoreAcpEffect::WriteStdin {
                    line: b"{}\n".to_vec(),
                },
            ),
            (AcpAdapterEffect::CloseStdin, CoreAcpEffect::CloseStdin),
            (
                AcpAdapterEffect::TerminateAfterGrace { seconds: 2.0 },
                CoreAcpEffect::TerminateAfterGrace { seconds: 2.0 },
            ),
            (
                AcpAdapterEffect::ArmStartWatchdog {
                    generation: 4,
                    seconds: 30.0,
                },
                CoreAcpEffect::ArmStartWatchdog {
                    generation: 4,
                    seconds: 30.0,
                },
            ),
            (
                AcpAdapterEffect::Emit(HarnessEvent::Ended { exit_code: 1 }),
                CoreAcpEffect::Emit {
                    event: CoreHarnessEvent::Ended { exit_code: 1 },
                },
            ),
        ];
        for (core, bridge) in pairs {
            assert_eq!(CoreAcpEffect::from(core), bridge);
        }
    }

    #[test]
    fn the_acp_adapter_object_runs_the_core_rules() {
        let adapter = CoreAcpAdapter::new().unwrap();
        assert_eq!(adapter.generation(), Ok(0));
        let effects = adapter
            .start(CoreHarnessConfiguration {
                project_dir: "/work/app".to_owned(),
                model: "default".to_owned(),
                permission_mode: "default".to_owned(),
                effort: "default".to_owned(),
                resume_session_id: None,
                binary_path_override: None,
                agent_command: Some(vec!["agent".to_owned(), "acp".to_owned()]),
            })
            .unwrap();
        assert_eq!(
            effects,
            vec![
                CoreAcpEffect::Publish {
                    snapshot: CoreAcpSnapshot {
                        state: CoreHarnessState::Starting,
                        session_id: None,
                        model_name: None,
                        total_tokens: 0,
                    }
                },
                CoreAcpEffect::Spawn {
                    generation: 1,
                    executable: "agent".to_owned(),
                    arguments: vec!["acp".to_owned()],
                    project_dir: "/work/app".to_owned(),
                },
            ]
        );
        assert!(matches!(
            adapter.spawned(1).unwrap().as_slice(),
            [
                CoreAcpEffect::WriteStdin { .. },
                CoreAcpEffect::ArmStartWatchdog { generation: 1, .. }
            ]
        ));
        assert!(matches!(
            adapter
                .stdout_line(1, br#"{"jsonrpc":"2.0","id":1,"result":{}}"#.to_vec())
                .unwrap()
                .as_slice(),
            [CoreAcpEffect::WriteStdin { .. }]
        ));
        let session = br#"{"jsonrpc":"2.0","id":2,"result":{"sessionId":"s1"}}"#;
        assert_eq!(
            adapter.stdout_line(1, session.to_vec()).unwrap().last(),
            Some(&CoreAcpEffect::Emit {
                event: CoreHarnessEvent::SessionReady {
                    session_id: "s1".to_owned(),
                    model: "acp".to_owned(),
                }
            })
        );
        assert_eq!(adapter.snapshot().unwrap().state, CoreHarnessState::Ready);
        // A retired launch's watchdog does nothing.
        assert_eq!(adapter.start_watchdog_fired(0), Ok(vec![]));
    }

    #[test]
    fn the_permission_choice_answers_like_the_core() {
        let option = |id: &str, kind: &str| CoreAcpPermissionOption {
            option_id: id.to_owned(),
            kind: kind.to_owned(),
        };
        let options = vec![
            option("aa", "allow_always"),
            option("ao", "allow_once"),
            option("ro", "reject_once"),
        ];
        assert_eq!(
            acp_permission_choice(options.clone(), true),
            Ok(Some("ao".to_owned()))
        );
        assert_eq!(
            acp_permission_choice(options, false),
            Ok(Some("ro".to_owned()))
        );
        assert_eq!(acp_permission_choice(vec![], true), Ok(None));
    }

    #[test]
    fn the_scrub_list_crosses_unchanged() {
        assert_eq!(
            acp_environment_scrub(),
            Ok(CoreAcpEnvironmentScrub {
                names: vec!["CLAUDECODE".to_owned(), "CLAUDE_PID".to_owned()],
                prefixes: vec!["CLAUDE_CODE_".to_owned()],
            })
        );
    }

    #[test]
    fn agent_launch_crosses_unchanged() {
        assert_eq!(
            acp_agent_launch("opencode".to_owned(), "ignored".to_owned()),
            Ok(Some(CoreAcpAgentLaunch {
                program: CoreAcpProgram::Opencode,
                arguments: vec!["acp".to_owned()],
            }))
        );
        assert_eq!(
            acp_agent_launch("codexBridge".to_owned(), String::new()),
            Ok(Some(CoreAcpAgentLaunch {
                program: CoreAcpProgram::Npx,
                arguments: vec!["-y".to_owned(), agents::CODEX_BRIDGE_PACKAGE.to_owned()],
            }))
        );
        assert_eq!(
            acp_agent_launch("custom".to_owned(), " /x/agent  acp ".to_owned()),
            Ok(Some(CoreAcpAgentLaunch {
                program: CoreAcpProgram::Command {
                    executable: "/x/agent".to_owned()
                },
                arguments: vec!["acp".to_owned()],
            }))
        );
        assert_eq!(
            acp_agent_launch("custom".to_owned(), "  ".to_owned()),
            Ok(None)
        );
    }
}
