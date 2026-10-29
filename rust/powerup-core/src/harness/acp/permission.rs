//! Which option answers an agent's permission request (HK-131).

use crate::text;

/// One option of a `session/request_permission`, as the agent listed it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PermissionOption {
    pub option_id: String,
    /// The option's kind (`allow_once`, `reject_always`, …); `""` when the
    /// agent sent none.
    pub kind: String,
}

/// The option that answers the request when the user approves (`allow`) or
/// denies it: among the options whose kind contains `allow` (or `reject`),
/// the first whose kind contains `once`, else the first. So a controller
/// press never silently grants or denies "always". `None` means no option
/// matches, and the request is answered cancelled.
///
/// The kinds are matched as Swift's `String.contains` matched them, whole
/// clusters and case-sensitively ([`text::contains_clusters`]), so
/// `disallow` counts as an allow kind, as it did in Swift, and `allow`
/// followed by a combining mark does not.
pub fn permission_choice(options: &[PermissionOption], allow: bool) -> Option<&str> {
    let direction = if allow { "allow" } else { "reject" };
    let matching: Vec<&PermissionOption> = options
        .iter()
        .filter(|option| text::contains_clusters(&option.kind, direction))
        .collect();
    matching
        .iter()
        .find(|option| text::contains_clusters(&option.kind, "once"))
        .or(matching.first())
        .map(|option| option.option_id.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn options(list: &[(&str, &str)]) -> Vec<PermissionOption> {
        list.iter()
            .map(|(id, kind)| PermissionOption {
                option_id: (*id).to_owned(),
                kind: (*kind).to_owned(),
            })
            .collect()
    }

    #[test]
    fn a_press_never_picks_always_when_once_exists() {
        let four = options(&[
            ("aa", "allow_always"),
            ("ao", "allow_once"),
            ("ra", "reject_always"),
            ("ro", "reject_once"),
        ]);
        assert_eq!(permission_choice(&four, true), Some("ao"));
        assert_eq!(permission_choice(&four, false), Some("ro"));
        let always = options(&[("aa", "allow_always")]);
        assert_eq!(permission_choice(&always, true), Some("aa"));
        assert_eq!(permission_choice(&always, false), None);
        assert_eq!(permission_choice(&[], true), None);
    }
}
