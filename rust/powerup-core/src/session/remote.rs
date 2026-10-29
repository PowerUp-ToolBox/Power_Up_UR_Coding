//! Remote mode's read-back state (DESIGN v1.10, v2.2 B, v2.8 A): the turn
//! table, the sessions seen recently and the read-back focus, plus the
//! folder rules that decide which hooks are PowerUp's.

use std::collections::BTreeMap;

use super::context::{HookEvent, PlacedPath};
use crate::text::{grapheme_prefix, last_path_component};

/// The turn key of a hook that carried no session id: every such hook is
/// one shared session.
pub const UNKNOWN_SESSION: &str = "unknown-session";

/// A remote session unseen for this long leaves the focus cycle (HK-117):
/// sessions end without telling anyone (a closed terminal sends no
/// SessionEnd).
pub const REMOTE_SESSION_MEMORY_SECONDS: f64 = 30.0 * 60.0;

/// A remote session seen through its hooks.
#[derive(Debug, Clone, PartialEq)]
pub struct KnownSession {
    /// Its working directory, as the last hook that carried one said.
    pub cwd: Option<String>,
    /// When a hook last came from it, in the context's seconds.
    pub last_seen: f64,
}

/// Turn state per remote session, the session registry and the focus.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RemoteState {
    /// Session id → its turn's last sign of life. One global flag let
    /// sessions running at once corrupt each other, and a session closed
    /// mid-turn pinned the light amber; entries leave on Stop, on
    /// SessionEnd, or by expiring (HK-109).
    pub turns: BTreeMap<String, f64>,
    /// What the platform shows: a turn is in flight (the focused one's,
    /// when a focus is set).
    pub active: bool,
    pub known: BTreeMap<String, KnownSession>,
    /// `None` hears every session; otherwise only this one is spoken,
    /// buzzes and drives the working light, and the rest only log.
    pub focus: Option<String>,
}

/// Whether a hook belongs to the chosen project folder (HK-113): the folder
/// itself or any folder below it, compared by whole components after the
/// platform standardized both paths and resolved their symlinks, so
/// `/work/app-old` is not inside `/work/app`. With no folder chosen every
/// hook counts; with one chosen, a hook without a working directory cannot
/// be placed and does not. A path the platform did not place is treated
/// the same way.
pub fn in_project_folder(
    project_dir: Option<&str>,
    project: Option<&PlacedPath>,
    hook: &HookEvent,
) -> bool {
    if project_dir.is_none_or(str::is_empty) {
        return true;
    }
    if hook.cwd.as_deref().is_none_or(str::is_empty) {
        return false;
    }
    match (&hook.cwd_place, project) {
        (Some(cwd), Some(project)) => cwd.components.starts_with(&project.components),
        _ => false,
    }
}

/// The label a reply from another folder gets (HK-114): `"[name] "`, or
/// nothing when the hook had no working directory, when it is the project
/// folder itself, or when the folder has no name.
///
/// Quirk kept on purpose (HK-115): membership resolves symlinks, the label
/// only standardizes, so a session that reaches the project folder through
/// a symlink is heard and still labelled with its folder's name.
pub fn cwd_label(
    project_dir: Option<&str>,
    project: Option<&PlacedPath>,
    hook: &HookEvent,
) -> String {
    if hook.cwd.as_deref().is_none_or(str::is_empty) {
        return String::new();
    }
    let Some(cwd) = &hook.cwd_place else {
        return String::new();
    };
    if project_dir.is_some_and(|dir| !dir.is_empty())
        && project.is_some_and(|project| project.standardized == cwd.standardized)
    {
        return String::new();
    }
    if cwd.name.is_empty() {
        String::new()
    } else {
        format!("[{}] ", cwd.name)
    }
}

/// The focus cycle's order (HK-117): by folder name (the last component of
/// the session's cwd, or of its id when it has none), then by session id,
/// so two folders with the same name never swap places. Compared by scalar
/// values, where Swift compared canonically (HK-397): only ASCII ids and
/// folder names that order the cycle are compared.
pub fn focus_order(known: &BTreeMap<String, KnownSession>) -> Vec<String> {
    let mut ordered: Vec<(&str, &str)> = known
        .iter()
        .map(|(id, session)| {
            let source = session.cwd.as_deref().unwrap_or(id);
            (last_path_component(source), id.as_str())
        })
        .collect();
    ordered.sort();
    ordered.into_iter().map(|(_, id)| id.to_owned()).collect()
}

