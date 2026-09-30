expect "$(cat "$CFG/statusline/config/calendar.conf")" "$MINE"   # the edited calendar survives an update
cmp -s "$CFG/statusline/spend-statusline.sh" "$REPO/statusline/spend-statusline.sh" || { echo "    script was not refreshed"; fail=$((fail + 1)); }
expect "$(jq -r .statusLine.command "$CFG/settings.json")" 'CLAUDE_SPEND_TZ=America/Chicago bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/spend-statusline.sh"'   # pre-2.8 absolute path migrated, knob kept
expect "$(cat "$CFG/statusline/config/display.conf")" "$MYDISPLAY"   # the edited display file survives an update
