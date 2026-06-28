#!/usr/bin/env bash
# PostToolUse 钩子：改动 GridTrader.mq5 后提醒完成"修改闭环"。
# 仅当 tool_input.file_path 指向 GridTrader.mq5 时触发（编辑 CLAUDE.md/BASELINE.md 不触发）。
# 输出 JSON：additionalContext 注入给模型，systemMessage 显示给用户。

input=$(cat)

if printf '%s' "$input" | grep -Eq '"file_path"[[:space:]]*:[[:space:]]*"[^"]*GridTrader\.mq5"'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"⚠️ 检测到 GridTrader.mq5 被修改。结束本次任务前务必完成修改闭环：① 同步更新 CLAUDE.md 与 BASELINE.md 的相关小节，使其与新代码一致；② 递增 #property version（+0.01）；③ 重新编译并核对 GridTrader.log 出现 Result: 0 errors。"},"systemMessage":"⚠️ GridTrader.mq5 已改动 — 别忘了：更新 CLAUDE.md/BASELINE.md、#property version +0.01、重新编译核对 0 errors。"}
JSON
fi
exit 0
