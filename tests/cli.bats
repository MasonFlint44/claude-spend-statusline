#!/usr/bin/env bats
# Flag handling: anything but --calendar [YYYY] or no flag exits 2 with usage.
load helpers

@test "--holidays (the old flag) is rejected" { run at "$NOW" bash "$SL" --holidays 2027 </dev/null; assert_status 2; assert_has "usage:"; }
@test "--calendar with a bad year is rejected" { run at "$NOW" bash "$SL" --calendar 20x; assert_status 2; assert_has "usage:"; }
@test "--calendar with an extra argument is rejected" { run at "$NOW" bash "$SL" --calendar 2026 extra; assert_status 2; assert_has "usage:"; }
@test "a stray argument is rejected" { run at "$NOW" bash "$SL" render-me </dev/null; assert_status 2; assert_has "usage:"; }
@test "--calendar exits 0" { run at "$NOW" bash "$SL" --calendar 2026; assert_status 0; assert_has "workdays:"; }
@test "CLAUDE_SPEND_CALENDAR: off, none, no, 0, false (any case) all disable the file" {
    local v; for v in off none no 0 false OFF None; do
        run at "$NOW" env CLAUDE_SPEND_CALENDAR="$v" bash "$SL" --calendar 2026
        assert_status 0; assert_has "calendar: disabled (CLAUDE_SPEND_CALENDAR=$v)" "workdays: Mon Tue Wed Thu Fri"; assert_lacks "Labor Day"
    done
}
@test "CLAUDE_SPEND_CALENDAR: any other word is a path" {
    run at "$NOW" env CLAUDE_SPEND_CALENDAR=disabled bash "$SL" --calendar 2026; assert_has "calendar: no file at disabled"
}
@test "the bash version guard is the first command and uses nothing newer than bash 3" {
    # Everything before the guard must be bash-3 safe, or an old bash dies with
    # a syntax error before reaching it. Pin the guard's position and its text.
    local n; n=$(grep -n 'BASH_VERSINFO\[0\]}" -lt 4' "$SL" | head -1 | cut -d: -f1); [ "$n" -lt 60 ]
    ! head -n "$n" "$SL" | grep -Eq 'mapfile|\$\{[a-zA-Z_]+,,\}|%\(.*\)T|local -A|read -d|\[\[ '
    grep -q 'brew install bash (the statusline switches to it on its own)' "$SL"
    grep -qF 'exec "$b" "${BASH_SOURCE[0]:-$0}" "$@"' "$SL"   # an old bash hands off to Homebrew's
}
@test "--display takes at most one argument" {
    run at "$NOW" bash "$SL" --display a b; assert_status 2; assert_has "usage:"
    run at "$NOW" bash "$SL" --display off; assert_status 0; assert_has "everything shown"
}
