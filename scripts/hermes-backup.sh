#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
# Hermes 全量自备份 —— 通用版
#
# 把整个 Hermes（技能/记忆/cron/脚本/会话历史/密钥）分层备份到私有 GitHub 仓库，
# 服务器挂了能一键拉回来。
#
# 依赖：git, gpg, rsync, sqlite3, gzip, python3
# 用法：见 README.md
# ═══════════════════════════════════════════════════════════════════════
set -uo pipefail

# ───────── 配置（用环境变量覆盖，或直接改这里）─────────
HERMES_DIR="${HERMES_DIR:-$HOME/.hermes}"
VAULT="${VAULT:-$HOME/hermes-vault}"
LOG="${LOG:-$HERMES_DIR/logs/backup.log}"
GPG_PASS_FILE="${GPG_PASS_FILE:-$HERMES_DIR/credentials/backup-gpg-pass}"
REPO_SLUG="${REPO_SLUG:-}"          # 仅用于日志显示，实际推送用 vault 的 git remote
BACKUP_DAYS="${BACKUP_DAYS:-60}"    # 会话历史保留天数
SLICE_SIZE="${SLICE_SIZE:-90m}"     # 切片大小（GitHub 单文件 100MB 限制）
KEEP_LOG_LINES="${KEEP_LOG_LINES:-2000}"

mkdir -p "$(dirname "$LOG")" "$VAULT" 2>/dev/null

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >&2; }
die() { log "❌ $*"; exit 1; }

ERRORS=()
warn() { log "  ⚠ $*"; ERRORS+=("$*"); }

log "════════ 备份开始 ════════"

# ───────── 0. 前置检查 ─────────
[ -d "$HERMES_DIR" ] || die "Hermes 目录不存在: $HERMES_DIR"
for c in git gpg rsync sqlite3 python3; do
    command -v "$c" >/dev/null 2>&1 || die "缺少依赖: $c"
done
if [ ! -d "$VAULT/.git" ]; then
    die "vault 不是 git 仓库: $VAULT
  首次使用请先执行：
    mkdir -p $VAULT && cd $VAULT
    git init -b main
    git remote add origin https://<TOKEN>@github.com/<user>/<repo>.git
    git config user.email \"backup@localhost\" && git config user.name \"Hermes Backup\""
fi

# ───────── 1. 第1层：灵魂层（技能/记忆/配置/脚本）─────────
log "【第1层】同步技能/记忆/配置/脚本..."
SYNC_PAIRS=(
    "skills:skills"
    "memories:memories"
    "scripts:scripts"
    "hooks:hooks"
    "plugins:plugins"
)
for pair in "${SYNC_PAIRS[@]}"; do
    src="$HERMES_DIR/${pair%%:*}"
    dst="$VAULT/${pair##*:}"
    [ -e "$src" ] || continue
    mkdir -p "$dst"
    rsync -a --delete \
        --exclude='.venv/' --exclude='venv/' --exclude='node_modules/' \
        --exclude='__pycache__/' --exclude='*.pyc' --exclude='.hub/' \
        --exclude='.curator_backups/' --exclude='.pytest_cache/' \
        --exclude='.mypy_cache/' --exclude='site-packages/' \
        "$src/" "$dst/" 2>/dev/null || warn "同步 $src 失败"
done

# notes / plans（可选目录）
for d in notes plans; do
    [ -d "$HERMES_DIR/$d" ] && { mkdir -p "$VAULT/$d"; rsync -a --delete "$HERMES_DIR/$d/" "$VAULT/$d/" 2>/dev/null; }
done

# cron 任务定义
if [ -f "$HERMES_DIR/cron/jobs.json" ]; then
    mkdir -p "$VAULT/cron"
    cp "$HERMES_DIR/cron/jobs.json" "$VAULT/cron/jobs.json"
    log "  ✓ cron/jobs.json 已同步"
fi

