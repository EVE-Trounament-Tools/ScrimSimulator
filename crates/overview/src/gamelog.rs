//! Warp scramble and disruption attempts from EVE gamelogs, and matching their names to the
//! overview's pilots. Ported from the simulator's `CombatLog` (`simulator/scripts/combat_log.gd`),
//! which reads the same logs: keep the two in step.

use chrono::NaiveDateTime;

/// Fuzzy name matches ([`similarity`]) below this don't count.
const MIN_SIMILARITY: f64 = 0.8;
/// Shortest name that may match another as a prefix (OCR truncation).
const MIN_PREFIX: usize = 3;

/// One `Warp scramble/disruption attempt from X to Y` line. An empty name is the listener.
#[derive(Clone, Debug, PartialEq)]
pub struct ScramLine {
    pub eve: NaiveDateTime,
    pub disruption: bool,
    pub source: String,
    pub source_ship: String,
    pub target: String,
    pub target_ship: String,
}

/// A gamelog's listener (from its header) and its scram lines.
#[derive(Debug, Default)]
pub struct Gamelog {
    pub listener: String,
    pub scrams: Vec<ScramLine>,
}

/// Parse a gamelog's `Listener:` and its `(combat)` warp scramble/disruption lines.
pub fn parse(text: &str) -> Gamelog {
    let mut log = Gamelog::default();
    for line in text.lines() {
        if let Some(name) = line.trim().strip_prefix("Listener:") {
            if log.listener.is_empty() {
                log.listener = name.trim().to_string();
            }
            continue;
        }
        let Some(rest) = line.strip_prefix("[ ") else { continue };
        let Some(eve) = rest.get(..19).and_then(|s| NaiveDateTime::parse_from_str(s, "%Y.%m.%d %H:%M:%S").ok()) else {
            continue;
        };
        let Some(msg) = rest.get(19..).and_then(|m| m.strip_prefix(" ] (combat) ")) else { continue };
        if let Some(s) = parse_scram(&strip_markup(msg), eve) {
            log.scrams.push(s);
        }
    }
    log
}

/// `Warp scramble attempt from X to Y` (markup stripped) -> its line.
fn parse_scram(text: &str, eve: NaiveDateTime) -> Option<ScramLine> {
    let (disruption, rest) = if let Some(r) = text.strip_prefix("Warp scramble attempt from ") {
        (false, r)
    } else {
        (true, text.strip_prefix("Warp disruption attempt from ")?)
    };
    let (from, to) = rest.split_once(" to ")?;
    let (source_ship, source) = ship_and_name(from);
    let (target_ship, target) = ship_and_name(to);
    Some(ScramLine { eve, disruption, source, source_ship, target, target_ship })
}

