//! The first-party ACP agents and how each one is launched (HK-129,
//! HK-130).
//!
//! opencode speaks ACP natively. Claude Code and Codex speak it through
//! bridge packages run with `npx -y` and no version pin, so the bridges
//! float with npm. The packages have been renamed three times; these names
//! were last verified on 2026-08-27 (claude-agent-acp 0.16.2, and the
//! codex-acp 1.7.0 handshake), so the next rename is a one-line change
//! here. The platform finds opencode and npx on its own install paths
//! (HK-286); a custom executable is used as typed.

use crate::text;

/// The Claude Code bridge package.
pub const CLAUDE_BRIDGE_PACKAGE: &str = "@agentclientprotocol/claude-agent-acp";

/// The Codex bridge package.
pub const CODEX_BRIDGE_PACKAGE: &str = "@agentclientprotocol/codex-acp";

/// Where the Codex bridge lives (docs/harnesses.md).
pub const CODEX_BRIDGE_REPOSITORY: &str = "https://github.com/agentclientprotocol/codex-acp";

/// The program an agent runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentProgram {
    /// opencode, found on the platform's install paths.
    Opencode,
    /// npx, found on the platform's install paths.
    Npx,
    /// A custom executable, as the user typed it.
    Command(String),
}

/// An agent's program and the arguments that follow it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentLaunch {
    pub program: AgentProgram,
    pub arguments: Vec<String>,
}

/// How the stored ACP agent is launched: `opencode` runs `opencode acp`,
/// `claudeBridge` and `codexBridge` run `npx -y` and their package, and
/// `custom` runs `custom_command` split on spaces with the empty pieces
/// dropped ([`text::split_on_spaces`]), its first piece the executable.
/// There is no quoting, so a path with a space splits wrongly, as it did in
/// Swift (HK-130). `None` for a custom command with no pieces and for any
/// other agent; names match exactly and case-sensitively.
pub fn agent_launch(agent: &str, custom_command: &str) -> Option<AgentLaunch> {
    let npx = |package: &str| AgentLaunch {
        program: AgentProgram::Npx,
        arguments: vec!["-y".to_owned(), package.to_owned()],
    };
    match agent {
        "opencode" => Some(AgentLaunch {
            program: AgentProgram::Opencode,
            arguments: vec!["acp".to_owned()],
        }),
        "claudeBridge" => Some(npx(CLAUDE_BRIDGE_PACKAGE)),
        "codexBridge" => Some(npx(CODEX_BRIDGE_PACKAGE)),
        "custom" => {
            let pieces = text::split_on_spaces(custom_command);
            let (executable, arguments) = pieces.split_first()?;
            Some(AgentLaunch {
                program: AgentProgram::Command((*executable).to_owned()),
                arguments: arguments.iter().map(|piece| (*piece).to_owned()).collect(),
            })
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_presets_are_pinned() {
        assert_eq!(
            agent_launch("claudeBridge", ""),
            Some(AgentLaunch {
                program: AgentProgram::Npx,
                arguments: vec![
                    "-y".to_owned(),
                    "@agentclientprotocol/claude-agent-acp".to_owned()
                ],
            })
        );
        assert_eq!(
            agent_launch("custom", "  /x/agent  acp "),
            Some(AgentLaunch {
                program: AgentProgram::Command("/x/agent".to_owned()),
                arguments: vec!["acp".to_owned()],
            })
        );
        assert_eq!(agent_launch("custom", "   "), None);
        assert_eq!(agent_launch("Opencode", ""), None);
        assert!(CODEX_BRIDGE_REPOSITORY
            .ends_with(CODEX_BRIDGE_PACKAGE.trim_start_matches("@agentclientprotocol")));
    }
}
