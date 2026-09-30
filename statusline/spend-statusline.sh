#!/usr/bin/env bash
# Claude Code statusline with daily + monthly spend bars, read from the
# same usage endpoint the /usage page renders (real billed dollars; the monthly
# limit comes from the org). Plus model, effort, context, session cost, git.
#
# Ships as: this file + config/calendar.conf + config/display.conf (see
# README.md for install and prerequisites). `spend-statusline.sh --calendar
# [YEAR]` prints the calendar; `--display` lists the elements and which show.
#
#   day: today's spend vs today's allowance, where the allowance divides the
#        month's REMAINING budget (as of this morning) evenly over the
#        remaining workdays of the month, today included:
#            allowance = (limit - (monthly - daily)) / workdays_left
#        workdays = the days of the week you work, minus holidays, both
#        from config/calendar.conf (evaluated at refresh time, cached);
#        one-off closures or PTO go there too as "once" lines.
#        Subtracting daily from monthly freezes the
#        allowance at its start-of-day value -- otherwise today's own spend
#        would shrink its own denominator. On a non-workday the label
#        reads "off:" and workdays_left counts the workdays after today
#        (floored at 1), so that spend draws against the next workday's slice.
#   month: monthly spend vs the monthly limit. Past the limit the bar pegs,
#        the percent keeps counting, and a coral "+$N" shows the overage
#        (e.g. a month where the limit got raised on request). A light tick
#        in the bar marks how far through the month's workdays today is: fill
#        short of the tick is under pace, fill past it is over.
#   ctx:  context use and the session's cost, then the prompt cache: "cache
#        42m" while the conversation's cached prefix is warm (gold in its last
#        five minutes), "cache cold ↻38k" once it has expired, with the tokens
#        the next request re-caches.
#
# The monthly limit is CLAUDE_SPEND_MONTHLY_LIMIT if set (your own target,
# even when the org sets a higher one), else the limit in the usage response.
# With neither, the spend bars stay hidden.
#
# Wire-up (~/.claude/settings.json), written literally so the shell running
# it resolves the path on each machine or container that shares the file:
#   "statusLine": { "type": "command", "command": "bash \"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/spend-statusline.sh\"" }

# printf and awk must parse "42.5" regardless of the user's locale, and the
# --calendar listing prints English day and month names whatever the locale
# (its own notes and headers are English). LC_ALL would override both, so
# keep only its character set and pin the numeric and time categories.
if [ -n "${LC_ALL:-}" ]; then export LC_CTYPE="$LC_ALL"; unset LC_ALL; fi
export LC_NUMERIC=C LC_TIME=C
VERSION=2.8.0   # kept equal to .claude-plugin/plugin.json's version (the tests check)
# Bash 4.4+ (mapfile -d, ${var,,}, printf %()T). This guard is the first
# thing that runs and uses only bash 3 syntax. An old bash (macOS ships 3.2)
# hands the run to Homebrew's bash when one is installed, stdin and arguments
# intact, so the statusLine command can say plain `bash` on every machine that
# shares the settings file; with none, it gets one clear line instead of a
# syntax error further down. Every code path, the render included, passes here.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
    for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        # shellcheck disable=SC2016  # expanded by the candidate bash, not this one
        [ -x "$b" ] && "$b" -c '[ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }' 2>/dev/null \
            && exec "$b" "${BASH_SOURCE[0]:-$0}" "$@"
    done
    case "$(uname -s 2>/dev/null)" in
        Darwin) echo "spend-statusline: bash $BASH_VERSION is too old, 4.4+ needed. Run: brew install bash (the statusline switches to it on its own)." >&2 ;;
        *) echo "spend-statusline: bash $BASH_VERSION is too old, 4.4+ needed." >&2 ;;
    esac
    exit 1
fi
SCRIPT_DIR=$(readlink -f "${BASH_SOURCE[0]:-$0}"); SCRIPT_DIR="${SCRIPT_DIR%/*}"
# The spend clock: CLAUDE_SPEND_TZ if set (any TZ name), else local time.
SPEND_TZ="${CLAUDE_SPEND_TZ:-}"
# bstamp FMT VAR: the current time on the spend clock, formatted by the
# printf builtin (no process; POSIX strftime conversions only), into VAR.
bstamp() { if [ -n "$SPEND_TZ" ]; then TZ="$SPEND_TZ" printf -v "$2" "%($1)T" -1; else printf -v "$2" "%($1)T" -1; fi; }
days_in_month() {  # YYYY MM -> DIM
    local y=$((10#$1)) m=$((10#$2))
    case $m in
        2) if (( (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 )); then DIM=29; else DIM=28; fi ;;
        4|6|9|11) DIM=30 ;; *) DIM=31 ;;
    esac
}
# The calendar: CLAUDE_SPEND_CALENDAR if set (a path, or off), else config/calendar.conf.
CALENDAR="${CLAUDE_SPEND_CALENDAR:-$SCRIPT_DIR/config/calendar.conf}"
case "${CALENDAR,,}" in off|none|no|0|false) CALENDAR="" ;; esac   # no file: workdays mon-fri, no holidays
# Which elements show: CLAUDE_SPEND_DISPLAY if set (a path, or off), else config/display.conf.
DISPLAY_SRC="CLAUDE_SPEND_DISPLAY=${CLAUDE_SPEND_DISPLAY:-}"
DISPLAY_FILE="${CLAUDE_SPEND_DISPLAY:-$SCRIPT_DIR/config/display.conf}"

# --- Calendar (config/calendar.conf) ---
# Which days of the week you work and which dates are holidays, so the daily
# allowance is spread over the days you actually work. One entry per line,
# "#" starts a comment, names run to the end of the line:
#   workdays DAYS           the days you work: a wrapping range (mon-fri,
#                           sun-thu), a list (mon,tue,wed,thu), a mix
#                           (mon-wed,fri) or "all". Default mon-fri. Last wins.
#   observe MODE [DOW=MODE ...]
#                           how a yearly holiday that falls on a non-workday
#                           is observed. MODE: nearest = the nearest workday,
#                           ties go forward (the default; US federal on a
#                           mon-fri week); next / prev = always that way;
#                           none = no substitute day. DOW=MODE overrides the
#                           mode for one day (Japan: "observe next sat=none").
#                           The substitute skips days that are already yearly
#                           holidays (so Christmas and Boxing Day chain), not once days.
#                           Applies file-wide wherever the line sits.
#   fixed MM-DD      name   a yearly holiday on a fixed date
#   nth   N DOW MM   name   Nth weekday of a month (DOW = mon..sun, N = 1..5;
#                           a fifth that the month lacks is skipped)
#   last  DOW MM     name   last weekday of a month
#   once  YYYY-MM-DD[..YYYY-MM-DD] name
#                           a one-off date or inclusive range (PTO, closures).
#                           Literal: never shifted. One that lands on a day
#                           you don't work anyway simply has no effect.
# Yearly rules (fixed/nth/last) follow the observe policy; once lines don't.
# Keywords, day names and modes are case-insensitive. Lines that don't parse
# are skipped (reported by --calendar).

# All of the calendar arithmetic is bash integer math: no date(1) calls, so a
# refresh costs no processes for the calendar however many rules it has.
dow_num() {  # mon..sun -> DN = 1..7 (matches date +%u); empty if unknown
    case "${1,,}" in mon) DN=1 ;; tue) DN=2 ;; wed) DN=3 ;; thu) DN=4 ;; fri) DN=5 ;; sat) DN=6 ;; sun) DN=7 ;; *) DN="" ;; esac
}
dow_abbr() {  # 1..7 -> DA = Mon..Sun
    case "$1" in 1) DA=Mon ;; 2) DA=Tue ;; 3) DA=Wed ;; 4) DA=Thu ;; 5) DA=Fri ;; 6) DA=Sat ;; 7) DA=Sun ;; *) DA="" ;; esac
}
set_char() { local v="${!1}"; printf -v "$1" '%s%s%s' "${v:0:$(($2 - 1))}" "$3" "${v:$2}"; }   # VAR POS CH: replace char POS (1-based)
is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
is_pos() { is_num "$1" && case "$1" in *[1-9]*) return 0 ;; esac; return 1; }   # a decimal > 0
is_num() { case "$1" in ''|*[!0-9.]*|*.*.*|.) return 1 ;; *) return 0 ;; esac; }
is_mask() { case "$1" in [01][01][01][01][01][01][01]) return 0 ;; *) return 1 ;; esac; }
is_workday() { [ "${1:$(($2 - 1)):1}" = 1 ]; }   # $1 = mask, $2 = day-of-week 1..7
# day_ordinal Y M D -> ORD, days since 1970-01-01 (proleptic Gregorian), and
# DOW 1..7 (Mon..Sun) of that date. Howard Hinnant's days_from_civil.
day_ordinal() {
    local y=$1 m=$2 d=$3 era yoe doy doe
    [ "$m" -le 2 ] && y=$((y - 1))
    era=$(( (y >= 0 ? y : y - 399) / 400 ))
    yoe=$(( y - era * 400 ))
    doy=$(( (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1 ))
    doe=$(( yoe * 365 + yoe / 4 - yoe / 100 + doy ))
    ORD=$(( era * 146097 + doe - 719468 ))
    DOW=$(( ((ORD % 7 + 7) % 7 + 3) % 7 + 1 ))   # 1970-01-01 was a Thursday
}
add_day() {  # Y M D +1|-1 -> Y M D (globals), the neighbouring date
    Y=$1; M=$2; D=$(( $3 + $4 ))
    if [ "$D" -lt 1 ]; then
        M=$((M - 1)); [ "$M" -lt 1 ] && { M=12; Y=$((Y - 1)); }
        days_in_month "$Y" "$M"; D=$DIM
    else
        days_in_month "$Y" "$M"
        [ "$D" -gt "$DIM" ] && { D=1; M=$((M + 1)); [ "$M" -gt 12 ] && { M=1; Y=$((Y + 1)); }; }
    fi
}
# valid_date Y M D: M 1..12 and D within the month (all already integers).
valid_date() { [ "$2" -ge 1 ] && [ "$2" -le 12 ] && days_in_month "$1" "$2" && [ "$3" -ge 1 ] && [ "$3" -le "$DIM" ]; }

# The calendar file, read once into CAL_LINES with comments, CR and BOM
# stripped; index = line number - 1. Empty when there is no file.
CAL_LINES=()
cal_load() {
    local i line
    CAL_LINES=()
    [ -n "$1" ] && [ -r "$1" ] || return 0
    mapfile -t CAL_LINES < "$1"
    for i in "${!CAL_LINES[@]}"; do
        line="${CAL_LINES[i]}"; line="${line%$'\r'}"; line="${line#$'\xef\xbb\xbf'}"
        CAL_LINES[i]="${line%%#*}"
    done
}

# The file's settings: wd_mask (7 chars indexed by date +%u, 1 = workday),
# obs_mode (nearest|next|prev|none) and obs_day (7 chars: ~ nearest, > next,
# < prev, x none, - inherit obs_mode). Defaults first, then the file's lines,
# last one wins. Bad tokens are reported on stderr when $1 is non-empty.
read_calendar_settings() {  # $1 = report bad lines
    local warn="$1" line kind rest tok toks lineno mask a b i d mode
    wd_mask=1111100; obs_mode=nearest; obs_day=-------
    lineno=0
    for line in "${CAL_LINES[@]}"; do
        lineno=$((lineno + 1))
        read -r kind rest <<< "$line"
        case "${kind,,}" in
            workdays)
                mask=0000000
                IFS=', ' read -ra toks <<< "$rest"
                for tok in "${toks[@]}"; do
                    case "$tok" in
                        [Aa][Ll][Ll]) mask=1111111 ;;
                        *-*) dow_num "${tok%%-*}"; a=$DN; dow_num "${tok#*-}"; b=$DN
                             if [ -n "$a" ] && [ -n "$b" ]; then
                                 i=$a
                                 while :; do set_char mask "$i" 1; [ "$i" = "$b" ] && break; i=$((i % 7 + 1)); done
                             else [ -n "$warn" ] && echo "calendar: line $lineno: unknown day range '$tok'" >&2; fi ;;
                        *)   dow_num "$tok"; a=$DN
                             if [ -n "$a" ]; then set_char mask "$a" 1
                             else [ -n "$warn" ] && echo "calendar: line $lineno: unknown day '$tok'" >&2; fi ;;
                    esac
                done
                if [ "$mask" = 0000000 ]; then [ -n "$warn" ] && echo "calendar: line $lineno: no workdays named, line ignored" >&2
                else wd_mask=$mask; fi ;;
            observe)
                read -ra toks <<< "$rest"
                for tok in "${toks[@]}"; do
                    tok="${tok,,}"
                    case "$tok" in
                        nearest|next|prev|none) obs_mode=$tok ;;
                        *=nearest|*=next|*=prev|*=none)
                            dow_num "${tok%%=*}"; d=$DN
                            case "${tok#*=}" in nearest) mode='~' ;; next) mode='>' ;; prev) mode='<' ;; none) mode=x ;; esac
                            if [ -n "$d" ]; then set_char obs_day "$d" "$mode"
                            else [ -n "$warn" ] && echo "calendar: line $lineno: unknown day in '$tok'" >&2; fi ;;
                        *) [ -n "$warn" ] && echo "calendar: line $lineno: unknown observe option '$tok'" >&2 ;;
                    esac
                done ;;
        esac
    done
    if [ -n "$warn" ]; then
        for d in 1 2 3 4 5 6 7; do
            [ "${obs_day:$((d - 1)):1}" != - ] && is_workday "$wd_mask" "$d" \
                && { dow_abbr "$d"; echo "calendar: observe ${DA,,}=... has no effect: $DA is a workday" >&2; }
        done
    fi
    return 0
}

