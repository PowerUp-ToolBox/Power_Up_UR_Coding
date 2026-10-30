//! The loopback listener's connection policy (DESIGN v1.4, v1.7;
//! `docs/protocol.md` "Transport" and "Security"; spec #101, #162): what the
//! listener does with its bind, with each connection it accepts, with each
//! chunk of bytes a connection delivers, with each close and with each
//! timer, as effects the platform carries out in order. Ported from the
//! Swift app's `RemoteListener`, `ConnectionRegistry` and `HookConnection`;
//! the scenarios in `Tests/Fixtures/listener/` pin each rule.
//!
//! One port serves two things. A hook post (`POST /event` with the
//! read-back token in `X-PowerUp-Token`) is answered 204 and then handed to
//! the app; `GET /ws` upgrades to the protocol, whose client must send a
//! hello with the token before anything else. Every connection starts as
//! HTTP, under the 15-second deadline; an authenticated protocol client is
//! exempt from it and from the connection cap's evictions.
//!
//! The platform owns the sockets: it binds 127.0.0.1 only (the loopback
//! bind, port reuse and no-delay are its, HK-288, HK-290), accepts, reads
//! (at most [`RECEIVE_CHUNK_BYTES`] at a time), writes, cancels and arms the
//! timers. It calls the [`Listener`] with what happened and carries out the
//! returned effects in order, each before the next and before its next call
//! (CONTEXT.md, "Effect"). The machine never calls back: an effect that
//! needs an answer (a bind, an accepted socket, a welcome) names the call
//! that carries it. Timers are one-shot and never cancelled; the machine
//! decides, when one fires, whether it still applies (as the Swift
//! listener's `asyncAfter` blocks did, and as the ACP adapter's watchdog
//! does).
//!
//! Recorded choices where Swift left the order to chance or to a race:
//! - the cap evicts the oldest connections that are not authenticated
//!   (Swift took them in its dictionary's hash order, HK-261);
//! - a connection that has been answered or sent a close frame reads
//!   nothing more: the frames after a close or a refusal in the same chunk
//!   are not processed (Swift processed them until its close completed),
//!   and nothing more is sent to it, a broadcast or a welcome included;
//! - a protocol client refused for the authenticated cap is not exempt from
//!   the deadline (it is closing anyway);
//! - tokens are compared byte for byte (Swift compared by canonical
//!   equivalence; the two agree for the UUID string the app mints).

use std::mem;

use super::framing::{self, close_code, decode_frames, Frame, Opcode};
use super::handshake::{header_boundary, upgrade_decision, RequestHead, UpgradeDecision};
use super::message::{
    encode, parse_client_message, ClientMessage, ClientMessageFailure, ErrorCode, ServerMessage,
    AUTH_FAILED_MESSAGE, NOT_AUTHENTICATED_MESSAGE, SERVER_BUSY_MESSAGE,
};
use crate::intent::Intent;
use crate::json::{self, JsonValue};
use crate::session::HookKind;
use crate::text::trim;

/// The most connections held at once (HK-261): accepting one more evicts
/// the oldest connection that is not an authenticated protocol client, so a
/// misbehaving client cannot pile up sockets, and a burst of hook posts can
/// never sever a device plugin (the hook-burst rule).
pub const MAX_CONNECTIONS: usize = 32;

/// The most authenticated protocol clients at once (HK-261): one more hello
/// with the right token is answered `server_busy` and closed with 1013.
pub const MAX_AUTHENTICATED: usize = 16;

/// How long after its accept a connection may stay open without being an
/// authenticated protocol client (HK-255). It is one deadline from the
/// accept, not an inactivity timer: a hook post still uploading and a
/// WebSocket that has not said hello are dropped alike when it fires, with
/// no reply, and a client authenticated by then is never dropped by it.
pub const IDLE_DEADLINE_SECONDS: f64 = 15.0;

/// The largest header block (HK-252): a request whose head has not ended
/// past this many bytes is answered 431.
pub const MAX_HEADER_BYTES: usize = 16 * 1024;

/// The largest hook post body (HK-252): a larger or negative
/// `Content-Length` is answered 413, and so is a request that has sent more
/// than [`MAX_HEADER_BYTES`] plus this.
pub const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;

/// The largest frame payload a client may send (ADR 0003; HK-259): a larger
/// one is a protocol violation, closed with 1002.
pub const MAX_PAYLOAD_BYTES: usize = 1024 * 1024;

/// The most bytes a WebSocket may have waiting to be decoded (HK-259): more
/// closes it with 1009. Reads of [`RECEIVE_CHUNK_BYTES`] cannot reach it
/// (decoding leaves at most one partial frame of at most
/// [`MAX_PAYLOAD_BYTES`] and its header); a platform reading larger chunks
/// can.
pub const MAX_WEBSOCKET_BUFFER_BYTES: usize = 2 * 1024 * 1024;

