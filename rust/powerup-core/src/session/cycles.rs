//! The setting cycles the pad steps through, and the names the session
//! speaks and logs for their values.

/// The model cycle when the user's own is empty.
pub const DEFAULT_MODEL_CYCLE: [&str; 4] = ["sonnet", "opus", "haiku", "fable"];

/// The effort cycle (HK-009). "default" is not in it: it means "pass no
/// --effort", which the cycle never needs to return to. "max" reads as
/// Ultra.
pub const EFFORT_CYCLE: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// The permission-mode cycle (HK-008). bypassPermissions is left out on
/// purpose: a stray press must never turn on approve-everything, and once
/// the cycle leaves a hand-set bypass it never comes back to it.
pub const PERMISSION_MODE_CYCLE: [&str; 3] = ["acceptEdits", "plan", "default"];

/// The entry after `current`, wrapping round; the first entry when
/// `current` is not in the cycle, so a hand-edited value never stalls the
/// button (HK-010). An empty cycle leaves `current` as it is.
pub fn next_value<S: AsRef<str>>(current: &str, cycle: &[S]) -> String {
    let Some(first) = cycle.first() else {
        return current.to_owned();
    };
    match cycle.iter().position(|entry| entry.as_ref() == current) {
        Some(index) => cycle[(index + 1) % cycle.len()].as_ref().to_owned(),
        None => first.as_ref().to_owned(),
    }
}

/// The user's model cycle with its entries trimmed and blank ones dropped;
/// an empty result is the default cycle (HK-010).
pub fn model_cycle(configured: &[String]) -> Vec<String> {
    let cycle: Vec<String> = configured
        .iter()
        .map(|entry| crate::text::trim(entry))
        .filter(|entry| !entry.is_empty())
        .map(str::to_owned)
        .collect();
    if cycle.is_empty() {
        DEFAULT_MODEL_CYCLE.iter().map(|&m| m.to_owned()).collect()
    } else {
        cycle
    }
}

/// The name an effort value is shown and spoken by; "max" is Ultra
/// everywhere. An unknown value is shown as it is.
pub fn effort_display_name(effort: &str) -> String {
    match effort {
        "default" => "Default",
        "low" => "Low",
        "medium" => "Medium",
        "high" => "High",
        "xhigh" => "Extra High",
        "max" => "Ultra",
        other => other,
    }
    .to_owned()
}

/// The name an ACP agent setting is shown by.
pub fn acp_agent_display_name(agent: &str) -> String {
    match agent {
        "opencode" => "opencode",
        "claudeBridge" => "Claude Code (ACP bridge)",
        "codexBridge" => "Codex (ACP bridge)",
        "custom" => "Custom command",
        other => other,
    }
    .to_owned()
}

/// The stored control mode read at runtime: only "remote" is remote mode,
/// anything else is the built-in session (HK-156).
pub fn is_remote_mode(control_mode: &str) -> bool {
    control_mode == "remote"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_value_wraps_and_falls_back() {
        assert_eq!(next_value("sonnet", &DEFAULT_MODEL_CYCLE), "opus");
        assert_eq!(next_value("fable", &DEFAULT_MODEL_CYCLE), "sonnet");
        assert_eq!(next_value("my-model", &DEFAULT_MODEL_CYCLE), "sonnet");
        let empty: [&str; 0] = [];
        assert_eq!(next_value("x", &empty), "x");
    }

    #[test]
    fn model_cycle_trims_and_defaults() {
        let configured = vec![" opus ".to_owned(), "".to_owned(), "\n".to_owned()];
        assert_eq!(model_cycle(&configured), ["opus"]);
        assert_eq!(model_cycle(&["  ".to_owned()]), DEFAULT_MODEL_CYCLE);
        assert_eq!(model_cycle(&[]), DEFAULT_MODEL_CYCLE);
    }

    #[test]
    fn effort_cycle_never_holds_default_and_max_reads_as_ultra() {
        assert!(!EFFORT_CYCLE.contains(&"default"));
        assert_eq!(next_value("default", &EFFORT_CYCLE), "low");
        assert_eq!(next_value("max", &EFFORT_CYCLE), "low");
        assert_eq!(effort_display_name("max"), "Ultra");
        assert_eq!(effort_display_name("xhigh"), "Extra High");
        assert_eq!(effort_display_name("turbo"), "turbo");
    }

    #[test]
    fn the_permission_cycle_never_holds_bypass() {
        assert!(!PERMISSION_MODE_CYCLE.contains(&"bypassPermissions"));
        assert_eq!(
            next_value("bypassPermissions", &PERMISSION_MODE_CYCLE),
            "acceptEdits"
        );
        assert_eq!(next_value("default", &PERMISSION_MODE_CYCLE), "acceptEdits");
    }

    #[test]
    fn only_remote_is_remote_mode() {
        assert!(is_remote_mode("remote"));
        for mode in ["builtin", "", "Remote", "x"] {
            assert!(!is_remote_mode(mode), "{mode}");
        }
        assert_eq!(acp_agent_display_name("custom"), "Custom command");
        assert_eq!(acp_agent_display_name("mine"), "mine");
    }
}
