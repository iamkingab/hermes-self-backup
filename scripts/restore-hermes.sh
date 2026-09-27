#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Hermes 灾难恢复 —— 从 GitHub 备份完整拉回
#
# 场景：服务器挂了 / 重装了 / 换机了，Hermes 变成一个空壳。
# 用法：
#   1. 装好 Hermes（能跑起来就行）
#   2. 停掉 Hermes 进程
#   3. bash restore-hermes.sh
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

HERMES_DIR="${HERMES_DIR:-$HOME/.hermes}"
WORK="${WORK:-/tmp/hermes-restore}"
GPG_PASS_FILE="${GPG_PASS_FILE:-$HERMES_DIR/credentials/backup-gpg-pass}"

info() { echo "▶ $*"; }
ok()   { echo "  ✅ $*"; }
warn() { echo "  ⚠ $*"; }
die()  { echo "  ❌ $*"; exit 1; }

echo "════════════════════════════════════════════"
echo " Hermes 灾难恢复"
echo " 目标: $HERMES_DIR"
echo "════════════════════════════════════════════"
echo

# ───────── 1. 收集输入 ─────────
if [ -z "${REPO_URL:-}" ]; then
    read -rp "备份仓库 HTTPS 地址（含 token，形如 https://user:TOKEN@github.com/u/r.git）: " REPO_URL
fi
[ -n "$REPO_URL" ] || die "必须提供仓库地址"

NEED_PASS=0
[ -s "$GPG_PASS_FILE" ] || NEED_PASS=1

# ───────── 2. 克隆 ─────────
info "从 GitHub 克隆备份"
rm -rf "$WORK"; mkdir -p "$WORK"
git clone -q "$REPO_URL" "$WORK/vault" || die "克隆失败（检查地址与 token）"
cd "$WORK/vault"
ok "克隆完成: $(git rev-parse --short HEAD) / $(du -sh . | cut -f1)"

# ───────── 3. 停 Hermes ─────────
info "停止 Hermes（避免恢复时文件被占用）"
if command -v hermes >/dev/null 2>&1; then
    hermes stop 2>/dev/null && ok "hermes stop" || warn "hermes stop 未生效（可能未在运行）"
fi
pkill -f 'hermes.*gateway' 2>/dev/null && ok "已终止残留进程" || true
sleep 2

# ───────── 4. 备份现有配置（可回滚）─────────
if [ -d "$HERMES_DIR" ] && [ -n "$(ls -A "$HERMES_DIR" 2>/dev/null)" ]; then
    BAK="$HERMES_DIR.before-restore-$(date +%Y%m%d%H%M%S)"
    info "现有 $HERMES_DIR 非空，先备份到 $BAK"
    mv "$HERMES_DIR" "$BAK" 2>/dev/null && ok "已备份（不满意可 mv 回来）" || warn "备份失败，继续"
fi
mkdir -p "$HERMES_DIR"

# ───────── 5. 第1层：灵魂层 ─────────
info "还原第1层（技能/记忆/脚本/配置）"
for d in skills memories scripts hooks plugins notes plans cron; do
    if [ -e "$WORK/vault/$d" ]; then
        mkdir -p "$HERMES_DIR/$d"
        rsync -a "$WORK/vault/$d/" "$HERMES_DIR/$d/" 2>/dev/null && \
            echo "     $d ($(find "$HERMES_DIR/$d" -type f 2>/dev/null | wc -l) 个文件)"
    fi
done
[ -f "$WORK/vault/SOUL.md" ] && cp "$WORK/vault/SOUL.md" "$HERMES_DIR/SOUL.md" && ok "SOUL.md"

# ───────── 6. 第2层：会话历史 ─────────
info "还原第2层（会话历史）"
M="$WORK/vault/memory"
GZ=$(ls "$M"/state-recent*.db.gz 2>/dev/null | head -1)
if [ -z "$GZ" ] && ls "$M"/state-recent*.db.gz.part-* >/dev/null 2>&1; then
    GZF=$(ls "$M"/state-recent*.db.gz.part-* | head -1 | sed 's/\.part-[0-9]*$//')
    info "合并切片 → $(basename "$GZF")"
    cat "$GZF".part-* > "$GZF" || die "切片合并失败"
    # 校验 SLICES.md 里的 sha256
    if [ -f "$M/SLICES.md" ]; then
        while read -r sum f; do
            [ -z "$sum" ] && continue
            case "$sum" in \#*) continue;; '[a-f0-9]'*) ;; *) continue;; esac
            if [ -f "$M/$f" ]; then
                A=$(sha256sum "$M/$f" | cut -d' ' -f1)
                [ "$A" = "$sum" ] && ok "$f 校验通过" || warn "$f sha256 不匹配！"
            fi
        done < <(grep -E '^[a-f0-9]{64} ' "$M/SLICES.md")
    fi
    GZ="$GZF"
