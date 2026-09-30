---
name: display
description: Choose which elements the spend statusline shows — hide or bring back the pace tick, the cache cue, the effort level, the spend bars, the repository row or any of its parts, list what is currently displayed or hidden, explain why an element disappeared, or reset the display to defaults. Use when the user says "hide the pace tick", "turn the cache countdown off", "I don't want the month bar", "show the session churn again", "what is hidden", "what else can the statusline show", "why did the cost disappear", "reset the statusline display". Bars that are blank or stale rather than hidden are the doctor skill's job.
---

# Choose what the spend statusline shows

Every element of the statusline has a name, and `display.conf` lists the ones to hide. This skill turns what the user wants into `hide` lines, edits the installed copy, and shows the resulting listing so the change is visible immediately.

## Where the file is

Read `statusLine.command` in `$CFG/settings.json` (`CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`). It names the installed script, normally written as `"${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/spend-statusline.sh"` (shell text that resolves to `$CFG/statusline/spend-statusline.sh`; older installs spell out an absolute path), may carry inline knobs such as `CLAUDE_SPEND_DISPLAY=...` before it, and names the interpreter (`bash`; older macOS installs name an absolute path such as `/opt/homebrew/bin/bash`). Run the listing with exactly those knobs, that interpreter and that script path:

```bash
[KNOBS] [BASH] "$CFG/statusline/spend-statusline.sh" --display
```

Its first line is `display: <path>`: **that path is the file to edit.** Without an override it is `$CFG/statusline/config/display.conf`. If the line reads `no file at <path>`, create the file at that path. If it reads `off (CLAUDE_SPEND_DISPLAY=off)`, the command has switched the file off; say so and ask whether to remove that knob from the `statusLine` command (the display skill never edits `settings.json` without asking). Do not edit the plugin's own `statusline/config/display.conf`: it is the shipped default and is replaced on every plugin update. If the script is not installed, say so and point the user at `/spend-statusline:install`.

## The grammar

One `hide` line per group of names, `#` starts a comment, lines accumulate:

```
hide pace cache
hide session
```

Names are case-insensitive, space or comma separated. No file, or no `hide` line, shows everything. There is no `show` keyword: an element comes back when no line hides it.

## The elements

| Name | On screen | Needs |
|------|-----------|-------|
| `model` | the model name (`Opus`) | |
| `effort` | the effort level (`· high`) | `model` |
| `ctx` | the context bar and its percentage | |
| `cost` | the session cost (`$3.72`) | `ctx` |
| `cache` | the prompt-cache cue (`· cache 42m`, `· cache cold ↻38k`) | `ctx` |
| `day` | the day bar with its spend and allowance | |
| `month` | the month bar with its spend, limit and overage | |
| `pace` | the tick in the month bar (`│`) | `month` |
| `age` | the stale-fetch tag (`·12m`) | `day` or `month` |
| `repo` | the whole repository row | |
| `path` | the working directory | `repo` |
| `branch` | the branch, with the repository name when the directory is named differently | `repo` |
| `pending` | uncommitted lines (`· pending +16`) | `branch` |
| `upstream` | commits ahead of and behind upstream (`↑1↓2`) | `branch` |
| `vs` | lines changed against the default branch (`· vs main +30`) | `branch` |
| `session` | lines Claude Code edited this session (`· session +118/-27`) | `repo` |

Hiding an element hides everything that needs it; the listing marks those `off (needs ctx)`. Hiding both `day` and `month` also stops the usage fetch (no credentials read, no request made). The rows and their order are fixed: the file can hide elements, not move them.

## Requests

- **Hide something** ("turn the pace tick off", "I don't want the cache countdown"): add its name to a `hide` line. Mention what goes with it when something does ("hiding ctx also hides the cost and the cache cue").
- **Show something again** ("bring the session churn back"): remove the name from every `hide` line that carries it; delete a line left empty. If the element is `off (needs X)`, it is X that must come back; say so.
- **What is displayed or hidden**: run the listing and show it. For a pure question, stop there: no edit.
- **What can be switched on**: the listing's `off` rows are the answer; an all-`on` listing means everything is already shown.
- **Why did X disappear**: run the listing. `off` means the file hides it; `off (needs Y)` means Y is hidden. If X is `on` the file is not the reason: the element hides itself when it has nothing to show (no spend figure for the bars, a clean tree for `pending`, no edits yet for `session`, no cache observed yet for `cache`), and blank spend bars are `/spend-statusline:doctor`'s question. Answer, no edit.
- **Reset to defaults**: remove every `hide` line (keep the comments). Everything shows.
- **Reorder, move an element to another row, put the repo row first**: not supported by the statusline, whose rows are fixed by design. Say so plainly and offer hiding instead.

## Steps

1. **Show the current state.** Run the listing and show it. For a question, stop here.
2. **Translate the request** into the exact `hide` lines to add, change or remove, and name any dependents that go with them.
3. **Confirm before writing.** Show the lines and the file path; write only after the user agrees, unless the user has already said not to ask. Do not rewrite lines that are not part of the request.
4. **Verify.** Rerun the listing and show it: every requested name reads `off` (or `on` after a show), and there are no `skipping` lines on stderr. A name the listing reports as unknown is a typo; fix it and rerun.
5. **Report** the change in a sentence. The statusline picks the file up on its next render, no restart needed.

## Do not

- Do not edit the plugin's copy of `display.conf` or the script itself. Edit the path the listing prints.
- Do not write without showing the exact lines first (unless told not to ask).
- Do not invent names: only the sixteen above exist. Check the listing rather than guess.
- Do not add per-element environment variables to the `statusLine` command; the file is the one mechanism.
- Do not skip the verification listing.
