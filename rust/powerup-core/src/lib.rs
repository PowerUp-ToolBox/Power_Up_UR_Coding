//! PowerUp's core: the platform-independent logic every OS app links
//! (ADR 0012). Each OS keeps its own UI and platform adapters; the core holds
//! no threads and binds no OS framework.
//!
//! Every public function is total: it returns its value, or a `Result` with a
//! [`CoreError`] when it can fail, and never panics. The bridge crate still
//! catches any panic at its boundary, so a core bug can never take down the
//! app that holds the microphone permission.

pub mod action;
pub mod harness;
pub mod hold;
pub mod intent;
pub mod mapping;
pub mod probe;
pub mod profile;
pub mod session;
pub mod slots;
pub mod status;
pub mod text;
pub mod wire;

use std::fmt;

/// A failure the core reports to its caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoreError {
    /// The call failed for the reason given.
    Failed { message: String },
}

impl fmt::Display for CoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CoreError::Failed { message } => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for CoreError {}
