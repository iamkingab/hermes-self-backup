#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# 备份看门狗 —— 零假警报设计
#
# 每 6 小时跑一次。正常时【完全静默】（无输出），只有真故障才输出内容，
# 输出内容会被 cron 捕获并投递到飞书/邮件。
#
# 检查项：
#   ① 距上次成功备份 > 30h
#   ② vault 目录丢失或不是 git 仓库
#   ③ 日志尾部有失败标记
#   ④ 远程仓库 pushed_at > 30h
#   ⑤ 会话历史导出为空（假成功检测）
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

HERMES_DIR="${HERMES_DIR:-$HOME/.hermes}"
VAULT="${VAULT:-$HOME/hermes-vault}"
LOG="${LOG:-$HERMES_DIR/logs/backup.log}"
STAMP="$HERMES_DIR/logs/backup.last-success"
MAX_AGE_H="${MAX_AGE_H:-30}"

PROBLEMS=()
add() { PROBLEMS+=("$1"); }

NOW=$(date +%s)
HOST=$(hostname)

# ── ① 距上次成功备份 ──
if [ ! -f "$STAMP" ]; then
    add "从未成功备份过（$STAMP 不存在）"
else
    AGE_H=$(( (NOW - $(cat "$STAMP" 2>/dev/null || echo 0)) / 3600 ))
    [ "$AGE_H" -gt "$MAX_AGE_H" ] && add "距上次成功备份已 ${AGE_H} 小时（阈值 ${MAX_AGE_H}h）"
fi

# ── ② vault 状态 ──
if [ ! -d "$VAULT" ]; then
    add "vault 目录丢失: $VAULT"
elif [ ! -d "$VAULT/.git" ]; then
    add "vault 不是 git 仓库: $VAULT"
elif ! git -C "$VAULT" remote get-url origin >/dev/null 2>&1; then
    add "vault 未配置 git remote（推送无处可去）"
fi

# ── ③ 日志尾部失败标记 ──
if [ -f "$LOG" ]; then
    RECENT=$(tail -80 "$LOG" 2>/dev/null)
    if echo "$RECENT" | grep -qE '❌|全部通道失败|导出失败|推送失败|加密失败'; then
        LASTERR=$(echo "$RECENT" | grep -E '❌|失败' | tail -2 | sed 's/^/     /')
        add "备份日志出现失败标记：
$LASTERR"
    fi
    # 最近一次运行是否太老（日志本身没更新）
    LOG_AGE_H=$(( (NOW - $(stat -c%Y "$LOG" 2>/dev/null || echo 0)) / 3600 ))
    [ "$LOG_AGE_H" -gt "$MAX_AGE_H" ] && add "备份日志已 ${LOG_AGE_H} 小时未更新（cron 可能没跑）"
fi

# ── ④ 远程仓库活性 ──
if [ -f "$HERMES_DIR/credentials/github-token.txt" ] && command -v curl >/dev/null 2>&1; then
    TOKEN=$(cat "$HERMES_DIR/credentials/github-token.txt" 2>/dev/null)
    SLUG=$(git -C "$VAULT" remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||')
    if [ -n "$TOKEN" ] && [ -n "$SLUG" ]; then
        PUSHED=$(curl -s -m 20 -H "Authorization: token $TOKEN" \
                 "https://api.github.com/repos/$SLUG" 2>/dev/null \
                 | python3 -c "import json,sys; print(json.load(sys.stdin).get('pushed_at',''))" 2>/dev/null)
        if [ -z "$PUSHED" ]; then
            add "无法查询远程仓库状态（$SLUG）—— 网络问题或 token 失效"
        else
            PT=$(date -d "$PUSHED" +%s 2>/dev/null || echo 0)
            if [ "$PT" -gt 0 ]; then
                RH=$(( (NOW - PT) / 3600 ))
                [ "$RH" -gt "$MAX_AGE_H" ] && add "远程仓库已 ${RH} 小时未收到推送（$SLUG）"
            fi
        fi
    fi
fi

# ── ⑤ 会话历史假成功检测 ──
if [ -d "$VAULT/memory" ]; then
    GZ=$(ls "$VAULT/memory"/state-recent*.db.gz 2>/dev/null | head -1)
    PARTS=$(ls "$VAULT/memory"/state-recent*.db.gz.part-* 2>/dev/null | wc -l)
    if [ -z "$GZ" ] && [ "$PARTS" -eq 0 ]; then
        add "memory/ 下没有会话历史文件（第2层可能从未导出成功）"
    fi
    # 非空但异常小 → 可疑（注意：会话很少的用户库本身就小，阈值取 1KB 以下才算可疑）
    if [ -n "$GZ" ]; then
        SZB=$(stat -c%s "$GZ" 2>/dev/null || echo 0)
        [ "$SZB" -lt 1024 ] && add "会话历史文件异常小（${SZB} 字节），疑似空库"
    fi
else
    add "memory/ 目录不存在（第2层未备份）"
fi

# ── 输出：有故障才说话 ──
if [ ${#PROBLEMS[@]} -eq 0 ]; then
    exit 0            # 静默
fi

echo "🚨 **Hermes 备份异常** — $HOST"
echo ""
for p in "${PROBLEMS[@]}"; do
    echo "- $p"
done
echo ""
echo "备份目录: \`$VAULT\`"
echo "日志: \`$LOG\`"
exit 1
