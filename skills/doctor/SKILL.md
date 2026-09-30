---
name: doctor
description: Diagnose the spend statusline — why the day and month bars are blank or stale, whether the credentials, usage endpoint, limit and cache are all in order. Use when the user says the spend bars are missing, empty, stuck, stale, wrong, or asks whether the statusline is working. An element the user hid on purpose through the display file is the display skill's job.
---

# Diagnose the spend statusline

The spend bars hide whenever any step of the usage refresh fails, and the statusline itself never says which. The script's `--doctor` flag runs those steps in the foreground, one at a time, and names the first one that fails. This skill finds the installed script, runs the flag, and turns its output into a fix.

## Steps

1. **Find the installed script.** Read `statusLine.command` in `$CFG/settings.json` (`CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`). It names the script, normally written as `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/spend-statusline.sh"` (shell text that resolves to `$CFG/statusline/spend-statusline.sh`; older installs spell out an absolute path), and may carry inline knobs such as `CLAUDE_SPEND_MONTHLY_LIMIT=...` or `CLAUDE_SPEND_TZ=...` in front of it, and names the interpreter (`bash`; older macOS installs name an absolute path such as `/opt/homebrew/bin/bash`): use the same one. If there is no `statusLine` entry, or it names another script, the spend statusline is not installed: say so and point the user at `/spend-statusline:install`.

2. **Run the doctor with exactly those knobs, that interpreter and that path**, and quote its output as printed, every line through the final `bars:` verdict, rather than summarizing it: the user needs the exact lines to match against the table below and to report if something is off.
   ```bash
   [KNOBS] [BASH] "$CFG/statusline/spend-statusline.sh" --doctor
   ```
   It prints one line per step (version, tools, config dir, spend clock, calendar, this month's workdays, display, credentials, the live usage fetch, the limit, the cache) and ends with `bars: will show` (exit 0) or `bars: hidden` (exit 1) right after the step that failed. A third ending, `bars: hidden by <display file> (day and month both hidden)` with exit 0, means nothing failed: the user's own display file hides both bars. A successful run also refreshes the cache, so the next render shows current figures.

3. **Explain the failing line and the fix.** The doctor's message names the cause; the usual ones:

   | Doctor says | What it means | Fix |
   |---|---|---|
   | `tools: missing: ...` | a required tool (jq, curl, awk, readlink) or a bash older than 4.4 | the line carries the install command for this platform (apt, dnf, pacman, brew, winget); run it, then rerun the doctor |
   | `no credentials file` / `no OAuth token` | Claude Code is using an API key, or has never logged in through claude.ai on this machine | `claude` then `/login`; API-key sessions have no usage token, so the bars cannot show there |
   | `the OAuth token expired` | the CLI refreshes it on its next request | start a Claude Code session; rerun the doctor |
   | `HTTP 401` / `HTTP 403` | the token was rejected | log in again |
   | `HTTP 429` | rate limited; the statusline backs off five minutes | wait, then rerun |
   | `curl failed` | no network, a proxy, or the endpoint timed out | check connectivity from this shell |
   | `spend.enabled is false` | the organization has spend billing switched off, so there is no dollar figure | nothing to fix in the statusline; the bars need a plan that reports dollars |
   | `no spend figure in the response` | the plan reports no dollars (a personal Pro/Max plan), or the endpoint changed shape | same; if the account *does* show dollars on `/usage`, this is a shape change worth an issue on the repo |
   | `limit: none` | the response carries no monthly limit | set `CLAUDE_SPEND_MONTHLY_LIMIT` inline in the `statusLine` command |
   | `line(s) not parsed` on the calendar line | a calendar entry is malformed; the bars still show, the workday count may be off | run `/spend-statusline:calendar` to see and fix the line |
   | `display: <file>: hidden day, month` and `bars: hidden by <file>` | both bars are hidden on purpose by the display file; the fetch is skipped | nothing is broken; `/spend-statusline:display` brings them back if that is not what the user wants |
   | `line(s) not parsed` on the display line | a display entry is malformed; the good lines still apply | run `/spend-statusline:display` to see and fix the line |

   If the doctor says `bars: will show` but the user still sees none, the statusline is rendering from a different config dir or a different script than the one in settings: compare the `config dir:` line with `$CLAUDE_CONFIG_DIR` in the session, and the script path with `statusLine.command`.

4. **Apply the fix only with the user's agreement**, then rerun the doctor and show the result. Editing `settings.json` for a knob follows the same rule as the installer: show the exact change first.

## Do not

- Do not print, copy or echo the token; the doctor never shows it and neither should you.
- Do not edit the plugin's own copy of the script; run the installed one.
- Do not guess at the cause when the doctor has named one; quote its line.
- Do not summarize the doctor's block in place of quoting it. Its lines, through the `bars:` verdict, are what the user compares against the table and pastes into an issue.
