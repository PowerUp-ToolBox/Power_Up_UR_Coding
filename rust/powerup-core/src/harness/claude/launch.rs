//! The argv the claude CLI is launched with (HK-077, HK-080). The platform
//! resolves the binary, sets the working directory and environment, and
//! spawns it with these arguments.

use crate::text;

/// The arguments of one launch, in order.
///
/// - `-p`, `--verbose`, `--input-format stream-json`, `--output-format
///   stream-json` and `--include-partial-messages` always come first.
///   `--verbose` is REQUIRED: verified live, stream-json output refuses to
///   run without it ("When using --print, --output-format=stream-json
///   requires --verbose"). `--include-partial-messages` is what makes the
///   CLI emit text deltas.
/// - `--model` unless the model is empty or `"default"`, which means the
///   CLI's own default.
/// - `--permission-mode` whenever the mode is non-empty: `"default"` is a
///   real permission mode and is passed.
/// - `--effort` unless it is empty or `"default"`. There is no live effort
///   switch, so a change restarts the session. `"max"` (shown as Ultra) is
///   accepted by `claude -p`, verified live (HK-080); Ultra's multi-agent
///   part has no flag and rides on the `ultracode` prompt keyword.
/// - `--resume` with the id trimmed, unless it trims to nothing.
///
/// Values other than the resume id are passed as given.
pub fn launch_arguments(
    model: &str,
    permission_mode: &str,
    effort: &str,
    resume_session_id: Option<&str>,
) -> Vec<String> {
    let mut arguments: Vec<String> = [
        "-p",
        "--verbose",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--include-partial-messages",
    ]
    .iter()
    .map(|argument| (*argument).to_owned())
    .collect();
    let mut flag = |name: &str, value: &str| {
        arguments.push(name.to_owned());
        arguments.push(value.to_owned());
    };
    if !model.is_empty() && model != "default" {
        flag("--model", model);
    }
    if !permission_mode.is_empty() {
        flag("--permission-mode", permission_mode);
    }
    if !effort.is_empty() && effort != "default" {
        flag("--effort", effort);
    }
    if let Some(id) = resume_session_id.map(text::trim) {
        if !id.is_empty() {
            flag("--resume", id);
        }
    }
    arguments
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verbose_is_always_passed() {
        for (model, mode, effort) in [("", "", ""), ("opus", "plan", "max")] {
            let arguments = launch_arguments(model, mode, effort, None);
            assert_eq!(arguments[..2], ["-p", "--verbose"]);
            assert!(arguments.contains(&"--include-partial-messages".to_owned()));
        }
    }
}
