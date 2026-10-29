//! The Agent Client Protocol adapter (DESIGN.md v2.0, v2.2 E): JSON-RPC 2.0,
//! one JSON object per line over the agent's stdio. It drives opencode
//! natively, Claude Code and Codex through their npx bridges, or a custom
//! command.
//!
//! The wire shapes were verified live on 2026-08-27 against opencode 1.1.44
//! and claude-agent-acp 0.16.2 (codex-acp 1.7.0: the handshake only). They
//! are ground truth (HK-126): `Tests/Fixtures/harness/acp-mock-agent.py`
//! proves only that the adapter talks to the mock. Parse defensively:
//! unknown methods, update kinds and fields are ignored, and a protocol
//! surprise degrades to an error event, never a panic.
//!
//! The core reads the agent's raw stdout lines with the shared
//! Foundation-matching reader (`crate::json`) and builds the lines it
//! writes; the platform owns the process, its pipes and its timers, and
//! carries out the adapter's effects in order.

pub mod adapter;
pub mod agents;
pub mod environment;
pub mod permission;
mod rpc;
mod update;
