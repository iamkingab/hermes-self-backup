#!/usr/bin/env bash
# 备份验收探针：交叉核对「日志声称的量级」vs「源库真值」
#
# 为什么需要它：脚本自己的成功判据可能是坏的。
# 实测过的事故 —— 导出崩溃留下空临时文件，被 gzip 成 4.0K，日志照样打 ✓，
# 还照常 commit + push，得到一个「看起来完美、实际会话历史全空」的备份。
# 抓到的关键是「量级不合理」：239 个会话不可能只有 4KB。
#
# 本探针不依赖备份脚本的正确性，只用两个独立事实对照：
#   ① 源库 COUNT(*)
#   ② 日志/仓库里产物的 COUNT(*)
#
# 用法:
#   bash verify-backup-integrity.sh [HERMES_DIR] [VAULT_DIR]
# 默认: ~/.hermes 和 ~/hermes-vault
#
# 退出码: 0 = 通过; 1 = 发现不一致（应视为备份失败，别信日志）

set -u
H="${1:-$HOME/.hermes}"
V="${2:-$HOME/hermes-vault}"
LOG="$H/logs/backup.log"
FAIL=0

say() { printf '%s\n' "$*"; }
bad() { printf '  🔴 %s\n' "$*"; FAIL=1; }
ok()  { printf '  ✅ %s\n' "$*"; }

say "════════ 备份完整性验收 ════════"
say "  Hermes: $H"
say "  Vault : $V"
say ""

# ── 1. 源库真值 ────────────────────────────────────────────────
say "【1】源库真值"
if [ ! -f "$H/state.db" ]; then
    bad "源库不存在: $H/state.db"
    SRC_S="?"; SRC_M="?"
else
    SRC_S=$(sqlite3 "file:$H/state.db?mode=ro" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "ERR")
    SRC_M=$(sqlite3 "file:$H/state.db?mode=ro" "SELECT COUNT(*) FROM messages;" 2>/dev/null || echo "ERR")
    say "  sessions: $SRC_S"
    say "  messages: $SRC_M"
fi
say ""

# ── 2. 产物真值（合并切片 → 解压 → 计数）──────────────────────
say "【2】产物真值（独立于日志，直接读备份文件）"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
GZ="$V/memory/state-recent60d.db.gz"
if ls "$V"/memory/state-recent60d.db.gz.part-* >/dev/null 2>&1; then
    say "  切片数: $(ls "$V"/memory/state-recent60d.db.gz.part-* | wc -l)"
    cat "$V"/memory/state-recent60d.db.gz.part-* > "$T/merged.gz" 2>/dev/null
    GZ="$T/merged.gz"
    # 顺便校验 SLICES.md 里的 sha256
    if [ -f "$V/memory/SLICES.md" ]; then
        BADSUM=0
        while read -r sum f; do
            [ -z "$sum" ] && continue
            case "$sum" in \#*) continue;; esac
            A=$(sha256sum "$V/memory/$f" 2>/dev/null | cut -d' ' -f1)
            [ "$A" = "$sum" ] || { bad "sha256 不符: $f"; BADSUM=1; }
        done < <(grep -E '^[a-f0-9]{64} ' "$V/memory/SLICES.md")
        [ "$BADSUM" -eq 0 ] && ok "各片 sha256 与 SLICES.md 一致"
    else
        bad "缺 SLICES.md，无法校验切片完整性"
    fi
fi
if [ -f "$GZ" ]; then
    gunzip -c "$GZ" > "$T/check.db" 2>/dev/null
    if [ ! -s "$T/check.db" ]; then
        bad "解压失败或为空: $GZ"
        DST_S="0"; DST_M="0"
    else
        DST_S=$(sqlite3 "$T/check.db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "ERR")
        DST_M=$(sqlite3 "$T/check.db" "SELECT COUNT(*) FROM messages;" 2>/dev/null || echo "ERR")
        say "  sessions: $DST_S"
        say "  messages: $DST_M"
        INT=$(sqlite3 "$T/check.db" "PRAGMA integrity_check;" 2>&1 | head -1)
        [ "$INT" = "ok" ] && ok "integrity_check: ok" || bad "integrity_check: $INT"
        # FTS 真能用吗（表在但 rebuild 没跑 = 命中 0）
        FTS=$(sqlite3 "$T/check.db" "SELECT COUNT(*) FROM messages_fts LIMIT 1;" 2>&1 | head -1)
        case "$FTS" in
            ERR*|*"no such table"*) bad "FTS 表缺失/不可查: $FTS" ;;
            *) ok "FTS 可查（命中 $FTS）" ;;
        esac
    fi
else
    bad "找不到产物: $GZ（也没找到切片）"
    DST_S="0"; DST_M="0"
fi
say ""

# ── 3. 量级交叉核对（核心判据）────────────────────────────────
say "【3】量级交叉核对"
if [ "$SRC_S" = "ERR" ] || [ "$DST_S" = "ERR" ] || [ "$DST_S" = "?" ]; then
    bad "计数不可得，无法核对"
elif [ "$DST_S" -eq 0 ] && [ "$SRC_S" -gt 0 ]; then
    bad "源库有 $SRC_S 个会话，产物 0 个 —— 导出失败被当成功了"
else
    # 产物是按时间窗筛的，正常情况下应 ≤ 源库且同量级（允许 60 天窗口差异）
    if [ "$DST_S" -gt "$SRC_S" ]; then
        bad "产物会话数($DST_S) > 源库($SRC_S) —— 数据异常"
    else
        ok "会话数合理: 产物 $DST_S / 源库 $SRC_S"
    fi
    # 每个会话平均消息数应在个位数以上（空壳库会有会话没消息）
    if [ "$DST_S" -gt 0 ] && [ "$DST_M" -gt 0 ]; then
        AVG=$(( DST_M / DST_S ))
        if [ "$AVG" -lt 2 ]; then
            bad "平均消息数仅 $AVG 条/会话，疑似空壳导出"
        else
            ok "平均 $AVG 条消息/会话"
        fi
    fi
fi
say ""

# ── 4. 扫出被绿色淹掉的报错 ───────────────────────────────────
say "【4】日志里的隐藏报错"
if [ -f "$LOG" ]; then
    HID=$(grep -nE 'no such column|Traceback|OperationalError|❌|导出入失败' "$LOG" 2>/dev/null | tail -5)
    if [ -n "$HID" ]; then
        say "$HID" | while read -r l; do bad "日志: $l"; done
    else
        ok "无隐藏报错"
    fi
    # 日志声称的计数 vs 产物真值
    CLAIM=$(grep -oE 'sessions=[0-9]+ messages=[0-9]+' "$LOG" 2>/dev/null | tail -1)
    if [ -n "$CLAIM" ]; then
        say "  日志声称: $CLAIM （产物真值: sessions=$DST_S messages=$DST_M）"
    else
        bad "日志里没有 sessions=/messages= 字段 —— 无法交叉核对（脚本需加该输出）"
    fi
else
    bad "无日志: $LOG"
fi
say ""

say "════════ 结论 ════════"
if [ "$FAIL" -eq 0 ]; then
    say "  ✅ 通过：产物量级与源数据相符，日志无隐藏报错"
    exit 0
else
    say "  🔴 发现问题（见上方 🔴 行）—— 视为备份失败，不要只看日志的 ✓"
    exit 1
fi
