//! The listener half of slice 2.6: the loopback listener's connection
//! policy as an object, its effects and its spec constants (DESIGN v2.15
//! A).
//!
//! `CoreListener` is owned by Swift (one per `RemoteListener`) and never
//! calls back: Swift reports the bind, each accepted socket, each read,
//! each end of stream, each close and each timer fire, and carries out the
//! effects each call returns, in order. Connections are the core's numbers;
//! the platform maps them to its sockets. The hook kind, the intent, the
//! status and the transcript entry reuse the session, mapping and
//! transcript modules' types.

use std::sync::{Arc, Mutex};

use powerup_core::protocol::listener::{
    BindError, HookPost, Listener, ListenerEffect, ListenerStatus, BIND_RETRY_STEP_SECONDS,
    IDLE_DEADLINE_SECONDS, MAX_AUTHENTICATED, MAX_BIND_RETRIES, MAX_BODY_BYTES, MAX_CONNECTIONS,
    MAX_HEADER_BYTES, MAX_PAYLOAD_BYTES, MAX_WEBSOCKET_BUFFER_BYTES, MIN_PORT, RECEIVE_CHUNK_BYTES,
};
use powerup_core::protocol::message::ServerMessage;

use crate::mapping::CoreIntent;
use crate::protocol::CoreServerMessage;
use crate::session::CoreHookKind;
use crate::{contain, locked, CoreBridgeError};

/// The listener's published state: whether the bind is ready, and the
/// text Settings shows for the last problem (`ListenerProblem::message`).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreListenerStatus {
    pub running: bool,
    pub problem: Option<String>,
}

impl From<ListenerStatus> for CoreListenerStatus {
    fn from(status: ListenerStatus) -> Self {
        CoreListenerStatus {
            running: status.running,
            problem: status.problem.map(|problem| problem.message()),
        }
    }
}

/// Why a bind went wrong, as the platform reports it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreBindError {
    /// The port is taken (EADDRINUSE).
    AddressInUse,
    /// Anything else, with the platform's description of it.
    Other { description: String },
}

impl From<CoreBindError> for BindError {
    fn from(error: CoreBindError) -> Self {
        match error {
            CoreBindError::AddressInUse => BindError::AddressInUse,
            CoreBindError::Other { description } => BindError::Other(description),
        }
    }
}

/// One Claude Code hook as a hook post delivered it (HK-248).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreHookPost {
    pub kind: CoreHookKind,
    pub text: Option<String>,
    pub session_id: Option<String>,
    pub cwd: Option<String>,
}

impl From<HookPost> for CoreHookPost {
    fn from(hook: HookPost) -> Self {
        CoreHookPost {
            kind: hook.kind.into(),
            text: hook.text,
            session_id: hook.session_id,
            cwd: hook.cwd,
        }
    }
}

/// What the listener asks the platform to do, case for case with
/// `powerup_core::protocol::listener::ListenerEffect`.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum CoreListenerEffect {
    Publish {
        status: CoreListenerStatus,
    },
    Listen {
        generation: u64,
        port: u16,
    },
    StopListening,
    ScheduleBindRetry {
        generation: u64,
        seconds: f64,
    },
    Admit {
        connection: u64,
    },
    Refuse,
    ArmIdleDeadline {
        connection: u64,
        seconds: f64,
    },
    Send {
        connection: u64,
        bytes: Vec<u8>,
    },
    Broadcast {
        connections: Vec<u64>,
        bytes: Vec<u8>,
    },
    Close {
        connection: u64,
    },
    Cancel {
        connection: u64,
    },
    DeliverHook {
        generation: u64,
        hook: CoreHookPost,
    },
    DeliverIntent {
        generation: u64,
        intent: CoreIntent,
    },
    Welcome {
        connection: u64,
    },
}