/// The most bytes the platform reads from a connection at a time (the
/// macOS listener's receive size).
pub const RECEIVE_CHUNK_BYTES: usize = 32 * 1024;

/// How many times a failed bind is retried before the listener stays down
/// (HK-292). The count is reset only by a bind that becomes ready.
pub const MAX_BIND_RETRIES: u32 = 3;

/// The bind retry's step: the n-th retry waits n times this, so 2, 4 and 6
/// seconds (linear, not exponential).
pub const BIND_RETRY_STEP_SECONDS: f64 = 2.0;

/// The lowest port the listener binds (HK-245): lower ports need root, and
/// accepting one would trade a clear message for an opaque bind failure.
pub const MIN_PORT: u16 = 1024;

/// A connection, numbered by the machine from 1 in accept order and never
/// reused.
pub type ConnectionId = u64;

/// One Claude Code hook as a hook post delivered it (HK-248): the five
/// hooks PowerUp installs, with the text each carries, its session id and
/// its working directory. A blank value (empty once trimmed of whitespace
/// and newlines) reads as absent; any other is kept untrimmed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookPost {
    pub kind: HookKind,
    /// Stop's `last_assistant_message`, UserPromptSubmit's `prompt`,
    /// Notification's `message`, SessionEnd's `reason` or PostToolUse's
    /// `tool_name`.
    pub text: Option<String>,
    pub session_id: Option<String>,
    pub cwd: Option<String>,
}

/// Why a bind went wrong, as the platform reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BindError {
    /// The port is taken (EADDRINUSE).
    AddressInUse,
    /// Anything else, with the platform's description of it.
    Other(String),
}

/// What keeps the listener from listening, for Settings to show.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ListenerProblem {
    /// A port below [`MIN_PORT`] (HK-245).
    UnusablePort(u16),
    /// An empty read-back token: hook posts would go unauthenticated
    /// (HK-245).
    EmptyToken,
    /// The platform could not create a listener at all.
    CannotListen { port: u16, detail: String },
    /// The bind found the port taken.
    PortInUse(u16),
    /// Any other bind problem.
    Failed { port: u16, detail: String },
}

impl ListenerProblem {
    /// The text Settings shows.
    pub fn message(&self) -> String {
        match self {
            ListenerProblem::UnusablePort(port) => format!(
                "Port {port} isn't a usable port number \u{2014} pick one between 1024 and 65535."
            ),
            ListenerProblem::EmptyToken => {
                "The read-back token is empty \u{2014} reinstall the hooks from Settings \u{2192} Remote."
                    .to_owned()
            }
            ListenerProblem::CannotListen { port, detail } => {
                format!("Couldn't listen on 127.0.0.1:{port} \u{2014} {detail}")
            }
            ListenerProblem::PortInUse(port) => format!(
                "Port {port} is already in use \u{2014} pick a different port in Settings \u{2192} Remote."
            ),
            ListenerProblem::Failed { port, detail } => {
                format!("Listener problem on port {port}: {detail}")
            }
        }
    }
}

/// The listener's published state: `RemoteListener.isRunning` and
/// `lastError`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ListenerStatus {
    /// The bind is ready.
    pub running: bool,
    /// The last problem; a stop keeps it, a successful bind clears it.
    pub problem: Option<ListenerProblem>,
}

