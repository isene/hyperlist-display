#!/bin/sh
# Tell Claude to drop the hierarchy when /hl is off.
#
# The MessageDisplay hook (hyperlist-display) renders answers as HyperList, but
# it is mechanical: it can only map structure the markdown already has. So the
# CLAUDE.md directive asks Claude to WRITE in hierarchy. That directive is
# static text and cannot see the toggle, hence this hook — it carries the
# toggle state into context so /hl off silences both halves, not just the
# renderer.
#
# Cost when HyperList is on (the common case): one stat() and exit. No output,
# nothing added to context. Only the off-path writes anything.
FLAG="$HOME/.claude/hyperlist-display.off"
[ -f "$FLAG" ] || exit 0

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"HyperList output is OFF. This is a STANDING setting, not a one-turn exception: answer in normal prose from now on, every turn, until the user runs /hl on. Do not drift back into tab-indented hierarchy or one-sentence-per-line structuring as the conversation goes on. Ordinary markdown headings and bullets are still fine where they genuinely help. This notice repeats each turn while the setting is off — treat it as the current state, not as news."}}
JSON