/// Text of a log message without its `<color>`/`<font>`/`<b>` markup, whitespace collapsed.
pub fn strip_markup(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => {
                in_tag = true;
                out.push(' ');
            }
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `"Hulk [ALPHA] [Kelto Ruvan] -"` -> `("Hulk", "Kelto Ruvan")`; `"you"` / `"you!"` ->
/// `("", "")`; a bare `"Venture"` (no pilot shown) -> `("Venture", "Venture")`.
pub fn ship_and_name(s: &str) -> (String, String) {
    let s = s.trim();
    if s == "you" || s == "you!" {
        return (String::new(), String::new());
    }
    let mut rest = s.trim_end().strip_suffix('-').unwrap_or(s).trim_end();
    let mut last_bracket: Option<&str> = None;
    while rest.ends_with(']') {
        let Some(open) = rest.rfind('[') else { break };
        if last_bracket.is_none() {
            last_bracket = Some(&rest[open + 1..rest.len() - 1]);
        }
        rest = rest[..open].trim_end();
    }
    let ship = rest.trim().to_string();
    match last_bracket {
        Some(name) => (ship, name.trim().to_string()),
        None => (ship.clone(), ship),
    }
}

/// Godot's `String.similarity`: Sørensen–Dice over character bigrams (each of `a`'s bigrams
/// counts once if `b` has it at all).
pub fn similarity(a: &str, b: &str) -> f64 {
    if a.is_empty() || b.is_empty() {
        return if a.is_empty() && b.is_empty() { 1.0 } else { 0.0 };
    }
    let bigrams = |s: &str| -> Vec<(char, char)> {
        let c: Vec<char> = s.chars().collect();
        c.windows(2).map(|w| (w[0], w[1])).collect()
    };
    let (x, y) = (bigrams(a), bigrams(b));
    let sum = (x.len() + y.len()) as f64;
    if sum == 0.0 {
        return 0.0;
    }
    let inter = x.iter().filter(|g| y.contains(g)).count() as f64;
    2.0 * inter / sum
}

/// The pilot in `pilots` (overview-OCR names) that is `name` (a real character name): an exact
/// case-insensitive match, else the only one that is a prefix of it or it of them (OCR cuts long
/// names short), else the most similar at [`MIN_SIMILARITY`] or above (the last of equals).
pub fn resolve_pilot(name: &str, pilots: &[&str]) -> Option<usize> {
    let lower = name.trim().to_lowercase();
    if lower.is_empty() {
        return None;
    }
    if let Some(i) = pilots.iter().position(|p| p.to_lowercase() == lower) {
        return Some(i);
    }
    let prefixed: Vec<usize> = (0..pilots.len())
        .filter(|&i| {
            let pl = pilots[i].to_lowercase();
            pl.chars().count().min(lower.chars().count()) >= MIN_PREFIX
                && (lower.starts_with(&pl) || pl.starts_with(&lower))
        })
        .collect();
    if prefixed.len() == 1 {
        return Some(prefixed[0]);
    }
    let mut best = None;
    let mut best_score = MIN_SIMILARITY;
    for (i, p) in pilots.iter().enumerate() {
        let score = similarity(&lower, &p.to_lowercase());
        if score >= best_score {
            best = Some(i);
            best_score = score;
        }
    }
    best
}

#[cfg(test)]
mod tests {
    use super::*;

    const LOG: &str = "------------------------------------------------------------\n  \
Gamelog\n  Listener: Ada Example\n  Session Started: 2026.01.02 03:04:05\n\
------------------------------------------------------------\n\
[ 2026.01.02 03:10:00 ] (combat) <color=0xffffffff><b>Warp scramble attempt</b> <color=0x77ffffff><font size=10>from</font> <color=0xffffffff><b>you!</b> <color=0x77ffffff><font size=10>to</font> <color=0xffffffff><b>Stabber [ABC] [Bo Sample]</b> -\n\
[ 2026.01.02 03:10:04 ] (combat) <color=0xffffffff><b>Warp disruption attempt</b> <color=0x77ffffff><font size=10>from</font> <color=0xffffffff><b>Arazu [XYZ] [Cy Other]</b> - <color=0x77ffffff><font size=10>to</font> <color=0xffffffff><b>you!</b>\n\
[ 2026.01.02 03:10:05 ] (combat) <color=0xffcc0000><b>312</b> <color=0x77ffffff><font size=10>from</font> <color=0xffffffff><b>Bo Sample[ABC](Stabber)</b> - Hits\n\
[ 2026.01.02 03:10:06 ] (notify) Warp scramble attempt from nobody to nowhere\n";

    #[test]
    fn reads_listener_and_scram_lines_only() {
        let log = parse(LOG);
        assert_eq!(log.listener, "Ada Example");
        assert_eq!(log.scrams.len(), 2, "{:?}", log.scrams);
        let a = &log.scrams[0];
        assert!(!a.disruption);
        assert_eq!((a.source.as_str(), a.target.as_str(), a.target_ship.as_str()), ("", "Bo Sample", "Stabber"));
        let b = &log.scrams[1];
        assert!(b.disruption);
        assert_eq!((b.source.as_str(), b.source_ship.as_str(), b.target.as_str()), ("Cy Other", "Arazu", ""));
        assert_eq!(b.eve.format("%H:%M:%S").to_string(), "03:10:04");
    }

    #[test]
    fn ship_and_name_cases() {
        let pair = |s: &str| ship_and_name(s);
        assert_eq!(pair("Hulk [ALPHA] [Kelto Ruvan] -"), ("Hulk".into(), "Kelto Ruvan".into()));
        assert_eq!(pair("you!"), (String::new(), String::new()));
        assert_eq!(pair("Venture"), ("Venture".into(), "Venture".into()));
    }

    #[test]
    fn resolves_truncated_and_misread_names() {
        let pilots = ["Bo Sample", "Cy Oth", "Dee Longername"];
        assert_eq!(resolve_pilot("bo sample", &pilots), Some(0));
        assert_eq!(resolve_pilot("Cy Other", &pilots), Some(1));
        assert_eq!(resolve_pilot("Dee Longernane", &pilots), Some(2));
        assert_eq!(resolve_pilot("Nobody", &pilots), None);
        assert!((similarity("night", "nacht") - 0.25).abs() < 1e-9);
    }
}