/// What the listener asks the platform to do.
#[derive(Debug, Clone, PartialEq)]
pub enum ListenerEffect {
    /// Assign the published state. It is pushed before any other effect
    /// whenever the state changed since the last one, and at the end of a
    /// call, so a call the platform makes while carrying out an effect
    /// never sees an older state published after a newer one.
    Publish(ListenerStatus),
    /// Bind 127.0.0.1:`port` and listen. Report what becomes of the bind
    /// with this generation ([`Listener::bind_ready`] and the others, or
    /// [`Listener::listen_refused`] at once when no listener can be
    /// created), and accept its connections with it.
    Listen { generation: u64, port: u16 },
    /// Cancel the listener; its connections are cancelled by their own
    /// effects.
    StopListening,
    /// One-shot: after `seconds`, call [`Listener::retry_fired`] with this
    /// generation. It is never cancelled; an explicit start or stop in
    /// between makes the fire do nothing.
    ScheduleBindRetry { generation: u64, seconds: f64 },
    /// The socket just accepted is this connection: start it, read from
    /// it, and report what happens to it by this id.
    Admit { connection: ConnectionId },
    /// The socket just accepted belongs to no current listener: cancel it.
    Refuse,
    /// One-shot: after `seconds`, call [`Listener::deadline_fired`] for
    /// this connection. It is never cancelled.
    ArmIdleDeadline {
        connection: ConnectionId,
        seconds: f64,
    },
    /// Write these bytes on the connection.
    Send {
        connection: ConnectionId,
        bytes: Vec<u8>,
    },
    /// Write the same bytes (one frame, encoded once) on each connection,
    /// in this order (HK-262).
    Broadcast {
        connections: Vec<ConnectionId>,
        bytes: Vec<u8>,
    },
    /// Once the bytes sent before it are written, call
    /// [`Listener::closed`] for the connection. It still counts against
    /// the cap until then.
    Close { connection: ConnectionId },
    /// Cancel the connection now. The machine has forgotten it.
    Cancel { connection: ConnectionId },
    /// Hand a hook post to the app. Its 204 has already been sent
    /// (HK-247). A platform that carries it out later than in order drops
    /// it when the generation has moved on meanwhile.
    DeliverHook { generation: u64, hook: HookPost },
    /// Hand an authenticated client's intent to the app, with the same
    /// generation rule.
    DeliverIntent { generation: u64, intent: Intent },
    /// The connection is now an authenticated protocol client: call
    /// [`Listener::welcome`] for it with the app version and the snapshot
    /// messages (HK-234). It already receives broadcasts (HK-260).
    Welcome { connection: ConnectionId },
}

/// A bind to retry once its timer fires.
#[derive(Debug, Clone, PartialEq, Eq)]
struct BindRetry {
    generation: u64,
    port: u16,
    token: String,
}

/// An HTTP request being read.
#[derive(Debug, Clone, Default)]
struct HttpRequest {
    buffer: Vec<u8>,
    head: Option<RequestHead>,
    /// Where the body (or the WebSocket stream) starts in `buffer`.
    body_start: usize,
    expected_body_length: usize,
    /// Chunked: the body is whatever arrives before the end of the stream.
    awaiting_end_of_stream: bool,
    continue_sent: bool,
}

#[derive(Debug, Clone)]
enum Phase {
    Http(HttpRequest),
    /// Bytes waiting to be decoded.
    WebSocket(Vec<u8>),
    /// Answered or sent a close frame; waiting for [`Listener::closed`].
    Closing,
}

#[derive(Debug, Clone)]
struct Connection {
    id: ConnectionId,
    /// Counted against [`MAX_AUTHENTICATED`] until the connection is
    /// forgotten, closing or not.
    authenticated: bool,
    phase: Phase,
}

/// What reading an HTTP request has come to.
enum HttpStep {
    Wait,
    Respond(u16, &'static str),
    Upgrade {
        accept_key: String,
        pipelined: Vec<u8>,
    },
    Hook(Vec<u8>),
}

/// What a connection's handling needs from the listener.
struct Context<'a> {
    connection: ConnectionId,
    token: &'a str,
    generation: u64,
    authenticated: usize,
    effects: &'a mut Vec<ListenerEffect>,
}

impl Context<'_> {
    fn send(&mut self, bytes: Vec<u8>) {
        self.effects.push(ListenerEffect::Send {
            connection: self.connection,
            bytes,
        });
    }

    /// One protocol message in a text frame; a message `encode` refuses is
    /// not sent.
    fn send_message(&mut self, message: &ServerMessage) {
        if let Some(text) = encode(message) {
            self.send(framing::encode_text(text.as_bytes()));
        }
    }

    fn close(&mut self) {
        self.effects.push(ListenerEffect::Close {
            connection: self.connection,
        });
    }
}

/// The listener's state between calls.
#[derive(Debug)]
pub struct Listener {
    /// Bumped by every start and stop (a successful start bumps it twice,
    /// stopping first), so a bind report, an accept or a retry of a
    /// torn-down listener is dropped (HK-291).
    generation: u64,
    /// A listener exists (bound, binding or waiting).
    listening: bool,
    port: Option<u16>,
    token: Option<String>,
    status: ListenerStatus,
    published: ListenerStatus,
    /// Failed binds retried since the last ready one.
    retry_attempts: u32,
    retry: Option<BindRetry>,
    /// In accept order.
    connections: Vec<Connection>,
    next_connection: ConnectionId,
    effects: Vec<ListenerEffect>,
}

impl Default for Listener {
    fn default() -> Self {
        Self::new()
    }
}

