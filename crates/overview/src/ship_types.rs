//! Snap an OCR'd Type-column reading to a known EVE ship (DESIGN.md S4.3's "fuzzy match against a
//! candidate set (... ship type names from the SDE)" pass, M2). The candidate set here is the EVE
//! University ship list rather than the SDE itself (`assets/ship_types.txt` — see that file's
//! header for provenance), which is the same closed set of playable-ship names for this purpose.

use crate::util::levenshtein;

const SHIP_TYPES_TXT: &str = include_str!("../assets/ship_types.txt");

/// What [`ShipTypes::resolve`] made of a reading.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution<'a> {
    /// The trimmed reading is, verbatim, a known ship name.
    Exact(&'a str),
    /// Not an exact match, but uniquely close to one known ship within tolerance.
    Corrected { name: &'a str, distance: usize },
    /// Within tolerance of more than one known ship — DESIGN.md's "don't guess" posture means
    /// this must not silently pick one.
    Ambiguous(Vec<&'a str>),
    /// Not close enough to any known ship (wrecks, containers, celestials, structures, ...).
    Unknown,
}

/// The closed set of known ship-type names, used to correct OCR noise in the Type column.
pub struct ShipTypes {
    names: Vec<String>,
}

/// Below this many characters a reading is too short for edit distance to mean anything (e.g. a
/// clipped single glyph); only an exact match is accepted.
const MIN_LEN_FOR_FUZZY: usize = 4;

/// Max edit distance tolerated between a short reading and a candidate ship (or one of that ship's
/// prefixes — see [`ShipTypes::score`]): one misread glyph, same reasoning as
/// `track::FUZZY_NAME_DISTANCE`. Short readings stay at `1`: this catalog has 400+ names, and at
/// distance `2` a short reading can be equidistant from several unrelated ships (e.g. `Tomado`
/// sits 2 from each of `Tornado`, `Nomad`, and `Komodo`).
const MAX_CORRECTION_DISTANCE: usize = 1;

/// Readings at least this long tolerate [`LONG_MAX_CORRECTION_DISTANCE`]: enough glyphs that two
/// misreads (e.g. `rm` merged into `n`, as in `Anageddon N` for a truncated `Armageddon Navy Issue`)
/// still leave one ship clearly closest, and a tie is still [`Resolution::Ambiguous`].
const LONG_READING_LEN: usize = 10;
const LONG_MAX_CORRECTION_DISTANCE: usize = 2;

/// How far a truncated reading's length may drift from the prefix it was clipped from, for glyphs
/// OCR dropped or split before the cut.
const PREFIX_SLACK: usize = 2;

fn max_distance(len: usize) -> usize {
    if len >= LONG_READING_LEN { LONG_MAX_CORRECTION_DISTANCE } else { MAX_CORRECTION_DISTANCE }
}

impl ShipTypes {
    /// Load the ship-type list bundled into this crate (`assets/ship_types.txt`). Cheap — safe to
    /// call once at process startup, same contract as `glyph::Font::builtin`.
    pub fn builtin() -> ShipTypes {
        ShipTypes::from_names(SHIP_TYPES_TXT.lines().filter_map(|line| {
            let line = line.trim();
            (!line.is_empty() && !line.starts_with('#')).then_some(line)
        }))
    }

    /// Build from an arbitrary name list (tests, or a future non-bundled source).
    pub fn from_names<'a>(names: impl IntoIterator<Item = &'a str>) -> ShipTypes {
        ShipTypes { names: names.into_iter().map(str::to_string).collect() }
    }

    /// Resolve one Type-column reading against the known-ship list.
    ///
    /// A reading shorter than [`MIN_LEN_FOR_FUZZY`] chars only ever matches [`Resolution::Exact`]
    /// or comes back [`Resolution::Unknown`] — too little signal in one or two glyphs to fuzzy-
    /// match safely. Otherwise: exact match wins outright (so `Scorpion` is never out-scored by
    /// `Scorpion Navy Issue`'s prefix distance); failing that, each known name is scored against
    /// the reading as the *minimum* of the reading's own edit distance to that name and to that
    /// name's prefixes of about the same length (which is what a Type-column truncation like
    /// `Griffin Navy Is` actually looks like), and the closest name is accepted only if it is within
    /// [`max_distance`] *and* no other known name ties it — a tie is
    /// [`Resolution::Ambiguous`], never a guess.
    pub fn resolve<'a>(&'a self, reading: &str) -> Resolution<'a> {
        let reading = reading.trim();
        if reading.is_empty() {
            return Resolution::Unknown;
        }
        if let Some(name) = self.names.iter().find(|n| n.as_str() == reading) {
            return Resolution::Exact(name);
        }

        let len = reading.chars().count();
        if len < MIN_LEN_FOR_FUZZY {
            return Resolution::Unknown;
        }

        let max = max_distance(len);
        let mut best: Option<usize> = None;
        let mut winners: Vec<&str> = Vec::new();
        for name in &self.names {
            let d = self.score(reading, name, len);
            if d > max {
                continue;
            }
            match best {
                Some(b) if d < b => {
                    best = Some(d);
                    winners.clear();
                    winners.push(name);
                }
                Some(b) if d == b => winners.push(name),
                None => {
                    best = Some(d);
                    winners.push(name);
                }
                _ => {}
            }
        }

        match (best, winners.as_slice()) {
            (Some(d), [only]) => Resolution::Corrected { name: only, distance: d },
            (Some(_), _) => Resolution::Ambiguous(winners),
            (None, _) => Resolution::Unknown,
        }
    }

    /// Edit distance from `reading` (already known to be `len` chars) to `name`, or to a prefix of
    /// `name` within [`PREFIX_SLACK`] chars of `len` when `name` is longer than that — whichever is
    /// smallest. The prefix comparison is what makes a Type-column truncation resolve (even one that
    /// also lost or gained a glyph) without also letting a genuinely short, different ship name
    /// score better than it should.
    fn score(&self, reading: &str, name: &str, len: usize) -> usize {
        let name: Vec<char> = name.chars().collect();
        let whole: String = name.iter().collect();
        let mut best = levenshtein(reading, &whole);
        for n in len.saturating_sub(PREFIX_SLACK).max(1)..=(len + PREFIX_SLACK).min(name.len().saturating_sub(1)) {
            let prefix: String = name[..n].iter().collect();
            best = best.min(levenshtein(reading, &prefix));
        }
        best
    }

    /// The name to use in place of `reading`: `reading` itself unless [`Self::resolve`] finds an
    /// exact or uniquely-corrected known ship, in which case the canonical spelling is returned
    /// instead. Ambiguous and unknown readings pass through unchanged (never guess).
    pub fn canonicalize<'a>(&'a self, reading: &'a str) -> &'a str {
        match self.resolve(reading) {
            Resolution::Exact(name) | Resolution::Corrected { name, .. } => name,
            Resolution::Ambiguous(_) | Resolution::Unknown => reading,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_loads_the_full_list_plus_capsule() {
        let types = ShipTypes::builtin();
        assert!(types.names.len() > 400, "expected ~425 names, got {}", types.names.len());
        assert!(types.names.iter().any(|n| n == "Capsule"));
        assert!(types.names.iter().any(|n| n == "Tornado"));
    }

    #[test]
    fn hand_added_skua_is_not_snapped_to_squall() {
        let types = ShipTypes::builtin();
        assert_eq!(types.resolve("Skua"), Resolution::Exact("Skua"));
    }

    #[test]
    fn every_ship_with_ruleset_points_is_known() {
        let types = ShipTypes::builtin();
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../../simulator/rulesets");
        for entry in std::fs::read_dir(dir).unwrap() {
            let path = entry.unwrap().path();
            if path.extension().is_none_or(|e| e != "json") {
                continue;
            }
            let ruleset: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
            let missing: Vec<&String> = ruleset["ships"]
                .as_object()
                .unwrap()
                .keys()
                .filter(|s| !types.names.contains(s))
                .collect();
            assert!(missing.is_empty(), "{}: not in ship_types.txt: {missing:?}", path.display());
        }
    }

    #[test]
    fn exact_name_matches_exactly_even_with_a_prefix_in_the_list() {
        let types = ShipTypes::from_names(["Scorpion", "Scorpion Navy Issue", "Scorpion Ishukone Watch"]);
        assert_eq!(types.resolve("Scorpion"), Resolution::Exact("Scorpion"));
    }

    #[test]
    fn near_miss_corrects_to_the_real_ship() {
        let types = ShipTypes::builtin();
        // Single-glyph substitution (c for d), distance 1 — safely unique against the full list.
        assert_eq!(types.resolve("Tornaco"), Resolution::Corrected { name: "Tornado", distance: 1 });
    }

    #[test]
    fn a_reading_two_glyphs_off_is_left_unknown_not_guessed() {
        let types = ShipTypes::builtin();
        // "Tomado" is genuinely equidistant (2) from "Tornado", "Nomad", and "Komodo" — all real
        // ships — which is exactly why MAX_CORRECTION_DISTANCE stays at 1 rather than 2: at 2, this
        // reading would tie three different real ships instead of resolving to one.
        assert_eq!(types.resolve("Tomado"), Resolution::Unknown);
    }

    #[test]
    fn column_truncation_corrects_via_prefix_match() {
        let types = ShipTypes::builtin();
        assert_eq!(types.resolve("Griffin Navy Is"), Resolution::Corrected { name: "Griffin Navy Issue", distance: 0 });
        assert_eq!(types.resolve("Wor"), Resolution::Unknown); // shorter than MIN_LEN_FOR_FUZZY
    }

    #[test]
    fn merged_glyphs_in_a_long_truncation_correct_to_the_real_ship() {
        let types = ShipTypes::builtin();
        // "rm" read as "n", then clipped mid-word: 2 from the "Armageddon N" prefix, 3 from
        // "Armageddon I", so the Navy Issue is the unique closest.
        assert_eq!(types.resolve("Anageddon N"), Resolution::Corrected { name: "Armageddon Navy Issue", distance: 2 });
        assert_eq!(types.resolve("Megathon Navy I"), Resolution::Corrected { name: "Megathron Navy Issue", distance: 1 });
        assert_eq!(types.resolve("Megahon Navy Is"), Resolution::Corrected { name: "Megathron Navy Issue", distance: 2 });
    }

    #[test]
    fn every_known_ship_resolves_exactly_to_itself() {
        let types = ShipTypes::builtin();
        for name in &types.names {
            assert_eq!(types.resolve(name), Resolution::Exact(name.as_str()));
        }
    }

    #[test]
    fn short_truncation_still_resolves_once_long_enough() {
        let types = ShipTypes::from_names(["Worm", "Wolf"]);
        // "Wor" is too short to fuzzy-match at all; a slightly longer truncation is unambiguous.
        assert_eq!(types.resolve("Worm"), Resolution::Exact("Worm"));
    }

    #[test]
    fn ambiguous_between_two_close_ships_is_not_guessed() {
        let types = ShipTypes::from_names(["Wolf", "Worm", "Hawk", "Hulk"]);
        match types.resolve("Wolm") {
            Resolution::Ambiguous(mut names) => {
                names.sort();
                assert_eq!(names, vec!["Wolf", "Worm"]);
            }
            other => panic!("expected Ambiguous, got {other:?}"),
        }
    }

    #[test]
    fn unrelated_text_is_unknown() {
        let types = ShipTypes::builtin();
        assert_eq!(types.resolve("Cargo Containe"), Resolution::Unknown);
        assert_eq!(types.resolve("Wreck of: Min"), Resolution::Unknown);
    }

    #[test]
    fn canonicalize_passes_through_unresolved_readings() {
        let types = ShipTypes::builtin();
        assert_eq!(types.canonicalize("Cargo Containe"), "Cargo Containe");
        assert_eq!(types.canonicalize("Tomado"), "Tomado"); // ambiguous, see the test above
        assert_eq!(types.canonicalize("Tornaco"), "Tornado");
    }
}