fi
if [ -n "$GZ" ]; then
    gunzip -c "$GZ" > "$HERMES_DIR/state.db" 2>/dev/null || die "解压失败"
    INT=$(sqlite3 "$HERMES_DIR/state.db" "PRAGMA integrity_check;" 2>/dev/null)
    SC=$(sqlite3 "$HERMES_DIR/state.db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo '?')
    MC=$(sqlite3 "$HERMES_DIR/state.db" "SELECT COUNT(*) FROM messages;" 2>/dev/null || echo '?')
    ok "state.db 还原: 完整性=$INT / sessions=$SC / messages=$MC"
else
    warn "未找到会话历史文件，跳过"
fi

# ───────── 7. 第3层：机密层 ─────────
info "还原第3层（密钥）"
if [ -f "$WORK/vault/secrets/secrets.enc" ]; then
    if [ ! -f "$GPG_PASS_FILE" ]; then
        echo
        echo "  需要备份时的 GPG 密码来解密密钥层。"
        while :; do
            read -rsp "  输入 GPG 密码: " P; echo
            [ ${#P} -ge 1 ] && break
            echo "  密码不能为空"
        done
        mkdir -p "$(dirname "$GPG_PASS_FILE")"
        printf '%s' "$P" > "$GPG_PASS_FILE"; chmod 600 "$GPG_PASS_FILE"; unset P
    fi
    if gpg --batch --yes --passphrase-file "$GPG_PASS_FILE" \
           --decrypt -o "$WORK/secrets.tar.gz" "$WORK/vault/secrets/secrets.enc" 2>"$WORK/gpg.err"; then
        mkdir -p "$WORK/secrets" && tar xzf "$WORK/secrets.tar.gz" -C "$WORK/secrets"
        # .env / auth.json / 其他散件
        for f in "$WORK/secrets"/*.json "$WORK/secrets"/*.env "$WORK/secrets"/.env; do
            [ -f "$f" ] && cp "$f" "$HERMES_DIR/" 2>/dev/null
        done
        # 完整 config.yaml 覆盖脱敏版
        if [ -f "$WORK/secrets/config.yaml.FULL" ]; then
            cp "$WORK/secrets/config.yaml.FULL" "$HERMES_DIR/config.yaml"
            ok "config.yaml 已用完整版覆盖（含真实密钥）"
        fi
        [ -d "$WORK/secrets/credentials" ] && {
            mkdir -p "$HERMES_DIR/credentials"
            rsync -a "$WORK/secrets/credentials/" "$HERMES_DIR/credentials/" 2>/dev/null
        }
        ok "密钥层已还原: $(find "$WORK/secrets" -type f | wc -l) 个文件"
    else
        warn "解密失败（密码错误？）: $(head -2 "$WORK/gpg.err")"
        warn "Hermes 主体已恢复，但需手动重填密钥"
    fi
else
    warn "备份中没有 secrets/secrets.enc（当初未设 GPG 密码）"
    [ -f "$WORK/vault/config.yaml" ] && cp "$WORK/vault/config.yaml" "$HERMES_DIR/config.yaml" && \
        warn "已还原脱敏版 config.yaml —— 需手动填入真实密钥"
fi

# ───────── 8. 收尾 ─────────
info "收尾"
mkdir -p "$HERMES_DIR/logs"
echo
echo "════════════════════════════════════════════"
echo " 恢复完成"
echo "════════════════════════════════════════════"
echo
echo "接下来："
echo "  1. 启动 Hermes:  hermes start   （或 systemctl --user start hermes-gateway）"
echo "  2. 验证会话历史:  hermes sessions list  （应看到历史会话）"
echo "  3. 验证技能:      ls $HERMES_DIR/skills  （应看到原技能目录）"
echo "  4. 验证 cron:     hermes cron list"
echo "  5. 【重要】重建自动备份："
echo "       cd $HOME/hermes-vault 2>/dev/null || { mkdir -p $HOME/hermes-vault && cd $HOME/hermes-vault && git init -b main; }"
echo "       git remote add origin $REPO_URL"
echo "       crontab -l | { cat; echo '0 4 * * * bash $HERMES_DIR/scripts/hermes-backup.sh >> $HERMES_DIR/logs/backup.log 2>&1'; } | crontab -"
echo
if [ -d "$HERMES_DIR.before-restore-"* ] 2>/dev/null; then
    echo "原有配置已备份到: $(ls -d "$HERMES_DIR.before-restore-"* 2>/dev/null | tail -1)"
fi