impl Listener {
    /// A stopped listener at generation 0.
    pub fn new() -> Self {
        Listener {
            generation: 0,
            listening: false,
            port: None,
            token: None,
            status: ListenerStatus::default(),
            published: ListenerStatus::default(),
            retry_attempts: 0,
            retry: None,
            connections: Vec::new(),
            next_connection: 1,
            effects: Vec::new(),
        }
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn status(&self) -> ListenerStatus {
        self.status.clone()
    }

    /// Connections held, closing ones included.
    pub fn connection_count(&self) -> usize {
        self.connections.len()
    }

    /// Authenticated protocol clients held, closing ones included.
    pub fn authenticated_count(&self) -> usize {
        self.connections.iter().filter(|c| c.authenticated).count()
    }

    // MARK: the bind

    /// Listens on 127.0.0.1:`port` with `token`. While the bind is ready on
    /// the same port and token this does nothing, so a settings refresh
    /// never drops a connected device (HK-289); any other call stops first,
    /// then refuses a port below [`MIN_PORT`] or an empty token with a
    /// problem and no bind (HK-245), or binds.
    pub fn start(&mut self, port: u16, token: &str) -> Vec<ListenerEffect> {
        self.start_inner(port, token);
        self.finish()
    }

    /// Stops listening and cancels every connection. Safe when stopped.
    pub fn stop(&mut self) -> Vec<ListenerEffect> {
        self.stop_inner();
        self.finish()
    }

    /// The bind of `generation` is ready: running, no problem, and the
    /// retry count starts over.
    pub fn bind_ready(&mut self, generation: u64) -> Vec<ListenerEffect> {
        if self.is_current_bind(generation) {
            self.status = ListenerStatus {
                running: true,
                problem: None,
            };
            self.retry_attempts = 0;
        }
        self.finish()
    }

    /// The bind of `generation` is waiting (usually a taken port). The
    /// platform keeps retrying it, so the listener stays (HK-292).
    pub fn bind_waiting(&mut self, generation: u64, error: &BindError) -> Vec<ListenerEffect> {
        if let (true, Some(port)) = (self.is_current_bind(generation), self.port) {
            self.status = ListenerStatus {
                running: false,
                problem: Some(describe(error, port)),
            };
        }
        self.finish()
    }

    /// The bind of `generation` failed, which is how a taken port arrives
    /// on macOS. The listener stops, and while fewer than
    /// [`MAX_BIND_RETRIES`] retries have run since the last ready bind, one
    /// more is scheduled after n times [`BIND_RETRY_STEP_SECONDS`]
    /// (HK-292). The count is not reset by an explicit start, only by a
    /// ready bind, as in Swift.
    pub fn bind_failed(&mut self, generation: u64, error: &BindError) -> Vec<ListenerEffect> {
        let (true, Some(port), Some(token)) = (
            self.is_current_bind(generation),
            self.port,
            self.token.clone(),
        ) else {
            return self.finish();
        };
        self.status = ListenerStatus {
            running: false,
            problem: Some(describe(error, port)),
        };
        self.stop_inner();
        if self.retry_attempts < MAX_BIND_RETRIES {
            self.retry_attempts += 1;
            let generation = self.generation;
            self.retry = Some(BindRetry {
                generation,
                port,
                token,
            });
            self.push(ListenerEffect::ScheduleBindRetry {
                generation,
                seconds: f64::from(self.retry_attempts) * BIND_RETRY_STEP_SECONDS,
            });
        }
        self.finish()
    }

    /// The listener of `generation` was cancelled.
    pub fn bind_cancelled(&mut self, generation: u64) -> Vec<ListenerEffect> {
        if self.is_current_bind(generation) {
            self.status.running = false;
        }
        self.finish()
    }

    /// The platform could not create the listener `Listen` asked for, for
    /// the reason it gives: no listener, no retry.
    pub fn listen_refused(&mut self, generation: u64, detail: &str) -> Vec<ListenerEffect> {
        if let (true, Some(port)) = (self.is_current_bind(generation), self.port) {
            self.listening = false;
            self.port = None;
            self.token = None;
            self.status = ListenerStatus {
                running: false,
                problem: Some(ListenerProblem::CannotListen {
                    port,
                    detail: detail.to_owned(),
                }),
            };
        }
        self.finish()
    }

    /// The bind retry of `generation` is due. It starts the failed bind
    /// again only if nothing started or stopped the listener since.
    pub fn retry_fired(&mut self, generation: u64) -> Vec<ListenerEffect> {
        if generation == self.generation && !self.listening {
            if let Some(retry) = self.retry.take_if(|retry| retry.generation == generation) {
                self.start_inner(retry.port, &retry.token);
            }
        }
        self.finish()
    }

    // MARK: connections

    /// The listener of `generation` accepted a socket. A current listener
    /// admits it as a new connection under the idle deadline; past
    /// [`MAX_CONNECTIONS`] the oldest connections that are not
    /// authenticated protocol clients are cancelled, unanswered (a hook
    /// script tolerates that), never an authenticated one and never the new
    /// one (HK-261). A socket of a torn-down listener is refused.
    pub fn accepted(&mut self, generation: u64) -> Vec<ListenerEffect> {
        if generation != self.generation || !self.listening {
            self.push(ListenerEffect::Refuse);
            return self.finish();
        }
        let id = self.next_connection;
        self.next_connection = id.saturating_add(1);
        self.push(ListenerEffect::Admit { connection: id });
        self.connections.push(Connection {
            id,
            authenticated: false,
            phase: Phase::Http(HttpRequest::default()),
        });

        let mut overflow = self.connections.len().saturating_sub(MAX_CONNECTIONS);
        let mut evicted = Vec::new();
        self.connections.retain(|connection| {
            let evict = overflow > 0 && connection.id != id && !connection.authenticated;
            if evict {
                overflow -= 1;
                evicted.push(connection.id);
            }
            !evict
        });
        for connection in evicted {
            self.push(ListenerEffect::Cancel { connection });
        }

        self.push(ListenerEffect::ArmIdleDeadline {
            connection: id,
            seconds: IDLE_DEADLINE_SECONDS,
        });
        self.finish()
    }

    /// A connection delivered bytes. Empty chunks and the bytes of a
    /// connection that is closing or forgotten are ignored.
    pub fn received(&mut self, connection: ConnectionId, bytes: &[u8]) -> Vec<ListenerEffect> {
        if !bytes.is_empty() {
            let authenticated = self.authenticated_count();
            let token = self.token.clone().unwrap_or_default();
            if let Some(held) = self.connections.iter_mut().find(|c| c.id == connection) {
                let mut cx = Context {
                    connection,
                    token: &token,
                    generation: self.generation,
                    authenticated,
                    effects: &mut self.effects,
                };
                held.receive(bytes, &mut cx);
            }
        }
        self.finish()
    }

    /// The peer ended its stream. A request whose head has arrived is
    /// answered with whatever body came (a chunked body, or one cut short,
    /// HK-251); any other connection, a WebSocket included, is cancelled.
    pub fn end_of_stream(&mut self, connection: ConnectionId) -> Vec<ListenerEffect> {
        let authenticated = self.authenticated_count();
        let token = self.token.clone().unwrap_or_default();
        if let Some(held) = self.connections.iter_mut().find(|c| c.id == connection) {
            let step = match &held.phase {
                Phase::Http(request) if request.head.is_some() => {
                    Some(complete(request, true, &token))
                }
                _ => None,
            };
            if let Some(step) = step {
                // An upgrade at the end of the stream still reads the
                // hello pipelined behind it, so the cap must be known.
                let mut cx = Context {
                    connection,
                    token: &token,
                    generation: self.generation,
                    authenticated,
                    effects: &mut self.effects,
                };
                held.apply(step, &mut cx);
                return self.finish();
            }
            self.forget(connection);
        }
        self.finish()
    }

    /// The connection is gone: a `Close` was carried out, a read failed or
    /// the socket failed. The machine forgets it and asks for it to be
    /// cancelled.
    pub fn closed(&mut self, connection: ConnectionId) -> Vec<ListenerEffect> {
        self.forget(connection);
        self.finish()
    }

    /// The idle deadline of a connection fired: it is cancelled, unanswered,
    /// unless it is an authenticated protocol client (HK-255).
    pub fn deadline_fired(&mut self, connection: ConnectionId) -> Vec<ListenerEffect> {
        let spared = self
            .connections
            .iter()
            .find(|c| c.id == connection)
            .is_some_and(|c| c.authenticated);
        if !spared {
            self.forget(connection);
        }
        self.finish()
    }

    // MARK: the app

    /// Sends one message to every authenticated client that is not closing,
    /// encoded once (HK-262). Nothing is sent when there is no such client
    /// or the message cannot be encoded.
    pub fn broadcast(&mut self, message: &ServerMessage) -> Vec<ListenerEffect> {
        let connections: Vec<ConnectionId> = self
            .connections
            .iter()
            .filter(|c| c.authenticated && !matches!(c.phase, Phase::Closing))
            .map(|c| c.id)
            .collect();
        if !connections.is_empty() {
            if let Some(text) = encode(message) {
                self.push(ListenerEffect::Broadcast {
                    connections,
                    bytes: framing::encode_text(text.as_bytes()),
                });
            }
        }
        self.finish()
    }

    /// Answers a `Welcome` effect: the welcome with `app_version`, then each
    /// snapshot message in order, each in its own frame (HK-234). Nothing
    /// is sent to a connection that is gone or closing meanwhile.
    pub fn welcome(
        &mut self,
        connection: ConnectionId,
        app_version: &str,
        snapshot: &[ServerMessage],
    ) -> Vec<ListenerEffect> {
        let open = self
            .connections
            .iter()
            .any(|c| c.id == connection && c.authenticated && !matches!(c.phase, Phase::Closing));
        if open {
            let mut cx = Context {
                connection,
                token: "",
                generation: self.generation,
                authenticated: 0,
                effects: &mut self.effects,
            };
            cx.send_message(&ServerMessage::Welcome {
                app_version: app_version.to_owned(),
            });
            for message in snapshot {
                cx.send_message(message);
            }
        }
        self.finish()
    }

    // MARK: helpers

    fn start_inner(&mut self, port: u16, token: &str) {
        if self.status.running
            && self.listening
            && self.port == Some(port)
            && self.token.as_deref() == Some(token)
        {
            return;
        }
        self.stop_inner();
        if port < MIN_PORT {
            self.status.problem = Some(ListenerProblem::UnusablePort(port));
            return;
        }
        if token.is_empty() {
            self.status.problem = Some(ListenerProblem::EmptyToken);
            return;
        }
        self.generation = self.generation.wrapping_add(1);
        self.listening = true;
        self.port = Some(port);
        self.token = Some(token.to_owned());
        self.status.problem = None;
        self.push(ListenerEffect::Listen {
            generation: self.generation,
            port,
        });
    }

    fn stop_inner(&mut self) {
        self.generation = self.generation.wrapping_add(1);
        self.status.running = false;
        if self.listening {
            self.push(ListenerEffect::StopListening);
        }
        self.listening = false;
        self.port = None;
        self.token = None;
        for connection in mem::take(&mut self.connections) {
            self.push(ListenerEffect::Cancel {
                connection: connection.id,
            });
        }
    }

    fn is_current_bind(&self, generation: u64) -> bool {
        generation == self.generation && self.listening
    }

    /// Drops a held connection and asks for it to be cancelled.
    fn forget(&mut self, connection: ConnectionId) {
        let before = self.connections.len();
        self.connections.retain(|c| c.id != connection);
        if self.connections.len() != before {
            self.push(ListenerEffect::Cancel { connection });
        }
    }

    fn push(&mut self, effect: ListenerEffect) {
        self.publish_if_changed();
        self.effects.push(effect);
    }

    fn publish_if_changed(&mut self) {
        if self.status != self.published {
            self.published = self.status.clone();
            self.effects
                .push(ListenerEffect::Publish(self.published.clone()));
        }
    }

    fn finish(&mut self) -> Vec<ListenerEffect> {
        self.publish_if_changed();
        mem::take(&mut self.effects)
    }
}

impl Connection {
    fn receive(&mut self, bytes: &[u8], cx: &mut Context) {
        match &mut self.phase {
            Phase::Closing => {}
            Phase::WebSocket(buffer) => {
                buffer.extend_from_slice(bytes);
                if buffer.len() > MAX_WEBSOCKET_BUFFER_BYTES {
                    self.close_websocket(close_code::MESSAGE_TOO_BIG, cx);
                } else {
                    self.process_frames(cx);
                }
            }
            Phase::Http(request) => {
                request.buffer.extend_from_slice(bytes);
                let step = if request.buffer.len() > MAX_HEADER_BYTES + MAX_BODY_BYTES {
                    HttpStep::Respond(413, "Payload Too Large")
                } else {
                    process_http(request, cx)
                };
                self.apply(step, cx);
            }
        }
    }

