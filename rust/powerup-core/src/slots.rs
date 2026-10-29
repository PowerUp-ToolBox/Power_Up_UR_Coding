//! The Controller slot (ADR 0013, DESIGN v2.7 B): which connected controller
//! the app listens to. Three slots each hold at most one device; this module
//! decides the Controller one. Input and Output follow the OS's own default
//! rules and stay in each OS app's audio adapter.

/// A controller that is connected right now, as the app sees it. Plain data,
/// so the slot rule is decided with no controller-framework types.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ConnectedController {
    /// Stable for the life of one connection; what a pin stores.
    pub id: String,
    /// The profile describing this kind of controller, e.g. `dualsense`.
    pub profile_id: String,
    /// What the settings picker shows.
    pub display_name: String,
}

/// The controller that fills the Controller slot, or `None` when it is
/// empty.
///
/// Automatic (`pinned_id == None`) takes the head of the list, the most
/// recent connection, so losing it hands the slot to the next most recent.
/// A pin takes the first entry whose id equals it exactly; while that
/// controller is away the slot stays empty rather than falling back to
/// Automatic (HK-016), and its return takes the slot back with no new
/// pinning.
///
/// The order is the caller's list, never a framework callback's arrival
/// order (HK-017): the parameter name says what the caller must pass, so a
/// differently ordered list cannot give a plausible wrong answer. An empty
/// string is a pin like any other and matches nothing; turning a blank
/// stored id into Automatic is the config decoder's job, before this rule
/// runs.
pub fn select_active_controller<'a>(
    most_recently_connected_first: &'a [ConnectedController],
    pinned_id: Option<&str>,
) -> Option<&'a ConnectedController> {
    match pinned_id {
        None => most_recently_connected_first.first(),
        Some(pinned) => most_recently_connected_first
            .iter()
            .find(|controller| controller.id == pinned),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pad(id: &str) -> ConnectedController {
        ConnectedController {
            id: id.to_owned(),
            profile_id: "dualsense".to_owned(),
            display_name: format!("Pad {id}"),
        }
    }

    #[test]
    fn an_absent_pin_never_falls_back_to_automatic() {
        let connected = [pad("couch"), pad("desk")];
        assert_eq!(
            select_active_controller(&connected, None),
            Some(&connected[0])
        );
        assert_eq!(select_active_controller(&connected, Some("gone")), None);
    }
}