# Evaluate every entry of the loaded calendar for each year given: prints
# "YYYY-MM-DD<TAB>rule year<TAB>dow<TAB>name<TAB>note", where dow is the
# printed date's weekday 1..7 and note is empty, "observed from DOW MM-DD"
# for a shifted yearly rule, or "not a workday, no effect" (the one field
# that can be empty comes last, since read collapses empty tab fields).
# Entries on workdays
# are placed first across ALL the years, then the yearly rules that fell on
# non-workdays are shifted in date order onto workdays not already taken, so
# chaining works across New Year's (a Saturday Jan 1 shifted back onto a
# Dec 31 the file also lists moves on to Dec 30; a Sunday Dec 31 shifted
# forward past Jan 1 lands on Jan 2). Callers pass the neighbouring years.
holidays_for_years() {
    local y line kind f1 f2 f3 rest name d dow n mm dd day lineno skipwhy
    local used=$'\n' taken=$'\n' i warn warnyear s e sy sm sd ey em ed mode odow fwd back k
    local -A def_entry=(); local def_dates=() j
    warnyear="${2:-$1}"   # report bad lines for the year of interest (the middle one), once
    read_calendar_settings "${CALENDAR_VERBOSE:-}"
    for y in "$@"; do
        lineno=0
        warn=""; [ "$y" = "$warnyear" ] && warn="${CALENDAR_VERBOSE:-}"
        for line in "${CAL_LINES[@]}"; do
            lineno=$((lineno + 1))
            read -r kind f1 f2 f3 rest <<< "$line"
            [ -n "$kind" ] || continue
            d=""; dow=""; name=""; skipwhy=""
            case "${kind,,}" in
                workdays|observe) continue ;;   # settings: read_calendar_settings
                fixed)
                    name="$f2 $f3 $rest"
                    case "$f1" in
                        [0-9][0-9]-[0-9][0-9]|[0-9]-[0-9][0-9]|[0-9][0-9]-[0-9]|[0-9]-[0-9])
                            mm=$((10#${f1%-*})); dd=$((10#${f1#*-}))
                            if valid_date "$y" "$mm" "$dd"; then
                                day_ordinal "$y" "$mm" "$dd"; dow=$DOW; printf -v d '%s-%02d-%02d' "$y" "$mm" "$dd"
                            else skipwhy="no such date in $y"; fi ;;
                    esac ;;
                nth)
                    name="$rest"; n="$f1"; dow_num "$f2"; dow=$DN; mm="$f3"
                    if is_int "$n" && [ "$n" -ge 1 ] && [ -n "$dow" ] && is_int "$mm" && valid_date "$y" "$((10#$mm))" 1; then
                        mm=$((10#$mm)); n=$((10#$n))
                        day_ordinal "$y" "$mm" 1
                        day=$(( 1 + (dow - DOW + 7) % 7 + 7 * (n - 1) ))
                        if [ "$day" -le "$DIM" ]; then printf -v d '%s-%02d-%02d' "$y" "$mm" "$day"
                        else skipwhy="no such weekday in $y"; fi
                    fi ;;
                last)
                    name="$f3 $rest"; dow_num "$f1"; dow=$DN; mm="$f2"
                    if [ -n "$dow" ] && is_int "$mm" && valid_date "$y" "$((10#$mm))" 1; then
                        mm=$((10#$mm))
                        day_ordinal "$y" "$mm" "$DIM"
                        day=$(( DIM - (DOW - dow + 7) % 7 ))
                        printf -v d '%s-%02d-%02d' "$y" "$mm" "$day"
                    fi ;;
                once)
                    name="$f2 $f3 $rest"; name="${name//$'\t'/ }"
                    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
                    s="${f1%%..*}"; e="${f1#*..}"
                    sy=""; ey=""
                    case "$s" in [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9])
                        sy=$((10#${s:0:4})); sm=$((10#${s:5:2})); sd=$((10#${s:8:2})); valid_date "$sy" "$sm" "$sd" || sy="" ;; esac
                    case "$e" in [0-9][0-9][0-9][0-9]-[0-1][0-9]-[0-3][0-9])
                        ey=$((10#${e:0:4})); em=$((10#${e:5:2})); ed=$((10#${e:8:2})); valid_date "$ey" "$em" "$ed" || ey="" ;; esac
                    if [ -z "$sy" ] || [ -z "$ey" ]; then skipwhy="cannot parse"
                    else
                        day_ordinal "$sy" "$sm" "$sd"; s=$ORD; day_ordinal "$ey" "$em" "$ed"; e=$ORD
                        if [ "$e" -lt "$s" ]; then skipwhy="range ends before it starts"
                        elif [ $(( e - s )) -gt 366 ]; then skipwhy="range longer than a year"
                        elif [ "$y" -lt "$sy" ] || [ "$y" -gt "$ey" ]; then
                            continue   # another year entirely: fine, not ours
                        else
                            # Clamp to this year, then walk the days.
                            if [ "$sy" -lt "$y" ]; then sy=$y; sm=1; sd=1; fi
                            if [ "$ey" -gt "$y" ]; then ey=$y; em=12; ed=31; fi
                            day_ordinal "$sy" "$sm" "$sd"; s=$ORD; dow=$DOW; day_ordinal "$ey" "$em" "$ed"; e=$ORD
                            Y=$sy; M=$sm; D=$sd
                            for ((k = s; k <= e; k++)); do
                                printf -v d '%s-%02d-%02d' "$Y" "$M" "$D"
                                case "$used" in *$'\n'"$d"$'\n'*) ;; *)
                                    used="$used$d"$'\n'
                                    if is_workday "$wd_mask" "$dow"; then printf '%s\t%s\t%s\t%s\t\n' "$d" "$y" "$dow" "${name:-holiday}"
                                    else printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$y" "$dow" "${name:-holiday}" "not a workday, no effect"; fi ;;
                                esac
                                add_day "$Y" "$M" "$D" 1; dow=$((dow % 7 + 1))
                            done
                            continue
                        fi
                    fi ;;
            esac
            if [ -z "$d" ]; then
                [ -n "$warn" ] && echo "calendar: skipping line $lineno (${skipwhy:-cannot parse}): $line" >&2
                continue
            fi
            name="${name//$'\t'/ }"
            name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
            if ! is_workday "$wd_mask" "$dow"; then
                # Non-workday: decided in pass 2, once every year's workday
                # holidays are known. First listing of a date wins.
                if [ -z "${def_entry[$d]+x}" ]; then
                    def_entry[$d]="$dow"$'\t'"$y"$'\t'"${name:-holiday}"
                    # Keep def_dates in date order (insertion; the list is short).
                    j=${#def_dates[@]}
                    while [ "$j" -gt 0 ] && [[ "${def_dates[j-1]}" > "$d" ]]; do def_dates[j]="${def_dates[j-1]}"; j=$((j - 1)); done
                    def_dates[j]="$d"
                fi
                continue
            fi
            case "$used" in *$'\n'"$d"$'\n'*) continue ;; esac   # same date listed twice
            used="$used$d"$'\n'; taken="$taken$d"$'\n'
            printf '%s\t%s\t%s\t%s\t\n' "$d" "$y" "$dow" "${name:-holiday}"
        done
    done
    # Pass 2: observe the yearly rules that fell on non-workdays, earliest
    # first, per the observe policy for that day. The substitute skips other
    # yearly holidays (so Christmas and Boxing Day chain) but not once
    # dates: a holiday observed on a day you already took off is still
    # observed there. No free workday within two weeks = no substitute.
    for d in "${def_dates[@]}"; do
        IFS=$'\t' read -r dow y name <<< "${def_entry[$d]}"
        mode="${obs_day:$((dow - 1)):1}"
        case "$mode" in '~') mode=nearest ;; '>') mode=next ;; '<') mode=prev ;; x) mode=none ;; -) mode=$obs_mode ;; esac
        if [ "$mode" = none ]; then printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$y" "$dow" "$name" "not a workday, no effect"; continue; fi
        if [ "$mode" = nearest ]; then
            # Distance to the nearest workday each way; ties go forward.
            k=$dow; fwd=0;  while [ "$fwd" -lt 7 ];  do k=$((k % 7 + 1)); fwd=$((fwd + 1));   is_workday "$wd_mask" "$k" && break; done
            k=$dow; back=0; while [ "$back" -lt 7 ]; do k=$(((k + 5) % 7 + 1)); back=$((back + 1)); is_workday "$wd_mask" "$k" && break; done
            mode=next; [ "$back" -lt "$fwd" ] && mode=prev
        fi
        s=1; [ "$mode" = prev ] && s=-1
        odow="$dow"; k=""
        Y=$((10#${d:0:4})); M=$((10#${d:5:2})); D=$((10#${d:8:2}))
        for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
            add_day "$Y" "$M" "$D" "$s"
            if [ "$s" = 1 ]; then dow=$((dow % 7 + 1)); else dow=$(((dow + 5) % 7 + 1)); fi
            printf -v e '%s-%02d-%02d' "$Y" "$M" "$D"
            is_workday "$wd_mask" "$dow" && case "$taken" in *$'\n'"$e"$'\n'*) ;; *) k=$e; break ;; esac
        done
        if [ -z "$k" ]; then printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$y" "$odow" "$name" "not a workday, no free workday to observe it on"; continue; fi
        taken="$taken$k"$'\n'
        dow_abbr "$odow"
        printf '%s\t%s\t%s\t%s\t%s\n' "$k" "$y" "$dow" "$name" "observed from $DA ${d#*-}"
    done
}

