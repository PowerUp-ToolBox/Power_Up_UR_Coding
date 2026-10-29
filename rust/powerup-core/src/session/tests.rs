//! Rules the shared scenarios do not reach. Everything else is pinned by
//! `Tests/Fixtures/session/` through `tests/session.rs`.

use std::collections::BTreeMap;

use super::*;

fn settings() -> SessionSettings {
    SessionSettings {
        harness_kind: "claude".to_owned(),
        acp_agent: "opencode".to_owned(),
        acp_custom_command: String::new(),
        control_mode: "builtin".to_owned(),
        model: "default".to_owned(),
        model_cycle: Vec::new(),
        effort: "default".to_owned(),
        permission_mode: "acceptEdits".to_owned(),
        project_dir: Some("/work/app".to_owned()),
        last_session_id: None,
        session_ids_by_project: BTreeMap::new(),
        recent_project_dirs: Vec::new(),
        claude_path: None,
        remote_auto_submit: true,
    }
}

fn context(settings: SessionSettings) -> SessionContext {
    SessionContext {
        settings,
        claude: HarnessSnapshot {
            supports_effort: true,
            ..HarnessSnapshot::stopped()
        },
        acp: None,
        acp_agent_command: None,
        now: 0.0,
    }
}

fn recents(effects: &[SessionEffect]) -> Option<Vec<String>> {
    effects.iter().rev().find_map(|effect| match effect {
        SessionEffect::ChangeConfig(ConfigChange::RecentProjectDirs(paths)) => Some(paths.clone()),
        _ => None,
    })
}

#[test]
fn a_new_machine_adopts_its_baselines_silently() {
    let mut stored = settings();
    stored.control_mode = "remote".to_owned();
    stored.harness_kind = "acp".to_owned();
    stored.acp_agent = "custom".to_owned();
    let mut machine = SessionMachine::new(&stored);
    // Launching in remote mode with an ACP agent selected is not a switch
    // into either: the derived-update pass finds nothing to do.
    assert_eq!(machine.sync_settings(&context(stored.clone())), []);
    // A real change afterwards still acts once.
    stored.control_mode = "builtin".to_owned();
    let effects = machine.sync_settings(&context(stored.clone()));
    assert!(effects.contains(&SessionEffect::AppendTranscript {
        kind: TranscriptKind::System,
        text: "Built-in session mode — PowerUp runs its own Claude session again.".to_owned(),
    }));
    assert_eq!(machine.sync_settings(&context(stored)), []);
}

#[test]
fn events_from_a_retired_adapter_are_dropped_without_a_status_update() {
    let mut machine = SessionMachine::new(&settings());
    let ctx = context(settings());
    let late_exit = HarnessEvent::Ended { exit_code: 1 };
    assert_eq!(
        machine.harness_event(&ctx, HarnessKind::Acp, late_exit.clone()),
        []
    );
    // The selected adapter's own event always ends with a status update.
    let effects = machine.harness_event(&ctx, HarnessKind::Claude, late_exit);
    assert_eq!(effects.last(), Some(&SessionEffect::UpdateStatus));
}

#[test]
fn recents_cap_at_eight() {
    let mut stored = settings();
    stored.recent_project_dirs = (1..=8).map(|n| format!("/work/p{n}")).collect();
    let mut machine = SessionMachine::new(&stored);
    let effects = machine.adopt_project(&context(stored.clone()), "/work/new", true);
    let written = recents(&effects).unwrap_or_default();
    assert_eq!(written.len(), 8);
    assert_eq!(written[0], "/work/new");
    assert_eq!(written[7], "/work/p7");

    // The picker moves a known folder to the front; nothing is dropped.
    let effects = machine.adopt_project(&context(stored.clone()), "/work/p5", true);
    let written = recents(&effects).unwrap_or_default();
    assert_eq!(written[0], "/work/p5");
    assert_eq!(written.len(), 8);

    // A switch to a folder already listed keeps the order and writes nothing.
    let effects = machine.adopt_project(&context(stored), "/work/p5", false);
    assert_eq!(recents(&effects), None);
}

#[test]
fn cycle_project_walks_the_list_in_order() {
    let mut stored = settings();
    stored.project_dir = Some("/work/b".to_owned());
    let list: Vec<String> = ["/work/a", "/work/b", "/work/c"]
        .iter()
        .map(|&p| p.to_owned())
        .collect();
    stored.recent_project_dirs = list.clone();
    let mut machine = SessionMachine::new(&stored);
    let effects = machine.cycle_project(&context(stored.clone()), &list);
    assert!(
        effects.contains(&SessionEffect::ChangeConfig(ConfigChange::ProjectDir(
            "/work/c".to_owned()
        )))
    );
    // Cycling never reorders the list.
    assert_eq!(recents(&effects), None);

    // From the last entry it wraps; from a folder not in the list it starts
    // at the first.
    stored.project_dir = Some("/work/c".to_owned());
    let effects = machine.cycle_project(&context(stored.clone()), &list);
    assert!(
        effects.contains(&SessionEffect::ChangeConfig(ConfigChange::ProjectDir(
            "/work/a".to_owned()
        )))
    );
    stored.project_dir = Some("/elsewhere".to_owned());
    let effects = machine.cycle_project(&context(stored.clone()), &list);
    assert!(
        effects.contains(&SessionEffect::ChangeConfig(ConfigChange::ProjectDir(
            "/work/a".to_owned()
        )))
    );

    // One folder is not a cycle.
    let effects = machine.cycle_project(&context(stored), &list[..1]);
    assert_eq!(effects.last(), Some(&SessionEffect::ErrorHaptic));
}

#[test]
fn an_acp_agent_that_cannot_be_found_is_reported_not_started() {
    let mut stored = settings();
    stored.harness_kind = "acp".to_owned();
    let mut machine = SessionMachine::new(&stored);
    let effects = machine.start_session_if_needed(&context(stored));
    assert!(!effects
        .iter()
        .any(|effect| matches!(effect, SessionEffect::StartHarness { .. })));
    assert!(effects.contains(&SessionEffect::AppendTranscript {
        kind: TranscriptKind::Error,
        text: "Couldn't find the opencode command — install it, or pick another harness in Settings → General.".to_owned(),
    }));
}

#[test]
fn the_send_refusal_matches_the_inline_one() {
    let mut stored = settings();
    stored.project_dir = None;
    let mut machine = SessionMachine::new(&stored);
    let inline = machine.send_user_text(&context(stored.clone()), "Hi.");
    let refused = machine.send_refused(&context(stored));
    assert_eq!(&inline[inline.len() - refused.len()..], refused.as_slice());
}
