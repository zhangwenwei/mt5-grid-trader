#!/usr/bin/env bash
# PreToolUse hook: when a PowerShell/Bash command launches an MT5 backtest (the command contains both terminal64 and config),
# first kill any existing MT5 instance holding terminal64 (including the GUI), then let the command continue.
# Reason: a command-line `terminal64 /config:` hands over to an already running instance and does not really run (user memory apply-mt5-cli-backtest-shutdown).
# The user has authorized closing MT5 before backtests. It only acts on "launch backtest" commands; ordinary commands (e.g. a Get-Process query) do not trigger it.

input=$(cat)

if printf '%s' "$input" | grep -qi 'terminal64' && printf '%s' "$input" | grep -qi 'config'; then
  taskkill //F //IM terminal64.exe >/dev/null 2>&1 || true
  sleep 0.7
fi
exit 0
