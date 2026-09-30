scaffold_installed "CLAUDE_SPEND_TZ=America/Chicago "   # the pre-2.8 absolute form
printf "# stale marker\n" >> "$CFG/statusline/spend-statusline.sh"
printf "once 2026-11-27 Day after Thanksgiving\n" >> "$CFG/statusline/config/calendar.conf"; MINE=$(cat "$CFG/statusline/config/calendar.conf")
printf "hide pace\n" >> "$CFG/statusline/config/display.conf"; MYDISPLAY=$(cat "$CFG/statusline/config/display.conf")
