//! The status pill and light bar (DESIGN v1.4, v2.6 B), and the remote-turn
//! table that feeds them in remote mode (v1.10, v2.2 B). Pure functions:
//! the platform reads its inputs (capture, speech, the harness) and shows
//! the answer.

use std::collections::BTreeMap;

use crate::harness::HarnessState;

/// What the pill and the light bar show.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppStatus {
    NoController,
    Idle,
    Listening,
    Thinking,
    Speaking,
}

impl AppStatus {
    /// The Swift case name, which the fixtures use.
    pub fn name(self) -> &'static str {
        match self {
            AppStatus::NoController => "noController",
            AppStatus::Idle => "idle",
            AppStatus::Listening => "listening",
            AppStatus::Thinking => "thinking",
            AppStatus::Speaking => "speaking",
        }
    }
}

/// The precedence of DESIGN v2.6 B (HK-121): listening, then speaking, then
/// thinking, then the resting state. Live activity outranks a missing
/// controller, because the controller is optional; "no controller" is only
/// ever the resting state.
pub fn derived_status(
    controller_connected: bool,
    is_ptt_active: bool,
    is_speaking: bool,
    is_working: bool,
) -> AppStatus {
    if is_ptt_active {
        AppStatus::Listening
    } else if is_speaking {
        AppStatus::Speaking
    } else if is_working {
        AppStatus::Thinking
    } else if controller_connected {
        AppStatus::Idle
    } else {
        AppStatus::NoController
    }
}

/// The working input of [`derived_status`] (HK-120): the harness itself is
/// working, or, in remote mode only, a hooked session's turn is active. A
/// remote-turn flag left over in built-in mode never counts.
pub fn derived_is_working(
    harness_state: HarnessState,
    is_remote_mode: bool,
    remote_turn_active: bool,
) -> bool {
    harness_state == HarnessState::Working || (is_remote_mode && remote_turn_active)
}

/// A remote turn with no sign of life for this long is presumed dead: a
/// killed terminal, a crashed CLI or an Escape pressed in the session sends
/// no Stop. A long turn can outlive it; the cost is an early idle that the
/// next hook corrects, against an amber light nothing would ever clear.
pub const REMOTE_TURN_EXPIRY_SECONDS: f64 = 15.0 * 60.0;

/// The turn table (session id → last sign of life, in seconds) without its
/// expired entries (HK-109): an entry survives only while its last sign of
/// life is strictly newer than `now - expiry`.
pub fn live_remote_turns(
    turns: &BTreeMap<String, f64>,
    now: f64,
    expiry: f64,
) -> BTreeMap<String, f64> {
    let cutoff = now - expiry;
    turns
        .iter()
        .filter(|(_, last)| **last > cutoff)
        .map(|(id, last)| (id.clone(), *last))
        .collect()
}

/// Whether a remote turn lights the bar: any entry, or, with a focus set,
/// only the focused session's (DESIGN v2.2 B).
pub fn remote_turn_is_active(turns: &BTreeMap<String, f64>, focus: Option<&str>) -> bool {
    match focus {
        Some(focus) => turns.contains_key(focus),
        None => !turns.is_empty(),
    }
}

/// The model chip (HK-088, DESIGN v1.3 C): the configured alias whenever it
/// is an explicit one, so a Cycle Model press shows at once; otherwise what
/// the harness reported, otherwise "default".
pub fn model_chip_label(configured: &str, reported: Option<&str>) -> String {
    if configured != "default" && !configured.is_empty() {
        return configured.to_owned();
    }
    match reported {
        Some(reported) if !reported.is_empty() => reported.to_owned(),
        _ => "default".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_chip_prefers_an_explicit_alias_then_the_report() {
        assert_eq!(model_chip_label("opus", Some("claude-sonnet-4-5")), "opus");
        assert_eq!(
            model_chip_label("default", Some("claude-sonnet-4-5")),
            "claude-sonnet-4-5"
        );
        assert_eq!(model_chip_label("", Some("x")), "x");
        assert_eq!(model_chip_label("default", Some("")), "default");
        assert_eq!(model_chip_label("default", None), "default");
    }
}
