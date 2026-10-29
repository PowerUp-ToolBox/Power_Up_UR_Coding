//! The text safety rules of remote mode (slice 2.5): flattening dictated
//! text, splitting it into escape-safe cmux sends, parsing
//! `cmux list-workspaces`, stripping a title's activity glyph, condensing
//! cmux output and the friendly message for a failed cmux command. The
//! injector stays with the app: these functions take and return strings and
//! values, and never run cmux or post a keystroke (DESIGN v2.14 A).

use powerup_core::text_safety::{self, CmuxWorkspace, CommandResult};

use crate::{contain, CoreBridgeError};

/// One row of `cmux list-workspaces`: the ref (`workspace:N` or a bare
/// UUID), the title without its activity glyph, and whether cmux has it
/// selected.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreCmuxWorkspace {
    pub reference: String,
    pub title: String,
    pub selected: bool,
}

/// How a cmux command ended, as the app's process runner reports it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreCommandResult {
    pub status: i64,
    pub standard_output: String,
    pub standard_error: String,
    pub timed_out: bool,
    pub spawn_failed: bool,
}

impl From<CmuxWorkspace> for CoreCmuxWorkspace {
    fn from(workspace: CmuxWorkspace) -> Self {
        CoreCmuxWorkspace {
            reference: workspace.reference,
            title: workspace.title,
            selected: workspace.selected,
        }
    }
}

impl From<CoreCommandResult> for CommandResult {
    fn from(result: CoreCommandResult) -> Self {
        CommandResult {
            status: result.status,
            standard_output: result.standard_output,
            standard_error: result.standard_error,
            timed_out: result.timed_out,
            spawn_failed: result.spawn_failed,
        }
    }
}

/// The text with every line break flattened to a space, a run of them to
/// one (`text_safety::flatten_line_breaks`).
#[uniffi::export]
pub fn flatten_line_breaks(text: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(text_safety::flatten_line_breaks(&text)))
}

/// The flattened text as `cmux send` segments cmux cannot reinterpret
/// (`text_safety::escape_safe_segments`); empty text is no segment.
#[uniffi::export]
pub fn escape_safe_segments(text: String) -> Result<Vec<String>, CoreBridgeError> {
    contain(|| Ok(text_safety::escape_safe_segments(&text)))
}

/// `cmux list-workspaces` output as rows (`text_safety::parse_workspaces`).
#[uniffi::export]
pub fn parse_workspaces(output: String) -> Result<Vec<CoreCmuxWorkspace>, CoreBridgeError> {
    contain(|| {
        Ok(text_safety::parse_workspaces(&output)
            .into_iter()
            .map(Into::into)
            .collect())
    })
}

/// A workspace title without its leading activity glyph
/// (`text_safety::strip_status_glyph`).
#[uniffi::export]
pub fn strip_status_glyph(title: String) -> Result<String, CoreBridgeError> {
    contain(|| Ok(text_safety::strip_status_glyph(&title).to_owned()))
}

/// cmux output as one line of at most `max_chars` characters
/// (`text_safety::condense`).
#[uniffi::export]
pub fn condense(text: String, max_chars: i64) -> Result<String, CoreBridgeError> {
    contain(|| Ok(text_safety::condense(&text, max_chars)))
}

/// The friendly message for a cmux command `action` names that failed as
/// `result` says (`text_safety::failure_message`).
#[uniffi::export]
pub fn failure_message(
    action: String,
    result: CoreCommandResult,
) -> Result<String, CoreBridgeError> {
    contain(|| Ok(text_safety::failure_message(&action, &result.into())))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn result(status: i64, standard_error: &str) -> CoreCommandResult {
        CoreCommandResult {
            status,
            standard_output: String::new(),
            standard_error: standard_error.into(),
            timed_out: false,
            spawn_failed: false,
        }
    }

    #[test]
    fn dictated_text_reaches_cmux_flat_and_defused() {
        assert_eq!(
            flatten_line_breaks("one\r\ntwo\u{2028}three".into()).unwrap(),
            "one two three"
        );
        assert_eq!(
            escape_safe_segments("ls\nC:\\new\\temp".into()).unwrap(),
            ["ls C:\\", "new\\", "temp"]
        );
        assert_eq!(
            escape_safe_segments(String::new()).unwrap(),
            Vec::<String>::new()
        );
    }

    #[test]
    fn workspace_rows_cross_as_records() {
        let output =
            "* workspace:11  \u{2810} Build app  [selected]\n  workspace:7   \u{2733} Design\n";
        assert_eq!(
            parse_workspaces(output.into()).unwrap(),
            [
                CoreCmuxWorkspace {
                    reference: "workspace:11".into(),
                    title: "Build app".into(),
                    selected: true
                },
                CoreCmuxWorkspace {
                    reference: "workspace:7".into(),
                    title: "Design".into(),
                    selected: false
                }
            ]
        );
        assert_eq!(
            strip_status_glyph("\u{2733} Design".into()).unwrap(),
            "Design"
        );
        assert_eq!(
            strip_status_glyph("\u{2705} Done".into()).unwrap(),
            "\u{2705} Done"
        );
    }

    #[test]
    fn failures_condense_and_classify() {
        assert_eq!(condense("a\n b".into(), 10).unwrap(), "a b");
        assert_eq!(condense(String::new(), -1).unwrap(), "\u{2026}");
        assert_eq!(
            failure_message("Sending text to cmux".into(), result(1, "Error: Socket not found")).unwrap(),
            "Sending text to cmux failed \u{2014} cmux isn\u{2019}t running. Open the cmux app, then try again."
        );
        assert_eq!(
            failure_message("Listing cmux workspaces".into(), result(-1, " ")).unwrap(),
            "Listing cmux workspaces failed (exit -1)."
        );
        let mut spawn = result(0, "no such file");
        spawn.spawn_failed = true;
        spawn.timed_out = true;
        assert_eq!(
            failure_message("Reaching cmux".into(), spawn).unwrap(),
            "Reaching cmux failed to start: no such file"
        );
    }
}
