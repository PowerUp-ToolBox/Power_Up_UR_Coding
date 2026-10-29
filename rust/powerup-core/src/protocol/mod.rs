//! The PowerUp protocol, spec v0 (`docs/protocol.md`; spec #101, slice
//! 2.6): the local plugin API a script or device plugin on the same machine
//! speaks to a running PowerUp over a WebSocket on the listener port. The
//! spec and this module change together (HK-217).
//!
//! - [`message`]: every client and server message, the error codes and the
//!   version rule, and the intents a client may name;
//! - [`handshake`]: the request head on the listener port, the upgrade
//!   decision and the `Sec-WebSocket-Accept` value;
//! - [`framing`]: RFC 6455 frames as the server decodes and encodes them,
//!   with v0's limits, and the close codes in use.
//!
//! Everything here is bytes in and values out. The platform keeps the
//! sockets (NWListener and NWConnection on macOS); what the listener does
//! with a connection is the connection policy's.

pub mod framing;
pub mod handshake;
pub mod message;