impl From<ListenerEffect> for CoreListenerEffect {
    fn from(effect: ListenerEffect) -> Self {
        match effect {
            ListenerEffect::Publish(status) => CoreListenerEffect::Publish {
                status: status.into(),
            },
            ListenerEffect::Listen { generation, port } => {
                CoreListenerEffect::Listen { generation, port }
            }
            ListenerEffect::StopListening => CoreListenerEffect::StopListening,
            ListenerEffect::ScheduleBindRetry {
                generation,
                seconds,
            } => CoreListenerEffect::ScheduleBindRetry {
                generation,
                seconds,
            },
            ListenerEffect::Admit { connection } => CoreListenerEffect::Admit { connection },
            ListenerEffect::Refuse => CoreListenerEffect::Refuse,
            ListenerEffect::ArmIdleDeadline {
                connection,
                seconds,
            } => CoreListenerEffect::ArmIdleDeadline {
                connection,
                seconds,
            },
            ListenerEffect::Send { connection, bytes } => {
                CoreListenerEffect::Send { connection, bytes }
            }
            ListenerEffect::Broadcast { connections, bytes } => {
                CoreListenerEffect::Broadcast { connections, bytes }
            }
            ListenerEffect::Close { connection } => CoreListenerEffect::Close { connection },
            ListenerEffect::Cancel { connection } => CoreListenerEffect::Cancel { connection },
            ListenerEffect::DeliverHook { generation, hook } => CoreListenerEffect::DeliverHook {
                generation,
                hook: hook.into(),
            },
            ListenerEffect::DeliverIntent { generation, intent } => {
                CoreListenerEffect::DeliverIntent {
                    generation,
                    intent: intent.into(),
                }
            }
            ListenerEffect::Welcome { connection } => CoreListenerEffect::Welcome { connection },
        }
    }
}

fn converted(effects: Vec<ListenerEffect>) -> Vec<CoreListenerEffect> {
    effects.into_iter().map(Into::into).collect()
}

/// The connection policy (`protocol::listener::Listener`). Swift creates
/// one per `RemoteListener` and keeps it across starts; the generation and
/// the connections live inside. Every call returns effects for Swift to run
/// in order before the next call. It is called on one queue at a time; the
/// lock only keeps the object sound.
#[derive(Debug, uniffi::Object)]
pub struct CoreListener {
    listener: Mutex<Listener>,
}

impl CoreListener {
    fn run(
        &self,
        call: impl FnOnce(&mut Listener) -> Vec<ListenerEffect>,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        contain(|| Ok(converted(call(&mut locked(&self.listener)))))
    }
}

#[uniffi::export]
impl CoreListener {
    /// A stopped listener at generation 0.
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, CoreBridgeError> {
        contain(|| {
            Ok(Arc::new(CoreListener {
                listener: Mutex::new(Listener::new()),
            }))
        })
    }

    /// The current generation.
    pub fn generation(&self) -> Result<u64, CoreBridgeError> {
        contain(|| Ok(locked(&self.listener).generation()))
    }

    /// The published state as it is now.
    pub fn status(&self) -> Result<CoreListenerStatus, CoreBridgeError> {
        contain(|| Ok(locked(&self.listener).status().into()))
    }

    /// Connections held, closing ones included.
    pub fn connection_count(&self) -> Result<u64, CoreBridgeError> {
        contain(|| Ok(count(locked(&self.listener).connection_count())))
    }

    /// Authenticated protocol clients held, closing ones included.
    pub fn authenticated_count(&self) -> Result<u64, CoreBridgeError> {
        contain(|| Ok(count(locked(&self.listener).authenticated_count())))
    }