# Days-of-month (space separated, ascending) that are holidays in $1-$2
# (YYYY MM), from the loaded calendar. Any failure -> empty (no holidays).
holidays_in_month() {
    local y=$((10#$1)) ym="$1-$2" d rest i out="" flags=()
    while IFS=$'\t' read -r d rest; do
        [ "${d:0:7}" = "$ym" ] && flags[10#${d:8:2}]=1
    done < <(holidays_for_years $((y - 1)) $y $((y + 1)) 2>/dev/null)
    for i in "${!flags[@]}"; do out="$out$i "; done
    printf '%s' "$out"
}

# Workdays from day-of-month $3 (a $4, 1..7) through day $5, given the workday
# mask $1 and the holiday days-of-month $2 -> WD.
count_workdays() {
    local n=0 w=$4 d hset=" $2 "
    for ((d = $3; d <= $5; d++)); do
        case "$hset" in *" $d "*) ;; *) [ "${1:$((w - 1)):1}" = 1 ] && n=$((n + 1)) ;; esac
        w=$((w % 7 + 1))
    done
    WD=$n
}

# --- Display (config/display.conf) ---
# Which elements render. "hide NAME ..." lines (names space or comma
# separated, case-insensitive, "#" starts a comment); hides accumulate, and
# hiding an element hides everything that hangs off it. No file: everything
# shows. Nothing else is configurable: the rows and their order are fixed.
# The names, in the order --display lists them, each with the element it
# needs and a description. display_info NAME -> D_NEEDS, D_WHAT (1 = unknown).
DISPLAY_NAMES=(model effort ctx cost cache day month pace age repo path branch pending upstream vs session)
display_info() {
    case "$1" in
        model)    D_NEEDS="";       D_WHAT="the model name (Opus)" ;;
        effort)   D_NEEDS=model;    D_WHAT="the effort level after the model (· high)" ;;
        ctx)      D_NEEDS="";       D_WHAT="the context bar and its percentage (ctx:█████░░ 43%)" ;;
        cost)     D_NEEDS=ctx;      D_WHAT="the session cost after the context bar (\$3.72)" ;;
        cache)    D_NEEDS=ctx;      D_WHAT="the prompt-cache cue (· cache 42m, · cache cold ↻38k)" ;;
        day)      D_NEEDS="";       D_WHAT="the day bar with its spend and allowance (day:███░░ 64% \$9.40/\$15)" ;;
        month)    D_NEEDS="";       D_WHAT="the month bar with its spend, limit and overage (month:██│█░ 36% \$143/\$400 +\$50)" ;;
        pace)     D_NEEDS=month;    D_WHAT="the pace tick in the month bar (│)" ;;
        age)      D_NEEDS="day or month"; D_WHAT="the stale-fetch tag after the spend bars (·12m)" ;;
        repo)     D_NEEDS="";       D_WHAT="the whole repository row" ;;
        path)     D_NEEDS=repo;     D_WHAT="the working directory (~/claude-spend-statusline)" ;;
        branch)   D_NEEDS=repo;     D_WHAT="the branch, with the repository name when the directory is named differently (⎇  feature/preview)" ;;
        pending)  D_NEEDS=branch;   D_WHAT="uncommitted lines (· pending +16)" ;;
        upstream) D_NEEDS=branch;   D_WHAT="commits ahead of and behind upstream (↑1↓2)" ;;
        vs)       D_NEEDS=branch;   D_WHAT="lines changed against the default branch (· vs main +30)" ;;
        session)  D_NEEDS=repo;     D_WHAT="lines Claude Code has edited this session (· session +118/-27)" ;;
        *)        D_NEEDS=""; D_WHAT=""; return 1 ;;
    esac
}
# read_display FILE: hidden[NAME] = "file" for a name the file hides, or
# "needs X" for one hidden because X is; display_bad = the lines that did not
# parse. An absent or unreadable file hides nothing.
declare -A hidden=(); display_bad=()
read_display() {
    local line kind rest tok toks lineno=0 n
    hidden=(); display_bad=()
    [ -n "$1" ] && [ -r "$1" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        lineno=$((lineno + 1))
        line="${line%$'\r'}"; line="${line#$'\xef\xbb\xbf'}"; line="${line%%#*}"
        read -r kind rest <<< "$line"
        [ -n "$kind" ] || continue
        case "${kind,,}" in
            hide)
                IFS=', ' read -ra toks <<< "$rest"
                n=0
                for tok in "${toks[@]}"; do
                    [ -n "$tok" ] || continue
                    tok="${tok,,}"; n=$((n + 1))
                    if display_info "$tok"; then hidden[$tok]="file"
                    else display_bad+=("line $lineno: unknown element '$tok'"); fi
                done
                [ "$n" -gt 0 ] || display_bad+=("line $lineno: hide names nothing") ;;
            *) display_bad+=("line $lineno: unknown keyword '$kind' (only hide)") ;;
        esac
    done < "$1"
    # Dependents follow their parents, parents before children.
    for n in effort cost cache pace path branch session pending upstream vs; do
        display_info "$n"
        [ -z "${hidden[$n]+x}" ] && [ -n "${hidden[$D_NEEDS]+x}" ] && hidden[$n]="needs $D_NEEDS"
    done
    [ -z "${hidden[age]+x}" ] && [ -n "${hidden[day]+x}" ] && [ -n "${hidden[month]+x}" ] && hidden[age]="needs day or month"
    return 0
}
shown() { [ -z "${hidden[$1]+x}" ]; }
# display_where -> WHERE: the display file in use, or why there is none.
display_where() {
    if [ -z "$DISPLAY_FILE" ]; then WHERE="off ($DISPLAY_SRC): everything shown"
    elif [ ! -r "$DISPLAY_FILE" ]; then WHERE="no file at $DISPLAY_FILE: everything shown"
    else WHERE="$DISPLAY_FILE"; fi
}

usage() {
    cat <<EOF
usage: spend-statusline.sh                  render the statusline from Claude Code's JSON on stdin
       spend-statusline.sh --calendar [YYYY]  list the calendar in use: work week, observed holidays,
                                            this month's workday counts (default: the current year)
       spend-statusline.sh --display [FILE]   list the elements: which show, which the display
                                            file hides (default: the file in use)
       spend-statusline.sh --doctor           explain the spend bars: credentials, one live fetch of
                                            the usage endpoint, the limit and the cache; exit 1 if
                                            the bars would be hidden
       spend-statusline.sh --help
Knobs (environment): CLAUDE_SPEND_MONTHLY_LIMIT CLAUDE_SPEND_TZ CLAUDE_SPEND_REFRESH
                     CLAUDE_SPEND_CALENDAR CLAUDE_SPEND_DISPLAY CLAUDE_CONFIG_DIR
spend-statusline $VERSION  https://github.com/MasonFlint44/claude-spend-statusline
EOF
}
case "${1:-}" in
    --calendar|--doctor|--display|'') ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if [ "${1:-}" = "--display" ]; then
    [ $# -le 2 ] || { usage >&2; exit 2; }
    [ $# -eq 2 ] && { DISPLAY_FILE="$2"; DISPLAY_SRC="--display $2"; }
fi
case "${DISPLAY_FILE,,}" in off|none|no|0|false) DISPLAY_FILE="" ;; esac   # no file: everything shown
read_display "$DISPLAY_FILE"
if [ "${1:-}" = "--display" ]; then
    display_where; echo "display: $WHERE"
    for n in "${DISPLAY_NAMES[@]}"; do
        display_info "$n"
        case "${hidden[$n]:-}" in '') state=on ;; file) state=off ;; *) state="off (${hidden[$n]})" ;; esac
        printf '%-9s %-25s%s\n' "$n" "$state" "$D_WHAT"
    done
    for line in "${display_bad[@]}"; do echo "display: skipping $line" >&2; done
    exit 0
