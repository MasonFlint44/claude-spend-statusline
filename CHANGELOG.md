# Changelog

Versions follow the `version` field in `.claude-plugin/plugin.json`; Claude
Code offers a plugin update when that field changes. Each version is a git
tag (`v2.2.0`) and a GitHub release with this section as its notes.

## 2.8.0 — 2026-09-30

- **Portable `statusLine` command.** The install skill now writes
  `bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/spend-statusline.sh"`
  literally instead of an absolute path. Claude Code runs the command through
  a shell, so one settings file works on the host and in a devcontainer that
  mounts `~/.claude` under another user's home. Re-running
  `/spend-statusline:install` migrates an older absolute-path command and
  keeps its inline knobs.
- **macOS: no absolute bash path either.** Started under bash 3.2, the script
  hands itself (stdin and arguments intact) to a 4.4+ bash at
  `/opt/homebrew/bin/bash` or `/usr/local/bin/bash`. The guard's message now
  just says `brew install bash`.
- README: a "Sharing ~/.claude" section. A host and a container on different
  time zones share the cache and disagree about the date for part of each
  day; pin `CLAUDE_SPEND_TZ` inline in the shared command. The install skill
  suggests it when told the config dir is shared.
- The calendar, display and doctor skills read the new command form.

## 2.7.0 — 2026-09-08

- **Renamed to `claude-spend-statusline`.** The plugin is `spend-statusline`,
  the script is `statusline/spend-statusline.sh`, and the skills are
  `/spend-statusline:install`, `:calendar`, `:display` and `:doctor` (were
  `/budget-statusline:...`).
- **Environment knobs renamed**: `CLAUDE_SPEND_MONTHLY_LIMIT`,
  `CLAUDE_SPEND_CALENDAR`, `CLAUDE_SPEND_DISPLAY`, `CLAUDE_SPEND_REFRESH`,
  `CLAUDE_SPEND_TZ` (were `CLAUDE_BUDGET_*`).
- **Cache files renamed**: `spend-usage`, `spend-usage.daystart`,
  `spend-usage.lock`, `spend-usage.hold` (were `budget-usage*`).
- The old names are **not** accepted: there is no fallback for
  `CLAUDE_BUDGET_*`, no alias for the old skill names, and the old cache
  files are ignored (the first render after updating refetches). Re-run
  `/spend-statusline:install` after updating the plugin so `statusLine` in
  `settings.json` points at the renamed script.

## 2.6.3 — 2026-09-06

- Doctor skill quotes the doctor's block through its `bars:` verdict instead
  of summarizing it (the headless doctor case dropped the verdict one run in
  two on sonnet; four of four after).

## 2.6.2 — 2026-09-06

