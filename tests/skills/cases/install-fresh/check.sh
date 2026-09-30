expect_file "$CFG/settings.json" "\"statusLine\"" "statusLine not set"
expect "$(jq -r .statusLine.command "$CFG/settings.json")" 'bash "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/statusline/spend-statusline.sh"'   # literal: resolved by the shell on each machine
[ -x "$CFG/statusline/spend-statusline.sh" ] || { echo "    script not installed or not executable"; fail=$((fail + 1)); }
[ -r "$CFG/statusline/config/calendar.conf" ] || { echo "    calendar.conf not installed"; fail=$((fail + 1)); }
cmp -s "$CFG/statusline/spend-statusline.sh" "$REPO/statusline/spend-statusline.sh" || { echo "    installed script differs from the plugin copy"; fail=$((fail + 1)); }
[ -r "$CFG/statusline/config/display.conf" ] || { echo "    display.conf not installed"; fail=$((fail + 1)); }