fi
# Both spend bars hidden: nothing to fetch, so no token is read, no request
# made, no cache or lock written.
spend_wanted=1; shown day || shown month || spend_wanted=0
if [ "${1:-}" = "--calendar" ]; then
    case "${2:-}" in ''|[0-9][0-9][0-9][0-9]) [ $# -le 2 ] ;; *) false ;; esac || { usage >&2; exit 2; }
    bstamp '%Y %m %e %u %B' stamp
    # shellcheck disable=SC2154  # stamp is set by bstamp's printf -v
    read -r cy cm cdom cdow cmonth <<< "$stamp"
    y=$((10#${2:-$cy}))
    if [ -z "$CALENDAR" ]; then echo "calendar: disabled (CLAUDE_SPEND_CALENDAR=$CLAUDE_SPEND_CALENDAR): workdays mon-fri, no holidays"
    elif [ ! -r "$CALENDAR" ]; then echo "calendar: no file at $CALENDAR: workdays mon-fri, no holidays"
    else echo "calendar: $CALENDAR"
    fi
    cal_load "$CALENDAR"
    read_calendar_settings ""
    days=""; for d in 1 2 3 4 5 6 7; do is_workday "$wd_mask" "$d" && { dow_abbr "$d"; days="$days $DA"; }; done
    echo "workdays:${days}"
    obs="$obs_mode"
    for d in 1 2 3 4 5 6 7; do
        dow_abbr "$d"
        case "${obs_day:$((d - 1)):1}" in '~') obs="$obs $DA=nearest" ;; '>') obs="$obs $DA=next" ;; '<') obs="$obs $DA=prev" ;; x) obs="$obs $DA=none" ;; esac
    done
    echo "observe:  $obs"
    CALENDAR_VERBOSE=1 holidays_for_years $((y - 1)) $y $((y + 1)) | sort \
        | while IFS=$'\t' read -r d ry dow name note; do
              [ "$ry" = "$y" ] || continue
              dow_abbr "$dow"; printf '%s %s %s%s\n' "$d" "$DA" "$name" "${note:+ ($note)}"
          done
    if [ "$y" = "$cy" ]; then
        days_in_month "$y" "$cm"; day_ordinal "$y" "$((10#$cm))" 1
        hol=$(holidays_in_month "$y" "$cm")
        count_workdays "$wd_mask" "$hol" 1 "$DOW" "$DIM"; total=$WD
        count_workdays "$wd_mask" "$hol" "$cdom" "$cdow" "$DIM"
        printf '%s %s: %s workdays, %s remaining\n' "$cmonth" "$y" "$total" "$WD"
    fi
    exit 0
fi

