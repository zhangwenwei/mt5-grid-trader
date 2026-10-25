#!/usr/bin/env bash
# PostToolUse hook: after GridTrader.mq5 is modified, remind to complete the "change loop".
# Triggers only when tool_input.file_path points to GridTrader.mq5 (editing CLAUDE.md/BASELINE.md does not trigger it).
# Outputs JSON: additionalContext is injected for the model, systemMessage is shown to the user.

input=$(cat)

if printf '%s' "$input" | grep -Eq '"file_path"[[:space:]]*:[[:space:]]*"[^"]*GridTrader\.mq5"'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⚠️ GridTrader.mq5 was modified. Before finishing the task, complete the change loop: ① update the relevant sections of CLAUDE.md and BASELINE.md to match the new code; ② bump #property version (+0.01); ③ recompile and confirm GridTrader.log shows Result: 0 errors."},"systemMessage":"⚠️ GridTrader.mq5 changed — remember to: update CLAUDE.md/BASELINE.md, bump #property version by +0.01, recompile and check for 0 errors."}
JSON
fi
exit 0