    pub fn start(
        &self,
        port: u16,
        token: String,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.start(port, &token))
    }

    pub fn stop(&self) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(Listener::stop)
    }

    pub fn bind_ready(&self, generation: u64) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.bind_ready(generation))
    }

    pub fn bind_waiting(
        &self,
        generation: u64,
        error: CoreBindError,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        let error = BindError::from(error);
        self.run(|listener| listener.bind_waiting(generation, &error))
    }

    pub fn bind_failed(
        &self,
        generation: u64,
        error: CoreBindError,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        let error = BindError::from(error);
        self.run(|listener| listener.bind_failed(generation, &error))
    }

    pub fn bind_cancelled(
        &self,
        generation: u64,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.bind_cancelled(generation))
    }

    /// The platform could not create the listener a `Listen` asked for.
    pub fn listen_refused(
        &self,
        generation: u64,
        detail: String,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.listen_refused(generation, &detail))
    }

    pub fn retry_fired(&self, generation: u64) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.retry_fired(generation))
    }

    /// The listener of `generation` accepted a socket.
    pub fn accepted(&self, generation: u64) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.accepted(generation))
    }

    /// One read's bytes from a connection.
    pub fn received(
        &self,
        connection: u64,
        bytes: Vec<u8>,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.received(connection, &bytes))
    }

    pub fn end_of_stream(
        &self,
        connection: u64,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.end_of_stream(connection))
    }

    pub fn closed(&self, connection: u64) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.closed(connection))
    }

    pub fn deadline_fired(
        &self,
        connection: u64,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        self.run(|listener| listener.deadline_fired(connection))
    }

    /// One message to every authenticated client, encoded once.
    pub fn broadcast(
        &self,
        message: CoreServerMessage,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        let message = ServerMessage::from(message);
        self.run(|listener| listener.broadcast(&message))
    }

    /// The answer to a `Welcome` effect: the welcome, then the snapshot.
    pub fn welcome(
        &self,
        connection: u64,
        app_version: String,
        snapshot: Vec<CoreServerMessage>,
    ) -> Result<Vec<CoreListenerEffect>, CoreBridgeError> {
        let snapshot: Vec<ServerMessage> = snapshot.into_iter().map(Into::into).collect();
        self.run(|listener| listener.welcome(connection, &app_version, &snapshot))
    }
}

fn count(value: usize) -> u64 {
    u64::try_from(value).unwrap_or(u64::MAX)
}

/// The listener's spec constants (`docs/protocol.md`), so the platform's
/// numbers are the core's.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct CoreListenerLimits {
    pub max_connections: u32,
    pub max_authenticated: u32,
    pub idle_deadline_seconds: f64,
    pub max_header_bytes: u32,
    pub max_body_bytes: u32,
    pub max_payload_bytes: u32,
    pub max_websocket_buffer_bytes: u32,
    /// The most bytes the platform reads from a connection at a time.
    pub receive_chunk_bytes: u32,
    pub max_bind_retries: u32,
    pub bind_retry_step_seconds: f64,
    pub min_port: u16,
}

