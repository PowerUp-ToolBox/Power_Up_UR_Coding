//! The built-in Claude harness: the `claude` CLI in stream-json mode
//! (DESIGN.md v1.1 A, verified live against claude CLI v2.1.243). The core
//! reads its stdout lines and builds its stdin lines; the platform spawns
//! the process and moves the bytes.

pub mod event;
mod json;
pub mod parse;
pub mod stdin;