    fn apply(&mut self, step: HttpStep, cx: &mut Context) {
        match step {
            HttpStep::Wait => {}
            HttpStep::Respond(status, reason) => self.respond(status, reason, cx),
            HttpStep::Upgrade {
                accept_key,
                pipelined,
            } => {
                // Bytes past the header block are the start of the stream:
                // a fast client sends its hello right behind the handshake
                // (HK-256).
                self.phase = Phase::WebSocket(pipelined);
                cx.send(
                    format!(
                        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\
                         Connection: Upgrade\r\nSec-WebSocket-Accept: {accept_key}\r\n\r\n"
                    )
                    .into_bytes(),
                );
                self.process_frames(cx);
            }
            HttpStep::Hook(body) => {
                // Answer first, so the hook script's one-second curl is
                // never held up by the app (HK-247); a body that is no hook
                // is answered all the same and dropped (HK-249).
                self.respond(204, "No Content", cx);
                if let Some(hook) = hook_post(&body) {
                    cx.effects.push(ListenerEffect::DeliverHook {
                        generation: cx.generation,
                        hook,
                    });
                }
            }
        }
    }

    /// The one HTTP response, then close (HK-253): `Connection: close`
    /// always, `Content-Length: 0` on every status but 204.
    fn respond(&mut self, status: u16, reason: &str, cx: &mut Context) {
        let length = if status == 204 {
            ""
        } else {
            "Content-Length: 0\r\n"
        };
        cx.send(
            format!("HTTP/1.1 {status} {reason}\r\nConnection: close\r\n{length}\r\n").into_bytes(),
        );
        cx.close();
        self.phase = Phase::Closing;
    }