# Claude Code's JSON, only when rendering (--doctor takes nothing from stdin).
input=""; f=()
if [ -z "${1:-}" ]; then
    IFS= read -r -d '' input   # all of stdin (the read stops at EOF)
    # Every field in one jq call, NUL-separated so names pass through byte for
    # byte. Garbage or non-object stdin makes jq fail: every field stays empty
    # and the line renders without them, quietly.
    mapfile -d '' -t f < <(printf '%s' "$input" | jq -j '[
        (.model.display_name // ""), (.effort.level // ""),
        ((.context_window.used_percentage // null) | if type == "number" then . else "" end),
        (.cost.total_cost_usd // ""), (.workspace.current_dir // .cwd // ""),
        (.cost.total_lines_added // 0), (.cost.total_lines_removed // 0),
        (.prompt_cache.caching_observed // false), (.prompt_cache.warm // false), (.prompt_cache.ttl // ""),
        ((.prompt_cache.expires_at // null) | if type == "number" then floor else "" end),
        ((.prompt_cache.recache_tokens_if_cold // null) | if type == "number" then floor else "" end)
        ] | map(tostring) | join("\u0000")' 2>/dev/null)
fi
model="${f[0]:-}"; effort="${f[1]:-}"; used_pct="${f[2]:-}"; session_cost="${f[3]:-}"
cur_dir="${f[4]:-}"; lines_added="${f[5]:-0}"; lines_removed="${f[6]:-0}"
pc_observed="${f[7]:-}"; pc_warm="${f[8]:-}"; pc_ttl="${f[9]:-}"; pc_exp="${f[10]:-}"; pc_recache="${f[11]:-}"

# ANSI color codes
CLR_DIM=$'\033[2m'
CLR_RESET=$'\033[0m'

# Shared heat ramp (24-bit truecolor): muted green -> Claude gold -> Claude coral,
# as channel arrays plus the percentage each stop is anchored at. Both the effort
# level and the progress bars draw from this, so their colors line up.
# Anchored on Claude Code's own tokens: gold #fab219 (warning) + coral #ff5858 (error).
#
# The 5/95 anchors (rather than 0/100) inset the endpoints just enough that full
# coral means ">=95%" instead of "exactly 100%" -- the alarm saturates while you can
# still act on it. Clamping outside the anchors is continuous in color and only puts
# a corner in the rate of change, so the small flat zones cost nothing in smoothness.
RAMP_R=(107 250 255)   # #6bb85f  #fab219  #ff5858
RAMP_G=(184 178  88)
RAMP_B=( 95  25  88)
RAMP_AT=(  5  50  95)

# Map a 0-100 percentage to a continuously interpolated ramp color. Single source
# of truth for the bars, so they all read on the same scale.
# Pure bash integer math (no subshell) since this runs on every render.
ramp_color() {   # PCT [VAR]: print the escape, or store it in VAR
    local p="${1:-0}"
    p="${p%%.*}"; [ -z "$p" ] && p=0
    (( p < 0 )) && p=0
    (( p > 100 )) && p=100

    local last=$(( ${#RAMP_AT[@]} - 1 ))
    local r g b
    if (( p <= RAMP_AT[0] )); then
        r=${RAMP_R[0]}; g=${RAMP_G[0]}; b=${RAMP_B[0]}
    elif (( p >= RAMP_AT[last] )); then
        r=${RAMP_R[last]}; g=${RAMP_G[last]}; b=${RAMP_B[last]}
    else
        # Find the segment containing p, then lerp each channel across it.
        local i=0
        while (( p > RAMP_AT[i+1] )); do i=$(( i + 1 )); done
        local span=$(( RAMP_AT[i+1] - RAMP_AT[i] ))
        local t=$(( p - RAMP_AT[i] ))
        r=$(( RAMP_R[i] + (RAMP_R[i+1] - RAMP_R[i]) * t / span ))
        g=$(( RAMP_G[i] + (RAMP_G[i+1] - RAMP_G[i]) * t / span ))
        b=$(( RAMP_B[i] + (RAMP_B[i+1] - RAMP_B[i]) * t / span ))
    fi
    # A real ESC byte, like the CLR_* constants: the final render prints the
    # line with printf '%s', so text from the input can't smuggle escapes in.
    if [ -n "${2:-}" ]; then printf -v "$2" $'\033[38;2;%d;%d;%dm' "$r" "$g" "$b"
    else printf $'\033[38;2;%d;%d;%dm' "$r" "$g" "$b"; fi
}

# Map an effort level to its ramp color by sampling the ramp at evenly spaced
# points, so the five levels stay visually distinct and stay in sync with the bars
# automatically if the stops above ever change. Unknown -> dim.
effort_color() {
    case "$1" in
        low)    ramp_color   0 ;;
        medium) ramp_color  25 ;;
        high)   ramp_color  50 ;;
        xhigh)  ramp_color  75 ;;
        max)    ramp_color 100 ;;
        *)      printf '%s' "$CLR_DIM" ;;
    esac
}

# Build an ASCII progress bar with the percentage shown after the bar: bar <pct> <width> [tick]
# e.g. bar 42 10 -> █████░░░░░ 42%  (width = number of block characters)
# Fill color: continuous green -> gold -> coral ramp, see ramp_color().
# Percentages over 100 peg the fill and keep counting in the label.
# An optional tick (a cell index, 0-based) replaces that block with a light
# line: bar 42 10 3 -> ███│█░░░░░ 42%. Over the fill it takes the default
# foreground, over the empty run it is dim, so it reads on either side.
# Round a non-negative decimal string half-up ("12.5" -> 13, "42.6" -> 43).
# printf '%.0f' would round halves to even, and awk's %d truncates.
round() {   # VALUE VAR
    # Anything but plain digits and a dot (an exponent form such as 1e-07,
    # a sign) goes through awk, which parses every numeric spelling.
    case "$1" in ''|*[!0-9.]*|*.*.*) printf -v "$2" '%s' "$(awk -v v="${1:-0}" 'BEGIN{printf "%d", int(v + 0.5)}')"; return ;; esac
    local i="${1%%.*}" frac=""
    [ "$i" != "$1" ] && frac="${1#*.}"
    case "$frac" in [5-9]*) printf -v "$2" '%d' $(( 10#${i:-0} + 1 )) ;; *) printf -v "$2" '%d' $(( 10#${i:-0} )) ;; esac
}
bar() {
    local pct="${1:-0}"
    local width="${2:-10}"

    # Anything but a plain non-negative decimal is normalised first (rare).
    case "$pct" in ''|*[!0-9.]*|*.*.*) pct=$(awk -v v="${pct:-0}" 'BEGIN{v+=0; if(v<0)v=0; printf "%.2f", v}') ;; esac
    local pct_int
    round "$pct" pct_int

    # Filled blocks = pct * width / 100, half-up, in integer hundredths.
    local ip="${pct%%.*}" fp="" p100 filled
    [ "$ip" != "$pct" ] && fp="${pct#*.}"
    fp="${fp}00"; fp="${fp:0:2}"
    p100=$(( 10#${ip:-0} * 100 + 10#$fp ))
    filled=$(( (p100 * width + 5000) / 10000 ))
    [ "$filled" -gt "$width" ] && filled=$width
    local empty=$(( width - filled ))

    # Pick color from the shared ramp (matches the effort levels).
    local color
    ramp_color "$pct_int" color

    # Colored filled blocks, then plain empty blocks, then space and percentage.
    # The strings are built from counts (no substring on the multibyte
    # blocks, which a C locale would slice mid-character).
    local tick="${3:-}" a b c
    if [ -n "$tick" ] && [ "$tick" -lt "$filled" ]; then
        rep '█' "$tick" a; rep '█' $(( filled - tick - 1 )) b; rep '░' "$empty" c
        [ -n "$b" ] && b="${color}${b}${CLR_RESET}"
        printf "${color}%s${CLR_RESET}%s%s%s %s%%" "$a" "$TICK" "$b" "$c" "$pct_int"
    elif [ -n "$tick" ]; then
        rep '█' "$filled" a; rep '░' $(( tick - filled )) b; rep '░' $(( width - tick - 1 )) c
        printf "${color}%s${CLR_RESET}%s${CLR_DIM}%s${CLR_RESET}%s %s%%" "$a" "$b" "$TICK" "$c" "$pct_int"
    else
        rep '█' "$filled" a; rep '░' "$empty" b
        printf "${color}%s${CLR_RESET}%s %s%%" "$a" "$b" "$pct_int"
    fi
}
rep() { local s="" i; for ((i = 0; i < $2; i++)); do s+="$1"; done; printf -v "$3" '%s' "$s"; }   # CH N VAR: CH repeated N times
TICK='│'   # the pace tick, a light vertical line (U+2502)

# Format dollar amounts compactly, one per line: <10 -> $1.23, <1000 -> $123,
# else $1.3k; an empty argument gives an empty line. One awk for all of them.
fmt_money() {
    awk 'BEGIN{ for (i = 1; i < ARGC; i++) { v = ARGV[i]
        if (v == "") { print ""; continue }
        v += 0
        if (v >= 1000) printf "$%.1fk\n", int(v / 100 + 0.5) / 10   # half-up, not printf'"'"'s half-even
        else if (v >= 10) printf "$%d\n", int(v + 0.5)
        else printf "$%.2f\n", int(v * 100 + 0.5) / 100 } }' "$@"
}

# --- Daily + monthly spend from the usage endpoint (cached, background) ---
# The same data /usage renders: GET api.anthropic.com/api/oauth/usage with the
# CLI's own OAuth token. .spend.used is the month-to-date dollars the page
# shows and .spend.limit is the org's monthly cap — real billed numbers, so no
# local token pricing to drift.
# The endpoint has no per-day figure, so today's spend is derived: the month
# total the first time each day is seen becomes that day's baseline
# (cache/statusline/spend-usage.daystart), and daily = month - baseline. Accurate from the first
# refresh of the day; a month rollover (month < baseline) resets the baseline.
#
# CLOCK: the day bar and the workday count run on the spend clock:
# CLAUDE_SPEND_TZ if set (any TZ name, e.g. UTC or America/New_York), else
# local time. The month figure is server-side and unaffected. The page has no
# per-day number to reconcile against, so "today" is the calendar day on that
# clock: on local time an 8 PM session counts as that day's spend against
# that day's allowance, not the next UTC day's. Only wrinkle: the page's
# month counter resets at 00:00 UTC on the last day, so if the spend clock
# lags UTC that evening's baseline re-pins via the month<baseline guard and
# the day bar shows only post-reset spend until midnight.
MONTHLY_LIMIT="${CLAUDE_SPEND_MONTHLY_LIMIT:-0}"   # your own monthly target; 0 = use the response's limit
is_num "$MONTHLY_LIMIT" || MONTHLY_LIMIT=0
# Cache lives INSIDE the config dir (not ~/.cache) so a devcontainer that mounts
# ~/.claude gets the credentials, the cache, and the day-start baseline together.
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CACHE_DIR="$CLAUDE_DIR/cache/statusline"
CACHE_FILE="$CACHE_DIR/spend-usage"
BASE_FILE="$CACHE_DIR/spend-usage.daystart"
LOCK_DIR="$CACHE_DIR/spend-usage.lock"
HOLD_FILE="$CACHE_DIR/spend-usage.hold"   # epoch before which no fetch is attempted (after a failure)
REFRESH_INTERVAL="${CLAUDE_SPEND_REFRESH:-60}"   # seconds between usage fetches
is_int "$REFRESH_INTERVAL" || REFRESH_INTERVAL=60
[ "$REFRESH_INTERVAL" -ge 10 ] || REFRESH_INTERVAL=10
[ "$spend_wanted" = 1 ] && { [ -d "$CACHE_DIR" ] || mkdir -p "$CACHE_DIR" 2>/dev/null; }

# The clock, from the printf builtin: epoch now, and on the spend clock
# today's date, day of month, day of week and year-month.
printf -v now '%(%s)T' -1
bstamp '%Y-%m-%d %e %u %Y-%m' stamp; read -r today dom dow ym <<< "$stamp"

# Fetch month-to-date spend and cache it as
# "<date> <fetched-epoch> <today-dollars> <month-dollars> <limit-dollars> <workday-mask> <holiday-days-of-month...>".
# Runs detached. Any failure keeps the stale cache and writes a hold so the
# next renders don't retry until the refresh interval has passed (5 minutes
# after an HTTP 429).
hold() { printf '%s\n' "$(( now + ${1:-$REFRESH_INTERVAL} ))" > "$HOLD_FILE" 2>/dev/null; }
# read_token: the CLI's OAuth token into TOK (empty on failure, with the
# reason in TOK_ERR) and its expiry (epoch ms) into TOK_EXP. Linux and
# Windows keep it in the credentials file. macOS keeps it in the Keychain,
# writing the file only when the Keychain is locked, so with no file there
# the Keychain is asked for the same JSON (the item Claude Code creates,
# "Claude Code-credentials"); the first read may prompt for access once.
read_token() {
    TOK=""; TOK_EXP=""; TOK_ERR=""; TOK_SRC="$CLAUDE_DIR/.credentials.json"
    local json=""
    if [ -r "$TOK_SRC" ]; then
        json=$(<"$TOK_SRC")
    elif [ -e "$TOK_SRC" ]; then TOK_ERR="$TOK_SRC is not readable"; return 1
    else
        case "$OSTYPE" in
            darwin*) if command -v security >/dev/null 2>&1; then
                         TOK_SRC="the macOS Keychain (Claude Code-credentials)"
                         json=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) \
                             || { TOK_ERR="no credentials file and no Keychain item: log in with claude"; return 1; }
                     else TOK_ERR="no credentials file at $TOK_SRC"; return 1; fi ;;
            *) TOK_ERR="no credentials file at $TOK_SRC: log in with claude (an API key gives no token)"; return 1 ;;
        esac
    fi
    # Token and expiry in one jq call (the token never contains whitespace).
    read -r TOK TOK_EXP <<< "$(printf '%s' "$json" | jq -r '[(.claudeAiOauth.accessToken // ""),
        ((.claudeAiOauth.expiresAt? // null) | if type == "number" then floor else "" end)] | join(" ")' 2>/dev/null)"
    [ -n "$TOK" ] || { TOK_ERR="no OAuth token in $TOK_SRC: log in with claude (an API key gives no token)"; return 1; }
    # Expired token (expiresAt is epoch milliseconds): the CLI refreshes the
    # credentials on its own; serve the stale cache until it does. A
    # missing or unreadable expiry is treated as "try".
    if [ -n "$TOK_EXP" ] && ! [ "$TOK_EXP" -gt "$(( now * 1000 ))" ] 2>/dev/null; then
        TOK_ERR="the OAuth token expired; the CLI refreshes it on its next request"; return 1
    fi
}
# fetch_usage: GET the usage endpoint with TOK. The body lands in RESP and
# the HTTP status in CODE; returns 1 when curl itself failed (CODE empty).
fetch_usage() {
    RESP=""; CODE=""
    # The token travels in a curl config piped from the printf builtin: never
    # in argv (ps), never in a temp file (a heredoc would be one on bash < 5.1).
    # The HTTP status rides as the last line of the output.
    RESP=$(printf '%s\n' 'url = "https://api.anthropic.com/api/oauth/usage"' \
                          "header = \"Authorization: Bearer $TOK\"" \
                          'header = "anthropic-beta: oauth-2025-04-20"' \
           | curl -s -m 5 -w '\n%{http_code}' -K -) || { RESP=""; return 1; }
    CODE="${RESP##*$'\n'}"; RESP="${RESP%$'\n'*}"
}
# parse_usage BODY: U_ENABLED (on/off/empty for no figure), U_MONTH and
# U_LIMIT in dollars. Amounts come in minor units with their exponent
# (12000 with exponent 2 = 120.00); the exponent defaults to 2 when absent.
# The limit is .spend.limit, else .spend.cap.credits. .spend.enabled false
# = the org has spend billing off and the amounts mean nothing.
parse_usage() {
    U_ENABLED=""; U_MONTH=""; U_LIMIT=""
    read -r U_ENABLED U_MONTH U_LIMIT <<< "$(printf '%s' "$1" | jq -r '
        def dollars: .amount_minor / pow(10; (.exponent // 2));
        if .spend.enabled? == false then "off"
        elif (.spend.used.amount_minor? // null) != null then
            (.spend.used | dollars) as $m
            | (if (.spend.limit.amount_minor? // null) != null then (.spend.limit | dollars)
               elif (.spend.cap.credits.amount_minor? // null) != null then (.spend.cap.credits | dollars)
               else 0 end) as $l
            | "on \($m) \($l)"
        else empty end' 2>/dev/null)"
}
refresh_usage() {
    read_token || { hold; return; }
    fetch_usage || { hold; return; }
    if [ "$CODE" = 429 ]; then hold 300; return; fi
    [ -n "$RESP" ] || { hold; return; }
    parse_usage "$RESP"
    # Spend billing off: drop any cache so the bars hide, like any other no-figure case.
    [ "$U_ENABLED" = off ] && rm -f "$CACHE_FILE" 2>/dev/null
    [ -n "$U_MONTH" ] || { hold; return; }
    store_usage "$U_MONTH" "$U_LIMIT"
}
# store_usage MONTH LIMIT: the day-start baseline and the cache line; clears the hold.
store_usage() {
    local month="$1" limit="$2"
    # Your own target wins over the org's; neither -> 0 -> bars hidden.
    is_pos "$MONTHLY_LIMIT" && limit="$MONTHLY_LIMIT"
    is_pos "$limit" || limit=0
    # Day-start baseline: first sighting of a spend-clock day pins the month total.
    local b_date b_month
    read -r b_date b_month < "$BASE_FILE" 2>/dev/null
    if [ "$b_date" != "$today" ] || ! is_num "${b_month:-}" || ! awk -v m="$month" -v b="$b_month" 'BEGIN{exit !(m >= b)}'; then
        b_month="$month"
        printf '%s %s\n' "$today" "$b_month" > "$BASE_FILE" 2>/dev/null
    fi
    local day
    day=$(awk -v m="$month" -v b="$b_month" 'BEGIN{d=m-b; if(d<0)d=0; printf "%.6g", d}')
    # This month's workday mask and holidays (days-of-month) from config/calendar.conf.
    local hol
    cal_load "$CALENDAR"; read_calendar_settings ""
    hol=$(holidays_in_month "${today:0:4}" "${today:5:2}")
    printf '%s %s %s %s %s %s %s\n' "$today" "$now" "$day" "$month" "$limit" "$wd_mask" "$hol" > "$CACHE_FILE.tmp" 2>/dev/null \
        && mv "$CACHE_FILE.tmp" "$CACHE_FILE" 2>/dev/null && { [ -e "$HOLD_FILE" ] && rm -f "$HOLD_FILE" 2>/dev/null; true; }
}

# --doctor: the same steps as a refresh, one at a time, each explained, and
# the verdict the next render would reach. Exit 1 when the bars stay hidden.
if [ "${1:-}" = "--doctor" ]; then
    [ $# -le 1 ] || { usage >&2; exit 2; }
    doc() { printf '%-14s%s\n' "$1" "$2"; }
    fail() { doc "$1" "$2"; doc "bars:" "hidden"; exit 1; }
    doc "version:" "spend-statusline $VERSION"
    # Tools first: without jq every later step would misreport its cause.
    # The hint names the command for this platform's package manager.
    install_hint() {   # PKGS... -> HINT
        case "$OSTYPE" in
            darwin*) HINT="brew install $*" ;;
            msys*|cygwin*) HINT="winget install $(for p in "$@"; do case $p in jq) printf 'jqlang.jq ' ;; *) printf '%s ' "$p" ;; esac; done)(in Git Bash, or PowerShell)" ;;
            *) if command -v apt-get >/dev/null 2>&1; then HINT="sudo apt install $*"
               elif command -v dnf >/dev/null 2>&1; then HINT="sudo dnf install $*"
               elif command -v pacman >/dev/null 2>&1; then HINT="sudo pacman -S $*"
               elif command -v zypper >/dev/null 2>&1; then HINT="sudo zypper install $*"
               elif command -v apk >/dev/null 2>&1; then HINT="sudo apk add $*"
               elif command -v brew >/dev/null 2>&1; then HINT="brew install $*"
               else HINT="install $* with your package manager"; fi ;;
        esac
    }
    missing=""; for t in jq curl awk readlink; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
    if [ -n "$missing" ]; then
        # shellcheck disable=SC2086  # the list is meant to split
        install_hint $missing
        fail "tools:" "missing:${missing}. Install: $HINT"
    fi
    # (bash itself is checked by the guard at the top of the script.)
    gitnote=""; command -v git >/dev/null 2>&1 || gitnote=", no git (the branch and diff line stays blank)"
    doc "tools:" "bash $BASH_VERSION, jq, curl, awk, readlink$gitnote"
    doc "config dir:" "$CLAUDE_DIR"
    bstamp '%Y %B' stamp; read -r cy cmonth <<< "$stamp"
    doc "spend clock:" "${SPEND_TZ:-local time}, today $today"
    cal_load "$CALENDAR"; read_calendar_settings ""
    if [ -z "$CALENDAR" ]; then doc "calendar:" "off (CLAUDE_SPEND_CALENDAR=$CLAUDE_SPEND_CALENDAR): workdays mon-fri, no holidays"
    elif [ ! -r "$CALENDAR" ]; then doc "calendar:" "no file at $CALENDAR: workdays mon-fri, no holidays"
    else
        warnings=$(CALENDAR_VERBOSE=1 holidays_for_years "$cy" 2>&1 >/dev/null | grep -c .)
        days=""; for d in 1 2 3 4 5 6 7; do is_workday "$wd_mask" "$d" && { dow_abbr "$d"; days="$days${days:+ }${DA,,}"; }; done
        n=$(holidays_for_years "$cy" | grep -c .)
        note=""; [ "$warnings" -gt 0 ] && note=", $warnings line(s) not parsed (see --calendar)"
        doc "calendar:" "$CALENDAR: workdays $days, $n holidays in $cy$note"
    fi
    days_in_month "$cy" "${today:5:2}"; hol=$(holidays_in_month "$cy" "${today:5:2}")
    count_workdays "$wd_mask" "$hol" "$dom" "$dow" "$DIM"
    doc "this month:" "$cmonth $cy, $WD workday(s) left including today"
    display_where
    if [ ${#hidden[@]} -eq 0 ]; then
        case "$WHERE" in *": everything shown") doc "display:" "${WHERE%: everything shown}: all elements shown" ;; *) doc "display:" "$WHERE: all elements shown" ;; esac
    else
        hid=""; for n in "${DISPLAY_NAMES[@]}"; do shown "$n" || hid="$hid${hid:+, }$n"; done
        note=""; [ ${#display_bad[@]} -gt 0 ] && note=", ${#display_bad[@]} line(s) not parsed (see --display)"
        doc "display:" "$DISPLAY_FILE: hidden $hid$note"
    fi
    if [ "$spend_wanted" = 0 ]; then doc "bars:" "hidden by $DISPLAY_FILE (day and month both hidden), so nothing is fetched"; exit 0; fi
    read_token || fail "credentials:" "$TOK_ERR"
    left=$(( TOK_EXP / 1000 - now ))
    doc "credentials:" "$TOK_SRC: OAuth token present${TOK_EXP:+, expires in $(( left / 3600 ))h $(( left % 3600 / 60 ))m}"
    fetch_usage || fail "usage fetch:" "curl failed (no network, or the endpoint timed out after 5 s)"
    case "$CODE" in
        200) ;;
        401|403) fail "usage fetch:" "HTTP $CODE: the token was rejected; run claude and log in again" ;;
        429) fail "usage fetch:" "HTTP 429: rate limited; the statusline waits 5 minutes after one of these" ;;
        *) fail "usage fetch:" "HTTP $CODE${RESP:+: ${RESP:0:200}}" ;;
    esac
    parse_usage "$RESP"
    case "$U_ENABLED" in
        off) fail "usage fetch:" "HTTP 200, but spend.enabled is false: the organization has spend billing off, so there is no dollar figure" ;;
        on) doc "usage fetch:" "HTTP 200: month to date \$$U_MONTH, limit \$$U_LIMIT" ;;
        *) fail "usage fetch:" "HTTP 200, but no spend figure in the response (the plan reports no dollars, or the endpoint changed): ${RESP:0:200}" ;;
    esac
    if is_pos "$MONTHLY_LIMIT"; then doc "limit:" "\$$MONTHLY_LIMIT from CLAUDE_SPEND_MONTHLY_LIMIT"
    elif is_pos "$U_LIMIT"; then doc "limit:" "\$$U_LIMIT from the response"
    else fail "limit:" "none: the response carries no limit and CLAUDE_SPEND_MONTHLY_LIMIT is unset; set one to see the bars"
    fi
    # store_usage fails when the cache dir is not writable; a leftover cache
    # line from an earlier run would otherwise read back as "refreshed just now".
    store_usage "$U_MONTH" "$U_LIMIT" || fail "cache:" "could not write $CACHE_FILE (is $CACHE_DIR writable?)"
    read -r c_date c_stamp c_day c_mo c_lim c_mask c_hol < "$CACHE_FILE" 2>/dev/null \
        || fail "cache:" "could not read back $CACHE_FILE"
    doc "cache:" "$CACHE_FILE: today \$$c_day, month \$$c_mo, limit \$$c_lim, refreshed just now"
    doc "bars:" "will show"
    exit 0
fi

# Read the cache. Its age comes from the stamp inside the line, not the file's
# mtime, so nothing here depends on stat(1).
day_cost=""; mo_cost=""; hol_doms=""; wd_mask=""; cache_age=""
if [ "$spend_wanted" = 1 ] && [ -f "$CACHE_FILE" ]; then
    read -r c_date c_stamp c_day c_mo c_lim c_mask c_hol < "$CACHE_FILE" 2>/dev/null
    # Yesterday's cache would misreport its daily total as today's: hide instead.
    # A garbled line (non-numeric fields, a malformed workday mask) is treated
    # as no cache, so the next render refreshes it.
    if [ "$c_date" = "$today" ] && is_num "$c_day" && is_num "$c_mo" && is_mask "$c_mask"; then
        is_int "$c_stamp" && cache_age=$(( now - c_stamp ))
        day_cost="$c_day"; mo_cost="$c_mo"; wd_mask="$c_mask"; hol_doms="$c_hol"
        is_pos "$c_lim" && MONTHLY_LIMIT="$c_lim"
    fi
fi

# Decide whether to trigger a background refresh: no usable cache, or one
# older than the interval (a future stamp = clock skew, also stale), and no
# hold from a recent failed fetch.
hold_until=""; { read -r hold_until < "$HOLD_FILE"; } 2>/dev/null; is_int "$hold_until" || hold_until=0
if [ "$spend_wanted" = 1 ] && { [ -z "$cache_age" ] || [ "$cache_age" -ge "$REFRESH_INTERVAL" ] || [ "$cache_age" -lt 0 ]; } \
   && [ "$now" -ge "$hold_until" ]; then
    # Clear a stale lock (crashed/killed refresher) so refreshes can't wedge
    # permanently. The lock's own stamp file dates it; rename-then-remove so
    # two renders can't both claim it.
    if [ -d "$LOCK_DIR" ]; then
        lock_stamp=""; { read -r lock_stamp < "$LOCK_DIR/stamp"; } 2>/dev/null; is_int "$lock_stamp" || lock_stamp=0
        [ $(( now - lock_stamp )) -gt 300 ] && mv "$LOCK_DIR" "$LOCK_DIR.stale.$$" 2>/dev/null && rm -rf "$LOCK_DIR.stale.$$" 2>/dev/null
    fi
    # mkdir is atomic: only one refresher runs at a time.
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$now" > "$LOCK_DIR/stamp" 2>/dev/null
        ( refresh_usage; rm -rf "$LOCK_DIR" 2>/dev/null ) >/dev/null 2>&1 &
        disown 2>/dev/null
    fi
fi

# --- Spend math ---
day_pct=""; mo_pct=""; day_allow=""; mo_over=0; day_label="day:"; pace_done=""; pace_total=0
# No known limit (response had none, no override): the bars stay hidden.
if [ -n "$day_cost" ] && is_pos "$MONTHLY_LIMIT"; then
    # Remaining WORKdays in the month, today included. The workday mask and
    # this month's holidays (days-of-month) arrive pre-derived in the cache
    # (see refresh_usage). On a non-workday today contributes nothing and the
    # count is the workdays still ahead (its spend draws on the next workday's
    # slice); floor at 1 so the last day of the month never divides by zero.
    days_in_month "${ym%-*}" "${ym#*-}"
    count_workdays "$wd_mask" "$hol_doms" "$dom" "$dow" "$DIM"; wd=$WD
    [ "$wd" -ge 1 ] 2>/dev/null || wd=1
    # The pace tick's position: workdays elapsed (today included) over the
    # month's workdays. A non-workday adds nothing, so a weekend sits where
    # Friday left it. Rendered as a cell of the month bar by pace_cell.
    day_ordinal "${ym%-*}" "$((10#${ym#*-}))" 1
    count_workdays "$wd_mask" "$hol_doms" 1 "$DOW" "$DIM"; pace_total=$WD
    count_workdays "$wd_mask" "$hol_doms" 1 "$DOW" "$dom"; pace_done=$WD
    # The cue that today's allowance is borrowed from the next workday.
    is_workday "$wd_mask" "$dow" || day_label="off:"
    case " $hol_doms " in *" $dom "*) day_label="off:" ;; esac
    read -r day_pct day_allow mo_pct mo_over <<< "$(awk \
        -v d="$day_cost" -v m="$mo_cost" -v lim="$MONTHLY_LIMIT" -v wd="$wd" 'BEGIN{
        rem = lim - (m - d)              # month budget left as of this morning
        allow = rem / wd                 # today fair share of what remains
        if (allow <= 0) { dp = (d > 0.005) ? 999 : 0; allow = 0 }
        else { dp = d * 100 / allow; if (dp > 999) dp = 999 }
        mp = m * 100 / lim; if (mp > 999) mp = 999
        over = m - lim; if (over < 0) over = 0
        printf "%d %.6g %d %.6g", int(dp + 0.5), allow, int(mp + 0.5), over   # half-up
    }')"
fi

# --- What the display file hides ---
# Blanking a piece here takes the same path as the piece being absent from
# the input or the cache: the row re-flows around it and its dependents go
# with it (read_display already marked those hidden).
shown model  || model=""
shown effort || effort=""
shown ctx    || used_pct=""
shown cost   || session_cost=""
shown cache  || pc_observed=""
shown day    || day_pct=""
shown month  || { mo_pct=""; mo_over=0; }
shown pace   || pace_total=0

# --- Responsive bar widths: bars fill the terminal width ---
# The statusline runs as a piped command (no controlling TTY), but Claude Code
# exports the terminal width as $COLUMNS. Fall back to tput, then to 80.
cols="${COLUMNS:-0}"
[ "$cols" -gt 0 ] 2>/dev/null || cols=$(tput cols 2>/dev/null || echo 80)

# COLUMNS is the raw terminal width, but the fullscreen TUI doesn't give the
# statusline all of it: the frame (border + padding) eats ~4 columns. Reserve
# those plus one spare so the right edge never truncates.
RESERVE=5
avail=$(( cols - RESERVE ))

# All bars render at ONE shared width so they read on the same visual scale:
# 16 blocks by default, stretched or squeezed together so the line fills the
# terminal. The floor is 10 blocks -- one block per 10%, the coarsest a bar
# still carries real information; rather than squeeze below it we wrap to two
# rows (and only a terminal too narrow even for that renders floor-width bars
# that overflow).
BAR_NOM=16; BAR_MIN=10

# Precompute the variable-length text pieces so we can measure the fixed
# "chrome" (everything that isn't bar blocks) exactly.
money=("" "" "" "" "" "")
[ -n "$session_cost$day_pct$mo_pct" ] && mapfile -t money < <(fmt_money "$session_cost" "$day_cost" "$day_allow" "$mo_cost" "$MONTHLY_LIMIT" "$mo_over")
session_money="${money[0]:-}"
ctx_i=""; [ -n "$used_pct" ] && round "$used_pct" ctx_i

have_ctx=0; have_day=0; have_mo=0
[ -n "$used_pct" ] && have_ctx=1
[ -n "$day_pct" ]  && have_day=1
[ -n "$mo_pct" ]   && have_mo=1
have_spend_figures=$(( have_day | have_mo ))

# Money annotations: spent/allotted beside each spend bar, plus a coral
# overage tag on the month once past the limit.
day_money=""; mo_money=""; over_str=""
if [ "$have_day" = 1 ]; then
    day_money="${money[1]}"
    # An exhausted month has no allowance to show a denominator for.
    is_pos "$day_allow" && day_money="$day_money/${money[2]}"
fi
if [ "$have_mo" = 1 ]; then
    mo_money="${money[3]}/${money[4]}"
    is_pos "$mo_over" && over_str="+${money[5]}"
fi
# Staleness cue: the figures are still today's, but no fetch has succeeded
# for a while (the token expired, the endpoint is down, no network). After
# STALE_AFTER seconds a dim age tag follows the bars: ·12m, ·3h.
STALE_AFTER=300
stale_str=""
if shown age && [ "$have_spend_figures" = 1 ] && is_int "$cache_age" && [ "$cache_age" -ge "$STALE_AFTER" ]; then
    if [ "$cache_age" -lt 3600 ]; then stale_str="·$(( cache_age / 60 ))m"; else stale_str="·$(( cache_age / 3600 ))h"; fi
fi

# --- Prompt-cache cue ---
# After the first response Claude Code reports whether the conversation's
# cached prefix is still warm and when it goes cold. While warm a dim
# "cache 42m" (minutes left, rounded up; seconds under a minute) hangs off
# the ctx segment; it turns gold in the last five minutes of a 1h TTL, the
# last minute of a 5m one: one more turn now keeps the prefix, an idle wait
# pays to rebuild it. Cold, it reads "cache cold" in coral with the tokens
# the next request re-caches when known (↻38k). Hidden until caching has
# been observed, and without a ctx bar to hang on.
CACHE_WARN_1H=300; CACHE_WARN_5M=60
cache_str=""; cache_clr=""
if [ "$have_ctx" = 1 ] && [ "$pc_observed" = true ]; then
    left=""; [ "$pc_warm" = true ] && is_int "$pc_exp" && left=$(( pc_exp - now ))
    if [ -n "$left" ] && [ "$left" -gt 0 ]; then
        if [ "$left" -ge 60 ]; then cache_str="cache $(( (left + 59) / 60 ))m"; else cache_str="cache ${left}s"; fi
        warn=$CACHE_WARN_1H; [ "$pc_ttl" = 5m ] && warn=$CACHE_WARN_5M
        if [ "$left" -le "$warn" ]; then ramp_color 50 cache_clr; else cache_clr="$CLR_DIM"; fi
    else
        cache_str="cache cold"; ramp_color 100 cache_clr
        if is_int "$pc_recache" && [ "$pc_recache" -gt 0 ]; then
            if [ "$pc_recache" -ge 1000 ]; then cache_str="$cache_str ↻$(( (pc_recache + 500) / 1000 ))k"; else cache_str="$cache_str ↻$pc_recache"; fi
        fi
    fi
fi

# --- Per-piece visible "chrome" widths (everything that isn't bar blocks) ---
# " · " is counted as the constant 3 and the cache cue measured with its "↻"
# swapped for ASCII; everything else is ASCII, so ${#...} is a correct
# column count regardless of locale.
model_w=0
if [ -n "$model" ]; then
    model_w=${#model}
    [ -n "$effort" ] && model_w=$(( model_w + 3 + ${#effort} ))       # " · <effort>"
fi
ctx_chrome=0
if [ "$have_ctx" = 1 ]; then
    ctx_chrome=$(( 4 + 1 + ${#ctx_i} + 1 ))                           # "ctx:" + " NN%"
    [ -n "$session_money" ] && ctx_chrome=$(( ctx_chrome + 1 + ${#session_money} ))
    # " · " is 3; "↻" is one column whatever the locale counts, so it is
    # swapped for an ASCII stand-in before measuring.
    [ -n "$cache_str" ] && { cache_w="${cache_str/↻/r}"; ctx_chrome=$(( ctx_chrome + 3 + ${#cache_w} )); }
fi
day_chrome=0
[ "$have_day" = 1 ] && day_chrome=$(( 4 + 1 + ${#day_pct} + 1 ))      # "day:"/"off:" + " NN%"
[ -n "$day_money" ] && day_chrome=$(( day_chrome + 1 + ${#day_money} ))
mo_chrome=0
[ "$have_mo" = 1 ]  && mo_chrome=$(( 6 + 1 + ${#mo_pct} + 1 ))        # "month:" + " NN%"
[ -n "$mo_money" ]  && mo_chrome=$(( mo_chrome + 1 + ${#mo_money} ))
[ -n "$over_str" ]  && mo_chrome=$(( mo_chrome + 1 + ${#over_str} ))
SEP=3   # width of " | "

# Spend segment: day and month share one " | "-delimited segment, with a space between.
spend_chrome=0; have_spend=0
if [ "$have_day" = 1 ] || [ "$have_mo" = 1 ]; then
    have_spend=1
    [ "$have_day" = 1 ] && spend_chrome=$(( spend_chrome + day_chrome ))
    if [ "$have_mo" = 1 ]; then
        [ "$have_day" = 1 ] && spend_chrome=$(( spend_chrome + 1 ))  # space between day and month
        spend_chrome=$(( spend_chrome + mo_chrome ))
    fi
    # "·" is one column: the tag's width is its character count.
    [ -n "$stale_str" ] && spend_chrome=$(( spend_chrome + 1 + ${#stale_str} ))
fi

# Shared bar width for a row: split the available columns evenly across its bars,
# clamped to the floor. The division remainder (at most nbars-1 columns) is left
# unfilled rather than making one bar wider than its siblings.
# Args: <columns> <nbars>. Echoes the width.
equal_width() {
    local cols=$1 n=$2 w
    w=$(( cols / n ))
    (( w < BAR_MIN )) && w=$BAR_MIN
    echo "$w"
}

# --- Segment builders (return the colored text for one segment) ---
build_model() {
    [ -z "$model" ] && return
    local s="$model"
    [ -n "$effort" ] && s="$s ${CLR_DIM}·${CLR_RESET} $(effort_color "$effort")$effort${CLR_RESET}"
    printf '%s' "$s"
}
build_ctx() {   # $1 = bar width
    [ "$have_ctx" = 1 ] || return
    local s
    s="ctx:$(bar "$used_pct" "$1")"
    [ -n "$session_money" ] && s="$s ${CLR_DIM}${session_money}${CLR_RESET}"
    [ -n "$cache_str" ] && s="$s ${CLR_DIM}·${CLR_RESET} ${cache_clr}${cache_str}${CLR_RESET}"
    printf '%s' "$s"
}
# pace_cell WIDTH -> PACE: the month bar cell the pace tick sits on, rounded
# like the fill (so fill that exactly meets the tick is exactly on pace) and
# clamped onto the last cell, where it stays through the final workday as the
# finish line. Empty when the month has no workdays at all.
pace_cell() {
    PACE=""
    [ "$pace_total" -gt 0 ] 2>/dev/null || return
    PACE=$(( (2 * pace_done * $1 + pace_total) / (2 * pace_total) ))
    [ "$PACE" -gt $(( $1 - 1 )) ] && PACE=$(( $1 - 1 ))
    return 0
}
build_spend() {  # $1 = day width, $2 = mo width
    local s=""
    if [ "$have_day" = 1 ]; then
        s="$day_label$(bar "$day_pct" "$1")"
        [ -n "$day_money" ] && s="$s ${CLR_DIM}${day_money}${CLR_RESET}"
    fi
    if [ "$have_mo" = 1 ]; then
        pace_cell "$2"
        s="$s month:$(bar "$mo_pct" "$2" "$PACE")"
        [ -n "$mo_money" ] && s="$s ${CLR_DIM}${mo_money}${CLR_RESET}"
        # shellcheck disable=SC2154  # coral is set by ramp_color's printf -v
        [ -n "$over_str" ] && { ramp_color 100 coral; s="$s ${coral}${over_str}${CLR_RESET}"; }
    fi
    [ -n "$s" ] && [ -n "$stale_str" ] && s="$s ${CLR_DIM}${stale_str}${CLR_RESET}"
    printf '%s' "${s# }"
}
# Render a "+A/-R" pair with zero sides suppressed (nothing at all when both
# are zero). $1=added $2=removed $3=style: "hot" (green/coral, the actionable
# pair) or "dim" (ambient context).
fmt_pair() {
    local a="${1:-0}" r="${2:-0}" style="$3" out=""
    [ "$a" -gt 0 ] 2>/dev/null || a=0
    [ "$r" -gt 0 ] 2>/dev/null || r=0
    (( a == 0 && r == 0 )) && return
    local pc mc
    if [ "$style" = hot ]; then ramp_color 0 pc; ramp_color 100 mc; else pc="$CLR_DIM" mc="$CLR_DIM"; fi
    (( a > 0 )) && out="${pc}+${a}${CLR_RESET}"
    if (( r > 0 )); then
        [ -n "$out" ] && out="$out${CLR_DIM}/${CLR_RESET}"
        out="$out${mc}-${r}${CLR_RESET}"
    fi
    printf '%s' "$out"
}

# Parse `git diff --shortstat` on stdin -> "added removed" (0 0 when empty).
parse_shortstat() {
    local line w prev="" a=0 r=0
    IFS= read -r line
    for w in $line; do case "$w" in insertion*) a=$prev ;; deletion*) r=$prev ;; esac; prev=$w; done
    printf '%d %d' "$a" "$r"
}

# Location line grammar: path, branch, then facts ordered now -> ambient:
#   ~/git/x ⎇ branch pending +A/-R ↑a↓b · vs <default> +A/-R · session +A/-R
# Every group is self-hiding (pending only when dirty, arrows only with a
# nonzero count against upstream, vs-<default> only off the default branch,
# session only with churn), so the quiet state collapses to "path ⎇ branch".
# "pending" folds untracked-file lines (gitignore respected; text files under 1 MB) into added; its
# presence IS the dirty flag. "behind" is as of the last fetch -- we never
# fetch here. Not width-managed: the TUI truncates rows on its own.
# In a linked worktree the path reads as a breadcrumb from the main repo:
#   ~/git/x › wt-demo ⎇ feature/wt
# (the main path dim, the worktree name bright, plus any directory below
# it), whether the worktree sits in .claude/worktrees/ or beside the repo.
# squeeze_path VAR: ~-shorten; past 35 chars squeeze middle components
# fish-style (~/g/project) so a deep path can't push the interesting right
# side of the line off-screen.
squeeze_path() {
    local sq_p="${!1}" parts n i o
    sq_p="${sq_p/#$HOME/\~}"
    if [ ${#sq_p} -gt 35 ]; then
        IFS=/ read -ra parts <<< "$sq_p"; n=${#parts[@]}; o="${parts[0]}"
        for ((i = 1; i < n - 1; i++)); do o="$o/${parts[i]:0:1}"; done
        sq_p="$o/${parts[n-1]}"
    fi
    printf -v "$1" '%s' "$sq_p"
}
build_locline() {
    local dir="${cur_dir:-$PWD}" s=""

    # Every group here follows the display file; with the path and branch
    # hidden their dependents are too, so git is not asked at all.
    # One rev-parse gives the repo's common dir, this checkout's own git
    # dir and its top level: the first two differ in a linked worktree
    # (--path-format needs git 2.31; older ones fail and get the plain form).
    local common gitdir top wt=""
    if shown path || shown branch; then
        { read -r common; read -r gitdir; read -r top; } < <(git -C "$dir" rev-parse --path-format=absolute --git-common-dir --git-dir --show-toplevel 2>/dev/null)
        [ -z "$top" ] && top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)
        if [ -n "$common" ] && [ "$common" != "$gitdir" ] && [ "${common##*/}" = .git ] && [ -n "$top" ]; then
            wt="${top##*/}"; [ "$dir" != "$top" ] && wt="$wt/${dir#"$top"/}"
        fi
    fi
    local disp
    if [ -n "$wt" ]; then
        disp="${common%/.git}"; squeeze_path disp
        [ ${#wt} -gt 26 ] && wt="${wt:0:24}.."
        shown path && s="${CLR_DIM}${disp} › ${CLR_RESET}${wt}"
    else
        disp="$dir"; squeeze_path disp
        shown path && s="${CLR_DIM}${disp}${CLR_RESET}"
    fi

    local branch name a r pair
    branch=""
    shown branch && branch=$(git -C "$dir" branch --show-current 2>/dev/null)
    shown branch && [ -z "$branch" ] && branch=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    if [ -n "$branch" ]; then
        # Cap the shown name so a long branch can't evict the groups after it.
        name="$branch"
        [ ${#name} -gt 26 ] && name="${name:0:24}.."
        # Remote repo name, dim, only when it differs from the repo root's
        # dirname (e.g. a checkout whose directory is named differently from
        # the repo); the breadcrumb already says that in a worktree.
        local repo
        repo=$(git -C "$dir" remote get-url origin 2>/dev/null)
        repo=${repo##*/}; repo=${repo%.git}
        [ -z "$wt" ] && [ -n "$repo" ] && [ "$repo" != "${top##*/}" ] && s="$s ${CLR_DIM}(${repo})${CLR_RESET}"

        # Two spaces after ⎇ — the glyph's overhang visually eats one.
        s="$s ⎇  ${name}"

        local cluster=""
        if shown pending; then
            # pending: uncommitted lines vs HEAD + lines in untracked files
            read -r a r <<< "$(git -C "$dir" diff --shortstat HEAD 2>/dev/null | parse_shortstat)"
            local u
            # Only text files under 1 MB count, so a stray build artifact or a
            # not-yet-ignored data dump can't turn every render into a disk scan.
            # ls-files emits repo-relative paths, so the pipeline runs from the repo.
            # Cheap check first: the pipeline runs only when something is untracked.
            u=0; local first=""
            read -r -d '' first < <(git -C "$dir" ls-files --others --exclude-standard -z 2>/dev/null)
            [ -n "$first" ] && u=$( (cd "$dir" 2>/dev/null && git ls-files --others --exclude-standard -z 2>/dev/null \
                   | xargs -0 sh -c 'find "$@" -maxdepth 0 -type f -size -1024k -print0' sh 2>/dev/null \
                   | xargs -0 grep -Ic '' 2>/dev/null) | awk -F: '{s+=$NF} END{print s+0}' )
            pair=$(fmt_pair $(( a + u )) "$r" hot)
            [ -n "$pair" ] && cluster="${CLR_DIM}pending${CLR_RESET} $pair"
        fi

        # ahead/behind upstream
        local behind ahead arrows=""
        shown upstream && read -r behind ahead <<< "$(git -C "$dir" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)"
        [ "${ahead:-0}" -gt 0 ] 2>/dev/null && arrows="↑$ahead"
        [ "${behind:-0}" -gt 0 ] 2>/dev/null && arrows="$arrows↓$behind"
        [ -n "$arrows" ] && cluster="${cluster:+$cluster }$arrows"

        # one separator for the whole working-state cluster, matching the
        # dim · that introduces the vs/session groups
        [ -n "$cluster" ] && s="$s ${CLR_DIM}·${CLR_RESET} $cluster"

        # vs default branch (origin/HEAD, falling back to main/master), hidden on it
        local def
        def=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
        def=${def#origin/}
        if [ -z "$def" ]; then
            if git -C "$dir" show-ref --verify -q refs/heads/main; then def=main
            elif git -C "$dir" show-ref --verify -q refs/heads/master; then def=master; fi
        fi
        if shown vs && [ -n "$def" ] && [ "$branch" != "$def" ]; then
            # A clone that only checked out a feature branch has origin/main but no local main.
            local defref="$def"
            git -C "$dir" show-ref --verify -q "refs/heads/$def" || defref="origin/$def"
            read -r a r <<< "$(git -C "$dir" diff --shortstat "$defref...HEAD" 2>/dev/null | parse_shortstat)"
            pair=$(fmt_pair "$a" "$r" dim)
            [ -n "$pair" ] && s="$s ${CLR_DIM}· vs ${def}${CLR_RESET} $pair"
        fi
    fi

    pair=""; shown session && pair=$(fmt_pair "$lines_added" "$lines_removed" dim)
    [ -n "$pair" ] && s="$s ${CLR_DIM}· session${CLR_RESET} $pair"
    printf '%s' "${s# }"
}
join_parts() {  # join non-empty args with " | "
    local out="" p
    for p in "$@"; do [ -z "$p" ] && continue; [ -n "$out" ] && out="$out | "; out="$out$p"; done
    printf '%s' "$out"
}

# --- One line, or two? Split only when a single row can't fit even with every
#     bar at its floor width. ---
nparts=0
[ -n "$model" ]         && nparts=$(( nparts + 1 ))
[ "$have_ctx" = 1 ]     && nparts=$(( nparts + 1 ))
[ "$have_spend" = 1 ]  && nparts=$(( nparts + 1 ))
one_fixed=$(( model_w + ctx_chrome + spend_chrome ))
[ "$nparts" -gt 1 ] && one_fixed=$(( one_fixed + (nparts - 1) * SEP ))
nbars=$(( have_ctx + have_day + have_mo ))
min_bars=$(( nbars * BAR_MIN ))

BAR_W=$BAR_NOM

if [ $(( one_fixed + min_bars )) -le "$avail" ]; then
    # ---------- ONE LINE: split the row's columns evenly across all bars ----------
    [ "$nbars" -gt 0 ] && BAR_W=$(equal_width $(( avail - one_fixed )) "$nbars")
    out=$(join_parts "$(build_model)" "$(build_ctx "$BAR_W")" "$(build_spend "$BAR_W" "$BAR_W")")
else
    # ---------- TWO LINES: identity+context on row 1, day+month spend on row 2 ----------
    # Each row could afford a different width; the tighter row sets the shared
    # width so bars still match across rows (the roomier row runs short).
    l1_nparts=0; [ -n "$model" ] && l1_nparts=$(( l1_nparts + 1 )); [ "$have_ctx" = 1 ] && l1_nparts=$(( l1_nparts + 1 ))
    l1_fixed=$(( model_w + ctx_chrome )); [ "$l1_nparts" -gt 1 ] && l1_fixed=$(( l1_fixed + SEP ))

    l2_nbars=$(( have_day + have_mo ))

    w1=""; w2=""
    [ "$have_ctx" = 1 ]   && w1=$(equal_width $(( avail - l1_fixed )) 1)
    [ "$l2_nbars" -gt 0 ] && w2=$(equal_width $(( avail - spend_chrome )) "$l2_nbars")
    if [ -n "$w1" ] && [ -n "$w2" ]; then
        BAR_W=$(( w1 < w2 ? w1 : w2 ))
    elif [ -n "$w1" ]; then BAR_W=$w1
    elif [ -n "$w2" ]; then BAR_W=$w2
    fi

    line1=$(join_parts "$(build_model)" "$(build_ctx "$BAR_W")")
    line2=$(build_spend "$BAR_W" "$BAR_W")

    out="$line1"
    if [ -n "$line2" ]; then [ -n "$out" ] && out="$out"$'\n'"$line2" || out="$line2"; fi
fi

# Location + git + churn get their own final row unless the display file hides it.
if shown repo; then
    loc_line=$(build_locline)
    if [ -n "$loc_line" ]; then [ -n "$out" ] && out="$out"$'\n'"$loc_line" || out="$loc_line"; fi
fi

printf '%s' "$out"
