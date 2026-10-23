//! Checks GitHub for a release newer than this build. Release builds have their version baked in
//! by `scripts/build.sh` (`SCRIM_VERSION`); other builds don't check. Every failure (offline,
//! rate limited, unexpected reply) is silent: the check just never reports anything.

use eframe::egui;
use std::sync::mpsc::{channel, Receiver};
use std::time::Duration;

const LATEST_URL: &str = "https://api.github.com/repos/AckbadP/ScrimSimulator/releases/latest";
const TIMEOUT: Duration = Duration::from_secs(5);

/// This build's version (`git describe` of the release), if it was built by `scripts/build.sh`.
pub const LOCAL_VERSION: Option<&str> = option_env!("SCRIM_VERSION");

/// A release newer than this build.
pub struct Release {
    pub tag: String,
    pub url: String,
}

/// The leading `vX.Y.Z` of a tag or `git describe` string (`v2.4.0-3-gabc-dirty` is 2.4.0).
pub fn parse_version(s: &str) -> Option<[u64; 3]> {
    let s = s.trim();
    let s = s.strip_prefix('v').unwrap_or(s);
    let mut parts = s.splitn(3, '.');
    let major = parts.next()?.parse().ok()?;
    let minor = parts.next()?.parse().ok()?;
    let rest = parts.next()?;
    let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap_or(rest.len());
    let patch = rest[..end].parse().ok()?;
    Some([major, minor, patch])
}

/// Whether `remote` is a later version than `local`; false if either can't be parsed.
pub fn is_newer(remote: &str, local: &str) -> bool {
    matches!((parse_version(remote), parse_version(local)), (Some(r), Some(l)) if r > l)
}

/// Starts the check in the background (if this build knows its version). The receiver gets the
/// newer release, if there is one; otherwise its sender is just dropped.
pub fn spawn_check(ctx: egui::Context) -> Option<Receiver<Release>> {
    let local = LOCAL_VERSION?;
    let (tx, rx) = channel();
    std::thread::spawn(move || {
        if let Some(release) = latest().filter(|r| is_newer(&r.tag, local)) {
            let _ = tx.send(release);
            ctx.request_repaint();
        }
    });
    Some(rx)
}

fn latest() -> Option<Release> {
    let agent: ureq::Agent = ureq::Agent::config_builder().timeout_global(Some(TIMEOUT)).build().into();
    let body = agent
        .get(LATEST_URL)
        .header("User-Agent", "scrimSimulator (EVE scrim replay tool)")
        .header("Accept", "application/vnd.github+json")
        .call()
        .ok()?
        .body_mut()
        .read_to_string()
        .ok()?;
    let json: serde_json::Value = serde_json::from_str(&body).ok()?;
    Some(Release { tag: json["tag_name"].as_str()?.to_owned(), url: json["html_url"].as_str()?.to_owned() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tags_and_describe_output() {
        assert_eq!(parse_version("v2.4.0"), Some([2, 4, 0]));
        assert_eq!(parse_version("2.10.3"), Some([2, 10, 3]));
        assert_eq!(parse_version("v2.4.0-3-gabc1234-dirty"), Some([2, 4, 0]));
        assert_eq!(parse_version("abc1234"), None);
        assert_eq!(parse_version("v2.4"), None);
        assert_eq!(parse_version(""), None);
    }

    #[test]
    fn newer_compares_numerically() {
        assert!(is_newer("v2.5.0", "v2.4.0"));
        assert!(is_newer("v2.10.0", "v2.9.9"));
        assert!(is_newer("v3.0.0", "v2.4.0-3-gabc1234"));
        assert!(!is_newer("v2.4.0", "v2.4.0"));
        assert!(!is_newer("v2.4.0", "v2.4.0-3-gabc1234-dirty"));
        assert!(!is_newer("v2.3.9", "v2.4.0"));
        assert!(!is_newer("v2.5.0", "abc1234"));
        assert!(!is_newer("nightly", "v2.4.0"));
    }
}