    fn close_websocket(&mut self, code: u16, cx: &mut Context) {
        cx.send(framing::encode_close(code));
        cx.close();
        self.phase = Phase::Closing;
    }

    /// Decodes and handles every complete frame waiting; a violation closes
    /// with 1002 (HK-236 to HK-242), and a frame after a close or a refusal
    /// is not handled.
    fn process_frames(&mut self, cx: &mut Context) {
        let Phase::WebSocket(buffer) = &mut self.phase else {
            return;
        };
        let frames = match decode_frames(buffer, MAX_PAYLOAD_BYTES) {
            Ok(decoded) => {
                buffer.drain(..decoded.consumed.min(buffer.len()));
                decoded.frames
            }
            Err(_) => {
                self.close_websocket(close_code::PROTOCOL_ERROR, cx);
                return;
            }
        };
        for frame in frames {
            if matches!(self.phase, Phase::Closing) {
                return;
            }
            self.frame(frame, cx);
        }
    }

    fn frame(&mut self, frame: Frame, cx: &mut Context) {
        match frame.opcode {
            Opcode::Text => self.text(&frame.payload, cx),
            // The pong echoes the ping's payload, before a hello too
            // (HK-225, HK-258).
            Opcode::Ping => cx.send(framing::encode_frame(Opcode::Pong, &frame.payload)),
            Opcode::Pong => {}
            // Answered so a stock client is not left waiting for a timeout;
            // its code and reason are not read (HK-258).
            Opcode::Close => self.close_websocket(close_code::NORMAL, cx),
            Opcode::Binary | Opcode::Continuation => {
                self.close_websocket(close_code::UNSUPPORTED_DATA, cx)
            }
        }
    }

