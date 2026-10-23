extends "res://tests/test_case.gd"
## UpdateCheck: version parsing and comparison; the GitHub request isn't covered.


func test_parse_version() -> void:
	assert_eq(UpdateCheck.parse_version("v2.4.0"), [2, 4, 0])
	assert_eq(UpdateCheck.parse_version("2.10.3"), [2, 10, 3])
	assert_eq(UpdateCheck.parse_version("v2.4.0-3-gabc1234-dirty\n"), [2, 4, 0])
	assert_eq(UpdateCheck.parse_version("abc1234"), [])
	assert_eq(UpdateCheck.parse_version("v2.4"), [])
	assert_eq(UpdateCheck.parse_version(""), [])


func test_is_newer() -> void:
	assert_true(UpdateCheck.is_newer("v2.5.0", "v2.4.0"))
	assert_true(UpdateCheck.is_newer("v2.10.0", "v2.9.9"))
	assert_true(UpdateCheck.is_newer("v3.0.0", "v2.4.0-3-gabc1234"))
	assert_false(UpdateCheck.is_newer("v2.4.0", "v2.4.0"))
	assert_false(UpdateCheck.is_newer("v2.4.0", "v2.4.0-3-gabc1234-dirty"))
	assert_false(UpdateCheck.is_newer("v2.3.9", "v2.4.0"))
	assert_false(UpdateCheck.is_newer("v2.5.0", "abc1234"))
	assert_false(UpdateCheck.is_newer("nightly", "v2.4.0"))