/// The chip's name for the focused session: its folder's name, or the
/// first eight characters of its id when no folder is known.
pub fn focus_label(known: &BTreeMap<String, KnownSession>, focus: &str) -> String {
    match known.get(focus).and_then(|session| session.cwd.as_deref()) {
        Some(cwd) if !cwd.is_empty() => last_path_component(cwd).to_owned(),
        _ => grapheme_prefix(focus, 8).to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session::context::HookKind;

    fn place(path: &str) -> PlacedPath {
        let mut components = vec!["/".to_owned()];
        components.extend(path.split('/').filter(|p| !p.is_empty()).map(str::to_owned));
        PlacedPath {
            components,
            standardized: path.to_owned(),
            name: last_path_component(path).to_owned(),
        }
    }

    fn hook(cwd: Option<&str>) -> HookEvent {
        HookEvent {
            kind: HookKind::Stop,
            text: None,
            session_id: None,
            cwd: cwd.map(str::to_owned),
            cwd_place: cwd.filter(|c| !c.is_empty()).map(place),
        }
    }

    fn session(cwd: Option<&str>) -> KnownSession {
        KnownSession {
            cwd: cwd.map(str::to_owned),
            last_seen: 0.0,
        }
    }

    #[test]
    fn membership_is_by_whole_components() {
        let project = place("/work/app");
        let dir = Some("/work/app");
        assert!(in_project_folder(
            dir,
            Some(&project),
            &hook(Some("/work/app"))
        ));
        assert!(in_project_folder(
            dir,
            Some(&project),
            &hook(Some("/work/app/api"))
        ));
        assert!(!in_project_folder(
            dir,
            Some(&project),
            &hook(Some("/work/app-old"))
        ));
        assert!(!in_project_folder(dir, Some(&project), &hook(None)));
        assert!(!in_project_folder(dir, Some(&project), &hook(Some(""))));
        assert!(in_project_folder(None, None, &hook(None)));
        assert!(in_project_folder(Some(""), None, &hook(Some("/x"))));
    }

    #[test]
    fn a_symlinked_member_keeps_its_label() {
        // The platform resolved the symlink for the components, not for the
        // standardized path: the hook is heard and labelled (HK-115).
        let project = place("/work/app");
        let mut linked = hook(Some("/links/app"));
        if let Some(place) = linked.cwd_place.as_mut() {
            place.components = project.components.clone();
        }
        let dir = Some("/work/app");
        assert!(in_project_folder(dir, Some(&project), &linked));
        assert_eq!(cwd_label(dir, Some(&project), &linked), "[app] ");
    }

    #[test]
    fn labels_name_other_folders_only() {
        let project = place("/work/app");
        let dir = Some("/work/app");
        assert_eq!(cwd_label(dir, Some(&project), &hook(Some("/work/app"))), "");
        assert_eq!(
            cwd_label(dir, Some(&project), &hook(Some("/work/app/api"))),
            "[api] "
        );
        assert_eq!(cwd_label(dir, Some(&project), &hook(None)), "");
        assert_eq!(cwd_label(None, None, &hook(Some("/work/beta"))), "[beta] ");
        assert_eq!(cwd_label(None, None, &hook(Some("/"))), "[/] ");
    }

    #[test]
    fn focus_order_breaks_name_ties_by_session_id() {
        let known = BTreeMap::from([
            ("s-b".to_owned(), session(Some("/one/app"))),
            ("s-a".to_owned(), session(Some("/two/app"))),
            ("s-c".to_owned(), session(Some("/zzz/alpha"))),
            ("beta-id".to_owned(), session(None)),
        ]);
        assert_eq!(focus_order(&known), ["s-c", "s-a", "s-b", "beta-id"]);
    }

    #[test]
    fn focus_label_falls_back_to_eight_clusters() {
        let known = BTreeMap::from([
            ("0123456789".to_owned(), session(None)),
            (
                "e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}xxxx".to_owned(),
                session(Some("")),
            ),
            ("s".to_owned(), session(Some("/work/alpha/"))),
        ]);
        assert_eq!(focus_label(&known, "0123456789"), "01234567");
        assert_eq!(
            focus_label(&known, "e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}xxxx"),
            "e\u{301}e\u{301}e\u{301}e\u{301}e\u{301}xxx"
        );
        assert_eq!(focus_label(&known, "s"), "alpha");
        assert_eq!(focus_label(&known, "unseen-session"), "unseen-s");
    }
}
