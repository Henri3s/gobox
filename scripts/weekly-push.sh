#!/usr/bin/env bash
# gobox 每周自动推送（由 launchd 周六 10:00 触发）
# 策略：master 普通 push；feat/auto-tidy 用 --force-with-lease（origin 是个人 fork）。
# 安全：只有确实有未推送提交才推；结束切回原分支；全流程写日志。
set -uo pipefail

REPO="/Users/henri/Documents/Mac App/gobox"
LOG="$HOME/Library/Logs/gobox-push.log"
BR_MASTER="master"
BR_FEATURE="feat/auto-tidy"
EXIT_CODE=0

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

cd "$REPO" || { log "FATAL: 仓库目录不存在，退出"; exit 2; }

log "==================== 开始每周推送 ===================="

# 保存当前分支，结束时切回（不污染工作区）
ORIG_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "")
log "当前分支：${ORIG_BRANCH:-（detached）}"

# 刷新 origin 引用（只读 fetch，不碰 upstream、不改本地分支）
git fetch origin --quiet 2>>"$LOG"

# --- master：普通 push ---
log "--- 处理 $BR_MASTER ---"
if git checkout "$BR_MASTER" --quiet 2>>"$LOG"; then
  AHEAD=$(git rev-list --count origin/"$BR_MASTER".."$BR_MASTER" 2>/dev/null || echo 0)
  BEHIND=$(git rev-list --count "$BR_MASTER"..origin/"$BR_MASTER" 2>/dev/null || echo 0)
  if [ "$AHEAD" -gt 0 ] && [ "$BEHIND" -eq 0 ]; then
    log "master 领先 $AHEAD 个提交，可快进，推送中…"
    if git push origin "$BR_MASTER" >>"$LOG" 2>&1; then
      log "master 推送成功 ✓"
    else
      log "master 推送失败 ✗（远端可能非 fast-forward，跳过，不强制）"
      EXIT_CODE=1
    fi
  elif [ "$AHEAD" -gt 0 ] && [ "$BEHIND" -gt 0 ]; then
    log "master 与 origin 分叉（领先 $AHEAD / 落后 $BEHIND），非快进，跳过待人工处理"
    EXIT_CODE=1
  else
    log "master 无未推送提交，跳过"
  fi
else
  log "无法切到 $BR_MASTER，跳过"
  EXIT_CODE=1
fi

# --- feat/auto-tidy：force-with-lease（个人 fork）---
log "--- 处理 $BR_FEATURE ---"
if git checkout "$BR_FEATURE" --quiet 2>>"$LOG"; then
  AHEAD=$(git rev-list --count origin/"$BR_FEATURE".."$BR_FEATURE" 2>/dev/null || echo 0)
  if [ "$AHEAD" -gt 0 ]; then
    log "feat/auto-tidy 领先 $AHEAD 个提交，force-with-lease 推送中…"
    # --force-with-lease：若远端被意外更新（非自己上次 fetch 的状态）则拒绝，不会盲目覆盖
    if git push --force-with-lease origin "$BR_FEATURE" >>"$LOG" 2>&1; then
      log "feat/auto-tidy 推送成功 ✓"
    else
      log "feat/auto-tidy 推送失败 ✗（--force-with-lease 被拒，远端可能被他人/他机更新，待人工确认）"
      EXIT_CODE=1
    fi
  else
    log "feat/auto-tidy 无未推送提交，跳过"
  fi
else
  log "无法切到 $BR_FEATURE，跳过"
  EXIT_CODE=1
fi

# 切回原分支
if [ -n "$ORIG_BRANCH" ]; then
  git checkout "$ORIG_BRANCH" --quiet 2>>"$LOG" || log "警告：无法切回 $ORIG_BRANCH"
fi

log "==================== 完成 (exit=$EXIT_CODE) ===================="
exit $EXIT_CODE
