#!/usr/bin/env bash
# PreToolUse 钩子：当 PowerShell/Bash 命令是在启动 MT5 回测(命令里同时含 terminal64 和 config)时，
# 先杀掉占用 terminal64 的现有 MT5 实例(含 GUI)，再让该命令继续。
# 原因：命令行 `terminal64 /config:` 若已有实例在跑，会移交给现有实例而不真正新跑(用户记忆 apply-mt5-cli-backtest-shutdown)。
# 用户已授权：回测前可擅自关闭 MT5。仅在"启动回测"的命令上动手，普通命令(只 Get-Process 查询等)不触发。

input=$(cat)

if printf '%s' "$input" | grep -qi 'terminal64' && printf '%s' "$input" | grep -qi 'config'; then
  taskkill //F //IM terminal64.exe >/dev/null 2>&1 || true
  sleep 0.7
fi
exit 0
