#!/usr/bin/env bats
# Other bash versions, through Docker's official bash images: the 4.4 floor
# is real (the script renders there, on Alpine's busybox awk), and older
# bashes get the one-line guard rather than a syntax error. Only with
# DOCKER=1 (CI sets it); the images are a few MB each.
load helpers
setup() { [ "${DOCKER:-}" = 1 ] || skip "set DOCKER=1 to run the bash-version checks in Docker"; command -v docker >/dev/null || skip "no docker"; }
# Pull once up front: a first pull's progress goes to stderr, which `run` would capture as output.
# Also lift bash 3.2's binary out of its image, to stand in for macOS's
# system bash inside the 4.4 image (whose own bash sits at /usr/local/bin/bash,
# Homebrew's Intel path).
setup_file() {
    [ "${DOCKER:-}" = 1 ] && command -v docker >/dev/null || return 0
    for v in 3.2 4.3 4.4; do docker pull -q "bash:$v" >/dev/null 2>&1; done
    local c; c=$(docker create bash:3.2) && docker cp "$c:/usr/local/bin/bash" "$BATS_FILE_TMPDIR/bash32" >/dev/null && docker rm "$c" >/dev/null
    true
}
in_bash() { local v="$1"; shift; run docker run --rm -v "$TESTS_DIR/../statusline:/s:ro" "bash:$v" bash -c "$*"; }

@test "bash 3.2: the guard is the first and only line, exit 1, on --doctor and on a render" {
    in_bash 3.2 'bash /s/spend-statusline.sh --doctor'; assert_status 1
    assert_equal "$output" "spend-statusline: bash 3.2.57(1)-release is too old, 4.4+ needed."
    in_bash 3.2 'echo "{}" | bash /s/spend-statusline.sh'; assert_status 1; assert_lacks "syntax error" "bad substitution"
}
@test "bash 3.2 on Darwin: the guard names brew" {
    in_bash 3.2 'mkdir -p /f; printf "#!/bin/sh\necho Darwin\n" > /f/uname; chmod +x /f/uname; PATH=/f:$PATH bash /s/spend-statusline.sh --doctor'
    assert_status 1; assert_has "Run: brew install bash (the statusline switches to it on its own)."
}
@test "bash 3.2 with a 4.4+ bash at a Homebrew path: the run switches to it, stdin and arguments intact" {
    run docker run --rm -v "$TESTS_DIR/../statusline:/s:ro" -v "$BATS_FILE_TMPDIR/bash32:/x/bash32:ro" bash:4.4 sh -c '
        apk add -q jq curl >/dev/null 2>&1; mkdir -p /c/cache/statusline; printf "hide repo\n" > /c/display.conf
        printf "%s %s 3.25 120 400 1111100 7\n" "$(date +%F)" "$(date +%s)" > /c/cache/statusline/spend-usage
        /x/bash32 -c "echo \$BASH_VERSION"
        echo "{\"model\":{\"display_name\":\"Opus\"},\"context_window\":{\"used_percentage\":42.6}}" \
          | CLAUDE_CONFIG_DIR=/c COLUMNS=120 CLAUDE_SPEND_DISPLAY=/c/display.conf /x/bash32 /s/spend-statusline.sh | sed "s/\x1b\[[0-9;]*m//g"; echo
        /x/bash32 /s/spend-statusline.sh --calendar 2026 | head -4'
    assert_status 0; assert_has "3.2.57(1)-release" "Opus | ctx:" '$120/$400' "2026-01-01 Thu New Year's Day"; assert_lacks "too old"
}
@test "bash 4.3 is also too old" { in_bash 4.3 'bash /s/spend-statusline.sh --doctor'; assert_status 1; assert_has "4.3.48(1)-release is too old"; }
@test "bash 4.4: the guard passes, the doctor reaches the tools line and names apk" {
    in_bash 4.4 'bash /s/spend-statusline.sh --doctor'; assert_status 1; assert_has "tools:        missing: jq curl. Install: sudo apk add jq curl"
}
@test "bash 4.4 with jq: a full render and a calendar listing" {
    in_bash 4.4 'apk add -q jq curl >/dev/null 2>&1; mkdir -p /c/cache/statusline; printf "hide repo\n" > /c/display.conf
        printf "%s %s 3.25 120 400 1111100 7\n" "$(date +%F)" "$(date +%s)" > /c/cache/statusline/spend-usage
        echo "{\"model\":{\"display_name\":\"Opus\"},\"effort\":{\"level\":\"high\"},\"context_window\":{\"used_percentage\":42.6},\"cost\":{\"total_cost_usd\":1.5}}" \
          | CLAUDE_CONFIG_DIR=/c COLUMNS=120 CLAUDE_SPEND_DISPLAY=/c/display.conf bash /s/spend-statusline.sh | sed "s/\x1b\[[0-9;]*m//g"; echo
        bash /s/spend-statusline.sh --calendar 2026 | head -4'
    assert_status 0; assert_has "Opus · high | ctx:" " 43% " "month:" '$120/$400' "workdays: Mon Tue Wed Thu Fri" "2026-01-01 Thu New Year's Day"
}