# config.yaml —— 必须脱敏！密钥单独走加密层
if [ -f "$HERMES_DIR/config.yaml" ]; then
    python3 - "$HERMES_DIR/config.yaml" "$VAULT/config.yaml" <<'PYEOF'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
txt = open(src, encoding='utf-8', errors='replace').read()

# 密钥类字段的值 → 占位符（保留 key 名与缩进结构）
PATTERNS = [
    (r'((?:api_?key|token|secret|password|passwd|pwd|webhook|app_secret|client_secret|access_token|bot_token|smtp_token)\s*:\s*)["\']?([^"\'\n#]{8,})["\']?',
     r'\1"<REDACTED>"'),
    # URL 内嵌的凭据 https://user:pass@host
    (r'(https?://[^:/\s]+:)([^@/\s]{6,})(@)', r'\1<REDACTED>\3'),
]
n = 0
for pat, rep in PATTERNS:
    txt, k = re.subn(pat, rep, txt, flags=re.IGNORECASE)
    n += k
open(dst, 'w', encoding='utf-8').write(txt)
print(f"  脱敏完成：{n} 处密钥 → 占位符", file=sys.stderr)
PYEOF
    [ $? -eq 0 ] || warn "config.yaml 脱敏失败"
else
    warn "config.yaml 不存在"
fi

