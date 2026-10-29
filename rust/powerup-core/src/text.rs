//! Text rules exactly as Swift's `String` and Foundation apply them, so the
//! core cuts, trims and flattens text where the Swift app did (HK-063).
//!
//! Swift counts and cuts `Character`s, which are extended grapheme clusters:
//! counting bytes (`len`) or scalars (`chars().count()`) would cut CJK and
//! emoji text elsewhere and could split a cluster. The cluster rules come
//! from `unicode-segmentation`, pinned to the Unicode version whose rules
//! Swift applies on current macOS (see Cargo.toml).

use unicode_segmentation::UnicodeSegmentation;

/// Swift's `trimmingCharacters(in: .whitespacesAndNewlines)`. Foundation's
/// set is `char::is_whitespace` (Z* plus U+0009 to U+000D and U+0085) plus
/// U+200B ZERO WIDTH SPACE, which Unicode dropped from Zs long ago and
/// Foundation still trims (every scalar compared on macOS 27.2): U+00A0,
/// U+2028 and U+200B are trimmed, U+180E and U+FEFF are not. Trimming works
/// on scalars, not clusters.
pub fn trim(text: &str) -> &str {
    text.trim_matches(|scalar: char| scalar.is_whitespace() || scalar == '\u{200B}')
}

/// Swift's `String.count`: the number of extended grapheme clusters.
pub fn grapheme_count(text: &str) -> usize {
    text.graphemes(true).count()
}

/// Swift's `prefix(n)`: the first `n` clusters, or the whole text.
pub fn grapheme_prefix(text: &str, n: usize) -> &str {
    match text.grapheme_indices(true).nth(n) {
        Some((end, _)) => &text[..end],
        None => text,
    }
}

/// Swift's `String.contains(_:)` on two Strings: whether `needle`'s
/// clusters appear as consecutive clusters of `haystack`. A match never
/// starts or ends inside a cluster, so a combining mark (or a ZWJ, or a
/// spacing mark) after the needle's last character hides it, as it did for
/// the Swift classifier (measured with Swift 5.9.2). An empty needle is
/// found anywhere.
///
/// Swift compares the clusters by canonical equivalence; this compares
/// their text. The two agree whenever the needle is ASCII apart from `;`
/// and `` ` ``, whose canonical singletons (U+037E, U+1FEF) are not ASCII.
pub fn contains_clusters(haystack: &str, needle: &str) -> bool {
    let wanted: Vec<&str> = needle.graphemes(true).collect();
    if wanted.is_empty() {
        return true;
    }
    let clusters: Vec<&str> = haystack.graphemes(true).collect();
    clusters
        .windows(wanted.len())
        .any(|window| window == wanted.as_slice())
}

/// Tool and status text as one short line (HK-062, HK-063): CR, LF and tab
/// become spaces, the text is split on clusters equal to `" "` with the
/// empty pieces dropped and joined with one space, and above `max` clusters
/// it keeps `max - 1` (at least one) and appends `…`.
///
/// Swift flattens with Foundation's `replacingOccurrences`, whose search
/// never matches a CR, LF or tab that a combining scalar follows
/// (Grapheme_Cluster_Break=Extend, measured on macOS 27.2): such a break is
/// kept, and the line keeps it too. A space followed by a combining mark is
/// one cluster that is not `" "`, so it never separates.
pub fn condense(text: &str, max: usize) -> String {
    let flattened = flatten_breaks(text);
    let clusters: Vec<&str> = flattened.graphemes(true).collect();
    let collapsed = clusters
        .split(|cluster| *cluster == " ")
        .filter(|piece| !piece.is_empty())
        .map(|piece| piece.concat())
        .collect::<Vec<_>>()
        .join(" ");
    if grapheme_count(&collapsed) <= max {
        return collapsed;
    }
    let mut cut = grapheme_prefix(&collapsed, max.saturating_sub(1).max(1)).to_owned();
    cut.push('…');
    cut
}

/// CR, LF and tab become spaces unless a cluster-extending scalar follows
/// (see `condense`). The three replacements Swift makes one after another
/// give the same text as one pass, because a space never extends a cluster.
fn flatten_breaks(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut scalars = text.chars().peekable();
    while let Some(scalar) = scalars.next() {
        let is_break = matches!(scalar, '\r' | '\n' | '\t');
        if is_break && !scalars.peek().is_some_and(|next| extends_a_cluster(*next)) {
            out.push(' ');
        } else {
            out.push(scalar);
        }
    }
    out
}

/// Whether `scalar` has Grapheme_Cluster_Break=Extend. The segmentation
/// crate keeps its property tables private, so this asks its rules instead:
/// GB11 joins an emoji, any number of Extend scalars, a ZWJ and another
/// emoji into one cluster, and nothing else (not a SpacingMark, not a ZWJ)
/// may stand in the Extend position.
fn extends_a_cluster(scalar: char) -> bool {
    let mut probe = String::with_capacity(16);
    probe.push('\u{1F600}');
    probe.push(scalar);
    probe.push('\u{200D}');
    probe.push('\u{1F600}');
    grapheme_count(&probe) == 1
}