    /// One client message (HK-224, HK-257). A refused message is answered
    /// with its error before anything else, authenticated or not; malformed,
    /// bad_hello and unsupported_protocol then close with 1002, the others
    /// leave the connection open. A hello with the token authenticates the
    /// connection while there is room under [`MAX_AUTHENTICATED`]; a second
    /// hello does nothing. An intent before the hello closes with 4003.
    fn text(&mut self, payload: &[u8], cx: &mut Context) {
        match parse_client_message(payload) {
            Err(failure) => {
                cx.send_message(&ServerMessage::failure(&failure));
                if matches!(
                    failure,
                    ClientMessageFailure::Malformed
                        | ClientMessageFailure::BadHello
                        | ClientMessageFailure::UnsupportedProtocol(_)
                ) {
                    self.close_websocket(close_code::PROTOCOL_ERROR, cx);
                }
            }
            Ok(ClientMessage::Hello { token }) => {
                if self.authenticated {
                    return;
                }
                if token != cx.token {
                    cx.send_message(&ServerMessage::error(
                        ErrorCode::AuthFailed,
                        AUTH_FAILED_MESSAGE,
                    ));
                    self.close_websocket(close_code::AUTH_FAILED, cx);
                } else if cx.authenticated >= MAX_AUTHENTICATED {
                    cx.send_message(&ServerMessage::error(
                        ErrorCode::ServerBusy,
                        SERVER_BUSY_MESSAGE,
                    ));
                    self.close_websocket(close_code::TRY_AGAIN_LATER, cx);
                } else {
                    self.authenticated = true;
                    cx.authenticated += 1;
                    cx.effects.push(ListenerEffect::Welcome {
                        connection: cx.connection,
                    });
                }
            }
            Ok(ClientMessage::Intent(intent)) => {
                if self.authenticated {
                    cx.effects.push(ListenerEffect::DeliverIntent {
                        generation: cx.generation,
                        intent,
                    });
                } else {
                    cx.send_message(&ServerMessage::error(
                        ErrorCode::NotAuthenticated,
                        NOT_AUTHENTICATED_MESSAGE,
                    ));
                    self.close_websocket(close_code::NOT_AUTHENTICATED, cx);
                }
            }
            Ok(ClientMessage::Ping) => cx.send_message(&ServerMessage::Pong),
        }
    }
}

/// Reads as much of the request as has arrived (HK-250 to HK-254): the head
/// once its block has ended (431 past [`MAX_HEADER_BYTES`] without an end,
/// 400 when it has no request line), then its body by `Content-Length`
/// (413 when negative or past [`MAX_BODY_BYTES`]; an unreadable value is no
/// body), or to the end of the stream when chunked. `Expect: 100-continue`
/// is answered once the head is read, whatever the request, since curl
/// waits for it before sending a body over about 1 KB.
fn process_http(request: &mut HttpRequest, cx: &mut Context) -> HttpStep {
    if request.head.is_none() {
        let Some(boundary) = header_boundary(&request.buffer) else {
            return if request.buffer.len() > MAX_HEADER_BYTES {
                HttpStep::Respond(431, "Request Header Fields Too Large")
            } else {
                HttpStep::Wait
            };
        };
        let Some(head) = request
            .buffer
            .get(..boundary.header_end)
            .and_then(RequestHead::parse)
        else {
            return HttpStep::Respond(400, "Bad Request");
        };
        request.body_start = boundary.body_start;
        if let Some(declared) = head.content_length() {
            match usize::try_from(declared) {
                Ok(length) if length <= MAX_BODY_BYTES => request.expected_body_length = length,
                _ => return HttpStep::Respond(413, "Payload Too Large"),
            }
        } else if head.is_chunked() {
            request.awaiting_end_of_stream = true;
        }
        if head.expects_continue() && !request.continue_sent {
            request.continue_sent = true;
            cx.send(b"HTTP/1.1 100 Continue\r\n\r\n".to_vec());
        }
        request.head = Some(head);
    }
    if request.awaiting_end_of_stream {
        return HttpStep::Wait;
    }
    let available = request.buffer.len().saturating_sub(request.body_start);
    if available >= request.expected_body_length {
        complete(request, false, cx.token)
    } else {
        HttpStep::Wait
    }
}

/// Routes a request whose head and body have arrived: `/ws` is the upgrade
/// decision's, with any method (HK-218 to HK-222); anything but `POST
/// /event` is 404; a missing or wrong `X-PowerUp-Token` is 403 (HK-246);
/// anything else is a hook post, its body cut at `Content-Length` (or all
/// that came, at the end of the stream). A request without a head stays
/// waiting.
fn complete(request: &HttpRequest, body_from_remainder: bool, token: &str) -> HttpStep {
    let Some(head) = &request.head else {
        return HttpStep::Wait;
    };
    let rest = request.buffer.get(request.body_start..).unwrap_or_default();
    match upgrade_decision(head) {
        Some(UpgradeDecision::Reject { status, reason }) => {
            return HttpStep::Respond(status, reason)
        }
        Some(UpgradeDecision::Accept { accept_key }) => {
            return HttpStep::Upgrade {
                accept_key,
                pipelined: rest.to_vec(),
            }
        }
        None => {}
    }
    if head.method != "POST" || head.path != "/event" {
        return HttpStep::Respond(404, "Not Found");
    }
    if token.is_empty() || head.value("x-powerup-token") != Some(token) {
        return HttpStep::Respond(403, "Forbidden");
    }
    let length = if body_from_remainder {
        rest.len()
    } else {
        request.expected_body_length.min(rest.len())
    };
    HttpStep::Hook(rest.get(..length).unwrap_or_default().to_vec())
}

/// A hook post's body as the hook it carries, or `None` for an empty or
/// unreadable body, one that is not a JSON object, one without a string
/// `hook_event_name`, or a hook PowerUp does not act on (SubagentStop,
/// PreToolUse, any later one). The body is read as Foundation's
/// `JSONSerialization` reads it, as a client's message is.
pub fn hook_post(body: &[u8]) -> Option<HookPost> {
    if body.is_empty() {
        return None;
    }
    let root = json::read_any_encoding(body)?;
    root.as_object()?;
    let (kind, text_key) = match root.get("hook_event_name")?.as_str()? {
        "Stop" => (HookKind::Stop, "last_assistant_message"),
        "UserPromptSubmit" => (HookKind::UserPromptSubmit, "prompt"),
        "Notification" => (HookKind::Notification, "message"),
        "SessionEnd" => (HookKind::SessionEnd, "reason"),
        "PostToolUse" => (HookKind::PostToolUse, "tool_name"),
        _ => return None,
    };
    let field = |key: &str| {
        root.get(key)
            .and_then(JsonValue::as_str)
            .filter(|value| !trim(value).is_empty())
            .map(str::to_owned)
    };
    Some(HookPost {
        kind,
        text: field(text_key),
        session_id: field("session_id"),
        cwd: field("cwd"),
    })
}

fn describe(error: &BindError, port: u16) -> ListenerProblem {
    match error {
        BindError::AddressInUse => ListenerProblem::PortInUse(port),
        BindError::Other(detail) => ListenerProblem::Failed {
            port,
            detail: detail.clone(),
        },
    }
}