/// The constants of `protocol::listener`.
#[uniffi::export]
pub fn listener_limits() -> Result<CoreListenerLimits, CoreBridgeError> {
    let limit = |value: usize| u32::try_from(value).unwrap_or(u32::MAX);
    contain(|| {
        Ok(CoreListenerLimits {
            max_connections: limit(MAX_CONNECTIONS),
            max_authenticated: limit(MAX_AUTHENTICATED),
            idle_deadline_seconds: IDLE_DEADLINE_SECONDS,
            max_header_bytes: limit(MAX_HEADER_BYTES),
            max_body_bytes: limit(MAX_BODY_BYTES),
            max_payload_bytes: limit(MAX_PAYLOAD_BYTES),
            max_websocket_buffer_bytes: limit(MAX_WEBSOCKET_BUFFER_BYTES),
            receive_chunk_bytes: limit(RECEIVE_CHUNK_BYTES),
            max_bind_retries: MAX_BIND_RETRIES,
            bind_retry_step_seconds: BIND_RETRY_STEP_SECONDS,
            min_port: MIN_PORT,
        })
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::CoreAppStatus;
    use powerup_core::intent::Intent;
    use powerup_core::protocol::listener::ListenerProblem;
    use powerup_core::session::HookKind;

    #[test]
    fn every_listener_effect_converts() {
        let hook = HookPost {
            kind: HookKind::Stop,
            text: Some("done".to_owned()),
            session_id: None,
            cwd: Some("/work".to_owned()),
        };
        let pairs = [
            (
                ListenerEffect::Publish(ListenerStatus {
                    running: false,
                    problem: Some(ListenerProblem::PortInUse(48738)),
                }),
                CoreListenerEffect::Publish {
                    status: CoreListenerStatus {
                        running: false,
                        problem: Some(
                            "Port 48738 is already in use \u{2014} pick a different port in Settings \u{2192} Remote."
                                .to_owned(),
                        ),
                    },
                },
            ),
            (
                ListenerEffect::Listen {
                    generation: 2,
                    port: 48738,
                },
                CoreListenerEffect::Listen {
                    generation: 2,
                    port: 48738,
                },
            ),
            (
                ListenerEffect::StopListening,
                CoreListenerEffect::StopListening,
            ),
            (
                ListenerEffect::ScheduleBindRetry {
                    generation: 3,
                    seconds: 2.0,
                },
                CoreListenerEffect::ScheduleBindRetry {
                    generation: 3,
                    seconds: 2.0,
                },
            ),
            (
                ListenerEffect::Admit { connection: 1 },
                CoreListenerEffect::Admit { connection: 1 },
            ),
            (ListenerEffect::Refuse, CoreListenerEffect::Refuse),
            (
                ListenerEffect::ArmIdleDeadline {
                    connection: 1,
                    seconds: 15.0,
                },
                CoreListenerEffect::ArmIdleDeadline {
                    connection: 1,
                    seconds: 15.0,
                },
            ),
            (
                ListenerEffect::Send {
                    connection: 1,
                    bytes: vec![1],
                },
                CoreListenerEffect::Send {
                    connection: 1,
                    bytes: vec![1],
                },
            ),
            (
                ListenerEffect::Broadcast {
                    connections: vec![1, 2],
                    bytes: vec![2],
                },
                CoreListenerEffect::Broadcast {
                    connections: vec![1, 2],
                    bytes: vec![2],
                },
            ),
            (
                ListenerEffect::Close { connection: 4 },
                CoreListenerEffect::Close { connection: 4 },
            ),
            (
                ListenerEffect::Cancel { connection: 5 },
                CoreListenerEffect::Cancel { connection: 5 },
            ),
            (
                ListenerEffect::DeliverHook {
                    generation: 2,
                    hook,
                },
                CoreListenerEffect::DeliverHook {
                    generation: 2,
                    hook: CoreHookPost {
                        kind: CoreHookKind::Stop,
                        text: Some("done".to_owned()),
                        session_id: None,
                        cwd: Some("/work".to_owned()),
                    },
                },
            ),
            (
                ListenerEffect::DeliverIntent {
                    generation: 2,
                    intent: Intent::Approve,
                },
                CoreListenerEffect::DeliverIntent {
                    generation: 2,
                    intent: CoreIntent::Approve,
                },
            ),
            (
                ListenerEffect::Welcome { connection: 6 },
                CoreListenerEffect::Welcome { connection: 6 },
            ),
        ];
        for (core, bridge) in pairs {
            assert_eq!(CoreListenerEffect::from(core), bridge);
        }
    }

    /// A text frame from a client: masked with a zero key, so the payload
    /// reads as written.
    fn client_text(text: &str) -> Vec<u8> {
        let length = u8::try_from(text.len()).unwrap();
        assert!(length < 126);
        let mut frame = vec![0x81, 0x80 | length, 0, 0, 0, 0];
        frame.extend_from_slice(text.as_bytes());
        frame
    }

    #[test]
    fn the_listener_object_runs_the_core_policy() {
        let listener = CoreListener::new().unwrap();
        assert_eq!(listener.generation(), Ok(0));
        assert_eq!(
            listener.start(48738, "secret".to_owned()),
            Ok(vec![CoreListenerEffect::Listen {
                generation: 2,
                port: 48738
            }])
        );
        assert_eq!(
            listener.bind_ready(2),
            Ok(vec![CoreListenerEffect::Publish {
                status: CoreListenerStatus {
                    running: true,
                    problem: None
                }
            }])
        );
        assert_eq!(listener.accepted(1), Ok(vec![CoreListenerEffect::Refuse]));
        assert_eq!(
            listener.accepted(2),
            Ok(vec![
                CoreListenerEffect::Admit { connection: 1 },
                CoreListenerEffect::ArmIdleDeadline {
                    connection: 1,
                    seconds: 15.0
                },
            ])
        );

        // A hook post is answered before it is delivered (HK-247).
        let post = b"POST /event HTTP/1.1\nX-PowerUp-Token: secret\nContent-Length: 44\n\n\
                     {\"hook_event_name\":\"Stop\",\"session_id\":\"s1\"}  "
            .to_vec();
        let effects = listener.received(1, post).unwrap();
        assert_eq!(
            effects,
            vec![
                CoreListenerEffect::Send {
                    connection: 1,
                    bytes: b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n".to_vec(),
                },
                CoreListenerEffect::Close { connection: 1 },
                CoreListenerEffect::DeliverHook {
                    generation: 2,
                    hook: CoreHookPost {
                        kind: CoreHookKind::Stop,
                        text: None,
                        session_id: Some("s1".to_owned()),
                        cwd: None,
                    },
                },
            ]
        );
        assert_eq!(listener.connection_count(), Ok(1));
        assert_eq!(
            listener.closed(1),
            Ok(vec![CoreListenerEffect::Cancel { connection: 1 }])
        );

        // A protocol client: upgrade with its hello pipelined behind it.
        let _ = listener.accepted(2).unwrap();
        let mut upgrade = b"GET /ws HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
                            Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
            .to_vec();
        upgrade.extend(client_text(r#"{"type":"hello","token":"secret"}"#));
        let effects = listener.received(2, upgrade).unwrap();
        assert_eq!(effects.len(), 2, "{effects:?}");
        assert_eq!(
            effects.last(),
            Some(&CoreListenerEffect::Welcome { connection: 2 })
        );
        assert_eq!(listener.authenticated_count(), Ok(1));
        let welcome = listener
            .welcome(
                2,
                "1.0".to_owned(),
                vec![CoreServerMessage::Status {
                    status: CoreAppStatus::Idle,
                }],
            )
            .unwrap();
        assert_eq!(welcome.len(), 2);
        assert_eq!(
            listener.received(2, client_text(r#"{"type":"intent","intent":"approve"}"#)),
            Ok(vec![CoreListenerEffect::DeliverIntent {
                generation: 2,
                intent: CoreIntent::Approve,
            }])
        );
        assert_eq!(
            listener.broadcast(CoreServerMessage::Pong),
            Ok(vec![CoreListenerEffect::Broadcast {
                connections: vec![2],
                bytes: vec![
                    0x81, 15, b'{', b'"', b't', b'y', b'p', b'e', b'"', b':', b'"', b'p', b'o',
                    b'n', b'g', b'"', b'}'
                ],
            }])
        );
        assert_eq!(
            listener.deadline_fired(2),
            Ok(vec![]),
            "an authenticated client is spared"
        );

        // A failed bind retries after 2 s; a stop invalidates the retry.
        let failed = listener
            .bind_failed(2, CoreBindError::AddressInUse)
            .unwrap();
        assert_eq!(
            failed.last(),
            Some(&CoreListenerEffect::ScheduleBindRetry {
                generation: 3,
                seconds: 2.0
            })
        );
        assert_eq!(
            listener.status().unwrap().problem.as_deref(),
            Some("Port 48738 is already in use \u{2014} pick a different port in Settings \u{2192} Remote.")
        );
        let _ = listener.stop().unwrap();
        assert_eq!(listener.retry_fired(3), Ok(vec![]));
    }

    #[test]
    fn a_platform_bind_error_crosses_with_its_description() {
        let listener = CoreListener::new().unwrap();
        let _ = listener.start(50000, "t".to_owned()).unwrap();
        let _ = listener
            .bind_waiting(
                2,
                CoreBindError::Other {
                    description: "nope".to_owned(),
                },
            )
            .unwrap();
        assert_eq!(
            listener.status(),
            Ok(CoreListenerStatus {
                running: false,
                problem: Some("Listener problem on port 50000: nope".to_owned()),
            })
        );
        assert_eq!(
            listener.listen_refused(2, "denied".to_owned()),
            Ok(vec![CoreListenerEffect::Publish {
                status: CoreListenerStatus {
                    running: false,
                    problem: Some("Couldn't listen on 127.0.0.1:50000 \u{2014} denied".to_owned()),
                }
            }])
        );
        assert_eq!(listener.bind_cancelled(2), Ok(vec![]));
        assert_eq!(listener.end_of_stream(9), Ok(vec![]));
    }

    #[test]
    fn the_limits_are_the_cores() {
        assert_eq!(
            listener_limits(),
            Ok(CoreListenerLimits {
                max_connections: 32,
                max_authenticated: 16,
                idle_deadline_seconds: 15.0,
                max_header_bytes: 16 * 1024,
                max_body_bytes: 4 * 1024 * 1024,
                max_payload_bytes: 1024 * 1024,
                max_websocket_buffer_bytes: 2 * 1024 * 1024,
                receive_chunk_bytes: 32 * 1024,
                max_bind_retries: 3,
                bind_retry_step_seconds: 2.0,
                min_port: 1024,
            })
        );
    }
}