- Doctor skill: documents the doctor's third ending, `bars: hidden by
  <display file>`, and the display line's parse warnings, routing both to
  the display skill. Calendar skill: writes without a confirmation round
  when the user has already said not to ask, as the display skill does.

## 2.6.1 — 2026-09-06

- Skill descriptions tuned against the trigger evals on sonnet (every skill
  20/20 at three runs per query): the install skill mentions switching the
  statusLine command to another bash; the doctor and display skills say
  which of them owns a hidden element versus a blank bar.

## 2.6.0 — 2026-09-06

- **Skills renamed** to `/budget-statusline:install`, `:calendar`, `:display`
  and `:doctor` (were `/budget-statusline-install` and so on). Claude Code
  namespaces plugin skills with the plugin name, so the prefix was said
  twice; the docs and the bash-too-old message now use the namespaced form.
- Marketplace is `claude-toolbox` (was `claude-statuslines`) in the README.
- The install skill's description carries its trigger phrases.
- Skill trigger evals: `tests/skills/triggers.sh` scores each skill's
  description over twenty queries in `tests/skills/triggers/` through the
  skill-creator plugin's evaluator, and can run its optimizer. Paid, by hand.
- `CLAUDE.md` for contributors.

## 2.5.0 — 2026-09-06

- **Worktrees on the repository row.** In a linked worktree the path
  reads as a breadcrumb from the main repository: `~/git/project ›
  wt-demo ⎇  feature/wt`, the main path dim, the worktree's name bright
  (capped at 24 characters plus `..`, with any directory below the worktree
  after it), then the worktree's own branch. Claude Code's
  `.claude/worktrees/<name>` and hand-made sibling worktrees render alike;
  the main checkout keeps the plain form. Detected through git (`rev-parse
  --path-format=absolute --git-common-dir`), so a git older than 2.31 falls
  back to the plain form. The `(repo)` tag is dropped in the worktree form.
  Part of the `path` element.
- Tests: `worktree.bats` (283 tests); three more boundary tests widened for
  the fake clock's jitter (refresh fallback, cache gold window, age tag).

## 2.4.0 — 2026-09-06

- **Display file.** `config/display.conf` decides which elements show:
  `hide NAME ...` lines, names space or comma separated, case-insensitive,
  accumulating; no file shows everything. Sixteen names: `model`, `effort`,
  `ctx`, `cost`, `cache`, `day`, `month`, `pace`, `age`, `repo`, `path`,
  `branch`, `pending`, `upstream`, `vs`, `session`. Hiding an element hides
  what hangs off it (ctx takes cost and cache; month takes pace; branch
  takes pending, upstream and vs; repo takes the row), and the row re-flows
  around the gap. Hiding both `day` and `month` switches the usage fetch off
  entirely: no credentials read, no request, no cache or lock written.
  `CLAUDE_BUDGET_DISPLAY` names another file, or `off` for none. The rows
  and their order stay fixed.
- **`--display [FILE]`** lists every element as `on`, `off` or `off (needs
  X)` with its description, and reports lines it skipped. `--doctor` gains a
  `display:` line and, with both budget bars hidden, says so and exits 0.
- **`/budget-statusline-display`** skill: hide or show elements, list what
  is hidden and what can be switched on, explain why an element vanished,
  reset to defaults. The installer copies `display.conf` only when absent,
  like the calendar.
- **Removed `CLAUDE_BUDGET_REPO_LINE`** (breaking; no users yet): `hide
  repo` in the display file replaces it.
- A statusline whose first line is entirely empty no longer prints a blank
  row above the repository row.
- README: an Elements section describing every element; the cache-line
  guard is described as plain corruption handling (the pre-mask format it
  mentioned never shipped).
- Tests: `display.bats`, the repository row's names in `repoline.bats`
  (269 tests); the test helpers hide the repository row through a display
  file instead of the removed knob.

## 2.3.0 — 2026-09-06

- **Pace tick.** A light line in the month bar marks today's place in the
  month's workdays (elapsed over total, from the calendar): fill short of
  it is under pace, fill past it is over. It rounds onto a cell the way the
  fill does, sits on the final cell through the last workday, and keeps its
  calendar position over a pegged, past-the-limit fill.
- **Prompt-cache cue.** After the session cost: `cache 42m` while the
  conversation's cached prefix is warm (dim; gold in the last five minutes
  of a 1h TTL, the last minute of a 5m one), `cache cold ↻38k` in coral once
  it has expired, with the tokens the next request re-caches. From the
  `prompt_cache` object Claude Code sends; hidden until caching has been
  observed. Counted in the row's width like the age tag.
- Tests: `pace.bats` and `cache.bats` (228 tests); the five-minute age-tag
  and 120-second refresh boundary tests allow the fake clock's second or two
  of jitter, as the 60-second one already did.
- README preview regenerated with both cues.

## 2.2.5 — 2026-09-06

- `--doctor` reports `cache: could not write` when the cache directory is not
  writable, instead of reading back an older line as "refreshed just now".
- Tests: a line-trace audit of the suite (207 tests) closed the last untested
  branches: an unknown day in an `observe DOW=MODE` override, the `master`
  default-branch fallback, two-row layouts without a ctx bar, and the
  unwritable cache directory above.
- README: the day-start baseline is per machine.

## 2.2.4 — 2026-09-05

- The bash version guard now points at `brew install bash` and
  `/budget-statusline-install`, which wires the new bash; no hand edit of
  the `statusLine` command is asked of the user.
- Compatibility tests through Docker's `bash` images (`DOCKER=1`, on in CI):
  the version guard verified on real 3.2 and 4.3, a full render on 4.4
  with busybox awk. The 3.2 guard in 2.2.3 was reasoned, not run.

## 2.2.3 — 2026-09-05

- The bash 4.4+ check is now the first command in the script, in bash-3
  syntax, so a too-old bash (macOS's 3.2) gets one clear line with the
  install command instead of a syntax error; 2.2.2's check sat inside
  `--doctor`, past bash-4 syntax, and was unreachable on the bash it was for.
- `/budget-statusline-install` picks the interpreter itself: on macOS it
  wires `/opt/homebrew/bin/bash` or `/usr/local/bin/bash` (4.4+) by absolute
  path, or stops and asks for `brew install bash`; the calendar and doctor
  skills reuse whatever interpreter the `statusLine` command names.

## 2.2.2 — 2026-09-05

- Skills renamed with the plugin's name as prefix, so they cannot collide
  with another statusline plugin's: `/budget-statusline-install`,
  `/budget-statusline-calendar` (was `/budget-calendar`),
  `/budget-statusline-doctor` (was `/budget-doctor`).
- `--doctor` checks the tools first: jq, curl, awk and readlink present,
  bash 4.4+, git optional, and names the install command for the platform
  (apt, dnf, pacman, zypper, apk, brew, winget). A missing jq used to
  surface as a bogus "no OAuth token".
- The headless skill runner bypasses permission prompts (test only), so the
  fresh-install case can wire `settings.json`.

## 2.2.1 — 2026-09-05

- `/install-statusline` is model-invocable again: 2.2.0 marked it
  `disable-model-invocation`, which also stopped "install the budget
  statusline" in chat from reaching it. The slash command and the ask both
  work.

## 2.2.0 — 2026-09-05

- `--doctor`: runs the refresh in the foreground one step at a time and names
  the first one that hides the bars (no credentials, no token, expired token,
  curl failure, HTTP status, spend billing off, no figure, no limit). Exit 1
  when the bars would stay hidden.
- `/budget-doctor` skill: finds the installed script and runs the doctor for
  "my budget bars are blank". The installer now runs the doctor as its last
  step, so the bars are filled on the first render.
- `--help`.
- Staleness tag: a dim `·12m` / `·3h` after the bars once no fetch has
  succeeded for five minutes; counted in the row width so bars shrink to fit.
- macOS: with no credentials file the token is read from the Keychain item
  Claude Code creates. Unverified on a Mac; Linux never touches it.
- README preview generated from the script (`docs/preview.py`).
- `plugin.json` carries author, license, repository and homepage and passes
  `claude plugin validate --strict`.
- shellcheck clean and run in CI. Tests for damaged cache files, 30- and
  20-column terminals, every doctor branch (195 tests).

## 2.1.0 — 2026-09-05

- Amounts honour the `exponent` field of the usage response instead of
  assuming cents.
- Spend billing switched off in the response (`spend.enabled: false`) hides
  the bars instead of showing zeros.
- Recorded usage response as a fixture; `LIVE=1 bats tests/live.bats` probes
  the real endpoint for drift.
- All date arithmetic in bash: no GNU `date`, no `date` calls at all. Render
  path 34 processes down to 6, refresh 81 down to 15.
- The off-words `off|none|no|0|false` work for both `CLAUDE_BUDGET_CALENDAR`
  and `CLAUDE_BUDGET_REPO_LINE`, in any case.
- Headless skill checks (`tests/skills/run.sh`) through `claude -p`.
- Round half up everywhere; locale tests build their own locale.

## 2.0.0 — 2026-09-05

- `calendar.conf` replaces `holidays.conf`: a configurable work week
  (`workdays sun-thu`), observe modes for holidays on non-workdays
  (`nearest`, `next`, `prev`, `none`, per weekday), `once` ranges for PTO.
- `--calendar [YYYY]` listing with observed dates and workday counts.
- `/budget-calendar` skill.
- Bats test suite with golden calendar listings; CI on every push.

## 1.0.0 — 2026-09-03

- Initial public release: day and month budget bars from the usage endpoint,
  US federal holidays, `CLAUDE_BUDGET_TZ`, `CLAUDE_BUDGET_REFRESH`,
  `CLAUDE_BUDGET_MONTHLY_LIMIT`, optional second line, `/install-statusline`.