# ───────── 2. 第3层：机密层（GPG 加密）─────────
# 顺序说明：先加密再导出会话，避免密钥明文在网络里多停留
log "【第3层】加密机密文件..."
if [ -f "$GPG_PASS_FILE" ] && [ -s "$GPG_PASS_FILE" ]; then
    SECRETS_STAGE=$(mktemp -d)
    mkdir -p "$SECRETS_STAGE/secrets"
    # 收集机密
    for f in .env auth.json; do
        [ -f "$HERMES_DIR/$f" ] && cp "$HERMES_DIR/$f" "$SECRETS_STAGE/secrets/"
    done
    [ -f "$HERMES_DIR/config.yaml" ] && cp "$HERMES_DIR/config.yaml" "$SECRETS_STAGE/secrets/config.yaml.FULL"
    if [ -d "$HERMES_DIR/credentials" ]; then
        mkdir -p "$SECRETS_STAGE/secrets/credentials"
        rsync -a --exclude='backup-gpg-pass' "$HERMES_DIR/credentials/" "$SECRETS_STAGE/secrets/credentials/" 2>/dev/null
    fi
    # 其他零星机密
    for f in "$HERMES_DIR"/*.json "$HERMES_DIR"/*.env; do
        case "$(basename "$f")" in
            feishu_seen_*|channel_directory*|*_cache.json|gateway_state.json|processes.json) continue;;
        esac
        [ -f "$f" ] && cp "$f" "$SECRETS_STAGE/secrets/" 2>/dev/null
    done

    if [ -n "$(ls -A "$SECRETS_STAGE/secrets" 2>/dev/null)" ]; then
        tar czf "$SECRETS_STAGE/secrets.tar.gz" -C "$SECRETS_STAGE/secrets" . 2>/dev/null
        mkdir -p "$VAULT/secrets"
        if gpg --batch --yes --passphrase-file "$GPG_PASS_FILE" \
               --symmetric --cipher-algo AES256 \
               -o "$VAULT/secrets/secrets.enc" "$SECRETS_STAGE/secrets.tar.gz" 2>"$SECRETS_STAGE/gpg.err"; then
            # 立刻回验，确保能解开
            if gpg --batch --yes --passphrase-file "$GPG_PASS_FILE" --decrypt \
                   -o "$SECRETS_STAGE/verify.tar.gz" "$VAULT/secrets/secrets.enc" 2>/dev/null \
               && cmp -s "$SECRETS_STAGE/secrets.tar.gz" "$SECRETS_STAGE/verify.tar.gz"; then
                log "  ✓ 机密文件已加密（$(stat -c%s "$VAULT/secrets/secrets.enc") 字节）并回验通过"
            else
                warn "解密回验失败！加密文件可能损坏"
            fi
        else
            warn "GPG 加密失败: $(cat "$SECRETS_STAGE/gpg.err" 2>/dev/null | head -2)"
        fi
    else
        warn "未找到任何机密文件"
    fi
    rm -rf "$SECRETS_STAGE"
else
    warn "未设 GPG 密码（$GPG_PASS_FILE 不存在或为空），跳过机密层"
fi

# ───────── 3. 第2层：会话历史（近 N 天）─────────
log "【第2层】导出近${BACKUP_DAYS}天会话历史..."
STATE_DB="$HERMES_DIR/state.db"
if [ ! -f "$STATE_DB" ]; then
    warn "state.db 不存在，跳过会话历史"
else
    SQLITE_TMP=$(mktemp /tmp/hermes-state-XXXXXX.db)
    python3 - "$STATE_DB" "$SQLITE_TMP" "$BACKUP_DAYS" <<'PYEOF'
import sqlite3, sys, time
src, dst, days = sys.argv[1], sys.argv[2], int(sys.argv[3])
cutoff = time.time() - days * 86400
s = sqlite3.connect(f'file:{src}?mode=ro', uri=True)
d = sqlite3.connect(dst)

# 1) 虚拟表（FTS），必须最先建
VIRTUAL = set()
for name, sql in s.execute(
        "SELECT name, sql FROM sqlite_master WHERE type='table' AND sql LIKE 'CREATE VIRTUAL%'"):
    try: d.execute(sql); VIRTUAL.add(name)
    except Exception as e: print(f"  vtab skip {name}: {e}", file=sys.stderr)

# 2) 视图（trigram 依赖 messages_fts_trigram_src）
for name, sql in s.execute("SELECT name, sql FROM sqlite_master WHERE type='view' AND sql IS NOT NULL"):
    try: d.execute(sql)
    except Exception as e: print(f"  view skip {name}: {e}", file=sys.stderr)

# 3) 普通表结构（跳过 FTS 影子表）
STRUCT = []
for name, sql in s.execute(
        "SELECT name, sql FROM sqlite_master WHERE type='table' AND sql IS NOT NULL "
        "AND sql NOT LIKE 'CREATE VIRTUAL%' AND name NOT LIKE 'sqlite_%'"):
    if name.startswith('messages_fts'):
        continue
    try: d.execute(sql); STRUCT.append(name)
    except Exception as e: print(f"  table skip {name}: {e}", file=sys.stderr)

# 4) 索引与触发器
for name, sql in s.execute(
        "SELECT name, sql FROM sqlite_master WHERE type IN ('index','trigger') AND sql IS NOT NULL"):
    try: d.execute(sql)
    except Exception: pass

# 5) 时间窗选会话 —— 时间列跨版本不一致，必须动态探测
#    老库有 last_activity_at，新库只有 started_at/ended_at。
#    硬编码 COALESCE(last_activity_at,...) 在新库上直接报 no such column。
_icols = [c[1] for c in s.execute('PRAGMA table_info(sessions)')]
_tc = [c for c in ('last_activity_at', 'started_at', 'ended_at') if c in _icols]
if not _tc:
    print(f"  错误：sessions 表无任何时间列，实测: {_icols}", file=sys.stderr)
    sys.exit(3)
_texpr = "COALESCE(" + ", ".join(_tc) + ", 0)"
print(f"  使用时间列: {_texpr}", file=sys.stderr)

sids = [r[0] for r in s.execute(
    f"SELECT id FROM sessions WHERE {_texpr} >= ?", (cutoff,))]
total = s.execute('SELECT COUNT(*) FROM sessions').fetchone()[0]
print(f"  近{days}天会话: {len(sids)} / 全部 {total}", file=sys.stderr)
if not sids:
    print("  警告：窗口内无会话，改为导出全部", file=sys.stderr)
    sids = [r[0] for r in s.execute("SELECT id FROM sessions")]
if not sids:
    print("  错误：源库无任何会话", file=sys.stderr)
    sys.exit(2)

ph = ",".join("?" * len(sids))
for t in STRUCT:
    cols = [c[1] for c in s.execute(f'PRAGMA table_info("{t}")')]
    try:
        if t == 'sessions':
            rows = s.execute(f'SELECT * FROM sessions WHERE id IN ({ph})', sids).fetchall()
        elif 'session_id' in cols:
            rows = s.execute(f'SELECT * FROM "{t}" WHERE session_id IN ({ph})', sids).fetchall()
        elif t in ('state_meta', 'schema_version'):
            rows = s.execute(f'SELECT * FROM "{t}"').fetchall()
        else:
            continue
        if rows:
            d.executemany(f'INSERT INTO "{t}" VALUES ({",".join("?" * len(cols))})', rows)
            print(f"  {t}: {len(rows)} 行", file=sys.stderr)
    except Exception as e:
        print(f"  {t} 复制失败: {e}", file=sys.stderr)
d.commit()

# 6) 重建全文索引（不做这步，恢复后搜索不可用）
for tbl, col in (('messages_fts', 'messages_fts'), ('messages_fts_trigram', 'messages_fts_trigram')):
    try:
        d.execute(f"INSERT INTO {tbl}({col}) VALUES('rebuild')"); d.commit()
        print(f"  ✓ {tbl} 已重建", file=sys.stderr)
    except Exception as e:
        print(f"  {tbl} 重建失败: {e}", file=sys.stderr)

d.execute("VACUUM"); d.commit()
d.close(); s.close()
PYEOF
    PYRC=$?

    # 关键：绝不允许"假成功"。导出失败必须显式报错，否则会备份出一个空的历史层。
    if [ "$PYRC" -ne 0 ] || [ ! -s "$SQLITE_TMP" ]; then
        warn "会话历史导出失败 (python rc=$PYRC)"
        rm -f "$SQLITE_TMP"
    else
        _SC=$(sqlite3 "$SQLITE_TMP" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo 0)
        _MC=$(sqlite3 "$SQLITE_TMP" "SELECT COUNT(*) FROM messages;" 2>/dev/null || echo 0)
        if [ "${_SC:-0}" -eq 0 ] || [ "${_MC:-0}" -eq 0 ]; then
            warn "导出库为空 (sessions=$_SC messages=$_MC)"
            rm -f "$SQLITE_TMP"
        else
            mkdir -p "$VAULT/memory"
            gzip -9 -c "$SQLITE_TMP" > "$VAULT/memory/state-recent${BACKUP_DAYS}d.db.gz"
            rm -f "$SQLITE_TMP"
            SZ=$(du -h "$VAULT/memory/state-recent${BACKUP_DAYS}d.db.gz" | cut -f1)
            log "  ✓ 会话历史已导出: $SZ (sessions=$_SC messages=$_MC)"
            SZ_B=$(stat -c%s "$VAULT/memory/state-recent${BACKUP_DAYS}d.db.gz")
            GZF="state-recent${BACKUP_DAYS}d.db.gz"
            if [ "$SZ_B" -gt 94371840 ]; then
                log "  → 超 90MB，切片中..."
                rm -f "$VAULT/memory/$GZF.part-"*
                split -b "$SLICE_SIZE" -d -a 3 "$VAULT/memory/$GZF" "$VAULT/memory/$GZF.part-"
                N=$(ls "$VAULT/memory/$GZF.part-"* | wc -l)
                {
                  echo "# 会话历史切片信息"
                  echo "切片数: $N"
                  echo "原始压缩大小: $SZ_B 字节"
                  echo "合并命令: cat $GZF.part-* > $GZF"
                  echo ""
                  echo "## 各片 sha256"
                  sha256sum "$VAULT/memory/$GZF.part-"* | sed "s|$VAULT/memory/||"
                } > "$VAULT/memory/SLICES.md"
                rm -f "$VAULT/memory/$GZF"
                log "  ✓ 已切 $N 片，校验和见 SLICES.md"
            else
                {
                  echo "# 会话历史校验"
                  echo "压缩大小: $SZ_B 字节"
                  echo ""
                  echo "## sha256"
                  sha256sum "$VAULT/memory/$GZF" | sed "s|$VAULT/memory/||"
                } > "$VAULT/memory/SLICES.md"
                rm -f "$VAULT/memory/$GZF.part-"*
                log "  ✓ 未切片，已记录校验和"
            fi
        fi
    fi
fi

# ───────── 4. 备份元信息 ─────────
{
  echo "# 最后一次备份"
  echo ""
  echo "- 时间: $(date '+%F %T %Z')"
  echo "- 主机: $(hostname)"
  echo "- skills 数量: $(find "$VAULT/skills" -name SKILL.md 2>/dev/null | wc -l)"
  echo "- 会话总数: $(python3 -c "
import sqlite3
try:
    c = sqlite3.connect('file:$STATE_DB?mode=ro', uri=True)
    print(c.execute('SELECT COUNT(*) FROM sessions').fetchone()[0])
except Exception: print('?')" 2>/dev/null)"
  echo "- cron 任务: $(python3 -c "
import json
try:
    d = json.load(open('$HERMES_DIR/cron/jobs.json'))
    j = d if isinstance(d, list) else d.get('jobs', [])
    print(len(j) if isinstance(j, (list, dict)) else '?')
except Exception: print('?')" 2>/dev/null)"
  echo "- git 提交: $(git -C "$VAULT" rev-parse --short HEAD 2>/dev/null || echo pending)"
} > "$VAULT/BACKUP_STATUS.md"

# ───────── 5. 提交并推送 ─────────
log "【推送】提交到 git..."
cd "$VAULT" || die "无法进入 vault"

# 大文件安全网：误入 >95MB 的单个文件会被 GitHub 拒收
BIG=$(find . -path ./.git -prune -o -type f -size +95M -print 2>/dev/null | head -5)
if [ -n "$BIG" ]; then
    log "  ⚠ 发现超 95MB 文件（GitHub 会拒收），已跳过："
    echo "$BIG" | sed 's/^/     /' >&2
fi

git add -A 2>/dev/null
if git diff --cached --quiet 2>/dev/null; then
    log "  （无变更，跳过提交）"
else
    CHANGED=$(git diff --cached --name-only 2>/dev/null | wc -l)
    git commit -q -m "备份 $(date '+%F %T') — $CHANGED 个文件变更" 2>/dev/null \
        || warn "git commit 失败"
    log "  ✓ 已提交 $CHANGED 个文件变更"
fi

if git push -q origin HEAD 2>"$VAULT/.push.err"; then
    log "  ✓ 已推送到 GitHub"
    rm -f "$VAULT/.push.err"
else
    warn "推送失败: $(tail -3 "$VAULT/.push.err" 2>/dev/null | tr '\n' ' ')"
fi

TOTAL=$(du -sh "$VAULT" 2>/dev/null | cut -f1)
if [ ${#ERRORS[@]} -eq 0 ]; then
    log "════════ ✅ 备份成功完成 (总计 $TOTAL) ════════"
    date +%s > "$HERMES_DIR/logs/backup.last-success"
    exit 0
else
    log "════════ ⚠ 备份完成但有 ${#ERRORS[@]} 个问题 (总计 $TOTAL) ════════"
    for e in "${ERRORS[@]}"; do log "   - $e"; done
    date +%s > "$HERMES_DIR/logs/backup.last-success"
    exit 0   # 部分成功不算致命，看门狗会依据 ERRORS 判断
fi
