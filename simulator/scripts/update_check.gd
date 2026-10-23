class_name UpdateCheck
extends RefCounted
## Checks GitHub for a release newer than this build. Release bundles carry their version in
## version.txt next to the executable (written by scripts/build.sh); without it (editor runs, the
## web build) there's no check. Every failure is silent: `check` just returns {}.

const LATEST_URL := "https://api.github.com/repos/AckbadP/ScrimSimulator/releases/latest"
const TIMEOUT := 5.0


## This build's version (`git describe` of the release), or "" if unknown.
static func local_version() -> String:
	if OS.has_feature("web") or OS.has_feature("editor"):
		return ""
	var path := OS.get_executable_path().get_base_dir().path_join("version.txt")
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path).strip_edges()


## The leading vX.Y.Z of a tag or `git describe` string (v2.4.0-3-gabc-dirty is [2, 4, 0]), or
## [] if there is none.
static func parse_version(s: String) -> Array:
	var re := RegEx.create_from_string("^v?(\\d+)\\.(\\d+)\\.(\\d+)")
	var m := re.search(s.strip_edges())
	if m == null:
		return []
	return [int(m.get_string(1)), int(m.get_string(2)), int(m.get_string(3))]


## Whether `remote` is a later version than `local`; false if either can't be parsed.
static func is_newer(remote: String, local: String) -> bool:
	var r := parse_version(remote)
	var l := parse_version(local)
	if r.is_empty() or l.is_empty():
		return false
	for i in 3:
		if r[i] != l[i]:
			return r[i] > l[i]
	return false


## { tag, url, local } of the latest release if it's newer than this build, else {}.
static func check(parent: Node) -> Dictionary:
	var local := local_version()
	if local == "":
		return {}
	var r := await Http.fetch(parent, LATEST_URL, ["Accept: application/vnd.github+json"], "",
		Callable(), TIMEOUT)
	if not r.ok:
		return {}
	var json = JSON.parse_string(r.body.get_string_from_utf8())
	if not json is Dictionary or not json.get("tag_name") is String or not json.get("html_url") is String:
		return {}
	if not is_newer(json.tag_name, local):
		return {}
	return {"tag": json.tag_name, "url": json.html_url, "local": local}