/// `NSString.lastPathComponent`: trailing slashes are dropped unless the
/// whole path is `/`, then the text after the last `/`. `""` stays `""`.
pub fn last_path_component(path: &str) -> &str {
    let trimmed = path.trim_end_matches('/');
    if trimmed.is_empty() {
        return if path.is_empty() { "" } else { "/" };
    }
    match trimmed.rfind('/') {
        Some(slash) => &trimmed[slash + 1..],
        None => trimmed,
    }
}

/// `Character.uppercased()` on the first cluster, the rest untouched
/// (`"sonnet"` becomes `"Sonnet"`; `"ß"` becomes `"SS"`).
pub fn capitalize_first(text: &str) -> String {
    let mut clusters = text.graphemes(true);
    match clusters.next() {
        Some(first) => first.to_uppercase() + clusters.as_str(),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trim_matches_swifts_whitespace_set() {
        assert_eq!(trim("\u{00A0} x \u{2028}\u{85}"), "x");
        assert_eq!(trim("\u{200B}x\u{200B}"), "x");
        assert_eq!(trim("\u{200B} \u{200B}"), "");
        assert_eq!(trim("a\u{200B}b"), "a\u{200B}b");
        assert_eq!(trim("\u{180E}x"), "\u{180E}x");
        assert_eq!(trim("\u{FEFF}x"), "\u{FEFF}x");
        assert_eq!(trim("\u{2060}x"), "\u{2060}x");
        assert_eq!(trim(" \u{301}x"), "\u{301}x");
    }

    #[test]
    fn contains_clusters_never_matches_part_of_a_cluster() {
        assert!(contains_clusters("x rm -rf y", "rm -rf"));
        assert!(contains_clusters("a\u{301}rm -rf", "rm -rf"));
        assert!(!contains_clusters("rm -rf\u{301}", "rm -rf"));
        assert!(!contains_clusters("rm -rf\u{200D}", "rm -rf"));
        assert!(!contains_clusters("rm -rf\u{903}", "rm -rf"));
        assert!(!contains_clusters("\u{600}rm -rf", "rm -rf"));
        assert!(!contains_clusters("rm -r \u{308}x", "rm -r "));
        assert!(!contains_clusters("rm", "rm -rf"));
        assert!(contains_clusters("", ""));
    }

    #[test]
    fn condense_keeps_a_cluster_whole_at_the_cut() {
        let text = format!("{}👍🏽zzzz", "a".repeat(78));
        assert_eq!(condense(&text, 80), format!("{}👍🏽…", "a".repeat(78)));
        assert_eq!(condense(&"a".repeat(80), 80), "a".repeat(80));
        assert_eq!(condense("abc", 1), "a…");
        assert_eq!(condense("abc", 0), "a…");
    }

    #[test]
    fn a_space_with_a_combining_mark_is_not_a_separator() {
        assert_eq!(condense("a \u{301}b", 80), "a \u{301}b");
        assert_eq!(condense("  a \t\n b  ", 80), "a b");
    }

    #[test]
    fn a_break_that_a_combining_scalar_follows_is_kept() {
        assert_eq!(condense("a\n\u{301}b", 80), "a\n\u{301}b");
        assert_eq!(condense("a\r\n\u{301}b", 80), "a \n\u{301}b");
        // Measured: Extend scalars keep the break, others do not.
        for kept in [
            '\u{301}',
            '\u{20DD}',
            '\u{FE0F}',
            '\u{1F3FD}',
            '\u{200C}',
            '\u{E0020}',
            '\u{FF9E}',
        ] {
            assert!(extends_a_cluster(kept), "{kept:?}");
        }
        for replaced in [
            '\u{903}',
            '\u{200D}',
            '\u{E33}',
            '\u{1160}',
            '\u{600}',
            '\u{AD}',
            'b',
            '\u{1F1E6}',
        ] {
            assert!(!extends_a_cluster(replaced), "{replaced:?}");
        }
    }

    #[test]
    fn last_path_component_like_nsstring() {
        assert_eq!(last_path_component("/tmp/"), "tmp");
        assert_eq!(last_path_component("/"), "/");
        assert_eq!(last_path_component("///"), "/");
        assert_eq!(last_path_component("a///"), "a");
        assert_eq!(last_path_component("/work/app"), "app");
        assert_eq!(last_path_component("app"), "app");
        assert_eq!(last_path_component(""), "");
    }

    #[test]
    fn capitalize_first_uppercases_one_cluster() {
        assert_eq!(capitalize_first("sonnet"), "Sonnet");
        assert_eq!(capitalize_first("ßx"), "SSx");
        assert_eq!(capitalize_first("e\u{301}x"), "E\u{301}x");
        assert_eq!(capitalize_first(""), "");
    }
}
